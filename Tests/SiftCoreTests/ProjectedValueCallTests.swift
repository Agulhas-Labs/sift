//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A call passing `$label:` to a parameter declared with a property wrapper `@T` constructs the wrapper through `T.init(projectedValue:)` at the call site, so `where` lists that call as one of its sites and never says "no callers" of an initializer called only there.
@Suite(.temporaryDirectories)
struct ProjectedValueCallTests {
    /// A wrapper with both initializers, parameters of each kind of callable declared with it, and a `$label:` call of each.
    static var source: String {
        """
        @propertyWrapper struct PV {
            var wrappedValue: Int
            init(wrappedValue: Int) { self.wrappedValue = wrappedValue }
            init(projectedValue: PV) { self = projectedValue }
            var projectedValue: PV { self }
        }
        func pv(@PV x: Int) -> Int { x }
        func labeled(@PV value x: Int) -> Int { x }
        struct Holder {
            init(@PV y: Int) {}
            func method(@PV z: Int) -> Int { z }
        }
        let stock = PV(wrappedValue: 5)
        func use() -> Int { pv($x: PV(wrappedValue: 2)) }
        func named() -> Int { labeled($value: stock) }
        func built() -> Holder { Holder($y: stock) }
        func sent(_ holder: Holder) -> Int { holder.method($z: stock) }
        func plain() -> Int { pv(x: 4) }
        """
    }

    /// A file that spells neither the wrapper nor an initializer, only a `$label:` call of a function whose parameter is declared with it.
    static var far: String {
        """
        func far() -> Int { pv($x: stock) }
        """
    }

    /// A committed git repo holding a package of `targets`, written as `.target(…)` entries, with `files`.
    static func repo(_ files: [String: String], targets: String = ".target(name: \"Probe\")") throws -> URL {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(
            """
            // swift-tools-version: 6.0
            import PackageDescription

            let package = Package(name: "Probe", targets: [\(targets)])
            """,
            to: "Package.swift",
            in: root
        )
        for (path, text) in files {
            try TestSources.write(text, to: path, in: root)
        }
        try TestSources.commitAll(in: root, message: "fixture")
        return root
    }

    /// The `where` answer for `symbol` over `root`, building it first where `built`, and read from a store that has finished loading whenever there is one.
    ///
    /// The wait is not keyed to `built`: a caller that built the package itself and then wrote a file again passes `false` to be answered stale, and its store must settle just the same. The budget is zero so that every call meets the store still loading, as a cold open does on a loaded machine; a lookup that skipped the wait would then read warming on every run rather than on an unlucky one.
    static func lookup(_ symbol: String, in root: URL, built: Bool) async throws -> String {
        if built {
            try TestSources.swiftBuild(packageAt: root)
        }
        let engine = try SiftEngine(directory: root)
        engine.openBudget = 0
        try await engine.awaitSemanticStore()
        let freshness = try await engine.ensureFresh()
        return try await engine.lookup(symbol: symbol, freshness: freshness)
    }

    /// The sites a lookup of `init(projectedValue:)` must list, one per `$label:` call.
    static var projectedSites: [String] {
        [
            "Sources/Probe/PV.swift:14  in use()",
            "Sources/Probe/PV.swift:15  in named()",
            "Sources/Probe/PV.swift:16  in built()",
            "Sources/Probe/PV.swift:17  in sent(_:)",
            "Sources/Probe/Far.swift:1  in far()",
        ]
    }

