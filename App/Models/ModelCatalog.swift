import Foundation

struct LicenseText: Hashable, Sendable {
    let resource: String
    let ext: String
}

enum LicenseKind: Sendable {
    case nonCommercial
    case commercialAllowed
    case attributionRequired
    case permissive

    var badge: String {
        switch self {
        case .nonCommercial: "Non-commercial use only"
        case .commercialAllowed: "Commercial use allowed"
        case .attributionRequired: "Commercial use allowed with credit"
        case .permissive: "Commercial use allowed"
        }
    }
}

/// What a model asks of the user before its first download.
enum AccessRequirement: Sendable {
    /// Downloads straight away.
    case open
    /// The licence sheet with the model's own statements; nothing is checked with Hugging Face.
    case terms
    /// The licence sheet plus a Hugging Face token whose account has accepted the authors' terms.
    case huggingFaceGated
}

struct ModelEntry: Identifiable, Hashable, Sendable {
    enum Engine: Sendable { case muscriptor, basicPitch, pianoOnnx, drumsAdtof, drumsOaf, handPercussion, separator, beatThis }

    let id: String
    let displayName: String
    let engine: Engine
    let mirrorRepo: String?
    let revision: String?
    let remotePath: String?
    let byteSize: Int64
    let sha256: String?
    let authorsRepo: String?
    let access: AccessRequirement
    /// The sentences the user ticks on the licence sheet. Empty for an open model.
    let statements: [String]
    /// Where "Open model page" goes when the authors have no Hugging Face repository.
    let homepage: URL?
    let licenseName: String
    let licenseKind: LicenseKind
    let attribution: String
    let licenseTexts: [LicenseText]
    /// MuScriptor's float32 KV cache, allocated next to the weights (`docs/PERFORMANCE.md` of muscriptor.cpp).
    var kvCacheBytes: Int64 = 0

    var fileName: String { remotePath.map { ($0 as NSString).lastPathComponent } ?? id }
    /// The sentence embedded in exported MIDI files and shown in the export sheet.
    var exportNotice: String {
        switch engine {
        case .muscriptor: "Transcribed with MuScriptor by Mirelo and Kyutai (CC BY-NC 4.0, non-commercial use only)."
        case .basicPitch: "Transcribed with Basic Pitch by Spotify (Apache-2.0)."
        case .pianoOnnx: "Transcribed with the high-resolution piano transcription model by Kong et al. (CC BY 4.0)."
        case .drumsAdtof: "Transcribed with ADTOF by Zehren, Alunno and Bientinesi (CC BY-NC-SA 4.0, non-commercial use only)."
        case .separator, .beatThis: ""
        case .drumsOaf: "Transcribed with Onsets and Frames Drums by Callender, Hawthorne and Engel, Magenta (Apache-2.0)."
        case .handPercussion: "Transcribed with the hand percussion detector built into Silly MIDI Tools (Apache-2.0). Low strokes are General MIDI Low Conga, high strokes Open Hi Conga."
        }
    }
    /// True for the engines that ship inside the app and have nothing to download.
    var isBuiltIn: Bool { engine == .basicPitch || engine == .handPercussion }
    var needsDownload: Bool { !isBuiltIn }
    /// True for the models that report no velocity, so the app can estimate it from the audio's loudness.
    var canEstimateVelocity: Bool { engine == .muscriptor || engine == .drumsAdtof || engine == .handPercussion }
    /// False for helper models, which are downloaded and listed but never picked to transcribe with.
    var transcribes: Bool { engine != .separator && engine != .beatThis }
    var isDrumModel: Bool { engine == .drumsAdtof || engine == .drumsOaf }
    /// True when a licence sheet comes before the download.
    var requiresAcceptance: Bool { access != .open }
    /// Rough working set while a run goes: MuScriptor's weights plus its KV cache; for the other models twice the file.
    var memoryEstimate: Int64 { engine == .muscriptor ? byteSize + kvCacheBytes : byteSize * 2 }

    /// Why this model may not fit, when its working set would take more than 40% of the Mac's memory and so leave too
    /// little for macOS and other apps. Nil when it fits.
    func memoryWarning(physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> String? {
        guard Double(memoryEstimate) > 0.4 * Double(physicalMemory) else { return nil }
        let needs = String(format: "%.1f GB", Double(memoryEstimate) / 1_000_000_000)
        return "\(displayName) needs about \(needs) of memory while it runs, and this Mac has \(physicalMemory / 1_073_741_824) GB. "
            + "Quit other apps first, or pick a smaller model."
    }

    var downloadURL: URL? {
        guard let mirrorRepo, let revision, let remotePath else { return nil }
        return URL(string: "https://huggingface.co/\(mirrorRepo)/resolve/\(revision)/\(remotePath)")
    }

    var modelPageURL: URL? {
        authorsRepo.flatMap { URL(string: "https://huggingface.co/\($0)") } ?? homepage
    }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (a: ModelEntry, b: ModelEntry) -> Bool { a.id == b.id }
}

enum ModelCatalog {
    static let mirrorRepo = "DamRsn/muscriptor-gguf"
    static let revision = "d7045f94e8b19427f4ff9542975035e66596e51c"

