import Foundation
import Testing
@testable import SillyMIDITools

@MainActor @Suite(.serialized)
struct ClickTrackTests {
    private let meterMap = MIDIGrid(bpm: 120, meters: [
        MeterChange(bar: 0, numerator: 4, denominator: 4),
        MeterChange(bar: 4, numerator: 3, denominator: 4),
    ])

    /// `sync` and `replace` schedule notes in a task that waits for the sound bank, so the count settles later.
    private func waitForScheduledNotes(_ playback: PlaybackEngine, count: Int) async throws {
        for _ in 0..<500 where playback.scheduledNoteCount != count { try await Task.sleep(for: .milliseconds(20)) }
    }

    @Test func barBeatUsesTheChosenGrid() {
        #expect(PlaybackEngine.barBeatText(seconds: 2, grid: MIDIGrid(bpm: 90, numerator: 3, denominator: 4)) == "2.1")
        #expect(PlaybackEngine.barBeat(seconds: 1.5, grid: MIDIGrid(bpm: 120, numerator: 6, denominator: 8)) == (2, 1))
    }

    @Test func clicksFollowMeterChanges() {
        let beats = PlaybackEngine.clickBeats(grid: meterMap, upTo: 10)
        #expect(beats.filter(\.accented).map(\.seconds) == [0, 2, 4, 6, 8, 9.5])
        #expect(beats.filter { $0.seconds >= 8 && $0.seconds < 9.5 }.map(\.seconds) == [8, 8.5, 9])
        #expect(PlaybackEngine.clickBeats(grid: meterMap, from: 8.1, upTo: 9).map(\.seconds) == [8.5, 9])
    }

    @Test func clickAloneRendersAndSilenceDoesNot() async throws {
        let off = PlaybackEngine()
        #expect(try await off.renderOffline(notes: [], seconds: 0.4) == 0)
        let on = PlaybackEngine()
        on.click = true
        #expect(try await on.renderOffline(notes: [], seconds: 0.4) > 0.0001)
    }

    @Test func muteAndReplaceDoNotRemoveTheClick() async throws {
        let playback = PlaybackEngine()
        playback.click = true
        let note = NoteEvent(onset: 0, offset: 0.8, pitch: 60, program: 0, isDrum: false, instrument: "piano", velocity: 100, pitchBends: nil)
        playback.sync(notes: [note])
        try await waitForScheduledNotes(playback, count: 1)
        #expect(playback.scheduledNoteCount == 1)
        playback.setSilenced(["piano"])
        #expect(try await playback.renderOffline(notes: [note], seconds: 0.4) > 0.0001)
        playback.replace(notes: [])
        try await waitForScheduledNotes(playback, count: 0)
        #expect(playback.scheduledNoteCount == 0)
        #expect(try await playback.renderOffline(notes: [], seconds: 0.4) > 0.0001)
    }

    private func original(seconds: Double = 8) -> [Float] {
        (0..<Int(seconds * 44100)).map { Float(sin(2 * .pi * 440 * Double($0) / 44100)) * 0.1 }
    }

    @Test func audioOnlyStartsSequencerAndTransfersClockWithoutReschedulingOriginal() throws {
        let playback = PlaybackEngine()
        playback.setOriginal(samples: original(), sampleRate: 44100)
        try playback.enableOfflineTransportForTesting()
        playback.duration = 8
        playback.seek(to: 1.25)
        playback.click = true
        playback.play()
        #expect(playback.isPlaying && playback.isSequencerRunning, "\(playback.lastError ?? "no error")")
        #expect(playback.originalScheduleCount == 1)
        playback.handleTick(1.25)
        playback.click = false
        #expect(playback.isPlaying && !playback.isSequencerRunning)
        #expect(abs(playback.position - 1.25) < 0.05)
        playback.click = true
        #expect(playback.isPlaying && playback.isSequencerRunning, "\(playback.lastError ?? "no error")")
        #expect(abs(playback.position - 1.25) < 0.05)
        let scheduled = playback.originalScheduleCount
        playback.rate = 1.25
        playback.grid = meterMap
        playback.duration = 9
        playback.loops = true
        playback.loopStart = 1
        #expect(abs(playback.position - 1.25) < 0.05)
        #expect(playback.originalScheduleCount == scheduled)
        #expect(playback.scheduledNoteCount == 0)
        playback.seek(to: 2)
        #expect(playback.isPlaying && playback.isSequencerRunning)
        #expect(abs(playback.position - 2) < 0.05)
        #expect(playback.originalScheduleCount == scheduled + 1)
        playback.handleTick(9.01)
        #expect(playback.isPlaying && playback.isSequencerRunning)
        #expect(abs(playback.position - 1) < 0.05)
        #expect(playback.originalScheduleCount == scheduled + 2)
        playback.stop()
    }

    @Test func enablingClickDuringAudioOnlyPlaybackHandsOffTheWallClock() throws {
        let playback = PlaybackEngine()
        playback.setOriginal(samples: original(), sampleRate: 44100)
        try playback.enableOfflineTransportForTesting()
        playback.duration = 8
        playback.seek(to: 1.25)
        playback.play()
        #expect(playback.isPlaying && !playback.isSequencerRunning, "\(playback.lastError ?? "no error")")
        playback.handleTick(1.25)
        let scheduled = playback.originalScheduleCount
        playback.click = true
        #expect(playback.isPlaying && playback.isSequencerRunning, "\(playback.lastError ?? "no error")")
        #expect(abs(playback.position - 1.25) < 0.05)
        #expect(playback.originalScheduleCount == scheduled)
        playback.stop()
    }

    @Test func clickReschedulingLeavesInstrumentEventsAndOriginalBufferAlone() async throws {
        let playback = PlaybackEngine()
        playback.setOriginal(samples: original(), sampleRate: 44100)
        let note = NoteEvent(onset: 0, offset: 0.8, pitch: 60, program: 0, isDrum: false, instrument: "piano", velocity: 100, pitchBends: nil)
        playback.sync(notes: [note])
        try await waitForScheduledNotes(playback, count: 1)
        #expect(playback.scheduledNoteCount == 1)
        try playback.enableOfflineTransportForTesting()
        playback.duration = 8
        playback.seek(to: 1.25)
        playback.click = true
        playback.play()
        #expect(playback.isPlaying && playback.isSequencerRunning, "\(playback.lastError ?? "no error")")
        let originalSchedules = playback.originalScheduleCount
        playback.rate = 0.8
        playback.grid = meterMap
        playback.loops = true
        playback.duration = 9
        #expect(playback.scheduledNoteCount == 1)
        #expect(playback.originalScheduleCount == originalSchedules)
        #expect(abs(playback.position - 1.25) < 0.05)
        playback.click = false
        #expect(playback.isSequencerRunning)
        #expect(playback.originalScheduleCount == originalSchedules)
        playback.stop()
    }
}