    /// With a fresh store, which records no call of `init(projectedValue:)` at a `$label:` call, each such call is listed beside the store's answer and "no callers" is not said.
    @Test
    func aProjectedArgumentIsListedBesideAFreshStore() async throws {
        let root = try Self.repo(["Sources/Probe/PV.swift": Self.source, "Sources/Probe/Far.swift": Self.far])
        let output = try await Self.lookup("PV.init(projectedValue:)", in: root, built: true)
        let sites = WhereAnswerRepetitionTests.sitesOnePerLine(output)

        #expect(output.contains("semantic: fresh"), "\(output)")
        #expect(!output.contains("no callers"), "\(output)")
        for site in Self.projectedSites {
            #expect(sites.split(separator: "\n").contains { $0.hasSuffix(site) }, "\(site) missing from\n\(output)")
        }
        #expect(!sites.contains("PV.swift:18"), "a plain argument calls init(wrappedValue:)\n\(output)")
        // The sites are read back as name-matched, never as resolved callers.
        #expect(!NameMatchedSites.linesOutside(answer: output).contains { $0.contains("PV.swift:14") }, "\(output)")
    }

    /// A `$label:` call is listed once under `init(projectedValue:)` and never under `init(wrappedValue:)`, which the store answers for itself.
    @Test
    func aProjectedArgumentIsNotListedForTheWrappedValueInitializer() async throws {
        let root = try Self.repo(["Sources/Probe/PV.swift": Self.source, "Sources/Probe/Far.swift": Self.far])
        let output = try await Self.lookup("PV.init", in: root, built: true)
        let sites = WhereAnswerRepetitionTests.sitesOnePerLine(output)

        #expect(sites.components(separatedBy: "Far.swift:1  in far()").count - 1 == 1, "\(output)")
        #expect(sites.components(separatedBy: "PV.swift:15  in named()").count - 1 == 1, "\(output)")
    }

    /// With no store, the name scan lists each `$label:` call as a site of `init(projectedValue:)`, a file that never spells the wrapper included.
    @Test
    func theNameScanListsAProjectedArgument() async throws {
        let root = try Self.repo(["Sources/Probe/PV.swift": Self.source, "Sources/Probe/Far.swift": Self.far])
        let output = try await Self.lookup("PV.init(projectedValue:)", in: root, built: false)
        let sites = WhereAnswerRepetitionTests.sitesOnePerLine(output)

        #expect(output.contains("syntactic call sites — by written name"), "\(output)")
        for site in Self.projectedSites {
            #expect(sites.split(separator: "\n").contains { $0.hasSuffix(site) }, "\(site) missing from\n\(output)")
        }
        #expect(!sites.contains("PV.swift:18"), "\(output)")
    }

    /// A `$label:` call of a function whose parameter is declared with another module's same-named wrapper is that wrapper's call, never lent to this one, so this one's answer stays "no callers".
    @Test
    func aSameNamedWrappersProjectedArgumentIsNotLent() async throws {
        let files = [
            "Sources/Other/PV.swift": """
            @propertyWrapper public struct PV {
                public var wrappedValue: Int
                public init(wrappedValue: Int) { self.wrappedValue = wrappedValue }
                public init(projectedValue: PV) { self = projectedValue }
                public var projectedValue: PV { self }
            }
            public func other(@PV x: Int) -> Int { x }
            public func call() -> Int { other($x: PV(wrappedValue: 1)) }
            """,
            "Sources/Probe/PV.swift": """
            @propertyWrapper struct PV {
                var wrappedValue: Int
                init(wrappedValue: Int) { self.wrappedValue = wrappedValue }
                init(projectedValue: PV) { self = projectedValue }
                var projectedValue: PV { self }
            }
            """,
        ]
        let root = try Self.repo(files, targets: ".target(name: \"Other\"), .target(name: \"Probe\", dependencies: [\"Other\"])")
        let output = try await Self.lookup("Probe.PV.init(projectedValue:)", in: root, built: true)

        #expect(output.contains("semantic: fresh"), "\(output)")
        #expect(output.contains("no callers"), "\(output)")
        #expect(!WhereAnswerRepetitionTests.sitesOnePerLine(output).contains("in call()"), "\(output)")
    }

