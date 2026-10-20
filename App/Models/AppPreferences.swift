import Foundation
import Observation
import SwiftUI

enum AppearancePreference: String, CaseIterable, Identifiable {
    case automatic, light, dark

    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    var colorScheme: ColorScheme? {
        switch self {
        case .automatic: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

@MainActor @Observable
final class AppPreferences {
    static let defaultModelKey = "defaultModel"
    static let appearanceKey = "appearance"
    static let addAudioModeKey = "addAudioMode"
    static let followPlayheadKey = "followPlayhead"
    static let debugLoggingKey = "debugLogging"
    static let defaultBPMKey = "defaultBPM"
    static let defaultTimeSignatureNumeratorKey = "defaultTimeSignatureNumerator"
    static let defaultTimeSignatureDenominatorKey = "defaultTimeSignatureDenominator"
    static let fallbackModelID = "basic-pitch"

    /// The model a new Audio screen starts on. Basic Pitch is built in, so a first Transcribe never waits for a download.
    var defaultModelID: String {
        didSet { defaults.set(defaultModelID, forKey: Self.defaultModelKey) }
    }

    var appearance: AppearancePreference {
        didSet { defaults.set(appearance.rawValue, forKey: Self.appearanceKey) }
    }

    /// Whether audio added from outside the working folder is copied into `Audio/` or referenced where it is.
    var addAudioMode: AddAudioMode {
        didSet { defaults.set(addAudioMode.rawValue, forKey: Self.addAudioModeKey) }
    }

    var followPlayhead: Bool {
        didSet { defaults.set(followPlayhead, forKey: Self.followPlayheadKey) }
    }

    var defaultGrid: MIDIGrid {
        didSet {
            if defaultGrid.hasMeterChanges {
                let first = defaultGrid.meters[0]
                defaultGrid = MIDIGrid(bpm: defaultGrid.bpm, numerator: first.numerator, denominator: first.denominator)
            }
            defaults.set(defaultGrid.bpm, forKey: Self.defaultBPMKey)
            defaults.set(defaultGrid.meters[0].numerator, forKey: Self.defaultTimeSignatureNumeratorKey)
            defaults.set(defaultGrid.meters[0].denominator, forKey: Self.defaultTimeSignatureDenominatorKey)
        }
    }

    /// Writes a debug log to `Logs/` in the working folder. Off until the user turns it on.
    var debugLogging: Bool {
        didSet {
            defaults.set(debugLogging, forKey: Self.debugLoggingKey)
            onDebugLoggingChange(debugLogging)
        }
    }

    @ObservationIgnored var onDebugLoggingChange: (Bool) -> Void = { _ in }

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.string(forKey: Self.defaultModelKey)
        defaultModelID = ModelCatalog.entries.contains { $0.id == stored && $0.transcribes } ? stored! : Self.fallbackModelID
        appearance = defaults.string(forKey: Self.appearanceKey).flatMap(AppearancePreference.init) ?? .automatic
        addAudioMode = defaults.string(forKey: Self.addAudioModeKey).flatMap(AddAudioMode.init) ?? .copy
        followPlayhead = defaults.object(forKey: Self.followPlayheadKey) as? Bool ?? true
        defaultGrid = MIDIGrid(bpm: (defaults.object(forKey: Self.defaultBPMKey) as? NSNumber)?.doubleValue ?? 120,
                               numerator: (defaults.object(forKey: Self.defaultTimeSignatureNumeratorKey) as? NSNumber)?.intValue ?? 4,
                               denominator: (defaults.object(forKey: Self.defaultTimeSignatureDenominatorKey) as? NSNumber)?.intValue ?? 4)
        debugLogging = defaults.bool(forKey: Self.debugLoggingKey)
    }
}
