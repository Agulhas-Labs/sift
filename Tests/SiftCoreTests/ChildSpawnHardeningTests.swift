//
// Copyright © Agulhas Labs
//

import Foundation
import SwiftParser
import SwiftSyntax
import Testing

/// Every place sift starts a `git` switches the repository's fsmonitor and hooks off, so a program named in a repository's own config is never run by a read.
///
/// The scan parses each source and checks every spawn site on its own: a string literal that is `git`, or a path ending in `/git`, whether handed to a process as its executable or as the first argument after `env`. The function holding it must also carry the hardening (`ProcessEnvironment.gitHardening`, or the literal `core.fsmonitor=false` where a site assembles its own settings), so a second, bare spawn beside a hardened one fails here.
@Suite(.temporaryDirectories)
struct ChildSpawnHardeningTests {
    /// Files that spell `git` without starting it: they parse, classify or redact command lines someone else runs.
    private static let recognitionOnly: Set<String> = [
        "ShellQuery.swift",
        "WorktreeOriginScan.swift",
        "RedactedCall.swift",
        "ShapeFlagVocabulary.swift",
    ]

    private static var sources: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources", isDirectory: true)
    }

    private static func swiftFiles(under root: URL) -> [URL] {
        let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        return (walker?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "swift" }.sorted { $0.path < $1.path }
    }

    /// Every git-naming spawn site in the files under a root, named `File.swift:line`, with whether its function carries the hardening.
    private static func sites(under root: URL, ignoring allowed: Set<String>) throws -> [(name: String, hardened: Bool)] {
        try swiftFiles(under: root).filter { !allowed.contains($0.lastPathComponent) }.flatMap { file in
            let tree = try Parser.parse(source: String(contentsOf: file, encoding: .utf8))
            let scan = SpawnSiteScan(fileName: file.lastPathComponent, converter: SourceLocationConverter(fileName: file.lastPathComponent, tree: tree))
            scan.walk(tree)
            return scan.found
        }
    }

    /// The git spawn sites that lack the hardening; empty when every site carries it.
    static func unhardenedSites(under root: URL, ignoring allowed: Set<String> = recognitionOnly) throws -> [String] {
        try sites(under: root, ignoring: allowed).filter { !$0.hardened }.map(\.name)
    }

    @Test
    func everyGitSpawnSiteCarriesTheHardening() throws {
        let files = Self.swiftFiles(under: Self.sources)
        try #require(files.count > 50, "the scan found \(files.count) sources under \(Self.sources.path)")

        #expect(try Self.unhardenedSites(under: Self.sources) == [])
    }

    /// The scan is not vacuous: it finds the spawn sites, and flags each one whose hardening is gone, beside a hardened one or reached through `env`.
    @Test
    func theScanFindsTheSpawnSitesAndFlagsEachWithoutTheHardening() throws {
        let spawning = try Set(Self.sites(under: Self.sources, ignoring: Self.recognitionOnly).map { String($0.name.split(separator: ":")[0]) })
        for expected in ["GitContext.swift", "TreeKey.swift", "TreeContentHash.swift", "RunChangedFiles.swift", "SetAsideGit.swift", "WrappedRunPermission.swift", "ExternalReplayHook.swift"] {
            #expect(spawning.contains(expected), "\(expected) is not recognised as a site that starts git")
        }

        let scratch = try TemporaryDirectory.make("spawn-hardening")
        let hardened = "func hardened() { let path = \"/usr/bin/git\"\nlet lead = ProcessEnvironment.gitHardening }\n"
        let files = [
            "Bare.swift": "func run() { let path = \"/usr/bin/git\" }\n",
            "Hardened.swift": hardened,
            "Prose.swift": "// the \"/usr/bin/git\" path\n",
            "Settings.swift": "func run() { let path = \"/usr/bin/git\"\nlet lead = [\"-c\", \"core.fsmonitor=false\"] }\n",
            "Twin.swift": hardened + "func bare() { let path = \"/usr/bin/git\" }\n",
            "Env.swift": hardened + "func env() { let run = [\"/usr/bin/env\", \"git\", \"status\"] }\n",
            "Path.swift": "func path() { let name = \"git\" }\n",
        ]
        for (name, text) in files {
            try Data(text.utf8).write(to: scratch.appendingPathComponent(name))
        }

        let flagged = try Self.unhardenedSites(under: scratch)

        #expect(flagged == ["Bare.swift:1", "Env.swift:3", "Path.swift:1", "Twin.swift:3"], "\(flagged)")
    }
}

private extension ChildSpawnHardeningTests {
    /// Collects the string literals naming git, each with whether the function around it mentions the hardening.
    final class SpawnSiteScan: SyntaxVisitor {
        let fileName: String
        let converter: SourceLocationConverter
        var found: [(name: String, hardened: Bool)] = []

        init(fileName: String, converter: SourceLocationConverter) {
            self.fileName = fileName
            self.converter = converter
            super.init(viewMode: .sourceAccurate)
        }

        override func visit(_ node: StringLiteralExprSyntax) -> SyntaxVisitorContinueKind {
            guard let text = node.representedLiteralValue, text == "git" || text.hasSuffix("/git") else { return .skipChildren }
            let line = converter.location(for: node.positionAfterSkippingLeadingTrivia).line
            found.append((name: "\(fileName):\(line)", hardened: Self.carriesHardening(around: node)))
            return .skipChildren
        }

        /// Whether the nearest enclosing function, initializer or variable declaration names the hardening in code.
        private static func carriesHardening(around node: some SyntaxProtocol) -> Bool {
            var scope: Syntax? = node.parent
            var property: Syntax?
            while let current = scope, !current.is(FunctionDeclSyntax.self), !current.is(InitializerDeclSyntax.self) {
                if current.is(VariableDeclSyntax.self) {
                    property = current
                }
                scope = current.parent
            }
            let probe = HardeningProbe(viewMode: .sourceAccurate)
            probe.walk(scope ?? property ?? Syntax(node))
            return probe.seen
        }
    }

    /// Looks for the hardening constant, or a literal that spells its fsmonitor setting.
    final class HardeningProbe: SyntaxVisitor {
        var seen = false

        override func visit(_ node: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
            if node.baseName.text == "gitHardening" {
                seen = true
            }
            return .visitChildren
        }

        override func visit(_ node: StringLiteralExprSyntax) -> SyntaxVisitorContinueKind {
            if node.representedLiteralValue == "core.fsmonitor=false" {
                seen = true
            }
            return .visitChildren
        }
    }
}
