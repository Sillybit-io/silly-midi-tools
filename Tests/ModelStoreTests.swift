import CryptoKit
import Foundation
import Testing
@testable import SillyMIDITools

struct ModelStoreTests {
    @Test func catalogSumsMatchPinnedRevision() {
        let sums = Dictionary(uniqueKeysWithValues: ModelCatalog.entries.compactMap { e in e.sha256.map { (e.id, $0) } })
        #expect(sums["muscriptor-small"] == "925f55af65a20ebc4f8b45ceaf095a12b72493d436cb112623cd0041a1af23d4")
        #expect(sums["muscriptor-medium"] == "3850cc9e5b436b17a09bd25b8f2615cb3366ab96a71e7b50f73a793a917fdf03")
        #expect(sums["muscriptor-large"] == "35a750fb1ab1e77195cdc2c0b9b4aeea2f4d59f11f729f02af9920c4854ef72e")
        #expect(sums["piano-onnx"] == "6ec4f07640837df2fcd2cede9c540865acff341def93fbd6432548dee169195a")
        #expect(sums["drums-adtof"]?.count == 64 && sums["drums-oaf"]?.count == 64)
        #expect(sums["beat-this"] == "ab31b5a815e2d90c6cb523e33f0ce45590fdcf80c4181a8115394d94633be14a")
        let urls = ModelCatalog.entries.compactMap(\.downloadURL)
        #expect(urls.count == 8)
        #expect(urls.allSatisfy { !$0.absoluteString.contains("/main/") })
        let muscriptor = ModelCatalog.entries.filter { $0.engine == .muscriptor }.compactMap(\.downloadURL)
        #expect(muscriptor.count == 3 && muscriptor.allSatisfy { $0.absoluteString.contains("d7045f94e8b19427f4ff9542975035e66596e51c") })
        for id in ["drums-adtof", "drums-oaf", "beat-this"] {
            let revision = ModelCatalog.entry(id: id)?.revision ?? ""
            #expect(revision.count == 40 && revision.allSatisfy(\.isHexDigit), "\(id) must be pinned to a commit")
        }
        #expect(ModelCatalog.entries.first { $0.id == "piano-onnx" }?.downloadURL?.absoluteString
            == "https://huggingface.co/LanOss/mobimml-piano-transcription/resolve/7dff58faf160d4c0bf13be48e30e614faecdba72/piano_transcription.onnx")
    }

    @Test func beatThisIsPinnedToThePublishedCommit() throws {
        let entry = try #require(ModelCatalog.entry(id: ModelCatalog.beatThisID))
        #expect(entry.revision == "92842057ebb781a31fcf0d638f04a098fb887313")
        #expect(entry.byteSize == 81_837_133)
        #expect(entry.downloadURL?.absoluteString
            == "https://huggingface.co/thebluescreen/beat-this-onnx/resolve/92842057ebb781a31fcf0d638f04a098fb887313/beat_this.onnx")
        #expect(!entry.transcribes && entry.exportNotice.isEmpty && entry.access == .open)
        #expect(ModelCatalog.entries.filter { !$0.transcribes }.contains { $0.id == entry.id }, "listed under Helpers")
        #expect(entry.sizeText == "82 MB", "the size comes from the pinned byte count, not a typed-in figure")
    }

    /// Downloads the published file through the app's own store and checks it, as a user's first run would.
    /// It moves 82 MB, so it runs only with SILLY_MIDI_NETWORK_TESTS=1 (pass TEST_RUNNER_SILLY_MIDI_NETWORK_TESTS=1 to xcodebuild).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SILLY_MIDI_NETWORK_TESTS"] == "1"))
    @MainActor func beatThisDownloadsAndVerifiesFromItsPinnedURL() async throws {
        let entry = try #require(ModelCatalog.entry(id: ModelCatalog.beatThisID))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("beat-this-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ModelStore(directory: directory)
        #expect(store.state(for: entry) == .notInstalled)
        await store.install(entry)
        #expect(store.state(for: entry) == .installed, "\(store.state(for: entry))")
        let url = try #require(store.installedURL(for: entry))
        let data = try Data(contentsOf: url)
        #expect(Int64(data.count) == entry.byteSize)
        #expect(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() == entry.sha256)
    }

    @Test func verifyAcceptsGoodAndRejectsCorruptFile() async throws {
        let good = Data((0..<4096).map { UInt8($0 % 251) })
        let sum = SHA256.hash(data: good).map { String(format: "%02x", $0) }.joined()
        let dir = FileManager.default.temporaryDirectory
        let okURL = dir.appendingPathComponent("ok-\(UUID().uuidString).bin")
        try good.write(to: okURL)
        try await ModelStore.verify(fileAt: okURL, sha256: sum, byteSize: Int64(good.count))
        #expect(FileManager.default.fileExists(atPath: okURL.path))
        try? FileManager.default.removeItem(at: okURL)

        var bad = good
        bad[10] ^= 0xFF
        let badURL = dir.appendingPathComponent("bad-\(UUID().uuidString).bin")
        try bad.write(to: badURL)
        await #expect(throws: ModelStoreError.self) {
            try await ModelStore.verify(fileAt: badURL, sha256: sum, byteSize: Int64(good.count))
        }
        #expect(!FileManager.default.fileExists(atPath: badURL.path))
    }

    @Test func licenseResourcesResolve() throws {
        let bundle = Bundle(for: ModelStoreProbe.self)
        for entry in ModelCatalog.entries {
            #expect(!entry.licenseTexts.isEmpty)
            for text in entry.licenseTexts {
                let url = try #require(bundle.url(forResource: text.resource, withExtension: text.ext), "\(text.resource) missing")
                #expect(try String(contentsOf: url, encoding: .utf8).count > 100)
            }
        }
    }

    @Test func aModelThatWouldCrowdTheMacOutIsFlagged() throws {
        let large = try #require(ModelCatalog.entry(id: "muscriptor-large"))
        let medium = try #require(ModelCatalog.entry(id: "muscriptor-medium"))
        let basicPitch = try #require(ModelCatalog.entry(id: "basic-pitch"))
        let gib: UInt64 = 1 << 30
        #expect(large.memoryEstimate == 2_739_142_176 + 1_500_000_000)
        #expect(large.memoryWarning(physicalMemory: 8 * gib)
            == "MuScriptor Large needs about 4.2 GB of memory while it runs, and this Mac has 8 GB. Quit other apps first, or pick a smaller model.")
        #expect(large.memoryWarning(physicalMemory: 16 * gib) == nil)
        #expect(medium.memoryWarning(physicalMemory: 8 * gib) == nil)
        #expect(basicPitch.memoryWarning(physicalMemory: 1 * gib) == nil)
    }
}