    private static func muscriptor(_ size: String, bytes: Int64, kvCache: Int64, sha: String) -> ModelEntry {
        ModelEntry(
            id: "muscriptor-\(size)", displayName: "MuScriptor \(size.capitalized)", engine: .muscriptor,
            mirrorRepo: mirrorRepo, revision: revision, remotePath: "v1/muscriptor-\(size)-f16.gguf",
            byteSize: bytes, sha256: sha, authorsRepo: "MuScriptor/muscriptor-\(size)", access: .huggingFaceGated,
            statements: [
                "I will use this model and its MIDI output for non-commercial purposes only.",
                "I hold the rights to the audio I transcribe.",
                "The model and its output are provided as is; Mirelo and Kyutai are not liable.",
            ], homepage: nil,
            licenseName: "CC BY-NC 4.0", licenseKind: .nonCommercial,
            attribution: "Mirelo and Kyutai; GGUF conversion by Damien Ronssin",
            licenseTexts: [LicenseText(resource: "CC-BY-NC-4.0", ext: "txt"), LicenseText(resource: "MuScriptorNotice", ext: "md")],
            kvCacheBytes: kvCache)
    }

    private static let pianoOnnx = ModelEntry(
        id: "piano-onnx", displayName: "Piano (ONNX)", engine: .pianoOnnx,
        mirrorRepo: "LanOss/mobimml-piano-transcription", revision: "7dff58faf160d4c0bf13be48e30e614faecdba72",
        remotePath: "piano_transcription.onnx", byteSize: 154_214_201,
        sha256: "6ec4f07640837df2fcd2cede9c540865acff341def93fbd6432548dee169195a", authorsRepo: nil, access: .open, statements: [], homepage: nil,
        licenseName: "CC BY 4.0", licenseKind: .attributionRequired,
        attribution: "Piano only. Qiuqiang Kong et al., ONNX conversion by LanOss",
        licenseTexts: [LicenseText(resource: "CC-BY-4.0", ext: "txt"), LicenseText(resource: "PianoOnnxNotice", ext: "md")])

    /// The converted drum models are hosted on the maintainer's Hugging Face account. `scripts/publish-drum-models.sh`
    /// uploads them and rewrites the owner, revision, size and checksum lines marked `drum-models` below.
    private static let drumsOwner = "thebluescreen" // drum-models:owner
    private static let drumsAdtofRevision = "d0e809bb1c1b6fe8a4a00c576852117a0636ab5a" // drum-models:adtof-revision
    private static let drumsOafRevision = "771fd5529062b9f6f0b58f01cc4b9819db046f4a" // drum-models:oaf-revision

    private static let drumsAdtof = ModelEntry(
        id: "drums-adtof", displayName: "Drums (ADTOF)", engine: .drumsAdtof,
        mirrorRepo: "\(drumsOwner)/adtof-drums-onnx", revision: drumsAdtofRevision, remotePath: "adtof_frame_rnn.onnx",
        byteSize: 2_171_762, // drum-models:adtof-size
        sha256: "189ca3c2bc7339a5f0fdc0bb11069d4bcc4fafabd142e945228c368c379b6227", // drum-models:adtof-sha
        authorsRepo: nil, access: .terms,
        statements: [
            "I will use this model and its MIDI output for non-commercial purposes only.",
            "I hold the rights to the audio I transcribe.",
            "The model and its output are provided as is; the ADTOF authors are not liable.",
        ],
        homepage: URL(string: "https://github.com/MZehren/ADTOF"),
        licenseName: "CC BY-NC-SA 4.0", licenseKind: .nonCommercial,
        attribution: "Drums only, five kit pieces. M. Zehren, M. Alunno and P. Bientinesi; ONNX conversion for this app",
        licenseTexts: [LicenseText(resource: "CC-BY-NC-SA-4.0", ext: "txt"), LicenseText(resource: "AdtofNotice", ext: "md")])

    private static let drumsOaf = ModelEntry(
        id: "drums-oaf", displayName: "Drums (OaF, Magenta)", engine: .drumsOaf,
        mirrorRepo: "\(drumsOwner)/oaf-drums-onnx", revision: drumsOafRevision, remotePath: "oaf_drums.onnx",
        byteSize: 5_966_247, // drum-models:oaf-size
        sha256: "23d4b05ce7e9715bdb4396823d68bc886e8a958fa9f6266c0f7132b78098b521", // drum-models:oaf-sha
        authorsRepo: nil, access: .open, statements: [], homepage: nil,
        licenseName: "Apache-2.0", licenseKind: .commercialAllowed,
        attribution: "Drums only, eight kit pieces with velocity, for drum-only audio. Callender, Hawthorne and Engel (Magenta); ONNX conversion for this app",
        licenseTexts: [LicenseText(resource: "Apache-2.0", ext: "txt"), LicenseText(resource: "OafDrumsNotice", ext: "md")])

