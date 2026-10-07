//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers how `affected` names XCTest tests that a case nests, inherits or declares generically, over a name-match walk that needs no build.
@Suite(.temporaryDirectories)
struct AffectedXCTestCaseTests {
    /// The answer for a repository whose `Widget` gains a member after the fixture commit, with `tests` written under `Tests/LibTests/`.
    private static func affected(tests: [(path: String, source: String)]) async throws -> String {
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
        try TestSources.write("public struct Widget {\n    public init() {}\n}\n", to: "Sources/Lib/Core.swift", in: root)
        for test in tests {
            try TestSources.write(test.source, to: "Tests/LibTests/\(test.path)", in: root)
        }
        try TestSources.commitAll(in: root, message: "fixture")
        try TestSources.write("public struct Widget {\n    public init() {}\n    public func shine() {}\n}\n", to: "Sources/Lib/Core.swift", in: root)
        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()
        let freshness = try await engine.ensureFresh()
        return try await engine.affected(options: AffectedOptions(), freshness: freshness)
    }

    /// The `swift test` command line of an answer.
    private static func swiftTestLine(_ output: String) -> String? {
        output.split(separator: "\n").first { $0.hasPrefix("  swift test") }.map(String.init)
    }

    /// No `swift test --filter` spelling selects a test in a nested XCTest case, so the filter leaves it out and the answer says so, rather than offering one that runs nothing.
    @Test
    func aNestedXCTestCaseIsLeftOutOfTheFilterAndSaidToBeSelectableByNone() async throws {
        let output = try await Self.affected(tests: [(
            "GadgetTests.swift",
            """
            import XCTest
            @testable import Lib

            enum Outer {
                final class Inner: XCTestCase {
                    func testOne() { _ = Widget() }
                }
            }

            final class GadgetTests: XCTestCase {
                func testTwo() { _ = Widget() }
            }
            """
        )])

        #expect(output.contains("LibTests.Outer.Inner/testOne"))
        #expect(!output.contains("-only-testing:LibTests/Outer.Inner"))
        #expect(Self.swiftTestLine(output) == #"  swift test --filter 'LibTests\.GadgetTests/testTwo'"#)
        #expect(!output.contains(#"Outer\.Inner"#))
        #expect(output.contains("an XCTest case nested inside another type (`Outer.Inner`) is, on macOS, selected by no `swift test --filter`"))
        #expect(output.contains("leaves out 1 test above in a nested XCTest case, which no filter selects"))
        #expect(!output.contains("verified for swift-testing's own ids"), "the swift-testing suite caveat is for a different runner's nesting and says nothing true about this one")
    }

    /// A generic base is never run by XCTest, so its test is named under each concrete subclass and never under the base.
    @Test
    func aGenericBaseIsNeverNamedAndItsSubclassesAre() async throws {
        let output = try await Self.affected(tests: [
            (
                "BaseCase.swift",
                """
                import XCTest
                @testable import Lib

                class BaseCase<Item>: XCTestCase {
                    func testOne() { _ = Widget() }
                }
                """
            ),
            (
                "GadgetTests.swift",
                """
                import XCTest

                final class GadgetTests: BaseCase<Int> {}

                final class GizmoTests: BaseCase<String> {}
                """
            ),
        ])

        #expect(output.contains("LibTests.GadgetTests/testOne"))
        #expect(output.contains("LibTests.GizmoTests/testOne"))
        #expect(output.contains("-only-testing:LibTests/GizmoTests/testOne"))
        #expect(!output.contains("BaseCase/testOne"))
    }

    /// A non-generic base runs its own test and lends it to every subclass, so the test is named under the base and under each subclass that does not override it.
    @Test
    func anInheritedTestIsNamedUnderTheBaseAndEachSubclassThatDoesNotOverrideIt() async throws {
        let output = try await Self.affected(tests: [(
            "BaseCase.swift",
            """
            import XCTest
            @testable import Lib

            class BaseCase: XCTestCase {
                func testOne() { _ = Widget() }
            }

            final class GadgetTests: BaseCase {}

            final class GizmoTests: BaseCase {
                override func testOne() {}
            }
            """
        )])

        #expect(output.contains("LibTests.BaseCase/testOne"))
        #expect(output.contains("LibTests.GadgetTests/testOne"))
        #expect(output.contains("-only-testing:LibTests/GadgetTests/testOne"))
        #expect(output.contains(#"--filter 'LibTests\.GadgetTests/testOne'"#))
        #expect(!output.contains("GizmoTests/testOne"))
    }

