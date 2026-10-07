//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// An initializer is called through its type — `Box(size: 2)` — rather than by its own name, and `where` lists those calls among its sites, by name with no store and from the store's references with one.
///
/// Scanned for the name `init` alone, the name scan found neither `Box(size: 2)` nor `Box.init(size:)` handed on, and answered "no call spelled" of an initializer called everywhere.
@Suite(.temporaryDirectories)
struct WhereInitializerCallsTests {
    /// The member an implicit initializer call is spelled with, joined here so this file's own source never writes the shorthand the linter forbids.
    static let implied = "." + "init"

    static var box: String {
        """
        class Box<Item> {
            let size: Int
            init(size: Int) { self.size = size }
            convenience init(width: Int, height: Int) {
                self.init(size: width * height)
            }
        }

        extension Box {
            static func unit() -> Box<Item> { Self.init(size: 1) }
        }
        """
    }

    static var uses: String {
        """
        final class Crate: Box<Int> {
            init() {
                super.init(size: 8)
            }
        }

        struct Depot {
            init(size: Int) {}
        }

        func take(_ box: Box<Int>) {}

        let plain = Box<Int>(size: 2)
        let named = Box<Int>\(implied)(size: 3)
        let typed: Box<Int> = \(implied)(size: 4)
        func make() -> Box<Int> { \(implied)(size: 5) }
        let handed = Box<Int>\(implied)(size:)
        let spread = Box<Int>(width: 1, height: 2)
        let other = Depot(size: 6)
        let elsewhere: Depot = \(implied)(size: 7)
        let untold = [take(\(implied)(size: 9))]
        """
    }

    static func lookup(_ symbol: String, in root: URL) async throws -> String {
        let engine = try SiftEngine(directory: root)
        let freshness = try await engine.ensureFresh()
        return try await engine.lookup(symbol: symbol, freshness: freshness)
    }

    static func repo() throws -> URL {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(box, to: "Sources/App/Box.swift", in: root)
        try TestSources.write(uses, to: "Sources/App/Uses.swift", in: root)
        try TestSources.commitAll(in: root, message: "fixture")
        return root
    }

    /// Every spelling of a call of the initializer is one of its sites: the type applied, generic or not, `T.init`, `self.init` and `Self.init` inside the type, `super.init` in a subclass, and `.init` where a declared type or a return type says which.
    @Test
    func everySpellingOfAnInitializerCallIsListed() async throws {
        let output = try await Self.lookup("Box.init(size:)", in: Self.repo())

        #expect(!output.contains("no call spelled"), "\(output)")
        #expect(output.contains("syntactic call sites — by written name"), "\(output)")
        #expect(WhereAnswerRepetitionTests.sitesOnePerLine(output).contains("Sources/App/Box.swift:5  in Box.init(width:height:)"), "\(output)")
        #expect(WhereAnswerRepetitionTests.sitesOnePerLine(output).contains("Sources/App/Box.swift:10  in Box.unit()"), "\(output)")
        #expect(WhereAnswerRepetitionTests.sitesOnePerLine(output).contains("Sources/App/Uses.swift:3  in Crate.init()"), "\(output)")
        #expect(WhereAnswerRepetitionTests.sitesOnePerLine(output).contains("Sources/App/Uses.swift:13  in plain"), "\(output)")
        #expect(WhereAnswerRepetitionTests.sitesOnePerLine(output).contains("Sources/App/Uses.swift:14  in named"), "\(output)")
        #expect(WhereAnswerRepetitionTests.sitesOnePerLine(output).contains("Sources/App/Uses.swift:15  in typed"), "\(output)")
        #expect(WhereAnswerRepetitionTests.sitesOnePerLine(output).contains("Sources/App/Uses.swift:16  in make()"), "\(output)")
    }

