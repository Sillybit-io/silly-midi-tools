import CoreGraphics
import Foundation
import Testing
@testable import SillyMIDITools

@MainActor
private func makeDocument(undo: UndoManager? = nil) -> MIDIDocument {
    let tracks = [
        MIDITrack(id: "piano", name: "Piano", program: 0, isDrums: false),
        MIDITrack(id: "bass", name: "Bass", program: 33, isDrums: false),
    ]
    let notes = [
        EditorNote(id: 1, track: "piano", pitch: 60, start: 0, duration: 0.5, velocity: 80),
        EditorNote(id: 2, track: "piano", pitch: 64, start: 0.5, duration: 0.5, velocity: 90),
        EditorNote(id: 3, track: "piano", pitch: 67, start: 1.0, duration: 0.25, velocity: 100),
        EditorNote(id: 4, track: "bass", pitch: 36, start: 0.1, duration: 0.8, velocity: 70),
    ]
    let document = MIDIDocument(sourceName: "Take.mid", tracks: tracks, notes: notes)
    document.undoManager = undo
    return document
}

@MainActor
private func makeUndoManager() -> UndoManager {
    let manager = UndoManager()
    manager.groupsByEvent = false
    return manager
}

@MainActor
struct MIDIDocumentTests {
    @Test func gridIsSavedAndRestoredByOneUndoPerEdit() {
        let undo = makeUndoManager()
        let document = makeDocument(undo: undo)
        let originalNotes = document.notes
        let ninety = MIDIGrid(bpm: 90, numerator: 3, denominator: 4)
        #expect(document.setGrid(ninety))
        #expect(!document.setGrid(ninety))
        #expect(undo.undoActionName == "Change Tempo" && document.isDirty)
        #expect(document.notes == originalNotes)
        document.markSaved()
        #expect(!document.isDirty)
        document.undo()
        #expect(document.grid == .standard && document.isDirty && !document.canUndo)
        document.redo()
        #expect(document.grid == ninety && !document.isDirty)
        #expect(document.setGrid(MIDIGrid(bpm: 90, meters: ninety.meters + [MeterChange(bar: 4, numerator: 6, denominator: 8)])))
        #expect(undo.undoActionName == "Add Meter Change")
        document.undo()
        #expect(document.grid == ninety && !document.isDirty && document.notes == originalNotes)
    }

    @Test func snapUsesDocumentQuarter() {
        let document = makeDocument()
        document.setGrid(MIDIGrid(bpm: 90, numerator: 3, denominator: 4))
        #expect(abs(MIDIEditing.snap(0.17, to: .sixteenth, quarter: document.grid.secondsPerQuarter) - 1.0 / 6) < 1e-9)
        let id = document.draw(at: 0.17, pitch: 70)
        #expect(abs((document.notes.first { $0.id == id }?.duration ?? 0) - 1.0 / 6) < 1e-9)
    }
    @Test func selectionByClickShiftAndMarquee() {
        let document = makeDocument()
        document.select(2)
        #expect(document.selection == [2])
        document.toggleSelection(3)
        #expect(document.selection == [2, 3])
        document.toggleSelection(2)
        #expect(document.selection == [3])
        document.select(99)
        document.toggleSelection(99)
        #expect(document.selection == [3])

        document.selectNotes(inTime: 0.4...1.1, pitches: 63...67)
        #expect(document.selection == [2, 3])
        document.selectNotes(inTime: 0.4...1.1, pitches: 63...67, additiveTo: [4])
        #expect(document.selection == [2, 3, 4])
        document.selectNotes(inTime: 5...6, pitches: 24...95)
        #expect(document.selection.isEmpty)

        document.selectAll()
        #expect(document.selection == [1, 2, 3, 4])
        document.clearSelection()
        #expect(document.selection.isEmpty)
        #expect(!document.isDirty && !document.isEdited)
    }

