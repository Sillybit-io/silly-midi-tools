import Foundation
import Testing
@testable import SillyMIDITools

// MARK: Raw Standard MIDI File bytes, independent of the library's encoder

private enum Ev {
    case on(Int, Int, Int)
    case off(Int, Int)
    case program(Int, Int)
    case tempo(Int)
    case meter(Int, Int)
    case text(String)

    var bytes: [UInt8] {
        switch self {
        case .on(let channel, let pitch, let velocity): [UInt8(0x90 | channel), UInt8(pitch), UInt8(velocity)]
        case .off(let channel, let pitch): [UInt8(0x80 | channel), UInt8(pitch), 0]
        case .program(let channel, let program): [UInt8(0xC0 | channel), UInt8(program)]
        case .tempo(let microseconds): [0xFF, 0x51, 0x03, UInt8(microseconds >> 16 & 0xFF), UInt8(microseconds >> 8 & 0xFF), UInt8(microseconds & 0xFF)]
        case .meter(let numerator, let power): [0xFF, 0x58, 0x04, UInt8(numerator), UInt8(power), 24, 8]
        case .text(let string): [0xFF, 0x01, UInt8(string.utf8.count)] + Array(string.utf8)
        }
    }
}

private func vlq(_ value: Int) -> [UInt8] {
    var groups = [UInt8(value & 0x7F)]
    var rest = value >> 7
    while rest > 0 {
        groups.append(UInt8(rest & 0x7F) | 0x80)
        rest >>= 7
    }
    return groups.reversed()
}

private func be(_ value: Int, bytes: Int) -> [UInt8] {
    (0..<bytes).map { UInt8(value >> (8 * (bytes - 1 - $0)) & 0xFF) }
}

private func track(_ events: [(Int, Ev)]) -> [UInt8] {
    var body: [UInt8] = []
    var last = 0
    for (tick, event) in events.enumerated().sorted(by: { ($0.element.0, $0.offset) < ($1.element.0, $1.offset) }).map(\.element) {
        body += vlq(tick - last) + event.bytes
        last = tick
    }
    body += [0x00, 0xFF, 0x2F, 0x00]
    return Array("MTrk".utf8) + be(body.count, bytes: 4) + body
}

private func smf(format: Int = 1, division: Int = 480, tracks: [[UInt8]]) -> Data {
    let header = Array("MThd".utf8) + be(6, bytes: 4) + be(format, bytes: 2) + be(tracks.count, bytes: 2) + be(division, bytes: 2)
    return Data(header + tracks.flatMap { $0 })
}

private func decode(_ data: Data) throws -> ImportedMIDI { try MIDIImporter.decode(data) }

// MARK: Library fakes

private final class MemoryBookmarks: BookmarkStorage {
    var values: [String: Data] = [:]
    func data(for key: String) -> Data? { values[key] }
    func set(_ data: Data?, for key: String) { values[key] = data }
}

private struct PlainCodec: BookmarkCodec {
    func makeBookmark(for url: URL) throws -> Data { Data(url.path.utf8) }
    func resolve(_ data: Data) throws -> (url: URL, isStale: Bool) { (URL(fileURLWithPath: String(decoding: data, as: UTF8.self)), false) }
}

private struct NoAccess: ScopedAccess {
    func start(_ url: URL) -> Bool { false }
    func stop(_ url: URL) {}
}

@MainActor
private struct NoWatcher: FolderWatcher {
    func watch(_ url: URL, onChange: @escaping @MainActor () -> Void) -> (any FolderWatching)? { nil }
}

private func scratchFolder() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "scratch-midi-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private let simpleFile = smf(tracks: [track([(0, .on(0, 60, 80)), (480, .off(0, 60))])])

struct MIDIImporterTests {
    @Test func firstTempoAndMeterOrDefaults() throws {
        let notes = track([(0, .on(0, 60, 80)), (480, .off(0, 60))])
        let withGrid = try decode(smf(tracks: [track([(0, .tempo(666_667)), (0, .meter(3, 2))]), notes]))
        #expect(withGrid.grid == MIDIGrid(bpm: 90, numerator: 3, denominator: 4))
        #expect(try decode(smf(tracks: [notes])).grid == .standard)
    }

