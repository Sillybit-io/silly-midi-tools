import Foundation
@preconcurrency import OnnxRuntimeBindings

enum BeatThisError: LocalizedError {
    case modelUnavailable(String)
    case unexpectedOutput
    case invalidSampleRate

    var errorDescription: String? {
        switch self {
        case .modelUnavailable(let reason): "The Beat This! model could not be loaded: \(reason)"
        case .unexpectedOutput: "The Beat This! model returned output of an unexpected shape."
        case .invalidSampleRate: "The audio sample rate must be positive."
        }
    }
}

struct BeatThisResult: Sendable {
    let beats: [Double]
    let downbeats: [Double]
    let beatLogits: [Float]
    let downbeatLogits: [Float]

    var meterMap: BeatThisMeterMap? { BeatThisMeterMap.derive(beats: beats, downbeats: downbeats) }
}

/// One ORT call per window. The input context already contains the reflected STFT halo;
/// pad_frames adds zero *mel* frames, never zero waveform samples.
final class BeatThisSession: @unchecked Sendable {
    private let env: ORTEnv
    private let session: ORTSession

    init(modelURL: URL, threads: Int = 0) throws {
        do {
            let env = try ORTEnv(loggingLevel: .warning)
            func make(_ level: ORTGraphOptimizationLevel) throws -> ORTSession {
                let options = try ORTSessionOptions()
                try options.setGraphOptimizationLevel(level)
                if threads > 0 { try options.setIntraOpNumThreads(Int32(threads)) }
                return try ORTSession(env: env, modelPath: modelURL.path, sessionOptions: options)
            }
            let session: ORTSession
            do { session = try make(.all) } catch { session = try make(.none) }
            self.env = env
            self.session = session
        } catch {
            throw BeatThisError.modelUnavailable(error.localizedDescription)
        }
    }

    func run(context: [Float], leftZeros: Int, rightZeros: Int) throws -> (beat: [Float], downbeat: [Float]) {
        guard context.count >= 1024, (context.count - 1024) % BeatThisEngine.hop == 0,
              leftZeros >= 0, rightZeros >= 0 else { throw BeatThisError.unexpectedOutput }
        let waveform = NSMutableData(bytes: context, length: context.count * MemoryLayout<Float>.size)
        let padding = [Int64(leftZeros), Int64(rightZeros)]
        let padData = padding.withUnsafeBytes { NSMutableData(bytes: $0.baseAddress!, length: $0.count) }
        let input = try ORTValue(tensorData: waveform, elementType: .float, shape: [1, NSNumber(value: context.count)])
        let pad = try ORTValue(tensorData: padData, elementType: .int64, shape: [2])
        let outputs = try session.run(withInputs: ["waveform": input, "pad_frames": pad],
                                      outputNames: Set(["beat", "downbeat"]), runOptions: nil)
        let expected = leftZeros + (context.count - 1024) / BeatThisEngine.hop + 1 + rightZeros
        func read(_ name: String) throws -> [Float] {
            guard let value = outputs[name] else { throw BeatThisError.unexpectedOutput }
            let data = try value.tensorData()
            let values = Data(data).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            guard values.count == expected else { throw BeatThisError.unexpectedOutput }
            return values
        }
        return try (read("beat"), read("downbeat"))
    }
}

struct BeatThisEngine: Sendable {
    static let sampleRate = 22_050.0
    static let hop = 441
    static let frameRate = 50.0
    static let border = 6
    static let chunkSize = 1500
    static let stride = chunkSize - 2 * border

    var modelURL: URL
    var threads = 0

    struct Chunk: Equatable, Sendable {
        let start: Int
        let frames: Range<Int>
        let leftZeros: Int
        let rightZeros: Int

        var outputCount: Int { leftZeros + frames.count + rightZeros }
    }

    static func frameCount(forSamples count: Int) -> Int { count > 0 ? 1 + count / hop : 0 }

    static func chunks(frameCount count: Int) -> [Chunk] {
        guard count > 0 else { return [] }
        var starts = Swift.stride(from: -border, to: count - border, by: stride).map { $0 }
        if count > stride { starts[starts.count - 1] = count - (chunkSize - border) }
        return starts.map { start in
            let frames = max(0, start)..<min(count, start + chunkSize)
            return Chunk(start: start, frames: frames, leftZeros: max(0, -start),
                         rightZeros: max(0, min(border, start + chunkSize - count)))
        }
    }

