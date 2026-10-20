import SwiftUI

/// State shared by the Audio screen and its inspector.
@MainActor @Observable
final class AudioScreenModel {
    /// What the status panel shows above the roll.
    enum RunPanel: Equatable {
        case running(title: String, steps: [String], current: Int, fraction: Double?)
        case failed(title: String, message: String)
    }

    /// What the last run used, for the result summary and to notice that the settings changed since.
    struct RunRecord: Equatable {
        var modelID: String
        var modelName: String
        var start: Double
        var end: Double
        var instruments: Set<String>
        var estimatesVelocity: Bool
        var separatedDrums = false
        /// Whole seconds from pressing Transcribe to the end, download included.
        var took: Int?
    }

    let document: DocumentModel
    let store: ModelStore
    let session: TranscriptionSession
    let access: AccessCoordinator
    let firstUse: FirstUseTranscription
    let writer = TranscriptionWriter()
    let playback = PlaybackEngine()
    var undoManager = UndoManager()
    private(set) var grid: MIDIGrid
    @ObservationIgnored private let preferences: AppPreferences
    private(set) var originMessage: String?
    enum OriginResult: Equatable { case applied, unavailable }
    @ObservationIgnored private var observedOrigin: Double
    @ObservationIgnored private var observedSlice: AudioSlice

    enum AnalysisOperation: Equatable { case quickTempo, beatThis, alignment, beatThisDownload }
    struct AnalysisIdentity: Equatable, Sendable {
        let source: URL
        let start: Double
        let end: Double
        let noteRevision: Int
        let resultIsCurrent: Bool
    }
    enum AnalysisValue: Sendable {
        case quick(AudioTempoResult)
        case beat(BeatThisResult)
        case alignment(OnsetAlignmentResult?)
    }
    /// Injected workers make cancellation and late completions deterministic in tests.
    @ObservationIgnored var analyzer: (@Sendable (AnalysisOperation, [Float], Double, [NoteEvent], URL?) async throws -> AnalysisValue)?
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var noteRevision = 0
    @ObservationIgnored private var observedNoteCount = 0
    private(set) var analysisOperation: AnalysisOperation?
    private(set) var failedAnalysis: (operation: AnalysisOperation, message: String)?
    private(set) var analysisProgress = 0.0
    private var quickResult: (identity: AnalysisIdentity, value: AudioTempoResult)?
    private var beatResult: (identity: AnalysisIdentity, value: BeatThisResult)?
    private var alignmentResult: (identity: AnalysisIdentity, value: OnsetAlignmentResult?)?

    var analysisIdentity: AnalysisIdentity? {
        guard let audio = document.document else { return nil }
        return AnalysisIdentity(source: audio.url, start: document.slice.start, end: document.slice.end,
                                noteRevision: noteRevision, resultIsCurrent: resultIsCurrent)
    }
    func notesChanged() {
        guard observedNoteCount != session.notes.count else { return }
        observedNoteCount = session.notes.count
        noteRevision += 1
        alignmentResult = nil
        cancelAnalysis()
    }
    var currentQuickResult: AudioTempoResult? { quickResult?.identity == analysisIdentity ? quickResult?.value : nil }
    var currentBeatResult: BeatThisResult? { beatResult?.identity == analysisIdentity ? beatResult?.value : nil }
    var currentAlignment: OnsetAlignmentResult?? { alignmentResult?.identity == analysisIdentity ? alignmentResult?.value : nil }
    var detectedBeats: [(time: Double, isDownbeat: Bool)] {
        guard let identity = analysisIdentity else { return [] }
        if let beat = currentBeatResult {
            return beat.beats.map { pulse in (identity.start + pulse, beat.downbeats.contains { abs($0 - pulse) < 0.04 }) }
        }
        return (currentQuickResult?.beats ?? []).map { (identity.start + $0, false) }
    }
    var beatThisEntry: ModelEntry? { ModelCatalog.entry(id: ModelCatalog.beatThisID) }
    var beatThisInstalled: Bool { beatThisEntry.flatMap { store.installedURL(for: $0) } != nil }
    var canAnalyze: Bool { document.document != nil && !session.isBusy && !isPreparing && analysisOperation == nil && !otherRunInProgress() }
    var analysisBlocker: String? {
        if document.document == nil { return "Open audio to analyse its tempo." }
        if session.isBusy || isPreparing || otherRunInProgress() { return "Wait for transcription or model preparation to finish." }
        if analysisOperation != nil { return "Wait for the current analysis to finish, or cancel it." }
        return nil
    }

    var selectedModel: ModelEntry.ID? {
        didSet { downloadFailure = nil }
    }
    var deviceIndex: Int?
    var threads = max(1, ProcessInfo.processInfo.activeProcessorCount / 2)
    var chosenInstruments: Set<String> = []
    var hiddenInstruments: Set<String> = []
    /// Muting affects playback only; hiding takes notes out of the roll and playback.
    var mutedInstruments: Set<String> = []
    var estimateVelocity = true
    /// Isolate the drums with the HT-Demucs helper before a drum model listens.
    var separateDrums = false
    var pixelsPerSecond: CGFloat = Metric.ppsDefault
    var showExport = false
    private(set) var keyFromAudio: [KeyMatch] = []
    private(set) var isDetectingKey = false
    private(set) var devices: [EngineDevice] = []
    private(set) var instruments: [EngineInstrument] = []
    private(set) var engine: EngineProcess?
    private(set) var engineProblem: String?
    private(set) var startedAt: Date?
    private(set) var downloadFailure: (entry: ModelEntry, message: String)?
    /// The failed panel was dismissed; it stays hidden until the next run.
    private(set) var failureDismissed = false
    private(set) var ran: RunRecord?
    /// Both of these decide what the screen shows (the download panel, the button), so they are observed: when a
    /// preparation ends without anything else changing, the screen has to redraw.
    private var includesDownload: ModelEntry?
    private var prepareTask: Task<Void, Never>?
    /// The run in flight; it is consumed by the first terminal state, so a run is saved once.
    @ObservationIgnored private var run: TranscriptionWriter.Run?
    @ObservationIgnored private let destination: () -> URL?
    @ObservationIgnored private let references: () -> [AudioReference]
    @ObservationIgnored private let onSaved: () -> Void
    /// True while a run for another audio file is going in the background. One run at a time keeps the machine usable.
    @ObservationIgnored var otherRunInProgress: () -> Bool = { false }

