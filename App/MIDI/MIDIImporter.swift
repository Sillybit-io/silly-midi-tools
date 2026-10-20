import Foundation
import SwiftMIDICore
import SwiftMIDIFile

enum MIDIImportError: LocalizedError, Equatable {
    case notMIDI
    case smpteTiming
    case unsupportedType2
    case damaged
    case noNotes
    case readFailed(String)
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .notMIDI: "This isn't a Standard MIDI File."
        case .smpteTiming: "SMPTE-timed MIDI files aren't supported."
        case .unsupportedType2: "Type 2 MIDI files aren't supported."
        case .damaged: "The file is damaged."
        case .noNotes: "No notes found in the playable range."
        case .readFailed(let name): "Couldn\u{2019}t read \u{201C}\(name)\u{201D}."
        case .writeFailed(let name): "Couldn\u{2019}t save a copy of \u{201C}\(name)\u{201D} in the MIDI folder."
        }
    }
}

/// What the library shows about a MIDI file without opening the editor.
struct MIDIFileInfo: Equatable, Hashable, Sendable {
    enum Origin: Sendable {
        case fromAudio, edited, imported

        var title: String {
            switch self {
            case .fromAudio: "From audio"
            case .edited: "Edited"
            case .imported: "Imported"
            }
        }
    }

    var noteCount: Int
    var trackNames: [String]
    var duration: Double
    var provenance: MIDIProvenance?

    var origin: Origin {
        guard let provenance else { return .imported }
        return provenance.edited ? .edited : .fromAudio
    }
}

struct ImportedMIDI: Sendable {
    var tracks: [MIDITrack]
    var notes: [EditorNote]
    var grid: MIDIGrid
    /// Notes outside C1–B6.
    var skippedNotes: Int
    var provenance: MIDIProvenance?

    var info: MIDIFileInfo {
        MIDIFileInfo(noteCount: notes.count, trackNames: tracks.map(\.name), duration: notes.map(\.end).max() ?? 0, provenance: provenance)
    }
}

extension MIDIDocument {
    convenience init(sourceName: String, imported: ImportedMIDI) {
        self.init(sourceName: sourceName, tracks: imported.tracks, notes: imported.notes, grid: imported.grid,
                  isEdited: imported.provenance?.edited ?? false, skippedNotes: imported.skippedNotes)
    }
}

/// Reads Standard MIDI Files, type 0 or 1 with PPQ timing, into editor notes placed in seconds.
enum MIDIImporter {
    private struct Header {
        var format: Int
        var trackCount: Int
        var ticksPerQuarter: Int
    }

    private struct OpenNote {
        var tick: Int
        var velocity: Int
        var program: Int?
    }

    private struct RawNote {
        var channel: Int
        var pitch: Int
        var start: Int
        var end: Int
        var velocity: Int
        var program: Int?
    }

