import Foundation
import SwiftMIDICore
import SwiftMIDIFile

struct MIDIExportOptions: Sendable {
    var title = "Silly MIDI Tools"
    /// Notes are relative to the slice start; this is the slice's own start in the source audio.
    var sliceStart = 0.0
    /// Slice length in seconds; notes running past it are clipped.
    var sliceLength: Double?
    var relativeTimeline = true
    var grid: MIDIGrid = .standard
    var defaultVelocity = 100
    var copyright: String?
    /// A plain text event on the conductor track, such as where the file came from.
    var comment: String?
    /// Adds an `smt:` text event to the conductor track. Left nil, the file is exactly what it was before.
    var provenance: MIDIProvenance?
    /// Pitch bends bend the whole channel and assume a ±2 semitone bend range, so a file for another app can leave them out.
    var includesPitchBends = true
}

enum MIDIBuilder {
    static let ticksPerQuarter: UInt16 = 480
    static let drumChannel = 9

    private enum Kind: Int { case programChange, noteOff, pitchBend, noteOn }

    private struct Timed {
        var tick: Int
        var kind: Kind
        var make: (MusicalMIDI1File.Track.DeltaTime) -> MusicalMIDI1File.Track.Event
    }

    static func ascii(_ text: String) -> String {
        String(text.unicodeScalars.map { $0.isASCII ? Character($0) : "?" })
    }

    static func tick(_ seconds: Double, bpm: Double = 120) -> Int { max(0, Int((seconds * Double(ticksPerQuarter) * bpm / 60).rounded())) }

    static func channels(for groups: [String], drums: Set<String>) -> [String: Int] {
        var map: [String: Int] = [:]
        var next = 0
        for name in groups {
            if drums.contains(name) { map[name] = drumChannel; continue }
            if next == drumChannel { next += 1 }
            map[name] = next % 16
            next += 1
            if next % 16 == drumChannel { next += 1 }
        }
        return map
    }

    static func build(notes: [NoteEvent], options: MIDIExportOptions = MIDIExportOptions()) throws -> Data {
        let offset = options.relativeTimeline ? 0 : options.sliceStart
        let limit = options.sliceLength

        var conductor: [MusicalMIDI1File.Track.Event] = [
            .text(type: .trackOrSequenceName, string: ascii(options.title)),
            .tempo(bpm: options.grid.bpm),
        ]
        let meters = options.grid.timeSignatureEvents
        conductor.append(.timeSignature(numerator: UInt8(meters[0].numerator), denominator: UInt8(meters[0].denominatorPower)))
        if let copyright = options.copyright, !copyright.isEmpty {
            conductor.append(.text(type: .copyright, string: ascii(copyright)))
        }
        if let comment = options.comment, !comment.isEmpty {
            conductor.append(.text(type: .text, string: ascii(comment)))
        }
        if let provenance = options.provenance {
            conductor.append(.text(type: .text, string: provenance.text))
        }
        var previousMeterTick = 0
        for meter in meters.dropFirst() {
            conductor.append(.timeSignature(delta: .ticks(UInt32(meter.tick - previousMeterTick)),
                                            numerator: UInt8(meter.numerator), denominator: UInt8(meter.denominatorPower)))
            previousMeterTick = meter.tick
        }

        let grouped = Dictionary(grouping: notes) { $0.isDrum ? "drums" : $0.instrument }
        let names = grouped.keys.sorted()
        let channelMap = channels(for: names, drums: ["drums"])

        var tracks = [MusicalMIDI1File.Track(events: conductor)]
        for name in names {
            let channel = channelMap[name] ?? 0
            let group = grouped[name] ?? []
            var timed: [Timed] = []
            let program = UInt7(UInt8(clamping: min(max(group.first?.program ?? 0, 0), 127)))
            let ch = UInt4(UInt8(channel))
            timed.append(Timed(tick: 0, kind: .programChange) { .programChange(delta: $0, program: program, channel: ch) })

            for note in group {
                var end = note.offset
                if let limit { end = min(end, limit) }
                if let limit, note.onset >= limit { continue }
                guard end > note.onset else { continue }
                let start = tick(note.onset + offset, bpm: options.grid.bpm)
                let stop = max(start + 1, tick(end + offset, bpm: options.grid.bpm))
                let key = UInt7(UInt8(clamping: min(max(note.pitch, 0), 127)))
                let velocity = UInt7(UInt8(clamping: min(max(note.velocity ?? options.defaultVelocity, 1), 127)))
                timed.append(Timed(tick: start, kind: .noteOn) { .noteOn(delta: $0, note: key, velocity: .midi1(velocity), channel: ch) })
                timed.append(Timed(tick: stop, kind: .noteOff) { .noteOff(delta: $0, note: key, velocity: .midi1(0), channel: ch) })

                if options.includesPitchBends, let bends = note.pitchBends, !bends.isEmpty {
                    for (i, bend) in bends.enumerated() {
                        let fraction = bends.count > 1 ? Double(i) / Double(bends.count - 1) : 0
                        let at = tick(note.onset + (end - note.onset) * fraction + offset, bpm: options.grid.bpm)
                        timed.append(bendEvent(tick: min(at, stop), units: bend, channel: ch))
                    }
                    timed.append(Timed(tick: stop, kind: .pitchBend) { delta in
                        .pitchBend(delta: delta, lsb: 0x00, msb: 0x40, channel: ch)
                    })
                }
            }

            timed.sort { ($0.tick, $0.kind.rawValue) < ($1.tick, $1.kind.rawValue) }
            var events: [MusicalMIDI1File.Track.Event] = [.text(type: .trackOrSequenceName, string: ascii(name))]
            var last = 0
            for item in timed {
                events.append(item.make(.ticks(UInt32(item.tick - last))))
                last = item.tick
            }
            tracks.append(MusicalMIDI1File.Track(events: events))
        }

        let file = MusicalMIDI1File(format: .multipleTracksSynchronous, timebase: .musical(ticksPerQuarterNote: ticksPerQuarter), tracks: tracks)
        return try file.rawData()
    }

    private static func bendEvent(tick: Int, units: Int, channel: UInt4) -> Timed {
        let ticks = min(8191, max(-8192, Int((Double(units) * 4096 / 3).rounded())))
        let value = UInt16(ticks + 8192)
        let lsb = UInt8(value & 0x7F)
        let msb = UInt8(value >> 7)
        return Timed(tick: tick, kind: .pitchBend) { delta in .pitchBend(delta: delta, lsb: lsb, msb: msb, channel: channel) }
    }
}
