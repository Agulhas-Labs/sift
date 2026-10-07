//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers the semantic axis against a *really built* index store: callers, overrides, store conformers, and per-symbol refusal-on-stale.
@Suite(.temporaryDirectories, .serialized)
struct SemanticWhereTests {
    /// A committed repo that is also a buildable SwiftPM package, built with an index store — at `.build/out` under Swift Build, at `.build/index/store` under the native build system.
    static func makeBuiltRepo() throws -> URL {
        let root = try TestSources.makeTempRepo()
        try writeBuiltRepo(in: root)
        try TestSources.swiftBuild(packageAt: root)
        return root
    }

    /// The built repo every test that only reads it shares, built once for the suite.
    private static func builtFixture() async throws -> SharedBuiltFixture {
        try await SharedBuiltFixtures.process.fixture(for: Self.self, named: "semantic-where") { root in
            try writeBuiltRepo(in: root)
            try await TestSources.swiftBuildSuspending(packageAt: root)
        }
    }

    /// Writes and commits the buildable package into `root`, without building it.
    private static func writeBuiltRepo(in root: URL) throws {
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
        try TestSources.write(
            """
            open class Base {
                public init() {}
                open func greet() {}
            }

            public class Child: Base {
                override public func greet() {}
            }
            """,
            to: "Sources/Lib/Base.swift",
            in: root
        )
        try TestSources.write(
            """
            public func callGreet() {
                Base().greet()
                helper()
            }

            func helper() {}
            """,
            to: "Sources/Lib/Caller.swift",
            in: root
        )
        try TestSources.commitAll(in: root, message: "buildable fixture")
    }

    @Test
    func callersOverridesAndStoreConformersResolve() async throws {
        try await Self.builtFixture().withEngine { engine in
            let freshness = try await engine.ensureFresh()

            let helper = try await engine.lookup(symbol: "helper()", freshness: freshness)
            let greet = try await engine.lookup(symbol: "greet()", freshness: freshness)
            let base = try await engine.lookup(symbol: "Base", freshness: freshness)

            #expect(helper.contains("mode: syntactic + semantic (index store via .build)"))
            #expect(helper.contains("semantic: fresh"))
            #expect(helper.contains("callers of Lib.helper() (1):"))
            #expect(helper.contains("callGreet"))
            #expect(greet.contains("overrides of Lib.Base.greet()"))
            #expect(greet.contains("callers of Lib.Base.greet() (1):"))
            #expect(base.contains("conformers of Base (1, direct subclasses from the store):"))
            #expect(base.contains("Child"))
            // The store answered, so the notice about what an unanswered query cannot see has nothing to say and
            // must not be printed — a standing caveat over an answer it does not apply to is how caveats stop
            // being read at all.
            #expect(!helper.contains("callers/overrides: NOT ANSWERED"))
        }
    }

    @Test
    func editedFileRefusesPerSymbolWhileOthersStillAnswer() async throws {
        let root = try Self.makeBuiltRepo()
        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()
        _ = try await engine.ensureFresh()
        // Edit Base.swift after the build: its symbols must refuse; Caller.swift's stay answerable.
        try TestSources.write(
            """
            open class Base {
                public init() {}
                open func greet() {}
                public func added() {}
            }

            public class Child: Base {
                override public func greet() {}
            }
            """,
            to: "Sources/Lib/Base.swift",
            in: root
        )
        let freshness = try await engine.ensureFresh()

        let greet = try await engine.lookup(symbol: "greet()", freshness: freshness)
        let helper = try await engine.lookup(symbol: "helper()", freshness: freshness)

        #expect(greet.contains("REFUSED"))
        #expect(greet.contains("rebuild with `sift run -- swift build`, then retry"))
        #expect(greet.contains("semantic: stale (1 file changed since last build)"))
        #expect(helper.contains("semantic: fresh"))
        #expect(helper.contains("callers of Lib.helper() (1):"))
    }

    /// The complaint at the point it actually bites — a refusal the reader cannot act on.
    ///
    /// A file edited since the build refuses, and "build the project" costs minutes in a monorepo. The refusal stays, because it must; it is simply not the whole answer.
    @Test
    func aRefusedSymbolStillGetsNameMatchedCallSites() async throws {
        let root = try Self.makeBuiltRepo()
        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()
        _ = try await engine.ensureFresh()
        try TestSources.write(
            "public func callGreet() {\n    Base().greet()\n    helper()\n}\n\nfunc helper() {}\n\nfunc alsoCalls() { helper() }\n",
            to: "Sources/Lib/Caller.swift",
            in: root
        )

        let freshness = try await engine.ensureFresh()
        let output = try await engine.lookup(symbol: "helper()", freshness: freshness)

        #expect(output.contains("REFUSED"))
        #expect(output.contains("semantic: stale (1 file changed since last build)"))
        #expect(output.contains("syntactic call sites"))
        #expect(output.contains("in Lib.callGreet()") || output.contains("in callGreet()"))
    }

