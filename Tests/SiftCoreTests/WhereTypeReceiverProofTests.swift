//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A qualified query drops a site written on a type's name as another type's only where a tree declaration of that name is proven to be what the site writes: visible from it, with every supertype held, and no value of the name in the way.
///
/// Each fixture typechecks with swiftc as module App.
@Suite(.temporaryDirectories)
struct WhereTypeReceiverProofTests {
    private static var package: String {
        """
        // swift-tools-version: 6.0
        import PackageDescription

        let package = Package(name: "App", targets: [.target(name: "App"), .target(name: "Kit")])
        """
    }

    private static var boundUse: String {
        """
        import SwiftUI

        struct Depot {
            var stock = 0
        }
        struct Row {
            func bound(_ depot: Depot) -> Int { Binding(get: { depot }, set: { _ in }).stock.wrappedValue }
        }
        """
    }

    /// Each way a tree type named like the framework's `Binding` stays out of sight of the site, by the files that declare it.
    private static let unseenBindings: [[String: String]] = [
        ["Sources/App/Uses.swift": boundUse, "Sources/App/Hidden.swift": "private struct Binding {\n    let key: String\n}\n"],
        [
            "Sources/App/Uses.swift": boundUse,
            "Sources/App/Linux.swift": "#if os(Linux)\nstruct Binding<Value> {\n    let key: String\n}\n#endif\n",
        ],
        ["Package.swift": package, "Sources/App/Uses.swift": boundUse, "Sources/Kit/Binding.swift": "struct Binding<Value> {\n    let key: String\n}\n"],
        [
            "Sources/App/Uses.swift": boundUse,
            "Sources/App/Shortcut.swift": """
            enum Shortcut {
                struct Binding<Value> {
                    let key: String
                }
                static func held() -> Int { Binding<Int>(key: "s").key.count }
            }
            """,
        ],
    ]

    private static var dependencySupertypes: String {
        """
        import Kit

        struct Depot {
            var stock = 0
        }
        struct Shelf: Forwarding {
            var wrapped: Depot { Depot() }
        }
        final class Bin: Holder<Depot> {
            init() { super.init(Depot()) }
        }
        struct Crate {
            var stock: Int { 1 }
        }
        struct Row {
            func shelved() -> Int { Shelf().stock }
            func binned() -> Int { Bin().stock }
            func crated() -> Int { Crate().stock }
        }
        """
    }

    /// Each way a tree type named like a plain framework type, with a supertype only a dependency declares, stays out of sight of the site — nested in another type, or under `#if` — by the function holding the site.
    private static let hiddenForwarders: [String: String] = [
        "Outer.nested()": """
        import Kit

        struct Depot {
            var stock = 0
        }
        enum Outer {
            struct Data: Forwarding {
                var target: Depot { Depot() }
            }
            static func nested() -> Int { Data().stock }
        }
        """,
        "Outer.conditional()": """
        import Kit

        struct Depot {
            var stock = 0
        }
        #if os(macOS)
        struct Result: Forwarding {
            var target: Depot { Depot() }
        }
        #endif
        enum Outer {
            static func conditional() -> Int { Result().stock }
        }
        """,
    ]

    private static var valuesNamedLikeTypes: String {
        """
        struct Depot {
            var stock = 0
        }
        struct Other {
            let key: String
        }
        typealias Factory = () -> Depot
        struct Row {
            func param(Other: Factory) -> Int { Other().stock }
            func plain(Other: Depot) -> Int { Other.stock }
            func local() -> Int { let Other = Depot(); return Other.stock }
            func closure() -> [Int] { [Depot()].map { Other in Other.stock } }
            func made() -> Int { func Other() -> Depot { Depot() }; return Other().stock }
        }
        """
    }

