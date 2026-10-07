//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers the static inventory: which declarations are counted as tests, and which of the four dispositions each one's declaration promises.
@Suite(.temporaryDirectories)
struct TestInventoryTests {
    /// The inventory of a set of fixture files, written at their repo-relative paths so the body reader has something to read.
    static func inventory(_ files: [(path: String, source: String)], guessedModules: Bool = false) throws -> TestInventory {
        let root = try TemporaryDirectory.make("inventory")
        let store = try TestSources.makeStore()
        let parsed = try files.map { try TestSources.parsed($0.source, path: $0.path, in: root) }
        try store.replaceFiles(parsed) { path in
            (path.split(separator: "/").first.map(String.init) ?? path, guessedModules)
        }
        return try TestInventory.read(store: store, repositoryRoot: root)
    }

    private static var swiftTestingFile: (path: String, source: String) {
        (
            "SuiteTests/Suites.swift",
            """
            import Testing

            @Suite(.disabled("suite off"))
            struct OffSuite {
                @Test func inheritsTheSuitesReason() {}

                @Test(.disabled("its own reason"))
                func carriesItsOwnReason() {}
            }

            @Suite("Named")
            struct NamedSuite {
                @Test("adds two numbers") func addsTwoNumbers() {}

                @Test(.disabled("above"))
                func disabledFromTheLineAbove() {}

                @Test(.disabled("inline")) func disabledInline() {}

                @Test(.enabled(if: Bool.random()))
                func decidedAtRuntime() {}

                @Test(.disabled())
                func disabledWithNoReason() {}

                @Test(arguments: [1, 2, 3])
                func doublingIsEven(_ value: Int) {}

                struct Inner {
                    @Test func nested() {}
                }
            }
            """
        )
    }

    private static var xcTestFile: (path: String, source: String) {
        (
            "BodyTests/BodyTests.swift",
            """
            import XCTest

            final class BodyTests: XCTestCase {
                func testExcludedInSource() {
                    XCTFail("switched off")
                }

                func testFailsAfterSetup() {
                    let value = 1 + 1
                    XCTFail("really failed")
                    XCTAssertEqual(value, 2)
                }

                func testSkipsOutright() throws {
                    throw XCTSkip("no hardware")
                }

                func testSkipsOnACondition() throws {
                    try XCTSkipIf(Bool.random())
                    XCTAssertEqual(1, 1)
                }

                func testSkipsUnlessACondition() throws {
                    try XCTSkipUnless(Bool.random())
                }

                func testRunsOrdinarily() {
                    XCTAssertEqual(2 + 2, 4)
                }

                @MainActor
                func testAttributedAndExcluded() {
                    XCTFail("switched off as well")
                }

                func helperThatFailsButIsNoTest() {
                    XCTFail("not a test")
                }
            }
            """
        )
    }

    private static func disposition(of function: String, in inventory: TestInventory) -> DeclaredTest.Disposition? {
        inventory.tests.first { $0.function == function }?.disposition
    }

    /// The join reads both spellings of an attributed declaration alike — the attribute above the `func` and the attribute inline with it — which is what an off-by-one on either anchor would break, and all this pins is that today neither spelling is read as a test that runs.
    @Test
    func anAttributeOnItsOwnLineAndAnInlineOneBothDecideTheDisposition() throws {
        let inventory = try Self.inventory([Self.swiftTestingFile])

        #expect(Self.disposition(of: "disabledFromTheLineAbove()", in: inventory) == .disabled(reason: "above"))
        #expect(Self.disposition(of: "disabledInline()", in: inventory) == .disabled(reason: "inline"))
    }

    /// Every swift-testing disposition an attribute can decide, including the one that carries no reason.
    @Test
    func theAttributeDecidesDisabledAndConditionalAndLeavesEverythingElseRunning() throws {
        let inventory = try Self.inventory([Self.swiftTestingFile])

        #expect(Self.disposition(of: "disabledWithNoReason()", in: inventory) == .disabled(reason: nil))
        #expect(Self.disposition(of: "decidedAtRuntime()", in: inventory) == .conditional(marker: "enabled(if:)"))
        #expect(Self.disposition(of: "addsTwoNumbers()", in: inventory) == .runs)
        #expect(Self.disposition(of: "doublingIsEven(_:)", in: inventory) == .runs)
    }

