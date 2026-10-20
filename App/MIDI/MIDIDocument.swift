import Foundation
import Observation

struct EditorNote: Identifiable, Equatable, Sendable {
    let id: Int
    var track: String
    var pitch: Int
    var start: Double
    var duration: Double
    var velocity: Int

    var end: Double { start + duration }
}

struct MIDITrack: Identifiable, Equatable, Sendable {
    let id: String
    var name: String
    var program: Int
    var isDrums: Bool

    /// Every instrument class a new track can be drawn on: the MuScriptor classes, grouped by family.
    static let classes: [String] = InstrumentFamily.all.flatMap(\.keys)

    /// A new, empty track for an instrument class, with the General MIDI program that maps back to it on import.
    static func newTrack(forClass id: String) -> MIDITrack? {
        guard classes.contains(id) else { return nil }
        let programs = ["piano": 0, "chromatic": 8, "organ": 16, "guitar": 24, "bass": 32, "violin": 40, "viola": 41, "cello": 42,
                        "contrabass": 43, "harp": 46, "timpani": 47, "string": 48, "voice": 52, "orchestra": 55, "trumpet": 56,
                        "trombone": 57, "tuba": 58, "french": 60, "brass": 61, "sax": 64, "oboe": 68, "english": 69,
                        "horn_e": 69, "bassoon": 70, "clarinet": 71, "flute": 73, "synth": 80]
        return MIDITrack(id: id, name: id.replacingOccurrences(of: "_", with: " "), program: programs[id] ?? 0, isDrums: id == "drums")
    }
}

@MainActor @Observable
final class MIDIDocument {
    let sourceName: String
    private(set) var grid: MIDIGrid
    /// Notes left out because they sit outside C1–B6.
    let skippedNotes: Int

    private(set) var tracks: [MIDITrack]
    private(set) var notes: [EditorNote]
    private(set) var selection: Set<Int> = []
    private(set) var mutedTracks: Set<String> = []
    private(set) var soloTracks: Set<String> = []
    private(set) var hiddenTracks: Set<String> = []
    /// True once any edit has been applied, and stays true after undo or a save.
    private(set) var isEdited: Bool
    /// Counts applied edits, undos and redos, so a view can refresh what the undo manager can do.
    private(set) var revision = 0
    private(set) var savedNotes: [EditorNote]
    private(set) var savedGrid: MIDIGrid

    var snap: SnapGrid = .sixteenth
    var drawTrackID: String
    @ObservationIgnored var undoManager: UndoManager?
    @ObservationIgnored private var nextID: Int

    init(sourceName: String, tracks: [MIDITrack], notes: [EditorNote], grid: MIDIGrid = .standard,
         isEdited: Bool = false, skippedNotes: Int = 0) {
        self.sourceName = sourceName
        self.tracks = tracks
        self.notes = notes
        self.grid = grid
        self.isEdited = isEdited
        self.skippedNotes = skippedNotes
        savedNotes = notes
        savedGrid = grid
        drawTrackID = tracks.first?.id ?? ""
        nextID = (notes.map(\.id).max() ?? 0) + 1
    }

    /// Builds a document from engine output, one track per instrument. Notes outside C1–B6 are counted, not kept.
    convenience init(sourceName: String, events: [NoteEvent]) {
        var tracks: [MIDITrack] = []
        var notes: [EditorNote] = []
        var skipped = 0
        for event in events {
            guard MIDIEditing.pitchRange.contains(event.pitch) else { skipped += 1; continue }
            if !tracks.contains(where: { $0.id == event.instrument }) {
                tracks.append(MIDITrack(id: event.instrument, name: event.instrument.replacingOccurrences(of: "_", with: " "),
                                        program: event.program, isDrums: event.isDrum))
            }
            notes.append(EditorNote(id: notes.count + 1, track: event.instrument, pitch: event.pitch, start: event.onset,
                                  duration: max(MIDIEditing.minimumDuration, event.offset - event.onset),
                                  velocity: MIDIEditing.clampedVelocity(event.velocity ?? MIDIEditing.defaultVelocity)))
        }
        self.init(sourceName: sourceName, tracks: tracks, notes: notes, skippedNotes: skipped)
    }

    var isDirty: Bool { notes != savedNotes || grid != savedGrid }
    var canUndo: Bool { undoManager?.canUndo ?? false }
    var canRedo: Bool { undoManager?.canRedo ?? false }
    var selectedNotes: [EditorNote] { notes.filter { selection.contains($0.id) } }