    /// `Box.init(size:)` handed on unapplied is a reference to the initializer, listed with its calls as a function's is.
    @Test
    func anInitializerHandedOnUnappliedIsListed() async throws {
        let output = try await Self.lookup("Box.init(size:)", in: Self.repo())

        #expect(WhereAnswerRepetitionTests.sitesOnePerLine(output).contains("Sources/App/Uses.swift:17  in handed"), "\(output)")
    }

    /// With two initializers on the type, labels decide which one a call belongs to, as they do for overloaded functions.
    @Test
    func labelsDecideWhichInitializerASiteBelongsTo() async throws {
        let root = try Self.repo()
        let sized = try await Self.lookup("Box.init(size:)", in: root)
        let spread = try await Self.lookup("Box.init(width:height:)", in: root)

        #expect(sized.contains("\"Box.init\" (9 call sites by name, 8 with the labels (size:), in 2 files"), "\(sized)")
        #expect(!WhereStoreSiteTextTests.located(sized).contains("Uses.swift:18"), "\(sized)")
        #expect(spread.contains("\"Box.init\" (9 call sites by name, 1 with the labels (width:height:), in 1 file"), "\(spread)")
        #expect(WhereAnswerRepetitionTests.sitesOnePerLine(spread).contains("Sources/App/Uses.swift:18  in spread"), "\(spread)")
    }

    /// The type named without a call — an annotation — is no site, and neither is another type's initializer, applied or implied.
    @Test
    func theTypeWrittenWithoutACallOrAnotherTypesInitializerIsNotListed() async throws {
        let output = try await Self.lookup("Box.init(size:)", in: Self.repo())

        #expect(!WhereStoreSiteTextTests.located(output).contains("Uses.swift:11"), "\(output)")
        #expect(!WhereStoreSiteTextTests.located(output).contains("Uses.swift:19"), "\(output)")
        #expect(!WhereStoreSiteTextTests.located(output).contains("Uses.swift:20"), "\(output)")
    }

    /// An implicit `.init` whose type the scan cannot tell is not listed, since it may be any type's; with nothing listed it is counted beside the answer, so "no call" is never read as unused.
    @Test
    func anImplicitInitializerOfAnUntoldTypeIsCountedBesideTheList() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(
            """
            struct Box {
                init(size: Int) {}
            }
            func take(_ box: Box) {}
            let untold = [take(\(Self.implied)(size: 9))]
            let spread = [take(\(Self.implied)(width: 9))]
            """,
            to: "Sources/App/Box.swift",
            in: root
        )
        try TestSources.commitAll(in: root, message: "fixture")

        let output = try await Self.lookup("Box.init(size:)", in: root)