    /// `destination` is the MIDI folder to save results in; `onSaved` lets the library pick the new file up.
    init(document: DocumentModel, store: ModelStore, session: TranscriptionSession, access: AccessCoordinator,
         preferences: AppPreferences, settle: Duration = .milliseconds(400), destination: @escaping () -> URL? = { nil },
         references: @escaping () -> [AudioReference] = { [] }, onSaved: @escaping () -> Void = {}) {
        self.document = document
        self.store = store
        self.session = session
        self.access = access
        self.destination = destination
        self.references = references
        self.onSaved = onSaved
        self.preferences = preferences
        grid = preferences.defaultGrid
        observedOrigin = document.slice.start
        observedSlice = document.slice
        firstUse = FirstUseTranscription(installer: store, settle: settle)
        selectedModel = preferences.defaultModelID
        playback.grid = grid
        observeSession()
    }

    /// Watches the session for the end of a run. This lives on the model, not on a view, so a run that finishes
    /// while another screen is showing is still saved.
    private func observeSession() {
        withObservationTracking {
            _ = session.state
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.sessionStateChanged()
                self?.observeSession()
            }
        }
    }

    func sessionStateChanged() {
        switch session.state {
        case .done, .cancelled, .failed:
            if ran?.took == nil, let startedAt { ran?.took = Int(Date().timeIntervalSince(startedAt).rounded()) }
        case .idle, .loading, .running, .refining:
            break
        }
        guard let run else { return }
        switch session.state {
        case .done, .cancelled:
            self.run = nil
            noteRevision += 1
            writer.finish(session.state, notes: session.notes, run: run, folder: destination())
            debugLog(.library, "Result of \"\(run.title)\": \(writer.status)")
            if case .saved = writer.status { onSaved() }
        case .failed:
            self.run = nil
        case .idle, .loading, .running, .refining:
            break
        }
    }

    func retrySave() {
        writer.retry(folder: destination())
        if case .saved = writer.status { onSaved() }
    }

    /// Set once the slice origin moves after a run, and cleared only by a new run or another recording: the notes were
    /// placed against the old origin, so undoing the move does not bring them back.
    private(set) var resultInvalidated = false

    var resultIsCurrent: Bool { ran != nil && !resultInvalidated && ran?.start == document.slice.start }
    var usableNotes: [NoteEvent] { resultIsCurrent ? session.notes : [] }

    func setGrid(_ new: MIDIGrid, actionName: String) {
        guard grid != new else { return }
        let previous = grid
        undoManager.registerUndo(withTarget: self) { model in model.setGrid(previous, actionName: actionName) }
        undoManager.setActionName(actionName)
        grid = new
        gridDidChange(from: previous, to: new)
    }

    func setBPM(_ bpm: Double) {
        setGrid(MIDIGrid(bpm: bpm, meters: grid.meters), actionName: "Change tempo")
    }

    func addMeterChange() {
        guard grid.meters.count < 256, let last = grid.meters.last, last.bar < Int.max else { return }
        setGrid(MIDIGrid(bpm: grid.bpm, meters: grid.meters + [MeterChange(bar: last.bar + min(8, Int.max - last.bar),
                                                                           numerator: last.numerator, denominator: last.denominator)]),
                actionName: "Add meter change")
    }

    func removeMeterChange(at bar: Int) {
        guard bar > 0, grid.meters.contains(where: { $0.bar == bar }) else { return }
        setGrid(MIDIGrid(bpm: grid.bpm, meters: grid.meters.filter { $0.bar != bar }), actionName: "Remove meter change")
    }

    private func gridDidChange(from old: MIDIGrid, to new: MIDIGrid) {
        playback.grid = new
        run?.grid = new
        writer.updatePendingGrid(new)
        if resultIsCurrent, case .saved = writer.status {
            if writer.regrid(to: new) == .updated { onSaved() }
        }
    }

    /// Called for waveform slice changes as well as atomic origin actions. Stage 2 cancels slice-dependent analyses here.
    func sliceChanged() {
        guard observedSlice != document.slice else { return }
        observedSlice = document.slice
        // A helper download does not depend on the slice, so moving the slice leaves it running.
        if analysisOperation != .beatThisDownload { cancelAnalysis() }
        if failedAnalysis?.operation != .beatThisDownload { failedAnalysis = nil }
        guard observedOrigin != document.slice.start else { return }
        observedOrigin = document.slice.start
        if session.isBusy || prepareTask != nil {
            cancel()
            sessionStateChanged()
        }
        if let ran, ran.start != document.slice.start { resultInvalidated = true }
        writer.discardPending()
        playback.replace(notes: usableNotes)
    }

    /// Changes the audio origin and optional meter together as one undo action, without reusing old-origin notes.
    @discardableResult
    func applyOrigin(absoluteStart requested: Double, grid newGrid: MIDIGrid?, actionName: String) -> OriginResult {
        if session.isBusy || prepareTask != nil {
            cancel()
            sessionStateChanged()
        }
        let oldStart = document.slice.start
        let oldGrid = grid
        document.slice.setStart(requested)
        guard requested.isFinite, abs(document.slice.start - requested) <= 0.010 else {
            document.slice.setStart(oldStart)
            originMessage = "Bar 1 would start too close to the end of the slice."
            return .unavailable
        }
        originMessage = nil
        let target = newGrid ?? grid
        guard oldStart != document.slice.start || oldGrid != target else { return .applied }
        undoManager.registerUndo(withTarget: self) { model in
            _ = model.applyOrigin(absoluteStart: oldStart, grid: oldGrid, actionName: actionName)
        }
        undoManager.setActionName(actionName)
        let moved = oldStart != document.slice.start
        if moved { sliceChanged() }
        if oldGrid != target {
            grid = target
            if moved {
                playback.grid = target
                run?.grid = target
                writer.updatePendingGrid(target)
            } else {
                gridDidChange(from: oldGrid, to: target)
            }
        }
        if moved { prepareOriginal() }
        return .applied
    }

    var selectedEntry: ModelEntry? {
        ModelCatalog.entries.first { $0.id == selectedModel }
    }

    var presentInstruments: [String] {
        Array(Set(session.notes.map(\.instrument))).sorted()
    }

    /// Each instrument in the result with its note count, in name order.
    var instrumentCounts: [(name: String, count: Int)] {
        Dictionary(grouping: session.notes, by: \.instrument).map { ($0.key, $0.value.count) }.sorted { $0.name < $1.name }
    }

    /// Drum hits in the result per kit piece, for the legend.
    var drumPieceCounts: [(piece: DrumPiece, count: Int)] {
        DrumKit.counts(pitches: session.notes.lazy.filter(\.isDrum).map(\.pitch))
    }

    /// Playback groups to switch off for muted or hidden instruments. No note is changed.
    var silencedGroups: Set<String> {
        let off = mutedInstruments.union(hiddenInstruments)
        return Set(session.notes.filter { off.contains($0.instrument) }.map(PlaybackEngine.groupKey))
    }

    /// Basic Pitch reports one undifferentiated track, which the handoff draws in the neutral colour.
    var usesNeutralColour: Bool { (ran?.modelID ?? selectedModel) == AppPreferences.fallbackModelID }

    /// The model, slice, instruments or velocity setting differ from the run that produced the notes on screen.
    var settingsChanged: Bool {
        guard let ran else { return false }
        if ran.modelID != selectedModel || ran.start != document.slice.start || ran.end != document.slice.end { return true }
        if selectedEntry?.isDrumModel == true, ran.separatedDrums != usesSeparator { return true }
        guard selectedEntry?.engine == .muscriptor else { return false }
        return ran.instruments != chosenInstruments || ran.estimatesVelocity != estimateVelocity
    }

    var summary: String {
        let text = Self.summary(state: session.state, noteCount: session.notes.count, instrumentCount: Set(session.notes.map(\.instrument)).count,
                                ran: ran, changed: settingsChanged)
        return ran != nil && !resultIsCurrent ? text + " · Bar 1 moved — transcribe again" : text
    }

    /// The footer's run summary, in the handoff's wording.
    static func summary(state: TranscriptionSession.State, noteCount: Int, instrumentCount: Int, ran: RunRecord?, changed: Bool) -> String {
        let range = ran.map { String(format: "%.1f\u{2013}%.1f s", $0.start, $0.end) } ?? ""
        switch state {
        case .loading, .running, .refining:
            guard let ran else { return "Transcribing\u{2026}" }
            return "Transcribing \(range) with \(ran.modelName)\u{2026}"
        case .idle, .done, .cancelled, .failed:
            guard noteCount > 0, let ran else { return "No notes yet" }
            var text: String
            if case .done = state {
                text = "Done \u{2014} \(noteCount) notes \u{00B7} "
            } else {
                text = "Cancelled \u{2014} partial notes kept \u{00B7} "
            }
            text += "\(instrumentCount) \(instrumentCount == 1 ? "instrument" : "instruments") \u{00B7} \(range) \u{00B7} \(ran.modelName)"
            if let took = ran.took { text += " \u{00B7} \(took) s" }
            if changed { text += " \u{00B7} Changed \u{2014} transcribe again to apply" }
            return text
        }
    }

    var separatorEntry: ModelEntry? { ModelCatalog.entry(id: ModelCatalog.separatorID) }
    var usesSeparator: Bool { separateDrums && selectedEntry?.isDrumModel == true }

    /// The models a run needs, in the order they are fetched: the separator first.
    private func requiredModels(for entry: ModelEntry) -> [ModelEntry] {
        (usesSeparator ? [separatorEntry].compactMap { $0 } : []) + [entry]
    }

    var isPreparing: Bool { prepareTask != nil }

    /// Why Transcribe is unavailable even though a file is open, for its tooltip.
    var startBlocker: String? {
        if analysisOperation != nil { return "Wait for the current audio analysis to finish, or cancel it." }
        return otherRunInProgress() ? "Another file is still being transcribed. Wait for it to finish, or open it and press Cancel." : nil
    }

    var canStart: Bool {
        guard document.document != nil, !session.isBusy, !isPreparing, analysisOperation == nil, !otherRunInProgress(), let entry = selectedEntry else { return false }
        guard requiredModels(for: entry).allSatisfy({ store.state(for: $0) == .installed || $0.downloadURL != nil }) else { return false }
        return entry.engine != .muscriptor || engine != nil
    }

    var transcribeLabel: String {
        if session.isBusy || isPreparing { return "Transcribing…" }
        guard let entry = selectedEntry else { return "Transcribe" }
        if requiredModels(for: entry).contains(where: { store.state(for: $0) != .installed }) { return "Download & Transcribe" }
        switch session.state {
        case .done, .cancelled: return "Transcribe Again"
        default: return "Transcribe"
        }
    }

    var runPanel: RunPanel? {
        if let failedAnalysis, !failureDismissed {
            let title: String
            switch failedAnalysis.operation {
            case .beatThisDownload: title = "Beat This! download failed"
            case .alignment: title = "Alignment check failed"
            case .quickTempo, .beatThis: title = "Beat analysis failed"
            }
            return .failed(title: title, message: failedAnalysis.message)
        }
        if let analysisOperation {
            if analysisOperation == .beatThisDownload, let entry = beatThisEntry {
                switch store.state(for: entry) {
                case .downloading(let fraction): return .running(title: Self.downloadTitle(entry, fraction: fraction), steps: ["Download", "Verify SHA-256"], current: 0, fraction: fraction)
                case .verifying: return .running(title: "Verifying Beat This!", steps: ["Download", "Verify SHA-256"], current: 1, fraction: nil)
                default: return .running(title: Self.downloadTitle(entry, fraction: 0), steps: ["Download", "Verify SHA-256"], current: 0, fraction: nil)
                }
            }
            let title = analysisOperation == .alignment ? "Checking alignment…" : "Finding the beat…"
            return .running(title: title, steps: [analysisOperation == .alignment ? "Check alignment" : "Analyse audio"], current: 0,
                            fraction: analysisOperation == .beatThis && analysisProgress > 0 ? analysisProgress : nil)
        }
        if let failure = downloadFailure {
            return .failed(title: "Couldn\u{2019}t download \(failure.entry.displayName)", message: failure.message)
        }
        var steps: [String] = []
        var offset = 0
        if let entry = includesDownload {
            steps = ["Download \(entry.sizeText)", "Verify SHA-256"]
            offset = 2
        }
        let load = selectedEntry?.engine == .handPercussion ? 0 : 1
        if load == 1 { steps += ["Load model"] }
        if usesSeparator { steps.append("Separate drums") }
        steps.append("Transcribe")
        if estimateVelocity, selectedEntry?.canEstimateVelocity == true { steps.append("Estimate velocity") }
        if isPreparing, let entry = includesDownload {
            switch store.state(for: entry) {
            case .downloading(let value):
                return .running(title: Self.downloadTitle(entry, fraction: value), steps: steps, current: 0, fraction: value)
            case .verifying: return .running(title: "Verifying download (SHA-256)", steps: steps, current: 1, fraction: nil)
            default: return .running(title: Self.downloadTitle(entry, fraction: 0), steps: steps, current: 0, fraction: nil)
            }
        }
        switch session.state {
        case .loading(let value): return .running(title: "Loading model", steps: steps, current: offset, fraction: value)
        case .running:
            let separating = usesSeparator && session.progress < DrumOnnxEngine.separationShare
            let label = separating ? "Separating drums" : "Transcribing"
            let title = session.progress > 0.15 ? session.eta.map { "\(label), about \(Int($0.rounded(.up))) s left" } ?? label : label
            return .running(title: title, steps: steps, current: offset + load + (usesSeparator && !separating ? 1 : 0), fraction: session.progress)
        case .refining: return .running(title: "Estimating velocity", steps: steps, current: offset + load + (usesSeparator ? 1 : 0) + 1, fraction: nil)
        case .failed(let message): return failureDismissed ? nil : .failed(title: "Transcription failed", message: message)
        default: return nil
        }
    }

    /// `Downloading {model} · {n} of {size}`, with n in the size's unit like the prototype (\u{201C}42 of 209 MB\u{201D}).
    static func downloadTitle(_ entry: ModelEntry, fraction: Double) -> String {
        let megabytes = Double(entry.byteSize) / 1_000_000
        return "Downloading \(entry.displayName) \u{00B7} \(Int((min(max(fraction, 0), 1) * megabytes).rounded())) of \(entry.sizeText)"
    }

    func loadEngineInfo() async {
        guard engine == nil || engineProblem != nil else { return }
        engineProblem = nil
        do {
            let process = EngineProcess(executable: try EngineLocator.locate())
            engine = process
            devices = try await process.devices()
            instruments = try await process.instruments()
            #if arch(x86_64)
            deviceIndex = devices.first { $0.backend == "CPU" }?.index
            #endif
        } catch {
            engineProblem = error.localizedDescription
            debugLog(.engine, "The engine isn\u{2019}t available: \(String(reflecting: error))")
        }
    }

    func audioForKey() -> (samples: [Float], rate: Double)? {
        guard let audio = document.document else { return nil }
        return (document.slice.cut(audio.samples, sampleRate: audio.sampleRate), audio.sampleRate)
    }

    func prepareOriginal() {
        guard let audio = document.document else { return }
        playback.grid = grid
        playback.duration = document.slice.span
        playback.setOriginal(samples: document.slice.cut(audio.samples, sampleRate: audio.sampleRate), sampleRate: audio.sampleRate)
    }

    /// Moves the playhead within the slice.
    func seek(to seconds: Double) {
        playback.duration = document.slice.span
        playback.seek(to: seconds)
    }

    func togglePlayback() {
        if playback.isPlaying {
            playback.pause()
        } else {
            prepareOriginal()
            playback.play()
        }
    }

    func clearKeyFromAudio() {
        keyFromAudio = []
    }

    /// Another audio file is open, so the notes, summary and save line on screen belonged to the last one.
    /// A run still going is cancelled first and its partial notes are saved for the file it was transcribing.
    func documentChanged() {
        debugLog(.audio, "The screen now shows \"\(document.document?.url.lastPathComponent ?? "nothing")\"; the previous result is cleared.")
        if session.isBusy || prepareTask != nil {
            cancel()
            sessionStateChanged()
        }
        cancelAnalysis()
        noteRevision += 1
        quickResult = nil
        beatResult = nil
        alignmentResult = nil
        failedAnalysis = nil
        run = nil
        ran = nil
        resultInvalidated = false
        startedAt = nil
        includesDownload = nil
        downloadFailure = nil
        failureDismissed = false
        hiddenInstruments = []
        mutedInstruments = []
        writer.reset()
        session.clear()
        observedNoteCount = 0
        clearKeyFromAudio()
        // Stage 2 cancels detached tempo/alignment analysis here.
        undoManager.removeAllActions(withTarget: self)
        grid = preferences.defaultGrid
        playback.grid = grid
        observedOrigin = document.slice.start
        observedSlice = document.slice
        originMessage = nil
        playback.replace(notes: [])
    }

    /// Ranks the keys of the selected slice of the audio itself.
    func detectKeyFromAudio() {
        guard !isDetectingKey, let audio = audioForKey() else { return }
        isDetectingKey = true
        Task {
            let result = await Task.detached { KeyDetector.rank(samples: audio.samples, sampleRate: audio.rate) }.value
            keyFromAudio = result
            isDetectingKey = false
        }
    }

    /// Hides the failed panel and the library row's warning until the next run. The notes on screen stay.
    func dismissFailure() {
        downloadFailure = nil
        failureDismissed = true
    }

    func cancelCurrent() {
        if analysisOperation != nil { cancelAnalysis() } else { cancel() }
    }

    func retryCurrent() {
        if let failedAnalysis {
            let operation = failedAnalysis.operation
            self.failedAnalysis = nil
            startAnalysis(operation)
        } else { start() }
    }

    private func cancelAnalysis() {
        generation += 1
        worker?.cancel()
        worker = nil
        if analysisOperation == .beatThisDownload {
            firstUse.answerConsent(false)
            access.finish(agreed: false)
        }
        analysisOperation = nil
    }

    func startAnalysis(_ operation: AnalysisOperation) {
        guard canAnalyze, let identity = analysisIdentity, let audio = audioForKey() else { return }
        if operation == .alignment && (!resultIsCurrent || TempoFromNotes.mergedOnsets(usableNotes.map(\.onset)).count < 8) { return }
        if operation == .beatThisDownload {
            guard let entry = beatThisEntry, !beatThisInstalled else { return }
            failedAnalysis = nil
            failureDismissed = false
            analysisOperation = operation
            generation += 1
            let request = generation
            worker = Task { [weak self] in
                guard let self else { return }
                let outcome = await firstUse.prepare(entry)
                guard request == generation else { return }
                worker = nil
                analysisOperation = nil
                if case .failed(let message) = outcome { failedAnalysis = (operation, message) }
            }
            return
        }
        let modelURL = operation == .beatThis ? beatThisEntry.flatMap { store.installedURL(for: $0) } : nil
        if operation == .beatThis && modelURL == nil { return }
        let notes = usableNotes
        let injected = analyzer
        failedAnalysis = nil
        failureDismissed = false
        analysisOperation = operation
        analysisProgress = 0
        generation += 1
        let request = generation
        let samples = audio.samples
        let rate = audio.rate
        worker = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                try Task.checkCancellation()
                let value: AnalysisValue
                if let injected { value = try await injected(operation, samples, rate, notes, modelURL) }
                else {
                    switch operation {
                    case .quickTempo: value = .quick(try TempoFromAudio.detect(samples: samples, sampleRate: rate))
                    case .alignment: value = .alignment(try OnsetAlignment.check(notes: notes, samples: samples, sampleRate: rate))
                    case .beatThis:
                        let result = try BeatThisEngine(modelURL: modelURL!).track(samples: samples, sampleRate: rate) { fraction in
                            Task { @MainActor [weak self] in
                                guard let self, request == self.generation else { return }
                                self.analysisProgress = fraction
                            }
                        }
                        value = .beat(result)
                    case .beatThisDownload: return
                    }
                }
                try Task.checkCancellation()
                await MainActor.run {
                    guard let self, request == self.generation else { return }
                    self.worker = nil
                    self.analysisOperation = nil
                    guard self.analysisIdentity == identity else { return }
                    switch value {
                    case .quick(let result): self.quickResult = (identity, result)
                    case .beat(let result): self.beatResult = (identity, result)
                    case .alignment(let result): self.alignmentResult = (identity, result)
                    }
                }
            } catch {
                await MainActor.run {
                    guard let self, request == self.generation else { return }
                    self.worker = nil
                    self.analysisOperation = nil
                    guard self.analysisIdentity == identity, !(error is CancellationError) else { return }
                    self.failedAnalysis = (operation, error.localizedDescription)
                }
            }
        }
    }

    func detectTempoFromAudio() { startAnalysis(beatThisInstalled ? .beatThis : .quickTempo) }
    func useTempoFromNotes(_ candidate: TempoCandidate) {
        setGrid(MIDIGrid(bpm: candidate.bpm, meters: grid.meters), actionName: "Use tempo from notes")
    }
    func useTempoFromAudio(_ candidate: TempoCandidate) {
        guard currentQuickResult?.candidates.contains(candidate) == true else { return }
        setGrid(MIDIGrid(bpm: candidate.bpm * 4 / Double(grid.meters[0].denominator), meters: grid.meters), actionName: "Use tempo from audio")
    }
    func useBeatThisBPM() {
        guard let beats = currentBeatResult?.beats, beats.count >= 2 else { return }
        let periods = zip(beats, beats.dropFirst()).map { $1 - $0 }.sorted()
        guard let middle = periods.indices.contains(periods.count / 2) ? periods[periods.count / 2] : nil, middle > 0 else { return }
        let bpm = 60 / middle
        setGrid(MIDIGrid(bpm: bpm * 4 / Double(grid.meters[0].denominator), meters: grid.meters), actionName: "Use tempo from audio")
    }
    var meterSuggestion: BeatThisMeterMap.Suggestion? {
        currentBeatResult?.meterMap?.suggestion(denominator: grid.meters[0].denominator)
    }
    @discardableResult func useMeterMap() -> OriginResult {
        guard let suggestion = meterSuggestion, let identity = analysisIdentity else { return .unavailable }
        return applyOrigin(absoluteStart: identity.start + suggestion.firstDownbeatTime, grid: suggestion.grid, actionName: "Use meter map")
    }
    @discardableResult func startSliceAtFirstBeat() -> OriginResult {
        guard let identity = analysisIdentity, let beat = currentBeatResult?.beats.first ?? currentQuickResult?.beats.first else { return .unavailable }
        return applyOrigin(absoluteStart: identity.start + beat, grid: nil, actionName: "Start slice at first beat")
    }

    /// Stops a run, a download, or a wait on the first-use alert or the licence sheet.
    func cancel() {
        debugLog(.transcription, "Cancel pressed (\(session.isBusy ? "run going" : prepareTask != nil ? "preparing the model" : "nothing running")).")
        prepareTask?.cancel()
        firstUse.answerConsent(false)
        access.finish(agreed: false)
        session.cancel()
    }

    /// Transcribes the slice, first fetching the model when it isn't on the disk yet.
    func start() {
        guard canStart, let entry = selectedEntry else { return }
        debugLog(.transcription, "Transcribe pressed on \"\(document.document?.url.lastPathComponent ?? "?")\": \(entry.displayName), "
                 + String(format: "slice %.2f\u{2013}%.2f s, ", document.slice.start, document.slice.end)
                 + "threads \(threads), device \(deviceIndex.map(String.init) ?? "auto"), "
                 + "instruments \(chosenInstruments.isEmpty ? "automatic" : chosenInstruments.sorted().joined(separator: ", ")), "
                 + "velocity \(estimateVelocity ? "on" : "off"), model \(store.state(for: entry) == .installed ? "installed" : "to download").")
        if let warning = entry.memoryWarning() { debugLog(.memory, "\(warning) The app uses \(DebugLog.footprint()).") }
        downloadFailure = nil
        failureDismissed = false
        startedAt = Date()
        let missing = requiredModels(for: entry).filter { store.state(for: $0) != .installed }
        if missing.isEmpty {
            includesDownload = nil
            launch(entry)
            return
        }
        prepareTask = Task { [weak self] in
            guard let self else { return }
            for model in missing {
                includesDownload = model
                let outcome = await firstUse.prepare(model)
                debugLog(.models, "Getting \(model.displayName) ready: \(outcome)")
                switch outcome {
                case .ready: continue
                case .cancelled: includesDownload = nil
                case .failed(let message):
                    downloadFailure = (model, message)
                    includesDownload = nil
                }
                prepareTask = nil
                return
            }
            launch(entry)
            prepareTask = nil
        }
    }

    private func launch(_ entry: ModelEntry) {
        guard let audio = document.document else { return }
        run = TranscriptionWriter.Run(source: audio.url, sourceID: TranscriptionWriter.sourceIdentifier(for: audio.url, references: references()),
                                      title: audio.name, modelID: entry.id, notice: entry.exportNotice, slice: document.slice, grid: grid)
        ran = RunRecord(modelID: entry.id, modelName: entry.displayName, start: document.slice.start, end: document.slice.end,
                        instruments: chosenInstruments, estimatesVelocity: estimateVelocity, separatedDrums: usesSeparator, took: nil)
        resultInvalidated = false
        noteRevision += 1
        alignmentResult = nil
        writer.reset()
        session.label = audio.url.lastPathComponent
        let samples = document.slice.cut(audio.samples, sampleRate: audio.sampleRate)
        let rate = audio.sampleRate
        debugLog(.transcription, "Starting \(entry.displayName) on \(samples.count) samples at \(Int(rate)) Hz.")
        let device = deviceIndex.map(String.init) ?? "auto"
        let names = chosenInstruments.sorted()
        let count = threads
        if entry.engine == .basicPitch {
            session.start { BasicPitchEngine().stream(samples: samples, sourceRate: rate) }
            return
        }
        /// Estimates velocity from the audio for the models that report none, when the user left that on.
        func velocityRefinement(_ audio16: Task<[Float], Error>) -> (@Sendable ([NoteEvent]) async -> [NoteEvent])? {
            guard estimateVelocity, entry.canEstimateVelocity else { return nil }
            return { (notes: [NoteEvent]) async -> [NoteEvent] in
                guard let audio = try? await audio16.value else { return notes }
                return await Task.detached { VelocityEstimator.estimate(notes: notes, samples: audio, sampleRate: 16000) }.value
            }
        }
        if entry.engine == .handPercussion {
            let audio16 = Task.detached { try Resampler.resample(samples, from: rate, to: 16000) }
            let hands = HandPercussionEngine()
            session.start(refine: velocityRefinement(audio16)) {
                let resampled = try await Task.detached { try Resampler.resample(samples, from: rate, to: HandPercussionEngine.sampleRate) }.value
                return hands.stream(samples: resampled)
            }
            return
        }
        guard let modelURL = store.installedURL(for: entry) else { return }
        if entry.engine == .pianoOnnx {
            let piano = PianoOnnxEngine(modelURL: modelURL, threads: count)
            session.start {
                let resampled = try await Task.detached { try Resampler.resample(samples, from: rate, to: PianoOnnxEngine.sampleRate) }.value
                return piano.stream(samples: resampled)
            }
            return
        }
        let audio16 = Task.detached { try Resampler.resample(samples, from: rate, to: 16000) }
        let refine = velocityRefinement(audio16)
        if entry.engine == .drumsAdtof || entry.engine == .drumsOaf {
            var drums = DrumOnnxEngine(modelURL: modelURL, spec: entry.engine == .drumsOaf ? .oaf : .adtof, threads: count)
            if usesSeparator, let helper = separatorEntry, let helperURL = store.installedURL(for: helper) {
                drums.separator = DrumSeparator(modelURL: helperURL, threads: count)
            }
            let engineForRun = drums
            session.start(refine: refine) {
                let resampled = try await Task.detached { try Resampler.resample(samples, from: rate, to: DrumOnnxEngine.sampleRate) }.value
                return engineForRun.stream(samples: resampled)
            }
            return
        }
        let process = engine
        session.start(refine: refine) {
            let resampled = try await audio16.value
            guard let process else { throw EngineLocatorError.missing }
            return process.transcribe(model: modelURL, samples: resampled, device: device, threads: count, instruments: names)
        }
    }
}

