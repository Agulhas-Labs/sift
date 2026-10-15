//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Pins a `where --refs` row naming the declaration the reference sits inside, leaving it out where the row's text is that declaration's own line, and keeping the bare row where the store records none.
@Suite(.temporaryDirectories, .serialized)
struct RefsRowEnclosingTests {
    private static func fixture() async throws -> SharedBuiltFixture {
        try await SharedBuiltFixtures.process.fixture(for: Self.self, named: "refs-row-enclosing") { root in
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
            try TestSources.write("public struct Gizmo: Sendable {\n    public init() {}\n}\n", to: "Sources/Lib/Gizmo.swift", in: root)
            try TestSources.write("public func build() -> Int {\n    let made = Gizmo()\n    _ = made\n    return 1\n}\n", to: "Sources/Lib/Build.swift", in: root)
            try TestSources.write("public typealias Alias = Gizmo\n", to: "Sources/Lib/Scope.swift", in: root)
            try TestSources.write("public func make(from seed: Gizmo) -> Int {\n    1\n}\n\nstruct Holder {\n    var part: Gizmo\n}\n", to: "Sources/Lib/Make.swift", in: root)
            try TestSources.commitAll(in: root, message: "refs row enclosing fixture")
            try await TestSources.swiftBuildSuspending(packageAt: root)
        }
    }

    /// The rows listed under one file's heading in a `--refs` answer.
    private static func rows(of file: String, in output: String) -> [String] {
        let lines = output.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.hasPrefix("  \(file) (") }) else { return [] }
        return Array(lines[(start + 1)...].prefix { $0.hasPrefix("    :") })
    }

    /// A reference inside a function names that function.
    @Test
    func aRowInsideAFunctionNamesIt() async throws {
        try await Self.fixture().withEngine { engine in
            let output = try await engine.lookup(symbol: "Gizmo", freshness: engine.ensureFresh(), options: WhereOptions(includeReferences: true))

            #expect(Self.rows(of: "Sources/Lib/Build.swift", in: output) == ["    :2  build()  | let made = Gizmo()"], "\(output)")
        }
    }

    /// A reference on the line declaring the function or property around it leaves the name out, since the row's text already shows it.
    @Test
    func aRowOnItsDeclarationsOwnLineLeavesTheNameOut() async throws {
        try await Self.fixture().withEngine { engine in
            let output = try await engine.lookup(symbol: "Gizmo", freshness: engine.ensureFresh(), options: WhereOptions(includeReferences: true))

            #expect(Self.rows(of: "Sources/Lib/Make.swift", in: output) == ["    :1  | public func make(from seed: Gizmo) -> Int {", "    :6  | var part: Gizmo"], "\(output)")
        }
    }

    /// A reference the store records inside no declaration keeps the bare row.
    @Test
    func aRowAtFileScopeKeepsTheBareForm() async throws {
        try await Self.fixture().withEngine { engine in
            let output = try await engine.lookup(symbol: "Gizmo", freshness: engine.ensureFresh(), options: WhereOptions(includeReferences: true))
            let rows = Self.rows(of: "Sources/Lib/Scope.swift", in: output)

            #expect(!rows.isEmpty, "\(output)")
            #expect(rows.allSatisfy { !$0.contains("(top level)") }, "\(output)")
        }
    }
}