    /// A suite's `.disabled` reaches every test in it, and a test's own annotation wins where both are written.
    @Test
    func aDisabledSuitesReasonIsInheritedUntilATestWritesItsOwn() throws {
        let inventory = try Self.inventory([Self.swiftTestingFile])

        #expect(Self.disposition(of: "inheritsTheSuitesReason()", in: inventory) == .disabled(reason: "suite off"))
        #expect(Self.disposition(of: "carriesItsOwnReason()", in: inventory) == .disabled(reason: "its own reason"))
        // The suite two levels out is not disabled, and nothing about the nested suite changes that.
        #expect(Self.disposition(of: "nested()", in: inventory) == .runs)
    }

    /// The display name is the test's own, and a suite's name is not lent to the tests inside it.
    @Test
    func onlyTheTestsOwnLiteralIsItsDisplayName() throws {
        let inventory = try Self.inventory([Self.swiftTestingFile])
        let named = inventory.tests.filter { $0.suite.hasPrefix("NamedSuite") }

        #expect(inventory.tests.first { $0.function == "addsTwoNumbers()" }?.displayName == "adds two numbers")
        #expect(named.filter { $0.displayName != nil }.count == 1)
        #expect(inventory.tests.first { $0.function == "nested()" }?.suite == "NamedSuite.Inner")
    }

    /// The four XCTest body openings, and the one that is a failure rather than an exclusion.
    @Test
    func theFirstStatementOfAnXCTestBodyDecidesItAndNothingLaterInTheBodyDoes() throws {
        let inventory = try Self.inventory([Self.xcTestFile])

        #expect(Self.disposition(of: "testExcludedInSource()", in: inventory) == .excludedByXCTFail)
        #expect(Self.disposition(of: "testFailsAfterSetup()", in: inventory) == .runs)
        #expect(Self.disposition(of: "testSkipsOutright()", in: inventory) == .skips(reason: "no hardware"))
        #expect(Self.disposition(of: "testSkipsOnACondition()", in: inventory) == .conditional(marker: "XCTSkipIf"))
        #expect(Self.disposition(of: "testSkipsUnlessACondition()", in: inventory) == .conditional(marker: "XCTSkipUnless"))
        #expect(Self.disposition(of: "testRunsOrdinarily()", in: inventory) == .runs)
        // An attribute written above the `func` keyword moves what the index calls the declaration's line, and the body behind it still has to be found.
        #expect(Self.disposition(of: "testAttributedAndExcluded()", in: inventory) == .excludedByXCTFail)
        // A helper that fails is not a test, whatever its body opens with.
        #expect(inventory.tests.contains { $0.function == "helperThatFailsButIsNoTest()" } == false)
    }

