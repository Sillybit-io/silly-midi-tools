import AVFoundation
import Observation

/// Plays transcribed notes through AVAudioSequencer and one AVAudioUnitSampler per instrument group,
/// next to the original audio on a player node. Every group's sampler and track exist before a
/// sequence plays; a group that appears mid-playback pauses the transport briefly to be added.
@MainActor @Observable
final class PlaybackEngine {
    private struct Group {
        let sampler: AVAudioUnitSampler
        let track: AVMusicTrack
    }

    nonisolated static let soundBankURL = URL(fileURLWithPath: "/System/Library/Components/CoreAudio.component/Contents/Resources/gs_instruments.dls")
    /// 120 bpm: two beats per second.
    nonisolated static let beatsPerSecond = 2.0

    private(set) var isPlaying = false
    private(set) var position = 0.0
    private(set) var lastError: String? {
        didSet { if let lastError, lastError != oldValue { debugLog(.playback, "Playback error: \(lastError)") } }
    }
    /// The end of the material: the slice's length, or the end of the last note. Looping wraps here.
    var duration = 0.0 { didSet { rescheduleClick() } }
    var loops = false { didSet { rescheduleClick() } }
    var loopStart = 0.0 { didSet { rescheduleClick() } }
    var grid: MIDIGrid = .standard { didSet { rescheduleClick() } }
    var click = false { didSet { if click != oldValue { updateClick() } } }
    /// Playback pauses here while a transcription is still running.
    var limit: Double? { didSet { if let limit, waitingForLimit, position < limit { play() } } }
    var mix = 0.5 { didSet { applyMix() } }
    var rate: Float = 1 {
        willSet { if isPlaying, clockStart != nil { position = currentPosition; clockStart = (position, Date()) } }
        didSet { sequencer.rate = rate; timePitch.rate = rate; rescheduleClick() }
    }

    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private let player = AVAudioPlayerNode()
    @ObservationIgnored private let timePitch = AVAudioUnitTimePitch()
    @ObservationIgnored private let sequencer: AVAudioSequencer
    @ObservationIgnored private let clickSampler: AVAudioUnitSampler
    @ObservationIgnored private let clickTrack: AVMusicTrack
    @ObservationIgnored private var clickSoundLoaded = false
    @ObservationIgnored private var clickScheduledThrough = 0.0
    @ObservationIgnored private(set) var originalScheduleCount = 0
    @ObservationIgnored private var groups: [String: Group] = [:]
    @ObservationIgnored private var muted: Set<String> = []
    @ObservationIgnored private var added = 0
    @ObservationIgnored private var latest: [NoteEvent] = []
    @ObservationIgnored private var syncing = false
    @ObservationIgnored private var rebuild = false
    @ObservationIgnored private var original: AVAudioPCMBuffer?
    @ObservationIgnored private var originalFormat: AVAudioFormat?
    @ObservationIgnored private var waitingForLimit = false
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var clockStart: (position: Double, time: Date)?

    var isSequencerRunning: Bool { sequencer.isPlaying }
    var scheduledNoteCount: Int { added }

