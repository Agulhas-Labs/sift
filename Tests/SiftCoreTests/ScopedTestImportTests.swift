//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers a scoped import (a kind keyword and a declaration after the module) counting as an import of its module for the test-file rule.
@Suite(.temporaryDirectories)
struct ScopedTestImportTests {
    private static func imports(of source: String) -> [String] {
        FileParser.parse(source: source, repoRelativePath: "Fixture.swift") { _, _ in }.file.imports
    }

    /// A file whose only framework import is a scoped XCTest one is a test file, and one scoped into Foundation is not.
    @Test
    func aScopedTestFrameworkImportMakesATestFile() {
        let scoped = Self.imports(of: "import struct XCTest.XCTestCase\nstruct Probe {}\n")
        #expect(scoped == ["XCTest"])
        #expect(TestFileRecognition.isTestFile(imports: scoped))

        let function = Self.imports(of: "import func Testing.expect\n")
        #expect(TestFileRecognition.isTestFile(imports: function))

        let other = Self.imports(of: "import class Foundation.NSObject\n")
        #expect(!TestFileRecognition.isTestFile(imports: other))
    }

    /// The plain, testable, exported and submodule spellings keep the path they were written with.
    @Test
    func otherImportSpellingsAreKept() {
        let source = "@testable import Alpha\n@_exported import Beta\nimport Gamma.Delta\nimport XCTest\n"

        #expect(Self.imports(of: source) == ["Alpha", "Beta", "Gamma.Delta", "XCTest"])
    }

    /// A source literal in a file with only a scoped test import is counted on the tests line, not listed as production.
    @Test
    func stringsSplitsAScopedImportFileAsTests() throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write("struct Depot {\n    func label() -> String {\n        \"a gizmo label\"\n    }\n}\n", to: "Sources/Depot/Depot.swift", in: root)
        try TestSources.write("import struct XCTest.XCTestCase\nstruct Probe {\n    func check() { _ = \"gizmo probe\" }\n}\n", to: "Tests/Depot/Probe.swift", in: root)
        try TestSources.commitAll(in: root, message: "scoped import fixture")

        let output = try SiftEngine(directory: root).strings(query: "gizmo")

        #expect(output.contains("Sources/Depot/Depot.swift:3"))
        #expect(!output.contains("Tests/Depot/Probe.swift:"))
        #expect(output.contains("in tests: 1 site in 1 file — Probe.swift (1)"))
    }
}