    /// Reflect at the actual piece boundary (including a one-sample piece), not at a chunk seam.
    /// The interval includes both 512-sample halos and yields 1024 + 441*(frames-1) samples.
    static func context(samples: [Float], frames: Range<Int>) -> [Float] {
        guard !samples.isEmpty, !frames.isEmpty else { return [] }
        func reflected(_ index: Int) -> Int {
            guard samples.count > 1 else { return 0 }
            let period = 2 * (samples.count - 1)
            let wrapped = (index % period + period) % period
            return wrapped < samples.count ? wrapped : period - wrapped
        }
        let first = frames.lowerBound * hop - 512
        let length = (frames.count - 1) * hop + 1024
        return (0..<length).map { samples[reflected(first + $0)] }
    }

    /// Trims both six-frame borders. Earlier chunks win at the shifted last-chunk overlap.
    static func aggregate(_ outputs: [[Float]], chunks: [Chunk], frameCount: Int) -> [Float] {
        var result = [Float](repeating: -1000, count: frameCount)
        var filled = [Bool](repeating: false, count: frameCount)
        for (chunk, output) in zip(chunks, outputs) {
            let end = min(output.count - border, chunk.outputCount - border)
            guard end > border else { continue }
            for index in border..<end {
                let frame = chunk.start + index
                if result.indices.contains(frame), !filled[frame] {
                    result[frame] = output[index]
                    filled[frame] = true
                }
            }
        }
        return result
    }

    static func peakFrames(_ logits: [Float]) -> [Double] {
        var peaks: [Int] = []
        for index in logits.indices where logits[index] > 0 {
            let maximum = logits[max(0, index - 3)...min(logits.count - 1, index + 3)].max()!
            if logits[index] == maximum { peaks.append(index) }
        }
        guard !peaks.isEmpty else { return [] }
        var groups: [[Int]] = [[peaks[0]]]
        for index in peaks.dropFirst() {
            if index == groups[groups.count - 1].last! + 1 { groups[groups.count - 1].append(index) }
            else { groups.append([index]) }
        }
        return groups.map { Double($0.reduce(0, +)) / Double($0.count) }
    }

    static func postprocess(beat: [Float], downbeat: [Float]) -> (beats: [Double], downbeats: [Double]) {
        let beats = peakFrames(beat).map { $0 / frameRate }
        guard !beats.isEmpty else { return ([], []) }
        let snapped = peakFrames(downbeat).map { frame in
            let time = frame / frameRate
            return beats.min { abs($0 - time) < abs($1 - time) }!
        }
        return (beats, Array(Set(snapped)).sorted())
    }

    func track(samples: [Float], sampleRate: Double, progress: (Double) -> Void = { _ in }) throws -> BeatThisResult {
        guard sampleRate.isFinite, sampleRate > 0 else { throw BeatThisError.invalidSampleRate }
        try Task.checkCancellation()
        let audio = try Resampler.resample(samples, from: sampleRate, to: Self.sampleRate)
        let count = Self.frameCount(forSamples: audio.count)
        let plan = Self.chunks(frameCount: count)
        guard !plan.isEmpty else { return BeatThisResult(beats: [], downbeats: [], beatLogits: [], downbeatLogits: []) }
        let session = try BeatThisSession(modelURL: modelURL, threads: threads)
        var beats: [[Float]] = [], downbeats: [[Float]] = []
        for (index, chunk) in plan.enumerated() {
            try Task.checkCancellation()
            try autoreleasepool {
                let output = try session.run(context: Self.context(samples: audio, frames: chunk.frames),
                                             leftZeros: chunk.leftZeros, rightZeros: chunk.rightZeros)
                beats.append(output.beat)
                downbeats.append(output.downbeat)
            }
            progress(Double(index + 1) / Double(plan.count))
        }
        try Task.checkCancellation()
        let beat = Self.aggregate(beats, chunks: plan, frameCount: count)
        let downbeat = Self.aggregate(downbeats, chunks: plan, frameCount: count)
        let positions = Self.postprocess(beat: beat, downbeat: downbeat)
        return BeatThisResult(beats: positions.beats, downbeats: positions.downbeats,
                              beatLogits: beat, downbeatLogits: downbeat)
    }
}

struct BeatThisMeterMap: Sendable {
    struct Segment: Equatable, Sendable {
        let barIndex: Int
        let beatsPerBar: Int
        let startTime: Double
    }

    let pulseBPM: Double
    let firstDownbeatTime: Double
    let segments: [Segment]

