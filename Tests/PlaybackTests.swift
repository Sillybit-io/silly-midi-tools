import Foundation
import Testing
@testable import SillyMIDITools

@MainActor @Suite(.serialized)
struct PlaybackTests {
    @Test func programMappingCoversAllGroups() {
        for program in 0...127 {
            let p = PlaybackEngine.patch(program: program, isDrum: false)
            #expect(Int(p.program) == program && p.bankMSB == 0x79)
        }
        let drums = PlaybackEngine.patch(program: 128, isDrum: true)
        #expect(drums.program == 0 && drums.bankMSB == 0x78)
    }

    @Test func beatConversion() {
        #expect(PlaybackEngine.beats(forSeconds: 1.5) == 3)
    }

    @Test func offlineRenderProducesSound() async throws {
        let note = NoteEvent(onset: 0, offset: 0.8, pitch: 60, program: 0, isDrum: false, instrument: "acoustic_piano", velocity: 100, pitchBends: nil)
        let rms = try await PlaybackEngine().renderOffline(notes: [note], seconds: 1)
        #expect(rms > 0.001)
    }

    @Test func offlineRenderOfNothingIsSilent() async throws {
        let rms = try await PlaybackEngine().renderOffline(notes: [], seconds: 0.5)
        #expect(rms < 0.0001)
    }

    private func sine(rate: Double, seconds: Double) -> [Float] {
        (0..<Int(rate * seconds)).map { 0.5 * Float(sin(2 * .pi * 440 * Double($0) / rate)) }
    }

    /// The original audio can have any sample rate; the engine must play it whatever the output device runs at.
    @Test(arguments: [8000.0, 16000.0, 22050.0, 44100.0, 48000.0, 96000.0])
    func originalAudioPlaysAtAnySampleRate(rate: Double) async throws {
        let playback = PlaybackEngine()
        playback.setOriginal(samples: sine(rate: rate, seconds: 1.5), sampleRate: rate)
        let rms = try await playback.renderOffline(notes: [], seconds: 1)
        #expect(rms > 0.2 && rms < 0.5, "rms \(rms) at \(rate) Hz")
    }

    @Test func notesStillSoundWithAnOriginalLoaded() async throws {
        let playback = PlaybackEngine()
        playback.setOriginal(samples: sine(rate: 48000, seconds: 1.5), sampleRate: 48000)
        playback.mix = 1
        let note = NoteEvent(onset: 0, offset: 0.8, pitch: 60, program: 0, isDrum: false, instrument: "acoustic_piano", velocity: 100, pitchBends: nil)
        let rms = try await playback.renderOffline(notes: [note], seconds: 1)
        #expect(rms > 0.001 && rms < 0.2, "rms \(rms)")
    }

    @Test func loadingTheSameFormatTwiceKeepsTheGraphWorking() async throws {
        let playback = PlaybackEngine()
        playback.setOriginal(samples: sine(rate: 44100, seconds: 1.5), sampleRate: 44100)
        playback.setOriginal(samples: sine(rate: 44100, seconds: 1.5), sampleRate: 44100)
        playback.setOriginal(samples: sine(rate: 48000, seconds: 1.5), sampleRate: 48000)
        let rms = try await playback.renderOffline(notes: [], seconds: 1)
        #expect(rms > 0.2 && rms < 0.5, "rms \(rms)")
    }
}

extension PlaybackTests {
    @Test func theTransportKeepsPlayingUntilTheEndOfTheMaterial() {
        #expect(PlaybackEngine.step(position: 1.5, duration: 4, loops: false, loopStart: 0, limit: nil) == .keep(1.5))
        #expect(PlaybackEngine.step(position: 3.999, duration: 4, loops: true, loopStart: 0, limit: nil) == .keep(3.999))
        #expect(PlaybackEngine.step(position: 4, duration: 4, loops: false, loopStart: 0, limit: nil) == .finish)
        #expect(PlaybackEngine.step(position: 0.5, duration: 0, loops: true, loopStart: 0, limit: nil) == .keep(0.5))
    }

    @Test func loopingWrapsToTheLoopStartAtTheEnd() {
        #expect(PlaybackEngine.step(position: 4.02, duration: 4, loops: true, loopStart: 0, limit: nil) == .wrap(to: 0))
        #expect(PlaybackEngine.step(position: 4.02, duration: 4, loops: true, loopStart: 1.5, limit: nil) == .wrap(to: 1.5))
        #expect(PlaybackEngine.step(position: 4.02, duration: 4, loops: true, loopStart: 9, limit: nil) == .wrap(to: 4))
        #expect(PlaybackEngine.step(position: 4.02, duration: 4, loops: true, loopStart: -2, limit: nil) == .wrap(to: 0))
    }

    @Test func aRunningTranscriptionHoldsTheTransportAtTheFinalizedEdgeEvenWhenLooping() {
        #expect(PlaybackEngine.step(position: 2, duration: 4, loops: true, loopStart: 0, limit: 3) == .keep(2))
        #expect(PlaybackEngine.step(position: 3.01, duration: 4, loops: true, loopStart: 0, limit: 3) == .hold(at: 3))
        #expect(PlaybackEngine.step(position: 5, duration: 4, loops: false, loopStart: 0, limit: 3) == .hold(at: 3))
    }

    @Test func aFourSecondSliceWithLoopReturnsToTheSliceStart() {
        let engine = PlaybackEngine()
        engine.duration = 4
        engine.loops = true
        #expect(engine.handleTick(2.5))
        #expect(engine.position == 2.5)
        #expect(!engine.handleTick(4.03))
        #expect(engine.position == 0)
        #expect(!engine.isPlaying)
        #expect(engine.rate == 1)
    }

