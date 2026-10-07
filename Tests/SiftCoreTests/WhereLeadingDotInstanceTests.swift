//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A leading-dot `.m(x)` that nothing follows is left out of a name whose every declaration is an instance member, and counted on the name line.
@Suite(.temporaryDirectories)
struct WhereLeadingDotInstanceTests {
    private static var types: String {
        """
        struct Depot {
            var stock: Int
            func load(_ value: Int) -> Depot { self }
        }
        struct Orchard {
            static func load(_ value: Int) -> Orchard { Orchard() }
            func tend() -> Orchard { self }
        }
        enum Crate {
            case load(Int)
            case stock(Int)
        }
        """
    }

    private static var calls: String {
        """
        struct Calls {
            func alone() { let crate: Crate = .load(1) }
            func held(_ depot: Depot) { _ = depot.load(2) }
            func curried(_ depot: Depot) { let next: Depot = .load(depot)(3) }
            func chained() { let orchard: Orchard = .load(4).tend() }
            func counted() { let crate: Crate = .stock(5) }
            func weighed(_ depot: Depot) -> Int { depot.stock }
        }
        """
    }

    private static func answer(_ symbol: String, types: String = types, calls: String = calls) async throws -> String {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(types, to: "Sources/App/Types.swift", in: root)
        try TestSources.write(calls, to: "Sources/App/Calls.swift", in: root)
        try TestSources.commitAll(in: root, message: "fixture")
        return try await CallSiteHeadingTests.lookup(symbol, in: root)
    }

    private static func nameLine(_ output: String, _ name: String, sourceLocation: SourceLocation = #_sourceLocation) throws -> String {
        try String(#require(output.split(separator: "\n").first { $0.hasPrefix("\"\(name)\" (") }, sourceLocation: sourceLocation))
    }

    /// An instance method's name written `.load(1)` with nothing after it is another type's static member or case, so it is dropped and counted.
    @Test
    func anUnchainedCallOfAnInstanceMethodIsDroppedAndCounted() async throws {
        let output = try await Self.answer("Depot.load")

        #expect(!output.contains("in Calls.alone()"))
        #expect(output.contains("in Calls.held(_:)"))
        let line = try Self.nameLine(output, "load")
        #expect(line.contains("4 call sites by name, 1 on other types dropped, 3 kept"))
    }

    /// A leading-dot call something is applied after — `.load(depot)(3)`, `.load(4).tend()` — may end in the contextual type through the member, so it stays listed.
    @Test
    func aChainedCallStaysListed() async throws {
        let output = try await Self.answer("Depot.load")

        #expect(output.contains("in Calls.curried(_:)"))
        #expect(output.contains("in Calls.chained()"))
    }

    /// A leading-dot line inside a postfix `#if` clause continues the expression above the `#if`, so it is a call on that receiver and stays listed.
    @Test
    func aLeadingDotLineUnderAPostfixIfConfigStaysListed() async throws {
        let calls = """
        struct Conditional {
            func alone(_ depot: Depot) -> Depot {
                depot
                #if DEBUG
                    .load(3)
                #endif
            }
            func after(_ depot: Depot) -> Depot {
                depot.load(1)
                #if DEBUG
                    .load(4)
                #endif
            }
        }
        """
        let output = try await Self.answer("Depot.load", calls: calls)

        #expect(output.contains("in Conditional.alone(_:)"))
        #expect(output.contains("in Conditional.after(_:)"))
        let line = try Self.nameLine(output, "load")
        #expect(!line.contains("dropped"))
    }

    /// A static method's name written `.load(1)` may be a call of it, so it stays listed.
    @Test
    func aStaticMethodsCallStaysListed() async throws {
        let output = try await Self.answer("Orchard.load")

        #expect(output.contains("in Calls.alone()"))
        #expect(!output.contains("on other types dropped"))
    }

    /// An enum case's name written `.load(1)` is how the case is made, so it stays listed.
    @Test
    func anEnumCasesUseStaysListed() async throws {
        let output = try await Self.answer("Crate.load")

        #expect(output.contains("in Calls.alone()"))
    }

    /// A name one of whose declarations is static or a case keeps every leading-dot call, since any of them may be one of those.
    @Test
    func aNameWithAStaticDeclarationKeepsEveryCall() async throws {
        let types = """
        struct Depot {
            func load(_ value: Int) -> Depot { self }
            static func load(_ value: String) -> Depot { Depot() }
        }
        """
        let calls = """
        struct Calls {
            func alone() { let depot: Depot = .load("a") }
        }
        """
        let output = try await Self.answer("load", types: types, calls: calls)

        #expect(output.contains("in Calls.alone()"))
        #expect(!output.contains("on other types dropped"))

        // A case among one owner's declarations keeps them too, as a static member does.
        let cased = try await Self.answer(
            "load",
            types: "enum Crate {\n    case load(Int)\n    func load(named value: String) -> Crate { self }\n}\n",
            calls: "struct Calls {\n    func boxed() { let crate: Crate = .load(1) }\n}\n"
        )

        #expect(cased.contains("in Calls.boxed()"))
        #expect(!cased.contains("on other types dropped"))
    }

    /// An instance property's name written `.stock(5)` is dropped as a method's is.
    @Test
    func anUnchainedUseOfAnInstancePropertyIsDropped() async throws {
        let output = try await Self.answer("Depot.stock")

        #expect(!output.contains("in Calls.counted()"))
        #expect(output.contains("in Calls.weighed(_:)"))
    }
}
