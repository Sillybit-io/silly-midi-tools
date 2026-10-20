import Foundation

enum TempoFromNotes {
    static func mergedOnsets(_ onsets: [Double]) -> [Double] {
        let sorted = onsets.filter { $0.isFinite && $0 >= 0 }.sorted()
        var merged: [Double] = []
        var previous: Double?
        for onset in sorted {
            if let previous {
                if onset - previous >= 0.03 { merged.append(onset) }
            } else {
                merged.append(onset)
            }
            previous = onset
        }
        return merged
    }

    static func rank(notes: [NoteEvent], currentBPM: Double) -> [TempoCandidate] {
        rank(onsets: notes.map(\.onset), currentBPM: currentBPM)
    }

    static func rank(onsets: [Double], currentBPM: Double) -> [TempoCandidate] {
        let onsets = mergedOnsets(onsets)
        guard onsets.count >= 8 else { return [] }

        func score(_ bpm: Double) -> Double {
            let radiansPerSecond = 2 * Double.pi * bpm / 15
            var x = 0.0, y = 0.0
            for onset in onsets {
                let phase = (onset * radiansPerSecond).truncatingRemainder(dividingBy: 2 * .pi)
                x += cos(phase)
                y += sin(phase)
            }
            return hypot(x, y) / Double(onsets.count)
        }

        let coarse = (0...400).map { score(40 + Double($0) * 0.5) }
        var peaks: [TempoCandidate] = []
        for index in coarse.indices where (index == 0 || coarse[index] >= coarse[index - 1]) &&
            (index == coarse.count - 1 || coarse[index] >= coarse[index + 1]) {
            let center = 40 + Double(index) * 0.5
            let lower = max(40, center - 0.5)
            let upper = min(240, center + 0.5)
            var best = TempoCandidate(bpm: center, score: coarse[index], relative: nil)
            for tenth in Int((lower * 10).rounded())...Int((upper * 10).rounded()) {
                let bpm = Double(tenth) / 10
                let value = score(bpm)
                if value > best.score { best = TempoCandidate(bpm: bpm, score: value, relative: nil) }
            }
            peaks.append(best)
        }
        peaks.sort { $0.score > $1.score }
        guard let strongest = peaks.first, strongest.score >= 0.3 else { return [] }

        var distinct: [TempoCandidate] = []
        for peak in peaks {
            if distinct.contains(where: { abs($0.bpm - peak.bpm) / $0.bpm < 0.02 }) { continue }
            distinct.append(peak)
        }
        let reference = currentBPM.isFinite && currentBPM > 0 ? currentBPM : strongest.bpm
        let near = distinct.filter { strongest.score - $0.score <= 0.05 }
            .sorted { a, b in
                let da = abs(a.bpm - reference), db = abs(b.bpm - reference)
                return da == db ? a.score > b.score : da < db
            }
        let remaining = distinct.filter { strongest.score - $0.score > 0.05 }
        var candidates = Array((near + remaining).prefix(3))
        guard let winner = candidates.first else { return [] }
        for index in candidates.indices.dropFirst() {
            let ratio = candidates[index].bpm / winner.bpm
            if abs(ratio - 2) < 0.04 { candidates[index].relative = .double }
            if abs(ratio - 0.5) < 0.01 { candidates[index].relative = .half }
        }
        return candidates
    }
}