    /// A symbol the store *could* answer for keeps its resolved answer and pays nothing for the fallback.
    @Test
    func anAnsweredSymbolGetsNoSyntacticFallback() async throws {
        try await Self.builtFixture().withEngine { engine in
            let freshness = try await engine.ensureFresh()
            let output = try await engine.lookup(symbol: "helper()", freshness: freshness)

            #expect(output.contains("callers of Lib.helper() (1):"))
            #expect(!output.contains("syntactic call sites"))
        }
    }

    @Test
    func buildingAgainHealsTheRefusal() async throws {
        let root = try Self.makeBuiltRepo()
        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()
        _ = try await engine.ensureFresh()
        try TestSources.write(
            "open class Base {\n    public init() {}\n    open func greet() {}\n    public func added() {}\n}\n\npublic class Child: Base {\n    override public func greet() {}\n}\n",
            to: "Sources/Lib/Base.swift",
            in: root
        )
        var freshness = try await engine.ensureFresh()
        let refused = try await engine.lookup(symbol: "greet()", freshness: freshness)
        try TestSources.swiftBuild(packageAt: root)
        try await engine.awaitSemanticStore()

        freshness = try await engine.ensureFresh()
        let healed = try await engine.lookup(symbol: "greet()", freshness: freshness)

        #expect(refused.contains("REFUSED"))
        #expect(healed.contains("semantic: fresh"))
        #expect(healed.contains("overrides of Lib.Base.greet()"))
    }

    @Test
    func declarationsWithoutCallersCollapseToASummaryLine() async throws {
        try await Self.builtFixture().withEngine { engine in
            let freshness = try await engine.ensureFresh()

            // callGreet() is public and called by nothing — the empty case, which must not cost a three-line block.
            let output = try await engine.lookup(symbol: "callGreet()", freshness: freshness)

            #expect(output.contains("no callers of Lib.callGreet() recorded in the store"))
            #expect(!output.contains("callers of Lib.callGreet() (0):"))
            #expect(!output.contains("none recorded"))
        }
    }

    @Test
    func refusalsCollapsePerFileNotPerDeclaration() async throws {
        let root = try Self.makeBuiltRepo()
        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()
        _ = try await engine.ensureFresh()
        // greet() resolves to both Base.greet and Child.greet, which share Base.swift: one edit, one fact, one line.
        try TestSources.write(
            """
            open class Base {
                public init() {}
                open func greet() {}
                public func added() {}
            }

            public class Child: Base {
                override public func greet() {}
            }
            """,
            to: "Sources/Lib/Base.swift",
            in: root
        )
        let freshness = try await engine.ensureFresh()

        let greet = try await engine.lookup(symbol: "greet()", freshness: freshness)

        #expect(greet.contains("declarations (2):"))
        #expect(greet.components(separatedBy: "REFUSED").count - 1 == 1)
        #expect(greet.contains("semantic REFUSED — changed since the last build"))
        #expect(!greet.contains("2 declarations:"))
        #expect(greet.contains("Lib.Base.greet()"))
        #expect(greet.contains("Lib.Child.greet()"))
    }

    @Test
    func refsListReferenceSitesThatCallersCannotSee() async throws {
        try await Self.builtFixture().withEngine { engine in
            let freshness = try await engine.ensureFresh()

            let plain = try await engine.lookup(symbol: "Base", freshness: freshness)
            let swept = try await engine.lookup(symbol: "Base", freshness: freshness, options: WhereOptions(includeReferences: true))

            // A type has no callers at all, so the sweep view is the only way to reach its use sites.
            #expect(!plain.contains("references to"))
            #expect(swept.contains("references to Lib.Base (2 in 2 files):"))
            // Grouped by file with line numbers, so a sweep works file by file instead of running past the list cap.
            #expect(swept.contains("Sources/Lib/Caller.swift (1):\n    :2  | Base().greet()"))
            #expect(swept.contains("Sources/Lib/Base.swift (1):\n    :6  | public class Child: Base {"))
        }
    }