    /// Decodes the whole file. Nothing is returned for a file that is not completely valid.
    static func decode(_ data: Data) throws -> ImportedMIDI {
        let header = try validate(data)
        let file: AnyMIDI1File
        do {
            file = try AnyMIDI1File(data: data)
        } catch {
            throw MIDIImportError.damaged
        }
        guard case .musical(let musical) = file else { throw MIDIImportError.smpteTiming }

        var tempos: [(tick: Int, microseconds: Double)] = []
        var meters: [(tick: Int, numerator: Int, denominator: Int)] = []
        var raw: [RawNote] = []
        var provenance: MIDIProvenance?
        for track in musical.tracks {
            var tick = 0
            var programs: [Int: Int] = [:]
            var open: [Int: [OpenNote]] = [:]
            func close(_ channel: Int, _ pitch: Int, at end: Int) {
                let key = channel * 128 + pitch
                guard let note = open[key]?.first else { return }
                open[key]?.removeFirst()
                raw.append(RawNote(channel: channel, pitch: pitch, start: note.tick, end: end, velocity: note.velocity, program: note.program))
            }
            for event in track.events {
                tick += Int(event.delta.ticks(using: musical.timebase))
                switch event.event {
                case .noteOn(let on):
                    let channel = on.channel.intValue, pitch = on.note.number.intValue, velocity = velocity(on.velocity)
                    if velocity > 0 {
                        open[channel * 128 + pitch, default: []].append(OpenNote(tick: tick, velocity: velocity, program: programs[channel]))
                    } else {
                        close(channel, pitch, at: tick)
                    }
                case .noteOff(let off):
                    close(off.channel.intValue, off.note.number.intValue, at: tick)
                case .programChange(let change):
                    programs[change.channel.intValue] = change.program.intValue
                case .tempo(let tempo):
                    tempos.append((tick, Double(tempo.microsecondsPerQuarter)))
                case .timeSignature(let meter):
                    let power = Int(meter.denominator)
                    meters.append((tick, Int(meter.numerator), power <= 5 ? 1 << power : 4))
                case .text(let text):
                    if provenance == nil { provenance = MIDIProvenance(text: text.text) }
                default:
                    break
                }
            }
            for (key, notes) in open {
                for _ in notes { close(key / 128, key % 128, at: tick) }
            }
        }

        let clock = TempoClock(tempos: tempos, ticksPerQuarter: header.ticksPerQuarter)
        var skipped = 0
        var timed: [(note: RawNote, start: Double, end: Double)] = []
        for note in raw {
            guard MIDIEditing.pitchRange.contains(note.pitch) else { skipped += 1; continue }
            timed.append((note, clock.seconds(at: note.start), clock.seconds(at: note.end)))
        }
        guard !timed.isEmpty else { throw MIDIImportError.noNotes }
        timed.sort { ($0.start, $0.note.pitch, $0.note.channel) < ($1.start, $1.note.pitch, $1.note.channel) }

        var tracks: [MIDITrack] = []
        var notes: [EditorNote] = []
        for (index, item) in timed.enumerated() {
            let name = instrument(program: item.note.program, channel: item.note.channel)
            if !tracks.contains(where: { $0.id == name }) {
                tracks.append(MIDITrack(id: name, name: name.replacingOccurrences(of: "_", with: " "),
                                          program: name == "drums" ? 0 : item.note.program ?? 0, isDrums: name == "drums"))
            }
            notes.append(EditorNote(id: index + 1, track: name, pitch: item.note.pitch, start: item.start,
                                    duration: max(MIDIEditing.minimumDuration, item.end - item.start),
                                    velocity: MIDIEditing.clampedVelocity(item.note.velocity)))
        }
        let bpm = tempos.min { $0.tick < $1.tick }.map { 60_000_000 / $0.microseconds } ?? 120
        var grid = MIDIGrid(bpm: bpm, numerator: 4, denominator: 4)
        for meter in meters.enumerated().sorted(by: { ($0.element.tick, $0.offset) < ($1.element.tick, $1.offset) }).map(\.element) {
            let seconds = clock.seconds(at: meter.tick)
            let segment = grid.segment(atSeconds: seconds)
            let bar = max(0, segment.bar + Int(((seconds - segment.startSeconds) / segment.secondsPerBar).rounded()))
            grid = MIDIGrid(bpm: bpm, meters: grid.meters.filter { $0.bar < bar }
                + [MeterChange(bar: bar, numerator: meter.numerator, denominator: meter.denominator)])
        }
        return ImportedMIDI(tracks: tracks, notes: notes, grid: grid,
                            skippedNotes: skipped, provenance: provenance)
    }

    /// Checks the header and every chunk length before any event is read, so a truncated file never half-imports.
    private static func validate(_ data: Data) throws -> Header {
        let bytes = [UInt8](data)
        guard bytes.count >= 4, Array(bytes[0..<4]) == Array("MThd".utf8) else { throw MIDIImportError.notMIDI }
        func u16(_ at: Int) -> Int { Int(bytes[at]) << 8 | Int(bytes[at + 1]) }
        func u32(_ at: Int) -> Int { u16(at) << 16 | u16(at + 2) }
        guard bytes.count >= 14 else { throw MIDIImportError.damaged }
        let headerLength = u32(4)
        guard headerLength >= 6, 8 + headerLength <= bytes.count else { throw MIDIImportError.damaged }
        let format = u16(8), trackCount = u16(10), division = u16(12)
        guard format <= 2, trackCount > 0 else { throw MIDIImportError.damaged }
        if division & 0x8000 != 0 { throw MIDIImportError.smpteTiming }
        guard division > 0 else { throw MIDIImportError.damaged }
        if format == 2 { throw MIDIImportError.unsupportedType2 }

        var offset = 8 + headerLength
        var found = 0
        while found < trackCount {
            guard offset + 8 <= bytes.count else { throw MIDIImportError.damaged }
            let length = u32(offset + 4)
            guard offset + 8 + length <= bytes.count else { throw MIDIImportError.damaged }
            if Array(bytes[offset..<offset + 4]) == Array("MTrk".utf8) { found += 1 }
            offset += 8 + length
        }
        return Header(format: format, trackCount: trackCount, ticksPerQuarter: division)
    }

