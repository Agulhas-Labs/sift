//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Pins the store's conformers block's last line: every Swift file git shows that writes the protocol's name, each counted once in the first class that holds it, the classes summing to the text search's count.
@Suite(.temporaryDirectories, .serialized)
struct WhereConformerFileAccountingTests {
    private static var manifest: String {
        """
        // swift-tools-version: 6.0
        // Greeter's conformers live in Lib.
        import PackageDescription

        let package = Package(
            name: "Lib",
            targets: [.target(name: "Lib")]
        )
        """
    }

    /// The shape the line was measured on: conformers, the protocol's declaration and an extension of it, a use, and a manifest writing the name in a comment.
    private static func corpus() async throws -> SharedBuiltFixture {
        try await SharedBuiltFixtures.process.fixture(for: Self.self, named: "conformer-file-accounting-corpus") { root in
            try TestSources.write(manifest, to: "Package.swift", in: root)
            try TestSources.write("public protocol Greeter {\n    func salute()\n}\n", to: "Sources/Lib/Greeter.swift", in: root)
            try TestSources.write("extension Greeter {\n    public func wave() {}\n}\n", to: "Sources/Lib/Wave.swift", in: root)
            try TestSources.write("public struct Soldier: Greeter {\n    public func salute() {}\n}\n", to: "Sources/Lib/Ranks.swift", in: root)
            try TestSources.write("public struct Cadet: Greeter {\n    public func salute() {}\n}\n", to: "Sources/Lib/Cadet.swift", in: root)
            try TestSources.write("public func drill(greeter: Greeter) {\n    greeter.salute()\n}\n", to: "Sources/Lib/Drill.swift", in: root)
            try TestSources.commitAll(in: root, message: "accounting corpus")
            try await TestSources.swiftBuildSuspending(packageAt: root)
        }
    }