    @Test func seekingStaysInsideTheMaterial() {
        let engine = PlaybackEngine()
        engine.seek(to: 12)
        #expect(engine.position == 12)
        engine.duration = 4
        engine.seek(to: 12)
        #expect(engine.position == 4)
        engine.seek(to: -3)
        #expect(engine.position == 0)
        engine.seek(to: 2.5)
        #expect(engine.position == 2.5 && !engine.isPlaying)
        engine.stop()
        #expect(engine.position == 0)
    }

    @Test func withoutLoopTheEndStopsAtTheStart() {
        let engine = PlaybackEngine()
        engine.duration = 4
        #expect(!engine.handleTick(4.03))
        #expect(engine.position == 0 && !engine.isPlaying)
        engine.loopStart = 1
        engine.loops = true
        #expect(!engine.handleTick(4.01))
        #expect(engine.position == 1)
    }

    @Test func barAndBeatAt120BPMInFourFour() {
        #expect(PlaybackEngine.barBeatText(seconds: 0) == "1.1")
        #expect(PlaybackEngine.barBeatText(seconds: 0.49) == "1.1")
        #expect(PlaybackEngine.barBeatText(seconds: 0.5) == "1.2")
        #expect(PlaybackEngine.barBeatText(seconds: 1.999) == "1.4")
        #expect(PlaybackEngine.barBeatText(seconds: 2) == "2.1")
        #expect(PlaybackEngine.barBeatText(seconds: 7.25) == "4.3")
        #expect(PlaybackEngine.barBeatText(seconds: -3) == "1.1")
        #expect(PlaybackEngine.barBeat(seconds: 63.9) == (32, 4))
    }

    @Test func timeIsShownAsMinutesSecondsAndTenths() {
        #expect(PlaybackEngine.timeText(seconds: 0) == "0:00.0")
        #expect(PlaybackEngine.timeText(seconds: 4) == "0:04.0")
        #expect(PlaybackEngine.timeText(seconds: 65.37) == "1:05.3")
        #expect(PlaybackEngine.timeText(seconds: 600) == "10:00.0")
        #expect(PlaybackEngine.timeText(seconds: -1) == "0:00.0")
    }

    @Test func followScrollsOnlyWhenThePlayheadLeavesTheViewport() {
        #expect(PlaybackEngine.followOffset(playheadX: 500, offsetX: 400, viewport: 1000) == nil)
        #expect(PlaybackEngine.followOffset(playheadX: 1300, offsetX: 400, viewport: 1000) == nil)
        #expect(PlaybackEngine.followOffset(playheadX: 1301, offsetX: 400, viewport: 1000) == 1201)
        #expect(PlaybackEngine.followOffset(playheadX: 2000, offsetX: 400, viewport: 1000) == 1900)
        #expect(PlaybackEngine.followOffset(playheadX: 0, offsetX: 400, viewport: 1000) == 0)
        #expect(PlaybackEngine.followOffset(playheadX: 50, offsetX: 400, viewport: 1000) == 0)
        #expect(PlaybackEngine.followOffset(playheadX: 300, offsetX: 400, viewport: 1000) == 200)
        #expect(PlaybackEngine.followOffset(playheadX: 300, offsetX: 0, viewport: 0) == nil)
    }

    @Test func muteSoloAndHideSilenceTracksWithoutEditingNotes() {
        let tracks = [MIDITrack(id: "piano", name: "piano", program: 0, isDrums: false),
                      MIDITrack(id: "kit", name: "kit", program: 0, isDrums: true),
                      MIDITrack(id: "bass", name: "bass", program: 33, isDrums: false)]
        let notes = [EditorNote(id: 1, track: "piano", pitch: 60, start: 0, duration: 1, velocity: 90),
                     EditorNote(id: 2, track: "kit", pitch: 36, start: 0, duration: 0.5, velocity: 100),
                     EditorNote(id: 3, track: "bass", pitch: 40, start: 1, duration: 1, velocity: 80)]
        let imported = ImportedMIDI(tracks: tracks, notes: notes, grid: .standard, skippedNotes: 0, provenance: nil)
        let editor = MIDIEditorModel(url: URL(fileURLWithPath: "/tmp/silence.mid"), imported: imported)
        let document = editor.document
        #expect(editor.silencedGroups.isEmpty)

        document.toggleMute("piano")
        #expect(editor.silencedGroups == ["piano"])
        document.toggleSolo("bass")
        #expect(editor.silencedGroups == ["piano", "drums"])
        document.toggleMute("piano")
        document.toggleSolo("bass")
        document.toggleHidden("kit")
        #expect(editor.silencedGroups == ["drums"])
        #expect(editor.document.isAudible(track: "piano") && !editor.document.isAudible(track: "kit"))

        #expect(document.notes == notes)
        #expect(!document.isDirty && !document.isEdited && !document.canUndo)
    }

    @Test func theEditorHandsThePlaybackEngineTheEndOfTheLastNote() {
        let tracks = [MIDITrack(id: "piano", name: "piano", program: 0, isDrums: false)]
        let notes = [EditorNote(id: 1, track: "piano", pitch: 60, start: 0, duration: 1, velocity: 90),
                     EditorNote(id: 2, track: "piano", pitch: 62, start: 2.5, duration: 1.5, velocity: 90)]
        let imported = ImportedMIDI(tracks: tracks, notes: notes, grid: .standard, skippedNotes: 0, provenance: nil)
        let editor = MIDIEditorModel(url: URL(fileURLWithPath: "/tmp/extent.mid"), imported: imported)
        editor.syncPlayback()
        #expect(editor.playback.duration == 4)
        #expect(editor.playback.loopStart == 0)
    }
}
