import SwiftUI

/// Formatting stays independent of the inspector so the same suggestions can be used in the editor.
enum TempoDetectionText {
    static let emptyPulse = "No clear pulse"
    static let noAlignment = "No clear match"

    static func candidate(_ candidate: TempoCandidate) -> String {
        let bpm = String(format: "%.1f", candidate.bpm).replacingOccurrences(of: ".0", with: "")
        let relative: String
        switch candidate.relative {
        case .half: relative = " · half time"
        case .double: relative = " · double time"
        case .third: relative = " · third time"
        case .triple: relative = " · triple time"
        case nil: relative = ""
        }
        return "\(bpm) BPM · \(Int((candidate.score * 100).rounded()))%\(relative)"
    }

    static func alignment(_ result: OnsetAlignmentResult?) -> String {
        guard let result else { return noAlignment }
        let lag = Int((result.lag * 1000).rounded())
        return "\(Int((result.matchedShare * 100).rounded()))% of notes sit on an audio onset, \(abs(lag)) ms \(lag < 0 ? "early" : "late")"
    }

    static func meter(_ segments: [BeatThisMeterMap.Segment], denominator: Int) -> String {
        guard let first = segments.first else { return "Meter unclear" }
        return "\(first.beatsPerBar)/\(denominator)" + segments.dropFirst().map {
            ", then \($0.beatsPerBar)/\(denominator) from bar \($0.barIndex + 1)"
        }.joined()
    }

    static func steadiness(_ beats: [Double]) -> String {
        let intervals = zip(beats, beats.dropFirst()).map { $1 - $0 }.filter { $0 > 0 }
        guard intervals.count >= 2 else { return emptyPulse }
        let mean = intervals.reduce(0, +) / Double(intervals.count)
        let deviation = sqrt(intervals.reduce(0) { $0 + pow($1 - mean, 2) } / Double(intervals.count)) / mean
        return deviation < 0.02 ? "Steady" : "Tempo varies · \(Int((deviation * 100).rounded()))%"
    }

    static func bpmOffer(pulseBPM: Double, denominator: Int) -> String {
        let bpm = MIDIGrid(bpm: pulseBPM * 4 / Double(denominator), numerator: 4, denominator: denominator).bpm
        return String(format: "Use %.1f BPM (quarter notes; %d-note pulses)", bpm, denominator)
    }
}

struct TempoCandidatesView: View {
    let title: String
    let candidates: [TempoCandidate]
    let currentBPM: Double
    let onUse: (TempoCandidate) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Metric.sp2) {
            Text(title).font(.subheadline.bold())
            if candidates.isEmpty {
                Text(TempoDetectionText.emptyPulse).font(.caption).foregroundStyle(Native.fgSecondary)
            }
            ForEach(Array(candidates.prefix(3).enumerated()), id: \.offset) { _, candidate in
                HStack {
                    Text(TempoDetectionText.candidate(candidate)).font(.caption.monospacedDigit())
                    Spacer()
                    Button("Use") { onUse(candidate) }
                        .accessibilityLabel("Use \(TempoDetectionText.candidate(candidate))")
                }
            }
        }
    }
}

struct TempoDetectionView: View {
    @Bindable var screen: AudioScreenModel

    private var notes: [TempoCandidate] { TempoFromNotes.rank(notes: screen.usableNotes, currentBPM: screen.grid.bpm) }
    private var busy: Bool { !screen.canAnalyze }

    var body: some View {
        VStack(alignment: .leading, spacing: Metric.sp4) {
            TempoCandidatesView(title: "Tempo from notes", candidates: notes, currentBPM: screen.grid.bpm,
                                onUse: screen.useTempoFromNotes)
            Divider()
            HStack {
                Text("Tempo from audio").font(.subheadline.bold())
                Spacer()
                Button(screen.analysisOperation == .beatThis || screen.analysisOperation == .quickTempo ? "Analysing…" : "Detect from audio") {
                    screen.detectTempoFromAudio()
                }
                .disabled(busy)
                .help(screen.analysisBlocker ?? "Detect beats in the selected audio")
                .accessibilityLabel("Detect tempo from audio")
            }
            if screen.beatThisInstalled {
                Button("Quick estimate") { screen.startAnalysis(.quickTempo) }
                    .disabled(busy).help(screen.analysisBlocker ?? "Estimate a single tempo without the helper")
                    .accessibilityLabel("Quick tempo estimate")
            } else if let entry = screen.beatThisEntry {
                Button("Download Beat This! (\(entry.sizeText))") { screen.startAnalysis(.beatThisDownload) }
                    .disabled(busy).help(screen.analysisBlocker ?? "Download the beat and downbeat helper")
                    .accessibilityLabel("Download Beat This! helper")
            }
            if let quick = screen.currentQuickResult {
                TempoCandidatesView(title: "Quick estimate", candidates: quick.candidates, currentBPM: screen.grid.bpm,
                                    onUse: screen.useTempoFromAudio)
                if let pulse = quick.candidates.first?.bpm {
                    Text(TempoDetectionText.bpmOffer(pulseBPM: pulse, denominator: screen.grid.meters[0].denominator))
                        .font(.caption).foregroundStyle(Native.fgSecondary)
                }
                Text(TempoDetectionText.steadiness(quick.beats)).font(.caption).foregroundStyle(Native.fgSecondary)
            }
            if let beat = screen.currentBeatResult {
                Text(TempoDetectionText.steadiness(beat.beats)).font(.caption).foregroundStyle(Native.fgSecondary)
                if beat.beats.count > 1 {
                    let periods = zip(beat.beats, beat.beats.dropFirst()).map { $1 - $0 }.sorted()
                    let pulse = 60 / periods[periods.count / 2]
                    HStack {
                        Text(TempoDetectionText.bpmOffer(pulseBPM: pulse, denominator: screen.grid.meters[0].denominator))
                        Spacer()
                        Button("Use BPM") { screen.useBeatThisBPM() }
                            .accessibilityLabel("Use Beat This! tempo")
                    }
                }
                if let map = screen.meterSuggestion {
                    HStack {
                        Text(TempoDetectionText.meter(map.segments, denominator: screen.grid.meters[0].denominator))
                        Spacer()
                        Button("Use map") { screen.useMeterMap() }
                            .accessibilityLabel("Use suggested meter map")
                    }
                } else {
                    Text("Meter unclear").font(.caption).foregroundStyle(Native.fgSecondary)
                }
            }
            if !(screen.currentBeatResult?.beats.isEmpty ?? true) || !(screen.currentQuickResult?.beats.isEmpty ?? true) {
                Button("Start slice at first beat") { screen.startSliceAtFirstBeat() }
                    .accessibilityLabel("Start slice at first beat")
            }
            if let message = screen.originMessage { Text(message).foregroundStyle(Native.danger).font(.caption) }
            if let notice = screen.writer.notice { Text(notice).foregroundStyle(Native.danger).font(.caption) }
            Divider()
            HStack {
                Text("Alignment").font(.subheadline.bold())
                Spacer()
                Button("Check alignment") { screen.startAnalysis(.alignment) }
                    .disabled(busy || !screen.resultIsCurrent || TempoFromNotes.mergedOnsets(screen.usableNotes.map(\.onset)).count < 8)
                    .help(screen.analysisBlocker ?? (!screen.resultIsCurrent ? "Transcribe this slice first." : "At least eight note onsets are needed."))
                    .accessibilityLabel("Check note and audio alignment")
            }
            if let alignment = screen.currentAlignment {
                Text(TempoDetectionText.alignment(alignment)).font(.caption).foregroundStyle(Native.fgSecondary)
            }
        }
    }
}
