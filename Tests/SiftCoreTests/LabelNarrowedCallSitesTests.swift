//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers the narrowing of a name-matched call list by the argument labels of the declarations it stands for.
///
/// A member's bare name is shared across a codebase, so the list for one method took in every call of the word. The labels cut it to the calls that can be the method, and the rule these defend is that the cut never drops one that can: a defaulted argument left out, a trailing closure, a compound callee and an overload all keep their calls, and the line still says how many the name alone matched.
@Suite(.temporaryDirectories)
struct LabelNarrowedCallSitesTests {
    private static func lookup(_ symbol: String, declaring declarations: String, calling calls: String) async throws -> String {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(declarations, to: "Sources/App/Types.swift", in: root)
        try TestSources.write(calls, to: "Sources/App/Calls.swift", in: root)
        try TestSources.commitAll(in: root, message: "fixture")
        let engine = try SiftEngine(directory: root)
        let freshness = try await engine.ensureFresh()
        return try await engine.lookup(symbol: symbol, freshness: freshness)
    }

    /// Calls of same-named methods of other types, written with labels the declaration cannot take, are dropped, and the line gives both counts.
    @Test
    func aMembersListKeepsOnlyCallsItsLabelsCanTake() async throws {
        let output = try await Self.lookup(
            "Depot.run",
            declaring: """
            struct Depot {
                func run(in place: String, limit: Int = 3) {}
            }
            struct Orchard {
                func run() {}
                func run(x: Int) {}
            }
            """,
            calling: """
            struct Calls {
                let depot = Depot()
                let orchard = Orchard()
                func one() { depot.run(in: "a") }
                func two() { depot.run(in: "a", limit: 4) }
                func three() { orchard.run() }
                func four() { orchard.run(x: 1) }
            }
            """
        )

        #expect(output.contains("\"run\" (4 call sites by name, 2 with the labels (in:limit:), in 1 file"))
        #expect(WhereAnswerRepetitionTests.sitesOnePerLine(output).contains("Sources/App/Calls.swift:4  in Calls.one()"))
        #expect(WhereAnswerRepetitionTests.sitesOnePerLine(output).contains("Sources/App/Calls.swift:5  in Calls.two()"))
        #expect(!output.contains("in Calls.three()"))
        #expect(!output.contains("in Calls.four()"))
        #expect(output.contains("labels narrowed"))
    }

    /// A call that leaves out a defaulted argument, first or in the middle, passes a trailing closure, or spells a compound callee is a call the declaration can take.
    @Test
    func noCallTheDeclarationCanTakeIsDropped() async throws {
        let output = try await Self.lookup(
            "Depot.run",
            declaring: """
            struct Depot {
                func run(in place: String, limit: Int = 3, then body: () -> Void = {}) {}
            }
            struct Orchard {
                func run() {}
            }
            """,
            calling: """
            struct Calls {
                let depot = Depot()
                func one() { depot.run(in: "a") }
                func two() { depot.run(in: "a", then: {}) }
                func three() { depot.run(in: "a") {} }
                func four() { depot.run(in:limit:then:)("a", 1, {}) }
                func five() { Orchard().run() }
            }
            """
        )

        #expect(output.contains("\"run\" (5 call sites by name, 4 with the labels (in:limit:then:), in 1 file"))
        for caller in ["one", "two", "three", "four"] {
            #expect(output.contains("in Calls.\(caller)()"))
        }
        #expect(!output.contains("in Calls.five()"))
    }

    /// Overloads keep the calls any one of them can take, and the line names each overload's labels.
    @Test
    func overloadsKeepWhatAnyOfThemCanTake() async throws {
        let output = try await Self.lookup(
            "Depot.run",
            declaring: """
            struct Depot {
                func run(in place: String) {}
                func run(from place: String) {}
            }
            struct Orchard {
                func run() {}
            }
            """,
            calling: """
            struct Calls {
                func one() { Depot().run(in: "a") }
                func two() { Depot().run(from: "a") }
                func three() { Orchard().run() }
            }
            """
        )

        #expect(output.contains("\"run\" (3 call sites by name, 2 with the labels (in:) or (from:), in 1 file — for "))
        #expect(!output.contains("in Calls.three()"))
    }

    /// A name one of whose declarations is not a function is listed by name: a property holding a closure is called with labels no signature states.
    @Test
    func aNameSharedWithAPropertyIsNotNarrowed() async throws {
        let output = try await Self.lookup(
            "run",
            declaring: """
            struct Depot {
                func run(in place: String) {}
            }
            extension Depot {
                var run: (Int) -> Void { { _ in } }
            }
            """,
            calling: """
            struct Calls {
                func one() { Depot().run(in: "a") }
                func two() { Depot().run(3) }
            }
            """
        )

        #expect(!output.contains("by name,"))
        #expect(output.contains("in Calls.two()"))
    }