    /// The notes as engine events, for playback, key detection and the MIDI builder.
    var noteEvents: [NoteEvent] {
        let byID = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
        return notes.sorted { ($0.start, $0.pitch) < ($1.start, $1.pitch) }.compactMap { note in
            guard let track = byID[note.track] else { return nil }
            return NoteEvent(onset: note.start, offset: note.end, pitch: note.pitch, program: track.program, isDrum: track.isDrums,
                             instrument: track.id, velocity: note.velocity, pitchBends: nil)
        }
    }

    func markSaved() {
        savedNotes = notes
        savedGrid = grid
    }

    // MARK: Selection

    func select(_ id: Int) {
        guard notes.contains(where: { $0.id == id }) else { return }
        selection = [id]
    }

    func toggleSelection(_ id: Int) {
        guard notes.contains(where: { $0.id == id }) else { return }
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }

    /// Selects the next (`+1`) or previous (`-1`) visible note in time order, starting from the current selection, or from
    /// the first or last note when nothing is selected. Stops at the ends. Returns the note now selected.
    @discardableResult
    func selectAdjacent(_ direction: Int) -> EditorNote? {
        let ordered = notes.filter(isVisible).sorted { ($0.start, $0.pitch, $0.id) < ($1.start, $1.pitch, $1.id) }
        guard !ordered.isEmpty else { return nil }
        let current = ordered.firstIndex { selection.contains($0.id) }
        let target: Int
        if let current {
            target = min(max(current + (direction > 0 ? 1 : -1), 0), ordered.count - 1)
        } else {
            target = direction > 0 ? 0 : ordered.count - 1
        }
        selection = [ordered[target].id]
        return ordered[target]
    }

    func selectAll() {
        selection = Set(notes.filter { !hiddenTracks.contains($0.track) }.map(\.id))
    }

    func clearSelection() {
        selection = []
    }

    /// Selects the visible notes overlapping the rectangle, on top of `base` when the marquee is additive.
    func selectNotes(inTime time: ClosedRange<Double>, pitches: ClosedRange<Int>, additiveTo base: Set<Int> = []) {
        selection = base.union(MIDIEditing.notes(inTime: time, pitches: pitches, among: notes, hiddenTracks: hiddenTracks))
    }

    // MARK: Tracks

    func isVisible(_ note: EditorNote) -> Bool {
        !hiddenTracks.contains(note.track)
    }

    func isAudible(_ note: EditorNote) -> Bool {
        isAudible(track: note.track)
    }

    /// Hidden, muted, or not soloed while another track is: silent. None of these touch the notes.
    func isAudible(track id: String) -> Bool {
        !hiddenTracks.contains(id) && !mutedTracks.contains(id) && (soloTracks.isEmpty || soloTracks.contains(id))
    }

    func toggleMute(_ track: String) {
        toggle(track, in: \.mutedTracks)
    }

    func toggleSolo(_ track: String) {
        toggle(track, in: \.soloTracks)
    }

    func toggleHidden(_ track: String) {
        toggle(track, in: \.hiddenTracks)
        let hidden = Set(notes.filter { hiddenTracks.contains($0.track) }.map(\.id))
        selection.subtract(hidden)
    }

    private func toggle(_ track: String, in keyPath: ReferenceWritableKeyPath<MIDIDocument, Set<String>>) {
        if self[keyPath: keyPath].contains(track) {
            self[keyPath: keyPath].remove(track)
        } else {
            self[keyPath: keyPath].insert(track)
        }
    }

    // MARK: Edits

    @discardableResult
    func setGrid(_ value: MIDIGrid, named name: String? = nil) -> Bool {
        let old = State(tracks: tracks, notes: notes, grid: grid)
        let new = State(tracks: tracks, notes: notes, grid: value)
        guard new != old else { return false }
        let action = name ?? (value.meters.count > grid.meters.count ? "Add Meter Change" : "Change Tempo")
        replace(old, with: new, named: action)
        return true
    }

    @discardableResult
    func addMeterChange(atBar bar: Int, numerator: Int, denominator: Int) -> Bool {
        setGrid(MIDIGrid(bpm: grid.bpm, meters: grid.meters + [MeterChange(bar: bar, numerator: numerator, denominator: denominator)]),
                named: "Add Meter Change")
    }

    /// Draws a note on the draw track and selects it. The draw track may be a new instrument class; its track is created
    /// with the first note, in the same undo step. Returns the note's id, or nil when the draw is rejected.
    @discardableResult
    func draw(at time: Double, pitch: Int, length: Double? = nil) -> Int? {
        let existing = tracks.contains { $0.id == drawTrackID }
        let added = existing ? nil : MIDITrack.newTrack(forClass: drawTrackID)
        guard existing || added != nil, !hiddenTracks.contains(drawTrackID),
               let note = MIDIEditing.draw(at: time, pitch: pitch, track: drawTrackID, id: nextID, grid: snap, length: length,
                                           quarter: grid.secondsPerQuarter)
        else { return nil }
        nextID += 1
        commit(notes + [note], tracks: added.map { tracks + [$0] }, named: "Draw Note")
        selection = [note.id]
        return note.id
    }

