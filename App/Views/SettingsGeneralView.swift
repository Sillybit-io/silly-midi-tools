import AppKit
import SwiftUI

struct SettingsGeneralView: View {
    let workingFolder: WorkingFolderStore
    @Bindable var preferences: AppPreferences


    var body: some View {
        Form {
            Section {
                HStack(spacing: Metric.sp4) {
                    Image(systemName: "folder").foregroundStyle(Token.accentText)
                    VStack(alignment: .leading, spacing: Metric.sp1) {
                        Text(workingFolder.folder?.lastPathComponent ?? "No folder chosen")
                        Text(workingFolder.folder.map { $0.abbreviatedPath + "/" } ?? "Choose where your audio and MIDI files live.")
                            .font(.caption.monospaced()).foregroundStyle(Native.fgSecondary).textSelection(.enabled)
                    }
                    Spacer()
                    Button("Show in Finder") {
                        if let folder = workingFolder.folder { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
                    }
                    .disabled(workingFolder.folder == nil)
                    Button("Choose…") { pick(inDefaultLocation: false) }
                }
                LabeledContent("Audio/") { Text("Audio you add or drop on the window").foregroundStyle(Native.fgSecondary) }
                LabeledContent("MIDI/") { Text("Transcriptions and your edits, saved automatically").foregroundStyle(Native.fgSecondary) }
                Picker("When you add audio", selection: $preferences.addAudioMode) {
                    Text("Copy into the Audio folder").tag(AddAudioMode.copy)
                    Text("Leave it where it is").tag(AddAudioMode.reference)
                }
                HStack {
                    Button("Reset to Default…") { pick(inDefaultLocation: true) }
                    Spacer()
                }
                if let message = workingFolder.errorMessage {
                    Text(message).font(.caption).foregroundStyle(Token.warn)
                }
            } header: {
                Text("Working Folder")
            } footer: {
                Text("The app keeps access to this folder with a security-scoped bookmark, so it keeps working inside the macOS sandbox. Changing the folder doesn\u{2019}t move the files already in the old one.")
            }
            Section("Appearance") {
                Picker("Appearance", selection: $preferences.appearance) {
                    ForEach(AppearancePreference.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
            }
            Section("Transcription") {
                Picker("Default model", selection: $preferences.defaultModelID) {
                    ForEach(ModelCatalog.entries.filter(\.transcribes)) { Text($0.displayName).tag($0.id) }
                }
            }
            Section {
                LabeledContent("Sound", value: "General MIDI")
                Toggle("Scroll piano roll to follow playhead", isOn: $preferences.followPlayhead)
                TempoFieldsView(grid: $preferences.defaultGrid, showsMeterChanges: false)
                LabeledContent("MIDI file", value: "Type 1")
            } header: {
                Text("Playback and files")
            } footer: {
                Text("New transcriptions start with this tempo and time signature.")
            }
            Section {
                Toggle("Save debug logs", isOn: $preferences.debugLogging)
                if preferences.debugLogging {
                    HStack(spacing: Metric.sp4) {
                        Text(logStatus).font(.caption).foregroundStyle(DebugLog.shared.problem == nil ? Native.fgSecondary : Token.warn)
                            .textSelection(.enabled)
                        Spacer()
                        Button("Show Logs in Finder", action: showLogs).disabled(DebugLog.shared.currentFile == nil)
                    }
                }
            } header: {
                Text("Troubleshooting")
            } footer: {
                Text("Writes what the app does, and the reason for a crash, to a Logs folder in your working folder: one file per launch, the newest 10 kept. Logs name your files but never hold your Hugging Face token or your audio. Leave this off unless you are tracking down a problem.")
            }
        }
        .formStyle(.grouped)
    }

    private var logStatus: String {
        if let problem = DebugLog.shared.problem { return problem }
        guard let file = DebugLog.shared.currentFile else { return "Starting\u{2026}" }
        return "Writing to \(DebugLog.folderName)/\(file.lastPathComponent)"
    }

    private func showLogs() {
        if let file = DebugLog.shared.currentFile { NSWorkspace.shared.activateFileViewerSelecting([file]) }
    }

    private func directory(inDefaultLocation: Bool) -> URL {
        if !inDefaultLocation, let folder = workingFolder.folder { return folder.deletingLastPathComponent() }
        return WorkingFolderStore.suggestedFolder.deletingLastPathComponent()
    }

    private func pick(inDefaultLocation: Bool) {
        workingFolder.choose(using: SystemFolderPanel(), startingIn: directory(inDefaultLocation: inDefaultLocation))
    }
}
