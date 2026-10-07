//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A qualified query's name-matched sites leave out the calls written on another type, and count them on the name line.
@Suite(.temporaryDirectories)
struct WhereQualifierNarrowingTests {
    private static var types: String {
        """
        struct Depot {
            func load(_ value: Int) {}
        }
        struct Orchard {
            func load(_ value: Int) {}
            func tend() { load(1) }
            func also() { self.load(8) }
        }
        extension Depot {
            func refill() { load(2) }
            func again() { self.load(7) }
        }
        """
    }

    private static var calls: String {
        """
        struct Calls {
            func typed() { Depot.load(3) }
            func made() { Orchard().load(4) }
            func named() { Orchard.load(5) }
            func held(_ depot: Depot) { depot.load(6) }
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

    /// Calls written on another type, made on one, or implicitly inside an unrelated type are left out and counted.
    @Test
    func callsOnAnotherTypeAreDroppedAndCounted() async throws {
        let output = try await Self.answer("Depot.load")

        #expect(!output.contains("in Calls.made()"))
        #expect(!output.contains("in Calls.named()"))
        #expect(!output.contains("in Orchard.tend()"))
        #expect(!output.contains("in Orchard.also()"))
        let line = try Self.nameLine(output, "load")
        #expect(line.contains("8 call sites by name, 4 on other types dropped, 4 kept, in 2 files"))
    }

    /// Calls on the type itself, implicit or on self inside an extension of it, and on a receiver the scan cannot type stay listed.
    @Test
    func callsThatMayReachTheTypeStayListed() async throws {
        let output = try await Self.answer("Depot.load")

        #expect(output.contains("in Calls.typed()"))
        #expect(output.contains("in Calls.held(_:)"))
        #expect(output.contains("in Depot.refill()"))
        #expect(output.contains("in Depot.again()"))
    }

    /// An unqualified query names no type to narrow by, so every call by name stays listed.
    @Test
    func anUnqualifiedQueryDropsNothing() async throws {
        let types = """
        struct Depot {
            func load(_ value: Int) {}
        }
        struct Orchard {
            func tend() { load(1) }
        }
        """
        let output = try await Self.answer("load", types: types)

        #expect(!output.contains("on other types dropped"))
        #expect(output.contains("in Calls.made()"))
        #expect(output.contains("in Orchard.tend()"))
    }

    /// A subclass reaches its superclass's members, so calls on it or inside it stay listed.
    @Test
    func aSubclassReachesItsSuperclassMembers() async throws {
        let types = """
        class Base {
            func load(_ value: Int) {}
        }
        class Sub: Base {
            func tend() { load(1) }
        }
        struct Orchard {
            func load(_ value: Int) {}
        }
        """
        let calls = """
        struct Calls {
            func made() { Sub().load(2) }
            func other() { Orchard().load(3) }
        }
        """
        let output = try await Self.answer("Base.load", types: types, calls: calls)

        #expect(output.contains("in Sub.tend()"))
        #expect(output.contains("in Calls.made()"))
        #expect(!output.contains("in Calls.other()"))
        #expect(try Self.nameLine(output, "load").contains("1 on other types dropped"))
    }

    /// A protocol's members are reached through conformers and generic parameters the scan cannot see, so nothing is dropped.
    @Test
    func aProtocolMemberDropsNothing() async throws {
        let types = """
        protocol Loader {
            func load(_ value: Int)
        }
        struct Crate {
            func tend() { load(1) }
        }
        """
        let calls = """
        struct Calls {
            func made() { Crate().load(2) }
        }
        """
        let output = try await Self.answer("Loader.load", types: types, calls: calls)

        #expect(!output.contains("on other types dropped"))
        #expect(output.contains("in Crate.tend()"))
        #expect(output.contains("in Calls.made()"))
    }

    /// A subclass whose superclass is written as a nested type's dotted path still reaches its members.
    @Test
    func aSubclassOfANestedSuperclassReachesItsMembers() async throws {
        let types = """
        class Depot {
            class Crate {
                func load(_ value: Int) {}
            }
        }
        class Sub: Depot.Crate {
            func tend() { load(1) }
        }
        struct Orchard {
            func load(_ value: Int) {}
            func other() { load(2) }
        }
        """
        let calls = """
        struct Calls {
            func made() { Sub().load(3) }
        }
        """
        let output = try await Self.answer("Depot.Crate.load", types: types, calls: calls)

        #expect(output.contains("in Sub.tend()"))
        #expect(output.contains("in Calls.made()"))
        #expect(!output.contains("in Orchard.other()"))
    }

    /// A type whose inheritance clause writes a nested type's dotted path is listed among that type's conformers.
    @Test
    func aNestedTypeWrittenAsADottedPathListsItsConformers() async throws {
        let types = """
        class Depot {
            class Crate {}
        }
        class Sub: Depot.Crate {}
        """
        let output = try await Self.answer("Depot.Crate", types: types, calls: "")

        #expect(output.contains("conformers of Crate (1, by written name):"))
        #expect(output.contains("Sub — class"))
    }

    /// A subclass whose superclass is written behind its module's name still reaches its members.
    @Test
    func aSubclassOfAModuleQualifiedSuperclassReachesItsMembers() async throws {
        let types = """
        class Base {
            func load(_ value: Int) {}
        }
        class Sub: App.Base {
            func tend() { load(1) }
        }
        struct Orchard {
            func load(_ value: Int) {}
        }
        """
        let output = try await Self.answer("Base.load", types: types)

        #expect(output.contains("in Sub.tend()"))
        #expect(!output.contains("in Calls.made()"))
    }

    /// A call on self inside a superclass dispatches to the subclass's override, so it stays listed.
    @Test
    func aSuperclassCallingTheMemberOnSelfStaysListed() async throws {
        let types = """
        class Base {
            func run() { step() }
            func again() { self.step() }
            func step() {}
        }
        class Sub: Base {
            override func step() {}
        }
        struct Orchard {
            func step() {}
            func walk() { step() }
        }
        """
        let output = try await Self.answer("Sub.step", types: types, calls: "")

        #expect(output.contains("in Base.run()"))
        #expect(output.contains("in Base.again()"))
        #expect(!output.contains("in Orchard.walk()"))
    }

    /// A call inside an extension of a protocol the type conforms to dispatches to the type's witness, so it stays listed.
    @Test
    func aConformedProtocolCallingTheMemberOnSelfStaysListed() async throws {
        let types = """
        protocol Loader {
            func load(_ value: Int)
        }
        extension Loader {
            func go() { load(1) }
        }
        struct Crate: Loader {
            func load(_ value: Int) {}
        }
        struct Orchard {
            func load(_ value: Int) {}
            func tend() { load(2) }
        }
        """
        let output = try await Self.answer("Crate.load", types: types, calls: "")

        #expect(output.contains("in Loader.go()"))
        #expect(!output.contains("in Orchard.tend()"))
    }

    /// A call inside an extension constrained to the type runs on it, so it stays listed.
    @Test
    func anExtensionConstrainedToTheTypeStaysListed() async throws {
        let types = """
        class Depot {
            func load(_ value: Int) {}
        }
        protocol Loader {}
        extension Loader where Self: Depot {
            func fill() { load(1) }
        }
        struct Orchard {
            func load(_ value: Int) {}
            func tend() { load(2) }
        }
        """
        let output = try await Self.answer("Depot.load", types: types, calls: "")

        #expect(output.contains("in Loader.fill()"))
        #expect(!output.contains("in Orchard.tend()"))
    }

    /// Where a supertype is declared outside the repository, a call inside an extension of any type the repository does not declare may run on the type, so it stays listed.
    @Test
    func aSupertypeTheRepositoryCannotShowKeepsCallsInUnseenTypes() async throws {
        let types = """
        class Depot: Frame {
            func load(_ value: Int) {}
        }
        extension Panel {
            func go() { load(1) }
        }
        struct Orchard {
            func load(_ value: Int) {}
            func tend() { load(2) }
        }
        """
        let output = try await Self.answer("Depot.load", types: types, calls: "")

        #expect(output.contains("in Panel.go()"))
        #expect(!output.contains("in Orchard.tend()"))
    }

    /// A typealias may name the type, so a call written on one stays listed.
    @Test
    func aCallOnATypealiasStaysListed() async throws {
        let calls = """
        typealias Alias = Depot
        struct Calls {
            func named() { Alias.load(1) }
            func made() { Alias().load(2) }
            func other() { Orchard.load(3) }
        }
        """
        let output = try await Self.answer("Depot.load", calls: calls)

        #expect(output.contains("in Calls.named()"))
        #expect(output.contains("in Calls.made()"))
        #expect(!output.contains("in Calls.other()"))
    }

    /// A generic parameter, of a declaration around the site or of the type an extension extends, may stand for the type, so a call written on one stays listed.
    @Test
    func aCallOnAGenericParameterStaysListed() async throws {
        let calls = """
        struct Calls {
            func each<C: Depot>(_ value: C) { C.load(1) }
            func other() { Orchard.load(2) }
        }
        extension Array where Element: Depot {
            func all() { Element.load(3) }
        }
        """
        let output = try await Self.answer("Depot.load", calls: calls)

        #expect(output.contains("in Calls.each(_:)"))
        #expect(output.contains("in Array.all()"))
        #expect(!output.contains("in Calls.other()"))
    }

    /// The trailing name of a dotted receiver may be a property rather than a type, or the type of a module the scan does not resolve, so it stays listed and counted even where the repository declares a type by that name.
    @Test
    func aDottedReceiverStaysListed() async throws {
        let calls = """
        struct Calls {
            func shared() { Depot.Shared.load(1) }
            func other() { App.Orchard.load(2) }
        }
        """
        let output = try await Self.answer("Depot.load", calls: calls)

        #expect(output.contains("in Calls.shared()"))
        // The scan does not resolve the qualifier, so App.Orchard is not proven the tree's Orchard.
        #expect(output.contains("in Calls.other()"))
        #expect(output.contains("2 on types outside the tree"))
    }

    /// Where every call by name is on another type, the name line says so and counts them.
    @Test
    func everyCallOnAnotherTypeIsSaidSo() async throws {
        let types = """
        struct Depot {
            func load(_ value: Int) {}
        }
        struct Orchard {
            func load(_ value: Int) {}
            func tend() { load(1) }
        }
        """
        let calls = """
        struct Calls {
            func made() { Orchard().load(2) }
        }
        """
        let output = try await Self.answer("Depot.load", types: types, calls: calls)

        #expect(output.contains("every call spelled \"load\" is on another type — 2 call sites by name, 2 on other types dropped, none kept"))
    }
}

/// A type related to the queried type only through a typealias or a where clause is still one of its receivers.
extension WhereQualifierNarrowingTests {
    /// A subclass whose inheritance clause names a typealias for the type reaches its members, so calls on it or inside it stay listed.
    @Test
    func aSubclassWrittenThroughATypealiasReachesItsMembers() async throws {
        let types = """
        class Depot {
            func load(_ value: Int) {}
        }
        typealias Alias = Depot
        class Sub: Alias {
            func tend() { load(1) }
        }
        struct Orchard {
            func load(_ value: Int) {}
        }
        """
        let calls = """
        struct Calls {
            func made() { Sub().load(2) }
            func other() { Orchard().load(3) }
        }
        """
        let output = try await Self.answer("Depot.load", types: types, calls: calls)

        #expect(output.contains("in Sub.tend()"))
        #expect(output.contains("in Calls.made()"))
        #expect(!output.contains("in Calls.other()"))
    }

    /// A superclass named through a typealias is still a supertype, so its own calls on self, which may dispatch to the override, stay listed.
    @Test
    func aSuperclassWrittenThroughATypealiasKeepsItsCallsOnSelf() async throws {
        let types = """
        class Base {
            func load(_ value: Int) {}
            func go() { load(1) }
        }
        typealias Alias = Base
        class Depot: Alias {
            override func load(_ value: Int) {}
        }
        struct Orchard {
            func load(_ value: Int) {}
            func tend() { load(2) }
        }
        """
        let output = try await Self.answer("Depot.load", types: types, calls: "")

        #expect(output.contains("in Base.go()"))
        #expect(!output.contains("in Orchard.tend()"))
    }

    /// A protocol conformed to through a typealias is still a supertype, so a call inside an extension of it, which dispatches to the witness, stays listed.
    @Test
    func aProtocolConformedToThroughATypealiasKeepsItsWitnessCalls() async throws {
        let types = """
        protocol Loader {
            func load(_ value: Int)
        }
        typealias Alias = Loader
        struct Crate: Alias {
            func load(_ value: Int) {}
        }
        extension Loader {
            func go() { load(1) }
        }
        struct Orchard {
            func load(_ value: Int) {}
            func tend() { load(2) }
        }
        """
        let output = try await Self.answer("Crate.load", types: types, calls: "")

        #expect(output.contains("in Loader.go()"))
        #expect(!output.contains("in Orchard.tend()"))
    }

    /// A typealias for a protocol composition stands for every protocol in it, so a call inside an extension of any of them stays listed.
    @Test
    func aCompositionTypealiasKeepsCallsInEachOfItsProtocols() async throws {
        let types = """
        protocol Frame {}
        protocol Loader {
            func load(_ value: Int)
        }
        typealias Both = Frame & Loader
        class Crate: Both {
            func load(_ value: Int) {}
        }
        extension Loader {
            func go() { load(1) }
        }
        struct Orchard {
            func load(_ value: Int) {}
            func tend() { load(2) }
        }
        """
        let output = try await Self.answer("Crate.load", types: types, calls: "")

        #expect(output.contains("in Loader.go()"))
        #expect(!output.contains("in Orchard.tend()"))
    }

    /// A protocol whose own where clause requires Self to be the type, a protocol inheriting one, and a protocol inheriting the class itself run their extensions' calls on it, so those stay listed.
    @Test
    func aProtocolRequiringSelfToBeTheTypeKeepsItsCalls() async throws {
        let types = """
        class Depot {
            func load(_ value: Int) {}
        }
        protocol Loader where Self: Depot {}
        extension Loader {
            func fill() { load(1) }
        }
        protocol Panel: Loader {}
        extension Panel {
            func go() { load(2) }
        }
        protocol Frame: Depot {}
        extension Frame {
            func pack() { load(3) }
        }
        struct Orchard {
            func load(_ value: Int) {}
            func tend() { load(4) }
        }
        """
        let output = try await Self.answer("Depot.load", types: types, calls: "")

        #expect(output.contains("in Loader.fill()"))
        #expect(output.contains("in Panel.go()"))
        #expect(output.contains("in Frame.pack()"))
        #expect(!output.contains("in Orchard.tend()"))
    }

    /// A function whose own where clause requires Self to be the type runs its body on it, so a call on self inside it stays listed.
    @Test
    func aFunctionRequiringSelfToBeTheTypeKeepsItsCalls() async throws {
        let types = """
        class Depot {
            func load(_ value: Int) {}
        }
        protocol Loader {}
        extension Loader {
            func fill() where Self: Depot { self.load(1) }
        }
        struct Orchard {
            func load(_ value: Int) {}
            func tend() { load(3) }
        }
        """
        let output = try await Self.answer("Depot.load", types: types, calls: "")

        #expect(output.contains("in Loader.fill()"))
        #expect(!output.contains("in Orchard.tend()"))
    }

    /// A type or typealias declared inside a function body is never indexed, so a call inside such a type, or written on one, stays listed.
    @Test
    func aTypeDeclaredInAFunctionBodyKeepsItsCalls() async throws {
        let types = """
        class Depot {
            required init() {}
            func load(_ value: Int) {}
        }
        struct Orchard {
            func load(_ value: Int) {}
            func tend() { load(3) }
        }
        func host() {
            typealias Stand = Depot
            class Shed: Stand { func stock() { load(1) } }
            class Barn: Depot { func sweep() { self.load(2) } }
            Barn().load(4)
            Stand().load(5)
        }
        """
        let output = try await Self.answer("Depot.load", types: types, calls: "")

        #expect(output.contains("Shed.stock()"))
        #expect(output.contains("Barn.sweep()"))
        #expect(output.contains(":13  in host()  | Barn().load(4)\n    :14  in host()  | Stand().load(5)"), "\(output)")
        #expect(!output.contains("in Orchard.tend()"))
    }
}
