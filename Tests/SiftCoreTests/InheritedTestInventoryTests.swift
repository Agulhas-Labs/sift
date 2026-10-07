//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers the tests an XCTest case inherits: XCTest runs a superclass's `test…` methods under every subclass, so the inventory declares each of them under the class that runs it.
@Suite(.temporaryDirectories)
struct InheritedTestInventoryTests {
    /// XCTest runs a superclass's `test…` methods under each subclass declared beside it, so each is declared under the subclass too, and an override is declared once.
    @Test
    func aSubclassInTheSameFileDeclaresTheTestsItInherits() throws {
        let inventory = try TestInventoryTests.inventory([(
            "WidgetTests/WidgetTests.swift",
            """
            import XCTest

            class WidgetTests: XCTestCase {
                func testOne() {}
                func testThree() {}
            }

            final class GizmoTests: WidgetTests {
                func testTwo() {}
                override func testThree() {}
            }
            """
        )])

        #expect(inventory.tests.map { "\($0.suite)/\($0.function):\($0.line)" } == [
            "GizmoTests/testOne():4",
            "GizmoTests/testThree():10",
            "GizmoTests/testTwo():9",
            "WidgetTests/testOne():4",
            "WidgetTests/testThree():5",
        ])
    }

    /// A superclass declared in another file of the module is found by its name, directly or through a typealias, and a subclass whose every test is inherited is declared with all of them, each keeping the disposition of the body that runs.
    @Test
    func aSubclassOfABaseInAnotherFileDeclaresTheTestsItInheritsEvenWithNoneOfItsOwn() throws {
        let inventory = try TestInventoryTests.inventory([
            (
                "WidgetTests/WidgetTests.swift",
                """
                import XCTest

                class WidgetTests: XCTestCase {
                    func testOne() {}
                    func testExcludedInSource() {
                        XCTFail("not yet")
                    }
                }

                typealias BaseCase = WidgetTests
                """
            ),
            (
                "WidgetTests/GizmoTests.swift",
                """
                import XCTest

                final class GizmoTests: WidgetTests {}
                """
            ),
            (
                "WidgetTests/GadgetTests.swift",
                """
                import XCTest

                final class GadgetTests: BaseCase {
                    func testThree() {}
                }
                """
            ),
        ])

        #expect(inventory.tests.map { "\($0.target)/\($0.suite)/\($0.function)" } == [
            "WidgetTests/GadgetTests/testExcludedInSource()",
            "WidgetTests/GadgetTests/testOne()",
            "WidgetTests/GadgetTests/testThree()",
            "WidgetTests/GizmoTests/testExcludedInSource()",
            "WidgetTests/GizmoTests/testOne()",
            "WidgetTests/WidgetTests/testExcludedInSource()",
            "WidgetTests/WidgetTests/testOne()",
        ])
        #expect(inventory.tests.filter { $0.function == "testExcludedInSource()" }.allSatisfy { $0.disposition == .excludedByXCTFail })
    }

    /// XCTest never runs a generic case itself, only its subclasses, so a generic base's methods are declared under each specialising subclass and never under the base.
    ///
    /// An extension of a generic class cannot expose its methods to the runtime XCTest discovers through, so those run nowhere, which `swift test list` confirms.
    @Test
    func aGenericBaseLendsItsTestsToItsSubclassesAndDeclaresNoneItself() throws {
        let inventory = try TestInventoryTests.inventory([
            (
                "WidgetTests/BaseCase.swift",
                """
                import XCTest

                class BaseCase<Item>: XCTestCase {
                    func testOne() {}
                }

                extension BaseCase {
                    func testTwo() {}
                }
                """
            ),
            (
                "WidgetTests/GadgetTests.swift",
                """
                import XCTest

                final class GadgetTests: BaseCase<Int> {}

                final class GizmoTests: BaseCase<String> {
                    func testThree() {}
                }
                """
            ),
        ])

        #expect(inventory.tests.map { "\($0.suite)/\($0.function)" } == [
            "GadgetTests/testOne()",
            "GizmoTests/testOne()",
            "GizmoTests/testThree()",
        ])
    }
}
