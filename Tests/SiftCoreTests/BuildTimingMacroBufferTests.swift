//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A macro expansion's generated buffer is never ranked as a file of the package, and its time is said on a line of its own, over a captured `--build-tests` build.
@Suite(.temporaryDirectories)
struct BuildTimingMacroBufferTests {
    /// The capture's two files, byte for byte, so its locations land on the lines they were measured on.
    private static var ledgerSource: String {
        """
        public struct Ledger {
            public var rates: [Double] = [1, 2, 3]
            public init() {}
            public func total() -> Double {
                rates.reduce(0, +)
            }
        }

        """
    }

    private static var testSource: String {
        """
        import Testing
        @testable import Widget

        @Test func totalAddsRates() {
            let ledger = Ledger()
            #expect(ledger.total() == 6)
            #expect(ledger.rates.count == 3)
        }

        """
    }

    private static func capture(relocatedTo root: URL?) throws -> [BuildTiming] {
        let capture = try TestSources.runOutput("swift-build-tests-debug-time-macros")
        return BuildTimingParser.timings(in: root.map { capture.replacingOccurrences(of: "/Users/dev/Widget", with: $0.path) } ?? capture)
    }

    /// The compiler prints a buffer as a bare `@__swiftmacro_….swift`, which read against the working directory is a file at the package's root when the build is analysed from there, as `sift build --analyse` is.
    @Test
    func aBufferIsNoFileOfAPackageRootedAtTheWorkingDirectory() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let analysis = try BuildTimingAnalysis(timings: Self.capture(relocatedTo: nil), packageRoot: root, treeRoot: root, top: 10)

        #expect(!analysis.files.contains { $0.path.contains("@__swiftmacro_") })
        #expect(!(analysis.bodies + analysis.expressions).contains { $0.path.contains("@__swiftmacro_") })
        #expect(analysis.bodyLines + analysis.expressionLines == 0)
        let rendered = BuildTimingRenderer(root: root).render(analysis, seconds: 1, logLines: 75, logURL: nil, top: 10, builtWithTests: true)
        #expect(rendered.contains("macro expansions: 25 timing lines name a generated @__swiftmacro_… buffer rather than a source file, 1.56 ms of function bodies, 7.27 ms of expressions"))
    }

    /// Analysed from anywhere else, the buffers are not dependencies or `.build/` products either, so the outside line no longer counts them.
    @Test
    func aBufferIsNotCountedOutsideThePackage() throws {
        let made = try TemporaryDirectory.make("build-timing-macro")
        let root = URL(fileURLWithPath: CanonicalPath.of(made.path))
        try TestSources.write(Self.ledgerSource, to: "Sources/Widget/Ledger.swift", in: root)
        try TestSources.write(Self.testSource, to: "Tests/WidgetTests/WidgetTests.swift", in: root)
        let analysis = try BuildTimingAnalysis(timings: Self.capture(relocatedTo: root), packageRoot: root, treeRoot: root, top: 10)

        #expect(analysis.files.map(\.path).sorted() == ["Sources/Widget/Ledger.swift", "Tests/WidgetTests/WidgetTests.swift"])
        let rendered = BuildTimingRenderer(root: root).render(analysis, seconds: 1, logLines: 75, logURL: nil, top: 10, builtWithTests: true)
        #expect(rendered.contains("outside the package's own sources (dependencies, .build/): 14 timing lines,"))
        #expect(rendered.contains("macro expansions: 25 timing lines name a generated @__swiftmacro_… buffer"))
    }
}