    /// Where the labels leave nothing, the answer says the name matched calls and none had the labels, rather than that no call was found.
    @Test
    func aListTheLabelsEmptySaysWhatTheNameMatched() async throws {
        let output = try await Self.lookup(
            "Depot.run",
            declaring: """
            struct Depot {
                func run(in place: String) {}
            }
            struct Orchard {
                func run() {}
            }
            """,
            calling: """
            struct Calls {
                func one() { Orchard().run() }
            }
            """
        )

        #expect(output.contains("no call spelled \"run\" with its labels anywhere in the working tree — 1 call site by name, none with the labels (in:)"))
    }

    /// A name declared more times than semantic relations are resolved for keeps the calls of every declaration, not only of those resolved.
    @Test
    func callsOfDeclarationsPastTheSemanticCapAreKept() async throws {
        let overloads = 0 ..< 7
        let output = try await Self.lookup(
            "stack",
            declaring: "struct Depot {\n" + overloads.map { "    func stack(a\($0): Int) {}" }.joined(separator: "\n") + "\n}",
            calling: "struct Calls {\n"
                + overloads.map { "    func call\($0)() { Depot().stack(a\($0): 1) }" }.joined(separator: "\n")
                + "\n    func stray() { Depot().stack(b: 1) }\n}\n"
        )

        #expect(overloads.count > WhereRenderer.semanticDeclCap)
        #expect(output.contains("\"stack\" (8 call sites by name, 7 with the labels "))
        for index in overloads {
            #expect(output.contains("in Calls.call\(index)()"))
        }
        #expect(!output.contains("in Calls.stray()"))
    }

    /// A method named on its type and given only its instance is kept whatever its labels, and through `Self` only inside the type declaring it.
    @Test
    func aMethodGivenItsInstanceIsKept() async throws {
        let output = try await Self.lookup(
            "Depot.run",
            declaring: """
            struct Depot {
                func run(in place: Int) {}
                static func curried(_ depot: Depot) { Self.run(depot)(in: 1) }
                static func partial(_ depot: Depot) { _ = Self.run(depot) }
            }
            """,
            calling: """
            struct Calls {
                func one(_ depot: Depot) { Depot.run(depot)(in: 1) }
                func two() { _ = Depot.run(Depot()) }
                static func three(_ depot: Depot) { _ = Self.run(depot) }
                func four(_ depot: Depot) { depot.run(1) }
            }
            """
        )

        #expect(output.contains("\"run\" (6 call sites by name, 4 with the labels (in:), in 2 files"))
        #expect(output.contains("in Calls.one("))
        #expect(output.contains("in Calls.two()"))
        #expect(output.contains("in Depot.curried("))
        #expect(output.contains("in Depot.partial("))
        #expect(!output.contains("in Calls.three("))
        #expect(!output.contains("in Calls.four("))
    }

    /// Initializers are never narrowed: the compiler writes memberwise and raw-value initializers the index has no row for, and a call of one is a call of the name.
    @Test
    func callsOfCompilerWrittenInitializersAreKept() async throws {
        let memberwise = try await Self.lookup(
            "Depot.init",
            declaring: """
            struct Depot {
                let first: Int
                let second: Int
            }
            extension Depot {
                init(spelled: String) { self.init(first: 0, second: 0) }
            }
            """,
            calling: """
            struct Calls {
                func one() -> Depot { Depot.init(first: 1, second: 2) }
            }
            """
        )
        let rawValue = try await Self.lookup(
            "Gizmo.init",
            declaring: """
            enum Gizmo: Int {
                case one
                init(spelled: String) { self = .one }
            }
            """,
            calling: """
            struct Calls {
                func two() -> Gizmo? { Gizmo.init(rawValue: 1) }
            }
            """
        )

        #expect(memberwise.contains("in Calls.one()"))
        #expect(memberwise.contains("in Depot.init(spelled:)"))
        #expect(rawValue.contains("in Calls.two()"))
    }

    /// A `Self.m(x)` inside an extension of a specialised generic type is written inside the type declaring the method.
    @Test
    func aMethodGivenItsInstanceInASpecialisedExtensionIsKept() async throws {
        let output = try await Self.lookup(
            "Depot.run",
            declaring: """
            struct Depot<Element> {
                func run(in place: Int) {}
            }
            extension Depot<Int> {
                static func partial(_ depot: Depot<Int>) { _ = Self.run(depot) }
            }
            """,
            calling: """
            struct Calls {
                func stray(_ depot: Depot<Int>) { depot.run(1) }
            }
            """
        )

        #expect(output.contains("\"run\" (2 call sites by name, 1 with the labels (in:), in 1 file"))
        #expect(output.contains("in Depot<Int>.partial("))
    }

    /// A declaring type is matched by the name it is declared under, whatever generic arguments, qualification or sugar its container path spells.
    @Test(arguments: [
        ("App.Depot<Pallet.Gizmo>", "Depot"),
        ("App.Orchard.Depot", "Depot"),
        ("App.[Pallet.Gizmo]", "Array"),
        ("App.[String: Int]", "Dictionary"),
        ("App.Int?", "Optional"),
        ("Depot", "Depot"),
    ])
    func aDeclaringTypeIsMatchedByItsDeclaredName(path: String, name: String) {
        #expect(DeclaredTypeName.last(ofPath: path) == name)
    }
}