    @Test func drawSnapsToTheGridAndSelectsTheNewNote() throws {
        let document = makeDocument()
        let id = try #require(document.draw(at: 2.19, pitch: 62))
        #expect(id == 5)
        let note = try #require(document.notes.first { $0.id == id })
        #expect(note.track == "piano" && note.pitch == 62 && note.start == 2.125 && note.duration == 0.125)
        #expect(note.velocity == MIDIEditing.defaultVelocity)
        #expect(document.selection == [5])
        #expect(document.isDirty && document.isEdited)

        let longer = try #require(document.draw(at: 3, pitch: 70, length: 0.3))
        #expect(document.notes.first { $0.id == longer }?.duration == 0.25)

        document.snap = .off
        let free = try #require(document.draw(at: 4.19, pitch: 72))
        #expect(document.notes.first { $0.id == free }?.start == 4.19)
        #expect(document.notes.first { $0.id == free }?.duration == 0.25)
    }

    @Test func eraseRemovesTheNotesAndPrunesTheSelection() {
        let document = makeDocument()
        document.selectAll()
        #expect(document.erase([2, 3]))
        #expect(document.notes.map(\.id) == [1, 4])
        #expect(document.selection == [1, 4])
        #expect(document.deleteSelection())
        #expect(document.notes.isEmpty && document.selection.isEmpty)
    }

    @Test func moveIsSnappedAndStopsAtTheEdges() throws {
        let document = makeDocument()
        #expect(document.move([1, 2], deltaTime: 0.16, deltaPitch: 2))
        #expect(document.notes.map(\.start) == [0.125, 0.625, 1.0, 0.1])
        #expect(document.notes.map(\.pitch) == [62, 66, 67, 36])

        #expect(document.move([3], deltaTime: -5, deltaPitch: 100))
        let note = try #require(document.notes.first { $0.id == 3 })
        #expect(note.start == 0 && note.pitch == 95)
        #expect(!document.move([3], deltaTime: 0, deltaPitch: 1))
        #expect(!document.move([3], deltaTime: -1, deltaPitch: 0))
    }

    @Test func movingAGroupKeepsItsShapeAtTheEdge() {
        let document = makeDocument()
        #expect(document.move([1, 2, 3], deltaTime: 0, deltaPitch: 100))
        #expect(document.notes.filter { [1, 2, 3].contains($0.id) }.map(\.pitch) == [88, 92, 95])
    }

    @Test func edgeHandleIsSixPointsAndHitsAreByNoteID() {
        let document = makeDocument()
        let layout = PianoRollLayout(pixelsPerSecond: 100, xOrigin: 0, laneHeight: 12, topPitch: 95)
        let row = CGFloat(95 - 60) * 12 + 4
        #expect(MIDIEditing.resizeEdgeWidth == 6)
        #expect(MIDIEditing.hit(at: CGPoint(x: 47, y: row), notes: document.notes, layout: layout, hiddenTracks: []) == .resizeEdge(1))
        #expect(MIDIEditing.hit(at: CGPoint(x: 44, y: row), notes: document.notes, layout: layout, hiddenTracks: []) == .resizeEdge(1))
        #expect(MIDIEditing.hit(at: CGPoint(x: 43, y: row), notes: document.notes, layout: layout, hiddenTracks: []) == .body(1))
        #expect(MIDIEditing.hit(at: CGPoint(x: 20, y: row), notes: document.notes, layout: layout, hiddenTracks: []) == .body(1))
        #expect(MIDIEditing.hit(at: CGPoint(x: 60, y: row), notes: document.notes, layout: layout, hiddenTracks: []) == nil)

        let bassRow = CGFloat(95 - 36) * 12 + 4
        #expect(MIDIEditing.hit(at: CGPoint(x: 30, y: bassRow), notes: document.notes, layout: layout, hiddenTracks: []) == .body(4))
        #expect(MIDIEditing.hit(at: CGPoint(x: 30, y: bassRow), notes: document.notes, layout: layout, hiddenTracks: ["bass"]) == nil)
    }

