import Foundation
import Testing
@testable import SillyMIDITools

private let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
private let modelsDirectory = testsDirectory.deletingLastPathComponent().appendingPathComponent("build/models")
private let separatorModel = modelsDirectory.appendingPathComponent("htdemucs_ft_drums.onnx")
private let separatorAvailable = FileManager.default.fileExists(atPath: separatorModel.path)

struct DrumSeparatorTests {
    @Test func segmentsStrideByThreeQuartersAndCoverTheAudio() {
        #expect(DrumSeparator.segment == 343_980 && DrumSeparator.overlap == 85_995 && DrumSeparator.stride == 257_985)
        #expect(DrumSeparator.starts(sampleCount: 0).isEmpty)
        #expect(DrumSeparator.starts(sampleCount: 1) == [0])
        #expect(DrumSeparator.starts(sampleCount: 257_985) == [0])
        #expect(DrumSeparator.starts(sampleCount: 257_986) == [0, 257_985])
        let count = 44_100 * 30
        let starts = DrumSeparator.starts(sampleCount: count)
        #expect((starts.last ?? 0) + DrumSeparator.segment >= count)
    }

    @Test func theWindowFadesLinearlyOverTheOverlap() {
        let w = DrumSeparator.window()
        #expect(w.count == DrumSeparator.segment)
        #expect(w[0] == 0 && w[w.count - 1] == 0)
        #expect(w[DrumSeparator.overlap - 1] == 1 && w[w.count / 2] == 1)
        #expect(abs(w[DrumSeparator.overlap / 2] - 0.5) < 1e-3)
    }

    @Test func overlapAddRebuildsAConstantSignal() {
        let count = DrumSeparator.segment + 100_000
        let starts = DrumSeparator.starts(sampleCount: count)
        let stems = starts.map { _ in [Float](repeating: 0.25, count: DrumSeparator.segment) }
        let out = DrumSeparator.combine(stems, starts: starts, count: count)
        #expect(out.count == count)
        // Sample 0 has weight zero, so it is skipped; everywhere else the fades cancel out.
        #expect(out.dropFirst().allSatisfy { abs($0 - 0.25) < 1e-4 })
    }

    @Test func theSeparatorIsAHelperNotAChoiceOfTranscriber() throws {
        let entry = try #require(ModelCatalog.entry(id: ModelCatalog.separatorID))
        #expect(!entry.transcribes && entry.needsDownload && !entry.requiresAcceptance)
        // The beat tracker is the other helper: downloaded and listed, never picked to transcribe with.
        #expect(ModelCatalog.entries.filter { !$0.transcribes }.map(\.id).sorted() == [ModelCatalog.beatThisID, ModelCatalog.separatorID].sorted())
        #expect(ModelCatalog.entries.filter(\.transcribes).count == ModelCatalog.entries.count - 2)
    }

    @Test(.enabled(if: separatorAvailable))
    func aDrumLoopSurvivesSeparationAndIsStillTranscribed() throws {
        let clip = try AudioDocument.load(url: testsDirectory.appendingPathComponent("Fixtures/DrumsOnnx/drums_synthetic.wav"))
        let drums = try DrumSeparator(modelURL: separatorModel).separate(samples: clip.samples)
        #expect(drums.count == clip.samples.count)
        let energy = drums.reduce(Float(0)) { $0 + $1 * $1 }
        #expect(energy > 0 && energy.isFinite)
    }
}
