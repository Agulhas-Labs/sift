//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// An enum case is named, never read, and called only where a payload is built — so `where` answers for one with its uses from the index store, and an empty answer names what it looked for, where before it printed the declaration and nothing else.
@Suite(.temporaryDirectories)
struct SemanticEnumCaseUseTests {
    /// The declaring file, with `value`'s declaration as given — the one line a range can change without moving any other.
    static func mode(value: String = "case value(Int)") -> String {
        """
        public enum Mode: Equatable {
            case fast
            case slow
            \(value)
            case pair(left: Int, right: Int)
            case spare

            public static var preferred: Mode { .fast }

            public var quick: Bool {
                if case .fast = self { return true }
                return false
            }
        }
        """
    }

    /// Two modules of one package, and every shape a case is used in: bare and qualified, in an expression, a `switch` pattern, an `if case` and a comparison, built with a payload and matched with one, unapplied, and from the other module.
    static func writePackage(in root: URL) throws {
        try TestSources.write(
            """
            // swift-tools-version: 6.0
            import PackageDescription

            let package = Package(
                name: "Gizmo",
                targets: [
                    .target(name: "GizmoCore"),
                    .target(name: "GizmoApp", dependencies: ["GizmoCore"]),
                ]
            )
            """,
            to: "Package.swift",
            in: root
        )
        try TestSources.write(mode(), to: "Sources/GizmoCore/Mode.swift", in: root)
        try TestSources.write(
            """
            func pick(_ mode: Mode) -> Int {
                switch mode {
                case .fast: return 1
                case Mode.slow: return 2
                case .value(let x): return x
                case let .pair(left, _): return left
                default: return 0
                }
            }

            func make() -> [Mode] {
                [.fast, Mode.slow, .value(3), Mode.value(4), .pair(left: 1, right: 2)]
            }

            let maker = Mode.value
            """,
            to: "Sources/GizmoCore/Picker.swift",
            in: root
        )
        try TestSources.write(
            """
            import GizmoCore

            public func run(_ mode: Mode) -> Int {
                if case .value(let n) = mode { return n }
                return mode == .fast ? 1 : 0
            }
            """,
            to: "Sources/GizmoApp/Use.swift",
            in: root
        )
    }

    static func makeBuiltRepo() throws -> URL {
        let root = try TestSources.makeTempRepo()
        try writePackage(in: root)
        try TestSources.commitAll(in: root, message: "buildable fixture")
        try TestSources.swiftBuild(packageAt: root)
        return root
    }

    @Test
    func aCaseWithoutAPayloadListsItsUsesFromExpressionsAndPatternsInEveryFileAndModule() async throws {
        let engine = try SiftEngine(directory: Self.makeBuiltRepo())
        try await engine.awaitSemanticStore()
        let freshness = try await engine.ensureFresh()
        let fast = try await engine.lookup(symbol: "Mode.fast", freshness: freshness)
        let slow = try await engine.lookup(symbol: "Mode.slow", freshness: freshness)

        #expect(fast.contains("semantic: fresh"))
        #expect(fast.contains("uses of GizmoCore.Mode.fast (5):"))
        #expect(fast.contains("    :8  getter:preferred  | public static var preferred: Mode { .fast }"))
        #expect(fast.contains("    :11  getter:quick  | if case .fast = self { return true }"))
        #expect(fast.contains("    :3  pick(_:)  | case .fast: return 1"))
        #expect(fast.contains("    :12  make()  | [.fast, Mode.slow, .value(3), Mode.value(4), .pair(left: 1, right: 2)]"))
        #expect(fast.contains("    :5  run(_:)  | return mode == .fast ? 1 : 0"))
        #expect(slow.contains("uses of GizmoCore.Mode.slow (2):"))
        #expect(slow.contains("    :4  pick(_:)  | case Mode.slow: return 2"))
        #expect(slow.contains("    :12  make()  | [.fast, Mode.slow, .value(3), Mode.value(4), .pair(left: 1, right: 2)]"))
        for output in [fast, slow] {
            #expect(!output.contains("callers"))
            #expect(!output.contains(" — read"))
            #expect(!output.contains(" — write"))
        }
    }