struct AudioDetailView: View {
    @Bindable var screen: AudioScreenModel
    let onOpenAudio: (URL) -> Void
    /// Opens a saved transcription in the MIDI editor.
    var onEditMIDI: (URL) -> Void = { _ in }
    @Environment(AppPreferences.self) private var preferences
    @Environment(\.undoManager) private var windowUndoManager
    @FocusState private var focused: Bool

    private var model: DocumentModel { screen.document }
    private var session: TranscriptionSession { screen.session }
    private var playback: PlaybackEngine { screen.playback }

    var body: some View {
        VStack(spacing: 0) {
            if let problem = screen.engineProblem {
                Text(problem).foregroundStyle(Native.danger).padding(Metric.sp4)
            }
            WaveformSliceView(model: model, grid: screen.grid, beats: screen.detectedBeats, onSeek: screen.seek)
            AudioStatusView(panel: screen.runPanel, startedAt: screen.startedAt,
                            onCancel: screen.cancelCurrent, onRetry: screen.retryCurrent, onDismiss: screen.dismissFailure)
                .padding(.horizontal, Metric.sp6)
            PianoRollView(notes: screen.usableNotes, duration: model.slice.span, finalizedThrough: session.finalizedThrough,
                          playhead: playback.position, hidden: screen.hiddenInstruments,
                          pixelsPerSecond: $screen.pixelsPerSecond, grid: screen.grid, follows: preferences.followPlayhead, onSeek: screen.seek,
                          neutralColour: screen.usesNeutralColour,
                          showsEmptyState: session.notes.isEmpty && session.state == .idle && !screen.isPreparing)
                .onTapGesture { focused = true }
            Divider()
            AudioFooterView(screen: screen, onEditMIDI: onEditMIDI)
        }
        .dropDestination(for: URL.self) { urls, _ in
            debugLog(.library, "Dropped on the Audio screen: \(urls.map(\.lastPathComponent).joined(separator: ", "))")
            guard let url = urls.first else { return false }
            onOpenAudio(url)
            return true
        }
        .task { await screen.loadEngineInfo() }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress { press in
            guard press.modifiers.isEmpty else { return .ignored }
            if press.characters == " " {
                screen.togglePlayback()
            } else if press.characters.lowercased() == "l" {
                playback.loops.toggle()
            } else if press.characters.lowercased() == "c" {
                playback.click.toggle()
            } else {
                return .ignored
            }
            return .handled
        }
        .alert(consentTitle, isPresented: Binding(get: { screen.firstUse.consentRequest != nil }, set: { _ in })) {
            Button("Review Licence…") { screen.firstUse.answerConsent(true) }
            Button("Cancel", role: .cancel) { screen.firstUse.answerConsent(false) }
        } message: {
            Text("The model file is downloaded once and kept on your Mac.")
        }
        .onChange(of: session.notes.count) {
            screen.notesChanged()
            playback.sync(notes: screen.usableNotes)
        }
        .onChange(of: windowUndoManager, initial: true) { _, manager in
            if let manager, screen.undoManager !== manager { screen.undoManager = manager }
        }
        .onChange(of: session.finalizedThrough) { playback.limit = session.isBusy ? session.finalizedThrough : nil }
        .onChange(of: session.state) { playback.limit = session.isBusy ? session.finalizedThrough : nil }
        // From the start, not only after the first Play, so the transport is sized for this audio before it plays.
        .onChange(of: model.slice, initial: true) {
            screen.sliceChanged()
            playback.duration = model.slice.span
        }
        .onChange(of: model.document?.url) { screen.documentChanged() }
        .onChange(of: screen.silencedGroups, initial: true) { _, groups in playback.setSilenced(groups) }
        .toolbar {
            ToolbarItem {
                TransportView(playback: playback, toggle: screen.togglePlayback)
            }
            ToolbarSpacer(.fixed)
            // The capsule draws its own background, so it stays out of the transport's glass.
            ToolbarItem {
                TranscribeButton(label: screen.transcribeLabel, isBusy: session.isBusy, isPrimary: !isRepeat,
                                 canStart: screen.canStart, hint: screen.startBlocker ?? "Transcribe the selected slice", action: screen.start)
            }
            .sharedBackgroundVisibility(.hidden)
            ToolbarSpacer(.fixed)
            ToolbarItem {
                ExportView(notes: screen.usableNotes, entry: screen.selectedEntry,
                           slice: model.slice, name: model.document?.name ?? "transcription", grid: screen.grid,
                           showNotice: $screen.showExport)
            }
            .sharedBackgroundVisibility(.hidden)
            ToolbarSpacer(.fixed)
            ToolbarItem { InspectorToggle() }
        }
    }