    /// Types a note's start (seconds) and length (seconds); nil leaves that value as it is.
    @discardableResult
    func setTiming(_ id: Int, start: Double? = nil, duration: Double? = nil) -> Bool {
        commit(MIDIEditing.setTiming(notes, id: id, start: start, duration: duration), named: "Change Timing")
    }

    @discardableResult
    func erase(_ ids: Set<Int>) -> Bool {
        commit(MIDIEditing.erase(notes, ids: ids), named: "Delete Notes")
    }

    @discardableResult
    func deleteSelection() -> Bool {
        erase(selection)
    }

    @discardableResult
    func move(_ ids: Set<Int>? = nil, deltaTime: Double, deltaPitch: Int) -> Bool {
        commit(MIDIEditing.move(notes, ids: ids ?? selection, deltaTime: deltaTime, deltaPitch: deltaPitch, grid: snap,
                                quarter: grid.secondsPerQuarter), named: "Move Notes")
    }

    @discardableResult
    func resize(_ ids: Set<Int>? = nil, delta: Double) -> Bool {
        commit(MIDIEditing.resize(notes, ids: ids ?? selection, delta: delta, grid: snap, quarter: grid.secondsPerQuarter), named: "Resize Notes")
    }

    @discardableResult
    func transpose(by semitones: Int) -> Bool {
        commit(MIDIEditing.transpose(notes, ids: selection, by: semitones), named: "Transpose")
    }

    @discardableResult
    func nudge(steps: Int) -> Bool {
        commit(MIDIEditing.nudge(notes, ids: selection, steps: steps, grid: snap, quarter: grid.secondsPerQuarter), named: "Nudge Notes")
    }

    /// Quantizes the selection, or every note when nothing is selected.
    @discardableResult
    func quantize() -> Bool {
        commit(MIDIEditing.quantize(notes, ids: selection.isEmpty ? nil : selection, grid: snap,
                                    quarter: grid.secondsPerQuarter), named: "Quantize")
    }

    @discardableResult
    func setVelocity(_ value: Int, for ids: Set<Int>? = nil) -> Bool {
        commit(MIDIEditing.setVelocity(notes, ids: ids ?? selection, to: value), named: "Change Velocity")
    }

    @discardableResult
    func setVelocities(_ values: [Int: Int]) -> Bool {
        commit(MIDIEditing.setVelocities(notes, values: values), named: "Change Velocity")
    }

    @discardableResult
    func paintVelocity(from: Double, to: Double, value: Int) -> Bool {
        commit(MIDIEditing.paintVelocity(notes, from: from, to: to, value: value, hiddenTracks: hiddenTracks), named: "Change Velocity")
    }

    /// Drops this document's undo and redo steps, for when it is closed or replaced.
    func closeUndo() {
        undoManager?.removeAllActions(withTarget: self)
        undoManager = nil
    }

    func undo() {
        undoManager?.undo()
    }

    func redo() {
        undoManager?.redo()
    }

    // MARK: Undo

    /// The part of the document an edit changes and undo restores.
    private struct State: Equatable, Sendable {
        var tracks: [MIDITrack]
        var notes: [EditorNote]
        var grid: MIDIGrid
    }

    @discardableResult
    private func commit(_ edited: [EditorNote]?, tracks newTracks: [MIDITrack]? = nil, named name: String) -> Bool {
        guard let edited else { return false }
        let new = State(tracks: newTracks ?? tracks, notes: edited, grid: grid)
        let old = State(tracks: tracks, notes: notes, grid: grid)
        guard new != old else { return false }
        replace(old, with: new, named: name)
        return true
    }

    /// Swaps in `new` and registers the swap back, so undo and redo are the same operation run in opposite directions.
    private func replace(_ old: State, with new: State, named name: String) {
        tracks = new.tracks
        notes = new.notes
        grid = new.grid
        selection.formIntersection(Set(new.notes.map(\.id)))
        isEdited = true
        revision += 1
        guard let undoManager else { return }
        let opensGroup = !undoManager.isUndoing && !undoManager.isRedoing
        if opensGroup { undoManager.beginUndoGrouping() }
        undoManager.registerUndo(withTarget: self) { document in
            MainActor.assumeIsolated { document.replace(new, with: old, named: name) }
        }
        undoManager.setActionName(name)
        if opensGroup { undoManager.endUndoGrouping() }
    }
}
