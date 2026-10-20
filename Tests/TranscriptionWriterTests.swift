import CryptoKit
import Foundation
import SwiftMIDIFile
import Testing
@testable import SillyMIDITools

private let notice = "Transcribed with Basic Pitch by Spotify (Apache-2.0)."
private let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/BasicPitch")

private func note(_ onset: Double, _ offset: Double, _ pitch: Int) -> NoteEvent {
    NoteEvent(onset: onset, offset: offset, pitch: pitch, program: 0, isDrum: false, instrument: "acoustic_piano", velocity: 90, pitchBends: nil)
}

private func makeRun(_ name: String = "synthetic", model: String? = "basic-pitch") -> TranscriptionWriter.Run {
    let url = URL(fileURLWithPath: "/Audio/\(name).wav")
    return TranscriptionWriter.Run(source: url, sourceID: TranscriptionWriter.sourceIdentifier(for: url, references: []), title: name,
                                   modelID: model, notice: notice, slice: AudioSlice(duration: 3))
}

private func scratchFolder() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "scratch-writer-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    // Directory listings return /private/var/... for a /var/... temporary directory when the app isn't sandboxed, so compare real paths.
    var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
    guard realpath(url.path, &buffer) != nil else { return url }
    return URL(fileURLWithPath: String(cString: buffer), isDirectory: true)
}

private func listing(_ folder: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
}

private func sha(_ url: URL) throws -> String {
    SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
}

private func created(_ url: URL) throws -> Date? {
    try FileManager.default.attributesOfItem(atPath: url.path)[.creationDate] as? Date
}

/// A MIDI file as the app would leave it after a transcription (or after the user's edits). No version means one saved
/// before versions existed.
@discardableResult
private func existing(_ name: String, in folder: URL, source: TranscriptionWriter.Run?, version: Int? = nil, edited: Bool = false,
                      partial: Bool = false, pitch: Int = 70) throws -> URL {
    var options = MIDIExportOptions()
    options.provenance = source.map { MIDIProvenance(source: $0.sourceID, modelID: $0.modelID, version: version, edited: edited, partial: partial) }
    let url = folder.appending(path: name)
    try MIDIBuilder.build(notes: [note(0, 1, pitch)], options: options).write(to: url)
    return url
}

private let first = "synthetic - basic-pitch.mid"
private let second = "synthetic - basic-pitch 2.mid"

@MainActor
private final class Counter {
    var value = 0
}

@MainActor
struct TranscriptionWriterTests {
    private let writer = TranscriptionWriter()

