import Foundation

struct OnsetAlignmentResult: Equatable, Sendable {
    var lag: Double
    var matchedShare: Double
    var noteCount: Int
}

enum OnsetAlignment {
    static func check(notes: [NoteEvent], samples: [Float], sampleRate: Double) throws -> OnsetAlignmentResult? {
        try check(onsets: notes.map(\.onset), samples: samples, sampleRate: sampleRate)
    }

    static func check(onsets: [Double], samples: [Float], sampleRate: Double) throws -> OnsetAlignmentResult? {
        let onsets = TempoFromNotes.mergedOnsets(onsets)
        guard onsets.count >= 8, sampleRate > 0 else { return nil }
        let audio = try Resampler.resample(samples, from: sampleRate, to: TempoFromAudio.sampleRate)
        let flux = try OnsetEnvelope.flux(audio, sampleRate: TempoFromAudio.sampleRate,
                                           frameSize: TempoFromAudio.frameSize, hop: TempoFromAudio.hop, optimized: true)
        let envelope = OnsetEnvelope.highPassed(flux, sampleRate: TempoFromAudio.sampleRate, hop: TempoFromAudio.hop)
        let frameSeconds = Double(TempoFromAudio.hop) / TempoFromAudio.sampleRate
        let frames = onsets.map { Int(($0 / frameSeconds).rounded()) }
        var bestLag = 0
        var bestCorrelation = -Double.infinity
        // Centred spectral-flux frames peak one frame before these click transients.
        for lag in -25...25 {
            let correlation = frames.reduce(0.0) { sum, frame in
                let shifted = frame - lag - 1
                return sum + (envelope.indices.contains(shifted) ? Double(envelope[shifted]) : 0)
            }
            if correlation > bestCorrelation {
                bestCorrelation = correlation
                bestLag = lag
            }
        }
        let nearbyStrength = frames.reduce(0.0) { sum, frame in
            let shifted = frame - bestLag - 1
            let lower = max(0, shifted - 5), upper = min(envelope.count - 1, shifted + 5)
            return sum + (lower <= upper ? Double(max(0, envelope[lower...upper].max() ?? 0)) : 0)
        }
        guard nearbyStrength > 0, bestCorrelation / nearbyStrength >= 0.3 else { return nil }

        func median(around frame: Int) -> Float {
            let lower = max(0, frame - 12), upper = min(envelope.count - 1, frame + 12)
            let sorted = envelope[lower...upper].sorted()
            return sorted[sorted.count / 2]
        }

        var matched = 0
        for frame in frames {
            let shifted = frame - bestLag - 1
            let lower = max(1, shifted - 5), upper = min(envelope.count - 2, shifted + 5)
            guard lower <= upper else { continue }
            if (lower...upper).contains(where: { index in
                envelope[index] > median(around: index) &&
                    envelope[index] > envelope[index - 1] && envelope[index] >= envelope[index + 1]
            }) { matched += 1 }
        }
        let share = Double(matched) / Double(onsets.count)
        guard share >= 0.3 else { return nil }
        return OnsetAlignmentResult(lag: Double(bestLag) * frameSeconds, matchedShare: share, noteCount: onsets.count)
    }
}
