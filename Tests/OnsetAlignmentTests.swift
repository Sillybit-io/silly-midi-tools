import Foundation
import Testing
@testable import SillyMIDITools

struct OnsetAlignmentTests {
    private let rate = 16_000.0

    private func clickTrain(bpm: Double, seconds: Double) -> (samples: [Float], onsets: [Double]) {
        var samples = [Float](repeating: 0, count: Int(seconds * rate))
        var state: UInt32 = 2_463_534_242
        var beat = 0.3
        var onsets: [Double] = []
        while beat < seconds - 0.1 {
            onsets.append(beat)
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
        return (samples, onsets)
    }

    @Test func clickOnsetsFortyMillisecondsLateAlign() throws {
        let audio = clickTrain(bpm: 95, seconds: 20)
        let result = try #require(try OnsetAlignment.check(onsets: audio.onsets.map { $0 + 0.04 },
                                                            samples: audio.samples, sampleRate: rate))
        #expect(abs(result.lag - 0.04) <= 0.01, "lag: \(result.lag)")
        #expect(result.matchedShare >= 0.9)
        #expect(result.noteCount == audio.onsets.count)
    }

    @Test func threeHundredMillisecondsLateHasNoMatch() throws {
        let audio = clickTrain(bpm: 95, seconds: 20)
        let result = try OnsetAlignment.check(onsets: audio.onsets.map { $0 + 0.3 },
                                               samples: audio.samples, sampleRate: rate)
        #expect(result == nil, "alignment: \(String(describing: result))")
    }

    @Test func tooFewOnsetsHaveNoAlignmentOrGridFit() throws {
        let audio = clickTrain(bpm: 95, seconds: 20)
        #expect(try OnsetAlignment.check(onsets: Array(audio.onsets.prefix(5)),
                                         samples: audio.samples, sampleRate: rate) == nil)
        let three = Array(audio.onsets.prefix(3))
        let notes = three.map { NoteEvent(onset: $0, offset: $0 + 0.1, pitch: 60, program: 0,
                                           isDrum: false, instrument: "acoustic_piano", velocity: nil, pitchBends: nil) }
        #expect(TempoFromNotes.rank(onsets: three, currentBPM: 95).isEmpty)
        #expect(try OnsetAlignment.check(notes: notes, samples: audio.samples, sampleRate: rate) == nil)
    }
}