    struct Suggestion: Sendable {
        let quarterBPM: Double
        let firstDownbeatTime: Double
        let segments: [Segment]
        let grid: MIDIGrid
    }

    /// The denominator belongs to the user, not the model. Only return a usable grid
    /// when MIDIGrid can represent the measured pulse rate without clamping.
    func suggestion(denominator: Int) -> Suggestion? {
        guard [1, 2, 4, 8, 16, 32].contains(denominator) else { return nil }
        let bpm = pulseBPM * 4 / Double(denominator)
        guard (20...300).contains(bpm), segments.count <= 256 else { return nil }
        let grid = MIDIGrid(bpm: bpm, meters: segments.map {
            MeterChange(bar: $0.barIndex, numerator: $0.beatsPerBar, denominator: denominator)
        })
        // Two-decimal MIDI tempo cannot reproduce arbitrary detected intervals exactly.
        return Suggestion(quarterBPM: grid.bpm, firstDownbeatTime: firstDownbeatTime,
                          segments: segments, grid: grid)
    }

    /// Every boundary is indexed in the complete ordered beat list. A missing downbeat
    /// divides a 2k-beat span into two k bars; a spurious 2+2 boundary rejoins a k bar.
    /// Neither repair removes elapsed pulses or shifts the next real anchor.
    static func derive(beats: [Double], downbeats: [Double]) -> BeatThisMeterMap? {
        guard beats.count >= 3, downbeats.count >= 2,
              beats.allSatisfy(\.isFinite), downbeats.allSatisfy(\.isFinite),
              zip(beats, beats.dropFirst()).allSatisfy({ $0 < $1 }),
              zip(downbeats, downbeats.dropFirst()).allSatisfy({ $0 < $1 }) else { return nil }
        let intervals = zip(beats, beats.dropFirst()).map { $1 - $0 }
        let sorted = intervals.sorted()
        let middle = sorted.count / 2
        let period = sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
        guard period > 0, Double(intervals.filter { abs($0 - period) <= period * 0.1 }.count) / Double(intervals.count) >= 0.6 else { return nil }
        var anchors: [Int] = []
        for time in downbeats {
            guard let index = beats.indices.min(by: { abs(beats[$0] - time) < abs(beats[$1] - time) }),
                  abs(beats[index] - time) < period * 0.25,
                  index > (anchors.last ?? -1) else { return nil }
            anchors.append(index)
        }
        let counts = zip(anchors, anchors.dropFirst()).map { $1 - $0 }
        guard counts.allSatisfy({ (1...32).contains($0) }) else { return nil }
        // Require corroboration for a leading anomaly. If the next interval begins
        // on a real snapped downbeat, that downbeat may instead anchor bar 1.
        let histogram = Dictionary(counts.map { ($0, 1) }, uniquingKeysWith: +)
        guard let stable = histogram.max(by: { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value })?.key else { return nil }
        var first = 0
        if counts.count > 1, counts[0] != stable, counts[1] == stable { first = 1 }
        var bar = 0
        var lengths: [(Int, Int, Double)] = []
        var index = first
        while index < counts.count {
            let count = counts[index]
            let left = index > first ? counts[index - 1] : nil
            let right = index + 1 < counts.count ? counts[index + 1] : nil
            let neighboursAgree = left == stable && right == stable
            if neighboursAgree, count == 2 * stable {
                lengths.append((bar, stable, beats[anchors[index]])); bar += 1
                lengths.append((bar, stable, beats[anchors[index] + stable])); bar += 1
            } else if index + 1 < counts.count, count + counts[index + 1] == stable,
                      count < stable, counts[index + 1] < stable,
                      left == stable, index + 2 < counts.count, counts[index + 2] == stable {
                lengths.append((bar, stable, beats[anchors[index]])); bar += 1
                index += 1
            } else {
                // A one-beat neighbouring change can be real. A larger isolated
                // mismatch without a span-preserving repair is not actionable.
                if neighboursAgree && abs(count - stable) > 1 { return nil }
                lengths.append((bar, count, beats[anchors[index]])); bar += 1
            }
            index += 1
        }
        guard let firstBar = lengths.first else { return nil }
        var segments: [Segment] = []
        for (barIndex, count, time) in lengths where segments.last?.beatsPerBar != count {
            segments.append(Segment(barIndex: barIndex, beatsPerBar: count, startTime: time))
        }
        return BeatThisMeterMap(pulseBPM: 60 / period, firstDownbeatTime: firstBar.2, segments: segments)
    }
}
