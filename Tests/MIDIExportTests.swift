import Foundation
import SwiftMIDICore
import SwiftMIDIFile
import Testing
@testable import SillyMIDITools

private func note(_ onset: Double, _ offset: Double, _ pitch: Int, _ instrument: String = "acoustic_piano",
                  program: Int = 0, drum: Bool = false, velocity: Int? = nil, bends: [Int]? = nil) -> NoteEvent {
    NoteEvent(onset: onset, offset: offset, pitch: pitch, program: program, isDrum: drum, instrument: instrument, velocity: velocity, pitchBends: bends)
}

private func parse(_ data: Data) throws -> MusicalMIDI1File { try MusicalMIDI1File(data: data) }

private func absoluteEvents(_ track: MusicalMIDI1File.Track, _ file: MusicalMIDI1File) -> [(tick: Int, event: MIDIFileEvent)] {
    var tick = 0
    return track.events.map { e in
        tick += Int(e.delta.ticks(using: file.timebase))
        return (tick, e.event)
    }
}

struct MIDIExportTests {
    @Test func headerIsStandardMIDI() throws {
        let data = try MIDIBuilder.build(notes: [note(0, 1, 60)])
        #expect(Array(data.prefix(4)) == Array("MThd".utf8))
    }

    @Test func roundTripTrackCount() throws {
        let notes = [note(0, 1, 60), note(0, 1, 40, "acoustic_bass", program: 32), note(0, 0.5, 36, "drums", program: 128, drum: true)]
        let file = try parse(try MIDIBuilder.build(notes: notes))
        #expect(file.tracks.count == 4)
    }

    @Test func tickMath() throws {
        let file = try parse(try MIDIBuilder.build(notes: [note(1.0, 1.5, 60)]))
        let events = absoluteEvents(file.tracks[1], file)
        let on = events.first { if case .noteOn = $0.event { true } else { false } }
        let off = events.first { if case .noteOff = $0.event { true } else { false } }
        #expect(on?.tick == 960)
        #expect((off?.tick ?? 0) - (on?.tick ?? 0) == 480)
    }

