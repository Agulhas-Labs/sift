//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers the runner spellings `affected` prints for every test shape it can name, measured against `swift test list`, `swift test --filter` and `xcodebuild -only-testing:` on macOS, where every wrong spelling ran nothing and exited 0.
@Suite(.temporaryDirectories)
struct AffectedFilterSpellingTests {
    /// Every shape, with `listed` exactly as `swift test list` printed it.
    static let shapes: [Shape] = [
        Shape(
            symbol: TestSymbol(target: "LibTests", suite: "GadgetTests", function: "testOne", style: .xcTest),
            listed: "LibTests.GadgetTests/testOne",
            filter: #"LibTests\.GadgetTests/testOne"#,
            onlyTesting: "-only-testing:LibTests/GadgetTests/testOne"
        ),
        Shape(
            symbol: TestSymbol(target: "LibTests", suite: "GizmoTests", function: "polishes()", style: .swiftTesting),
            listed: "LibTests.GizmoTests/polishes()",
            filter: #"LibTests\.GizmoTests/polishes\(\)"#,
            onlyTesting: "-only-testing:LibTests/GizmoTests/polishes()"
        ),
        Shape(
            symbol: TestSymbol(target: "LibTests", suite: "GizmoTests", function: "scales(by:)", style: .swiftTesting),
            listed: "LibTests.GizmoTests/scales(by:)",
            filter: #"LibTests\.GizmoTests/scales\(by:\)"#,
            onlyTesting: "-only-testing:LibTests/GizmoTests/scales(by:)"
        ),
        Shape(
            symbol: TestSymbol(target: "LibTests", suite: "Outer.Inner", function: "deep()", style: .swiftTesting),
            listed: "LibTests.Outer/Inner/deep()",
            filter: #"LibTests\.Outer/Inner/deep\(\)"#,
            onlyTesting: "-only-testing:LibTests/Outer/Inner/deep()"
        ),
        Shape(
            symbol: TestSymbol(target: "LibTests", suite: "Outer.Inner", function: nil, style: .swiftTesting),
            listed: "LibTests.Outer/Inner",
            filter: #"LibTests\.Outer/Inner"#,
            onlyTesting: "-only-testing:LibTests/Outer/Inner"
        ),
        Shape(
            symbol: TestSymbol(target: "LibTests", suite: nil, function: "shines()", style: .swiftTesting),
            listed: "LibTests.shines()",
            filter: #"LibTests\.shines\(\)"#,
            onlyTesting: "-only-testing:LibTests/shines()"
        ),
        Shape(
            symbol: TestSymbol(target: "LibTests", suite: nil, function: "echoes(text:)", style: .swiftTesting),
            listed: "LibTests.echoes(text:)",
            filter: #"LibTests\.echoes\(text:\)"#,
            onlyTesting: "-only-testing:LibTests/echoes(text:)"
        ),
    ]

    /// Each shape's three spellings: the id `swift test list` prints, the filter that selects it, and the `-only-testing:` argument `xcodebuild` ran it by — a file-scope test dotted in the filter, a nested suite slashed in both.
    @Test(arguments: shapes)
    func eachShapeIsSpeltAsTheRunnersSelectIt(_ shape: Shape) {
        #expect(shape.symbol.described == shape.listed)
        #expect(shape.symbol.swiftTestFilter == shape.filter)
        #expect(shape.symbol.onlyTestingArgument == shape.onlyTesting)
    }

    /// The test file of the built fixture: one test of every shape, each reaching the changed `Widget`.
    private static var fixtureTests: String {
        """
        import Testing
        import XCTest
        @testable import Lib

        final class GadgetTests: XCTestCase {
            func testOne() { _ = Widget() }
        }

        struct GizmoTests {
            @Test func polishes() { _ = Widget() }
            @Test(arguments: [1, 2]) func scales(by factor: Int) { _ = Widget(); #expect(factor > 0) }
            @Test("A display name") func named() { _ = Widget() }
        }

        extension GizmoTests {
            @Test func extended() { _ = Widget() }
        }

        enum Outer {
            struct Inner {
                @Test func deep() { _ = Widget() }
            }
        }

        extension Outer.Inner {
            @Test func deeper() { _ = Widget() }
        }

        @Test func shines() { _ = Widget() }
        @Test(arguments: ["x"]) func echoes(text: String) { _ = Widget(); #expect(!text.isEmpty) }
        @Test("A display name at file scope") func titled() { _ = Widget() }
        """
    }

