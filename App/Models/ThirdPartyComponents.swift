import Foundation

enum ThirdPartyComponents {
    /// Must equal the level-two headings of THIRD_PARTY_NOTICES.md, in order.
    static let names = [
        "MuScriptor weights", "GGUF conversion", "muscriptor.cpp", "ggml", "pffft", "Basic Pitch",
        "swift-midi-file", "ONNX Runtime", "Piano transcription model", "Piano transcription post-processing", "Drum transcription model (ADTOF)",
        "Drum transcription model (Onsets and Frames)", "Drum separator model (HT-Demucs)", "Beat tracking model (Beat This!)", "Jon Worthy and the Bends excerpt", "Apple General MIDI soundbank",
    ]

    static func noticesText(bundle: Bundle = Bundle(for: ModelStoreProbe.self)) -> String {
        bundle.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "md")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
    }

    static func onnxRuntimeNoticesText(bundle: Bundle = Bundle(for: ModelStoreProbe.self)) -> String {
        bundle.url(forResource: "ONNXRuntimeThirdPartyNotices", withExtension: "txt")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
    }

    static func headings(in text: String) -> [String] {
        var inFence = false
        var found: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("```") {
                inFence.toggle()
                continue
            }
            if !inFence, line.hasPrefix("## ") { found.append(String(line.dropFirst(3))) }
        }
        return found
    }
}

struct LicenceEntry: Identifiable, Hashable {
    let id: String
    let name: String
    let credit: String
    let licence: String
    /// The `## ` sections of THIRD_PARTY_NOTICES.md this entry shows.
    let sections: [String]
    let text: String
}

struct LicenceGroup: Identifiable, Hashable {
    let title: String
    let entries: [LicenceEntry]

    var id: String { title }
}

extension ThirdPartyComponents {
    private struct Spec {
        let id: String
        let name: String
        let credit: String
        let licence: String
        let sections: [String]
    }

    private static let specs: [(group: String, entries: [Spec])] = [
        ("Models", [
            Spec(id: "muscriptor", name: "MuScriptor", credit: "Mirelo and Kyutai · GGUF conversion by Damien Ronssin",
                 licence: "CC BY-NC 4.0", sections: ["MuScriptor weights", "GGUF conversion"]),
            Spec(id: "piano", name: "Piano transcription model", credit: "Qiuqiang Kong et al. · ONNX conversion by LanOss",
                 licence: "CC BY 4.0", sections: ["Piano transcription model", "Piano transcription post-processing"]),
            Spec(id: "adtof", name: "Drums (ADTOF)", credit: "M. Zehren, M. Alunno and P. Bientinesi · ONNX conversion for this app",
                 licence: "CC BY-NC-SA 4.0", sections: ["Drum transcription model (ADTOF)"]),
            Spec(id: "oaf", name: "Drums (Onsets and Frames)", credit: "Lee Callender, Curtis Hawthorne and Jesse Engel (Magenta) · ONNX conversion for this app",
                 licence: "Apache-2.0", sections: ["Drum transcription model (Onsets and Frames)"]),
            Spec(id: "htdemucs", name: "Drum separator (HT-Demucs)", credit: "Rouard, Massa and Defossez (Meta) · ONNX export by StemSplit.io",
                 licence: "MIT", sections: ["Drum separator model (HT-Demucs)"]),
            Spec(id: "beatthis", name: "Beat tracker (Beat This!)", credit: "Francesco Foscarin, Jan Schl\u{00FC}ter and Gerhard Widmer (JKU Linz) \u{00B7} ONNX conversion for this app",
                 licence: "MIT", sections: ["Beat tracking model (Beat This!)"]),
            Spec(id: "basicpitch", name: "Basic Pitch", credit: "Spotify", licence: "Apache-2.0", sections: ["Basic Pitch"]),
        ]),
        ("Libraries", [
            Spec(id: "ggml", name: "ggml", credit: "The ggml authors", licence: "MIT", sections: ["ggml"]),
            Spec(id: "muscriptorcpp", name: "muscriptor.cpp", credit: "Damien Ronssin", licence: "MIT", sections: ["muscriptor.cpp"]),
            Spec(id: "swiftmidifile", name: "swift-midi-file", credit: "Steffan Andrews", licence: "MIT", sections: ["swift-midi-file"]),
            Spec(id: "onnx", name: "ONNX Runtime", credit: "Microsoft Corporation", licence: "MIT", sections: ["ONNX Runtime"]),
            Spec(id: "pffft", name: "pffft", credit: "Julien Pommier", licence: "BSD-style", sections: ["pffft"]),
        ]),
        ("Audio", [
            Spec(id: "dls", name: "General MIDI sound bank", credit: "Apple", licence: "Apple licence terms",
                 sections: ["Apple General MIDI soundbank"]),
            Spec(id: "testaudio", name: "Test audio excerpt", credit: "Jon Worthy and the Bends", licence: "CC BY 4.0",
                 sections: ["Jon Worthy and the Bends excerpt"]),
        ]),
    ]

    /// The body of each component section, keyed by its `## ` title. Lines inside code fences never start a section,
    /// and the fence lines themselves are Markdown, not licence text, so they are left out.
    static func sections(in text: String) -> [String: String] {
        var bodies: [String: [Substring]] = [:]
        var current: String?
        var inFence = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("```") {
                inFence.toggle()
                continue
            }
            if !inFence, line.hasPrefix("## "), names.contains(String(line.dropFirst(3))) {
                current = String(line.dropFirst(3))
                bodies[current!] = []
                continue
            }
            if let current { bodies[current, default: []].append(line) }
        }
        return bodies.mapValues { $0.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    /// Models, Libraries, Audio and This app, built from the bundled notices and the Apache-2.0 text.
    static func groups(notices: String = noticesText(), appLicence: String = appLicenceText()) -> [LicenceGroup] {
        let bodies = sections(in: notices)
        var result = specs.map { group in
            LicenceGroup(title: group.group, entries: group.entries.map { spec in
                LicenceEntry(id: spec.id, name: spec.name, credit: spec.credit, licence: spec.licence, sections: spec.sections,
                             text: spec.sections.compactMap { bodies[$0] }.joined(separator: "\n\n"))
            })
        }
        result.append(LicenceGroup(title: "This app", entries: [
            LicenceEntry(id: "app", name: "Silly MIDI Tools", credit: "Sillybit", licence: "Apache-2.0", sections: [], text: appLicence),
        ]))
        return result
    }

    static func appLicenceText(bundle: Bundle = Bundle(for: ModelStoreProbe.self)) -> String {
        bundle.url(forResource: "Apache-2.0", withExtension: "txt")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
    }
}
