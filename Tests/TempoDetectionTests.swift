import Foundation
import Testing
@testable import SillyMIDITools

private let tempoFixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appending(path: "Fixtures/TempoUI/fixture.wav")

private actor DelayedTempo {
    private var continuations: [CheckedContinuation<AudioScreenModel.AnalysisValue, Error>] = []
    private var calls = 0
    func run() async throws -> AudioScreenModel.AnalysisValue {
        calls += 1
        return try await withCheckedThrowingContinuation { continuations.append($0) }
    }
    func count() -> Int { calls }
    func release(_ index: Int, with value: AudioScreenModel.AnalysisValue) { continuations[index].resume(returning: value) }
    func fail(_ index: Int) { continuations[index].resume(throwing: TempoTestError.failed) }
}
private enum TempoTestError: Error { case failed }

@MainActor
struct TempoDetectionTests {
    private func wait(_ condition: @escaping @MainActor () async -> Bool) async throws {
        for _ in 0..<3000 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for analysis")
    }

    private func delayed() async throws -> (AudioScreenModel, DelayedTempo) {
        let (model, _) = try await screen()
        let gate = DelayedTempo()
        model.analyzer = { _, _, _, _, _ in try await gate.run() }
        return (model, gate)
    }

    @Test func delayedResultsCannotPublishAfterSourceSliceSupersessionOrCancel() async throws {
        let answer = AudioScreenModel.AnalysisValue.quick(AudioTempoResult(candidates: [TempoCandidate(bpm: 95, score: 0.9, relative: nil)], beats: [0.3]))
        for scenario in 0..<5 {
            let (model, gate) = try await delayed()
            model.startAnalysis(.quickTempo)
            try await wait { await gate.count() == 1 }
            switch scenario {
            case 0:
                let old = try #require(model.document.document)
                model.document.document = AudioDocument(url: URL(fileURLWithPath: "/different-source.wav"), samples: old.samples, sampleRate: old.sampleRate)
                model.documentChanged()
            case 1: model.document.slice.setStart(0.4); model.sliceChanged()
            case 2: model.document.slice.setEnd(18); model.sliceChanged()
            case 3:
                model.cancelCurrent()
                model.startAnalysis(.quickTempo)
                try await wait { await gate.count() == 2 }
            default: model.cancelCurrent()
            }
            await gate.release(0, with: answer)
            try await Task.sleep(for: .milliseconds(30))
            #expect(model.currentQuickResult == nil)
            if scenario == 3 {
                await gate.release(1, with: answer)
                try await wait { model.currentQuickResult != nil }
            }
        }
    }

    @Test func failedAnalysisRetriesOnlyItselfAndStatusCancelDoesNotCancelTranscription() async throws {
        let (model, gate) = try await delayed()
        model.startAnalysis(.quickTempo)
        try await wait { await gate.count() == 1 }
        #expect(!model.canStart)
        #expect(model.session.state == .idle)
        #expect(model.runPanel != nil)
        model.cancelCurrent()
        #expect(model.session.state == .idle)
        await gate.release(0, with: .quick(AudioTempoResult(candidates: [], beats: [])))
        model.startAnalysis(.quickTempo)
        try await wait { await gate.count() == 2 }
        await gate.fail(1)
        try await wait { model.failedAnalysis != nil }
        model.retryCurrent()
        try await wait { await gate.count() == 3 }
        #expect(model.session.state == .idle)
        await gate.release(2, with: .quick(AudioTempoResult(candidates: [], beats: [])))
        try await wait { model.analysisOperation == nil }
        model.start()
        #expect(model.session.isBusy)
        model.startAnalysis(.quickTempo)
        #expect(model.analysisOperation == nil)
        model.cancelCurrent()
    }

    @Test func cancelKeepsPreviousResultForSameIdentity() async throws {
        let (model, gate) = try await delayed()
        model.startAnalysis(.quickTempo)
        try await wait { await gate.count() == 1 }
        let original = TempoCandidate(bpm: 95, score: 0.9, relative: nil)
        await gate.release(0, with: .quick(AudioTempoResult(candidates: [original], beats: [0.3])))
        try await wait { model.currentQuickResult != nil }
        model.startAnalysis(.quickTempo)
        try await wait { await gate.count() == 2 }
        model.cancelCurrent()
        await gate.release(1, with: .quick(AudioTempoResult(candidates: [TempoCandidate(bpm: 120, score: 1, relative: nil)], beats: [0.1])))
        try await Task.sleep(for: .milliseconds(30))
        #expect(model.currentQuickResult?.candidates.first == original)
        model.document.slice.setEnd(18)
        model.sliceChanged()
        #expect(model.currentQuickResult == nil)
    }