    /// The store names a case with associated values as it names a function, so `value(_:)` resolves where a bare `value` was refused for want of a build no build could supply.
    ///
    /// Two uses on one line — `.value(3), Mode.value(4)` — are one row, never "×2 units".
    @Test
    func aCaseWithAPayloadResolvesByItsLabeledNameAndListsWhatBuildsAndMatchesIt() async throws {
        let engine = try SiftEngine(directory: Self.makeBuiltRepo())
        try await engine.awaitSemanticStore()
        let freshness = try await engine.ensureFresh()
        let bare = try await engine.lookup(symbol: "Mode.value", freshness: freshness)
        let labeled = try await engine.lookup(symbol: "Mode.value(_:)", freshness: freshness)
        let pair = try await engine.lookup(symbol: "Mode.pair(left:right:)", freshness: freshness)

        for output in [bare, labeled] {
            #expect(!output.contains("not found in the store"))
            #expect(!output.contains("REFUSED"))
            #expect(output.contains("uses of GizmoCore.Mode.value(_:) (4):"))
            #expect(output.contains("    :5  pick(_:)  | case .value(let x): return x"))
            #expect(output.contains("    :12  make()  | [.fast, Mode.slow, .value(3), Mode.value(4), .pair(left: 1, right: 2)]"))
            #expect(output.contains("    :15  maker  | let maker = Mode.value"))
            #expect(output.contains("    :4  run(_:)  | if case .value(let n) = mode { return n }"))
            #expect(!output.contains("units"))
        }

        #expect(pair.contains("uses of GizmoCore.Mode.pair(left:right:) (2):"))
        #expect(pair.contains("    :6  pick(_:)  | case let .pair(left, _): return left"))
        #expect(pair.contains("    :12  make()  | [.fast, Mode.slow, .value(3), Mode.value(4), .pair(left: 1, right: 2)]"))
    }

    /// The empty case says what was looked for: "no callers" of a case is true of almost every case there is, and reads as dead code.
    @Test
    func aCaseNothingUsesSaysNoUsesWereRecorded() async throws {
        let engine = try SiftEngine(directory: Self.makeBuiltRepo())
        try await engine.awaitSemanticStore()
        let freshness = try await engine.ensureFresh()
        let output = try await engine.lookup(symbol: "Mode.spare", freshness: freshness)

        #expect(output.contains("no uses of GizmoCore.Mode.spare recorded in the store"))
        #expect(!output.contains("callers"))
        #expect(!output.contains("reads or writes"))
    }

    /// A use of an enum case is neither a read nor a write, so its row carries no access mark — never the "write" a line with neither would otherwise fall through to.
    @Test
    func aCasesUseCarriesNoAccessMark() {
        let use = SemanticStore.Use(
            hit: SemanticStore.Hit(name: "pick(_:)", path: "/repo/Sources/GizmoCore/Picker.swift", line: 3),
            reads: false,
            writes: false
        )

        #expect(WhereRenderer.collapsedUses([use]).map(\.access) == [nil])
    }

    /// `sift diff` resolves a changed case's uses through the same store query, so a case the store records as used is listed, where before a changed case was left out of the section altogether.
    @Test
    func aChangedCasesUsesInADiffAreResolvedFromTheStore() async throws {
        let root = try TestSources.makeTempRepo()
        try Self.writePackage(in: root)
        try TestSources.commitAll(in: root, message: "before")
        try TestSources.write(Self.mode(value: "case value(Int = 0)"), to: "Sources/GizmoCore/Mode.swift", in: root)
        try TestSources.commitAll(in: root, message: "default")
        try TestSources.swiftBuild(packageAt: root)

        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()
        let freshness = try await engine.ensureFresh()
        let range = try DiffRange.resolve("HEAD", git: GitContext(repoRoot: root))
        let output = try await engine.diff(options: DiffOptions(range: range, member: nil, offset: 0), freshness: freshness)

        #expect(output.contains("~ Mode.value(_:) — resolved by the index store: 4 uses"))
        #expect(output.contains("      maker — Sources/GizmoCore/Picker.swift:15"))
        #expect(output.contains("      run(_:) — Sources/GizmoApp/Use.swift:4"))
    }
}
