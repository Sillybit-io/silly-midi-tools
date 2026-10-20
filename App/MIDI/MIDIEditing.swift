import CoreGraphics
import Foundation

/// Fractions of a quarter note; the actual duration comes from the document tempo.
enum SnapGrid: Double, CaseIterable, Identifiable, Sendable {
    case quarter = 1
    case eighth = 0.5
    case sixteenth = 0.25
    case thirtySecond = 0.125
    case off = 0

    var id: Double { rawValue }
    func step(quarter: Double) -> Double { rawValue * quarter }

    var title: String {
        switch self {
        case .quarter: "1/4 note"
        case .eighth: "1/8 note"
        case .sixteenth: "1/16 note"
        case .thirtySecond: "1/32 note"
        case .off: "Off"
        }
    }
}

enum MIDIHit: Equatable, Sendable {
    case body(Int)
    case resizeEdge(Int)

    var id: Int {
        switch self {
        case .body(let id), .resizeEdge(let id): id
        }
    }
}

/// Pure edits on note values. Each returns the new notes, or nil when the edit is rejected or would change nothing,
/// so a caller can tell a real change from a no-op without comparing arrays.
enum MIDIEditing {
    /// C1 to B6.
    static let pitchRange = 24...95
    static let velocityRange = 1...127
    static let defaultVelocity = 100
    @available(*, deprecated, message: "RollDrawing uses this until its grid migration")
    static let secondsPerBar = 2.0
    /// The shortest note when the grid is off.
    static let minimumDuration = 0.03
    static let resizeEdgeWidth: CGFloat = 6

    static func snap(_ seconds: Double, to grid: SnapGrid, quarter: Double = 0.5) -> Double {
        let step = grid.step(quarter: quarter)
        return grid == .off ? seconds : (seconds / step).rounded() * step
    }

    static func snapFloor(_ seconds: Double, to grid: SnapGrid, quarter: Double = 0.5) -> Double {
        let step = grid.step(quarter: quarter)
        return grid == .off ? seconds : (seconds / step).rounded(.down) * step
    }

    static func minimumLength(on grid: SnapGrid, quarter: Double = 0.5) -> Double {
        grid == .off ? minimumDuration : grid.step(quarter: quarter)
    }

    static func clampedVelocity(_ value: Int) -> Int {
        min(max(value, velocityRange.lowerBound), velocityRange.upperBound)
    }

    /// A new note at `time` floored to the grid. Rejected outside C1–B6 or before time zero.
    static func draw(at time: Double, pitch: Int, track: String, id: Int, grid: SnapGrid, length: Double? = nil,
                     quarter: Double = 0.5) -> EditorNote? {
        guard time.isFinite, time >= 0, pitchRange.contains(pitch) else { return nil }
        let duration: Double
        if let length, length.isFinite {
            duration = max(minimumLength(on: grid, quarter: quarter), snap(length, to: grid, quarter: quarter))
        } else {
            duration = grid == .off ? 0.25 : grid.step(quarter: quarter)
        }
        return EditorNote(id: id, track: track, pitch: pitch, start: snapFloor(time, to: grid, quarter: quarter), duration: duration,
                          velocity: defaultVelocity)
    }

    static func erase(_ notes: [EditorNote], ids: Set<Int>) -> [EditorNote]? {
        guard notes.contains(where: { ids.contains($0.id) }) else { return nil }
        return notes.filter { !ids.contains($0.id) }
    }

    /// Moves the group by whole grid steps. The group stops at time zero and at C1/B6 instead of bending its shape.
    static func move(_ notes: [EditorNote], ids: Set<Int>, deltaTime: Double, deltaPitch: Int, grid: SnapGrid,
                     quarter: Double = 0.5) -> [EditorNote]? {
        let moving = notes.filter { ids.contains($0.id) }
        guard let earliest = moving.map(\.start).min(), let lowest = moving.map(\.pitch).min(),
              let highest = moving.map(\.pitch).max(), deltaTime.isFinite else { return nil }
        let time = max(snap(deltaTime, to: grid, quarter: quarter), -earliest)
        let semitones = min(max(deltaPitch, pitchRange.lowerBound - lowest), pitchRange.upperBound - highest)
        guard time != 0 || semitones != 0 else { return nil }
        return notes.map { note in
            guard ids.contains(note.id) else { return note }
            var moved = note
            moved.start += time
            moved.pitch += semitones
            return moved
        }
    }

    static func transpose(_ notes: [EditorNote], ids: Set<Int>, by semitones: Int) -> [EditorNote]? {
        move(notes, ids: ids, deltaTime: 0, deltaPitch: semitones, grid: .off)
    }

    /// Shifts by `steps` grid steps (an eighth of a second when the grid is off).
    static func nudge(_ notes: [EditorNote], ids: Set<Int>, steps: Int, grid: SnapGrid, quarter: Double = 0.5) -> [EditorNote]? {
        let step = grid == .off ? 0.125 : grid.step(quarter: quarter)
        return move(notes, ids: ids, deltaTime: Double(steps) * step, deltaPitch: 0, grid: .off)
    }

    /// Changes each note's length by `delta`, snapped, never below the shortest note the grid allows.
    static func resize(_ notes: [EditorNote], ids: Set<Int>, delta: Double, grid: SnapGrid, quarter: Double = 0.5) -> [EditorNote]? {
        guard delta.isFinite else { return nil }
        let floor = minimumLength(on: grid, quarter: quarter)
        var changed = false
        let result = notes.map { note in
            guard ids.contains(note.id) else { return note }
            var resized = note
            resized.duration = max(floor, snap(note.duration + delta, to: grid, quarter: quarter))
            if resized.duration != note.duration { changed = true }
            return resized
        }
        return changed ? result : nil
    }