    @Test func meterEventsRoundToBarsAndDefaultBeforeFirstEvent() throws {
        let notes = track([(0, .on(0, 60, 80)), (9600, .off(0, 60))])
        let expected = MIDIGrid(bpm: 120, meters: [MeterChange(bar: 0, numerator: 4, denominator: 4),
                                                    MeterChange(bar: 4, numerator: 3, denominator: 4)])
        for tick in [7680, 7700] {
            let conductor = track([(0, .meter(4, 2)), (tick, .meter(3, 2))])
            #expect(try decode(smf(tracks: [conductor, notes])).grid == expected)
        }
        let late = track([(3840, .meter(3, 2))])
        #expect(try decode(smf(tracks: [late, notes])).grid.meters == [MeterChange(bar: 0, numerator: 4, denominator: 4),
                                                                      MeterChange(bar: 2, numerator: 3, denominator: 4)])
        let duplicate = track([(0, .meter(4, 2)), (7680, .meter(6, 3)), (7700, .meter(3, 2))])
        #expect(try decode(smf(tracks: [duplicate, notes])).grid == expected)
        let invalid = track([(0, .meter(3, 7))])
        #expect(try decode(smf(tracks: [invalid, notes])).grid.meters[0].denominator == 4)
    }

    @Test func meterChangesUseFlattenedTempoClock() throws {
        let notes = track([(0, .on(0, 60, 80)), (9600, .off(0, 60))])
        let conductor = track([(0, .tempo(500_000)), (960, .tempo(1_000_000)), (4320, .meter(3, 2))])
        let imported = try decode(smf(tracks: [conductor, notes]))
        #expect(imported.grid.meters == [MeterChange(bar: 0, numerator: 4, denominator: 4),
                                         MeterChange(bar: 4, numerator: 3, denominator: 4)])
    }
    @Test func tempoChangesAreIntegratedIntoSeconds() throws {
        let conductor = track([(0, .tempo(500_000)), (480, .tempo(1_000_000))])
        let notes = track([(0, .on(0, 60, 80)), (480, .off(0, 60)), (480, .on(0, 62, 90)), (960, .off(0, 62))])
        let imported = try decode(smf(tracks: [conductor, notes]))

        #expect(imported.notes.map(\.id) == [1, 2])
        #expect(imported.notes.map(\.pitch) == [60, 62])
        #expect(imported.notes.map(\.start) == [0, 0.5])
        #expect(imported.notes.map(\.duration) == [0.5, 1.0])
        #expect(imported.notes.map(\.velocity) == [80, 90])
        #expect(imported.grid.bpm == 120)
    }

    @Test func laterTemposAndTicksPerQuarterScaleCorrectly() throws {
        let conductor = track([(0, .tempo(250_000)), (960, .tempo(500_000))])
        let notes = track([(0, .on(0, 60, 100)), (1920, .off(0, 60))])
        let imported = try decode(smf(division: 960, tracks: [conductor, notes]))
        // 960 ticks at 250 ms per quarter of 960 ticks is 0.25 s, then 960 more at 500 ms is 0.5 s.
        #expect(imported.notes[0].duration == 0.75)
        #expect(imported.grid.bpm == 240)
    }

    @Test func typeZeroPairsNotesAndTreatsZeroVelocityAsOff() throws {
        let single = track([
            (0, .program(1, 33)), (0, .on(1, 40, 90)), (240, .on(1, 40, 0)),
            (0, .on(0, 72, 64)), (480, .off(0, 72)),
        ])
        let imported = try decode(smf(format: 0, tracks: [single]))

        #expect(imported.notes.map(\.pitch) == [40, 72])
        #expect(imported.notes.map(\.duration) == [0.25, 0.5])
        #expect(imported.notes.map(\.velocity) == [90, 64])
        #expect(imported.tracks.map(\.id) == ["bass", "piano"])
    }

    @Test func channelTenIsDrumsAndProgramsMapToClasses() throws {
        let drums = track([(0, .on(9, 36, 100)), (240, .off(9, 36))])
        let imported = try decode(smf(tracks: [drums]))
        let drumTrack = try #require(imported.tracks.first)
        #expect(drumTrack.id == "drums" && drumTrack.isDrums)

        let table: [(Int?, String)] = [(nil, "piano"), (0, "piano"), (9, "chromatic"), (19, "organ"), (25, "guitar"), (33, "bass"),
                                       (40, "violin"), (42, "cello"), (47, "timpani"), (48, "string"), (53, "voice"), (56, "trumpet"),
                                       (60, "french"), (62, "brass"), (65, "sax"), (70, "bassoon"), (73, "flute"), (81, "synth"), (110, "piano")]
        for (program, name) in table {
            #expect(MIDIImporter.instrument(program: program, channel: 0) == name, "program \(String(describing: program))")
        }
        #expect(MIDIImporter.instrument(program: 33, channel: 9) == "drums")
    }

    @Test func aProgramChangeSplitsOneChannelAcrossTracks() throws {
        let notes = track([
            (0, .program(0, 0)), (0, .on(0, 60, 80)), (240, .off(0, 60)),
            (480, .program(0, 40)), (480, .on(0, 62, 80)), (720, .off(0, 62)),
        ])
        let imported = try decode(smf(tracks: [notes]))
        #expect(imported.notes.map(\.track) == ["piano", "violin"])
        #expect(imported.tracks.map(\.program) == [0, 40])
    }

    @Test func notesOutsideC1ToB6AreCountedNotKept() throws {
        let notes = track([
            (0, .on(0, 20, 80)), (240, .off(0, 20)), (0, .on(0, 100, 80)), (240, .off(0, 100)),
            (0, .on(0, 24, 80)), (240, .off(0, 24)), (0, .on(0, 95, 80)), (240, .off(0, 95)),
        ])
        let imported = try decode(smf(tracks: [notes]))
        #expect(imported.skippedNotes == 2)
        #expect(imported.notes.map(\.pitch) == [24, 95])

        let onlyOutside = track([(0, .on(0, 10, 80)), (240, .off(0, 10))])
        #expect(throws: MIDIImportError.noNotes) { try decode(smf(tracks: [onlyOutside])) }
        #expect(throws: MIDIImportError.noNotes) { try decode(smf(tracks: [track([])])) }
    }

    @Test func overlappingNotesPairInOrderAndOpenNotesEndWithTheTrack() throws {
        let overlap = track([
            (0, .on(0, 60, 80)), (240, .on(0, 60, 80)), (480, .off(0, 60)), (720, .off(0, 60)),
            (0, .on(0, 62, 80)), (0, .on(0, 64, 80)), (960, .off(0, 64)),
        ])
        let imported = try decode(smf(tracks: [overlap]))
        let byPitch = Dictionary(grouping: imported.notes, by: \.pitch)
        #expect(byPitch[60]?.map(\.start) == [0, 0.25])
        #expect(byPitch[60]?.map(\.duration) == [0.5, 0.5])
        #expect(byPitch[62]?.first?.duration == 1.0)
    }

    @Test func notesAreSortedByStartWithStableIDs() throws {
        let notes = track([(480, .on(0, 60, 80)), (720, .off(0, 60)), (0, .on(0, 72, 80)), (240, .off(0, 72))])
        let imported = try decode(smf(tracks: [notes]))
        #expect(imported.notes.map(\.id) == [1, 2])
        #expect(imported.notes.map(\.pitch) == [72, 60])
    }

    @Test func rejectedFilesUseTheHandoffMessages() throws {
        let body = track([(0, .on(0, 60, 80)), (480, .off(0, 60))])
        #expect(throws: MIDIImportError.unsupportedType2) { try decode(smf(format: 2, tracks: [body])) }
        #expect(throws: MIDIImportError.smpteTiming) { try decode(smf(division: 0xE728, tracks: [body])) }
        #expect(throws: MIDIImportError.notMIDI) { try decode(Data("RIFF....WAVE".utf8)) }
        #expect(throws: MIDIImportError.notMIDI) { try decode(Data()) }
        #expect(throws: MIDIImportError.damaged) { try decode(Data("MThd".utf8)) }

        #expect(MIDIImportError.notMIDI.errorDescription == "This isn't a Standard MIDI File.")
        #expect(MIDIImportError.smpteTiming.errorDescription == "SMPTE-timed MIDI files aren't supported.")
        #expect(MIDIImportError.damaged.errorDescription == "The file is damaged.")
    }

    @Test func truncatedFilesAreDamagedWhereverTheyAreCut() {
        let whole = smf(tracks: [track([(0, .tempo(500_000))]), track([(0, .on(0, 60, 80)), (480, .off(0, 60))])])
        for cut in [1, 3, 8, 12, 30] {
            let truncated = whole.prefix(whole.count - cut)
            #expect(throws: MIDIImportError.damaged, "cut \(cut) bytes") { try decode(Data(truncated)) }
        }
        let missingTrack = smf(tracks: [track([(0, .on(0, 60, 80)), (480, .off(0, 60))])]).prefix(14 + 8 + 2)
        #expect(throws: MIDIImportError.damaged) { try decode(Data(missingTrack)) }

        var lyingCount = Array(simpleFile)
        lyingCount[11] = 3
        #expect(throws: MIDIImportError.damaged) { try decode(Data(lyingCount)) }
    }

    @Test func importCopiesTheOriginalBytesUnderAUniqueName() throws {
        let source = try scratchFolder().appending(path: "Bassline Sketch.mid")
        try simpleFile.write(to: source)
        let folder = try scratchFolder()

        let first = try MIDIImporter.importFile(from: source, into: folder)
        let second = try MIDIImporter.importFile(from: source, into: folder)
        #expect(first.lastPathComponent == "Bassline Sketch.mid")
        #expect(second.lastPathComponent == "Bassline Sketch 2.mid")
        #expect(try Data(contentsOf: first) == simpleFile)
        #expect(try Data(contentsOf: second) == simpleFile)
        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    @Test func aDamagedFileCreatesNothingInTheFolder() throws {
        let whole = smf(tracks: [track([(0, .on(0, 60, 80)), (480, .off(0, 60))])])
        let source = try scratchFolder().appending(path: "broken.mid")
        try Data(whole.dropLast(6)).write(to: source)
        let folder = try scratchFolder()

        #expect(throws: MIDIImportError.damaged) { try MIDIImporter.importFile(from: source, into: folder) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)

        let missing = folder.appending(path: "nothing.mid")
        #expect(throws: MIDIImportError.readFailed("nothing.mid")) { try MIDIImporter.importFile(from: missing, into: folder) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
    }

    @MainActor
    @Test func aDocumentStartsEditedOnlyWhenTheFileSaysSo() throws {
        let plain = try decode(simpleFile)
        #expect(!MIDIDocument(sourceName: "plain.mid", imported: plain).isEdited)

        let marked = smf(tracks: [track([(0, .text(MIDIProvenance(modelID: "basic-pitch", edited: true).text)), (0, .on(0, 60, 80)), (480, .off(0, 60))])])
        let document = MIDIDocument(sourceName: "marked.mid", imported: try decode(marked))
        #expect(document.isEdited && !document.isDirty)
        #expect(document.notes.count == 1 && document.sourceName == "marked.mid")
    }

    @Test func exactClassNamesBeatSubstringsWhenColouringTracks() {
        #expect(InstrumentFamily.id(for: "bassoon") == "winds")
        #expect(InstrumentFamily.id(for: "contrabass") == "strings")
        #expect(InstrumentFamily.id(for: "acoustic_bass") == "bass")
        #expect(InstrumentFamily.id(for: "acoustic_piano") == "keys")
        #expect(InstrumentFamily.id(for: "drums") == "drums")
        #expect(InstrumentFamily.id(for: "theremin") == "all")
    }
}

