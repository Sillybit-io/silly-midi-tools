import SwiftUI

extension ModelEntry {
    /// "209 MB", "2.74 GB": the size shown next to a model that still has to be downloaded.
    var sizeText: String {
        byteSize >= 1_000_000_000
            ? String(format: "%.2f GB", Double(byteSize) / 1_000_000_000)
            : String(format: "%.0f MB", Double(byteSize) / 1_000_000)
    }
}

struct AudioInspectorView: View {
    @Bindable var screen: AudioScreenModel
    @Environment(\.openSettings) private var openSettings
    @AppStorage("settingsTab") private var settingsTab = "general"

    private static let manageTag = "manage"

    private var session: TranscriptionSession { screen.session }
    private var entry: ModelEntry? { screen.selectedEntry }

    var body: some View {
        Form {
            modelSection
            if entry?.engine == .muscriptor {
                Section {
                    InstrumentChipsView(instruments: screen.instruments, selection: $screen.chosenInstruments)
                } header: {
                    HStack { Text("Instruments"); Spacer(); Text(screen.chosenInstruments.isEmpty ? "automatic" : "\(screen.chosenInstruments.count) selected") }
                } footer: {
                    Text("Leave all off to let MuScriptor detect instruments automatically.")
                }
            }
            if entry?.isDrumModel == true {
                Section("Drums") {
                    Toggle(isOn: $screen.separateDrums) {
                        VStack(alignment: .leading, spacing: Metric.sp1) {
                            Text("Separate drums first")
                            Text(Self.separatorNote(screen.separatorEntry, installed: separatorInstalled))
                                .font(.caption).foregroundStyle(Native.fgSecondary)
                        }
                    }
                }
            }
            Section("Velocity") {
                if let entry, entry.canEstimateVelocity {
                    Toggle(isOn: $screen.estimateVelocity) {
                        VStack(alignment: .leading, spacing: Metric.sp1) {
                            Text("Estimate note velocity from the audio")
                            Text("\(Self.velocitylessName(entry)) has none. Reflects relative loudness, not playing force.")
                                .font(.caption).foregroundStyle(Native.fgSecondary)
                        }
                    }
                } else {
                    Text(velocityNote).foregroundStyle(Native.fgSecondary)
                }
            }
            SliceFieldsSection(model: screen.document)
            Section("Tempo") {
                TempoFieldsView(grid: Binding(get: { screen.grid }, set: { screen.setGrid($0, actionName: "Change tempo and meter") }),
                                showsMeterChanges: true)
                TempoDetectionView(screen: screen)
            }
            Section {
                KeyView(notes: session.notes, fromAudio: screen.keyFromAudio, busy: screen.isDetectingKey, detect: screen.detectKeyFromAudio)
            } header: {
                Text("Key")
            } footer: {
                Text("Ranks major, minor and five more modes in all twelve keys. Similar modes can score closely.")
            }
            if !screen.presentInstruments.isEmpty {
                Section("Instruments in Result") {
                    InstrumentLegendView(counts: screen.instrumentCounts, neutral: screen.usesNeutralColour,
                                         drumPieces: screen.drumPieceCounts,
                                         muted: $screen.mutedInstruments, hidden: $screen.hiddenInstruments)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var modelSection: some View {
        Section("Model") {
            Picker("Model", selection: Binding(
                get: { screen.selectedModel },
                set: { choice in
                    if choice == Self.manageTag {
                        settingsTab = "models"
                        openSettings()
                    } else {
                        screen.selectedModel = choice
                    }
                })) {
                Section("MuScriptor · multi-instrument") { ForEach(entries(.muscriptor)) { row($0) } }
                Section("Piano only") { ForEach(entries(.pianoOnnx)) { row($0) } }
                Section("Kit drums only") { ForEach(entries(.drumsAdtof) + entries(.drumsOaf)) { row($0) } }
                Section("Hand percussion · built in") { ForEach(entries(.handPercussion)) { row($0) } }
                Section("Built in") { ForEach(entries(.basicPitch)) { row($0) } }
                Divider()
                Text("Manage Models…").tag(Optional(Self.manageTag))
            }
            .labelsHidden()
            if let entry {
                HStack(spacing: Metric.sp4) {
                    LicenseBadge(entry: entry)
                }
                if entry.engine == .pianoOnnx {
                    Text("Piano only. On other instruments it still reports piano notes.").font(.caption).foregroundStyle(Native.fgSecondary)
                }
                if entry.engine == .drumsAdtof {
                    Text("Drum kit only: kick, snare, toms, hi-hat and cymbals. Reads the drums in a full mix. Not for darbuka or other hand drums; use Hand percussion.")
                        .font(.caption).foregroundStyle(Native.fgSecondary)
                }
                if entry.engine == .handPercussion {
                    Text("Darbuka, doumbek, bendir and similar hand drums, one drum on its own. Finds each stroke and labels it low (doum, a Low Conga) or high (tek or ka, an Open Hi Conga). It cannot tell tek from ka, and it will not separate a drum from a band.")
                        .font(.caption).foregroundStyle(Native.fgSecondary)
                }
                if entry.engine == .drumsOaf {
                    Text("Drum kit only, eight kit pieces. Trained on isolated drums, so it works best on drum-only audio such as an e-kit recording, a drum stem or a loop. Not for darbuka or other hand drums; use Hand percussion.")
                        .font(.caption).foregroundStyle(Native.fgSecondary)
                }
                if let warning = entry.memoryWarning() {
                    Label(warning, systemImage: "memorychip").font(.caption).foregroundStyle(Token.warn)
                }
            }
            if entry?.engine == .muscriptor {
                Picker("Device", selection: $screen.deviceIndex) {
                    Text("Auto").tag(Int?.none)
                    ForEach(screen.devices, id: \.index) { Text("\($0.name) (\($0.backend))").tag(Optional($0.index)) }
                }
                LabeledContent("Threads") {
                    HStack(spacing: Metric.sp3) {
                        Text("\(screen.threads)").monospacedDigit()
                        Stepper("Threads", value: $screen.threads, in: 1...32).labelsHidden()
                    }
                }
            }
            if let entry {
                Text(entry.attribution).font(.caption).foregroundStyle(Native.fgSecondary)
            }
        }
    }

    private var separatorInstalled: Bool {
        screen.separatorEntry.map { screen.store.state(for: $0) == .installed } ?? false
    }

    /// Says whether the helper is already on this Mac, so the toggle doesn't promise a download that already happened.
    static func separatorNote(_ separator: ModelEntry?, installed: Bool) -> String {
        let source = installed
            ? "Uses the \(separator?.displayName ?? "drum separator") you downloaded."
            : "The first run downloads the \(separator?.displayName ?? "drum separator") helper (\(separator?.sizeText ?? "a large file")) once."
        return "Isolates the drums from the mix before listening. \(source) Very slow: on an Intel Mac, many times the length of the audio. Best for short slices. Helps most with Onsets and Frames on full songs."
    }

    private static func velocitylessName(_ entry: ModelEntry) -> String {
        switch entry.engine {
        case .muscriptor: "MuScriptor"
        case .handPercussion: "Hand percussion"
        default: "ADTOF"
        }
    }

    private var velocityNote: String {
        switch entry?.engine {
        case .pianoOnnx: "Predicted by the piano model."
        case .drumsOaf: "Predicted by the drum model."
        default: "Taken from the note amplitude Basic Pitch reports."
        }
    }

    private func entries(_ engine: ModelEntry.Engine) -> [ModelEntry] {
        ModelCatalog.entries.filter { $0.engine == engine }
    }

    private func row(_ entry: ModelEntry) -> some View {
        let installed = screen.store.state(for: entry) == .installed
        return Text(installed ? entry.displayName : "\(entry.displayName) — \(entry.sizeText) download")
            .tag(Optional(entry.id))
    }
}

private struct SliceFieldsSection: View {
    @Bindable var model: DocumentModel
    @State private var startText = ""
    @State private var endText = ""
    @State private var error: String?

    private static let minimumLength = AudioSlice.minimumSpan

    var body: some View {
        Section {
            LabeledContent("Start") {
                TextField("Start", text: $startText).labelsHidden().multilineTextAlignment(.trailing)
                    .monospacedDigit().frame(width: Metric.fieldW).onSubmit(commit).accessibilityLabel("Slice start")
            }
            LabeledContent("End") {
                TextField("End", text: $endText).labelsHidden().multilineTextAlignment(.trailing)
                    .monospacedDigit().frame(width: Metric.fieldW).onSubmit(commit).accessibilityLabel("Slice end")
            }
            LabeledContent("Length", value: Self.format(model.slice.span))
        } header: {
            Text("Slice")
        } footer: {
            if let error { Text(error).foregroundStyle(Native.danger) }
        }
        .onAppear(perform: sync)
        .onChange(of: model.slice) { sync() }
    }

    private func sync() {
        startText = Self.format(model.slice.start)
        endText = Self.format(model.slice.end)
        error = nil
    }

    private func commit() {
        guard let start = Self.parse(startText), let end = Self.parse(endText) else {
            error = "Use m:ss.s or seconds, e.g. 0:04.5 or 4.5"
            return
        }
        if start < 0 || end > model.slice.duration + 0.05 {
            error = "Times must be between 0:00.0 and \(Self.format(model.slice.duration))."
        } else if end - start < Self.minimumLength {
            error = "The slice must be at least 0.5 s long."
        } else {
            model.slice.setEnd(end)
            model.slice.setStart(start)
            sync()
        }
    }

    static func format(_ seconds: Double) -> String {
        String(format: "%d:%04.1f", Int(seconds) / 60, seconds.truncatingRemainder(dividingBy: 60))
    }

    static func parse(_ text: String) -> Double? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), let seconds = Double(parts.last!), seconds >= 0 else { return nil }
        if parts.count == 2 {
            guard let minutes = Int(parts[0]) else { return nil }
            return Double(minutes) * 60 + seconds
        }
        return seconds
    }
}
