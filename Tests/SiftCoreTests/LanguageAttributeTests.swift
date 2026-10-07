//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers which attributes Sift reads as the language's own: a spelling the compiler's attribute tables carry parses as that attribute wherever it is written, so it introduces no name and marks no macro, while a macro the SDK ships stays a possible macro in the digest and, in a file that does not import its module, keeps a bare name outside every type a use in `where`.
@Suite(.temporaryDirectories)
struct LanguageAttributeTests {
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
        try await WhereNestedTypeOutsideTests.answer("Net.URL", files: ["Sources/Lib/Lib.swift": plain, "Sources/Lib/Entry.swift": file])
    }

    /// A file-scope type carrying `@main` declares nothing beside it, so the lines writing `URL` bare at the top level are still counted apart.
    @Test
    func aMainTypeAtFileScopeLeavesTheLinesCountedApart() async throws {
        let url = try await Self.answer(beside: "@main\nstruct Entry {\n    static func main() {}\n}\n")

        #expect(url.contains(Self.setApartTwo), "\(url)")
        #expect(url.contains("\n    :6  | func check(_ x: Net.URL) { x.fetched() }"), "\(url)")
    }

    /// An import re-exported with `@_exported`, or one marked `@_spi`, is the language's own spelling and declares nothing at file scope.
    @Test
    func aReexportedImportLeavesTheLinesCountedApart() async throws {
        for file in ["@_exported import Foundation\n", "@_spi(Internal) import Foundation\n"] {
            let url = try await Self.answer(beside: file)

            #expect(url.contains(Self.setApartTwo), "\(file): \(url)")
        }
    }

    /// A function marked `@Test` at file scope, in a file that does not import Testing, carries a peer macro the language does not define and may be anyone's, so every line writing the name bare stays a use.
    @Test
    func aTestFunctionAtFileScopeKeepsTheLines() async throws {
        let url = try await Self.answer(beside: "@Test func anchor() {}\n")

        #expect(url.contains("\n    :3  | func home() -> URL? {"), "\(url)")
        #expect(!url.contains("bare outside every type"), "\(url)")
    }

    /// The language's own attributes mark no macro in the digest.
    @Test
    func theLanguagesOwnAttributesMarkNoMacro() {
        let signatures = [
            "@main struct Entry",
            "@NSApplicationMain final class Delegate",
            "@_exported import Foundation",
            "@_spi(Internal) @backDeployed(before: macOS 15) public func home()",
            "@_documentation(visibility: private) @_disfavoredOverload @_alwaysEmitIntoClient public func home()",
            "@_silgen_name(\"swift_demangle\") func demangled()",
        ]
        for signature in signatures {
            #expect(AttributeScanner.customAttributeNames(in: signature).isEmpty, "\(signature)")
        }
    }

    /// A macro the SDK ships, adding members or peers, still marks a possible macro in the digest.
    @Test
    func anSDKMacroStillMarksAMacro() {
        #expect(AttributeScanner.customAttributeNames(in: "@Observable @MainActor final class Store") == ["Observable"])
        #expect(AttributeScanner.customAttributeNames(in: "@Model final class Item") == ["Model"])
        #expect(AttributeScanner.customAttributeNames(in: "@Suite struct Checks") == ["Suite"])
        #expect(AttributeScanner.customAttributeNames(in: "@Test func anchor()") == ["Test"])
    }
}