    #if DEBUG
    func enableOfflineTransportForTesting() throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
    }
    #endif

    init() {
        sequencer = AVAudioSequencer(audioEngine: engine)
        clickSampler = AVAudioUnitSampler()
        clickTrack = sequencer.createAndAppendTrack()
        engine.attach(clickSampler)
        engine.connect(clickSampler, to: engine.mainMixerNode, format: nil)
        clickTrack.destinationAudioUnit = clickSampler
        clickTrack.isMuted = true
        engine.attach(player)
        engine.attach(timePitch)
        engine.connect(player, to: timePitch, format: nil)
        engine.connect(timePitch, to: engine.mainMixerNode, format: nil)
        sequencer.tempoTrack.addEvent(AVExtendedTempoEvent(tempo: 120), at: 0)
        applyMix()
    }

    // MARK: Pure helpers

    nonisolated static func beats(forSeconds seconds: Double) -> Double { seconds * beatsPerSecond }

    nonisolated static func patch(program: Int, isDrum: Bool) -> (program: UInt8, bankMSB: UInt8, bankLSB: UInt8) {
        if isDrum || program >= 128 { return (0, 0x78, 0) }
        return (UInt8(max(0, min(127, program))), 0x79, 0)
    }

    nonisolated static func groupKey(_ note: NoteEvent) -> String { note.isDrum ? "drums" : note.instrument }

    /// What the transport does with a measured position.
    enum Step: Equatable {
        case keep(Double)
        /// Jump back to the loop start and keep playing.
        case wrap(to: Double)
        /// A transcription is still running: wait at the last finalized note.
        case hold(at: Double)
        case finish
    }

    nonisolated static func step(position: Double, duration: Double, loops: Bool, loopStart: Double, limit: Double?) -> Step {
        if let limit { return position >= limit ? .hold(at: limit) : .keep(position) }
        guard duration > 0, position >= duration else { return .keep(position) }
        return loops ? .wrap(to: min(max(0, loopStart), duration)) : .finish
    }

    nonisolated static func barBeat(seconds: Double, grid: MIDIGrid = .standard) -> (bar: Int, beat: Int) {
        grid.barBeat(atSeconds: seconds)
    }

    nonisolated static func barBeatText(seconds: Double, grid: MIDIGrid = .standard) -> String {
        let value = barBeat(seconds: seconds, grid: grid)
        return "\(value.bar).\(value.beat)"
    }

    nonisolated static func clickBeats(grid: MIDIGrid, from start: Double = 0, upTo end: Double) -> [(seconds: Double, accented: Bool)] {
        guard end.isFinite, end >= 0 else { return [] }
        let start = start.isFinite ? max(0, start) : 0
        var bar = max(0, grid.barBeat(atSeconds: start).bar - 1)
        var beats: [(seconds: Double, accented: Bool)] = []
        while true {
            let barStart = grid.seconds(ofBar: bar)
            if barStart > end { break }
            let segment = grid.segment(atSeconds: barStart)
            for beat in 0..<segment.beatsPerBar {
                let seconds = barStart + Double(beat) * segment.secondsPerBeat
                if seconds >= start, seconds <= end { beats.append((seconds, beat == 0)) }
            }
            bar += 1
        }
        return beats
    }

    /// `m:ss.s`
    nonisolated static func timeText(seconds: Double) -> String {
        let tenths = Int((max(0, seconds) * 10).rounded(.down))
        return String(format: "%d:%02d.%d", tenths / 600, tenths / 10 % 60, tenths % 10)
    }

    /// Where a roll should scroll to keep the playhead in view, or nil when it already is. The playhead is kept in the
    /// left nine tenths of the viewport; leaving it jumps a page so the view isn't redrawn on every tick.
    nonisolated static func followOffset(playheadX: CGFloat, offsetX: CGFloat, viewport: CGFloat) -> CGFloat? {
        guard viewport > 0 else { return nil }
        if playheadX >= offsetX, playheadX <= offsetX + viewport * 0.9 { return nil }
        return max(0, playheadX - viewport * 0.1)
    }

    // MARK: Original audio

    func setOriginal(samples: [Float], sampleRate: Double) {
        guard !samples.isEmpty, let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { original = nil; return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        original = buffer
        // The time-pitch unit cannot convert channel counts or sample rates, so both of its connections take the
        // file's format; the mixer converts to the output device.
        guard originalFormat != format else { return }
        if engine.isRunning { engine.stop() }
        engine.connect(player, to: timePitch, format: format)
        engine.connect(timePitch, to: engine.mainMixerNode, format: format)
        originalFormat = format
    }

    private func applyMix() {
        player.volume = Float(min(1, 2 * (1 - mix)))
        for group in groups.values { group.sampler.volume = Float(min(1, 2 * mix)) }
    }

    private func rescheduleClick(from seconds: Double? = nil) {
        guard click else { return }
        let start = seconds ?? (isPlaying ? currentPosition : position)
        let horizon = max(duration, start) + 30
        clearClickEvents()
        clickScheduledThrough = horizon
        for beat in Self.clickBeats(grid: grid, from: start, upTo: clickScheduledThrough) {
            let event = AVMIDINoteEvent(channel: 9, key: beat.accented ? 76 : 77, velocity: beat.accented ? 115 : 85,
                                        duration: Self.beats(forSeconds: min(0.1, grid.segment(atSeconds: beat.seconds).secondsPerBeat * 0.3)))
            clickTrack.addEvent(event, at: Self.beats(forSeconds: beat.seconds))
        }
    }

    private func clearClickEvents() {
        guard clickScheduledThrough > 0 else { return }
        clickTrack.clearEvents(in: AVBeatRange(start: 0, length: Self.beats(forSeconds: clickScheduledThrough + 1)))
        clickScheduledThrough = 0
    }

    private func updateClick() {
        if click {
            if !clickSoundLoaded {
                do {
                    try clickSampler.loadSoundBankInstrument(at: Self.soundBankURL, program: 0, bankMSB: 0x78, bankLSB: 0)
                    clickSoundLoaded = true
                } catch {
                    lastError = "Could not load the General MIDI sound bank: \(error.localizedDescription)"
                }
            }
            clickTrack.isMuted = false
            if isPlaying, groups.isEmpty, clockStart != nil {
                position = currentPosition
                sequencer.currentPositionInSeconds = position
                clockStart = nil
            }
            rescheduleClick()
            if isPlaying, groups.isEmpty, !sequencer.isPlaying {
                do {
                    sequencer.prepareToPlay()
                    try sequencer.start()
                } catch {
                    lastError = error.localizedDescription
                    clockStart = (position, Date())
                }
            }
        } else {
            if isPlaying, groups.isEmpty, sequencer.isPlaying {
                position = currentPosition
                clockStart = (position, Date())
                sequencer.stop()
            }
            clickTrack.isMuted = true
            clearClickEvents()
        }
    }

    // MARK: Notes

    /// Replaces every note, for a document whose notes can change anywhere (the MIDI editor), not only grow.
    func replace(notes: [NoteEvent]) {
        rebuild = true
        sync(notes: notes)
    }

    func sync(notes: [NoteEvent]) {
        latest = notes
        guard !syncing else { return }
        syncing = true
        Task { @MainActor in
            while true {
                let snapshot = latest
                await apply(snapshot)
                if latest.count == snapshot.count, !rebuild { break }
            }
            syncing = false
        }
    }

    private func apply(_ notes: [NoteEvent]) async {
        if notes.count < added || rebuild {
            rebuild = false
            for group in groups.values { group.track.clearEvents(in: AVBeatRange(start: 0, length: .greatestFiniteMagnitude)) }
            added = 0
        }
        for note in notes[added...] {
            let key = Self.groupKey(note)
            if groups[key] == nil { await createGroup(key, program: note.program, isDrum: note.isDrum) }
            guard let group = groups[key], note.offset > note.onset else { continue }
            let event = AVMIDINoteEvent(channel: note.isDrum ? 9 : 0, key: UInt32(max(0, min(127, note.pitch))),
                                        velocity: UInt32(note.velocity ?? 100), duration: Self.beats(forSeconds: note.offset - note.onset))
            group.track.addEvent(event, at: Self.beats(forSeconds: note.onset))
        }
        added = notes.count
    }

    private func createGroup(_ key: String, program: Int, isDrum: Bool) async {
        let resume = isPlaying
        if resume { pauseTransport() }
        let sampler = AVAudioUnitSampler()
        engine.attach(sampler)
        engine.connect(sampler, to: engine.mainMixerNode, format: nil)
        let patch = Self.patch(program: program, isDrum: isDrum)
        nonisolated(unsafe) let unit = sampler
        do {
            try await Task.detached(priority: .userInitiated) {
                try unit.loadSoundBankInstrument(at: Self.soundBankURL, program: patch.program, bankMSB: patch.bankMSB, bankLSB: patch.bankLSB)
            }.value
        } catch {
            lastError = "Could not load the General MIDI sound bank: \(error.localizedDescription)"
        }
        let track = sequencer.createAndAppendTrack()
        track.destinationAudioUnit = sampler
        track.isMuted = muted.contains(key)
        groups[key] = Group(sampler: sampler, track: track)
        applyMix()
        if resume { play() }
    }

    func setMuted(_ key: String, _ isMuted: Bool) {
        if isMuted { muted.insert(key) } else { muted.remove(key) }
        groups[key]?.track.isMuted = isMuted
    }

    /// Silences exactly these groups. Muting only switches a track off; no note is touched.
    func setSilenced(_ keys: Set<String>) {
        muted = keys
        for (key, group) in groups { group.track.isMuted = keys.contains(key) }
    }

    // MARK: Transport

    func play() {
        guard !isPlaying else { return }
        waitingForLimit = false
        if let limit, position >= limit { waitingForLimit = true; return }
        do {
            if !engine.isRunning { try engine.start() }
            sequencer.currentPositionInSeconds = position
            sequencer.rate = rate
            schedulePlayer(from: position)
            if groups.isEmpty && !click {
                clockStart = (position, Date())
            } else {
                clockStart = nil
                rescheduleClick()
                sequencer.prepareToPlay()
                try sequencer.start()
            }
            player.play()
            isPlaying = true
            startTicker()
            debugLog(.playback, String(format: "Playing from %.2f s at %.2f\u{00D7}, %ld instrument groups.", position, rate, groups.count))
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func schedulePlayer(from seconds: Double) {
        player.stop()
        guard let original else { return }
        let rate = original.format.sampleRate
        let start = AVAudioFramePosition(seconds * rate)
        guard start < AVAudioFramePosition(original.frameLength) else { return }
        let remaining = AVAudioFrameCount(AVAudioFramePosition(original.frameLength) - start)
        guard let segment = AVAudioPCMBuffer(pcmFormat: original.format, frameCapacity: remaining) else { return }
        segment.frameLength = remaining
        segment.floatChannelData![0].update(from: original.floatChannelData![0] + Int(start), count: Int(remaining))
        player.scheduleBuffer(segment, completionHandler: nil)
        originalScheduleCount += 1
    }

    private var currentPosition: Double {
        if let clockStart { return clockStart.position + Date().timeIntervalSince(clockStart.time) * Double(rate) }
        return sequencer.currentPositionInSeconds
    }

    private func pauseTransport() {
        position = currentPosition
        clockStart = nil
        sequencer.stop()
        player.stop()
        isPlaying = false
        ticker?.cancel()
    }

    func pause() {
        waitingForLimit = false
        if isPlaying { pauseTransport() }
    }

    func stop() {
        if isPlaying { debugLog(.playback, "Stopped.") }
        pause()
        position = 0
        sequencer.currentPositionInSeconds = 0
    }

    /// Moves the playhead, never before the start or past the end of the material.
    func seek(to seconds: Double) {
        let resume = isPlaying
        if resume { pauseTransport() }
        position = max(0, duration > 0 ? min(seconds, duration) : seconds)
        if resume { play() } else { rescheduleClick() }
    }

    private func startTicker() {
        ticker?.cancel()
        ticker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(33))
                guard let self, self.isPlaying else { return }
                if self.click, self.currentPosition > self.clickScheduledThrough - 5 { self.rescheduleClick() }
                if !self.handleTick(self.currentPosition) { return }
            }
        }
    }

    /// Applies the transport's decision for a measured position. Returns false when the ticker should end: the transport
    /// was paused, restarted from the loop start, or stopped.
    @discardableResult
    func handleTick(_ measured: Double) -> Bool {
        position = measured
        switch Self.step(position: measured, duration: duration, loops: loops, loopStart: loopStart, limit: limit) {
        case .keep:
            return true
        case .hold(let limit):
            pauseTransport()
            position = limit
            waitingForLimit = true
            return false
        case .wrap(let start):
            seek(to: start)
            return false
        case .finish:
            stop()
            return false
        }
    }

    // MARK: Offline rendering (tests)

    /// Renders the synthesised notes, and the original audio if one is loaded, offline and returns the RMS of the output.
    func renderOffline(notes: [NoteEvent], seconds: Double) async throws -> Float {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
        await apply(notes)
        // Nothing to play: skip the engine, whose start is unreliable on an empty graph.
        guard !groups.isEmpty || original != nil || click else {
            engine.disableManualRenderingMode()
            return 0
        }
        try engine.start()
        sequencer.currentPositionInSeconds = 0
        rescheduleClick(from: 0)
        if original != nil {
            schedulePlayer(from: 0)
            player.play()
        }
        if !groups.isEmpty || click {
            sequencer.prepareToPlay()
            try sequencer.start()
        }
        let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 4096)!
        var sum: Double = 0
        var count = 0
        var rendered = 0
        let total = Int(seconds * 44100)
        while rendered < total {
            let status = try engine.renderOffline(AVAudioFrameCount(min(4096, total - rendered)), to: buffer)
            guard status == .success else { break }
            for channel in 0..<Int(buffer.format.channelCount) {
                let data = buffer.floatChannelData![channel]
                for i in 0..<Int(buffer.frameLength) { sum += Double(data[i] * data[i]); count += 1 }
            }
            rendered += Int(buffer.frameLength)
        }
        if !groups.isEmpty || click { sequencer.stop() }
        player.stop()
        engine.stop()
        engine.disableManualRenderingMode()
        return count > 0 ? Float((sum / Double(count)).squareRoot()) : 0
    }
}