        #expect(output.contains("no call spelled \"Box.init\" anywhere in the working tree"), "\(output)")
        #expect(output.contains("but an implicit .init is called once with those labels on a type the scan cannot tell"), "\(output)")
        #expect(WhereAnswerRepetitionTests.sitesOnePerLine(output).contains("  Sources/App/Box.swift:5  in untold"), "\(output)")
        #expect(!WhereStoreSiteTextTests.located(output).contains("Box.swift:6"), "\(output)")
    }

    /// The case that was answered falsely: a file holding only the type applied and the initializer handed on.
    @Test
    func theTypeAppliedAndTheInitializerHandedOnAreBothListedByName() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(
            """
            struct Box {
                let size: Int
                init(size: Int) { self.size = size }
            }
            let make = Box.init(size:)
            let b = Box(size: 2)
            """,
            to: "Sources/App/Box.swift",
            in: root
        )
        try TestSources.commitAll(in: root, message: "fixture")

        let output = try await Self.lookup("Box.init", in: root)

        #expect(output.contains("\"Box.init\" (2 call sites in 1 file"), "\(output)")
        #expect(WhereAnswerRepetitionTests.sitesOnePerLine(output).contains("Sources/App/Box.swift:5  in make"), "\(output)")
        #expect(WhereAnswerRepetitionTests.sitesOnePerLine(output).contains("Sources/App/Box.swift:6  in b"), "\(output)")
    }

    /// `sift diff` names a changed initializer's callers by the same scan, so its calls through the type are among them.
    @Test
    func aDiffListsAChangedInitializersCallsThroughItsType() async throws {
        let root = try Self.repo()
        try TestSources.write(
            Self.box.replacingOccurrences(of: "init(size: Int) {", with: "init(size: Int, depth: Int = 1) {"),
            to: "Sources/App/Box.swift",
            in: root
        )

        let output = try await DiffEngineTests.diff(root)

        #expect(output.contains("Box.init(size:) — name-matched on \"Box\""), "\(output)")
        #expect(WhereAnswerRepetitionTests.sitesOnePerLine(output).contains("Sources/App/Uses.swift:3  in Crate.init()"), "\(output)")
        #expect(WhereAnswerRepetitionTests.sitesOnePerLine(output).contains("Sources/App/Uses.swift:13  in plain"), "\(output)")
        #expect(WhereAnswerRepetitionTests.sitesOnePerLine(output).contains("Sources/App/Uses.swift:17  in handed"), "\(output)")
        #expect(!WhereStoreSiteTextTests.located(output).contains("Uses.swift:19"), "\(output)")
    }

    /// With a fresh store, the initializer's callers are its calls through the type and its references, each marked as what it is.
    @Test
    func theStoresCallersOfAnInitializerIncludeEverySpelling() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(
            """
            // swift-tools-version: 6.0
            import PackageDescription

            let package = Package(name: "Gizmo", targets: [.target(name: "GizmoCore")])
            """,
            to: "Package.swift",
            in: root
        )
        try TestSources.write(
            """
            struct Box {
                let size: Int
                init(size: Int) { self.size = size }
                init(width: Int, height: Int) { self.init(size: width * height) }
            }
            let make = Box.init(size:)
            let b = Box(size: 2)
            let c = Box.init(size: 3)
            let d: Box = \(Self.implied)(size: 4)
            let e = Box(width: 1, height: 2)
            func both() -> [Box] { [Box(size: 5)] + [6].map(Box.init(size:)) }
            """,
            to: "Sources/GizmoCore/Box.swift",
            in: root
        )
        try TestSources.commitAll(in: root, message: "buildable fixture")
        try TestSources.swiftBuild(packageAt: root)
        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()
        let freshness = try await engine.ensureFresh()

        let output = try await engine.lookup(symbol: "Box.init(size:)", freshness: freshness)
        let lines = output.split(separator: "\n")

        #expect(output.contains("semantic: fresh"), "\(output)")
        #expect(output.contains("callers of GizmoCore.Box.init(size:) (6):"), "\(output)")
        #expect(lines.contains("    :4  init(width:height:)  | init(width: Int, height: Int) { self.init(size: width * height) }"), "\(output)")
        #expect(lines.contains("    :6  make — referenced, not called  | let make = Box.init(size:)"), "\(output)")
        #expect(lines.contains("    :7  b  | let b = Box(size: 2)"), "\(output)")
        #expect(lines.contains("    :8  c  | let c = Box.init(size: 3)"), "\(output)")
        #expect(lines.contains("    :9  d  | let d: Box = " + ".in" + "it(size: 4)"), "\(output)")
        // A line that calls the initializer and hands it on is a caller, never marked as one that does not call it.
        #expect(lines.contains("    :11  both()  | func both() -> [Box] { [Box(size: 5)] + [6].map(Box.init(size:)) }"), "\(output)")
        #expect(!WhereStoreSiteTextTests.located(output).contains("Box.swift:10"), "\(output)")
    }

    /// A call matching none of a type's declared initializers can only be one the compiler wrote — here the memberwise `Depot(first:second:)` beside a declared `init(spelled:)` — so a bare query keeps it instead of dropping it.
    @Test
    func aCallMatchingNoDeclaredInitializerIsKeptUnderABareQuery() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(
            """
            struct Depot {
                let first: Int
                let second: Int
            }
            extension Depot {
                init(spelled: String) { self.init(first: 0, second: 0) }
            }
            let made = Depot(first: 1, second: 2)
            """,
            to: "Sources/App/Depot.swift",
            in: root
        )
        try TestSources.commitAll(in: root, message: "fixture")

        let output = try await Self.lookup("Depot.init", in: root)

        #expect(WhereAnswerRepetitionTests.sitesOnePerLine(output).contains("Sources/App/Depot.swift:8  in made"), "\(output)")
    }

    static var wrapper: String {
        """
        @propertyWrapper struct Wrap {
            var wrappedValue: Int
            init(wrappedValue: Int) { self.wrappedValue = wrappedValue }
            init(wrappedValue: Int, other: Int) { self.wrappedValue = wrappedValue + other }
        }

        struct Holder {
            @Wrap var x: Int = 1
            @Wrap(wrappedValue: 1, other: 2) var y: Int
        }
        """
    }

    /// A property wrapper written on a stored property calls the wrapper's initializer, so a wrapper used only that way is never answered "no call".
    @Test
    func aPropertyWrapperOnAStoredPropertyIsACallOfItsInitializer() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(Self.wrapper, to: "Sources/App/Wrap.swift", in: root)
        try TestSources.commitAll(in: root, message: "fixture")

        let output = try await Self.lookup("Wrap.init", in: root)

        #expect(!output.contains("no call spelled"), "\(output)")
        #expect(output.contains("\"Wrap.init\" (2 call sites in 1 file"), "\(output)")
        #expect(WhereAnswerRepetitionTests.sitesOnePerLine(output).contains("Sources/App/Wrap.swift:8  in Holder.x"), "\(output)")
        #expect(WhereAnswerRepetitionTests.sitesOnePerLine(output).contains("Sources/App/Wrap.swift:9  in Holder.y"), "\(output)")
    }

    /// A wrapper's arguments are the ones it is called with: an initial value is passed as `wrappedValue:`, ahead of any written in parentheses.
    @Test
    func aPropertyWrappersArgumentsDecideWhichInitializerItCalls() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(Self.wrapper, to: "Sources/App/Wrap.swift", in: root)
        try TestSources.commitAll(in: root, message: "fixture")

        let plain = try await Self.lookup("Wrap.init(wrappedValue:)", in: root)
        let both = try await Self.lookup("Wrap.init(wrappedValue:other:)", in: root)

        #expect(WhereAnswerRepetitionTests.sitesOnePerLine(plain).contains("Sources/App/Wrap.swift:8  in Holder.x"), "\(plain)")
        #expect(!WhereStoreSiteTextTests.located(plain).contains("Wrap.swift:9"), "\(plain)")
        #expect(WhereAnswerRepetitionTests.sitesOnePerLine(both).contains("Sources/App/Wrap.swift:9  in Holder.y"), "\(both)")
        #expect(!WhereStoreSiteTextTests.located(both).contains("Wrap.swift:8"), "\(both)")
    }

    /// A result builder on a function, a parameter or a computed property builds a body rather than calling an initializer, so none of them is a site.
    @Test
    func aResultBuilderAttributeIsNoCallOfItsInitializer() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(
            """
            @resultBuilder struct Build {
                init() {}
                static func buildBlock(_ parts: Int...) -> Int { parts.count }
            }
            @Build func make() -> Int { 1 }
            func take(@Build _ body: () -> Int) {}
            struct Holder {
                @Build var total: Int { 1 }
            }
            """,
            to: "Sources/App/Build.swift",
            in: root
        )
        try TestSources.commitAll(in: root, message: "fixture")

        let output = try await Self.lookup("Build.init", in: root)

        #expect(output.contains("no call spelled \"Build.init\" anywhere in the working tree"), "\(output)")
    }

    /// An implicit `.init` returned under `try` or `await`, or written as an element of an array declared of the type, is the type's; one still untold is counted beside a list that is not empty.
    @Test
    func anImplicitInitializerUnderTryOrInAnArrayIsListedAndAnUntoldOneCountedBesideTheList() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(
            """
            struct Box {
                init(size: Int) {}
            }
            func take(_ box: Box) {}
            func thrower() throws -> Box {
                return try \(Self.implied)(size: 9)
            }
            func later() async -> Box { await \(Self.implied)(size: 3) }
            let arr: [Box] = [\(Self.implied)(size: 6)]
            let untold = [take(\(Self.implied)(size: 10))]
            """,
            to: "Sources/App/Box.swift",
            in: root
        )
        try TestSources.commitAll(in: root, message: "fixture")

        let output = try await Self.lookup("Box.init", in: root)

        #expect(output.contains("\"Box.init\" (3 call sites in 1 file"), "\(output)")
        #expect(WhereAnswerRepetitionTests.sitesOnePerLine(output).contains("Sources/App/Box.swift:6  in thrower()"), "\(output)")
        #expect(WhereAnswerRepetitionTests.sitesOnePerLine(output).contains("Sources/App/Box.swift:8  in later()"), "\(output)")
        #expect(WhereAnswerRepetitionTests.sitesOnePerLine(output).contains("Sources/App/Box.swift:9  in arr"), "\(output)")
        #expect(output.contains("but an implicit .init is called once with those labels on a type the scan cannot tell"), "\(output)")
        #expect(WhereAnswerRepetitionTests.sitesOnePerLine(output).contains("  Sources/App/Box.swift:10  in untold"), "\(output)")
    }
}

