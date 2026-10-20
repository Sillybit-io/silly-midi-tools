import Foundation
import Testing
@testable import SillyMIDITools

private let beatThisRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
private let beatThisFixtures = beatThisRoot.appendingPathComponent("Tests/Fixtures/BeatThis")
private let beatThisModel = beatThisRoot.appendingPathComponent("build/models/beat_this.onnx")
private let beatThisIntegrationAvailable = FileManager.default.fileExists(atPath: beatThisModel.path)
    && FileManager.default.fileExists(atPath: beatThisFixtures.appendingPathComponent("beat_this_manifest.json").path)

struct BeatThisTests {
    @Test func frameAndChunkPlan() {
        #expect(BeatThisEngine.frameCount(forSamples: 661_500) == 1501)
        #expect(BeatThisEngine.chunks(frameCount: 0).isEmpty)
        let short = BeatThisEngine.chunks(frameCount: 501)
        #expect(short == [.init(start: -6, frames: 0..<501, leftZeros: 6, rightZeros: 6)])
        #expect(short[0].outputCount == 513)
        let edge = BeatThisEngine.chunks(frameCount: 151)
        #expect(edge == [.init(start: -6, frames: 0..<151, leftZeros: 6, rightZeros: 6)])
        #expect(edge[0].outputCount == 163)
        let full = BeatThisEngine.chunks(frameCount: 1501)
        #expect(full == [.init(start: -6, frames: 0..<1494, leftZeros: 6, rightZeros: 0),
                         .init(start: 7, frames: 7..<1501, leftZeros: 0, rightZeros: 6)])
        #expect(full.map(\.outputCount) == [1500, 1500])
        let seam = BeatThisEngine.chunks(frameCount: 2251)
        #expect(seam == [.init(start: -6, frames: 0..<1494, leftZeros: 6, rightZeros: 0),
                         .init(start: 757, frames: 757..<2251, leftZeros: 0, rightZeros: 6)])
        #expect(seam.map(\.outputCount) == [1500, 1500])
    }

    @Test func reflectOnlyAtRealWaveformBoundaries() {
        let audio = (0..<2000).map(Float.init)
        let beginning = BeatThisEngine.context(samples: audio, frames: 0..<2)
        #expect(beginning.count == 1465)
        #expect(Array(beginning.prefix(4)) == [512, 511, 510, 509])
        #expect(beginning[512] == 0)
        let interior = BeatThisEngine.context(samples: audio, frames: 2..<4)
        #expect(interior.count == 1465)
        #expect(interior[0] == 370)
        #expect(interior[512] == 882)
        let ending = BeatThisEngine.context(samples: audio, frames: 4..<5)
        #expect(ending[512] == 1764)
        #expect(ending.last == 1723) // sample 2275 reflects around sample 1999
        let tiny = BeatThisEngine.context(samples: [10, 20, 30], frames: 0..<1)
        #expect(tiny.count == 1024)
        #expect(tiny[512] == 10)
        #expect(tiny[513] == 20)
        #expect(tiny[515] == 20)
        #expect(Set(BeatThisEngine.context(samples: [42], frames: 0..<1)) == [42])
    }

    @Test func peakPickingAndDownbeatSnapping() {
        var beat = [Float](repeating: -1, count: 30)
        beat[8] = 1; beat[10] = 1
        #expect(BeatThisEngine.peakFrames(beat) == [8, 10])
        beat[10] = -1; beat[9] = 1
        #expect(BeatThisEngine.peakFrames(beat) == [8.5])
        beat[8] = 0; beat[9] = 0
        #expect(BeatThisEngine.peakFrames(beat).isEmpty)
        beat[8] = 1; beat[20] = 1
        var down = [Float](repeating: -1, count: 30)
        down[7] = 2; down[9] = 2; down[22] = 2
        let positions = BeatThisEngine.postprocess(beat: beat, downbeat: down)
        #expect(positions.beats == [0.16, 0.4])
        #expect(positions.downbeats == [0.16, 0.4])
    }

    @Test func aggregationDropsBordersAndKeepsFirstOverlap() {
        let chunks = BeatThisEngine.chunks(frameCount: 2251)
        let first = (0..<1500).map { Float($0 - 6) }
        let second = [Float](repeating: 9999, count: 1500)
        let joined = BeatThisEngine.aggregate([first, second], chunks: chunks, frameCount: 2251)
        #expect(joined.count == 2251)
        #expect(joined[0] == 0 && joined[762] == 762 && joined[1487] == 1487)
        #expect(joined[1488] == 9999 && joined[2250] == 9999)
        #expect(!joined.contains(-1000))
        var sentinelFirst = first
        sentinelFirst[768] = -1000 // a real logit equal to the initialization value still owns the overlap
        let sentinelJoined = BeatThisEngine.aggregate([sentinelFirst, second], chunks: chunks, frameCount: 2251)
        #expect(sentinelJoined[762] == -1000)
    }

    private func map(_ counts: [Int], extraAt: Int? = nil, missedAt: Int? = nil,
                     leadingOffset: Double = 0) -> BeatThisMeterMap? {
        var boundaries = [0]
        for count in counts { boundaries.append(boundaries.last! + count) }
        if let missedAt { boundaries.remove(at: missedAt) }
        if let extraAt { boundaries.append(extraAt); boundaries.sort() }
        let beats = (0...boundaries.last!).map { Double($0) * 0.5 }
        var downbeats = boundaries.map { Double($0) * 0.5 }
        downbeats[0] += leadingOffset
        return BeatThisMeterMap.derive(beats: beats, downbeats: downbeats)
    }

    private var longCounts: [Int] { Array(repeating: 4, count: 40) + Array(repeating: 3, count: 8) + Array(repeating: 4, count: 8) }

    @Test func missedDownbeatPreservesFortiethBarAndExactTransition() throws {
        let result = try #require(map(longCounts, missedAt: 12))
        #expect(result.pulseBPM == 120)
        #expect(result.firstDownbeatTime == 0)
        #expect(result.segments == [.init(barIndex: 0, beatsPerBar: 4, startTime: 0),
                                    .init(barIndex: 40, beatsPerBar: 3, startTime: 80),
                                    .init(barIndex: 48, beatsPerBar: 4, startTime: 92)])
    }

    @Test func extraDownbeatRejoinsTwoPlusTwoWithoutShiftingLaterBars() throws {
        let result = try #require(map(longCounts, extraAt: 50))
        #expect(result.segments == [.init(barIndex: 0, beatsPerBar: 4, startTime: 0),
                                    .init(barIndex: 40, beatsPerBar: 3, startTime: 80),
                                    .init(barIndex: 48, beatsPerBar: 4, startTime: 92)])
    }

    @Test func realThreeBeatSingletonRemainsItsOwnBar() throws {
        let counts = Array(repeating: 4, count: 8) + [3] + Array(repeating: 4, count: 8)
        let result = try #require(map(counts))
        #expect(result.segments == [.init(barIndex: 0, beatsPerBar: 4, startTime: 0),
                                    .init(barIndex: 8, beatsPerBar: 3, startTime: 16),
                                    .init(barIndex: 9, beatsPerBar: 4, startTime: 17.5)])
    }

    @Test func unsupportedLeadingAnchorAndAmbiguousIntervalOfferNoMap() {
        #expect(map([3, 4, 4, 4], leadingOffset: 0.2) == nil)
        #expect(map([4, 4, 7, 4, 4]) == nil)
    }

    @Test func anchoredLeadingSingletonBecomesPickupNotAnInventedBar() throws {
        let result = try #require(map([3, 4, 4, 4]))
        #expect(result.firstDownbeatTime == 1.5)
        #expect(result.segments == [.init(barIndex: 0, beatsPerBar: 4, startTime: 1.5)])
    }

    @Test func denominatorConvertsPulseBPMWithoutInventingPulseUnits() throws {
        let three = try #require(map([3, 3, 3, 3]))
        let threeEighths = try #require(three.suggestion(denominator: 8))
        #expect(threeEighths.quarterBPM == 60)
        #expect(threeEighths.grid.meters[0].denominator == 8)
        #expect(threeEighths.grid.secondsPerBar == 1.5)
        let six = try #require(map([6, 6, 6, 6]))
        let sixEighths = try #require(six.suggestion(denominator: 8))
        #expect(sixEighths.quarterBPM == 60)
        #expect(sixEighths.grid.secondsPerBar == 3.0)
        let sixQuarters = try #require(six.suggestion(denominator: 4))
        #expect(sixQuarters.quarterBPM == 120)
        #expect(sixQuarters.grid.secondsPerBar == 3.0)
        #expect(six.suggestion(denominator: 3) == nil)
    }

    @Test(.enabled(if: beatThisIntegrationAvailable))
    func onnxWindowsAndPeakTimesMatchPythonOracle() throws {
        let document = try AudioDocument.load(url: beatThisFixtures.appendingPathComponent("beat_this_fixture.wav"))
        try #require(document.sampleRate == 22_050)
        let text = try String(contentsOf: beatThisFixtures.appendingPathComponent("reference_beats.csv"), encoding: .utf8)
        let rows = text.split(whereSeparator: \.isNewline).dropFirst().map { $0.split(separator: ",", omittingEmptySubsequences: false).map(String.init) }
        try #require(rows.allSatisfy { $0.count == 4 && Double($0[2]) != nil && Double($0[3]) != nil })
        let prefixSeconds = ["short3": 3, "short10": 10, "full30": 30, "seam45": 45]
        let engine = BeatThisEngine(modelURL: beatThisModel)
        let names = Set(rows.map { $0[0] }).sorted()
        try #require(!names.isEmpty && names.allSatisfy { prefixSeconds[$0] != nil })
        for name in names {
            let fixtureRows = rows.filter { $0[0] == name }
            try #require(!fixtureRows.isEmpty)
            let sampleCount = min(document.samples.count, prefixSeconds[name]! * 22_050)
            let result = try engine.track(samples: Array(document.samples.prefix(sampleCount)), sampleRate: document.sampleRate)
            let data = try Data(contentsOf: beatThisFixtures.appendingPathComponent("reference_logits_\(name).f32"))
            let expected = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            let count = BeatThisEngine.frameCount(forSamples: sampleCount)
            #expect(expected.count == 2 * count)
            #expect(result.beatLogits.count == count && result.downbeatLogits.count == count)
            if expected.count == 2 * count {
                #expect(zip(result.beatLogits, expected.prefix(count)).allSatisfy { abs($0 - $1) < 1e-3 })
                #expect(zip(result.downbeatLogits, expected.suffix(count)).allSatisfy { abs($0 - $1) < 1e-3 })
            }
            for (kind, got) in [("beat", result.beats), ("downbeat", result.downbeats)] {
                let want = fixtureRows.filter { $0[1] == kind }.map { Double($0[2])! }
                #expect(got.count == want.count)
                #expect(zip(got, want).allSatisfy { abs($0 - $1) < 1e-9 })
            }
        }
    }
}
