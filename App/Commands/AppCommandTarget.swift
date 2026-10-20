import SwiftUI

/// What the menu bar needs from the focused window: whether each command is available, and a call into the same action the
/// matching button uses. The window publishes a fresh one whenever its models change, and menus read it through
/// `@FocusedValue`, so they always act on the window that has focus and never on one that lost it.
struct AppCommandTarget {
    enum Screen { case audio, midi, empty }

    var screen = Screen.empty
    var canSave = false
    var canExport = false
    var hasSelection = false
    var canQuantize = false
    var canTranscribe = false
    var isTranscribing = false
    var canResetSlice = false
    var canDetectKey = false
    var canDetectTempo = false
    var canPlay = false
    var isPlaying = false
    var isLooping = false
    var isClickOn = false
    var canSelectAudio = false
    var canSelectMIDI = false
    var hasWorkingFolder = false
    var tool: MIDITool?
    var inspectorShown = false

    var openAudio: () -> Void = {}
    var importMIDI: () -> Void = {}
    var save: () -> Void = {}
    var export: () -> Void = {}
    var showWorkingFolder: () -> Void = {}
    var deleteSelection: () -> Void = {}
    var transposeUp: () -> Void = {}
    var transposeDown: () -> Void = {}
    var quantize: () -> Void = {}
    var transcribe: () -> Void = {}
    var cancelTranscription: () -> Void = {}
    var resetSlice: () -> Void = {}
    var detectKey: () -> Void = {}
    var detectTempo: () -> Void = {}
    var toggleInspector: () -> Void = {}
    var zoomIn: () -> Void = {}
    var zoomOut: () -> Void = {}
    var setTool: (MIDITool) -> Void = { _ in }
    var togglePlayback: () -> Void = {}
    var stop: () -> Void = {}
    var toggleLoop: () -> Void = {}
    var toggleClick: () -> Void = {}
    var selectAudio: () -> Void = {}
    var selectMIDI: () -> Void = {}
    var showWelcome: () -> Void = {}
    var showShortcuts: () -> Void = {}
}

private struct AppCommandTargetKey: FocusedValueKey {
    typealias Value = AppCommandTarget
}

extension FocusedValues {
    var commandTarget: AppCommandTarget? {
        get { self[AppCommandTargetKey.self] }
        set { self[AppCommandTargetKey.self] = newValue }
    }
}