    @Test
    func anExtensionNeverRefusesSemanticsItCanNeverHave() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(
            "// swift-tools-version: 6.0\nimport PackageDescription\n\nlet package = Package(name: \"Lib\", targets: [.target(name: \"Lib\")])\n",
            to: "Package.swift",
            in: root
        )
        try TestSources.write(
            """
            open class Base {
                public init() {}
            }

            extension Base {
                public func extra() {}
            }
            """,
            to: "Sources/Lib/Base.swift",
            in: root
        )
        try TestSources.commitAll(in: root, message: "type with an extension")
        try TestSources.swiftBuild(packageAt: root)
        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()
        let freshness = try await engine.ensureFresh()

        let output = try await engine.lookup(symbol: "Base", freshness: freshness)

        // An extension carries no USR of its own, so refusing it would tell the reader to run a build that could never clear it.
        #expect(output.contains("extensions of Base"))
        #expect(!output.contains("REFUSED"))
        #expect(output.contains("semantic: fresh"))
    }

    @Test
    func headerNeverReportsStalenessForAnUnresolvedDeclaration() async throws {
        try await Self.builtFixture().withEngine { engine in
            let freshness = try await engine.ensureFresh()

            let output = try await engine.lookup(symbol: "Base", freshness: freshness)

            // "N files changed since last build" is a claim about the working tree; an unresolved USR is no evidence for it.
            if output.contains("REFUSED") {
                #expect(output.contains("not found in the store"))
                #expect(!output.contains("changed since last build"))
            } else {
                #expect(output.contains("semantic: fresh"))
            }
        }
    }

    @Test
    func referenceCountsReconcileWithTheLinesListed() async throws {
        let root = try Self.makeBuiltRepo()
        try TestSources.write(
            """
            public func callGreet() {
                Base().greet()
                helper()
            }

            func helper() {}

            public func twiceOnOneLine() {
                _ = (Base(), Base())
            }
            """,
            to: "Sources/Lib/Caller.swift",
            in: root
        )
        try TestSources.commitAll(in: root, message: "two references on one line")
        try TestSources.swiftBuild(packageAt: root)
        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()
        let freshness = try await engine.ensureFresh()

        let swept = try await engine.lookup(symbol: "Base", freshness: freshness, options: WhereOptions(includeReferences: true))

        // The header counts distinct lines, exactly what the per-file lines enumerate — a header promising more
        // sites than the listing accounts for reads as an unreachable reference during a sweep.
        // Required rather than subscripted: an answer with no references line is a failure of this test, and a
        // trap here would take every test still running in the process down with it.
        let header = try #require(swept.split(separator: "\n").first(where: { $0.hasPrefix("references to Lib.Base (") }), "\(swept)")
        let count = try #require(header.split(separator: "(").dropFirst().first?.split(separator: " ").first, "\(header)")
        let total = Int(count) ?? -1
        let listed = swept
            .split(separator: "\n")
            .filter { $0.hasPrefix("  Sources/") }
            .reduce(0) { $0 + ($1.split(separator: ":").last?.split(separator: ",").count ?? 0) }

        #expect(total == listed)
    }

    @Test
    func refsWithoutTheStoreSaySoRatherThanReturningNothing() async throws {
        try await Self.builtFixture().withEngine { engine in
            let freshness = try await engine.ensureFresh()

            let output = try await engine.lookup(
                symbol: "Base",
                freshness: freshness,
                options: WhereOptions(includeSemantic: false, includeReferences: true)
            )

            // Silently dropping the flag would let a sweep read a clean answer as "nothing to change".
            #expect(output.contains("references: UNAVAILABLE"))
            #expect(output.contains("grep instead"))
        }
    }

    @Test
    func emptyReferenceResultsAreSummarisedNotItemised() async throws {
        try await Self.builtFixture().withEngine { engine in
            let freshness = try await engine.ensureFresh()

            // callGreet() is referenced by nothing — the same emptiness rule the callers path follows.
            let output = try await engine.lookup(symbol: "callGreet()", freshness: freshness, options: WhereOptions(includeReferences: true))

            #expect(output.contains("no references to Lib.callGreet() recorded in the store"))
            #expect(!output.contains("references to Lib.callGreet() (0"))
        }
    }

    @Test
    func syntacticFlagNeverOpensTheStore() async throws {
        // A private, unbuilt package: this test is about never opening the store, so it must not share an engine that already did.
        let root = try TestSources.makeTempRepo()
        try Self.writeBuiltRepo(in: root)
        let engine = try SiftEngine(directory: root)
        let freshness = try await engine.ensureFresh()

        let output = try await engine.lookup(symbol: "helper()", freshness: freshness, options: WhereOptions(includeSemantic: false))

        #expect(output.contains("semantic: syntactic-only"))
        #expect(output.contains("semantic disabled (--syntactic)"))
        #expect(!output.contains("callers of"))
    }

    /// A store still warming has to read as a wait, not as the refusal standing next to it.
    ///
    /// The two are one line apart and mean opposite things: "build the project" says the data does not exist and asking again is pointless, while this says the data is being read right now and asking again is the entire remedy. A reader who confuses them either rebuilds for nothing or writes the store off as broken and goes back to grep — and a slow cold read of a large store makes the second all the more tempting.
    @Test
    func aWarmingStoreSaysToWaitRatherThanToBuild() {
        let note = SiftEngine.warmingNote(provenance: .derivedData, seconds: 7)

        #expect(note.contains("still warming"))
        #expect(note.contains("7s"))
        #expect(note.contains("Ask again in a moment"))
        // The distinction the whole note exists for.
        #expect(!note.contains("build the project"))
        #expect(note.contains("No build and no reindex will speed this up"))
    }

    /// A built fixture with a protocol requirement, a conforming witness, and references in a second file.
    private static func protocolFixture() async throws -> SharedBuiltFixture {
        try await SharedBuiltFixtures.process.fixture(for: Self.self, named: "semantic-where-protocol") { root in
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
            try TestSources.write(
                """
                public protocol Greeter {
                    func salute()
                }

                public struct Soldier: Greeter {
                    public init() {}
                    public func salute() {}
                }
                """,
                to: "Sources/Lib/Proto.swift",
                in: root
            )
            try TestSources.write(
                """
                public func drill(greeter: Greeter) {
                    greeter.salute()
                }
                """,
                to: "Sources/Lib/Drill.swift",
                in: root
            )
            try TestSources.commitAll(in: root, message: "protocol fixture")
            try await TestSources.swiftBuildSuspending(packageAt: root)
        }
    }

    @Test
    func protocolWitnessesAreHeadedImplementationsNotOverrides() async throws {
        try await Self.protocolFixture().withEngine { engine in
            let freshness = try await engine.ensureFresh()

            let output = try await engine.lookup(symbol: "salute()", freshness: freshness)

            // The store's overrideOf relation covers witnesses, but the word "overrides" on a protocol
            // requirement reads as classes-only and leaves the reader unsure witnesses are covered.
            #expect(output.contains("implementations of Lib.Greeter.salute() (1):"))
            #expect(!output.contains("overrides of Lib.Greeter.salute()"))
        }
    }

    @Test
    func refsFileListPagesOnTheOffsetCursor() async throws {
        try await Self.protocolFixture().withEngine { engine in
            let freshness = try await engine.ensureFresh()

            let firstPage = try await engine.lookup(
                symbol: "Greeter",
                freshness: freshness,
                options: WhereOptions(includeReferences: true)
            )
            let secondPage = try await engine.lookup(
                symbol: "Greeter",
                freshness: freshness,
                options: WhereOptions(includeReferences: true, offset: 1)
            )

            // Greeter is referenced in both files (Soldier's conformance clause, drill's parameter);
            // the sorted file list puts Drill.swift first, so offset 1 skips it and serves Proto.swift.
            #expect(firstPage.contains("Sources/Lib/Drill.swift ("))
            #expect(secondPage.contains("(…1 file skipped)"))
            #expect(secondPage.contains("Sources/Lib/Proto.swift ("))
            #expect(!secondPage.contains("Sources/Lib/Drill.swift ("))
        }
    }
}