    /// Two wrappers, same-named declarations whose parameters are declared with one or the other, and a `$x:` call of each.
    static var overloads: [String: String] {
        [
            "Sources/Probe/Wrappers.swift": """
            @propertyWrapper struct PV {
                var wrappedValue: Int
                init(wrappedValue: Int) { self.wrappedValue = wrappedValue }
                init(projectedValue: PV) { self = projectedValue }
                var projectedValue: PV { self }
            }
            @propertyWrapper struct QW {
                var wrappedValue: Int
                init(wrappedValue: Int) { self.wrappedValue = wrappedValue }
                init(projectedValue: QW) { self = projectedValue }
                var projectedValue: QW { self }
            }
            """,
            "Sources/Probe/Decls.swift": """
            struct A { func pv(@PV x: Int) -> Int { x } }
            struct B { func pv(@QW x: Int) -> Int { x } }
            func top(@PV x: Int) -> Int { x }
            func top(@QW x: Int, y: Int) -> Int { x }
            struct Holder { init(@PV x: Int) {} }
            struct Outer { struct In { init(@PV x: Int) {} } }
            """,
            "Sources/Probe/Calls.swift": """
            func calls() -> [Int] {
                [
                    A().pv($x: PV(wrappedValue: 1)),
                    B().pv($x: QW(wrappedValue: 1)),
                    top($x: QW(wrappedValue: 1), y: 4),
                    top($x: PV(wrappedValue: 1)),
                ]
            }
            func consume(_ holder: Holder) {}
            func make() { consume(\(WhereInitializerCallsTests.implied)($x: PV(wrappedValue: 3))) }
            """,
        ]
    }

    /// The `where` answers for each of `symbols` over `root`, from one engine once its store is fresh.
    ///
    /// Held to a zero budget for the reason the single lookup above is, so a missing wait fails every run.
    static func builtLookups(_ symbols: [String], in root: URL) async throws -> [String] {
        try TestSources.swiftBuild(packageAt: root)
        let engine = try SiftEngine(directory: root)
        engine.openBudget = 0
        try await engine.awaitSemanticStore()
        var answers: [String] = []
        for symbol in symbols {
            try await answers.append(engine.lookup(symbol: symbol, freshness: engine.ensureFresh()))
        }
        return answers
    }

    /// Whether `answer` lists a site at `line` of the calls file.
    static func lists(_ line: Int, in answer: String) -> Bool {
        WhereAnswerRepetitionTests.sitesOnePerLine(answer).split(separator: "\n").contains { $0.contains("Calls.swift:\(line)  ") }
    }

    /// With a fresh store, a `$x:` call goes only to the wrapper of the declaration the store records it calling, never to a same-named declaration's other wrapper.
    @Test
    func aProjectedArgumentGoesToTheWrapperOfTheDeclarationTheStoreRecords() async throws {
        let root = try Self.repo(Self.overloads)
        let answers = try await Self.builtLookups(["PV.init(projectedValue:)", "QW.init(projectedValue:)"], in: root)

        #expect(answers.allSatisfy { $0.contains("semantic: fresh") }, "\(answers)")
        #expect([3, 6].allSatisfy { Self.lists($0, in: answers[0]) } && ![4, 5].contains { Self.lists($0, in: answers[0]) }, "\(answers[0])")
        #expect([4, 5].allSatisfy { Self.lists($0, in: answers[1]) } && ![3, 6].contains { Self.lists($0, in: answers[1]) }, "\(answers[1])")
        #expect(!answers.contains { $0.contains("labels also reach") }, "the store said which declaration each call calls\n\(answers)")
    }