    @Test func tempoControlsTicksAndConductorMetadata() throws {
        var options = MIDIExportOptions()
        options.grid = MIDIGrid(bpm: 90, numerator: 3, denominator: 4)
        let file = try parse(try MIDIBuilder.build(notes: [note(1, 1.5, 60)], options: options))
        let events = absoluteEvents(file.tracks[1], file)
        #expect(events.first { if case .noteOn = $0.event { true } else { false } }?.tick == 720)
        #expect(events.first { if case .noteOff = $0.event { true } else { false } }?.tick == 1080)
        let conductor = absoluteEvents(file.tracks[0], file)
        let bpm = conductor.compactMap { if case .tempo(let tempo) = $0.event { return 60_000_000 / Double(tempo.microsecondsPerQuarter) }; return nil }
        #expect(bpm.count == 1 && abs(bpm[0] - 90) < 0.001)
        #expect(conductor.contains { if case .timeSignature(let meter) = $0.event { return meter.numerator == 3 && meter.denominator == 2 }; return false })

        options.grid = MIDIGrid(bpm: 93.5, numerator: 6, denominator: 8)
        let sixEight = try parse(try MIDIBuilder.build(notes: [note(1, 1.5, 60)], options: options))
        #expect(absoluteEvents(sixEight.tracks[1], sixEight).first { if case .noteOn = $0.event { true } else { false } }?.tick == 748)
        #expect(absoluteEvents(sixEight.tracks[0], sixEight).contains {
            if case .timeSignature(let meter) = $0.event { return meter.numerator == 6 && meter.denominator == 3 }; return false
        })
    }

    @Test func meterMapAndAbsoluteSliceOrigin() throws {
        var options = MIDIExportOptions()
        options.grid = MIDIGrid(bpm: 120, meters: [MeterChange(bar: 0, numerator: 4, denominator: 4),
                                                     MeterChange(bar: 4, numerator: 3, denominator: 4)])
        options.sliceStart = 10.3
        options.comment = "origin"
        for relative in [true, false] {
            options.relativeTimeline = relative
            let data = try MIDIBuilder.build(notes: [note(8, 9, 60)], options: options)
            let file = try parse(data)
            let signatures = absoluteEvents(file.tracks[0], file).compactMap { item -> Int? in
                if case .timeSignature = item.event { return item.tick }; return nil
            }
            #expect(signatures == [0, 7680])
            #expect(absoluteEvents(file.tracks[0], file).contains { item in
                if case .text(let text) = item.event { return text.text == "origin" && item.tick == 0 }; return false
            })
            #expect(file.tracks.dropFirst().allSatisfy { track in
                !absoluteEvents(track, file).contains { if case .timeSignature = $0.event { return true }; return false }
            })
            let on = absoluteEvents(file.tracks[1], file).first { if case .noteOn = $0.event { return true }; return false }
            #expect(on?.tick == (relative ? 7680 : 17568))
            let imported = try MIDIImporter.decode(data)
            #expect(imported.grid == options.grid)
            #expect(abs(imported.notes[0].start - (relative ? 8 : 18.3)) < 0.000001)
        }
    }

    @Test func copyrightEventPresentOnlyWhenRequested() throws {
        func copyrights(_ options: MIDIExportOptions) throws -> Int {
            let file = try parse(try MIDIBuilder.build(notes: [note(0, 1, 60)], options: options))
            return file.tracks[0].events.filter {
                if case .text(let t) = $0.event { t.textType == .copyright } else { false }
            }.count
        }
        var options = MIDIExportOptions()
        #expect(try copyrights(options) == 0)
        options.copyright = "Transcribed with Basic Pitch by Spotify (Apache-2.0)."
        #expect(try copyrights(options) == 1)
    }

    @Test func sliceClipping() throws {
        var options = MIDIExportOptions()
        options.sliceLength = 2
        let file = try parse(try MIDIBuilder.build(notes: [note(1.5, 3.0, 60)], options: options))
        let off = absoluteEvents(file.tracks[1], file).first { if case .noteOff = $0.event { true } else { false } }
        #expect(off?.tick == 1920)
    }

    @Test func originalTimelineAddsTheSliceStart() throws {
        var options = MIDIExportOptions()
        options.sliceStart = 4
        options.relativeTimeline = false
        let file = try parse(try MIDIBuilder.build(notes: [note(1, 2, 60)], options: options))
        let on = absoluteEvents(file.tracks[1], file).first { if case .noteOn = $0.event { true } else { false } }
        #expect(on?.tick == 5 * 960)
    }

    @Test func drumsUseChannelTenAndMelodicSkipIt() {
        let map = MIDIBuilder.channels(for: (0..<12).map { "i\($0)" } + ["drums"], drums: ["drums"])
        #expect(map["drums"] == 9)
        #expect(!(0..<12).contains { map["i\($0)"] == 9 })
    }

    @Test func pitchBendsAreWrittenAndResetAfterTheNote() throws {
        let file = try parse(try MIDIBuilder.build(notes: [note(0, 1, 60, velocity: 90, bends: [0, 3, 0])]))
        let bends = absoluteEvents(file.tracks[1], file).filter { if case .pitchBend = $0.event { true } else { false } }
        #expect(bends.count == 4)
    }

    @Test func pitchBendsCanBeLeftOut() throws {
        var options = MIDIExportOptions()
        options.includesPitchBends = false
        let file = try parse(try MIDIBuilder.build(notes: [note(0, 1, 60, velocity: 90, bends: [0, 3, 0])], options: options))
        #expect(!absoluteEvents(file.tracks[1], file).contains { if case .pitchBend = $0.event { true } else { false } })
    }

    @Test func zeroNotesStillWriteAValidFile() throws {
        let file = try parse(try MIDIBuilder.build(notes: []))
        #expect(file.tracks.count == 1)
    }
}

