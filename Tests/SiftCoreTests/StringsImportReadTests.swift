//
// Copyright © Agulhas Labs
//

@testable import SiftCore
import Testing

/// Pins that the parse-free import read `strings` classifies files by agrees with the imports the index stores for the same source.
struct StringsImportReadTests {
    private static let fixtures: [String: String] = [
        "plain": "import Foundation\nimport Testing\n\nstruct A {}\n",
        "scoped": "import struct XCTest.XCTestCase\nimport func Darwin.sqrt\nimport class Foundation.NSObject\n",
        "testable": "@testable import SiftCore\n@_exported import Foundation\npublic import Testing\n",
        "attributes": "@preconcurrency import Dispatch\n@_spi(Private) import Kit\n@testable\nimport Split\nprivate import Hidden\n",
        "comments": "// header\n\n/* block\nimport Ghost\n*/\n   \n  import Real // trailing\nimport Other /* note */\n",
        "submodule": "import Foundation.Date\nimport Kit.Sub\n",
        "conditions": "#if os(macOS)\nimport XCTest\n#endif\n#if DEBUG\nimport Debugging\n#else\nimport Release\n#endif\n",
        "late": "import First\n\nstruct A {}\n\nimport Late\n",
        "literal": "let text = \"\"\"\nimport Fake\n\"\"\"\nimport Real\n",
        "none": "struct A {\n    var important = 1\n}\n",
    ]

    @Test(arguments: fixtures.keys.sorted())
    func theFastReadAgreesWithTheParse(name: String) throws {
        let source = try #require(Self.fixtures[name])
        let parsed = FileParser.parse(source: source, repoRelativePath: "\(name).swift", alongside: { _, _ in }).file

        #expect(ImportLineReader.modules(inSource: source) == parsed.imports)
    }

    @Test func aScopedTestImportMakesATestFile() {
        let modules = ImportLineReader.modules(inSource: "import struct XCTest.XCTestCase\n")

        #expect(modules == ["XCTest"])
        #expect(TestFileRecognition.isTestFile(imports: modules))
    }
}