// MARK: - Which attributes call a property wrapper's initializer

extension WhereInitializerCallsTests {
    /// A wrapped property with no initial value and no arguments is set through the memberwise initializer's `wrappedValue:`, so its labels are unknown and it is never narrowed away.
    @Test
    func aWrappedPropertyWithNoInitialValueIsKeptUnderEveryInitializersLabels() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(
            """
            @propertyWrapper struct Keep {
                var wrappedValue: Int
                init(wrappedValue: Int) { self.wrappedValue = wrappedValue }
                init() { wrappedValue = 0 }
            }
            struct Shelf {
                @Keep var z: Int
            }
            """,
            to: "Sources/App/Keep.swift",
            in: root
        )
        try TestSources.commitAll(in: root, message: "fixture")

        let output = try await Self.lookup("Keep.init(wrappedValue:)", in: root)

        #expect(!output.contains("no call spelled"), "\(output)")
        #expect(WhereAnswerRepetitionTests.sitesOnePerLine(output).contains("Sources/App/Keep.swift:7  in Shelf.z"), "\(output)")
    }

    /// A property wrapper on a function's or a closure's parameter is called with each argument passed, so a wrapper used only there is never answered "no call".
    @Test
    func aPropertyWrapperOnAParameterIsACallOfItsInitializer() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(
            """
            @propertyWrapper struct Clamp {
                var wrappedValue: Int
                init(wrappedValue: Int) { self.wrappedValue = min(wrappedValue, 10) }
            }
            func clamped(@Clamp _ x: Int) -> Int { x }
            let size = clamped(3)
            let scale = { (@Clamp x: Int) in x }
            """,
            to: "Sources/App/Clamp.swift",
            in: root
        )
        try TestSources.commitAll(in: root, message: "fixture")

        let output = try await Self.lookup("Clamp.init(wrappedValue:)", in: root)

        #expect(!output.contains("no call spelled"), "\(output)")
        #expect(WhereAnswerRepetitionTests.sitesOnePerLine(output).contains("Sources/App/Clamp.swift:5  in clamped(_:)"), "\(output)")
        #expect(WhereAnswerRepetitionTests.sitesOnePerLine(output).contains("Sources/App/Clamp.swift:7  in scale"), "\(output)")
    }

    /// An attribute naming a type that is no property wrapper — a user type sharing a name with a wrapper or a macro another module declares — is no call of its initializer.
    @Test
    func anAttributeNamingATypeThatIsNoPropertyWrapperIsNoSite() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(
            """
            struct State {
                init(v: Int) {}
            }
            struct Screen {
                @State var count = 0
                @State(initialValue: 1) var total: Int
                let made = State(v: 1)
            }
            """,
            to: "Sources/App/State.swift",
            in: root
        )
        try TestSources.commitAll(in: root, message: "fixture")

        let output = try await Self.lookup("State.init", in: root)

        #expect(output.contains("\"State.init\" (1 call site in 1 file"), "\(output)")
        #expect(WhereAnswerRepetitionTests.sitesOnePerLine(output).contains("Sources/App/State.swift:7  in Screen.made"), "\(output)")
        #expect(!WhereStoreSiteTextTests.located(output).contains("State.swift:5"), "\(output)")
        #expect(!WhereStoreSiteTextTests.located(output).contains("State.swift:6"), "\(output)")
    }

    /// A wrapper's attribute qualified by a name that spells no owner of the wrapper is kept and noted, not dropped: a typealias of the owner makes it the owner's own.
    @Test
    func anAttributeQualifiedByAnotherNameIsKeptAndNoted() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(
            """
            // swift-tools-version: 6.0
            import PackageDescription

            let package = Package(name: "App", targets: [.target(name: "App")])
            """,
            to: "Package.swift",
            in: root
        )
        try TestSources.write(
            """
            enum Outer {
                @propertyWrapper struct State {
                    var wrappedValue: Int
                    init(wrappedValue: Int) { self.wrappedValue = wrappedValue }
                }
            }
            struct Screen {
                @SwiftUI.State var count = 0
                @Outer.State var total = 1
                @App.Outer.State var depth = 2
            }
            """,
            to: "Sources/App/State.swift",
            in: root
        )
        try TestSources.commitAll(in: root, message: "fixture")

        let output = try await Self.lookup("State.init", in: root)

        #expect(output.contains("\"State.init\" (3 call sites by name, 1 written as an attribute behind a qualifier that spells no owner of it, kept"), "\(output)")
        #expect(!output.contains("of another type named State dropped"), "\(output)")
        #expect(WhereAnswerRepetitionTests.sitesOnePerLine(output).contains("Sources/App/State.swift:8  in Screen.count"), "\(output)")
        #expect(WhereAnswerRepetitionTests.sitesOnePerLine(output).contains("Sources/App/State.swift:9  in Screen.total"), "\(output)")
        #expect(WhereAnswerRepetitionTests.sitesOnePerLine(output).contains("Sources/App/State.swift:10  in Screen.depth"), "\(output)")
    }

    /// `sift diff` counts an implicit `.init` of an untold type beside a changed initializer without narrowing it by labels, so it does not say it did.
    @Test
    func aDiffCountsAnUntoldImplicitInitializerWithoutClaimingItsLabels() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(
            """
            struct Box {
                init(size: Int) {}
            }
            func take(_ box: Box) {}
            let untold = [take(\(Self.implied)(size: 9))]
            """,
            to: "Sources/App/Box.swift",
            in: root
        )
        try TestSources.commitAll(in: root, message: "fixture")
        try TestSources.write(
            """
            struct Box {
                init(size: Int, depth: Int = 1) {}
            }
            func take(_ box: Box) {}
            let untold = [take(\(Self.implied)(size: 9))]
            """,
            to: "Sources/App/Box.swift",
            in: root
        )

        let output = try await DiffEngineTests.diff(root)

        #expect(output.contains("but an implicit .init is called once on a type the scan cannot tell"), "\(output)")
        #expect(!output.contains("with those labels"), "\(output)")
    }
}
