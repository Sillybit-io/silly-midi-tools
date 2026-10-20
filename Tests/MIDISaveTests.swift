import AppKit
import CryptoKit
import Foundation
import Testing
@testable import SillyMIDITools

private func note(_ onset: Double, _ pitch: Int, velocity: Int = 90) -> NoteEvent {
    NoteEvent(onset: onset, offset: onset + 1, pitch: pitch, program: 0, isDrum: false, instrument: "acoustic_piano", velocity: velocity, pitchBends: nil)
}

private func scratchFolder() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "scratch-save-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func sha(_ url: URL) throws -> String {
    SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
}

private func listing(_ folder: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
}

/// Notes as (start, pitch, duration, velocity), the values a save has to keep.
private func values(_ url: URL) throws -> [[Double]] {
    try MIDIImporter.decode(Data(contentsOf: url)).notes.map { [$0.start, Double($0.pitch), $0.duration, Double($0.velocity)] }
}

@MainActor
private final class Prompts {
    var asked: [String] = []
    var answer: UnsavedChoice = .cancel
    var held: ((UnsavedChoice) -> Void)?
    var hold = false
}

@MainActor
private final class Outcomes {
    var proceeded = 0
    var cancelled = 0
    var fileAtProceed: String?
}

@MainActor
private struct Fixture {
    let folder: URL
    let url: URL
    let editor: MIDIEditorModel
    let coordinator = MIDISaveCoordinator()
    let prompts = Prompts()
    let outcomes = Outcomes()
    let saved = Outcomes()

    init(provenance: MIDIProvenance? = MIDIProvenance(source: "file:///Audio/take.wav", modelID: "basic-pitch"),
         grid: MIDIGrid = .standard) throws {
        folder = try scratchFolder()
        url = folder.appending(path: "take.mid")
        var options = MIDIExportOptions()
        options.provenance = provenance
        options.grid = grid
        try MIDIBuilder.build(notes: [note(0, 60), note(1, 64, velocity: 100), note(2, 67)], options: options).write(to: url)
        editor = try MIDIEditorModel.load(url)
        coordinator.editor = editor
        let prompts = prompts
        coordinator.presenter = { name, completion in
            prompts.asked.append(name)
            if prompts.hold { prompts.held = completion } else { completion(prompts.answer) }
        }
        let saved = saved
        coordinator.onSaved = { saved.proceeded += 1 }
    }

    /// Transposes the middle note up two semitones and softens it.
    func edit() {
        let middle = editor.document.notes.first { $0.pitch == 64 }!
        editor.document.select(middle.id)
        editor.document.transpose(by: 2)
        editor.document.setVelocity(33)
    }

    func leave() {
        let outcomes = outcomes, url = url
        coordinator.confirmLeaving(then: {
            outcomes.proceeded += 1
            outcomes.fileAtProceed = MIDIImporter.info(at: url)?.provenance.map { $0.edited ? "edited" : "unedited" }
        }, cancelled: { outcomes.cancelled += 1 })
    }
}

@MainActor
struct MIDISaveTests {
    @Test func gridOnlySaveKeepsNoteSecondsAndReopensMeterMap() throws {
        for grid in [MIDIGrid(bpm: 90, numerator: 3, denominator: 4), MIDIGrid(bpm: 95, numerator: 3, denominator: 4),
                     MIDIGrid(bpm: 120, meters: [MeterChange(bar: 0, numerator: 4, denominator: 4),
                                                  MeterChange(bar: 4, numerator: 3, denominator: 4)])] {
            let fixture = try Fixture()
            let before = fixture.editor.document.notes.map(\.start)
            #expect(fixture.editor.document.setGrid(grid))
            #expect(fixture.coordinator.hasUnsavedChanges)
            #expect(fixture.coordinator.saveOpenFile())
            let reopened = try MIDIEditorModel.load(fixture.url)
            #expect(reopened.document.grid == grid)
            #expect(zip(reopened.document.notes.map(\.start), before).allSatisfy { abs($0 - $1) < 0.00001 })
            #expect(!fixture.editor.document.isDirty)
        }
    }