    private static var membersNamedLikeTypes: String {
        """
        struct Orchard {
            init(_ count: Int) {}
            func load() -> Int { 2 }
        }
        enum Depot {
            case Orchard(Int)
            case Annex
            func load() -> Int { 1 }
            static func direct() -> Int { Orchard(1).load() }
        }
        struct Annex {
            func load() -> Int { 4 }
        }
        extension Depot {
            static func bare() -> Int { Annex.load() }
        }
        struct Calls {
            static func Orchard() -> Depot { .Annex }
            static func use() -> Int { Orchard().load() }
        }
        """
    }

    private static var qualifiedFrameworkName: String {
        """
        import SwiftUI

        struct Depot {
            var stock = 0
        }
        struct Binding<Value> {
            let key: String
        }
        struct Row {
            func bound(_ depot: Depot) -> Int { SwiftUI.Binding(get: { depot }, set: { _ in }).stock.wrappedValue }
        }
        """
    }

    private static func answer(_ files: [String: String], query: String = "Depot.stock") async throws -> String {
        let root = try TestSources.makeTempRepo()
        for (path, source) in files {
            try TestSources.write(source, to: path, in: root)
        }
        try TestSources.commitAll(in: root, message: "fixture")
        return try await CallSiteHeadingTests.lookup(query, in: root)
    }

    /// A same-named tree type the site cannot see — private to another file, under `#if`, internal to another target, or nested in a type the site is not in — leaves the written name the framework's, which may hand on the member.
    @Test(arguments: unseenBindings.indices)
    func aTypeOutOfSightIsNotAnotherType(fixture: Int) async throws {
        let output = try await Self.answer(Self.unseenBindings[fixture])

        #expect(output.contains("in Row.bound(_:)"), "\(output)")
    }

    /// A tree type whose supertype only a dependency declares may inherit a dynamic member subscript from it, so a site written on it stays listed; one with no supertype is another type's.
    @Test
    func aTypeWithASupertypeOutsideTheTreeIsNotAnotherType() async throws {
        let output = try await Self.answer(["Sources/App/Uses.swift": Self.dependencySupertypes])

        #expect(output.contains("in Row.shelved()"), "\(output)")
        #expect(output.contains("in Row.binned()"), "\(output)")
        #expect(!output.contains("in Row.crated()"), "\(output)")
    }

    /// A type named like a plain framework type that the site cannot see, but whose supertype only a dependency declares, may be what the site writes and inherit a dynamic member subscript, so the site stays listed.
    @Test(arguments: hiddenForwarders.keys.sorted())
    func aHiddenTypeWithASupertypeOutsideTheTreeIsNotAnotherType(site: String) async throws {
        let output = try await Self.answer(["Sources/App/Uses.swift": Self.hiddenForwarders[site, default: ""]])

        #expect(output.contains("in \(site)"), "\(output)")
    }

    /// A parameter, a local value, a closure parameter or a local function named like a tree type hides the type, so a site written on it stays listed.
    @Test
    func aValueNamedLikeATypeIsNotThatType() async throws {
        let output = try await Self.answer(["Sources/App/Uses.swift": Self.valuesNamedLikeTypes])

        for member in ["Row.param(Other:)", "Row.plain(Other:)", "Row.local()", "Row.closure()", "Row.made()"] {
            #expect(output.contains("in \(member)"), "\(member)\n\(output)")
        }
    }

    /// An enum case or a function the tree names like a type may build or be the owner, so a site written on the name stays listed.
    @Test
    func aMemberNamedLikeATypeIsNotThatType() async throws {
        let output = try await Self.answer(["Sources/App/Calls.swift": Self.membersNamedLikeTypes], query: "Depot.load")

        for member in ["Depot.direct()", "Depot.bare()", "Calls.use()"] {
            #expect(output.contains("in \(member)"), "\(member)\n\(output)")
        }
    }

    /// A name qualified by a module the tree does not declare is that module's type, not the tree's type of the name, so the site stays listed.
    @Test
    func aModuleQualifiedNameIsNotTheTreeType() async throws {
        let output = try await Self.answer(["Sources/App/Uses.swift": Self.qualifiedFrameworkName])

        #expect(output.contains("in Row.bound(_:)"), "\(output)")
    }
}
