//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Pins the conformers block's file accounting over a working tree that moved after the build: a file changed since, one deleted, one that cannot be read; each test edits its own freshly built repository.
@Suite(.temporaryDirectories)
struct WhereConformerFileAccountingTreeTests {
    private static var prefix: String {
        "every Swift file that writes Greeter is accounted for ("
    }

    /// A built package of a protocol, a conformer, a use and a file writing the name only in a comment, and an engine warmed over it.
    private static func builtRepo() async throws -> (root: URL, engine: SiftEngine) {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(
            """
            // swift-tools-version: 6.0
            import PackageDescription

            let package = Package(
                name: "Lib",
                targets: [.target(name: "Lib")]
            )
            """,
            to: "Package.swift",
            in: root
        )
        try TestSources.write("public protocol Greeter {\n    func salute()\n}\n", to: "Sources/Lib/Greeter.swift", in: root)
        try TestSources.write("public struct Soldier: Greeter {\n    public func salute() {}\n}\n", to: "Sources/Lib/Ranks.swift", in: root)
        try TestSources.write("public func drill(greeter: Greeter) {\n    greeter.salute()\n}\n", to: "Sources/Lib/Drill.swift", in: root)
        try TestSources.write("// Greeter is saluted on parade.\nlet parade = 1\n", to: "Sources/Lib/Notes.swift", in: root)
        try TestSources.commitAll(in: root, message: "accounting tree")
        try await TestSources.swiftBuildSuspending(packageAt: root)
        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()
        _ = try await engine.ensureFresh()
        return (root, engine)
    }

    private static func accountingLine(in output: String) -> String? {
        output.components(separatedBy: "\n").first { $0.hasPrefix(prefix) }
    }

    /// A file written since the build is classed `changed since the build`, ahead of the use the build recorded in it.
    @Test
    func aFileChangedSinceTheBuildIsClassedSo() async throws {
        let (root, engine) = try await Self.builtRepo()
        try TestSources.write("public func drill(greeter: Greeter) {\n    greeter.salute()\n    greeter.salute()\n}\n", to: "Sources/Lib/Drill.swift", in: root)

        let output = try await engine.lookup(symbol: "Greeter", freshness: engine.ensureFresh())

        #expect(Self.accountingLine(in: output) == Self.prefix + "4, a text search of the Swift files git shows): 1 declares a conformer (above), 1 declares or extends it, 1 changed since the build: Sources/Lib/Drill.swift, 1 writes it only in comments or strings: Sources/Lib/Notes.swift", "\(output)")
    }

    /// A tracked file deleted from the tree is no file of the search.
    @Test
    func aDeletedFileIsNotCounted() async throws {
        let (root, engine) = try await Self.builtRepo()
        try FileManager.default.removeItem(at: root.appendingPathComponent("Sources/Lib/Drill.swift"))

        let output = try await engine.lookup(symbol: "Greeter", freshness: engine.ensureFresh())

        #expect(Self.accountingLine(in: output) == Self.prefix + "3, a text search of the Swift files git shows): 1 declares a conformer (above), 1 declares or extends it, 1 writes it only in comments or strings: Sources/Lib/Notes.swift", "\(output)")
    }

    /// A file that is there but cannot be read is named after the classes, outside the count, never dropped.
    @Test
    func anUnreadableFileIsNamedOutsideTheCount() async throws {
        let (root, engine) = try await Self.builtRepo()
        let drill = root.appendingPathComponent("Sources/Lib/Drill.swift").path
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: drill)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: drill) }

        let output = try await engine.lookup(symbol: "Greeter", freshness: engine.ensureFresh())

        #expect(Self.accountingLine(in: output) == Self.prefix + "3, a text search of the Swift files git shows): 1 declares a conformer (above), 1 declares or extends it, 1 writes it only in comments or strings: Sources/Lib/Notes.swift; 1 could not be read: Sources/Lib/Drill.swift", "\(output)")
    }

    /// Under `--refs`, where the `not code` section lists every comments-or-strings file, that class gives its count alone.
    @Test
    func referencesListingEveryCommentFileGiveTheCountAlone() async throws {
        let (_, engine) = try await Self.builtRepo()

        let output = try await engine.lookup(symbol: "Greeter", freshness: engine.ensureFresh(), options: WhereOptions(includeReferences: true))

        #expect(Self.accountingLine(in: output) == Self.prefix + "4, a text search of the Swift files git shows): 1 declares a conformer (above), 1 declares or extends it, 1 uses it (used by, above), 1 writes it only in comments or strings (not code, below)", "\(output)")
        #expect(output.contains("Sources/Lib/Notes.swift"), "\(output)")
    }
}