    /// With no store, full labels tell `top($x:)` from `top($x:y:)`, and a call whose labels reach two wrappers' declarations is listed under both, flagged.
    @Test
    func theNameScanTellsOverloadsApartByLabelsAndFlagsTheRest() async throws {
        let root = try Self.repo(Self.overloads)
        let first = try await Self.lookup("PV.init(projectedValue:)", in: root, built: false)
        let second = try await Self.lookup("QW.init(projectedValue:)", in: root, built: false)

        #expect(Self.lists(6, in: first) && !Self.lists(5, in: first), "\(first)")
        #expect(Self.lists(5, in: second) && !Self.lists(6, in: second), "\(second)")
        #expect(first.contains(":3  in calls() (labels also reach an overload declaring @QW)  | A().pv($x: PV(wrappedValue: 1)),\n    :4  in calls() (labels also reach an overload declaring @QW)  | B().pv($x: QW(wrappedValue: 1)),"), "\(first)")
        #expect(second.contains(":3  in calls() (labels also reach an overload declaring @PV)  | A().pv($x: PV(wrappedValue: 1)),\n    :4  in calls() (labels also reach an overload declaring @PV)  | B().pv($x: QW(wrappedValue: 1)),"), "\(second)")
    }

    /// A file declaring a wrapped parameter, written since the build, heads the answer stale and keeps its calls, never "no callers" under a fresh header.
    @Test
    func aStaleDeclaringFileIsJudgedAndItsCallsKept() async throws {
        let root = try Self.repo(Self.overloads)
        try TestSources.swiftBuild(packageAt: root)
        try TestSources.write("\n\n" + (Self.overloads["Sources/Probe/Decls.swift"] ?? ""), to: "Sources/Probe/Decls.swift", in: root)
        let output = try await Self.lookup("PV.init(projectedValue:)", in: root, built: false)

        #expect(output.contains("semantic: stale"), "\(output)")
        #expect(!output.contains("no callers"), "\(output)")
        #expect(Self.lists(6, in: output), "\(output)")
    }

    /// An implicit member's `init($x:)` call, which two same-wrapper initializers could each be, is listed once.
    @Test
    func aCallFoundUnderTwoInitializersIsListedOnce() async throws {
        let root = try Self.repo(Self.overloads)
        let output = try await Self.builtLookups(["PV.init(projectedValue:)"], in: root)[0]

        #expect(WhereAnswerRepetitionTests.sitesOnePerLine(output).components(separatedBy: "Calls.swift:10  ").count - 1 == 1, "\(output)")
    }

    /// A file of calls written since the build heads the answer stale and keeps its calls, marked, never "no callers" under a fresh header.
    @Test
    func aStaleCallingFileIsJudgedAndItsCallsKept() async throws {
        let root = try Self.repo(Self.overloads)
        try TestSources.swiftBuild(packageAt: root)
        try TestSources.write("\n" + (Self.overloads["Sources/Probe/Calls.swift"] ?? ""), to: "Sources/Probe/Calls.swift", in: root)
        let output = try await Self.lookup("PV.init(projectedValue:)", in: root, built: false)

        #expect(output.contains("semantic: stale"), "\(output)")
        #expect(!output.contains("no callers"), "\(output)")
        #expect(Self.lists(7, in: output), "\(output)")
        #expect(output.contains("in calls()  (file changed since last build)"), "\(output)")
    }

    /// A `$x:` call and a plain call of a same-named declaration on one line are told apart by where the store records each, so only the wrapper the `$x:` call's declaration is declared with lists the line.
    @Test
    func twoSameNamedCallsOnOneLineGoToTheirOwnWrappers() async throws {
        var files = Self.overloads
        files["Sources/Probe/Line.swift"] = """
        func oneLine(a: A, b: B) -> Int {
            let p = PV(wrappedValue: 2)
            return a.pv($x: p) + b.pv(x: 1)
        }
        """
        let root = try Self.repo(files)
        let answers = try await Self.builtLookups(["PV.init(projectedValue:)", "QW.init(projectedValue:)"], in: root)
        let lists = { (answer: String) in WhereAnswerRepetitionTests.sitesOnePerLine(answer).contains("Line.swift:3  ") }

        #expect(answers.allSatisfy { $0.contains("semantic: fresh") }, "\(answers)")
        #expect(lists(answers[0]), "\(answers[0])")
        #expect(!lists(answers[1]), "b.pv(x: 1) runs init(wrappedValue:)\n\(answers[1])")
    }
}