    @Test func pointerGeometryMapsToPitchesStepsAndRanges() {
        let layout = PianoRollLayout(pixelsPerSecond: 100, xOrigin: -50, laneHeight: 12, topPitch: 95)
        #expect(MIDIEditing.pitch(atGridY: 0) == 95 && MIDIEditing.pitch(atGridY: 11.9) == 95)
        #expect(MIDIEditing.pitch(atGridY: 12) == 94)
        #expect(MIDIEditing.pitch(atGridY: 71 * 12) == 24)
        #expect(MIDIEditing.pitch(atGridY: 72 * 12) == 23)
        #expect(MIDIEditing.pitch(atGridY: -1) == 96)
        #expect(MIDIEditing.semitones(forDragY: -25) == 2 && MIDIEditing.semitones(forDragY: 25) == -2)
        #expect(MIDIEditing.semitones(forDragY: 5) == 0)

        let box = MIDIEditing.marquee(from: CGPoint(x: 250, y: 60), to: CGPoint(x: 150, y: 12), layout: layout)
        #expect(box.time == 2.0...3.0)
        #expect(box.pitches == 90...94)

        #expect(MIDIEditing.drawLength(dragSeconds: 0, grid: .sixteenth) == 0.125)
        #expect(MIDIEditing.drawLength(dragSeconds: 0.4, grid: .sixteenth) == 0.5)
        #expect(MIDIEditing.drawLength(dragSeconds: -9, grid: .sixteenth) == 0.125)
        #expect(MIDIEditing.drawLength(dragSeconds: 0.1, grid: .off) == 0.35)
        #expect(MIDIEditing.drawLength(dragSeconds: -9, grid: .off) == MIDIEditing.minimumDuration)
    }

    @Test func resizeIsSnappedAndNeverBelowOneGridStep() throws {
        let document = makeDocument()
        #expect(document.resize([1], delta: 0.19))
        #expect(document.notes.first { $0.id == 1 }?.duration == 0.75)

        #expect(document.resize([3], delta: -5))
        let shortest = try #require(document.notes.first { $0.id == 3 })
        #expect(shortest.duration == 0.125)
        #expect(document.notes.allSatisfy { $0.duration > 0 })

        document.snap = .off
        #expect(document.resize([3], delta: -5))
        #expect(document.notes.first { $0.id == 3 }?.duration == MIDIEditing.minimumDuration)
    }

    @Test func quantizeWorksOnTheSelectionOrEverything() throws {
        let document = makeDocument()
        document.select(1)
        #expect(!document.quantize())

        document.select(4)
        #expect(document.quantize())
        let bass = try #require(document.notes.first { $0.id == 4 })
        #expect(bass.start == 0.125 && bass.duration == 0.75)

        document.clearSelection()
        #expect(!document.quantize())
        document.snap = .off
        #expect(!document.quantize())
    }

    @Test func transposeAndNudgeMoveTheSelection() {
        let document = makeDocument()
        document.select(1)
        document.toggleSelection(2)
        #expect(document.transpose(by: 12))
        #expect(document.notes.map(\.pitch) == [72, 76, 67, 36])
        #expect(document.nudge(steps: 1))
        #expect(document.notes.map(\.start) == [0.125, 0.625, 1.0, 0.1])
        #expect(document.nudge(steps: -1))
        #expect(!document.nudge(steps: -1))
        #expect(document.notes.map(\.start) == [0, 0.5, 1.0, 0.1])

        document.clearSelection()
        #expect(!document.transpose(by: 1))
        #expect(!document.nudge(steps: 1))
    }

    @Test func velocityIsClampedAndPaintedAcrossATimeSpan() {
        let document = makeDocument()
        #expect(document.setVelocity(200, for: [1]))
        #expect(document.notes.first { $0.id == 1 }?.velocity == 127)
        #expect(document.setVelocity(0, for: [1]))
        #expect(document.notes.first { $0.id == 1 }?.velocity == 1)
        #expect(!document.setVelocity(0, for: [1]))

        #expect(document.paintVelocity(from: 1.05, to: 0.4, value: 55))
        #expect(document.notes.map(\.velocity) == [1, 55, 55, 70])

        document.toggleHidden("piano")
        #expect(document.paintVelocity(from: 0, to: 2, value: 33))
        #expect(document.notes.map(\.velocity) == [1, 55, 55, 33])
        #expect(!document.paintVelocity(from: 5, to: 6, value: 10))
    }

    @Test func aPaintStrokeGivesEachNoteItsOwnVelocityInOneUndoStep() {
        let undo = makeUndoManager()
        let document = makeDocument(undo: undo)
        #expect(document.setVelocities([1: 20, 2: 127, 3: 500, 99: 50]))
        #expect(document.notes.map(\.velocity) == [20, 127, 127, 70])
        #expect(!document.setVelocities([1: 20, 2: 127]))
        #expect(!document.setVelocities([:]))
        document.undo()
        #expect(document.notes.map(\.velocity) == [80, 90, 100, 70])
        #expect(!document.canUndo)
    }