    /// Every `--filter` an answer's `swift test` line carries, in order.
    private static func filters(in output: String) -> [String] {
        guard let line = output.split(separator: "\n").first(where: { $0.hasPrefix("  swift test --filter") }) else { return [] }
        return line.matches(of: /--filter '([^']*)'/).map { String($0.output.1) }
    }

    /// Each filter the answer prints, run on its own against the built package, runs exactly the one test it names: none of them is the silent `No matching test cases were run` that exits 0.
    @Test
    func everyPrintedFilterRunsItsTestWhenPastedIntoSwiftTest() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(
            """
            // swift-tools-version: 6.0
            import PackageDescription

            let package = Package(
                name: "Lib",
                targets: [.target(name: "Lib"), .testTarget(name: "LibTests", dependencies: ["Lib"])]
            )
            """,
            to: "Package.swift",
            in: root
        )
        try TestSources.write(".build/\n", to: ".gitignore", in: root)
        try TestSources.write("public struct Widget {\n    public init() {}\n}\n", to: "Sources/Lib/Core.swift", in: root)
        try TestSources.write(Self.fixtureTests, to: "Tests/LibTests/GadgetTests.swift", in: root)
        try TestSources.commitAll(in: root, message: "fixture")
        try TestSources.write("public struct Widget {\n    public init() {}\n    public func shine() {}\n}\n", to: "Sources/Lib/Core.swift", in: root)
        try await TestSources.swiftBuildSuspending(packageAt: root, includingTests: true)
        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()
        let freshness = try await engine.ensureFresh()
        let output = try await engine.affected(options: AffectedOptions(), freshness: freshness)

        let filters = Self.filters(in: output)
        #expect(filters.count == 10, "one filter per test of the fixture:\n\(output)")
        #expect(filters.contains(#"LibTests\.shines\(\)"#))
        #expect(filters.contains(#"LibTests\.Outer/Inner/deep\(\)"#))
        #expect(output.contains("-only-testing:LibTests/Outer/Inner/deeper()"))
        #expect(output.contains("-only-testing:LibTests/titled()"))
        for filter in filters {
            let run = try await Self.swiftTest(filter: filter, in: root)
            #expect(!run.contains("No matching test cases"), "\(filter) ran nothing:\n\(run.suffix(600))")
            #expect(
                run.contains("Test run with 1 test ") || run.contains("Executed 1 test,"),
                "\(filter) did not run exactly one test:\n\(run.suffix(600))"
            )
        }
    }

    /// `swift test --skip-build --filter <filter>` on the built fixture, everything it printed, run off the cooperative pool with SwiftPM's temporary directory in the test's scope.
    private static func swiftTest(filter: String, in root: URL) async throws -> String {
        let swiftPMTemporary = try TemporaryDirectory.make("swiftpm")
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            let runner = Thread {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
                process.arguments = ["test", "--package-path", root.path, "--skip-build", "--filter", filter]
                process.environment = ProcessInfo.processInfo.environment.merging(["TMPDIR": swiftPMTemporary.path + "/"]) { _, redirected in redirected }
                let sink = Pipe()
                process.standardOutput = sink
                process.standardError = sink
                do {
                    try process.run()
                    let output = sink.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    continuation.resume(returning: String(data: output, encoding: .utf8) ?? "")
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            runner.name = "sift.tests.fixture-swift-test"
            runner.start()
        }
    }
}

extension AffectedFilterSpellingTests {
    /// One test shape and the three spellings a runner accepts for it, as measured.
    struct Shape: Sendable, CustomTestStringConvertible {
        let symbol: TestSymbol
        let listed: String
        let filter: String
        let onlyTesting: String

        var testDescription: String {
            listed
        }
    }
}