    /// The whole inventory, ordered and attributed: two targets, both frameworks, each test carrying where it was declared.
    @Test
    func theInventoryIsOrderedByTargetThenSuiteThenFunctionAndCarriesItsDeclaringSite() throws {
        let inventory = try Self.inventory([Self.xcTestFile, Self.swiftTestingFile])
        let ordered = inventory.tests.map { "\($0.target)/\($0.suite)/\($0.function)" }

        #expect(ordered.count == 16)
        #expect(Array(ordered.prefix(3)) == [
            "BodyTests/BodyTests/testAttributedAndExcluded()",
            "BodyTests/BodyTests/testExcludedInSource()",
            "BodyTests/BodyTests/testFailsAfterSetup()",
        ])
        // A nested suite sorts under the suite that owns it, and both under the target they share.
        #expect(inventory.tests.filter { $0.target == "SuiteTests" }.map(\.suite) == [
            "NamedSuite", "NamedSuite", "NamedSuite", "NamedSuite", "NamedSuite", "NamedSuite",
            "NamedSuite.Inner", "OffSuite", "OffSuite",
        ])
        #expect(inventory.tests.filter { $0.style == .swiftTesting }.count == 9)
        let outright = try #require(inventory.tests.first { $0.function == "testSkipsOutright()" })
        #expect(outright.path == "BodyTests/BodyTests.swift")
        #expect(outright.line == 14)
        #expect(outright.targetWasGuessed == false)
        #expect(inventory.guessedTargets.isEmpty)
    }

    /// A target no build file claimed is named once, however many tests were attributed to it.
    @Test
    func aGuessedTargetIsNamedOnceForTheWholeTarget() throws {
        let inventory = try Self.inventory([Self.xcTestFile], guessedModules: true)

        let everyTestWasGuessed = inventory.tests.allSatisfy(\.targetWasGuessed)

        #expect(inventory.guessedTargets == ["BodyTests"])
        #expect(everyTestWasGuessed)
    }

    /// A file importing both libraries declares both kinds of test, each under the name and library its own runner logs it by.
    @Test
    func aFileImportingBothLibrariesDeclaresItsXCTestMethodsBesideItsSwiftTestingFunctions() throws {
        let inventory = try Self.inventory([(
            "MixedTests/MixedTests.swift",
            """
            import Testing
            import XCTest

            struct NamedSuite {
                @Test func polishes() {}
            }

            final class WidgetTests: XCTestCase {
                func testPolishes() {}

                func testSkipsOutright() throws {
                    throw XCTSkip("no hardware")
                }

                func helper() {}
            }
            """
        )])

        let declared = inventory.tests.map { "\($0.target)/\($0.suite)/\($0.function) \($0.style)" }

        #expect(declared == [
            "MixedTests/NamedSuite/polishes() swiftTesting",
            "MixedTests/WidgetTests/testPolishes() xcTest",
            "MixedTests/WidgetTests/testSkipsOutright() xcTest",
        ])
        // The body that decides an XCTest disposition is still read in a file the other library shares.
        #expect(Self.disposition(of: "testSkipsOutright()", in: inventory) == .skips(reason: "no hardware"))
    }

    /// A mixed file's XCTest body openings decide only its XCTest tests — a `@Test` function whose own body happens to open the same way an XCTest exclusion would must keep running.
    @Test
    func aTestFunctionsOwnStyleDecidesWhetherAnXCTestOpeningAppliesToIt() throws {
        let inventory = try Self.inventory([(
            "MixedTests/MixedTests.swift",
            """
            import Testing
            import XCTest

            struct NamedSuite {
                @Test func excludes() {
                    XCTFail("x")
                }

                @Test func skips() throws {
                    try XCTSkipIf(true)
                }
            }
            """
        )])

        let declared = inventory.tests.map(\.function)

        #expect(declared == ["excludes()", "skips()"])
        #expect(Self.disposition(of: "excludes()", in: inventory) == .runs)
        #expect(Self.disposition(of: "skips()", in: inventory) == .runs)
    }

    /// A file importing only XCTest still declares a marked function as a swift-testing test, since the marker is that library's own.
    @Test
    func aMarkedFunctionIsSwiftTestingWhateverElseItsFileImports() throws {
        let inventory = try Self.inventory([(
            "LegacyTests/LegacyTests.swift",
            """
            import XCTest

            struct NamedSuite {
                @Test func marked() {}
            }

            final class LegacyWidgetTests: XCTestCase {
                func testLegacyAnswer() {}
            }
            """
        )])

        let declared = inventory.tests.map { "\($0.suite)/\($0.function) \($0.style)" }

        #expect(declared == [
            "LegacyWidgetTests/testLegacyAnswer() xcTest",
            "NamedSuite/marked() swiftTesting",
        ])
    }

    /// A file that imports neither library declares no tests, whatever its functions are called.
    @Test
    func aFileOutsideATestTargetContributesNothing() throws {
        let inventory = try Self.inventory([(
            "Helpers/Helpers.swift",
            """
            import Foundation

            struct Helpers {
                func testLooksLikeOne() {}
            }
            """
        )])

        #expect(inventory.tests.isEmpty)
    }

    /// A superclass named through a typealias its module declares, in another file, still reaches `XCTestCase`, directly and through a class between.
    ///
    /// Another module's alias of the same name does not stand in for it.
    @Test
    func aSuperclassNamedThroughATypealiasOfItsModuleIsATestCase() throws {
        let inventory = try Self.inventory([
            ("WidgetTests/Support.swift", "import XCTest\n\ntypealias BaseCase = XCTestCase\n"),
            (
                "WidgetTests/WidgetTests.swift",
                """
                import XCTest

                class WidgetTests: BaseCase {
                    func testOne() {}
                }

                final class GizmoTests: WidgetTests {
                    func testTwo() {}
                }
                """
            ),
            ("AlphaTests/Support.swift", "import XCTest\n\ntypealias BetaTests = XCTestCase\n"),
            (
                "GadgetTests/GadgetTests.swift",
                """
                import XCTest

                final class GadgetTests: BetaTests {
                    func testThree() {}
                }
                """
            ),
        ])

        #expect(inventory.tests.map { "\($0.suite)/\($0.function)" } == ["GizmoTests/testOne()", "GizmoTests/testTwo()", "WidgetTests/testOne()"])
    }

    /// The `test…` methods an extension adds to a test case are tests of that case, whatever the extension's own clause names.
    @Test
    func aTestMethodAnExtensionAddsBelongsToTheClassItExtends() throws {
        let inventory = try Self.inventory([(
            "WidgetTests/WidgetTests.swift",
            """
            import XCTest

            final class WidgetTests: XCTestCase {
                func testOne() {}
            }

            extension WidgetTests {
                func testTwo() {}
            }

            extension WidgetTests: Sendable {
                func testThree() {}
            }
            """
        )])

        #expect(inventory.tests.map { "\($0.suite)/\($0.function)" } == [
            "WidgetTests/testOne()",
            "WidgetTests/testThree()",
            "WidgetTests/testTwo()",
        ])
    }

    /// A method of a struct nested in a test case is a test of neither, however it is named.
    @Test
    func aMethodOfAStructNestedInATestCaseIsNotATest() throws {
        let inventory = try Self.inventory([(
            "WidgetTests/WidgetTests.swift",
            """
            import XCTest

            final class WidgetTests: XCTestCase {
                struct Inner {
                    func testTwo() {}
                }

                func testOne() {}
            }
            """
        )])

        #expect(inventory.tests.map { "\($0.suite)/\($0.function)" } == ["WidgetTests/testOne()"])
    }

    /// An extension can only extend a type its own file can see — its own module and the modules it imports — so a same-named type declared in an unrelated module does not conscript the extension's methods.
    @Test
    func anExtensionOfALikeNamedTypeInAnUnimportedModuleIsNotConscripted() throws {
        let inventory = try Self.inventory([
            ("LibCore/TypeA.swift", "public struct TypeA {}\n"),
            (
                "LibTests/TypeA.swift",
                """
                import XCTest

                final class TypeA: XCTestCase {
                    func testOne() {}
                }
                """
            ),
            (
                "SomeOtherTests/TypeA.swift",
                """
                import LibCore
                import XCTest

                extension TypeA {
                    func testNope() {}
                }
                """
            ),
        ])

        #expect(inventory.tests.map { "\($0.target)/\($0.suite)/\($0.function)" } == ["LibTests/TypeA/testOne()"])
    }

    /// A typealias stands in for `XCTestCase` only where the subclass's own file can see the module that declares it, so an import brings a cross-module alias into reach the same way it would a same-module one.
    @Test
    func aSuperclassNamedThroughAnImportedModulesTypealiasIsATestCase() throws {
        let inventory = try Self.inventory([
            ("ModuleA/Support.swift", "import XCTest\n\ntypealias BaseCase = XCTestCase\n"),
            (
                "ModuleB/GadgetTests.swift",
                """
                import ModuleA
                import XCTest

                final class GadgetTests: BaseCase {
                    func testThree() {}
                }
                """
            ),
        ])

        #expect(inventory.tests.map { "\($0.target)/\($0.suite)/\($0.function)" } == ["ModuleB/GadgetTests/testThree()"])
    }
}