/// Kept apart from the suite's own body — a struct already at the type-body-length ceiling gains no more members.
extension SemanticWhereTests {
    /// Three files refused for one reason are one fact, stated once — the header already counts the stale files, so naming each one again below is the notice this issue exists to remove.
    @Test
    func refusalsAcrossSeveralFilesCollapseToOneLine() async throws {
        let root = try Self.makeBuiltRepo()
        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()
        _ = try await engine.ensureFresh()
        // Three overloads of the same name, one per file, so one query resolves all three declarations.
        try TestSources.write("public func stale(_ value: Int) {}", to: "Sources/Lib/Alder.swift", in: root)
        try TestSources.write("public func stale(_ value: String) {}", to: "Sources/Lib/Birch.swift", in: root)
        try TestSources.write("public func stale(_ value: Double) {}", to: "Sources/Lib/Cedar.swift", in: root)
        let freshness = try await engine.ensureFresh()

        let stale = try await engine.lookup(symbol: "stale", freshness: freshness)

        #expect(stale.components(separatedBy: "REFUSED").count - 1 == 1)
        #expect(stale.contains("semantic REFUSED for 3 declarations: their files were changed since the last build; rebuild with `sift run -- swift build`, then retry"))
        // The declarations section above still names every file — only the refusal notice itself drops the per-file breakdown.
        #expect(!stale.contains("REFUSED —"))
    }
}
