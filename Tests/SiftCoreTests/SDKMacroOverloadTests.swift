//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers an SDK macro's spelling that may be another module's overload: `@Observable` and `@Model` written with an argument list, and `@Test`, `@Suite` or `#Preview` where the tree declares a macro of that name.
@Suite(.temporaryDirectories)
struct SDKMacroOverloadTests {
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

    /// A declaration of a macro named `name` in the tree, with the role `role`.
    private static func declaring(_ name: String, role: String) -> String {
        "\(role) public macro \(name)(tag: Int) = #externalMacro(module: \"DepotKit\", type: \"Stamp\")\n"
    }

    /// Whether the files of `files`, written into a fresh repo in the order given, expand at file scope.
    private static func expands(_ files: [(path: String, source: String)]) async throws -> Bool {
        let root = try TestSources.makeTempRepo()
        for file in files {
            try TestSources.write(file.source, to: file.path, in: root)
        }
        return await BareNameOutsideTypes.expandsAtFileScope(paths: files.map(\.path), under: root)
    }

    /// `@Observable` and `@Model` take no arguments in the SDK, so one written with an argument list, empty parentheses included, is another module's macro and keeps every line writing the name bare.
    @Test
    func anArgumentlessSDKMacroWrittenWithArgumentsKeepsTheLines() async throws {
        let files = [
            "import Observation\n@Observable(tag: 1) final class Store {}\n",
            "import SwiftUI\n@Observable() final class Store {}\n",
            "import SwiftData\n@Model(tag: 1) final class Item {}\n",
        ]
        for file in files {
            let url = try await WhereNestedTypeOutsideTests.answer("Net.URL", files: ["Sources/Lib/Entry.swift": file, "Sources/Lib/Lib.swift": Self.plain])

            #expect(url.contains("\n    :3  | func home() -> URL? {"), "\(file): \(url)")
            #expect(!url.contains("bare outside every type"), "\(file): \(url)")
        }
    }

    /// A `@Test`, `@Suite` or `#Preview` under its import expands at file scope once any file declares a macro of its name, before or after it.
    @Test
    func anSDKMacroTheTreeAlsoDeclaresExpands() async throws {
        let cases: [(use: String, declaration: String)] = [
            ("import Testing\n@Test(tag: 1) func anchor() {}\n", Self.declaring("Test", role: "@attached(peer)")),
            ("import Testing\n@Suite(tag: 1) struct Checks {}\n", Self.declaring("Suite", role: "@attached(peer)")),
            ("import SwiftUI\n#Preview(tag: 1) { Text(\"a\") }\n", Self.declaring("Preview", role: "@freestanding(declaration)")),
        ]
        for (use, declaration) in cases {
            let uses = (path: "Sources/Lib/Entry.swift", source: use)
            let declares = (path: "Sources/Macros/Macros.swift", source: declaration)

            #expect(try await Self.expands([uses, declares]), "\(use)")
            #expect(try await Self.expands([declares, uses]), "\(use)")
            #expect(try await !Self.expands([uses]), "\(use)")
        }
    }

    /// A tree declaring a macro of another name leaves the SDK macro gated by its import.
    @Test
    func aDeclarationOfAnotherNameDoesNotCount() async throws {
        let uses = (path: "Sources/Lib/Entry.swift", source: "import Testing\n@Test func anchor() {}\n")
        let declares = (path: "Sources/Macros/Macros.swift", source: Self.declaring("Stamp", role: "@attached(peer)"))

        #expect(try await !Self.expands([uses, declares]))
    }
}