    private var consentTitle: String {
        guard let entry = screen.firstUse.consentRequest else { return "" }
        return "\(entry.displayName) downloads on first use (\(entry.sizeText))"
    }

    private var isRepeat: Bool {
        switch session.state {
        case .done, .cancelled: true
        default: false
        }
    }
}

struct AudioFooterView: View {
    @Bindable var screen: AudioScreenModel
    let onEditMIDI: (URL) -> Void

    private var playback: PlaybackEngine { screen.playback }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Metric.sp6) {
                summaryText
                Spacer(minLength: Metric.sp4)
                exportChip
                mixControl
                speedControl
                zoomControl
            }
            VStack(alignment: .leading, spacing: Metric.sp3) {
                HStack(spacing: Metric.sp6) { summaryText; Spacer(minLength: Metric.sp4); exportChip; zoomControl }
                HStack(spacing: Metric.sp6) { mixControl; speedControl; Spacer(minLength: 0) }
            }
            VStack(alignment: .leading, spacing: Metric.sp3) {
                summaryText
                HStack(spacing: Metric.sp6) { exportChip; Spacer(minLength: 0); zoomControl }
                HStack(spacing: Metric.sp6) { mixControl; speedControl; Spacer(minLength: 0) }
            }
            VStack(alignment: .leading, spacing: Metric.sp3) {
                summaryText
                exportChip
                mixControl
                speedControl
                zoomControl
            }
        }
        .padding(.horizontal, Metric.sp6).padding(.vertical, Metric.sp4)
    }

    private var exportChip: some View {
        MIDIDragChip(notes: screen.usableNotes, entry: screen.selectedEntry, slice: screen.document.slice,
                     name: screen.document.document?.name ?? "transcription", grid: screen.grid)
    }

    private var summaryText: some View {
        VStack(alignment: .leading, spacing: Metric.sp1) {
            HStack(spacing: Metric.sp3) {
                Text(screen.summary).font(.caption).foregroundStyle(Native.fgSecondary).lineLimit(1)
                if let url = savedURL, !screen.session.isBusy {
                    Button("Edit MIDI") { onEditMIDI(url) }.buttonStyle(.link).font(.caption).fixedSize()
                }
            }
            saveLine
            if let notice = screen.writer.notice { Text(notice).font(.caption).foregroundStyle(Native.danger) }
            if let message = screen.originMessage { Text(message).font(.caption).foregroundStyle(Native.danger) }
            if let message = playback.lastError { Text(message).font(.caption).foregroundStyle(Native.danger) }
        }
    }

    @ViewBuilder private var saveLine: some View {
        switch screen.writer.status {
        case .idle:
            EmptyView()
        case .saved(let url, let version, let partial):
            Text("\(partial ? "Partial result saved" : "Saved") as Version \(version)")
                .font(.caption).foregroundStyle(Native.fgSecondary).lineLimit(1).help("MIDI/\(url.lastPathComponent)")
        case .keptPrevious(let url, let version):
            Text(version.map { "Kept the earlier result, Version \($0)" } ?? "Kept the earlier result")
                .font(.caption).foregroundStyle(Native.fgSecondary).lineLimit(1).help("MIDI/\(url.lastPathComponent)")
        case .empty:
            Text("No notes found, so nothing was saved.").font(.caption).foregroundStyle(Native.fgSecondary).lineLimit(1)
        case .failed(let message):
            HStack(spacing: Metric.sp3) {
                Text(message).font(.caption).foregroundStyle(Native.danger).lineLimit(2)
                Button("Try Saving Again", action: screen.retrySave).controlSize(.small)
            }
        }
    }

    private var mixControl: some View {
        HStack(spacing: Metric.sp3) {
            Text("Original").font(.caption).fixedSize()
            Slider(value: Binding(get: { playback.mix }, set: { playback.mix = $0 }))
                .frame(width: Metric.mixSliderW).accessibilityLabel("Original and notes mix")
            Text("Notes").font(.caption).fixedSize()
        }
    }

    private var speedControl: some View {
        HStack(spacing: Metric.sp3) {
            Text("Speed").font(.caption).fixedSize()
            Slider(value: Binding(get: { Double(playback.rate) }, set: { playback.rate = Float($0) }), in: 0.5...2)
                .frame(width: Metric.sliderW).accessibilityLabel("Playback speed")
            Text(String(format: "%.2f×", playback.rate)).font(.caption.monospacedDigit()).frame(width: Metric.readoutW, alignment: .leading)
        }
    }

    private var zoomControl: some View {
        HStack(spacing: Metric.sp3) {
            Image(systemName: "minus").font(.caption)
            Slider(value: Binding(get: { Double(screen.pixelsPerSecond) }, set: { screen.pixelsPerSecond = CGFloat($0) }), in: Double(Metric.ppsMin)...Double(Metric.ppsMax))
                .frame(width: Metric.sliderW).accessibilityLabel("Zoom")
            Image(systemName: "plus").font(.caption)
        }
    }

    /// The file the last run was saved to (or left in place), for the Edit MIDI link.
    private var savedURL: URL? {
        switch screen.writer.status {
        case .saved(let url, _, _), .keptPrevious(let url, _): url
        case .idle, .empty, .failed: nil
        }
    }
}
