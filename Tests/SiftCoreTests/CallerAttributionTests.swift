//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers caller attribution against a *really built* index store: which rows a call site produces, and at which line.
@Suite(.temporaryDirectories)
struct CallerAttributionTests {
    /// One call site is one row, at the line the call is actually written on — and it stays one after a rebuild that moved it.
    ///
    /// **This guards against a recurrence; it does not pin a fix.** The shape it covers — a caller listed twice, once at a line holding no call at all — is what a server running a stale binary can report, and it does not reproduce against this code.
    ///
    /// It is worth keeping anyway, because of what a wrong count costs. A caller *count* can be the deciding input in a design decision — one call site means narrow prior art, two mean an existing general mechanism to point at — and a wrong count does not look wrong: it reads as a fact and goes straight into a plan. So the property asserted is the count *and* the line, since a row at the wrong line is the same defect wearing a right-looking number, and it is asserted across a rebuild that moves the call, which is the shape a lingering occurrence from an earlier unit would take.
    @Test
    func oneCallSiteIsOneCallerRowAtTheLineTheCallIsWrittenOn() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(
            "// swift-tools-version: 6.0\nimport PackageDescription\n\nlet package = Package(name: \"Lib\", targets: [.target(name: \"Lib\")])\n",
            to: "Package.swift",
            in: root
        )
        /// The shape at risk: one guarded call, with same-shaped returns on the lines either side of it, and the declaration below its own call site.
        func source(shiftedBy padding: String) -> String {
            """
            public enum Verdict {
                case elapsed(Int)
                case measured(Int)
            }
            \(padding)
            public struct Producer {
                public init() {}

                public func headline(for value: Int, in mode: Int) -> Verdict {
                    guard mode > 0 else {
                        return .elapsed(value)
                    }
                    guard isWideScale(value) else {
                        return .elapsed(value)
                    }
                    return .measured(value)
                }

                private func isWideScale(_ value: Int) -> Bool {
                    value > 100
                }
            }
            """
        }
        try TestSources.write(source(shiftedBy: ""), to: "Sources/Lib/Producer.swift", in: root)
        try TestSources.commitAll(in: root, message: "producer")
        try TestSources.swiftBuild(packageAt: root)
        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()

        var freshness = try await engine.ensureFresh()
        let first = try await engine.lookup(symbol: "isWideScale", freshness: freshness)
        // Moving every declaration down two lines and rebuilding: the first build's unit recorded the call at its
        // old line, and a lingering occurrence would show up here as a second caller at a line holding no call.
        try TestSources.write(source(shiftedBy: "\n\n"), to: "Sources/Lib/Producer.swift", in: root)
        try TestSources.commitAll(in: root, message: "moved")
        try TestSources.swiftBuild(packageAt: root)
        try await engine.awaitSemanticStore()
        freshness = try await engine.ensureFresh()
        let moved = try await engine.lookup(symbol: "isWideScale", freshness: freshness)

        #expect(first.contains("semantic: fresh"))
        #expect(first.contains("callers of Lib.Producer.isWideScale(_:) (1):"))
        #expect(WhereStoreSiteTextTests.located(first).contains("Sources/Lib/Producer.swift:13  headline(for:in:)  | guard isWideScale(value) else {"))
        #expect(moved.contains("callers of Lib.Producer.isWideScale(_:) (1):"))
        #expect(WhereStoreSiteTextTests.located(moved).contains("Sources/Lib/Producer.swift:15  headline(for:in:)  | guard isWideScale(value) else {"))
        #expect(!WhereStoreSiteTextTests.located(moved).contains("Sources/Lib/Producer.swift:13"))
    }

    /// One function calling the subject twice is listed once per call site, each row naming it and carrying its line's text, while the block is short enough to read in place: above that it folds to one row carrying the count.
    @Test
    func aCallersOwnRepeatedCallSitesAreEachARowWithTheirText() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(
            "// swift-tools-version: 6.0\nimport PackageDescription\n\nlet package = Package(name: \"Lib\", targets: [.target(name: \"Lib\")])\n",
            to: "Package.swift",
            in: root
        )
        try TestSources.write(
            """
            public struct Producer {
                public init() {}

                public func headline(for value: Int, in mode: Int) -> Int {
                    if mode > 0 {
                        return isWideScale(value)
                    }
                    return isWideScale(value + 1)
                }

                private func isWideScale(_ value: Int) -> Int {
                    value
                }
            }
            """,
            to: "Sources/Lib/Producer.swift",
            in: root
        )
        try TestSources.commitAll(in: root, message: "producer")
        try TestSources.swiftBuild(packageAt: root)
        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()

        let freshness = try await engine.ensureFresh()
        let output = try await engine.lookup(symbol: "isWideScale", freshness: freshness)

        #expect(output.contains("callers of Lib.Producer.isWideScale(_:) (2):"))
        #expect(output.contains("  Sources/Lib/Producer.swift (2):\n    :6  headline(for:in:)  | return isWideScale(value)\n    :8  headline(for:in:)  | return isWideScale(value + 1)"))
        #expect(!output.contains("sites)"))
    }
}