@MainActor
struct LibraryMIDIMetadataTests {
    private func library(midi: URL) -> LibraryStore {
        let imports = AudioImportStore(storage: MemoryBookmarks(), codec: PlainCodec(), access: NoAccess())
        let library = LibraryStore(imports: imports, watcher: NoWatcher())
        let audio = midi.deletingLastPathComponent().appending(path: "Audio", directoryHint: .isDirectory)
        library.attach(audio: audio, midi: midi)
        return library
    }

    @Test func listsTracksOriginsAndUnreadableFiles() throws {
        let folder = try scratchFolder()
        let multi = smf(tracks: [
            track([(0, .tempo(500_000))]),
            track([(0, .program(0, 33)), (0, .on(0, 40, 80)), (480, .off(0, 40)), (0, .on(9, 36, 100)), (240, .off(9, 36))]),
        ])
        try multi.write(to: folder.appending(path: "Imported.mid"))

        var fromAudio = MIDIExportOptions()
        fromAudio.provenance = MIDIProvenance(source: "take.wav", modelID: "basic-pitch")
        let note = NoteEvent(onset: 0, offset: 1, pitch: 60, program: 0, isDrum: false, instrument: "piano", velocity: 90, pitchBends: nil)
        try MIDIBuilder.build(notes: [note], options: fromAudio).write(to: folder.appending(path: "Transcribed.mid"))
        var edited = fromAudio
        edited.provenance?.edited = true
        try MIDIBuilder.build(notes: [note, note], options: edited).write(to: folder.appending(path: "Tweaked.mid"))
        try Data("not midi".utf8).write(to: folder.appending(path: "Broken.mid"))

        let entries = Dictionary(uniqueKeysWithValues: library(midi: folder).midi.map { ($0.name, $0.midiInfo) })
        let imported = try #require(entries["Imported"] ?? nil)
        #expect(imported.noteCount == 2 && imported.origin == .imported)
        #expect(imported.trackNames == ["drums", "bass"])
        #expect(try #require(entries["Transcribed"] ?? nil).origin == .fromAudio)
        #expect(try #require(entries["Tweaked"] ?? nil).origin == .edited)
        #expect(entries["Broken"] != nil && entries["Broken"]! == nil)
    }