    /// Signal processing in the app itself, so it has no download, no weights and the app's own licence.
    private static let handPercussion = ModelEntry(
        id: "hand-percussion", displayName: "Hand percussion (doum / tek)", engine: .handPercussion,
        mirrorRepo: nil, revision: nil, remotePath: nil, byteSize: 0, sha256: nil, authorsRepo: nil, access: .open,
        statements: [], homepage: nil, licenseName: "Apache-2.0", licenseKind: .commercialAllowed,
        attribution: "Built in. Signal processing, not a trained model",
        licenseTexts: [LicenseText(resource: "Apache-2.0", ext: "txt"), LicenseText(resource: "HandPercussionNotice", ext: "md")])

    static let separatorID = "drum-separator"

    private static let separator = ModelEntry(
        id: separatorID, displayName: "Drum separator (HT-Demucs)", engine: .separator,
        mirrorRepo: "StemSplitio/htdemucs-ft-drums-onnx", revision: "55f929d333054c69ae0e829b15e8f8826a39d6eb",
        remotePath: "htdemucs_ft_drums.onnx", byteSize: 316_446_953,
        sha256: "f76b68af36066e38885b369299b5032a861038f9b49da5aa6cf1c31cfa69cf27", authorsRepo: nil, access: .open,
        statements: [], homepage: nil, licenseName: "MIT", licenseKind: .permissive,
        attribution: "Optional helper: isolates the drums before a drum model listens. Rouard, Massa and Defossez (Meta); ONNX export by StemSplit.io",
        licenseTexts: [LicenseText(resource: "MIT", ext: "txt"), LicenseText(resource: "HTDemucsNotice", ext: "md")])

    static let beatThisID = "beat-this"

    /// Beat This! is hosted on the maintainer's Hugging Face account. It is listed only once `scripts/publish-beat-this.sh`
    /// has uploaded it and rewritten the lines marked `beat-this-models` below, so no download is offered that does not exist.
    private static let beatThisPublished = true // beat-this-models:published
    private static let beatThisOwner = "thebluescreen" // beat-this-models:owner
    private static let beatThisRevision = "92842057ebb781a31fcf0d638f04a098fb887313" // beat-this-models:revision

    private static let beatThis = ModelEntry(
        id: beatThisID, displayName: "Beat tracker (Beat This!)", engine: .beatThis,
        mirrorRepo: "\(beatThisOwner)/beat-this-onnx", revision: beatThisRevision, remotePath: "beat_this.onnx",
        byteSize: 81_837_133, // beat-this-models:size
        sha256: "ab31b5a815e2d90c6cb523e33f0ce45590fdcf80c4181a8115394d94633be14a", // beat-this-models:sha
        authorsRepo: nil, access: .open, statements: [],
        homepage: URL(string: "https://github.com/CPJKU/beat_this"),
        licenseName: "MIT", licenseKind: .permissive,
        attribution: "Optional helper: finds beats and downbeats for tempo and meter suggestions. Foscarin, Schl\u{00FC}ter and Widmer (JKU Linz); ONNX conversion for this app",
        licenseTexts: [LicenseText(resource: "MIT-BeatThis", ext: "txt"), LicenseText(resource: "BeatThisNotice", ext: "md")])

    static let entries: [ModelEntry] = [
        muscriptor("small", bytes: 209_425_152, kvCache: 218_000_000, sha: "925f55af65a20ebc4f8b45ceaf095a12b72493d436cb112623cd0041a1af23d4"),
        muscriptor("medium", bytes: 618_442_496, kvCache: 499_000_000, sha: "3850cc9e5b436b17a09bd25b8f2615cb3366ab96a71e7b50f73a793a917fdf03"),
        muscriptor("large", bytes: 2_739_142_176, kvCache: 1_500_000_000, sha: "35a750fb1ab1e77195cdc2c0b9b4aeea2f4d59f11f729f02af9920c4854ef72e"),
        ModelEntry(
            id: "basic-pitch", displayName: "Basic Pitch", engine: .basicPitch, mirrorRepo: nil, revision: nil,
            remotePath: nil, byteSize: 0, sha256: nil, authorsRepo: nil, access: .open, statements: [], homepage: nil,
            licenseName: "Apache-2.0", licenseKind: .commercialAllowed, attribution: "Spotify",
            licenseTexts: [LicenseText(resource: "Apache-2.0", ext: "txt"), LicenseText(resource: "BasicPitchNotice", ext: "txt")]),
        pianoOnnx,
        drumsAdtof,
        drumsOaf,
        handPercussion,
        separator,
    ] + (beatThisPublished ? [beatThis] : [])

    static func entry(id: String?) -> ModelEntry? {
        guard let id else { return nil }
        return entries.first { $0.id == id }
    }

    /// The name the interface shows for a model ID. An ID the catalogue doesn't know is never shown as it is.
    static func displayName(id: String) -> String {
        entry(id: id)?.displayName ?? "Unknown model"
    }
}