    /// Every residue class at once, under a qualified query: a typealias and the conformer and use written only through it, a longer name, seven files writing the name only in comments or strings (one a manifest), a second `Greeter` in another module with its conformer, and a symbolic link to an ignored file.
    private static func residues() async throws -> SharedBuiltFixture {
        try await SharedBuiltFixtures.process.fixture(for: Self.self, named: "conformer-file-accounting-residues") { root in
            try TestSources.write(
                """
                // swift-tools-version: 6.0
                // Greeter is declared twice, once in each target.
                import PackageDescription

                let package = Package(
                    name: "Lib",
                    targets: [.target(name: "Lib"), .target(name: "Other")]
                )
                """,
                to: "Package.swift",
                in: root
            )
            try TestSources.write("public protocol Greeter {\n    func salute()\n}\n", to: "Sources/Lib/Greeter.swift", in: root)
            try TestSources.write("public typealias Host = Greeter\n", to: "Sources/Lib/Alias.swift", in: root)
            try TestSources.write("public struct Guest: Host {\n    public func salute() {}\n}\n\npublic func seat(_ host: Host) {}\n", to: "Sources/Lib/Guest.swift", in: root)
            try TestSources.write("public struct GreeterBadge {}\n", to: "Sources/Lib/Badge.swift", in: root)
            for (index, letter) in ["A", "B", "C", "D", "E", "F"].enumerated() {
                let text = index.isMultiple(of: 2) ? "// Greeter is the protocol to conform to.\nlet note\(letter) = 1\n" : "let label\(letter) = \"Greeter\"\n"
                try TestSources.write(text, to: "Sources/Lib/Notes/\(letter).swift", in: root)
            }
            try TestSources.write("public protocol Greeter {}\n", to: "Sources/Other/Greeter.swift", in: root)
            try TestSources.write("struct Usher: Greeter {}\n", to: "Sources/Other/Usher.swift", in: root)
            try TestSources.write("Hidden/\n", to: ".gitignore", in: root)
            try TestSources.write("// Greeter, behind a link.\n", to: "Hidden/Shadow.swift", in: root)
            try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("Sources/Lib/Echo.swift").path, withDestinationPath: "../../Hidden/Shadow.swift")
            try TestSources.commitAll(in: root, message: "accounting residues")
            try await TestSources.swiftBuildSuspending(packageAt: root)
        }
    }

    private static var corpusLine: String {
        "every Swift file that writes Greeter is accounted for (6, a text search of the Swift files git shows, manifests included): 2 declare a conformer (above), 2 declare or extend it, 1 uses it (used by, above), 1 writes it only in comments or strings: Package.swift"
    }

    private static func lines(of output: String) -> [String] {
        output.components(separatedBy: "\n")
    }

    /// The corpus shape: two conformers, the declaration and its extension, one use and the manifest's comment sum to the six files.
    @Test
    func theCorpusShapeSumsToTheTextSearch() async throws {
        try await Self.corpus().withEngine { engine in
            let output = try await engine.lookup(symbol: "Greeter", freshness: engine.ensureFresh())

            #expect(Self.lines(of: output).contains(Self.corpusLine), "\(output)")
            #expect(output.components(separatedBy: "every Swift file that writes").count == 2, "\(output)")
        }
    }

    /// Under `--refs` the manifest is no file the `not code` section reads, so it is still named, and the files of `references to` stay counted as uses.
    @Test
    func referencesKeepAManifestNamed() async throws {
        try await Self.corpus().withEngine { engine in
            let output = try await engine.lookup(symbol: "Greeter", freshness: engine.ensureFresh(), options: WhereOptions(includeReferences: true))

            #expect(Self.lines(of: output).contains(Self.corpusLine), "\(output)")
        }
    }

    /// An answer the hook serves in place of a search keeps the line, the class naming its files.
    @Test
    func theStandInAnswerKeepsTheLine() async throws {
        try await Self.corpus().withEngine { engine in
            let output = try await engine.lookup(symbol: "Greeter", freshness: engine.ensureFresh(), options: WhereOptions(standsInForSearch: true))

            #expect(Self.lines(of: output).contains(Self.corpusLine), "\(output)")
        }
    }

    /// No conformer's file writes the name, so that class is left out; the typealias's file is `alias it` while its conformer and use, written through it, are in no class; the other module's `Greeter` is code not counted above; a residue over five files ends `+<k> more`; and the symbolic link is not followed.
    @Test
    func residuesAreNamedAndCapped() async throws {
        try await Self.residues().withEngine { engine in
            let output = try await engine.lookup(symbol: "Lib.Greeter", freshness: engine.ensureFresh())

            #expect(Self.lines(of: output).contains("every Swift file that writes Greeter is accounted for (12, a text search of the Swift files git shows, manifests included): 1 declares or extends it, 1 aliases it, 7 write it only in comments or strings: Package.swift, Sources/Lib/Notes/A.swift, Sources/Lib/Notes/B.swift, Sources/Lib/Notes/C.swift, Sources/Lib/Notes/D.swift, +2 more, 1 writes it only inside a longer name: Sources/Lib/Badge.swift, 2 write it in code not counted above: Sources/Other/Greeter.swift, Sources/Other/Usher.swift"), "\(output)")
            #expect(!output.contains("Echo.swift"), "\(output)")
            #expect(!output.contains("Shadow"), "\(output)")
        }
    }

    /// Under `--refs` the comments-or-strings files the index reads are counted under `not code`, and only the manifest is named.
    @Test
    func referencesCountTheNotCodeFiles() async throws {
        try await Self.residues().withEngine { engine in
            let output = try await engine.lookup(symbol: "Lib.Greeter", freshness: engine.ensureFresh(), options: WhereOptions(includeReferences: true))

            #expect(output.contains(", 7 write it only in comments or strings (6 under not code, below): Package.swift, 1 writes it only inside a longer name: Sources/Lib/Badge.swift, "), "\(output)")
        }
    }

    /// A page past the first gives the counts and no paths.
    @Test
    func aLaterPageGivesCountsOnly() async throws {
        try await Self.residues().withEngine { engine in
            let output = try await engine.lookup(symbol: "Lib.Greeter", freshness: engine.ensureFresh(), options: WhereOptions(includeReferences: true, offset: 1))

            #expect(Self.lines(of: output).contains("every Swift file that writes Greeter is accounted for (12, a text search of the Swift files git shows, manifests included): 1 declares or extends it, 1 aliases it, 7 write it only in comments or strings (6 under not code, below), 1 writes it only inside a longer name, 2 write it in code not counted above"), "\(output)")
        }
    }

    /// The `--files` view and an answer at a revision carry no line.
    @Test
    func theFilesViewAndARevisionLeaveItOut() async throws {
        try await Self.residues().withEngine { engine in
            let files = try await engine.lookup(symbol: "Lib.Greeter", freshness: engine.ensureFresh(), options: WhereOptions(filesOnly: true))
            let revision = try await engine.lookup(symbol: "Lib.Greeter", at: "HEAD")

            #expect(!files.contains("every Swift file that writes"), "\(files)")
            #expect(!revision.contains("every Swift file that writes"), "\(revision)")
        }
    }

    /// Past any of the scan's bounds the whole line is left out, the deadline judged on an injected clock that steps a second at each reading.
    @Test
    func pastTheBoundsTheLineIsLeftOut() async throws {
        try await Self.corpus().withEngine { engine in
            let freshness = try await engine.ensureFresh()
            defer { engine.textSearchBounds = TextSearchFiles.Bounds() }
            let start = ContinuousClock.now
            engine.textSearchBounds = TextSearchFiles.Bounds(now: { start })
            let stopped = try await engine.lookup(symbol: "Greeter", freshness: freshness)
            engine.textSearchBounds = TextSearchFiles.Bounds(files: 5)
            let tooMany = try await engine.lookup(symbol: "Greeter", freshness: freshness)
            engine.textSearchBounds = TextSearchFiles.Bounds(bytes: 64)
            let tooLarge = try await engine.lookup(symbol: "Greeter", freshness: freshness)
            let ticker = Ticker(start: start)
            engine.textSearchBounds = TextSearchFiles.Bounds(now: { ticker.next() })
            let tooLate = try await engine.lookup(symbol: "Greeter", freshness: freshness)

            #expect(Self.lines(of: stopped).contains(Self.corpusLine), "\(stopped)")
            for output in [tooMany, tooLarge, tooLate] {
                #expect(output.contains("conformers of Greeter ("), "\(output)")
                #expect(!output.contains("every Swift file that writes"), "\(output)")
            }
        }
    }
}

private extension WhereConformerFileAccountingTests {
    /// A clock a second further on at each reading.
    final class Ticker: @unchecked Sendable {
        private let lock = NSLock()
        private var instant: ContinuousClock.Instant

        init(start: ContinuousClock.Instant) {
            instant = start
        }

        func next() -> ContinuousClock.Instant {
            lock.withLock {
                instant += .seconds(1)
                return instant
            }
        }
    }
}