    @Test func failedGridSaveKeepsOldBytesAndDirtyState() throws {
        let fixture = try Fixture()
        fixture.editor.document.setGrid(MIDIGrid(bpm: 90, numerator: 3, denominator: 4))
        let before = try sha(fixture.url)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: fixture.folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.folder.path) }
        #expect(!fixture.coordinator.saveOpenFile())
        #expect(fixture.editor.document.isDirty)
        #expect(try sha(fixture.url) == before)
    }
    @Test func savingWritesTheEditsAndMarksTheFileEdited() throws {
        let fixture = try Fixture()
        let before = try values(fixture.url)
        fixture.edit()
        #expect(fixture.editor.document.isDirty)

        #expect(fixture.coordinator.saveOpenFile())
        #expect(!fixture.editor.document.isDirty && fixture.editor.document.isEdited)
        #expect(fixture.coordinator.saveFailure == nil && fixture.saved.proceeded == 1)

        let after = try values(fixture.url)
        #expect(after.count == before.count)
        #expect(after[0] == before[0] && after[2] == before[2])
        #expect(after[1] == [before[1][0], 66, before[1][2], 33])

        let provenance = try #require(MIDIImporter.info(at: fixture.url)?.provenance)
        #expect(provenance == MIDIProvenance(source: "audio:take.wav", modelID: "basic-pitch", edited: true, partial: false))
        #expect(try Data(contentsOf: fixture.url).range(of: Data("file%3A".utf8)) == nil)
        #expect(MIDIImporter.info(at: fixture.url)?.origin == .edited)
        #expect(fixture.editor.provenance?.edited == true)
        #expect(try listing(fixture.folder) == ["take.mid"])
    }

    @Test func aFileWithoutMetadataGetsOnlyTheEditedMarker() throws {
        let fixture = try Fixture(provenance: nil)
        fixture.edit()
        #expect(fixture.coordinator.saveOpenFile())
        #expect(MIDIImporter.info(at: fixture.url)?.provenance == MIDIProvenance(edited: true))
    }

    @Test func savingKeepsTheVersionAndTheAudioName() throws {
        let fixture = try Fixture(provenance: MIDIProvenance(source: "audio:take.wav", sourceName: "take", modelID: "basic-pitch", version: 3))
        fixture.edit()
        #expect(fixture.coordinator.saveOpenFile())
        #expect(MIDIImporter.info(at: fixture.url)?.provenance
                == MIDIProvenance(source: "audio:take.wav", sourceName: "take", modelID: "basic-pitch", version: 3, edited: true))
    }

    @Test func aSavedFileKeepsItsLicenceNotice() throws {
        let fixture = try Fixture()
        fixture.edit()
        #expect(fixture.coordinator.saveOpenFile())
        let bytes = try Data(contentsOf: fixture.url)
        #expect(String(decoding: bytes, as: UTF8.self).contains("Basic Pitch by Spotify"))
    }

    @Test func aFailedWriteLeavesTheFileAndTheDirtyFlagAlone() throws {
        let fixture = try Fixture()
        fixture.edit()
        let before = try sha(fixture.url)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: fixture.folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.folder.path) }

        #expect(!fixture.coordinator.saveOpenFile())
        let failure = try #require(fixture.coordinator.saveFailure)
        #expect(failure.name == "take.mid" && failure.message.contains("isn\u{2019}t writable"))
        #expect(fixture.editor.document.isDirty)
        #expect(fixture.saved.proceeded == 0)
        #expect(try sha(fixture.url) == before)
        #expect(try listing(fixture.folder) == ["take.mid"])

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.folder.path)
        #expect(fixture.coordinator.saveOpenFile())
        #expect(fixture.coordinator.saveFailure == nil && !fixture.editor.document.isDirty)
    }

    @Test func aFileReplacedOnDiskIsNotOverwritten() throws {
        let fixture = try Fixture()
        fixture.edit()
        var options = MIDIExportOptions()
        options.provenance = MIDIProvenance(source: "file:///Audio/take.wav", modelID: "muscriptor-small")
        try MIDIBuilder.build(notes: [note(0, 72), note(1, 74)], options: options).write(to: fixture.url)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: fixture.url.path)
        let replacement = try sha(fixture.url)

        #expect(!fixture.coordinator.saveOpenFile())
        #expect(fixture.coordinator.saveFailure?.message.contains("changed on disk") == true)
        #expect(try sha(fixture.url) == replacement)
        #expect(fixture.editor.document.isDirty)
    }

    @Test func aDocumentWithNoNotesIsNotSaved() throws {
        let fixture = try Fixture()
        let before = try sha(fixture.url)
        fixture.editor.document.selectAll()
        fixture.editor.document.deleteSelection()

        #expect(!fixture.coordinator.saveOpenFile())
        #expect(fixture.coordinator.saveFailure?.message.contains("at least one note") == true)
        #expect(try sha(fixture.url) == before)
        #expect(fixture.editor.document.isDirty)
    }

    @Test func aCleanDocumentLeavesWithoutAsking() throws {
        let fixture = try Fixture()
        fixture.leave()
        #expect(fixture.outcomes.proceeded == 1 && fixture.outcomes.cancelled == 0)
        #expect(fixture.prompts.asked.isEmpty)

        #expect(!fixture.coordinator.hasUnsavedChanges)
        fixture.edit()
        #expect(fixture.coordinator.hasUnsavedChanges)
    }

    @Test func cancelKeepsEverythingAsItWas() throws {
        let fixture = try Fixture()
        fixture.edit()
        let before = try sha(fixture.url)
        let notes = fixture.editor.document.notes
        fixture.prompts.answer = .cancel

        fixture.leave()
        #expect(fixture.prompts.asked == ["take"])
        #expect(fixture.outcomes.proceeded == 0 && fixture.outcomes.cancelled == 1)
        #expect(try sha(fixture.url) == before)
        #expect(fixture.editor.document.isDirty && fixture.editor.document.notes == notes)
        #expect(!fixture.coordinator.promptIsOpen)
    }

    @Test func dontSaveLeavesWithoutWriting() throws {
        let fixture = try Fixture()
        fixture.edit()
        let before = try sha(fixture.url)
        fixture.prompts.answer = .dontSave

        fixture.leave()
        #expect(fixture.outcomes.proceeded == 1 && fixture.outcomes.cancelled == 0)
        #expect(try sha(fixture.url) == before)
        #expect(fixture.saved.proceeded == 0)
    }

    @Test func saveWritesBeforeLeaving() throws {
        let fixture = try Fixture()
        fixture.edit()
        fixture.prompts.answer = .save

        fixture.leave()
        #expect(fixture.outcomes.proceeded == 1 && fixture.outcomes.cancelled == 0)
        #expect(fixture.outcomes.fileAtProceed == "edited")
        #expect(!fixture.editor.document.isDirty)
        #expect(try values(fixture.url)[1][1] == 66)
    }

    @Test func aFailedSaveKeepsTheFileOpen() throws {
        let fixture = try Fixture()
        fixture.edit()
        let before = try sha(fixture.url)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: fixture.folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.folder.path) }
        fixture.prompts.answer = .save

        fixture.leave()
        #expect(fixture.outcomes.proceeded == 0 && fixture.outcomes.cancelled == 1)
        #expect(fixture.coordinator.saveFailure != nil)
        #expect(fixture.editor.document.isDirty)
        #expect(try sha(fixture.url) == before)
    }

    @Test func onlyOnePromptIsOpenAtATime() throws {
        let fixture = try Fixture()
        fixture.edit()
        fixture.prompts.hold = true

        fixture.leave()
        #expect(fixture.coordinator.promptIsOpen && fixture.prompts.asked.count == 1)
        fixture.leave()
        #expect(fixture.prompts.asked.count == 1)
        #expect(fixture.outcomes.cancelled == 1 && fixture.outcomes.proceeded == 0)

        fixture.prompts.held?(.dontSave)
        #expect(fixture.outcomes.proceeded == 1 && !fixture.coordinator.promptIsOpen)
    }

    @Test func theWindowDotFollowsTheDocument() throws {
        let fixture = try Fixture()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
        fixture.coordinator.sync(window: window)
        #expect(!window.isDocumentEdited)

        fixture.edit()
        fixture.coordinator.sync(window: window)
        #expect(window.isDocumentEdited)

        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: fixture.folder.path)
        #expect(!fixture.coordinator.saveOpenFile())
        fixture.coordinator.sync(window: window)
        #expect(window.isDocumentEdited)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.folder.path)

        #expect(fixture.coordinator.saveOpenFile())
        fixture.coordinator.sync(window: window)
        #expect(!window.isDocumentEdited)
    }

    @Test func renamingMovesTheFileAndKeepsTheEdits() throws {
        let fixture = try Fixture()
        fixture.edit()
        let renamed = try fixture.editor.rename(to: "Better Take")
        #expect(renamed.lastPathComponent == "Better Take.mid")
        #expect(fixture.editor.url == renamed && fixture.editor.document.isDirty)
        #expect(try listing(fixture.folder) == ["Better Take.mid"])
        #expect(fixture.coordinator.saveOpenFile())
        #expect(MIDIImporter.info(at: renamed)?.provenance?.edited == true)

        try Data([0]).write(to: fixture.folder.appending(path: "Taken.mid"))
        #expect(try fixture.editor.rename(to: "Taken.mid").lastPathComponent == "Taken 2.mid")
        #expect(try fixture.editor.rename(to: "taken 2").lastPathComponent == "taken 2.mid")
        #expect(throws: MIDIRenameError.invalidName) { try fixture.editor.rename(to: "  ") }
        #expect(throws: MIDIRenameError.invalidName) { try fixture.editor.rename(to: "a/b") }
        #expect(try listing(fixture.folder) == ["Taken.mid", "taken 2.mid"])
    }

    @Test func noOpenFileMeansNothingToProtect() {
        let coordinator = MIDISaveCoordinator()
        var proceeded = false
        coordinator.confirmLeaving(then: { proceeded = true })
        #expect(proceeded && !coordinator.hasUnsavedChanges && !coordinator.saveOpenFile())
    }
}