    @Test func closingADocumentDropsItsUndoSteps() {
        let undo = makeUndoManager()
        let document = makeDocument(undo: undo)
        document.select(1)
        document.transpose(by: 2)
        #expect(undo.canUndo)
        document.closeUndo()
        #expect(!undo.canUndo && document.undoManager == nil)
    }

    @Test func trackMuteSoloAndHideChangeAudibilityButNeverDirtyTheDocument() {
        let document = makeDocument()
        let piano = document.notes[0], bass = document.notes[3]
        #expect(document.isAudible(piano) && document.isAudible(bass))

        document.toggleMute("piano")
        #expect(!document.isAudible(piano) && document.isAudible(bass))
        document.toggleMute("piano")
        document.toggleSolo("bass")
        #expect(!document.isAudible(piano) && document.isAudible(bass))
        document.toggleMute("bass")
        #expect(!document.isAudible(bass))
        document.toggleMute("bass")

        document.select(4)
        document.toggleHidden("bass")
        #expect(!document.isVisible(bass) && !document.isAudible(bass))
        #expect(document.selection.isEmpty)
        document.selectAll()
        #expect(document.selection == [1, 2, 3])
        document.drawTrackID = "bass"
        #expect(document.draw(at: 1, pitch: 40) == nil)
        document.toggleHidden("bass")
        #expect(document.isVisible(bass))

        #expect(!document.isDirty && !document.isEdited && document.notes.count == 4)
    }

    @Test func undoAndRedoAcrossTwoEdits() throws {
        let undo = makeUndoManager()
        let document = makeDocument(undo: undo)
        let original = document.notes

        let id = try #require(document.draw(at: 2, pitch: 62))
        let afterDraw = document.notes
        #expect(document.transpose(by: 2))
        let afterTranspose = document.notes
        #expect(afterTranspose.first { $0.id == id }?.pitch == 64)
        #expect(document.canUndo && !document.canRedo)

        document.undo()
        #expect(document.notes == afterDraw)
        #expect(document.selection == [id])
        document.undo()
        #expect(document.notes == original)
        #expect(document.selection.isEmpty)
        #expect(!document.isDirty)
        #expect(document.isEdited)
        #expect(!document.canUndo && document.canRedo)

        document.redo()
        #expect(document.notes == afterDraw)
        document.redo()
        #expect(document.notes == afterTranspose)
        #expect(document.isDirty)
    }

    @Test func aNewEditClearsRedoAndEachEditHasAName() {
        let undo = makeUndoManager()
        let document = makeDocument(undo: undo)
        document.select(1)
        document.transpose(by: 1)
        #expect(undo.undoActionName == "Transpose")
        document.undo()
        #expect(document.canRedo)
        document.erase([2])
        #expect(undo.undoActionName == "Delete Notes")
        #expect(!document.canRedo)
    }

    @Test func rejectedEditsLeaveNoTraceAndNeverSetDirty() {
        let undo = makeUndoManager()
        let document = makeDocument(undo: undo)
        let before = document.notes
        let revision = document.revision

        #expect(document.draw(at: 1, pitch: 20) == nil)
        #expect(document.draw(at: 1, pitch: 96) == nil)
        #expect(document.draw(at: -0.5, pitch: 60) == nil)
        #expect(document.draw(at: .nan, pitch: 60) == nil)
        #expect(!document.erase([]))
        #expect(!document.erase([99]))
        #expect(!document.deleteSelection())
        #expect(!document.resize([99], delta: -1))
        #expect(!document.resize([3], delta: .infinity))
        #expect(!document.move([], deltaTime: 1, deltaPitch: 1))

        document.snap = .eighth
        #expect(!document.resize([3], delta: -5))
        #expect(document.notes.allSatisfy { $0.duration > 0 })

        #expect(document.notes == before)
        #expect(!document.isDirty && !document.isEdited)
        #expect(!document.canUndo)
        #expect(document.revision == revision)
    }

    @Test func markSavedClearsDirtyButKeepsTheEditedFlag() {
        let document = makeDocument()
        document.select(1)
        document.transpose(by: 1)
        #expect(document.isDirty && document.isEdited)
        document.markSaved()
        #expect(!document.isDirty && document.isEdited)
        document.transpose(by: 1)
        #expect(document.isDirty)

        let reopened = MIDIDocument(sourceName: "Edited.mid", tracks: [], notes: [], isEdited: true)
        #expect(reopened.isEdited && !reopened.isDirty)
    }

