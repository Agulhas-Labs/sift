//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A type's own declaration leads the declarations list above its extensions, whatever its file sorts as, and the list carries every row its count states, whether the store is fresh, stale, or holds no unit for the type's own file.
@Suite(.serialized, .temporaryDirectories)
struct WhereCountedRowsTests {
    static var package: String {
        """
        // swift-tools-version:5.9
        import PackageDescription

        let package = Package(name: "Lib", targets: [.target(name: "Lib")])
        """
    }

    static var ownDeclaration: String {
        """
        public struct Swatch {
            public init() {}
        }
        """
    }

    /// An extension of the type adding one static member of the given name, written to a file of its own by the caller.
    static func extensionSource(_ member: String) -> String {
        """
        extension Swatch {
            public static var \(member): Int { 1 }
        }
        """
    }

    /// Under a fresh store, the struct written in a file that sorts after both extensions' files is the first row, and the list holds the three rows it counts.
    @Test
    func theOwnDeclarationLeadsUnderAFreshStore() async throws {
        let root = try await Self.builtPackage()
        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()
        let answer = try await engine.lookup(symbol: "Swatch", freshness: engine.ensureFresh())

        #expect(answer.contains("semantic: fresh"), "\(answer)")
        Self.expectOwnDeclarationFirst(in: answer, stated: 3, ownPath: "Sources/Lib/Swatch.swift")
    }

    /// With the struct moved after the build into a new file the store holds no unit for, and an extension's file edited, the store is stale and cannot resolve the struct: it is still listed first, and every counted row is listed.
    @Test
    func theOwnDeclarationLeadsWhenTheStoreDoesNotHoldIt() async throws {
        let root = try await Self.builtPackage()
        try FileManager.default.removeItem(at: root.appendingPathComponent("Sources/Lib/Swatch.swift"))
        try TestSources.write(Self.ownDeclaration, to: "Sources/Lib/Zinc.swift", in: root)
        try TestSources.write(Self.extensionSource("amber") + "\n// edited after the build\n", to: "Sources/Lib/Amber.swift", in: root)
        try TestSources.write(Self.extensionSource("cobalt"), to: "Sources/Lib/Cobalt.swift", in: root)
        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()
        let answer = try await engine.lookup(symbol: "Swatch", freshness: engine.ensureFresh())

        #expect(answer.contains("semantic: stale"), "\(answer)")
        Self.expectOwnDeclarationFirst(in: answer, stated: 4, ownPath: "Sources/Lib/Zinc.swift")
    }

    /// With more extension files sorting before the struct's file than the list's cap, the struct is still the first row, so the cap cannot cut it off.
    @Test
    func theOwnDeclarationLeadsAheadOfTheListCap() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(Self.package, to: "Package.swift", in: root)
        for index in 0 ..< 45 {
            try TestSources.write(Self.extensionSource("shade\(index)"), to: "Sources/Lib/Ext\(String(format: "%02d", index)).swift", in: root)
        }
        try TestSources.write(Self.ownDeclaration, to: "Sources/Lib/Swatch.swift", in: root)
        try TestSources.commitAll(in: root, message: "seed")
        let engine = try SiftEngine(directory: root)
        let answer = try await engine.lookup(symbol: "Swatch", freshness: engine.ensureFresh())

        let listed = Self.declarationRows(in: answer)
        #expect(listed.stated == 46, "\(answer)")
        #expect(listed.rows.count == 40, "\(answer)")
        #expect(answer.contains("truncated: 6 more declarations"), "\(answer)")
        let first = listed.rows.first ?? ""
        #expect(first.contains(" — struct — ") && first.contains("Sources/Lib/Swatch.swift"), "\(answer)")
    }

    /// The rows under the answer's declarations count line: each indented line up to the first that is not, less the cap's and the compact list's notes.
    static func declarationRows(in answer: String) -> (stated: Int?, rows: [String]) {
        let lines = answer.components(separatedBy: "\n")
        guard let head = lines.firstIndex(where: { $0.hasPrefix("declarations (") }) else { return (nil, []) }
        let stated = Int(lines[head].dropFirst("declarations (".count).prefix { $0.isNumber })
        let rows = lines[(head + 1)...].prefix { $0.hasPrefix("  ") }
            .filter { !$0.hasPrefix("  truncated:") && !$0.hasPrefix("  signatures:") }
        return (stated, Array(rows))
    }

    /// Checks the count line states `stated`, exactly that many rows follow it, and the first is the struct's own row at `ownPath`.
    static func expectOwnDeclarationFirst(in answer: String, stated: Int, ownPath: String, sourceLocation: SourceLocation = #_sourceLocation) {
        let listed = declarationRows(in: answer)
        #expect(listed.stated == stated, "\(answer)", sourceLocation: sourceLocation)
        #expect(listed.rows.count == listed.stated, "\(answer)", sourceLocation: sourceLocation)
        let first = listed.rows.first ?? ""
        #expect(first.contains(" — struct — ") && first.contains(ownPath), "\(answer)", sourceLocation: sourceLocation)
        #expect(listed.rows.dropFirst().allSatisfy { $0.contains(" — extension — ") }, "\(answer)", sourceLocation: sourceLocation)
    }

    private static func builtPackage() async throws -> URL {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(package, to: "Package.swift", in: root)
        try TestSources.write(extensionSource("amber"), to: "Sources/Lib/Amber.swift", in: root)
        try TestSources.write(extensionSource("blush"), to: "Sources/Lib/Blush.swift", in: root)
        try TestSources.write(ownDeclaration, to: "Sources/Lib/Swatch.swift", in: root)
        try TestSources.write("public let picked = Swatch.amber + Swatch.blush\n", to: "Sources/Lib/Use.swift", in: root)
        try TestSources.commitAll(in: root, message: "seed")
        try await TestSources.swiftBuildSuspending(packageAt: root)
        return root
    }
}