    @Test func textAndPulseConversionUseTheChosenDenominator() {
        let candidate = TempoCandidate(bpm: 95, score: 0.87, relative: .half)
        #expect(TempoDetectionText.candidate(candidate) == "95 BPM · 87% · half time")
        #expect(TempoDetectionText.emptyPulse == "No clear pulse")
        #expect(TempoDetectionText.alignment(nil) == "No clear match")
        #expect(TempoDetectionText.alignment(OnsetAlignmentResult(lag: -0.025, matchedShare: 0.75, noteCount: 8)) ==
                "75% of notes sit on an audio onset, 25 ms early")
        #expect(TempoDetectionText.steadiness([0, 0.5, 1, 1.5]) == "Steady")
        #expect(TempoDetectionText.steadiness([0, 0.4, 0.9, 1.5]) .hasPrefix("Tempo varies ·"))
        #expect(TempoDetectionText.bpmOffer(pulseBPM: 120, denominator: 8).contains("60.0 BPM"))
        #expect(TempoDetectionText.bpmOffer(pulseBPM: 120, denominator: 4).contains("120.0 BPM"))
        let sixEight = MIDIGrid(bpm: 60, numerator: 6, denominator: 8)
        let threeEight = MIDIGrid(bpm: 60, numerator: 3, denominator: 8)
        let sixFour = MIDIGrid(bpm: 120, numerator: 6, denominator: 4)
        #expect(sixEight.secondsPerBar == 3 && threeEight.secondsPerBar == 1.5 && sixFour.secondsPerBar == 3)
        let segments = [BeatThisMeterMap.Segment(barIndex: 0, beatsPerBar: 4, startTime: 0.4),
                        BeatThisMeterMap.Segment(barIndex: 40, beatsPerBar: 3, startTime: 80.4)]
        #expect(TempoDetectionText.meter(segments, denominator: 4) == "4/4, then 3/4 from bar 41")
    }

    @Test func useAudioCandidateKeepsDenominatorAndOnlyChangesBPM() async throws {
        let (model, gate) = try await delayed()
        model.setGrid(MIDIGrid(bpm: 95, numerator: 6, denominator: 8), actionName: "Meter")
        model.startAnalysis(.quickTempo)
        try await wait { await gate.count() == 1 }
        let candidate = TempoCandidate(bpm: 120, score: 0.8, relative: nil)
        await gate.release(0, with: .quick(AudioTempoResult(candidates: [candidate], beats: [0.4])))
        try await wait { model.currentQuickResult != nil }
        model.useTempoFromAudio(candidate)
        #expect(model.grid.bpm == 60 && model.grid.meters[0].denominator == 8)
        #expect(model.document.slice.start == 0)
        #expect(model.startSliceAtFirstBeat() == .applied)
        #expect(model.document.slice.start == 0.4 && model.currentQuickResult == nil)
    }

    @Test func beatMapIsAtomicAndUnclearMapIsNotApplicable() async throws {
        let (model, _) = try await screen()
        let entry = try #require(model.beatThisEntry)
        try FileManager.default.createDirectory(at: model.store.directory, withIntermediateDirectories: true)
        // The injected worker never opens this size-correct placeholder; only the opt-in integration runs real weights.
        let placeholder = model.store.directory.appending(path: entry.fileName)
        #expect(FileManager.default.createFile(atPath: placeholder.path, contents: Data()))
        let handle = try FileHandle(forWritingTo: placeholder)
        try handle.truncate(atOffset: UInt64(entry.byteSize))
        try handle.close()
        model.store.refresh()
        model.undoManager.groupsByEvent = false
        model.undoManager.beginUndoGrouping()
        model.setGrid(MIDIGrid(bpm: 95, numerator: 6, denominator: 8), actionName: "Meter")
        model.undoManager.endUndoGrouping()
        let beats = (0..<24).map { 0.4 + Double($0) * 0.5 }
        let good = BeatThisResult(beats: beats, downbeats: [0.4, 3.4, 6.4, 9.4], beatLogits: [], downbeatLogits: [])
        model.analyzer = { _, _, _, _, _ in .beat(good) }
        model.startAnalysis(.beatThis)
        try await wait { model.currentBeatResult != nil }
        #expect(model.meterSuggestion?.grid.bpm == 60)
        #expect(model.meterSuggestion?.grid.secondsPerBar == 3)
        model.undoManager.beginUndoGrouping()
        #expect(model.useMeterMap() == .applied)
        model.undoManager.endUndoGrouping()
        #expect(model.grid.bpm == 60 && model.grid.meters[0].numerator == 6 && model.document.slice.start == 0.4)
        model.undoManager.undo()
        #expect(model.document.slice.start == 0 && model.grid.bpm == 95)
        model.undoManager.redo()
        #expect(model.document.slice.start == 0.4 && model.grid.bpm == 60)
        model.analyzer = { _, _, _, _, _ in .beat(BeatThisResult(beats: beats, downbeats: [], beatLogits: [], downbeatLogits: [])) }
        model.startAnalysis(.beatThis)
        try await wait { model.currentBeatResult?.downbeats.isEmpty == true }
        #expect(model.meterSuggestion == nil && model.useMeterMap() == .unavailable)
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().appending(path: "build/models/beat_this.onnx").path)))
    func installedBeatThisOperationProducesBeatsAndDiscardsStaleCompletion() async throws {
        let (model, _) = try await screen()
        let entry = try #require(model.beatThisEntry)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        try FileManager.default.createDirectory(at: model.store.directory, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: root.appending(path: "build/models/beat_this.onnx"),
                                         to: model.store.directory.appending(path: entry.fileName))
        model.store.refresh()
        model.document.document = try AudioDocument.load(url: root.appending(path: "Tests/Fixtures/BeatThis/beat_this_fixture.wav"))
        model.document.slice = AudioSlice(duration: model.document.document!.duration)
        model.documentChanged()
        model.startAnalysis(.beatThis)
        try await wait { model.currentBeatResult != nil || model.failedAnalysis != nil }
        #expect((model.currentBeatResult?.beats.count ?? 0) > 0)
        #expect((model.currentBeatResult?.downbeats.count ?? 0) > 0)
        model.startAnalysis(.beatThis)
        model.document.slice.setStart(0.4)
        model.sliceChanged()
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.currentBeatResult == nil)
    }

    /// The real helper on a real 15 s recording (the MuScriptor test excerpt in the Engine submodule): it finds a steady
    /// six-pulse bar, and with the denominator the user chose (8) the offer is 125 quarter-note BPM and a 1.44 s bar.
    @Test(.enabled(if: FileManager.default.fileExists(atPath: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().appending(path: "build/models/beat_this.onnx").path)
        && FileManager.default.fileExists(atPath: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Engine/muscriptor.cpp/testdata/audio/fixture_3chunks_16k.wav").path)))
    func installedBeatThisMapOnARealRecordingAppliesWhileIdle() async throws {
        let (model, _) = try await screen()
        let entry = try #require(model.beatThisEntry)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        try FileManager.default.createDirectory(at: model.store.directory, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: root.appending(path: "build/models/beat_this.onnx"),
                                         to: model.store.directory.appending(path: entry.fileName))
        model.store.refresh()
        model.document.document = try AudioDocument.load(url: root.appending(path: "Engine/muscriptor.cpp/testdata/audio/fixture_3chunks_16k.wav"))
        model.document.slice = AudioSlice(duration: model.document.document!.duration)
        model.documentChanged()
        model.setGrid(MIDIGrid(bpm: 120, numerator: 4, denominator: 8), actionName: "Meter")
        model.startAnalysis(.beatThis)
        try await wait { model.currentBeatResult != nil || model.failedAnalysis != nil }
        let result = try #require(model.currentBeatResult)
        #expect(result.beats.count > 40 && result.downbeats.count >= 8)
        let suggestion = try #require(model.meterSuggestion)
        #expect(abs(suggestion.grid.bpm - 125) < 1 && suggestion.grid.meters[0].numerator == 6 && suggestion.grid.meters[0].denominator == 8)
        #expect(abs(suggestion.grid.secondsPerBar - 1.44) < 0.03)
        #expect(model.useMeterMap() == .applied)
        #expect(abs(model.document.slice.start - suggestion.firstDownbeatTime) <= 0.01 && model.grid == suggestion.grid)
        #expect(model.currentBeatResult == nil, "beats are slice-dependent, so they are invalidated rather than rebased")
        model.undoManager.undo()
        #expect(model.document.slice.start == 0 && model.grid.bpm == 120)
    }

    /// Twenty seconds at 22,050 Hz and 95 BPM: loud quarter-note pitched tones cycle C4 E4 G4 E4,
    /// with a 4 ms attack and 0.12 s decay, plus quieter offbeat eighth notes a fifth higher.
    @Test func ownedFixtureRunsAllThreeAnalyzers() throws {
        let audio = try AudioDocument.load(url: tempoFixture)
        #expect(audio.samples.count == 20 * 22_050)
        let notes = try BasicPitchEngine().notes(samples: audio.samples)
        #expect(TempoFromNotes.mergedOnsets(notes.map(\.start)).count >= 8)
        let quick = try TempoFromAudio.detect(samples: audio.samples, sampleRate: audio.sampleRate)
        #expect(abs((quick.candidates.first?.bpm ?? 0) - 95) <= 1)
        #expect(TempoFromNotes.rank(onsets: notes.map(\.start), currentBPM: 95).contains { abs($0.bpm - 95) <= 1 })
        let alignment = try OnsetAlignment.check(onsets: notes.map(\.start), samples: audio.samples, sampleRate: audio.sampleRate)
        #expect((alignment?.matchedShare ?? 0) >= 0.5 && abs(alignment?.lag ?? 1) < 0.05)
    }
    private func screen() async throws -> (AudioScreenModel, URL) {
        let folder = FileManager.default.temporaryDirectory.appending(path: "tempo-screen-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let document = DocumentModel()
        document.open(tempoFixture)
        for _ in 0..<200 where document.document == nil { try await Task.sleep(for: .milliseconds(50)) }
        _ = try #require(document.document)
        let (defaults, _) = scratchDefaults("tempo-screen")
        let screen = AudioScreenModel(document: document, store: ModelStore(directory: folder.appending(path: "models")),
                                      session: TranscriptionSession(),
                                      access: AccessCoordinator(keychain: KeychainStore(service: "tempo-test-\(UUID().uuidString)")),
                                      preferences: AppPreferences(defaults: defaults), destination: { folder })
        screen.selectedModel = "basic-pitch"
        return (screen, folder)
    }

    @Test func headlessRunRegridsWithoutRetranscriptionAndKeepsNoteSeconds() async throws {
        let (model, folder) = try await screen()
        model.setGrid(MIDIGrid(bpm: 95, numerator: 3, denominator: 4), actionName: "Tempo")
        model.start()
        for _ in 0..<1200 where model.writer.status == .idle { try await Task.sleep(for: .milliseconds(50)) }
        guard case .saved(let url, let version, _) = model.writer.status else {
            Issue.record("Run did not save: \(model.writer.status)")
            return
        }
        #expect(version == 1 && url.deletingLastPathComponent().resolvingSymlinksInPath().path == folder.resolvingSymlinksInPath().path)
        let oldNotes = model.usableNotes
        #expect(!oldNotes.isEmpty)
        model.setBPM(92)
        let imported = try MIDIImporter.decode(Data(contentsOf: url))
        #expect(imported.grid == MIDIGrid(bpm: 92, numerator: 3, denominator: 4))
        #expect(imported.provenance?.version == 1 && imported.provenance?.edited == false)
        #expect(model.usableNotes == oldNotes)
        #expect(!model.summary.contains("transcribe again"))
        model.document.slice.setEnd(19)
        model.sliceChanged()
        #expect(model.resultIsCurrent && model.usableNotes == oldNotes)
    }

    @Test func originAndGridAreOneUndoStepAndClampedOriginIsRejected() async throws {
        let (model, _) = try await screen()
        let original = model.grid
        let mapped = MIDIGrid(bpm: 95, numerator: 3, denominator: 4)
        #expect(model.applyOrigin(absoluteStart: 0.4, grid: mapped, actionName: "Use map") == .applied)
        #expect(model.document.slice.start == 0.4 && model.grid == mapped)
        model.undoManager.undo()
        #expect(model.document.slice.start == 0 && model.grid == original)
        #expect(!model.undoManager.canUndo && model.undoManager.canRedo)
        model.undoManager.redo()
        #expect(model.document.slice.start == 0.4 && model.grid == mapped)
        #expect(!model.undoManager.canRedo)

        model.addMeterChange()
        let withChange = model.grid
        #expect(withChange.meters.count == 2)
        model.undoManager.undo()
        #expect(model.grid == mapped)
        model.undoManager.redo()
        #expect(model.grid == withChange)
        model.removeMeterChange(at: withChange.meters[1].bar)
        #expect(model.grid == mapped)
        model.undoManager.undo()
        #expect(model.grid == withChange)

        let before = model.document.slice.start
        let gridBefore = model.grid
        let canUndo = model.undoManager.canUndo
        #expect(model.applyOrigin(absoluteStart: model.document.slice.end - 0.1, grid: original, actionName: "Use map") == .unavailable)
        #expect(model.document.slice.start == before && model.grid == gridBefore)
        #expect(model.undoManager.canUndo == canUndo && model.originMessage != nil)
        model.documentChanged()
        #expect(model.grid == original && !model.undoManager.canUndo && !model.undoManager.canRedo)
    }

    @Test func completedRunBecomesUnusableOnOriginMoveAndSavedVersionStaysPut() async throws {
        let (model, _) = try await screen()
        model.start()
        for _ in 0..<1200 where model.writer.status == .idle { try await Task.sleep(for: .milliseconds(50)) }
        guard case .saved(let url, _, _) = model.writer.status else {
            Issue.record("Run did not save: \(model.writer.status)")
            return
        }
        let bytes = try Data(contentsOf: url)
        #expect(!model.usableNotes.isEmpty)
        #expect(model.applyOrigin(absoluteStart: 0.4, grid: MIDIGrid(bpm: 92, numerator: 3, denominator: 4), actionName: "Use map") == .applied)
        #expect(model.usableNotes.isEmpty)
        #expect(model.summary.contains("Bar 1 moved — transcribe again"))
        #expect(MIDIExport.item(notes: model.usableNotes, entry: nil, slice: model.document.slice, name: "take", grid: model.grid).notes.isEmpty)
        #expect(try Data(contentsOf: url) == bytes)
        for _ in 0..<100 where model.playback.scheduledNoteCount != 0 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(model.playback.scheduledNoteCount == 0)
        model.undoManager.undo()
        #expect(model.document.slice.start == 0 && !model.resultIsCurrent && model.usableNotes.isEmpty, "undoing the move does not bring the old notes back")
        #expect(try Data(contentsOf: url) == bytes)
    }

    @Test func originMoveDuringActiveRunCancelsAndFailedSaveLosesRetry() async throws {
        let (model, _) = try await screen()
        model.start()
        #expect(model.session.isBusy)
        #expect(model.applyOrigin(absoluteStart: 0.4, grid: nil, actionName: "Start bar 1") == .applied)
        #expect(!model.session.isBusy && !model.resultIsCurrent && model.usableNotes.isEmpty)
        #expect(model.writer.status != .idle || model.session.state == .cancelled)

        let (failed, _) = try await screen()
        // A missing destination reproduces a failed first save without an OS-dependent permission race.
        let noFolder = AudioScreenModel(document: failed.document, store: failed.store, session: TranscriptionSession(),
                                        access: failed.access, preferences: AppPreferences(defaults: scratchDefaults("tempo-fail").defaults))
        noFolder.selectedModel = "basic-pitch"
        noFolder.start()
        for _ in 0..<1200 where noFolder.session.isBusy || noFolder.writer.status == .idle {
            try await Task.sleep(for: .milliseconds(50))
        }
        guard case .failed = noFolder.writer.status else {
            Issue.record("Expected failed save: \(noFolder.writer.status)")
            return
        }
        _ = noFolder.applyOrigin(absoluteStart: 0.4, grid: nil, actionName: "Start bar 1")
        #expect(noFolder.writer.status == .idle)
        noFolder.retrySave()
        #expect(noFolder.writer.status == .idle)
    }

    @Test func nonzeroOriginAndExternalSliceChangesInvalidateWithoutRewriting() async throws {
        let (model, _) = try await screen()
        model.document.slice.setStart(1.2)
        model.sliceChanged()
        model.start()
        for _ in 0..<1200 where model.writer.status == .idle { try await Task.sleep(for: .milliseconds(50)) }
        guard case .saved(let url, _, _) = model.writer.status else {
            Issue.record("Run did not save: \(model.writer.status)")
            return
        }
        let bytes = try Data(contentsOf: url)
        #expect(model.resultIsCurrent)
        #expect(model.applyOrigin(absoluteStart: 1.6, grid: nil, actionName: "Start bar 1") == .applied)
        #expect(!model.resultIsCurrent && model.usableNotes.isEmpty)
        model.setBPM(92)
        #expect(try Data(contentsOf: url) == bytes)
        model.document.slice.setStart(1.8)
        model.sliceChanged()
        #expect(model.usableNotes.isEmpty)
        model.document.slice.setStart(1.2)
        model.sliceChanged()
        #expect(!model.resultIsCurrent && model.usableNotes.isEmpty, "returning to the run's origin does not revive invalidated notes")
        #expect(try Data(contentsOf: url) == bytes)
        model.start()
        for _ in 0..<1200 where model.session.isBusy || model.writer.status == .idle { try await Task.sleep(for: .milliseconds(50)) }
        #expect(model.resultIsCurrent, "a new run makes the result current again")
    }
}
