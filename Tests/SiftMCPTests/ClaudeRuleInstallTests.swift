//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore
import Testing

/// The agent rule `sift install` copies in: found beside the binary or in Homebrew's share directory, copied when absent, kept when identical or linked, and backed up before a differing one is replaced.
@Suite(.temporaryDirectories)
struct ClaudeRuleInstallTests {
    private static func layout() throws -> (source: URL, destination: URL) {
        let root = try TemporaryDirectory.make("claude-rule")
        let source = root.appendingPathComponent("bundle/Sift.md")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "the rule".write(to: source, atomically: true, encoding: .utf8)
        return (source, root.appendingPathComponent("home/.claude/rules/sift.md"))
    }

    @Test
    func anAbsentRuleIsCopiedAndAnIdenticalOneLeft() throws {
        let (source, destination) = try Self.layout()

        let first = try ClaudeRuleInstall.install(source: source, destination: destination)
        #expect(first.lines == ["rule: installed \(destination.path) (loads on **/*.swift)"])
        #expect(first.written == [destination.path])
        #expect(try String(contentsOf: destination, encoding: .utf8) == "the rule")

        let second = try ClaudeRuleInstall.install(source: source, destination: destination)
        #expect(second.lines == ["rule: already installed — \(destination.path)"])
        #expect(!second.changed)
        #expect(PathKind.of(SettingsBackupFile.url(beside: destination)) == .absent)
    }

    @Test
    func aDifferingRuleIsKeptAsABackupThenReplaced() throws {
        let (source, destination) = try Self.layout()
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "my own edits".write(to: destination, atomically: true, encoding: .utf8)

        let backup = destination.deletingLastPathComponent().appendingPathComponent("sift.md.bak-sift")

        let outcome = try ClaudeRuleInstall.install(source: source, destination: destination)

        #expect(try String(contentsOf: backup, encoding: .utf8) == "my own edits")
        #expect(try String(contentsOf: destination, encoding: .utf8) == "the rule")
        #expect(outcome.lines == ["rule: installed \(destination.path) (loads on **/*.swift) (the previous one kept as \(backup.path))"])
    }

    @Test
    func aSymlinkedRuleIsLeftAlone() throws {
        let (source, destination) = try Self.layout()
        let checkout = source.deletingLastPathComponent().appendingPathComponent("checkout.md")
        try "checkout rule".write(to: checkout, atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: destination.path, withDestinationPath: checkout.path)

        let outcome = try ClaudeRuleInstall.install(source: source, destination: destination)

        #expect(outcome.lines == ["rule: \(destination.path) is a symlink to \(checkout.path) — left as is"])
        #expect(try String(contentsOf: checkout, encoding: .utf8) == "checkout rule")
        #expect(!outcome.changed)
    }

    @Test
    func withoutAShippedRuleTheStepIsSkippedWithANote() throws {
        let (_, destination) = try Self.layout()
        let binary = try TemporaryDirectory.make("npm-bin").appendingPathComponent("sift")
        try "binary".write(to: binary, atomically: true, encoding: .utf8)

        let source = ClaudeRuleInstall.source(forBinary: binary.path)
        let outcome = try ClaudeRuleInstall.install(source: source, destination: destination)

        #expect(source == nil)
        #expect(outcome.notes == ["rule: skipped — no Sift.md ships with this binary (the release bundle and Homebrew carry it)"])
        #expect(PathKind.of(destination) == .absent)
    }

    @Test
    func theRuleIsFoundBesideTheBinaryOrInHomebrewsShareThroughALink() throws {
        let root = try TemporaryDirectory.make("rule-source")
        let manager = FileManager.default
        let bundle = root.appendingPathComponent("bundle")
        try manager.createDirectory(at: bundle, withIntermediateDirectories: true)
        try "binary".write(to: bundle.appendingPathComponent("sift"), atomically: true, encoding: .utf8)
        try "rule".write(to: bundle.appendingPathComponent("Sift.md"), atomically: true, encoding: .utf8)
        #expect(ClaudeRuleInstall.source(forBinary: bundle.appendingPathComponent("sift").path)?.lastPathComponent == "Sift.md")

        let cellar = root.appendingPathComponent("Cellar/sift/1.0")
        try manager.createDirectory(at: cellar.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try manager.createDirectory(at: cellar.appendingPathComponent("share/sift"), withIntermediateDirectories: true)
        try "binary".write(to: cellar.appendingPathComponent("bin/sift"), atomically: true, encoding: .utf8)
        try "rule".write(to: cellar.appendingPathComponent("share/sift/Sift.md"), atomically: true, encoding: .utf8)
        let linkDirectory = root.appendingPathComponent("bin")
        try manager.createDirectory(at: linkDirectory, withIntermediateDirectories: true)
        try manager.createSymbolicLink(atPath: linkDirectory.appendingPathComponent("sift").path, withDestinationPath: "../Cellar/sift/1.0/bin/sift")

        let found = try #require(ClaudeRuleInstall.source(forBinary: linkDirectory.appendingPathComponent("sift").path))
        #expect(found.path.hasSuffix("Cellar/sift/1.0/share/sift/Sift.md"))
    }
}
