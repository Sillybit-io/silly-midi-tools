import Foundation
import Testing
@testable import SillyMIDITools

private func entry(_ id: String) -> ModelEntry { ModelCatalog.entries.first { $0.id == id }! }

private let ran = AudioScreenModel.RunRecord(modelID: "basic-pitch", modelName: "Basic Pitch", start: 2, end: 12.5,
                                             instruments: [], estimatesVelocity: true, took: 4)

@MainActor
struct HandoffStringsTests {
    @Test func theFooterSummaryUsesTheHandoffWording() {
        typealias S = AudioScreenModel
        #expect(S.summary(state: .idle, noteCount: 0, instrumentCount: 0, ran: nil, changed: false) == "No notes yet")
        #expect(S.summary(state: .running, noteCount: 3, instrumentCount: 1, ran: ran, changed: false)
            == "Transcribing 2.0\u{2013}12.5 s with Basic Pitch\u{2026}")
        #expect(S.summary(state: .done(48), noteCount: 48, instrumentCount: 1, ran: ran, changed: false)
            == "Done \u{2014} 48 notes \u{00B7} 1 instrument \u{00B7} 2.0\u{2013}12.5 s \u{00B7} Basic Pitch \u{00B7} 4 s")
        #expect(S.summary(state: .cancelled, noteCount: 9, instrumentCount: 2, ran: ran, changed: true)
            == "Cancelled \u{2014} partial notes kept \u{00B7} 2 instruments \u{00B7} 2.0\u{2013}12.5 s \u{00B7} Basic Pitch \u{00B7} 4 s \u{00B7} Changed \u{2014} transcribe again to apply")
    }

    @Test func downloadStepTitleCountsInTheSizesUnit() {
        #expect(AudioScreenModel.downloadTitle(entry("muscriptor-small"), fraction: 0.2).hasPrefix("Downloading MuScriptor Small \u{00B7} "))
        #expect(AudioScreenModel.downloadTitle(entry("piano-onnx"), fraction: 0).hasSuffix(" \u{00B7} 0 of 154 MB"))
        #expect(AudioScreenModel.downloadTitle(entry("piano-onnx"), fraction: 2).contains(" of 154 MB"))
    }

    @Test func theEditorSubtitleAndFooterMatchThePrototype() {
        #expect(ContentView.editorSubtitle(notes: 24, tracks: 1, grid: .standard, dirty: false)
            == "24 notes \u{00B7} 1 track \u{00B7} 120 BPM 4/4")
        #expect(ContentView.editorSubtitle(notes: 1, tracks: 3, grid: MIDIGrid(bpm: 95, numerator: 3, denominator: 4), dirty: true)
            == "1 note \u{00B7} 3 tracks \u{00B7} 95 BPM 3/4 \u{00B7} Edited")
        let threeMeters = MIDIGrid(bpm: 120, meters: [MeterChange(bar: 0, numerator: 4, denominator: 4),
                                                       MeterChange(bar: 2, numerator: 3, denominator: 4),
                                                       MeterChange(bar: 4, numerator: 6, denominator: 8)])
        #expect(ContentView.editorSubtitle(notes: 8, tracks: 2, grid: threeMeters, dirty: false)
            == "8 notes \u{00B7} 2 tracks \u{00B7} 120 BPM 4/4 \u{00B7} 2 meter changes")

        let notes = [EditorNote(id: 1, track: "piano", pitch: 60, start: 1.25, duration: 0.5, velocity: 90),
                     EditorNote(id: 2, track: "piano", pitch: 64, start: 2, duration: 0.5, velocity: 90)]
        let name: (String) -> String = { $0 == "piano" ? "Piano" : $0 }
        #expect(MIDIEditorView.summary(notes: notes, selection: [], trackName: name, skipped: 0)
            == "2 notes \u{00B7} drag empty space to select, \u{2325}\u{2190} \u{2325}\u{2192} to step through notes, D to draw, E to erase")
        #expect(MIDIEditorView.summary(notes: notes, selection: [1], trackName: name, skipped: 0) == "C4 \u{00B7} Piano \u{00B7} 1.25 s \u{2014} 1 of 2 selected")
        #expect(MIDIEditorView.summary(notes: notes, selection: [1, 2], trackName: name, skipped: 0) == "2 of 2 notes selected")
        #expect(MIDIEditorView.summary(notes: notes, selection: [], trackName: name, skipped: 3).hasSuffix(" \u{00B7} 3 outside C1\u{2013}B6 skipped"))
    }

    @Test func subtitleFormatsFractionalTempoSingleMeterChangeAndDirtySuffix() {
        let grid = MIDIGrid(bpm: 93.5, meters: [MeterChange(bar: 0, numerator: 6, denominator: 8),
                                                MeterChange(bar: 3, numerator: 3, denominator: 4)])
        #expect(ContentView.editorSubtitle(notes: 1, tracks: 1, grid: grid, dirty: true)
            == "1 note \u{00B7} 1 track \u{00B7} 93.5 BPM 6/8 \u{00B7} 1 meter change \u{00B7} Edited")
        #expect(ContentView.editorSubtitle(notes: 0, tracks: 1, grid: MIDIGrid(bpm: 93.55, numerator: 4, denominator: 4), dirty: false)
            == "0 notes \u{00B7} 1 track \u{00B7} 93.55 BPM 4/4")
    }

    @Test func audioThatCantBeOpenedGetsTheHandoffAlert() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "scratch-open-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let oggURL = folder.appending(path: "take.ogg"), wavURL = folder.appending(path: "Take 3.WAV")
        try Data([1, 2, 3]).write(to: oggURL)
        try Data([1, 2, 3]).write(to: wavURL)
        let ogg = AudioOpenFailure.decoding(oggURL)
        #expect(ogg.title == "Could not open audio")
        #expect(ogg.message == "This file can't be decoded. OGG isn't supported. Use WAV, MP3, FLAC, M4A or AIFF.")
        let wav = AudioOpenFailure.decoding(wavURL)
        #expect(wav.title == "Could not open \u{201C}Take 3.WAV\u{201D}")
        #expect(wav.message == "The file may be damaged, or it's in a format Core Audio can't read.")
        let gone = AudioOpenFailure.decoding(folder.appending(path: "gone.wav"))
        #expect(gone.title == "Could not open \u{201C}gone.wav\u{201D}")
        #expect(gone.message.hasPrefix("The file was moved or deleted."))
        let long = AudioOpenFailure.tooLong(folder.appending(path: "Set.wav"), seconds: 3600 + 12 * 60)
        #expect(long.title == "Could not open \u{201C}Set.wav\u{201D}")
        #expect(long.message == "It\u{2019}s 1 h 12 min long. Silly MIDI Tools opens audio up to 1 hour long, because it keeps the whole recording in memory. Split it into shorter files first.")
    }

    @Test func layoutSizesComeFromTheTokens() {
        #expect(Metric.mixSliderW == 220)
        #expect(Metric.aboutH == 460 && Metric.settingsMinH == 520)
        #expect(Metric.licenceSheetW == 560 && Metric.licenceTextH == 200)
        #expect(Metric.sliderW == 80 && Metric.readoutW == 40)
        #expect(Metric.toolbarItemH == 36 && Metric.dragIcon == 28)
    }

    @Test func theSeparatorToggleOnlyPromisesADownloadWhenOneIsNeeded() {
        let separator = entry(ModelCatalog.separatorID)
        let missing = AudioInspectorView.separatorNote(separator, installed: false)
        #expect(missing.contains("The first run downloads the Drum separator (HT-Demucs) helper (316 MB) once."))
        let installed = AudioInspectorView.separatorNote(separator, installed: true)
        #expect(installed.contains("Uses the Drum separator (HT-Demucs) you downloaded."))
        #expect(!installed.contains("downloads") && !installed.contains("316 MB"))
        #expect(installed.hasPrefix("Isolates the drums from the mix before listening."))
    }

    @Test func settingsSaysWhereTheDrumSeparatorIsSwitchedOn() {
        #expect(SettingsModelsView.helperUsage.contains("choose Drums (ADTOF) or Drums (OaF, Magenta) as the model"))
        #expect(SettingsModelsView.helperUsage.contains("turn on Separate drums first in the inspector\u{2019}s Drums section"))
        #expect(SettingsModelsView.helperUsage.contains("Tempo section of the Audio inspector"))
    }
}