    @Test func buildsTracksFromEngineEventsAndKeepsOnlyC1ToB6() {
        func event(_ onset: Double, _ offset: Double, _ pitch: Int, _ instrument: String, program: Int = 0, drum: Bool = false, velocity: Int? = nil) -> NoteEvent {
            NoteEvent(onset: onset, offset: offset, pitch: pitch, program: program, isDrum: drum, instrument: instrument, velocity: velocity, pitchBends: nil)
        }
        let document = MIDIDocument(sourceName: "From audio", events: [
            event(0, 1, 60, "piano"),
            event(0.5, 0.9, 20, "piano"),
            event(1, 1.5, 36, "drums", drum: true, velocity: 90),
            event(2, 2, 72, "acoustic_bass", program: 32, velocity: 500),
        ])
        #expect(document.tracks.map(\.id) == ["piano", "drums", "acoustic_bass"])
        #expect(document.tracks.map(\.name) == ["piano", "drums", "acoustic bass"])
        #expect(document.skippedNotes == 1)
        #expect(document.notes.map(\.id) == [1, 2, 3])
        #expect(document.notes.map(\.velocity) == [100, 90, 127])
        #expect(document.notes[2].duration == MIDIEditing.minimumDuration)
        #expect(document.drawTrackID == "piano")

        let events = document.noteEvents
        #expect(events.map(\.pitch) == [60, 36, 72])
        #expect(events.map(\.instrument) == ["piano", "drums", "acoustic_bass"])
        #expect(events[1].isDrum && events[2].program == 32)
        #expect(!document.isDirty)
    }
}

@MainActor
struct MIDIDocumentTrackAndTimingTests {
    private func document(undo: UndoManager) -> MIDIDocument {
        let document = MIDIDocument(sourceName: "t.mid", tracks: [MIDITrack(id: "piano", name: "piano", program: 0, isDrums: false)],
                                    notes: [EditorNote(id: 1, track: "piano", pitch: 60, start: 1, duration: 0.5, velocity: 90)])
        undo.groupsByEvent = false
        document.undoManager = undo
        return document
    }

    @Test func typedStartAndLengthAreKeptUnsnappedAndUndoable() {
        let undo = UndoManager()
        let document = document(undo: undo)
        #expect(document.setTiming(1, start: 1.237))
        #expect(document.setTiming(1, duration: 0.333))
        #expect(document.notes[0].start == 1.237 && document.notes[0].duration == 0.333)
        #expect(document.setTiming(1, start: -4, duration: 0))
        #expect(document.notes[0].start == 0 && document.notes[0].duration == MIDIEditing.minimumDuration)
        #expect(!document.setTiming(1, start: 0))
        #expect(!document.setTiming(1, start: .nan))
        #expect(!document.setTiming(99, start: 2))
        document.undo()
        #expect(document.notes[0].start == 1.237 && document.notes[0].duration == 0.333)
    }

    @Test func drawingOnANewInstrumentAddsItsTrackInTheSameUndoStep() throws {
        let undo = UndoManager()
        let document = document(undo: undo)
        #expect(MIDITrack.classes.contains("violin") && MIDITrack.newTrack(forClass: "theremin") == nil)
        document.drawTrackID = "violin"
        let id = try #require(document.draw(at: 2, pitch: 67))
        #expect(document.tracks.map(\.id) == ["piano", "violin"])
        #expect(document.tracks[1].program == 40 && !document.tracks[1].isDrums)
        #expect(document.notes.first { $0.id == id }?.track == "violin")
        #expect(MIDIImporter.instrument(program: document.tracks[1].program, channel: 0) == "violin")

        document.undo()
        #expect(document.tracks.map(\.id) == ["piano"] && document.notes.count == 1)
        document.redo()
        #expect(document.tracks.map(\.id) == ["piano", "violin"] && document.notes.count == 2)

        document.drawTrackID = "drums"
        _ = try #require(document.draw(at: 3, pitch: 36))
        #expect(document.tracks.last?.isDrums == true)
        #expect(document.noteEvents.last { $0.pitch == 36 }?.isDrum == true)
    }
}
