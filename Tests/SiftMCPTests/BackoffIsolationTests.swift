//
// Copyright © Agulhas Labs
//

import Foundation
import Testing

/// No test source reaches the real back-off directory: a test that did armed windows in `~/.sift/advice/backoff/` for a temp-directory root, and the next real lookup of that shape was answered "backing off".
///
/// The compile-time half is that ``InPlaceAnswerer`` and ``PreToolUseCommand/decided(command:payload:cwd:session:context:answerer:ledger:usage:suppressions:runPermission:couldAnswer:)`` take their back-off or answerer with no default, so a test has to choose one. This is the textual half: a test source may not write the standard back-off, or the standard advice directory, unless it names the environment it resolves from.
struct BackoffIsolationTests {
    private static var testsDirectory: URL {
        URL(filePath: #filePath)
            .deletingLastPathComponent() // SiftMCPTests
            .deletingLastPathComponent() // Tests
    }

    /// What a test source may not write: the standard back-off however it is spelled or wrapped, the standard advice directory with no `environment:` to resolve it from, or a back-off built over the real home.
    private static var testPatterns: [String] {
        [
            #"InPlaceBackoff\s*\.\s*standard\s*\("#,
            #"InPlaceBackoff\s*=\s*\.\s*standard\s*\("#,
            #"backoff\s*:\s*\.\s*standard\s*\("#,
            #"AdviceLedger\s*\.\s*standardDirectory\s*\((?!\s*environment\s*:)"#,
            #"InPlaceBackoff\s*\(\s*directory\s*:\s*SiftPaths\s*\.\s*home"#,
        ]
    }

    /// What production code may not write: a parameter or property that defaults to the standard back-off, or an answerer that defaults to the production one, either of which a test reaches by leaving the argument out. The one production `backoff: .standard()`, passed explicitly where the hook runs, is not a default and is allowed.
    private static var sourcePatterns: [String] {
        [
            #"InPlaceBackoff\s*=\s*\.\s*standard\s*\("#,
            #"InPlaceBackoff\s*=\s*InPlaceBackoff\s*\.\s*standard\s*\("#,
            #"InPlaceAnswerer\s*\.\s*Outcome\s*=\s*\{"#,
        ]
    }

    /// Where `patterns` match in `text`, as `line: text` for the line each match starts on; a match may run across lines.
    static func offences(in text: String, patterns: [String]) -> [String] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let whole = NSRange(text.startIndex..., in: text)
        let starts = patterns.flatMap { pattern -> [Int] in
            guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
            return expression.matches(in: text, range: whole).compactMap { match in
                Range(match.range, in: text).map { text[..<$0.lowerBound].count { $0 == "\n" } }
            }
        }
        return Set(starts).sorted().map { "\($0 + 1): \(lines[$0].trimmingCharacters(in: .whitespaces))" }
    }

    /// The lines of a test source that reach the real back-off directory.
    static func offences(in text: String) -> [String] {
        offences(in: text, patterns: testPatterns)
    }

    /// Every Swift file under `top` (`Tests` or `Sources`), written or not: what git has not yet been told about is read too.
    private static func swiftFiles(under top: String) -> [URL] {
        let root = testsDirectory.deletingLastPathComponent().appendingPathComponent(top, isDirectory: true)
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        return (enumerator?.compactMap { $0 as? URL } ?? []).filter { $0.pathExtension == "swift" }.sorted { $0.path < $1.path }
    }

    private static func scan(_ top: String, patterns: [String]) throws -> (files: Int, found: [String]) {
        let own = URL(filePath: #filePath).path
        let files = swiftFiles(under: top).filter { $0.path != own }
        let prefix = testsDirectory.deletingLastPathComponent().path + "/"
        let found = try files.flatMap { file in
            try offences(in: String(contentsOf: file, encoding: .utf8), patterns: patterns).map { "\(file.path.replacingOccurrences(of: prefix, with: "")):\($0)" }
        }
        return (files.count, found)
    }

    @Test
    func noTestSourceWritesTheStandardBackoff() throws {
        let scanned = try Self.scan("Tests", patterns: Self.testPatterns)

        #expect(scanned.files > 0)
        #expect(scanned.found.isEmpty, "a test reaches the real back-off directory; pass a scratch one: \(scanned.found)")
    }

    @Test
    func noSourceDefaultsToTheStandardBackoff() throws {
        let scanned = try Self.scan("Sources", patterns: Self.sourcePatterns)

        #expect(scanned.files > 0)
        #expect(scanned.found.isEmpty, "a default reaches the real back-off directory from any caller that leaves it out, tests included; take it explicitly: \(scanned.found)")
    }

    @Test
    func theScanSeesWhatItIsMeantToForbid() {
        let standard = ".standard()"
        let written = [
            "let a = InPlaceBackoff" + standard,
            "let b = AdviceLedger" + ".standardDirectory()",
            "let c = AdviceLedger" + ".standardDirectory(environment: [:])",
            "let d: InPlaceBackoff = " + standard,
            "answer(match, backoff:",
            "    " + standard + ")",
            "let e = InPlaceBackoff(directory: SiftPaths" + ".home)",
        ].joined(separator: "\n")

        #expect(Self.offences(in: written).map { $0.prefix { $0 != ":" } } == ["1", "2", "4", "5", "7"])
    }

    @Test
    func theSourceScanSeesADefaultedParameter() {
        let written = [
            "    backoff: InPlaceBackoff = " + ".standard(),",
            "    answerer: (Match) -> InPlaceAnswerer.Outcome = { _ in .answered },",
            "    answerer: { InPlaceAnswerer.answer($0, backoff: " + ".standard()) },",
        ].joined(separator: "\n")

        #expect(Self.offences(in: written, patterns: Self.sourcePatterns).count == 2)
    }
}