    /// Snaps starts and ends to the grid. `ids` nil means every note.
    static func quantize(_ notes: [EditorNote], ids: Set<Int>?, grid: SnapGrid, quarter: Double = 0.5) -> [EditorNote]? {
        guard grid != .off else { return nil }
        var changed = false
        let result = notes.map { note in
            guard ids?.contains(note.id) ?? true else { return note }
            var quantized = note
            let end = snap(note.end, to: grid, quarter: quarter)
            quantized.start = snap(note.start, to: grid, quarter: quarter)
            quantized.duration = max(grid.step(quarter: quarter), end - quantized.start)
            if quantized != note { changed = true }
            return quantized
        }
        return changed ? result : nil
    }

    static func setVelocity(_ notes: [EditorNote], ids: Set<Int>, to value: Int) -> [EditorNote]? {
        let velocity = clampedVelocity(value)
        var changed = false
        let result = notes.map { note in
            guard ids.contains(note.id), note.velocity != velocity else { return note }
            var painted = note
            painted.velocity = velocity
            changed = true
            return painted
        }
        return changed ? result : nil
    }

    /// Sets one note's start and length to typed values. Neither is snapped; the start can't go below zero and the
    /// length can't go below the shortest note.
    static func setTiming(_ notes: [EditorNote], id: Int, start: Double?, duration: Double?) -> [EditorNote]? {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return nil }
        var note = notes[index]
        if let start {
            guard start.isFinite else { return nil }
            note.start = max(0, start)
        }
        if let duration {
            guard duration.isFinite else { return nil }
            note.duration = max(minimumDuration, duration)
        }
        guard note != notes[index] else { return nil }
        var result = notes
        result[index] = note
        return result
    }

    /// Gives each listed note its own velocity, for a paint stroke that changes value along the way.
    static func setVelocities(_ notes: [EditorNote], values: [Int: Int]) -> [EditorNote]? {
        var changed = false
        let result = notes.map { note in
            guard let value = values[note.id], clampedVelocity(value) != note.velocity else { return note }
            var painted = note
            painted.velocity = clampedVelocity(value)
            changed = true
            return painted
        }
        return changed ? result : nil
    }

    /// Sets the velocity of every visible note that starts inside the painted time span.
    static func paintVelocity(_ notes: [EditorNote], from: Double, to: Double, value: Int, hiddenTracks: Set<String>) -> [EditorNote]? {
        let span = min(from, to)...max(from, to)
        let ids = Set(notes.filter { span.contains($0.start) && !hiddenTracks.contains($0.track) }.map(\.id))
        return setVelocity(notes, ids: ids, to: value)
    }

    /// Visible notes that overlap the rectangle in time and pitch.
    static func notes(inTime time: ClosedRange<Double>, pitches: ClosedRange<Int>, among notes: [EditorNote], hiddenTracks: Set<String>) -> Set<Int> {
        Set(notes.filter { note in
            !hiddenTracks.contains(note.track) && pitches.contains(note.pitch)
                && note.start < time.upperBound && note.end > time.lowerBound
        }.map(\.id))
    }

    static func rect(of note: EditorNote, in layout: PianoRollLayout) -> CGRect {
        layout.rect(for: NoteEvent(onset: note.start, offset: note.end, pitch: note.pitch, program: 0, isDrum: false,
                                   instrument: note.track, velocity: note.velocity, pitchBends: nil))
    }

    /// The topmost visible note under `point`, and whether the point is on its right-edge resize handle.
    /// `point` is in the layout's space: x as drawn, y from the top of the C1–B6 grid.
    static func hit(at point: CGPoint, notes: [EditorNote], layout: PianoRollLayout, hiddenTracks: Set<String>) -> MIDIHit? {
        for note in notes.reversed() where !hiddenTracks.contains(note.track) {
            let rect = rect(of: note, in: layout)
            guard rect.contains(point) else { continue }
            let edge = min(resizeEdgeWidth, rect.width / 2)
            return point.x >= rect.maxX - edge ? .resizeEdge(note.id) : .body(note.id)
        }
        return nil
    }

    /// The pitch of the grid row at `y`, measured from the top of the grid. May lie outside C1–B6.
    static func pitch(atGridY y: CGFloat) -> Int {
        pitchRange.upperBound - Int((y / Metric.rowH).rounded(.down))
    }

    /// Whole semitones for a vertical drag; dragging up raises the pitch.
    static func semitones(forDragY dy: CGFloat) -> Int {
        -Int((dy / Metric.rowH).rounded())
    }

    /// The time and pitch ranges a marquee between two points covers.
    static func marquee(from a: CGPoint, to b: CGPoint, layout: PianoRollLayout) -> (time: ClosedRange<Double>, pitches: ClosedRange<Int>) {
        let time = layout.seconds(atX: min(a.x, b.x))...layout.seconds(atX: max(a.x, b.x))
        let pitches = pitch(atGridY: max(a.y, b.y))...pitch(atGridY: min(a.y, b.y))
        return (time, pitches)
    }

    /// A drawn note starts one grid step long (a quarter second with the grid off); dragging right lengthens it.
    static func drawLength(dragSeconds: Double, grid: SnapGrid, quarter: Double = 0.5) -> Double {
        let base = grid == .off ? 0.25 : grid.step(quarter: quarter)
        return max(minimumLength(on: grid, quarter: quarter), snap(base + dragSeconds, to: grid, quarter: quarter))
    }
}
