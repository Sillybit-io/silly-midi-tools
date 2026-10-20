import SwiftUI

struct MIDIEditorInspectorView: View {
    let editor: MIDIEditorModel
    /// Renames the file on disk; throws a message to show under the field.
    var rename: (String) throws -> Void = { _ in }
    /// Opens the audio this file was transcribed from, when it can still be found.
    var openSource: (() -> Void)?

    @State private var name = ""
    @State private var renameError: String?
    @State private var tempoCandidates: [TempoCandidate] = []

    private var document: MIDIDocument { editor.document }

    private static let pitchNames = ["C", "C\u{266F}", "D", "D\u{266F}", "E", "F", "F\u{266F}", "G", "G\u{266F}", "A", "A\u{266F}", "B"]

    static func pitchName(_ pitch: Int) -> String {
        "\(pitchNames[pitch % 12])\(pitch / 12 - 1)"
    }

    var body: some View {
        Form {
            fileSection
            selectionSection
            tracksSection
            tempoSection
            keySection
        }
        .formStyle(.grouped)
        .onChange(of: document.revision, initial: true) { _, _ in
            tempoCandidates = TempoFromNotes.rank(notes: document.noteEvents, currentBPM: document.grid.bpm)
        }
    }

    // MARK: File

    private var model: ModelEntry? {
        ModelCatalog.entry(id: editor.provenance?.modelID)
    }

    private var sourceText: String {
        guard let source = editor.provenance?.source else { return "Imported file" }
        if source.hasPrefix(MIDIProvenance.referencePrefix) { return "Referenced audio" }
        guard source.hasPrefix(MIDIProvenance.audioPrefix) else { return "Audio file" }
        return String(source.dropFirst(MIDIProvenance.audioPrefix.count))
    }

    private var fileSection: some View {
        Section {
            LabeledContent("Name") {
                TextField("Name", text: $name)
                    .labelsHidden().multilineTextAlignment(.trailing)
                    .onSubmit(commitName)
                    .accessibilityLabel("File name")
                    .onAppear { name = editor.url.lastPathComponent }
                    .onChange(of: editor.url) { name = editor.url.lastPathComponent }
            }
            LabeledContent("Where") {
                Text(editor.url.deletingLastPathComponent().abbreviatedPath).font(.caption.monospaced())
                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            }
            LabeledContent("Source") {
                if let openSource {
                    Button(sourceText, action: openSource).buttonStyle(.link).help("Open the audio this file was made from")
                } else {
                    Text(sourceText)
                }
            }
            if let model {
                LabeledContent("Made with") {
                    HStack(spacing: Metric.sp3) {
                        Text(model.displayName)
                        LicenseBadge(entry: model)
                    }
                }
            }
        } header: {
            Text("File")
        } footer: {
            if let renameError { Text(renameError).foregroundStyle(Native.danger) }
        }
    }

    private func commitName() {
        do {
            try rename(name)
            renameError = nil
        } catch {
            renameError = error.localizedDescription
            name = editor.url.lastPathComponent
        }
    }

    // MARK: Selection

    private var selectionSection: some View {
        let selected = document.selectedNotes
        return Section("Selection") {
            if let note = selected.first, selected.count == 1 {
                LabeledContent("Note", value: Self.pitchName(note.pitch))
                LabeledContent("Start (s)") {
                    TextField("Start", value: Binding(get: { note.start }, set: { document.setTiming(note.id, start: $0) }),
                              format: .number.precision(.fractionLength(3)))
                        .labelsHidden().multilineTextAlignment(.trailing).frame(width: Metric.fieldW).accessibilityLabel("Start, seconds")
                }
                LabeledContent("Length (ms)") {
                    TextField("Length", value: Binding(get: { (note.duration * 1000).rounded() }, set: { document.setTiming(note.id, duration: $0 / 1000) }),
                              format: .number.precision(.fractionLength(0)))
                        .labelsHidden().multilineTextAlignment(.trailing).frame(width: Metric.fieldW).accessibilityLabel("Length, milliseconds")
                }
                LabeledContent("Velocity") {
                    TextField("Velocity", value: Binding(get: { note.velocity }, set: { document.setVelocity($0, for: [note.id]) }), format: .number)
                        .labelsHidden().multilineTextAlignment(.trailing).frame(width: Metric.fieldW).accessibilityLabel("Velocity, 1 to 127")
                }
            } else if selected.isEmpty {
                Text("Click a note to select it, \u{21E7}-click to add more, or drag a box around several.")
                    .font(.caption).foregroundStyle(Native.fgSecondary)
            } else {
                LabeledContent("Notes", value: "\(selected.count) selected")
            }
            if !selected.isEmpty {
                LabeledContent("Transpose") {
                    HStack(spacing: Metric.sp2) {
                        ForEach([-12, -1, 1, 12], id: \.self) { step in
                            Button(step > 0 ? "+\(step)" : "\u{2212}\(-step)") { document.transpose(by: step) }
                                .controlSize(.small).accessibilityLabel("Transpose \(step) semitones")
                        }
                    }
                }
                Button("Delete \(selected.count) \(selected.count == 1 ? "Note" : "Notes")", role: .destructive) { document.deleteSelection() }
            }
        }
    }

