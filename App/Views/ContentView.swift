import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    let store: ModelStore
    @Bindable var access: AccessCoordinator
    let workingFolder: WorkingFolderStore
    let library: LibraryStore
    let imports: AudioImportStore
    let preferences: AppPreferences
    let saveCoordinator: MIDISaveCoordinator

    @State private var screens: AudioScreens
    @State private var selection: LibrarySelection?
    @AppStorage("inspectorShown") private var showInspector = true
    @State private var showWelcome = false
    @State private var showShortcuts = false
    @State private var importingMIDI = false
    @State private var sidebarRevision = 0
    @State private var midiEditor: MIDIEditorModel?
    @State private var midiFailure: (name: String, message: String)?

    init(store: ModelStore, access: AccessCoordinator,
         workingFolder: WorkingFolderStore, library: LibraryStore, imports: AudioImportStore, preferences: AppPreferences,
         saveCoordinator: MIDISaveCoordinator) {
        self.store = store
        self.access = access
        self.workingFolder = workingFolder
        self.library = library
        self.imports = imports
        self.preferences = preferences
        self.saveCoordinator = saveCoordinator
        saveCoordinator.onSaved = { library.refresh() }
        _screens = State(initialValue: AudioScreens {
            AudioScreenModel(document: DocumentModel(), store: store, session: TranscriptionSession(), access: access, preferences: preferences,
                             destination: { workingFolder.midiFolder }, references: { imports.references },
                             onSaved: { library.refresh() })
        })
    }

    private var screen: AudioScreenModel { screens.current }
    private var model: DocumentModel { screens.current.document }
    private var session: TranscriptionSession { screens.current.session }

    var body: some View {
        NavigationSplitView {
            LibrarySidebarView(library: library, workingFolder: workingFolder, imports: imports,
                               selection: gatedSelection, openAudio: { model.isImporting = true }, importingMIDI: $importingMIDI,
                               failedDownload: screen.downloadFailure == nil ? nil : model.document?.url,
                               transcribing: screens.transcribingURL)
                .id(sidebarRevision)
                .navigationSplitViewColumnWidth(min: Metric.sidebarW - Metric.sp9, ideal: Metric.sidebarW, max: Metric.sidebarW + Metric.sp10)
        } detail: {
            // A plain trailing pane rather than `.inspector`: with Reduce Transparency on, macOS 26.5 draws the
            // system inspector without its controls or default-coloured text.
            HStack(spacing: 0) {
                detail.frame(maxWidth: .infinity)
                if showInspector && hasInspector {
                    Divider()
                    inspector.frame(width: Metric.inspectorW).background(Token.bg)
                }
            }
            .navigationTitle(title)
            .navigationSubtitle(subtitle)
        }
        .frame(minWidth: Metric.windowMinWide, minHeight: Metric.windowMinH)
        .environment(saveCoordinator)
        .environment(preferences)
        .focusedSceneValue(\.commandTarget, commandTarget)
        .sheet(isPresented: $showShortcuts) { KeyboardShortcutsView() }
        .background(WindowGuard(coordinator: saveCoordinator, edited: saveCoordinator.hasUnsavedChanges))
        .alert(saveFailureTitle, isPresented: Binding(get: { saveCoordinator.saveFailure != nil }, set: { if !$0 { saveCoordinator.dismissFailure() } })) {
            Button("OK") { saveCoordinator.dismissFailure() }
        } message: {
            Text(saveCoordinator.saveFailure?.message ?? "")
        }
        .preferredColorScheme(preferences.appearance.colorScheme)
        .onChange(of: workingFolder.folder, initial: true) {
            library.attach(audio: workingFolder.audioFolder, midi: workingFolder.midiFolder)
        }
        .onChange(of: model.document?.url) { _, url in if let url { selection = .audio(url) } }
        .onChange(of: selection) { _, new in
            debugLog(.library, "Selected \(new?.logDescription ?? "nothing").")
            if case .audio(let url) = new, url != model.document?.url { screens.open(url) }
            if case .midi(let url) = new {
                screen.playback.stop()
                // Already open, for example just renamed: keep the edits and their undo steps.
                if midiEditor?.url != url { loadMIDI(url) }
            } else {
                closeMIDI()
            }
        }
        .sheet(isPresented: Binding(get: { !workingFolder.isResolved || showWelcome }, set: { showWelcome = $0 })) {
            WelcomeView(workingFolder: workingFolder) { showWelcome = false }
                .interactiveDismissDisabled(!workingFolder.isResolved)
        }
        .sheet(item: $access.request) { request in
            LicenseSheet(coordinator: access, request: request).interactiveDismissDisabled()
        }
        .fileImporter(isPresented: Binding(get: { model.isImporting }, set: { model.isImporting = $0 }), allowedContentTypes: [.audio]) { result in
            switch result {
            case .success(let url):
                debugLog(.library, "Chose \"\(url.lastPathComponent)\" in the open panel.")
                openAudio(url)
            case .failure(let error):
                debugLog(.library, "The open panel failed: \(error.localizedDescription)")
                model.failure = .other(error)
            }
        }
        .alert(model.failure?.title ?? "", isPresented: Binding(
            get: { model.failure != nil },
            set: { if !$0 { model.failure = nil } })) {
            Button("OK") { model.failure = nil }
        } message: {
            Text(model.failure?.message ?? "")
        }
    }

    /// Every way of changing the selection asks first when the open MIDI file has unsaved changes.
    private var gatedSelection: Binding<LibrarySelection?> {
        Binding(get: { selection }, set: { newValue in
            guard newValue != selection else { return }
            // A declined change leaves the List showing the row that was clicked; rebuilding it makes it show the real selection again.
            saveCoordinator.confirmLeaving(then: { selection = newValue }, cancelled: { sidebarRevision += 1 })
        })
    }

    /// What the menu bar sees of this window. The closures call the same actions the buttons do.
    private var commandTarget: AppCommandTarget {
        let editor = midiEditor
        let isMIDI = isMIDISelected && editor != nil
        let isAudio = !isMIDISelected && model.document != nil
        var target = AppCommandTarget()
        target.screen = isMIDI ? .midi : isAudio ? .audio : .empty
        target.canSave = isMIDI && (editor?.document.isDirty ?? false)
        target.canExport = isAudio ? !session.notes.isEmpty : isMIDI && !(editor?.document.notes.isEmpty ?? true)
        target.hasSelection = isMIDI && !(editor?.document.selection.isEmpty ?? true)
        target.canQuantize = isMIDI && (editor.map { $0.document.snap != .off && !$0.document.notes.isEmpty } ?? false)
        target.canTranscribe = isAudio && screen.canStart
        target.isTranscribing = session.isBusy || screen.isPreparing
        target.canResetSlice = isAudio
        target.canDetectKey = isAudio && !screen.isDetectingKey
        target.canDetectTempo = isAudio && screen.canAnalyze
        let transport = isMIDI ? editor?.playback : isAudio ? screen.playback : nil
        target.canPlay = transport != nil
        target.isPlaying = transport?.isPlaying ?? false
        target.isLooping = transport?.loops ?? false
        target.isClickOn = transport?.click ?? false
        target.canSelectAudio = model.document != nil || !library.audio.isEmpty
        target.canSelectMIDI = !library.midi.isEmpty
        target.hasWorkingFolder = workingFolder.folder != nil
        target.tool = isMIDI ? editor?.tool : nil
        target.inspectorShown = showInspector

        target.openAudio = { model.isImporting = true }
        target.importMIDI = { importingMIDI = true }
        target.save = { saveCoordinator.saveOpenFile() }
        target.export = { if isMIDI { editor?.showExport = true } else { screen.showExport = true } }
        target.showWorkingFolder = {
            if let folder = workingFolder.folder { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
        }
        target.deleteSelection = { editor?.document.deleteSelection() }
        target.transposeUp = { editor?.document.transpose(by: 1) }
        target.transposeDown = { editor?.document.transpose(by: -1) }
        target.quantize = { editor?.document.quantize() }
        target.transcribe = { screen.start() }
        target.cancelTranscription = { screen.cancel() }
        target.resetSlice = { model.slice.reset() }
        target.detectKey = { screen.detectKeyFromAudio() }
        target.detectTempo = { screen.detectTempoFromAudio() }
        target.toggleInspector = { showInspector.toggle() }
        target.zoomIn = { zoom(by: 1.25) }
        target.zoomOut = { zoom(by: 0.8) }
        target.setTool = { editor?.tool = $0 }
        target.togglePlayback = { if isMIDI { editor?.togglePlayback() } else { screen.togglePlayback() } }
        target.stop = { transport?.stop() }
        target.toggleLoop = { transport?.loops.toggle() }
        target.toggleClick = { transport?.click.toggle() }
        target.selectAudio = {
            if let url = model.document?.url ?? library.audio.first(where: { !$0.isMissing })?.url { gatedSelection.wrappedValue = .audio(url) }
        }
        target.selectMIDI = {
            if let url = library.midi.first?.url { gatedSelection.wrappedValue = .midi(url) }
        }
        target.showWelcome = { showWelcome = true }
        target.showShortcuts = { showShortcuts = true }
        return target
    }

    private func zoom(by factor: CGFloat) {
        if isMIDISelected, let midiEditor {
            midiEditor.pixelsPerSecond = min(Metric.ppsMax, max(Metric.ppsEditorMin, midiEditor.pixelsPerSecond * factor))
        } else {
            screen.pixelsPerSecond = min(Metric.ppsMax, max(Metric.ppsMin, screen.pixelsPerSecond * factor))
        }
    }

    private var saveFailureTitle: String {
        "Could not save \u{201C}\(saveCoordinator.saveFailure?.name ?? "")\u{201D}"
    }

    private func openAudio(_ url: URL) {
        debugLog(.library, "Opening \"\(url.lastPathComponent)\" as \(AudioDocument.kind(of: url)), from \(url.deletingLastPathComponent().path)")
        switch AudioDocument.kind(of: url) {
        case .audio:
            saveCoordinator.confirmLeaving(then: { importAndOpen(url) })
        case .midi:
            model.failure = AudioOpenFailure(title: "That\u{2019}s a MIDI file",
                                             message: "Use Import MIDI\u{2026} in the sidebar to add it to your library.")
        case .other:
            model.failure = AudioOpenFailure(title: "Could not open \u{201C}\(url.lastPathComponent)\u{201D}",
                                             message: "This isn\u{2019}t an audio file. Use WAV, MP3, FLAC, M4A or AIFF.")
        }
    }

    /// Copies or references the audio as the user prefers, then opens it. The file is taken in at once, while a dropped
    /// file is still reachable; switching the window to it waits until the drop or the panel has finished.
    private func importAndOpen(_ url: URL) {
        do {
            let target = try imports.importAudio(from: url, mode: preferences.addAudioMode,
                                                 audioFolder: workingFolder.audioFolder)
            debugLog(.library, "Added \"\(url.lastPathComponent)\" (\(preferences.addAudioMode.rawValue)): it opens from \(target.path)")
            Task { @MainActor in
                library.refresh()
                screens.open(target)
            }
        } catch {
            debugLog(.library, "Couldn\u{2019}t add \"\(url.lastPathComponent)\": \(String(reflecting: error))")
            model.failure = .other(error)
        }
    }

    private func loadMIDI(_ url: URL) {
        closeMIDI()
        do {
            midiEditor = try MIDIEditorModel.load(url)
            saveCoordinator.editor = midiEditor
            midiFailure = nil
            debugLog(.midi, "Opened \"\(url.lastPathComponent)\": \(midiEditor?.document.notes.count ?? 0) notes, \(midiEditor?.document.tracks.count ?? 0) tracks.")
        } catch {
            midiFailure = (url.lastPathComponent, error.localizedDescription)
            debugLog(.midi, "Couldn\u{2019}t open \"\(url.lastPathComponent)\": \(String(reflecting: error))")
        }
    }

    /// Renames the open file on disk and keeps it open and selected under its new name.
    private func renameMIDI(_ editor: MIDIEditorModel, to name: String) throws {
        let renamed = try editor.rename(to: name)
        debugLog(.midi, "Renamed to \"\(renamed.lastPathComponent)\".")
        selection = .midi(renamed)
        library.refresh()
    }

    /// The audio an open MIDI file was transcribed from, when it can still be found.
    private func sourceAudio(of editor: MIDIEditorModel) -> URL? {
        guard let source = editor.provenance?.source else { return nil }
        if source.hasPrefix(MIDIProvenance.referencePrefix) {
            guard let id = UUID(uuidString: String(source.dropFirst(MIDIProvenance.referencePrefix.count))),
                  let reference = imports.references.first(where: { $0.id == id }) else { return nil }
            return imports.resolved(reference)
        }
        guard source.hasPrefix(MIDIProvenance.audioPrefix), let folder = workingFolder.audioFolder else { return nil }
        let url = folder.appending(path: String(source.dropFirst(MIDIProvenance.audioPrefix.count)), directoryHint: .notDirectory)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func closeMIDI() {
        midiEditor?.playback.stop()
        midiEditor?.document.closeUndo()
        midiEditor = nil
        saveCoordinator.editor = nil
        midiFailure = nil
    }

    @ViewBuilder private var detail: some View {
        if case .midi(let url) = selection {
            if let midiEditor, midiEditor.url == url {
                MIDIEditorView(editor: midiEditor).id(midiEditor.id)
            } else if let midiFailure {
                ContentUnavailableView("Could not open \u{201C}\(midiFailure.name)\u{201D}", systemImage: "exclamationmark.triangle",
                                       description: Text(midiFailure.message))
            } else {
                ProgressView()
            }
        } else if model.document == nil {
            if model.isLoading {
                ProgressView()
            } else {
                DropZoneView(onOpen: openAudio, onChooseFile: { model.isImporting = true },
                             folderPath: workingFolder.folder.map { $0.abbreviatedPath + "/" })
            }
        } else {
            AudioDetailView(screen: screen, onOpenAudio: openAudio, onEditMIDI: { gatedSelection.wrappedValue = .midi($0) })
                .id(ObjectIdentifier(screen))
        }
    }

    private var inspector: some View {
        Group {
            if isMIDISelected {
                if let midiEditor {
                    MIDIEditorInspectorView(editor: midiEditor, rename: { try renameMIDI(midiEditor, to: $0) },
                                            openSource: sourceAudio(of: midiEditor).map { url in { gatedSelection.wrappedValue = .audio(url) } })
                } else {
                    ContentUnavailableView("No MIDI File", systemImage: "pianokeys")
                }
            } else if model.document != nil {
                AudioInspectorView(screen: screen).id(ObjectIdentifier(screen))
            } else {
                ContentUnavailableView("No Audio Selected", systemImage: "waveform")
            }
        }
    }

    /// There is nothing to inspect on the empty screen, so the pane (and its toolbar button) only exist with a file open.
    private var hasInspector: Bool { isMIDISelected || model.document != nil }

    private var isMIDISelected: Bool {
        if case .midi = selection { true } else { false }
    }

    private var title: String {
        if case .midi(let url) = selection { return midiEditor?.url.lastPathComponent ?? url.lastPathComponent }
        return model.document?.name ?? "Silly MIDI Tools"
    }

    private var subtitle: String {
        if case .midi = selection {
            guard let editor = midiEditor else { return "" }
            return Self.editorSubtitle(notes: editor.document.notes.count, tracks: editor.document.tracks.count,
                                       grid: editor.document.grid, dirty: editor.document.isDirty)
        }
        guard let document = model.document else { return "" }
        return String(format: "%.1f s · %@", document.duration, sampleRateText(document.sampleRate))
    }

    /// `{n} notes · {k} tracks · {tempo} BPM {meter}`, plus the map and unsaved changes.
    static func editorSubtitle(notes: Int, tracks: Int, grid: MIDIGrid, dirty: Bool) -> String {
        let meter = grid.meters[0]
        let changes = grid.meters.count - 1
        let tempo = grid.bpm.formatted(.number.precision(.fractionLength(0...2)).locale(Locale(identifier: "en_US_POSIX")))
        let map = changes > 0 ? " \u{00B7} \(changes) meter \(changes == 1 ? "change" : "changes")" : ""
        return "\(notes) \(notes == 1 ? "note" : "notes") \u{00B7} \(tracks) \(tracks == 1 ? "track" : "tracks") \u{00B7} \(tempo) BPM \(meter.numerator)/\(meter.denominator)" + map
            + (dirty ? " \u{00B7} Edited" : "")
    }

    private func sampleRateText(_ rate: Double) -> String {
        "\((rate / 1000).formatted(.number.precision(.fractionLength(0...2)))) kHz"
    }
}
