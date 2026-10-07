//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers the SDK macros `where` reads as declaring no name at file scope in a file that imports their module, `@Test` and `@Suite` under Testing, `@Observable` under Observation and the modules re-exporting it, `@Model` under SwiftData, while the same spelling without that import, or in another file, still keeps a bare name outside every type a use, and the digest still marks each a possible macro.
@Suite(.temporaryDirectories)
struct ImportedSDKMacroTests {
    /// The verdict's clause for two lines set apart as outside every type.
    private static var setApartTwo: String {
        "; 2 more lines writing \"URL\" bare outside every type, extension and protocol, where the name cannot mean a type nested in another, so not use"
    }

    /// A top-level function writing Foundation's `URL` bare twice, and one writing the nested type's whole path.
    private static var plain: String {
        """
        import Foundation
        enum Net { struct URL { func fetched() {} } }
        func home() -> URL? {
            URL(string: "https://example.com")
        }
        func check(_ x: Net.URL) { x.fetched() }

        """
    }

    /// `Net.URL` asked of an unbuilt repo holding the plain fixture beside `files`.
    private static func answer(beside files: [String: String]) async throws -> String {
        try await WhereNestedTypeOutsideTests.answer("Net.URL", files: files.merging(["Sources/Lib/Lib.swift": plain]) { kept, _ in kept })
    }

    /// Each SDK macro at file scope, in a file importing a module that brings it in, adds only members, conformances or unique peers, so the lines writing `URL` bare at the top level are still counted apart.
    @Test
    func anSDKMacroUnderItsImportLeavesTheLinesCountedApart() async throws {
        let files = [
            "import Testing\n@Test func anchor() {}\n",
            "import Testing\n@Suite struct Checks {}\n",
            "@testable import Lib\nimport Testing\n@Suite(.serialized) struct Checks { @Test func anchor() {} }\n",
            "import Observation\n@Observable final class Store {}\n",
            "import SwiftUI\n@Observable final class Store {}\n",
            "import Foundation\n@Observable final class Store {}\n",
            "import SwiftData\n@Observable final class Store {}\n",
            "import SwiftData\n@Model final class Item {}\n",
            "import Testing\n#if DEBUG\n@Test func anchor() {}\n#endif\n",
        ]
        for file in files {
            let url = try await Self.answer(beside: ["Sources/Lib/Entry.swift": file])

            #expect(url.contains(Self.setApartTwo), "\(file): \(url)")
            #expect(url.contains("\n    :6  | func check(_ x: Net.URL) { x.fetched() }"), "\(file): \(url)")
        }
    }

    /// The same spelling under an import that does not bring that macro in may be anyone's macro, which may declare `URL` beside it, so every line writing the name bare stays a use.
    @Test
    func anSDKMacroUnderAnotherModulesImportKeepsTheLines() async throws {
        let files = [
            "@Observable final class Store {}\n",
            "import Testing\n@Observable final class Store {}\n",
            "import Observation\n@Model final class Item {}\n",
            "import SwiftData\n@Suite struct Checks {}\n",
            "import DepotKit\n@Test func anchor() {}\n",
            "import SwiftUI\n@MainActor @Observable final class Store {}\n",
        ]
        for file in files {
            let url = try await Self.answer(beside: ["Sources/Lib/Entry.swift": file])

            #expect(url.contains("\n    :3  | func home() -> URL? {"), "\(file): \(url)")
            #expect(!url.contains("bare outside every type"), "\(file): \(url)")
        }
    }

    /// An import written in another file brings nothing into this one, so a `@Test` in a file that does not import Testing still keeps the lines.
    @Test
    func anImportInAnotherFileDoesNotCount() async throws {
        let url = try await Self.answer(beside: ["Sources/Lib/Entry.swift": "@Test func anchor() {}\n", "Sources/Lib/Other.swift": "import Testing\n"])

        #expect(url.contains("\n    :3  | func home() -> URL? {"), "\(url)")
        #expect(!url.contains("bare outside every type"), "\(url)")
    }

    /// The digest still marks `@Observable` and `@Model` a possible macro in a file importing their module: the members they add are ones the parser cannot see.
    @Test
    func theDigestStillMarksAnImportedSDKMacro() async throws {
        // Bodies long enough that the digest renders rather than handing back the source.
        let body = (1 ... 20).map { "        let total\($0) = \($0) * 2\n" }.joined()
        let members = (1 ... 6).map { "    func step\($0)() {\n\(body)    }\n" }.joined()
        let root = try TestSources.makeTempRepo()
        try TestSources.write("import Observation\n@Observable final class Store {\n\(members)}\n", to: "Sources/Lib/Store.swift", in: root)
        try TestSources.write("import SwiftData\n@Model final class Item {\n\(members)}\n", to: "Sources/Lib/Item.swift", in: root)
        try TestSources.commitAll(in: root, message: "two SDK macros under their imports")
        let engine = try SiftEngine(directory: root)
        _ = try await engine.ensureFresh()

        let store = try engine.digest(target: "Store", options: DigestOptions())
        let item = try engine.digest(target: "Item", options: DigestOptions())

        #expect(store.contains("⚠ macro-attributed (@Observable): members may be generated"), "\(store)")
        #expect(item.contains("⚠ macro-attributed (@Model): members may be generated"), "\(item)")
    }

    /// The table brings in only the macros of the modules imported.
    @Test
    func theAttributesKnownFollowTheImports() {
        let testing = AttributeScanner.nonIntroducingAttributes(importing: ["Testing"])
        let data = AttributeScanner.nonIntroducingAttributes(importing: ["SwiftData"])

        #expect(testing.isSuperset(of: ["Test", "Suite", "main"]) && !testing.contains("Observable"))
        #expect(data.isSuperset(of: ["Model", "Observable"]) && !data.contains("Test"))
        #expect(AttributeScanner.nonIntroducingAttributes(importing: []) == AttributeScanner.builtinAttributes.subtracting(["MainActor"]))
    }
}
