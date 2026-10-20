import AppKit
import Foundation
import Testing
@testable import SillyMIDITools

struct LicenseTests {
    @Test func everyCatalogEntryHasLicenseText() throws {
        let bundle = Bundle(for: ModelStoreProbe.self)
        for entry in ModelCatalog.entries {
            let joined = try entry.licenseTexts.map { t in
                try String(contentsOf: #require(bundle.url(forResource: t.resource, withExtension: t.ext)), encoding: .utf8)
            }.joined()
            #expect(!joined.isEmpty)
            let keyword = switch entry.licenseKind {
            case .nonCommercial: "NonCommercial"
            case .commercialAllowed: "Apache License"
            case .attributionRequired: "Attribution 4.0 International"
            case .permissive: "Permission is hereby granted"
            }
            #expect(joined.contains(keyword), "\(entry.id) text should name its licence")
        }
    }

    @Test func beatThisLicenceAndNoticeAreBundledWithTheirOwnCopyright() throws {
        let bundle = Bundle(for: ModelStoreProbe.self)
        let licence = try String(contentsOf: #require(bundle.url(forResource: "MIT-BeatThis", withExtension: "txt")), encoding: .utf8)
        #expect(licence.contains("Permission is hereby granted"))
        #expect(licence.contains("Institute of Computational Perception, JKU Linz"))
        let notice = try String(contentsOf: #require(bundle.url(forResource: "BeatThisNotice", withExtension: "md")), encoding: .utf8)
        #expect(notice.contains("Foscarin") && notice.contains("b95c8ab0c58c2d9fcfd40508ae8dffbc05ac4f5c"))
        #expect(ThirdPartyComponents.sections(in: ThirdPartyComponents.noticesText())["Beat tracking model (Beat This!)"]?.contains("Foscarin") == true)
    }

    @Test func noticesHeadingsMatchComponents() {
        let text = ThirdPartyComponents.noticesText()
        #expect(!text.isEmpty)
        #expect(ThirdPartyComponents.headings(in: text) == ThirdPartyComponents.names)
    }

    @Test func onnxRuntimeNoticesAreBundled() {
        #expect(ThirdPartyComponents.onnxRuntimeNoticesText().contains("Third Party Notices") || ThirdPartyComponents.onnxRuntimeNoticesText().count > 100_000)
    }
}

struct GroupedLicenceTests {
    @Test func fourGroupsInOrder() {
        #expect(ThirdPartyComponents.groups().map(\.title) == ["Models", "Libraries", "Audio", "This app"])
    }

    @Test func everyNoticeSectionIsGroupedExactlyOnce() {
        let used = ThirdPartyComponents.groups().flatMap { $0.entries.flatMap(\.sections) }
        #expect(used.sorted() == ThirdPartyComponents.names.sorted())
        #expect(Set(used).count == used.count)
    }

    @Test func everyEntryShowsBundledText() {
        for group in ThirdPartyComponents.groups() {
            for entry in group.entries {
                #expect(!entry.text.isEmpty, "\(entry.name) should have notice text")
            }
        }
    }

    @Test func codeFenceLinesAreNotShownAsLicenceText() {
        let bodies = ThirdPartyComponents.sections(in: ThirdPartyComponents.noticesText())
        #expect(bodies.values.allSatisfy { !$0.contains("```") })
        #expect(bodies["ONNX Runtime"]?.contains("MIT License") == true)
    }

    @Test func sectionBodiesKeepNestedHeadingsInsideTheirComponent() {
        let notices = "## ggml\nMIT text\n```\n## Not a heading\n```\n## pffft\nBSD text\n"
        let bodies = ThirdPartyComponents.sections(in: notices)
        #expect(bodies["ggml"]?.contains("## Not a heading") == true)
        #expect(bodies["pffft"] == "BSD text")
        #expect(bodies.count == 2)
    }

    @Test func appLicenceIsTheApacheText() {
        let app = ThirdPartyComponents.groups().last?.entries.first
        #expect(app?.text.contains("Apache License") == true)
    }
}

struct AppIconTests {
    @Test func appIconIsInTheAssetCatalog() {
        let image = NSImage(named: "AppIcon")
        #expect(image != nil)
        #expect((image?.size.width ?? 0) >= 128)
    }

    @Test func bundleDeclaresTheIconAndShipsTheCatalog() {
        let info = Bundle.main.infoDictionary
        #expect(info?["CFBundleIconName"] as? String == "AppIcon")
        #expect(Bundle.main.url(forResource: "Assets", withExtension: "car") != nil)
    }
}