extension MIDIExportTests {
    @Test func provenanceEventPresentOnlyWhenRequested() throws {
        func texts(_ options: MIDIExportOptions) throws -> [String] {
            let file = try parse(try MIDIBuilder.build(notes: [note(0, 1, 60)], options: options))
            return file.tracks[0].events.compactMap {
                if case .text(let t) = $0.event, t.text.hasPrefix(MIDIProvenance.prefix) { t.text } else { nil }
            }
        }
        var options = MIDIExportOptions()
        #expect(try texts(options).isEmpty)
        options.provenance = MIDIProvenance(source: "take.wav", modelID: "basic-pitch", partial: true)
        #expect(try texts(options) == [options.provenance!.text])
    }

    @Test func provenanceChangesNothingButTheConductorTrack() throws {
        let notes = [note(0, 1, 60), note(0.5, 1.5, 40, "acoustic_bass", program: 32)]
        var tagged = MIDIExportOptions()
        tagged.provenance = MIDIProvenance(modelID: "piano-onnx", edited: true)
        let plain = try parse(try MIDIBuilder.build(notes: notes))
        let withTag = try parse(try MIDIBuilder.build(notes: notes, options: tagged))

        #expect(plain.tracks.count == withTag.tracks.count)
        #expect(withTag.tracks[0].events.count == plain.tracks[0].events.count + 1)
        for index in 1..<plain.tracks.count {
            #expect(String(describing: absoluteEvents(plain.tracks[index], plain)) == String(describing: absoluteEvents(withTag.tracks[index], withTag)))
        }
        #expect(MIDIExportOptions().provenance == nil)
    }
}

extension MIDIExportTests {
    private func texts(_ file: MusicalMIDI1File) -> [String] {
        file.tracks[0].events.compactMap { if case .text(let t) = $0.event { t.text } else { nil } }
    }

    private var entry: ModelEntry { ModelCatalog.entry(id: "basic-pitch")! }

    @Test func aDraggedFileSaysWhereItCameFromAndCarriesNoNoticeBendsOrPath() throws {
        let notes = [note(0, 1, 60, velocity: 90, bends: [0, 3, 0]), note(0, 1, 23), note(0, 1, 96), note(1, 2, 95), note(1, 2, 24)]
        let item = MIDIExport.item(notes: notes, entry: entry, slice: AudioSlice(duration: 3), name: "take")
        let data = try MIDIBuilder.build(notes: item.notes, options: item.options)
        let file = try parse(data)

        #expect(item.notes.map(\.pitch) == [60, 95, 24])
        #expect(texts(file) == ["take", MIDIExport.comment])
        #expect(!absoluteEvents(file.tracks[1], file).contains { if case .pitchBend = $0.event { true } else { false } })
        #expect(data.range(of: Data(MIDIProvenance.prefix.utf8)) == nil)
    }

    @Test func theExportSheetCanAddTheNoticeAndThePitchBends() throws {
        let item = MIDIExport.item(notes: [note(0, 1, 60, velocity: 90, bends: [0, 3, 0])], entry: entry, slice: AudioSlice(duration: 3),
                                   name: "take", embedNotice: true, pitchBends: true)
        let file = try parse(try MIDIBuilder.build(notes: item.notes, options: item.options))

        #expect(texts(file) == ["take", try #require(entry.exportNotice), MIDIExport.comment])
        #expect(absoluteEvents(file.tracks[1], file).contains { if case .pitchBend = $0.event { true } else { false } })
    }

    @Test func theKeyInTheFileNameIgnoresNotesThatAreLeftOut() {
        let notes = [note(0, 1, 60), note(1, 2, 64), note(2, 3, 67)]
        let withNoise = notes + (0..<40).map { note(Double($0) / 10, Double($0) / 10 + 0.1, 97 + $0 % 3) }
        #expect(MIDIExport.fileName(notes: withNoise, name: "take") == MIDIExport.fileName(notes: notes, name: "take"))
    }
}