    private static func velocity(_ value: MIDIEvent.NoteVelocity) -> Int {
        switch value {
        case .midi1(let v): v.intValue
        case .midi2(let v): Int(v >> 9)
        case .unitInterval(let v): Int((v * 127).rounded())
        }
    }

    /// The editor track a note lands on, from channel 10 and the General MIDI program in effect when it starts.
    static func instrument(program: Int?, channel: Int) -> String {
        if channel == 9 { return "drums" }
        guard let program else { return "piano" }
        let fixed = [40: "violin", 41: "viola", 42: "cello", 43: "contrabass", 46: "harp", 47: "timpani",
                     56: "trumpet", 57: "trombone", 58: "tuba", 60: "french", 68: "oboe", 69: "english", 70: "bassoon", 71: "clarinet"]
        if let name = fixed[program] { return name }
        if program < 8 { return "piano" }
        if program < 16 { return "chromatic" }
        if program < 24 { return "organ" }
        if program < 32 { return "guitar" }
        if program < 40 { return "bass" }
        if (52...54).contains(program) { return "voice" }
        if program < 56 { return "string" }
        if program < 64 { return "brass" }
        if program < 68 { return "sax" }
        if program < 80 { return "flute" }
        if program < 104 { return "synth" }
        return "piano"
    }

    /// Checks a file, then keeps a copy of its original bytes in `folder` under a name that doesn't exist yet.
    /// A file that fails validation leaves the folder untouched.
    static func importFile(from source: URL, into folder: URL, fileManager: FileManager = .default) throws -> URL {
        let name = source.lastPathComponent
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let data: Data
        do {
            data = try Data(contentsOf: source)
        } catch {
            throw MIDIImportError.readFailed(name)
        }
        _ = try decode(data)
        let destination = LibraryNaming.uniqueURL(base: source.deletingPathExtension().lastPathComponent, ext: "mid", in: folder, fileManager: fileManager)
        let staging = folder.appending(path: ".import-\(UUID().uuidString).tmp", directoryHint: .notDirectory)
        do {
            try data.write(to: staging)
            try fileManager.moveItem(at: staging, to: destination)
        } catch {
            try? fileManager.removeItem(at: staging)
            throw MIDIImportError.writeFailed(name)
        }
        return destination
    }

    /// Reads a library file's summary. Nil when the file can't be imported.
    static func info(at url: URL) -> MIDIFileInfo? {
        (try? Data(contentsOf: url)).flatMap { try? decode($0).info }
    }
}

/// Converts ticks to seconds across a file's tempo changes.
struct TempoClock {
    private let segments: [(tick: Int, seconds: Double, microseconds: Double)]
    private let ticksPerQuarter: Double

    init(tempos: [(tick: Int, microseconds: Double)], ticksPerQuarter: Int) {
        let ppq = Double(ticksPerQuarter)
        var ordered: [(tick: Int, microseconds: Double)] = []
        for tempo in tempos.enumerated().sorted(by: { ($0.element.tick, $0.offset) < ($1.element.tick, $1.offset) }).map(\.element) {
            if let last = ordered.last, last.tick == tempo.tick { ordered.removeLast() }
            ordered.append(tempo)
        }
        if ordered.first?.tick != 0 { ordered.insert((0, 500_000), at: 0) }
        var segments: [(tick: Int, seconds: Double, microseconds: Double)] = []
        for tempo in ordered {
            let seconds = segments.last.map { $0.seconds + Double(tempo.tick - $0.tick) * $0.microseconds / ppq / 1e6 } ?? 0
            segments.append((tempo.tick, seconds, tempo.microseconds))
        }
        self.segments = segments
        self.ticksPerQuarter = ppq
    }

    func seconds(at tick: Int) -> Double {
        let segment = segments.last { $0.tick <= tick } ?? segments[0]
        return segment.seconds + Double(tick - segment.tick) * segment.microseconds / ticksPerQuarter / 1e6
    }
}
