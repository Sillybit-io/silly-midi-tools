import Foundation
import Testing
@testable import SillyMIDITools

struct TempoFromNotesTests {
    private func notes(_ onsets: [Double]) -> [NoteEvent] {
        onsets.map { NoteEvent(onset: $0, offset: $0 + 0.1, pitch: 60, program: 0,
                               isDrum: false, instrument: "acoustic_piano", velocity: nil, pitchBends: nil) }
    }

    @Test func jitteredSixteenthsRank93AndMark186AsDouble() throws {
        var state: UInt32 = 2_463_534_242
        let onsets = (0..<64).map { index -> Double in
            state ^= state << 13
            state ^= state >> 17
            state ^= state << 5
            let jitter = (Double(state) / Double(UInt32.max) * 2 - 1) * 0.005
            return 0.3 + Double(index) * 15 / 93 + jitter
        }
        let candidates = TempoFromNotes.rank(notes: notes(onsets), currentBPM: 93)
        #expect(abs(try #require(candidates.first).bpm - 93) <= 0.5, "candidates: \(candidates)")
        #expect(candidates.contains { abs($0.bpm - 186) <= 0.5 && $0.relative == .double }, "candidates: \(candidates)")
    }

    @Test func uniformlyRandomOnsetsHaveNoGridFit() {
        var state: UInt32 = 123_456_789
        let onsets = (0..<200).map { _ -> Double in
            state ^= state << 13
            state ^= state >> 17
            state ^= state << 5
            return 60 * Double(state) / Double(UInt32.max)
        }
        #expect(TempoFromNotes.rank(notes: notes(onsets), currentBPM: 120).isEmpty)
    }

    @Test func tooFewDistinctOnsetsHaveNoCandidates() {
        #expect(TempoFromNotes.rank(notes: notes((0..<6).map(Double.init)), currentBPM: 120).isEmpty)
        let clustered = [0.3, 0.31, 0.32] + (1...6).map(Double.init)
        #expect(TempoFromNotes.mergedOnsets(clustered).count == 7)
        #expect(TempoFromNotes.mergedOnsets([0, 0.025, 0.05]).count == 1)
        #expect(TempoFromNotes.rank(notes: notes(clustered), currentBPM: 120).isEmpty)
        #expect(TempoFromNotes.rank(notes: notes([0.3, 0.31, 0.32]), currentBPM: 120).isEmpty)
    }
}
