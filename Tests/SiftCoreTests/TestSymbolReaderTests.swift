//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers how a test is recognised from indexed rows alone — the shape rule `affected` stands on, and the two runners' spellings it produces.
@Suite(.temporaryDirectories)
struct TestSymbolReaderTests {
    /// One test file's rows in a store, attributed to the test target the recognition rule reads the module from.
    private static func store(_ source: String, at path: String, module: String = "LibTests") throws -> IndexStore {
        let store = try TestSources.makeStore()
        let parsed = try TestSources.parsed(source, path: path)
        try store.replaceFiles([parsed]) { _ in (module, false) }
        return store
    }

    /// Resolves the innermost declaration at `line` and asks what test, if any, it belongs to.
    private static func test(at line: Int, in path: String, store: IndexStore) throws -> TestDeclaration? {
        let reader = TestSymbolReader(store: store)
        guard let enclosing = try reader.enclosingSymbol(path: path, line: line) else { return nil }
        return try reader.testSymbol(enclosing: enclosing)
    }

    @Test
    func aSwiftTestingFunctionIsNamedWithItsLabelsIntactInBothSpellings() throws {
        let store = try Self.store(
            """
            import Testing

            struct WidgetTests {
                @Test func polishes() {
                    Widget().polish()
                }

                @Test(arguments: [1, 2]) func scales(by factor: Int, twice: Bool) {
                    Widget().scale(factor)
                }
            }
            """,
            at: "Tests/LibTests/WidgetTests.swift"
        )

        let simpleFound = try Self.test(at: 5, in: "Tests/LibTests/WidgetTests.swift", store: store)
        let labelledFound = try Self.test(at: 9, in: "Tests/LibTests/WidgetTests.swift", store: store)
        let simple = try #require(simpleFound)
        let labelled = try #require(labelledFound)

        #expect(simple.symbol.style == .swiftTesting)
        #expect(simple.symbol.onlyTestingArgument == "-only-testing:LibTests/WidgetTests/polishes()")
        #expect(simple.symbol.swiftTestFilter == #"LibTests\.WidgetTests/polishes\(\)"#)
        // The labelled form is what `swift test list` prints, so it is what a --filter has to spell.
        #expect(labelled.symbol.onlyTestingArgument == "-only-testing:LibTests/WidgetTests/scales(by:twice:)")
        #expect(labelled.symbol.swiftTestFilter == #"LibTests\.WidgetTests/scales\(by:twice:\)"#)
    }

    @Test
    func anXCTestMethodIsNamedWithoutParenthesesAndFoundThroughAnIntermediateBaseClass() throws {
        let store = try Self.store(
            """
            import XCTest

            class BaseCase: XCTestCase {}

            final class WidgetTests: BaseCase {
                func testPolishes() {
                    Widget().polish()
                }

                func helper() {}
            }
            """,
            at: "Tests/LibTests/WidgetTests.swift"
        )

        let testMethod = try Self.test(at: 7, in: "Tests/LibTests/WidgetTests.swift", store: store)
        let helperMember = try Self.test(at: 11, in: "Tests/LibTests/WidgetTests.swift", store: store)
        let found = try #require(testMethod)
        let helper = try #require(helperMember)

        #expect(found.symbol.style == .xcTest)
        #expect(found.symbol.onlyTestingArgument == "-only-testing:LibTests/WidgetTests/testPolishes")
        // A private member of the suite is suite-scoped by construction, so it coarsens to the whole class rather than naming a test it cannot identify.
        #expect(helper.symbol.function == nil)
        #expect(helper.symbol.onlyTestingArgument == "-only-testing:LibTests/WidgetTests")
    }

    /// A reference landing on the suite's own surface implicates every test in it, because nothing in the evidence singles one out.
    @Test
    func aReferenceOnTheSuitesOwnStoredPropertyNamesTheWholeSuite() throws {
        let store = try Self.store(
            """
            import Testing

            struct WidgetTests {
                let subject = Widget()

                @Test func polishes() {}
            }
            """,
            at: "Tests/LibTests/WidgetTests.swift"
        )

        let property = try Self.test(at: 4, in: "Tests/LibTests/WidgetTests.swift", store: store)
        let found = try #require(property)

        #expect(found.symbol.function == nil)
        #expect(found.symbol.onlyTestingArgument == "-only-testing:LibTests/WidgetTests")
        #expect(found.symbol.swiftTestFilter == #"LibTests\.WidgetTests"#)
    }