    /// The arguments an answer offers under its `xcodebuild` heading, one per line.
    private static func onlyTestingArguments(_ output: String) -> Set<String> {
        Set(output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.hasPrefix("-only-testing:") })
    }

    /// `xcodebuild` selects a nested XCTest case only by its mangled runtime class name, whose kind letters say what each enclosing type is, and leaves out, counted, a case in an extension whose extended type's kind it cannot know.
    @Test
    func aNestedXCTestCaseIsSelectedByItsMangledRuntimeName() async throws {
        let output = try await Self.affected(tests: [(
            "WidgetTests.swift",
            """
            import XCTest
            @testable import Lib

            enum ChoreTasks {
                final class LampTests: XCTestCase {
                    func testOne() { _ = Widget() }
                }
            }

            final class WidgetTests: XCTestCase {
                func testTwo() { _ = Widget() }

                final class GizmoTests: XCTestCase {
                    func testThree() { _ = Widget() }
                }
            }

            extension WidgetTests {
                final class GadgetTests: XCTestCase {
                    func testGamma() { _ = Widget() }
                }
            }
            """
        )])

        #expect(Self.onlyTestingArguments(output) == [
            "-only-testing:LibTests/WidgetTests/testTwo",
            "-only-testing:LibTests/_TtCO8LibTests10ChoreTasks9LampTests/testOne",
            "-only-testing:LibTests/_TtCC8LibTests11WidgetTests10GizmoTests/testThree",
        ])
        #expect(output.contains("  leaves out 1 test above in a nested XCTest case whose runtime class name cannot be spelt"))
    }

    /// When every test reached is in a nested XCTest case, the bare `swift test` is said to be the whole suite rather than printed over a line that contradicts it.
    @Test
    func aBareSwiftTestIsSaidToBeTheWholeSuiteWhenNothingReachedIsFilterable() async throws {
        let output = try await Self.affected(tests: [(
            "WidgetTests.swift",
            """
            import XCTest
            @testable import Lib

            enum ChoreTasks {
                final class LampTests: XCTestCase {
                    func testOne() { _ = Widget() }
                }
            }
            """
        )])

        #expect(Self.swiftTestLine(output)?.hasPrefix("  swift test — no filter: the 1 test above is in a nested XCTest case") == true)
        #expect(output.contains("so the only `swift test` that runs it is the whole suite"))
        #expect(!output.contains("leaves out"))
    }

    /// The `swift test` leave-out line counts tests, so a whole nested case reached counts every test it runs rather than one.
    @Test
    func theLeaveOutLineCountsTheTestsOfAWholeNestedCase() async throws {
        let output = try await Self.affected(tests: [(
            "WidgetTests.swift",
            """
            import XCTest
            @testable import Lib

            enum ChoreTasks {
                final class LampTests: XCTestCase {
                    let widget = Widget()
                    func testOne() {}
                    func testTwo() {}
                }
            }

            final class WidgetTests: XCTestCase {
                func testThree() { _ = Widget() }

                final class GizmoTests: XCTestCase {
                    func testGamma() { _ = Widget() }
                    func testNaming() { _ = Widget() }
                    func testNothing() { _ = Widget() }
                }
            }
            """
        )])

        #expect(output.contains("-only-testing:LibTests/_TtCO8LibTests10ChoreTasks9LampTests\n"))
        #expect(output.contains("  leaves out 5 tests above in a nested XCTest case, which no filter selects"))
        // Five listed entries — the whole `LampTests` case, `testThree`, and `GizmoTests`' three tests apart —
        // stand for six actual tests, since the case entry alone runs two: the header counts the tests, not the entries.
        #expect(output.contains("affected tests (6 in 1 target):"))
    }

    /// A reference in a case's own surface reaches the whole case, which a non-generic base runs itself and lends to its subclass.
    @Test
    func aWholeBaseCaseIsNamedWithEachSubclass() async throws {
        let output = try await Self.affected(tests: [(
            "BaseCase.swift",
            """
            import XCTest
            @testable import Lib

            class BaseCase: XCTestCase {
                let widget = Widget()
                func testOne() {}
            }

            final class GadgetTests: BaseCase {}
            """
        )])

        #expect(Self.onlyTestingArguments(output) == ["-only-testing:LibTests/BaseCase", "-only-testing:LibTests/GadgetTests"])
    }

    /// A whole generic base reached is never named, since XCTest runs none of it; only its concrete subclass is.
    @Test
    func aWholeGenericBaseCaseIsNamedOnlyByItsSubclass() async throws {
        let output = try await Self.affected(tests: [(
            "BaseCase.swift",
            """
            import XCTest
            @testable import Lib

            class BaseCase<Item>: XCTestCase {
                let widget = Widget()
                func testOne() {}
            }

            final class GadgetTests: BaseCase<Int> {}
            """
        )])

        #expect(Self.onlyTestingArguments(output) == ["-only-testing:LibTests/GadgetTests"])
    }
}