@MainActor
struct VelocityLaneStrokeTests {
    private let layout = PianoRollLayout(pixelsPerSecond: 100, xOrigin: 0, laneHeight: 12, topPitch: 95)
    private let notes = [EditorNote(id: 1, track: "piano", pitch: 60, start: 0, duration: 0.5, velocity: 90),
                         EditorNote(id: 2, track: "piano", pitch: 62, start: 1, duration: 0.5, velocity: 90),
                         EditorNote(id: 3, track: "bass", pitch: 40, start: 1, duration: 0.5, velocity: 90)]

    @Test func aStrokePaintsTheNotesUnderItAlongItsSlope() {
        let values = MIDIVelocityLaneView.stroke(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 100, y: Metric.velH),
                                                 notes: notes, layout: layout, selection: [], hiddenTracks: [])
        #expect(values == [1: 127, 2: 1, 3: 1])
    }

    @Test func withASelectionOnlySelectedNotesChangeAndHiddenTracksNever() {
        let selected = MIDIVelocityLaneView.stroke(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 100, y: 0),
                                                   notes: notes, layout: layout, selection: [2], hiddenTracks: [])
        #expect(selected == [2: 127])
        let hidden = MIDIVelocityLaneView.stroke(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 100, y: 0),
                                                 notes: notes, layout: layout, selection: [], hiddenTracks: ["bass"])
        #expect(hidden == [1: 127, 2: 127])
    }
}
