//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers where an import under `#if` counts for an SDK macro: in its own clause and the clauses nested in it, never in a sibling clause or outside the `#if`; an unconditional import counts everywhere.
@Suite(.temporaryDirectories)
struct ConditionalImportScopeTests {
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

    private static func expectSetApart(beside file: String, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let url = try await answer(beside: file)

        #expect(url.contains(setApartTwo), "\(file): \(url)", sourceLocation: sourceLocation)
    }

    private static func expectKept(beside file: String, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let url = try await answer(beside: file)

        #expect(url.contains("\n    :3  | func home() -> URL? {"), "\(file): \(url)", sourceLocation: sourceLocation)
        #expect(!url.contains("bare outside every type"), "\(file): \(url)", sourceLocation: sourceLocation)
    }

    /// The import and the macro in one `#if` clause: the import is compiled whenever the macro is.
    @Test
    func anImportAndAMacroInOneClauseCount() async throws {
        try await Self.expectSetApart(beside: "#if DEBUG\nimport SwiftUI\n#Preview { Text(\"a\") }\n#Preview { Text(\"b\") }\n#endif\n")
        try await Self.expectSetApart(beside: "#if canImport(Testing)\nimport Testing\n@Test func anchor() {}\n#endif\n")
    }

    /// A sibling clause is compiled only when the import's is not.
    @Test
    func anImportDoesNotCountInASiblingClause() async throws {
        try await Self.expectKept(beside: "#if A\nimport SwiftUI\n#else\n#Preview { Text(\"a\") }\n#endif\n")
        try await Self.expectKept(beside: "#if A\nimport SwiftUI\n#elseif B\n#Preview { Text(\"a\") }\n#endif\n")
    }

    /// Outside the `#if` the import may not have been compiled.
    @Test
    func anImportDoesNotCountAfterTheEndif() async throws {
        try await Self.expectKept(beside: "#if DEBUG\nimport SwiftUI\n#endif\n#Preview { Text(\"a\") }\n")
    }

    /// A clause nested in the import's clause is compiled only where the import is.
    @Test
    func anImportCountsInANestedClause() async throws {
        try await Self.expectSetApart(beside: "#if DEBUG\nimport SwiftUI\n#if os(iOS)\n#Preview { Text(\"a\") }\n#endif\n#endif\n")
    }

    /// An import nested deeper does not reach the enclosing clause.
    @Test
    func aNestedImportDoesNotCountInTheEnclosingClause() async throws {
        try await Self.expectKept(beside: "#if DEBUG\n#if os(iOS)\nimport SwiftUI\n#endif\n#Preview { Text(\"a\") }\n#endif\n")
    }

    /// An unconditional import counts for a macro under any `#if`, as before.
    @Test
    func anUnconditionalImportStillCountsUnderACondition() async throws {
        try await Self.expectSetApart(beside: "import SwiftUI\n#if DEBUG\n#Preview { Text(\"a\") }\n#endif\n")
        try await Self.expectSetApart(beside: "import SwiftUI\n#if A\n#else\n#Preview { Text(\"a\") }\n#endif\n")
    }
}