    @Test func infoIsRereadWhenAFileChanges() throws {
        let folder = try scratchFolder()
        let file = folder.appending(path: "Take.mid")
        try simpleFile.write(to: file)
        let library = library(midi: folder)
        #expect(library.midi.first?.midiInfo?.noteCount == 1)

        let two = smf(tracks: [track([(0, .on(0, 60, 80)), (240, .off(0, 60)), (240, .on(0, 62, 80)), (480, .off(0, 62))])])
        try two.write(to: file)
        library.refresh()
        #expect(library.midi.first?.midiInfo?.noteCount == 2)
    }

    @Test func sidebarSummaryReadsLikeThePrototype() {
        #expect(LibrarySidebarView.summary(MIDIFileInfo(noteCount: 48, trackNames: [], duration: 1, provenance: nil)) == "48 notes · Imported")
        #expect(LibrarySidebarView.summary(MIDIFileInfo(noteCount: 1, trackNames: [], duration: 1, provenance: MIDIProvenance())) == "1 note · From audio")
        #expect(LibrarySidebarView.summary(MIDIFileInfo(noteCount: 3, trackNames: [], duration: 1, provenance: MIDIProvenance(edited: true))) == "3 notes · Edited")
        #expect(LibrarySidebarView.summary(nil) == "Can\u{2019}t be read")
    }

    @Test func sidebarSummaryNamesTheModelNeverItsID() {
        func summary(_ count: Int, _ provenance: MIDIProvenance) -> String {
            LibrarySidebarView.summary(MIDIFileInfo(noteCount: count, trackNames: [], duration: 1, provenance: provenance))
        }
        #expect(summary(12, MIDIProvenance(modelID: "muscriptor-large", version: 2)) == "MuScriptor Large · 12 notes")
        #expect(summary(1, MIDIProvenance(modelID: "basic-pitch", partial: true)) == "Basic Pitch · 1 note · Partial")
        #expect(summary(3, MIDIProvenance(modelID: "piano-onnx", edited: true)) == "Piano (ONNX) · 3 notes · Edited")
        #expect(summary(2, MIDIProvenance(modelID: "retired-model")) == "Unknown model · 2 notes")
    }
}
