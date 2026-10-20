import AppKit
import SwiftUI

/// The one menu implementation. Every item runs through the focused window's `AppCommandTarget`.
struct AppCommands: Commands {
    @FocusedValue(\.commandTarget) private var target
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @AppStorage("settingsTab") private var settingsTab = "general"
    @AppStorage("aboutTab") private var aboutTab = "about"

    private static let repository = URL(string: "https://github.com/Sillybit-io/silly-midi-tools")!

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Silly MIDI Tools") { openAbout("about") }
        }
        CommandGroup(after: .appSettings) {
            Button("Manage Models\u{2026}") { openSettings(tab: "models") }
        }
        CommandGroup(replacing: .newItem) {
            Button("Open Audio\u{2026}") { target?.openAudio() }
                .keyboardShortcut("o").disabled(target == nil)
            Button("Import MIDI\u{2026}") { target?.importMIDI() }
                .keyboardShortcut("o", modifiers: [.command, .shift]).disabled(target == nil)
            Divider()
            Button("Save") { target?.save() }
                .keyboardShortcut("s").disabled(!(target?.canSave ?? false))
            Button("Export MIDI\u{2026}") { target?.export() }
                .keyboardShortcut("e").disabled(!(target?.canExport ?? false))
            Divider()
            Button("Show Working Folder in Finder") { target?.showWorkingFolder() }
                .disabled(!(target?.hasWorkingFolder ?? false))
            Button("Change Working Folder\u{2026}") { openSettings(tab: "general") }
        }
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Delete Notes") { target?.deleteSelection() }.disabled(!(target?.hasSelection ?? false))
            Button("Transpose Up") { target?.transposeUp() }.disabled(!(target?.hasSelection ?? false))
            Button("Transpose Down") { target?.transposeDown() }.disabled(!(target?.hasSelection ?? false))
            Button("Quantize") { target?.quantize() }.disabled(!(target?.canQuantize ?? false))
        }
        CommandMenu("Transcribe") {
            Button("Transcribe") { target?.transcribe() }.disabled(!(target?.canTranscribe ?? false))
            Button("Cancel Transcription") { target?.cancelTranscription() }
                .keyboardShortcut(".").disabled(!(target?.isTranscribing ?? false))
            Divider()
            Button("Reset Slice") { target?.resetSlice() }.disabled(!(target?.canResetSlice ?? false))
            Button("Detect Key from Audio") { target?.detectKey() }.disabled(!(target?.canDetectKey ?? false))
            Button("Detect Tempo") { target?.detectTempo() }.disabled(!(target?.canDetectTempo ?? false))
            Divider()
            Button("Manage Models\u{2026}") { openSettings(tab: "models") }
        }
        CommandGroup(after: .toolbar) {
            Button(target?.inspectorShown == true ? "Hide Inspector" : "Show Inspector") { target?.toggleInspector() }
                .keyboardShortcut("i", modifiers: [.command, .option]).disabled(target == nil)
            Divider()
            Button("Zoom In") { target?.zoomIn() }
                .keyboardShortcut("+").disabled(target?.screen == nil || target?.screen == .empty)
            Button("Zoom Out") { target?.zoomOut() }
                .keyboardShortcut("-").disabled(target?.screen == nil || target?.screen == .empty)
            Divider()
            Picker("Tool", selection: Binding(get: { target?.tool ?? .select }, set: { target?.setTool($0) })) {
                ForEach(MIDITool.allCases) { Text("\($0.title) Tool").tag($0) }
            }
            .pickerStyle(.inline).disabled(target?.tool == nil)
        }
        CommandMenu("Controls") {
            Button(target?.isPlaying == true ? "Pause" : "Play") { target?.togglePlayback() }.disabled(!(target?.canPlay ?? false))
            Button("Stop") { target?.stop() }.disabled(!(target?.canPlay ?? false))
            Toggle("Loop", isOn: Binding(get: { target?.isLooping ?? false }, set: { _ in target?.toggleLoop() }))
                .disabled(!(target?.canPlay ?? false))
            Toggle("Click", isOn: Binding(get: { target?.isClickOn ?? false }, set: { _ in target?.toggleClick() }))
                .keyboardShortcut("c", modifiers: []).disabled(!(target?.canPlay ?? false))
        }
        CommandGroup(after: .windowArrangement) {
            Divider()
            Button("Audio") { target?.selectAudio() }
                .keyboardShortcut("1").disabled(!(target?.canSelectAudio ?? false))
            Button("MIDI Editor") { target?.selectMIDI() }
                .keyboardShortcut("2").disabled(!(target?.canSelectMIDI ?? false))
            Divider()
            Button("Settings") { openSettings(tab: "general") }
            Button("About") { openAbout("about") }
        }
        CommandGroup(replacing: .help) {
            Button("Welcome to Silly MIDI Tools") { target?.showWelcome() }.disabled(target == nil)
            Button("Keyboard Shortcuts") { target?.showShortcuts() }
                .keyboardShortcut("/").disabled(target == nil)
            Divider()
            Button("Acknowledgements") { openAbout("licences") }
            Button("Silly MIDI Tools on GitHub") { NSWorkspace.shared.open(Self.repository) }
        }
    }

    private func openSettings(tab: String) {
        settingsTab = tab
        openSettings()
    }

    private func openAbout(_ tab: String) {
        aboutTab = tab
        openWindow(id: "about")
    }
}

#if DEBUG
/// Debug builds only: crashes the app on purpose, to check that the debug log records each kind of crash.
enum SimulatedCrash: String, CaseIterable {
    case swift, exception, memory

    var title: String {
        switch self {
        case .swift: "Swift Runtime Error"
        case .exception: "Uncaught Objective-C Exception"
        case .memory: "Bad Memory Access"
        }
    }

    func trigger() {
        debugLog(.app, "Simulating a crash: \(title).")
        switch self {
        case .swift:
            let empty: [Int] = []
            _ = empty[Int.random(in: 1...2)]
        case .exception:
            Thread.detachNewThread {
                NSException(name: .genericException, reason: "Simulated from the Debug menu", userInfo: nil).raise()
            }
        case .memory:
            UnsafeMutablePointer<Int>(bitPattern: 0x10)!.pointee = 1
        }
    }

    /// `open SillyMIDITools.app --args -SimulateCrash swift` crashes two seconds after launch, without the menu.
    static func fromLaunchArguments() {
        guard let name = UserDefaults.standard.string(forKey: "SimulateCrash"), let crash = SimulatedCrash(rawValue: name) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { crash.trigger() }
    }
}

struct SimulateCrashCommands: Commands {
    var body: some Commands {
        CommandMenu("Debug") {
            Menu("Simulate Crash") {
                ForEach(SimulatedCrash.allCases, id: \.self) { crash in
                    Button(crash.title) { crash.trigger() }
                }
            }
        }
    }
}
#endif