    @Test func aCompletedRunIsSavedAsVersionOneWithItsSourceModelAndLicenceNotice() throws {
        let folder = try scratchFolder()
        let run = makeRun()
        writer.finish(.done(2), notes: [note(0, 1, 60), note(1, 2, 64)], run: run, folder: folder)

        let url = folder.appending(path: first)
        #expect(writer.status == .saved(url, version: 1, partial: false))
        let info = try #require(MIDIImporter.info(at: url))
        #expect(info.noteCount == 2 && info.origin == .fromAudio)
        #expect(info.provenance == MIDIProvenance(source: run.sourceID, sourceName: "synthetic", modelID: "basic-pitch", version: 1,
                                                  edited: false, partial: false))

        let file = try MusicalMIDI1File(data: Data(contentsOf: url))
        let copyrights = file.tracks[0].events.compactMap { event -> String? in
            if case .text(let text) = event.event, text.textType == .copyright { text.text } else { nil }
        }
        #expect(copyrights == [notice])
        #expect(try listing(folder) == [first])
    }

    @Test func rerunningTheSameModelKeepsEveryVersion() throws {
        let folder = try scratchFolder()
        let run = makeRun()
        writer.finish(.done(1), notes: [note(0, 1, 60)], run: run, folder: folder)
        let original = folder.appending(path: first)
        let before = try sha(original)
        writer.finish(.done(3), notes: [note(0, 1, 60), note(1, 2, 62), note(2, 3, 64)], run: run, folder: folder)

        let rerun = folder.appending(path: second)
        #expect(writer.status == .saved(rerun, version: 2, partial: false))
        #expect(try listing(folder) == [second, first])
        #expect(try sha(original) == before)
        #expect(MIDIImporter.info(at: original)?.noteCount == 1)
        #expect(MIDIImporter.info(at: rerun)?.noteCount == 3)
        #expect(MIDIImporter.info(at: rerun)?.provenance?.version == 2)
    }

    @Test func eachModelGetsItsOwnFileAndNoneIsReplaced() throws {
        let folder = try scratchFolder()
        writer.finish(.done(1), notes: [note(0, 1, 60)], run: makeRun(), folder: folder)
        let basic = folder.appending(path: first)
        let before = try sha(basic)

        writer.finish(.done(2), notes: [note(0, 1, 60), note(1, 2, 62)], run: makeRun(model: "muscriptor-large"), folder: folder)
        let large = folder.appending(path: "synthetic - muscriptor-large.mid")
        #expect(writer.status == .saved(large, version: 2, partial: false))
        let largeBefore = try sha(large)

        writer.finish(.done(3), notes: [note(0, 1, 60), note(1, 2, 62), note(2, 3, 64)], run: makeRun(), folder: folder)
        #expect(writer.status == .saved(folder.appending(path: second), version: 3, partial: false))
        #expect(try listing(folder) == [second, first, "synthetic - muscriptor-large.mid"])
        #expect(try sha(basic) == before)
        #expect(try sha(large) == largeBefore)
        #expect(MIDIImporter.info(at: large)?.provenance?.modelID == "muscriptor-large")
    }

    @Test func aFileFromBeforeVersionsIsKeptAndCountsTowardsTheNextNumber() throws {
        let folder = try scratchFolder()
        let run = makeRun()
        let legacy = try existing("synthetic.mid", in: folder, source: run)
        let before = try sha(legacy)

        writer.finish(.done(1), notes: [note(0, 1, 60)], run: run, folder: folder)
        #expect(writer.status == .saved(folder.appending(path: first), version: 2, partial: false))
        #expect(try sha(legacy) == before)
        #expect(try listing(folder) == [first, "synthetic.mid"])
    }

    @Test func theNextVersionFollowsTheHighestEvenAfterOneIsDeleted() throws {
        let folder = try scratchFolder()
        let run = makeRun()
        for count in 1...3 { writer.finish(.done(count), notes: [note(0, 1, 60 + count)], run: run, folder: folder) }
        try FileManager.default.removeItem(at: folder.appending(path: second))

        writer.finish(.done(1), notes: [note(0, 1, 70)], run: run, folder: folder)
        #expect(writer.status == .saved(folder.appending(path: second), version: 4, partial: false))
    }

    @Test func aFileWithHandEditsIsNeverReplaced() throws {
        let folder = try scratchFolder()
        let run = makeRun()
        let edited = try existing(first, in: folder, source: run, version: 1, edited: true)
        let before = try sha(edited)

        writer.finish(.done(2), notes: [note(0, 1, 60), note(1, 2, 64)], run: run, folder: folder)
        let next = folder.appending(path: second)
        #expect(writer.status == .saved(next, version: 2, partial: false))
        #expect(try sha(edited) == before)
        let provenance = try #require(MIDIImporter.info(at: next)?.provenance)
        #expect(!provenance.edited && !provenance.partial && provenance.source == run.sourceID)
        #expect(try listing(folder) == [second, first])
    }

    @Test func filesThatAreNotThisSourcesOutputKeepTheirNames() throws {
        let folder = try scratchFolder()
        let run = makeRun()
        let imported = try existing(first, in: folder, source: nil)
        let other = try existing(second, in: folder, source: makeRun("elsewhere"))
        let unreadable = folder.appending(path: "synthetic - basic-pitch 3.mid")
        try Data("not midi".utf8).write(to: unreadable)
        let hashes = try [imported, other, unreadable].map(sha)

        writer.finish(.done(1), notes: [note(0, 1, 60)], run: run, folder: folder)
        #expect(writer.status == .saved(folder.appending(path: "synthetic - basic-pitch 4.mid"), version: 1, partial: false))
        #expect(try [imported, other, unreadable].map(sha) == hashes)
    }

    @Test func aCancelledRunSavesItsPartialNotesAndFinishingItKeepsItsVersionAndPlace() throws {
        let folder = try scratchFolder()
        let run = makeRun()
        let url = folder.appending(path: first)

        writer.finish(.cancelled, notes: [note(0, 1, 60)], run: run, folder: folder)
        #expect(writer.status == .saved(url, version: 1, partial: true))
        #expect(MIDIImporter.info(at: url)?.provenance?.partial == true)
        let born = try created(url)

        writer.finish(.cancelled, notes: [note(0, 1, 60), note(1, 2, 62)], run: run, folder: folder)
        #expect(writer.status == .saved(url, version: 1, partial: true))
        #expect(MIDIImporter.info(at: url)?.noteCount == 2)
        #expect(try listing(folder) == [first])

        writer.finish(.done(3), notes: [note(0, 1, 60), note(1, 2, 62), note(2, 3, 64)], run: run, folder: folder)
        #expect(writer.status == .saved(url, version: 1, partial: false))
        #expect(MIDIImporter.info(at: url)?.provenance?.partial == false)
        #expect(MIDIImporter.info(at: url)?.noteCount == 3)
        #expect(try listing(folder) == [first])
        // The library lists versions by creation date, so the finished file stays where its partial was.
        #expect(try created(url) == born)
    }

    @Test func cancellingARerunNeverErasesAnEarlierCompleteResult() throws {
        let folder = try scratchFolder()
        let run = makeRun()
        writer.finish(.done(2), notes: [note(0, 1, 60), note(1, 2, 64)], run: run, folder: folder)
        let url = folder.appending(path: first)
        let before = try sha(url)

        writer.finish(.cancelled, notes: [note(0, 1, 72)], run: run, folder: folder)
        #expect(writer.status == .keptPrevious(url, version: 1))
        #expect(try sha(url) == before)
        #expect(try listing(folder) == [first])

        writer.finish(.cancelled, notes: [], run: run, folder: folder)
        #expect(writer.status == .empty)
        #expect(try sha(url) == before)
    }

    @Test func aCancelledRunKeepsAResultFromBeforeVersionsWithoutANumber() throws {
        let folder = try scratchFolder()
        let run = makeRun()
        let legacy = try existing("synthetic.mid", in: folder, source: run)

        writer.finish(.cancelled, notes: [note(0, 1, 72)], run: run, folder: folder)
        #expect(writer.status == .keptPrevious(legacy, version: nil))
        #expect(try listing(folder) == ["synthetic.mid"])
    }

    @Test func aCancelledRunOfAnotherModelSavesItsOwnPartialBesideTheCompleteOne() throws {
        let folder = try scratchFolder()
        writer.finish(.done(1), notes: [note(0, 1, 60)], run: makeRun(), folder: folder)
        let basic = folder.appending(path: first)
        let before = try sha(basic)

        let small = makeRun(model: "muscriptor-small")
        let partial = folder.appending(path: "synthetic - muscriptor-small.mid")
        writer.finish(.cancelled, notes: [note(0, 1, 62)], run: small, folder: folder)
        #expect(writer.status == .saved(partial, version: 2, partial: true))

        writer.finish(.done(2), notes: [note(0, 1, 62), note(1, 2, 64)], run: small, folder: folder)
        #expect(writer.status == .saved(partial, version: 2, partial: false))
        #expect(try listing(folder) == [first, "synthetic - muscriptor-small.mid"])
        #expect(try sha(basic) == before)
    }

    @Test func aCancelledRunBesideAnEditedFileGetsItsOwnPartialFile() throws {
        let folder = try scratchFolder()
        let run = makeRun()
        let edited = try existing(first, in: folder, source: run, version: 1, edited: true)
        let before = try sha(edited)

        writer.finish(.cancelled, notes: [note(0, 1, 60)], run: run, folder: folder)
        let partial = folder.appending(path: second)
        #expect(writer.status == .saved(partial, version: 2, partial: true))
        #expect(MIDIImporter.info(at: partial)?.provenance?.partial == true)
        #expect(try sha(edited) == before)
    }

    @Test func emptyResultsAndNonTerminalStatesWriteNothing() throws {
        let folder = try scratchFolder()
        let run = makeRun()
        writer.finish(.done(0), notes: [], run: run, folder: folder)
        #expect(writer.status == .empty)
        #expect(try listing(folder).isEmpty)

        writer.reset()
        for state in [TranscriptionSession.State.idle, .loading(0.5), .running, .refining, .failed("The engine hit an internal error.")] {
            writer.finish(state, notes: [note(0, 1, 60)], run: run, folder: folder)
        }
        #expect(writer.status == .idle)
        #expect(try listing(folder).isEmpty)
    }

    @Test func aFailedWriteKeepsThePreviousResultAndCanBeRetried() throws {
        let folder = try scratchFolder()
        let run = makeRun()
        writer.finish(.done(1), notes: [note(0, 1, 60)], run: run, folder: folder)
        let url = folder.appending(path: first)
        let before = try sha(url)

        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
        writer.finish(.done(2), notes: [note(0, 1, 60), note(1, 2, 64)], run: run, folder: folder)
        guard case .failed(let message) = writer.status else {
            Issue.record("expected a failure, got \(writer.status)")
            return
        }
        #expect(message.contains(second) && message.contains("isn\u{2019}t writable"))
        #expect(try sha(url) == before)
        #expect(try listing(folder) == [first])

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        writer.retry(folder: folder)
        let retried = folder.appending(path: second)
        #expect(writer.status == .saved(retried, version: 2, partial: false))
        #expect(MIDIImporter.info(at: retried)?.noteCount == 2)
        #expect(try sha(url) == before)
    }

    @Test func aFailedWriteLeavesNoEmptyFileBehind() throws {
        let folder = try scratchFolder()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }

        writer.finish(.done(1), notes: [note(0, 1, 60)], run: makeRun(), folder: folder)
        if case .failed = writer.status {} else { Issue.record("expected a failure, got \(writer.status)") }
        #expect(try listing(folder).isEmpty)
    }

    @Test func noWorkingFolderIsReportedAndTheSaveCanBeRetried() throws {
        let run = makeRun()
        writer.finish(.done(1), notes: [note(0, 1, 60)], run: run, folder: nil)
        #expect(writer.status == .failed("Choose a working folder first."))

        let folder = try scratchFolder()
        writer.retry(folder: folder)
        #expect(writer.status == .saved(folder.appending(path: first), version: 1, partial: false))
    }

    @Test func regridRewritesTheSameVersionAndRefreshesItsDigestOnlyAfterSuccess() throws {
        let folder = try scratchFolder()
        var run = makeRun()
        run.grid = MIDIGrid(bpm: 95, numerator: 3, denominator: 4)
        let notes = [note(0.4, 1.1, 60), note(1.2, 1.9, 64)]
        writer.finish(.done(notes.count), notes: notes, run: run, folder: folder)
        let url = folder.appending(path: first)
        let status = writer.status
        #expect(writer.regrid(to: MIDIGrid(bpm: 92, numerator: 3, denominator: 4)) == .updated)
        #expect(writer.status == status)
        let imported = try MIDIImporter.decode(Data(contentsOf: url))
        #expect(imported.grid == MIDIGrid(bpm: 92, numerator: 3, denominator: 4))
        #expect(zip(imported.notes.map(\.start), [0.4, 1.2]).allSatisfy { abs($0 - $1) < 0.002 })
        #expect(imported.provenance?.version == 1 && imported.provenance?.edited == false)
        #expect(writer.notice == nil)
        #expect(writer.regrid(to: MIDIGrid(bpm: 90, numerator: 3, denominator: 4)) == .updated)
        #expect(try MIDIImporter.decode(Data(contentsOf: url)).grid.bpm == 90)

        var external = MIDIExportOptions()
        external.grid = MIDIGrid(bpm: 90, numerator: 3, denominator: 4)
        external.title = run.title
        external.sliceLength = run.slice.span
        external.copyright = run.notice
        external.provenance = imported.provenance
        try MIDIBuilder.build(notes: [note(0.4, 1.1, 72)], options: external).write(to: url)
        let altered = try sha(url)
        #expect(MIDIImporter.info(at: url)?.provenance == imported.provenance)
        #expect(writer.regrid(to: MIDIGrid(bpm: 88, numerator: 3, denominator: 4)) == .notUpdated)
        #expect(try sha(url) == altered)
        #expect(writer.status == status && writer.notice != nil)
    }

    @Test func pendingRetryUsesLatestGridAndAnOriginInvalidationDiscardsIt() throws {
        var run = makeRun()
        run.grid = MIDIGrid(bpm: 95, numerator: 3, denominator: 4)
        writer.finish(.done(1), notes: [note(0, 1, 60)], run: run, folder: nil)
        writer.updatePendingGrid(MIDIGrid(bpm: 92, numerator: 3, denominator: 4))
        let folder = try scratchFolder()
        writer.retry(folder: folder)
        #expect(try MIDIImporter.decode(Data(contentsOf: folder.appending(path: first))).grid.bpm == 92)
        writer.reset()
        writer.finish(.done(1), notes: [note(0, 1, 60)], run: run, folder: nil)
        writer.discardPending()
        writer.retry(folder: folder)
        #expect(writer.status == .idle)
    }

    @Test func failedReplacementDoesNotChangeTheSavedIdentityOrFile() throws {
        let folder = try scratchFolder()
        var run = makeRun()
        run.grid = MIDIGrid(bpm: 95, numerator: 3, denominator: 4)
        writer.finish(.done(1), notes: [note(0, 1, 60)], run: run, folder: folder)
        let url = folder.appending(path: first)
        let before = try sha(url)
        let status = writer.status
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        #expect(writer.regrid(to: MIDIGrid(bpm: 92, numerator: 3, denominator: 4)) == .notUpdated)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        #expect(try sha(url) == before)
        #expect(writer.status == status && writer.notice != nil)
        #expect(writer.regrid(to: MIDIGrid(bpm: 90, numerator: 3, denominator: 4)) == .updated)
        #expect(try MIDIImporter.decode(Data(contentsOf: url)).grid.bpm == 90)
    }

    @Test func aSourceIsIdentifiedByItsBookmarkOrItsNameNeverItsPath() {
        let url = URL(fileURLWithPath: "/Users/someone/Music/take.wav")
        let reference = AudioReference(name: "take.wav", lastPath: url.path, bookmark: Data())
        #expect(TranscriptionWriter.sourceIdentifier(for: url, references: [reference]) == "reference:\(reference.id.uuidString)")
        #expect(TranscriptionWriter.sourceIdentifier(for: url, references: []) == "audio:take.wav")
    }

    @Test func aFileThatNamedItsSourceByPathStillCountsAsAVersion() throws {
        let folder = try scratchFolder()
        let run = makeRun()
        var options = MIDIExportOptions()
        options.provenance = MIDIProvenance(source: "file:///Users/someone/Silly%20MIDI%20Tools/Audio/synthetic.wav",
                                            modelID: "basic-pitch", version: 1)
        try MIDIBuilder.build(notes: [note(0, 1, 70)], options: options).write(to: folder.appending(path: first))

        #expect(try TranscriptionWriter.write([note(0, 1, 60)], run: run, partial: false, in: folder)
                == .saved(folder.appending(path: second), version: 2))
        let data = try Data(contentsOf: folder.appending(path: second))
        #expect(data.range(of: Data("someone".utf8)) == nil && data.range(of: Data("%2F".utf8)) == nil)
    }

    @Test func defaultNamesAreToldApartFromNamesTheUserChose() {
        let isDefault = { TranscriptionWriter.isDefaultName($0, title: "song", modelID: "basic-pitch") }
        #expect(isDefault("song - basic-pitch"))
        #expect(isDefault("song - basic-pitch 3"))
        #expect(isDefault("song"))
        #expect(isDefault("song 2"))
        #expect(!isDefault("song - basic-pitch 1"))
        #expect(!isDefault("song - basic-pitch take two"))
        #expect(!isDefault("Best take"))
        #expect(!isDefault("song - muscriptor-large"))
        #expect(TranscriptionWriter.isDefaultName("song 2", title: "song", modelID: nil))
    }

    @Test func transcribingTheFixtureSavesALinkedFileAndTellsTheLibrary() async throws {
        let folder = try scratchFolder()
        let wav = fixtures.appendingPathComponent("synthetic.wav")
        let document = DocumentModel()
        document.open(wav)
        for _ in 0..<200 where document.document == nil { try await Task.sleep(for: .milliseconds(50)) }
        #expect(document.document != nil)

        let (defaults, cleanup) = scratchDefaults("smt-writer")
        defer { cleanup() }
        let refreshed = Counter()
        let session = TranscriptionSession()
        let screen = AudioScreenModel(document: document, store: ModelStore(directory: folder.appending(path: "models")), session: session,
                                      access: AccessCoordinator(keychain: KeychainStore(service: "smt-test-\(UUID().uuidString)")),
                                      preferences: AppPreferences(defaults: defaults), destination: { folder },
                                      onSaved: { refreshed.value += 1 })
        screen.selectedModel = "basic-pitch"
        screen.start()
        for _ in 0..<1200 where screen.writer.status == .idle { try await Task.sleep(for: .milliseconds(50)) }

        let url = folder.appending(path: first)
        #expect(screen.writer.status == .saved(url, version: 1, partial: false))
        #expect(session.state == .done(session.notes.count))
        let info = try #require(MIDIImporter.info(at: url))
        #expect(info.noteCount > 0 && info.origin == .fromAudio)
        #expect(info.provenance?.source == "audio:synthetic.wav")
        #expect(info.provenance?.sourceName == "synthetic")
        #expect(info.provenance?.modelID == "basic-pitch")
        #expect(info.provenance?.version == 1)
        #expect(refreshed.value == 1)
        #expect(try listing(folder).filter { $0.hasSuffix(".mid") } == [first])
    }
}
