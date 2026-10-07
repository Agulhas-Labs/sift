//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers which imports bring an SDK macro into a file and what is still read on one: only a whole-module import outside every `#if`, by its path's first component, counts, and an attribute written on a gated `#Preview` is still read.
@Suite(.temporaryDirectories)
struct FileScopeImportGateTests {
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

    /// `Net.URL` asked of an unbuilt repo holding the plain fixture beside `file`.
    private static func answer(beside file: String) async throws -> String {
        try await WhereNestedTypeOutsideTests.answer("Net.URL", files: ["Sources/Lib/Entry.swift": file, "Sources/Lib/Lib.swift": plain])
    }

    /// Every line writing the name bare in `file`'s neighbour is kept a use.
    private static func expectKept(beside file: String, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let url = try await answer(beside: file)

        #expect(url.contains("\n    :3  | func home() -> URL? {"), "\(file): \(url)", sourceLocation: sourceLocation)
        #expect(!url.contains("bare outside every type"), "\(file): \(url)", sourceLocation: sourceLocation)
    }

    /// An import naming a kind brings in that one declaration, never the module's macros, so the macro may be anyone's.
    @Test
    func anImportOfOneDeclarationDoesNotBringInTheMacro() async throws {
        for file in [
            "import struct SwiftUI.Text\n#Preview { Text(\"a\") }\n",
            "import class Foundation.NSObject\n@Observable final class Store {}\n",
            "import struct Testing.Tag\n@Suite struct Checks {}\n",
        ] {
            try await Self.expectKept(beside: file)
        }
    }

    /// A submodule import counts by its first component, so another module's submodule of the SDK's name brings in nothing.
    @Test
    func aSubmoduleOfAnotherModuleDoesNotBringInTheMacro() async throws {
        try await Self.expectKept(beside: "import DepotKit.SwiftUI\n#Preview { Text(\"a\") }\n")
    }

    /// An import under `#if` may not be compiled, so a macro outside its clause may be anyone's.
    @Test
    func anImportUnderAConditionDoesNotCount() async throws {
        for file in [
            "#if os(iOS)\nimport UIKit\n#else\nimport AppKit\n#endif\n#Preview { Gizmo() }\n",
            "#if DEBUG\nimport Observation\n#endif\n@Observable final class Store {}\n",
        ] {
            try await Self.expectKept(beside: file)
        }
    }

    /// A custom attribute written on a `#Preview` its import brings in is still a macro that may declare the name.
    @Test
    func anAttributeOnAGatedPreviewKeepsTheLines() async throws {
        try await Self.expectKept(beside: "import SwiftUI\n@Stamp #Preview { Text(\"a\") }\n")
    }

    /// The language's own attribute on such a `#Preview` adds nothing, so the lines are still counted apart.
    @Test
    func aLanguageAttributeOnAGatedPreviewLeavesTheLinesCountedApart() async throws {
        let url = try await Self.answer(beside: "import SwiftUI\n@available(iOS 17, *) #Preview { Text(\"a\") }\n")

        #expect(url.contains(Self.setApartTwo), "\(url)")
    }
}
