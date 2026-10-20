import Foundation
import Testing
@testable import SillyMIDITools

private func clicks(bpm: Double, seconds: Double, rate: Double = 16_000) -> [Float] {
    var samples = [Float](repeating: 0, count: Int(seconds * rate))
    var state: UInt32 = 2_463_534_242
    var beat = 0.3
    while beat < seconds - 0.1 {
        var previous: Float = 0
        let start = Int(beat * rate)
        for i in 0..<Int(0.08 * rate) where start + i < samples.count {
            state ^= state << 13
            state ^= state >> 17
            state ^= state << 5
            let noise = Float(state) / Float(UInt32.max) * 2 - 1
            let t = Double(i) / rate
            samples[start + i] += Float(0.35 * exp(-t / 0.03)) * (noise - previous)
            previous = noise
        }
        beat += 60 / bpm
    }
    return samples
}

private let maksumURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().appendingPathComponent("build/percussion/Maksum_Ejemplo.wav")

struct TempoFromAudioTests {
    @Test func clickTrainAt95HasASecondRelativeAndAlignedBeats() throws {
        let result = try TempoFromAudio.detect(samples: clicks(bpm: 95, seconds: 20), sampleRate: 16_000)
        let first = try #require(result.candidates.first)
        #expect(abs(first.bpm - 95) < 1, "first candidate: \(first.bpm)")
        #expect(first.score >= 0.15 && first.score <= 1)
        #expect(result.candidates.dropFirst().contains { candidate in
            candidate.relative != nil && (abs(candidate.bpm - 190) < 2 || abs(candidate.bpm - 47.5) < 1)
        }, "candidates: \(result.candidates)")
        for k in 0...27 {
            let expected = 0.3 + Double(k) * 60 / 95
            #expect(result.beats.contains { abs($0 - expected) < 0.02 }, "beat \(k) near \(expected): \(result.beats)")
        }
    }

    @Test func clickTrainAt128Finds128() throws {
        let result = try TempoFromAudio.detect(samples: clicks(bpm: 128, seconds: 20), sampleRate: 16_000)
        #expect(abs(try #require(result.candidates.first).bpm - 128) < 1)
    }

    @Test func fixedSeedWhiteNoiseHasNoPulse() throws {
        var state: UInt32 = 123_456_789
        let samples = (0..<320_000).map { _ -> Float in
            state ^= state << 13
            state ^= state >> 17
            state ^= state << 5
            return Float(state) / Float(UInt32.max) * 2 - 1
        }
        let result = try TempoFromAudio.detect(samples: samples, sampleRate: 16_000)
        #expect(result.candidates.isEmpty)
        #expect(result.beats.isEmpty)
    }

    @Test func tenMinutesFinishesWithinFiveSeconds() throws {
        let samples = clicks(bpm: 95, seconds: 600)
        let start = Date()
        let result = try TempoFromAudio.detect(samples: samples, sampleRate: 16_000)
        let seconds = Date().timeIntervalSince(start)
        #expect(abs(try #require(result.candidates.first).bpm - 95) < 1)
        #expect(seconds < 5, "10-minute detector took \(seconds) s")
    }

    @Test func tenSecondsOfSilenceHasNoCandidatesOrBeats() throws {
        let result = try TempoFromAudio.detect(samples: [Float](repeating: 0, count: 160_000), sampleRate: 16_000)
        #expect(result.candidates.isEmpty)
        #expect(result.beats.isEmpty)
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: maksumURL.path))) func maksumClipKeepsTimeWithTheDoums() throws {
        let audio = try AudioDocument.load(url: maksumURL)
        let result = try TempoFromAudio.detect(samples: audio.samples, sampleRate: audio.sampleRate)
        let samples = try Resampler.resample(audio.samples, from: audio.sampleRate, to: HandPercussionEngine.sampleRate)
        let doums = try HandPercussionEngine().hits(samples: samples)
            .filter { $0.pitch == HandPercussionEngine.lowPitch }.map(\.time)
        let distances = doums.map { doum in result.beats.map { abs($0 - doum) }.min() ?? .infinity }
        #expect((try #require(result.candidates.first)).bpm > 80)
        #expect(result.beats.count >= 12)
        #expect(doums.count >= 6 && distances.allSatisfy { $0 < 0.03 })
    }
}
