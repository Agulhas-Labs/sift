//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Pins the file accounting line's edges: what it says of the `not code` section under `--refs`, a class with no file, a conformer reached only through the inherited walk, and the byte bound judged before a file is read.
@Suite(.temporaryDirectories, .serialized)
struct WhereConformerFileAccountingLimitsTests {
    private static var manifest: String {
        """
        // swift-tools-version: 6.0
        import PackageDescription

        let package = Package(
            name: "Lib",
            targets: [.target(name: "Lib")]
        )
        """
    }

    /// A lowercase protocol with a conformer, written in three comment-or-string files, of which `not code` keeps only the backticked comment.
    private static func lowercase() async throws -> SharedBuiltFixture {
        try await SharedBuiltFixtures.process.fixture(for: Self.self, named: "conformer-file-accounting-lowercase") { root in
            try TestSources.write(manifest, to: "Package.swift", in: root)
            try TestSources.write("public protocol gadget {\n    func spin()\n}\n", to: "Sources/Lib/Gadget.swift", in: root)
            try TestSources.write("public struct Spinner: gadget {\n    public func spin() {}\n}\n", to: "Sources/Lib/Spinner.swift", in: root)
            try TestSources.write("// the gadget is here\nlet plain = 1\n", to: "Sources/Lib/PlainComment.swift", in: root)
            try TestSources.write("/// see `gadget`\nlet tick = 1\n", to: "Sources/Lib/TickComment.swift", in: root)
            try TestSources.write("let text = \"a gadget\"\n", to: "Sources/Lib/Str.swift", in: root)
            try TestSources.commitAll(in: root, message: "lowercase accounting")
            try await TestSources.swiftBuildSuspending(packageAt: root)
        }
    }

    /// A protocol, a refining protocol and a conformer to the refinement in a file of its own, a direct conformer, and no file writing the name in a comment or string.
    private static func inherited() async throws -> SharedBuiltFixture {
        try await SharedBuiltFixtures.process.fixture(for: Self.self, named: "conformer-file-accounting-inherited") { root in
            try TestSources.write(manifest, to: "Package.swift", in: root)
            try TestSources.write("public protocol Gizmo {\n    func spin()\n}\n", to: "Sources/Lib/Gizmo.swift", in: root)
            try TestSources.write("public protocol SubGizmo: Gizmo {}\n", to: "Sources/Lib/SubGizmo.swift", in: root)
            try TestSources.write("public struct Deep: SubGizmo {\n    public func spin() {}\n}\n", to: "Sources/Lib/Deep.swift", in: root)
            try TestSources.write("public struct Plain: Gizmo {\n    public func spin() {}\n}\n", to: "Sources/Lib/Plain.swift", in: root)
            try TestSources.commitAll(in: root, message: "inherited accounting")
            try await TestSources.swiftBuildSuspending(packageAt: root)
        }
    }

    private static func accountingLine(in output: String) -> String? {
        output.components(separatedBy: "\n").first { $0.hasPrefix("every Swift file that writes") }
    }

    /// A lowercase name's `not code` section lists only the backticked comment, so the other two files are named, not counted under it.
    @Test
    func aLowercaseProtocolNamesTheCommentFilesNotCodeLeavesOut() async throws {
        try await Self.lowercase().withEngine { engine in
            let output = try await engine.lookup(symbol: "gadget", freshness: engine.ensureFresh(), options: WhereOptions(includeReferences: true))

            #expect(Self.accountingLine(in: output)?.contains("3 write it only in comments or strings (1 under not code, below): Sources/Lib/PlainComment.swift, Sources/Lib/Str.swift") == true, "\(output)")
        }
    }

    /// With no file writing the name only in comments or strings the line has no such class, under `--refs` as well.
    @Test
    func aClassWithNoFileIsLeftOutUnderReferences() async throws {
        try await Self.inherited().withEngine { engine in
            let output = try await engine.lookup(symbol: "Gizmo", freshness: engine.ensureFresh(), options: WhereOptions(includeReferences: true))
            let line = Self.accountingLine(in: output)

            #expect(line != nil, "\(output)")
            #expect(line?.contains("comments or strings") == false, "\(output)")
        }
    }

    /// A conformer reached only through the inherited walk is counted under `declare a conformer`, though its file writes the name only inside a longer one.
    @Test
    func aConformerReachedOnlyByTheInheritedWalkIsCounted() async throws {
        try await Self.inherited().withEngine { engine in
            let output = try await engine.lookup(symbol: "Gizmo", freshness: engine.ensureFresh())

            #expect(Self.accountingLine(in: output) == "every Swift file that writes Gizmo is accounted for (4, a text search of the Swift files git shows): 3 declare a conformer (above), 1 declares or extends it", "\(output)")
        }
    }

    /// A file past the byte bound is never read: the scan stops on the file's size.
    @Test
    func aFilePastTheByteBoundIsNotRead() throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write("// Gizmo is a name written in a file of some length.\n", to: "Big.swift", in: root)
        let reads = ReadLog()
        let bounds = TextSearchFiles.Bounds(bytes: 10, read: { reads.record($0) })

        let past = TextSearchFiles.scan(name: "Gizmo", listing: ["Big.swift"], under: root, bounds: bounds)
        let within = TextSearchFiles.scan(name: "Gizmo", listing: ["Big.swift"], under: root, bounds: TextSearchFiles.Bounds(read: { reads.record($0) }))

        #expect(past == nil)
        #expect(within?.files.map(\.path) == ["Big.swift"])
        #expect(reads.paths.count == 1, "\(reads.paths)")
    }
}

private extension WhereConformerFileAccountingLimitsTests {
    /// The paths read, in order.
    final class ReadLog: @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [String] = []

        var paths: [String] {
            lock.withLock { seen }
        }

        func record(_ path: String) -> Data? {
            lock.withLock { seen.append(path) }
            return FileManager.default.contents(atPath: path)
        }
    }
}