    // MARK: Tracks

    private var tracksSection: some View {
        Section("Tracks") {
            ForEach(document.tracks) { track in
                let name = editor.displayName(ofTrack: track.id)
                HStack(spacing: Metric.sp3) {
                    Circle().fill(editor.colour(forTrack: track.id)).frame(width: Metric.sp4, height: Metric.sp4).accessibilityHidden(true)
                    Text(name).lineLimit(1)
                    Spacer(minLength: Metric.sp2)
                    Text("\(document.notes.filter { $0.track == track.id }.count)").font(.caption).foregroundStyle(Native.fgSecondary)
                    flag("M", "Mute \(name)", on: document.mutedTracks.contains(track.id)) { document.toggleMute(track.id) }
                    flag("S", "Solo \(name)", on: document.soloTracks.contains(track.id)) { document.toggleSolo(track.id) }
                    Toggle(isOn: Binding(get: { document.hiddenTracks.contains(track.id) }, set: { _ in document.toggleHidden(track.id) })) {
                        Image(systemName: document.hiddenTracks.contains(track.id) ? "eye.slash" : "eye")
                    }
                    .toggleStyle(.button).controlSize(.small).help("Hide \(name)").accessibilityLabel("Hide \(name)")
                }
            }
            Picker("Draw on", selection: Binding(get: { document.drawTrackID }, set: { document.drawTrackID = $0 })) {
                Section("Tracks") {
                    ForEach(document.tracks) { Text(editor.displayName(ofTrack: $0.id)).tag($0.id) }
                }
                Section("New track") {
                    ForEach(MIDITrack.classes.filter { id in !document.tracks.contains { $0.id == id } }, id: \.self) { id in
                        Text(editor.displayName(ofTrack: id)).tag(id)
                    }
                }
            }
        }
    }

    private func flag(_ title: String, _ label: String, on: Bool, action: @escaping () -> Void) -> some View {
        Toggle(title, isOn: Binding(get: { on }, set: { _ in action() }))
            .toggleStyle(.button).controlSize(.small).help(label).accessibilityLabel(label)
    }

    private var tempoSection: some View {
        Section("Tempo") {
            TempoFieldsView(grid: Binding(get: { document.grid }, set: { document.setGrid($0) }), showsMeterChanges: true)
            TempoCandidatesView(title: "Tempo from notes", candidates: tempoCandidates, currentBPM: document.grid.bpm) { candidate in
                document.setGrid(MIDIGrid(bpm: candidate.bpm, meters: document.grid.meters), named: "Use Tempo From Notes")
            }
        }
    }

    // MARK: Key

    private var keySection: some View {
        let matches = KeyDetector.rank(notes: document.noteEvents).prefix(3)
        return Section {
            if matches.isEmpty {
                Text("\u{2014}").foregroundStyle(Native.fgSecondary)
            } else {
                ForEach(Array(matches)) { Text("\($0.name)  \(Int(($0.score * 100).rounded()))%").font(.caption) }
            }
        } header: {
            Text("Key from notes")
        } footer: {
            Text("Recomputed after every edit. Similar modes can score closely.")
        }
    }
}
