import Accelerate
import Foundation

enum TempoRelative: String, Sendable {
    case double, half, triple, third
}

struct TempoCandidate: Equatable, Sendable {
    var bpm: Double
    /// Raw autocorrelation at the candidate's period, normalized by zero lag.
    var score: Double
    var relative: TempoRelative?
}

struct AudioTempoResult: Sendable {
    var candidates: [TempoCandidate]
    var beats: [Double]
}

/// A quick, single-tempo pulse estimate from spectral flux. Beats are relative to the input audio's start.
enum TempoFromAudio {
    static let sampleRate = 16_000.0
    static let frameSize = 1024
    static let hop = 160

    static func detect(samples: [Float], sampleRate inputRate: Double) throws -> AudioTempoResult {
        let empty = AudioTempoResult(candidates: [], beats: [])
        guard inputRate > 0, samples.count >= Int(inputRate * 2) else { return empty }
        try Task.checkCancellation()
        let audio = try Resampler.resample(samples, from: inputRate, to: sampleRate)
        let flux = try OnsetEnvelope.flux(audio, sampleRate: sampleRate, frameSize: frameSize, hop: hop, optimized: true)
        let envelope = OnsetEnvelope.highPassed(flux, sampleRate: sampleRate, hop: hop)
        guard let peak = envelope.max(), peak > 0 else { return empty }
        let minimumLag = Int((60 * sampleRate / (240 * Double(hop))).rounded(.up))
        let maximumLag = min(envelope.count - 1, Int((60 * sampleRate / (40 * Double(hop))).rounded(.down)))
        guard maximumLag >= minimumLag else { return empty }
        var energy: Float = 0
        vDSP_svesq(envelope, 1, &energy, vDSP_Length(envelope.count))
        let zero = Double(energy)
        guard zero > 0 else { return empty }

        var correlations = [Double](repeating: 0, count: maximumLag + 1)
        var weighted = correlations
        for lag in minimumLag...maximumLag {
            if lag % 16 == 0 { try Task.checkCancellation() }
            var sum: Float = 0
            envelope.withUnsafeBufferPointer { values in
                vDSP_dotpr(values.baseAddress! + lag, 1, values.baseAddress!, 1, &sum, vDSP_Length(envelope.count - lag))
            }
            correlations[lag] = max(0, min(1, Double(sum) / zero))
            let seconds = Double(lag * hop) / sampleRate
            let octaves = log2(seconds / 0.5) / 0.9
            weighted[lag] = correlations[lag] * exp(-0.5 * octaves * octaves)
        }
        guard let primary = (minimumLag...maximumLag).max(by: { weighted[$0] < weighted[$1] }), correlations[primary] >= 0.15 else { return empty }
        let bpm = 60 * sampleRate / Double(primary * hop)
        var candidates = [TempoCandidate(bpm: bpm, score: correlations[primary], relative: nil)]

        var secondary: (lag: Int, relative: TempoRelative)?
        let relatives: [(Double, TempoRelative)] = [(0.5, .double), (2, .half), (1.0 / 3, .triple), (3, .third)]
        for (ratio, relative) in relatives {
            let target = Double(primary) * ratio
            let lower = max(minimumLag, Int((target * 0.96).rounded(.down)))
            let upper = min(maximumLag, Int((target * 1.04).rounded(.up)))
            guard lower <= upper, let lag = (lower...upper).max(by: { weighted[$0] < weighted[$1] }) else { continue }
            if secondary == nil || weighted[lag] > weighted[secondary!.lag] { secondary = (lag, relative) }
        }
        if let secondary, correlations[secondary.lag] >= 0.15 {
            candidates.append(TempoCandidate(bpm: 60 * sampleRate / Double(secondary.lag * hop), score: correlations[secondary.lag], relative: secondary.relative))
        }
        return AudioTempoResult(candidates: candidates, beats: try beats(envelope, period: primary))
    }

    /// Ellis-style dynamic programme: onset strength plus the best predecessor at half to twice the period.
    private static func beats(_ envelope: [Float], period: Int) throws -> [Double] {
        guard let peak = envelope.max(), peak > 0 else { return [] }
        let strength = envelope.map { max(0, $0 / peak) }
        let onsets = (1..<(strength.count - 1)).filter { i in
            strength[i] >= 0.05 && strength[i] > strength[i - 1] && strength[i] >= strength[i + 1]
        }
        guard !onsets.isEmpty else { return [] }
        var cumulative = [Float](repeating: 0, count: strength.count)
        var predecessor = [Int](repeating: -1, count: strength.count)
        let minStep = max(1, period / 2), maxStep = period * 2
        let penalty = (0...maxStep).map { step in
            step > 0 ? Float(4 * pow(log2(Double(step) / Double(period)), 2)) : 0
        }
        var end = 0
        var firstPredecessor = 0
        var pastPredecessor = 0
        for i in strength.indices {
            if i % 512 == 0 { try Task.checkCancellation() }
            var best = i >= period ? cumulative[i - period] : 0
            var previous = i >= period ? i - period : -1
            while firstPredecessor < onsets.count && i - onsets[firstPredecessor] > maxStep { firstPredecessor += 1 }
            while pastPredecessor < onsets.count && i - onsets[pastPredecessor] >= minStep { pastPredecessor += 1 }
            for j in firstPredecessor..<pastPredecessor {
                let frame = onsets[j]
                let candidate = cumulative[frame] - penalty[i - frame]
                if candidate > best { best = candidate; previous = frame }
            }
            cumulative[i] = strength[i] + best
            predecessor[i] = previous
            if cumulative[i] > cumulative[end] { end = i }
        }
        var frames: [Int] = []
        while end >= 0 { frames.append(end); end = predecessor[end] }
        frames.reverse()
        while let first = frames.first, strength[first] < 0.2 { frames.removeFirst() }
        while let last = frames.last, strength[last] < 0.2 { frames.removeLast() }
        return frames.map { Double($0 * hop) / sampleRate }
    }
}