    /// The negative that keeps the walk honest: a test-target helper is a route to tests, not a test, so it must not be reported as one.
    @Test
    func aHelperFileInATestTargetIsNotATest() throws {
        let store = try Self.store(
            """
            import Foundation

            enum Fixtures {
                static func widget() -> Widget { Widget() }
            }
            """,
            at: "Tests/LibTests/Fixtures.swift"
        )

        let resolved = try Self.test(at: 4, in: "Tests/LibTests/Fixtures.swift", store: store)

        #expect(resolved == nil)
    }

    /// A file importing both libraries is read declaration by declaration, so its XCTest class is found beside its swift-testing suite.
    @Test
    func aFileImportingBothLibrariesNamesEachTestByItsOwnLibrary() throws {
        let store = try Self.store(
            """
            import Testing
            import XCTest

            struct NamedSuite {
                @Test func polishes() {}
            }

            final class GizmoTests: XCTestCase {
                func testPolishes() {}

                func helper() {}
            }
            """,
            at: "Tests/LibTests/MixedTests.swift"
        )

        let swiftTesting = try #require(try Self.test(at: 5, in: "Tests/LibTests/MixedTests.swift", store: store))
        let xcTest = try #require(try Self.test(at: 9, in: "Tests/LibTests/MixedTests.swift", store: store))
        let helper = try #require(try Self.test(at: 11, in: "Tests/LibTests/MixedTests.swift", store: store))

        #expect(swiftTesting.symbol.style == .swiftTesting)
        #expect(swiftTesting.symbol.onlyTestingArgument == "-only-testing:LibTests/NamedSuite/polishes()")
        #expect(xcTest.symbol.style == .xcTest)
        #expect(xcTest.symbol.onlyTestingArgument == "-only-testing:LibTests/GizmoTests/testPolishes")
        #expect(helper.symbol.function == nil)
        #expect(helper.symbol.style == .xcTest)
        #expect(helper.symbol.onlyTestingArgument == "-only-testing:LibTests/GizmoTests")
    }

    @Test
    func theSwiftPMFilterEscapesEveryMetacharacterAndTheCoarserGrainsDropWhatTheyDoNotName() {
        let full = TestSymbol(target: "Lib+Tests", suite: "Outer.Inner", function: "runs(a:)", style: .swiftTesting)

        #expect(full.onlyTestingArgument == "-only-testing:Lib+Tests/Outer/Inner/runs(a:)")
        #expect(full.swiftTestFilter == #"Lib\+Tests\.Outer/Inner/runs\(a:\)"#)
        #expect(full.suiteOnly.onlyTestingArgument == "-only-testing:Lib+Tests/Outer/Inner")
        #expect(full.targetOnly.onlyTestingArgument == "-only-testing:Lib+Tests")
        #expect(full.targetOnly.swiftTestFilter == #"Lib\+Tests"#)
        #expect(full.suiteIsNested)
    }

    /// A method of a struct nested in a test case is no test, and the runner would reject a path naming it, so its reference counts for the case that encloses the struct.
    @Test
    func aMethodOfAStructNestedInATestCaseNamesTheCaseNotTheMethod() throws {
        let store = try Self.store(
            """
            import XCTest

            final class WidgetTests: XCTestCase {
                struct Inner {
                    func testTwo() {
                        Widget().polish()
                    }
                }
            }
            """,
            at: "Tests/LibTests/WidgetTests.swift"
        )

        let found = try #require(try Self.test(at: 6, in: "Tests/LibTests/WidgetTests.swift", store: store))

        #expect(found.symbol.function == nil)
        #expect(found.symbol.onlyTestingArgument == "-only-testing:LibTests/WidgetTests")
    }
}
