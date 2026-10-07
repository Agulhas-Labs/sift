//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore
import Testing

/// A wrapper's initializer refused as stale beside one the store answers lists no site twice.
///
/// The name scan standing in for the refused initializer finds every site spelled with the type's name, including those the store's answer for the other initializer already lists, so those are counted there rather than listed again.
@Suite(.temporaryDirectories)
struct ProjectedValueInitCallerTests {
    /// A wrapper written on two functions' parameters and built once directly, with a second initializer declared in a file of its own.
    static var clamp: [String: String] {
        [
            "Sources/Probe/Clamp.swift": """
            @propertyWrapper struct Clamp {
                var wrappedValue: Int
                init(wrappedValue: Int) { self.wrappedValue = wrappedValue }
            }
            func low(@Clamp _ x: Int) -> Int { x }
            func high(@Clamp _ x: Int) -> Int { x }
            func calls() -> Int { low(1) + high(2) }
            func made() -> Clamp { Clamp(wrappedValue: 3) }
            """,
            "Sources/Probe/More.swift": """
            extension Clamp {
                init(wrappedValue: Int, step: Int) { self.wrappedValue = wrappedValue * step }
            }
            """,
        ]
    }

    /// A wrapper written on a parameter a call passes a projected argument to, with a third initializer declared in a file of its own.
    static var projected: [String: String] {
        [
            "Sources/Probe/Clamp.swift": """
            @propertyWrapper struct Clamp {
                var wrappedValue: Int
                init(wrappedValue: Int) { self.wrappedValue = wrappedValue }
                init(projectedValue: Clamp) { self = projectedValue }
                var projectedValue: Clamp { self }
            }
            func pv(@Clamp x: Int) -> Int { x }
            let stock = Clamp(wrappedValue: 5)
            func use() -> Int { pv($x: stock) }
            """,
            "Sources/Probe/More.swift": """
            extension Clamp {
                init(wrappedValue: Int, step: Int) { self.wrappedValue = wrappedValue * step }
            }
            """,
        ]
    }

    /// A wrapper with two initializers in its own declaration and a third in a file of its own, called twice from a file of calls.
    static var edited: [String: String] {
        [
            "Sources/Probe/Clamp.swift": """
            @propertyWrapper struct Clamp {
                var wrappedValue: Int
                init(wrappedValue: Int) { self.wrappedValue = wrappedValue }
                init(projectedValue: Clamp) { self = projectedValue }
                var projectedValue: Clamp { self }
            }
            """,
            "Sources/Probe/More.swift": """
            extension Clamp {
                init(wrappedValue: Int, step: Int) { self.wrappedValue = wrappedValue * step }
            }
            """,
            "Sources/Probe/Use.swift": use(spelling: "Clamp(wrappedValue: 3)"),
        ]
    }

    /// A file of calls whose fourth line is `spelling` and whose fifth calls the first initializer.
    static func use(spelling: String) -> String {
        """
        func use() -> Int {
            let a = 1
            let b = 2
            let c = \(spelling)
            let d = Clamp(wrappedValue: 4)
            return a + b + c.wrappedValue + d.wrappedValue
        }
        """
    }

    /// The `where` answer for `symbol` over a built package holding `files`, after the file declaring the second initializer is written again since the build.
    static func staleLookup(_ symbol: String, files: [String: String], thenWriting later: [String: String] = [:]) async throws -> String {
        let root = try ProjectedValueCallTests.repo(files)
        try TestSources.swiftBuild(packageAt: root)
        try TestSources.write("\n" + (files["Sources/Probe/More.swift"] ?? ""), to: "Sources/Probe/More.swift", in: root)
        for (path, text) in later {
            try TestSources.write(text, to: path, in: root)
        }
        let answer = try await ProjectedValueCallTests.lookup(symbol, in: root, built: false)
        return WhereAnswerRepetitionTests.sitesOnePerLine(answer)
    }

    /// How many times `text` appears in `output`.
    static func count(of text: String, in output: String) -> Int {
        output.components(separatedBy: text).count - 1
    }

    /// The attribute sites listed beside the store's answer for one initializer are not listed again for the refused one.
    @Test
    func anAttributeSiteListedBesideTheStoreIsNotListedAgain() async throws {
        let output = try await Self.staleLookup("Clamp.init", files: Self.clamp)

        #expect(output.contains("semantic REFUSED"), "\(output)")
        #expect(Self.count(of: "Clamp.swift:5  in low(_:)", in: output) == 1, "\(output)")
        #expect(Self.count(of: "Clamp.swift:6  in high(_:)", in: output) == 1, "\(output)")
        #expect(output.contains("listed above"), "\(output)")
    }

    /// A call the store records under one initializer is not listed again by name for the refused one.
    @Test
    func aCallTheStoreRecordsIsNotListedAgain() async throws {
        let output = try await Self.staleLookup("Clamp.init", files: Self.clamp)

        #expect(output.contains("callers of Probe.Clamp.init(wrappedValue:)"), "\(output)")
        #expect(Self.count(of: "Clamp.swift:8", in: WhereStoreSiteTextTests.located(output)) == 1, "\(output)")
    }

    /// A projected argument listed beside the store's answer for the projected-value initializer is not listed again for a refused one.
    ///
    /// The parameter's attribute, which the store records as a call at the attribute's own name, is listed once, as the store's caller, and never again by name.
    @Test
    func aProjectedArgumentListedBesideTheStoreIsNotListedAgain() async throws {
        let output = try await Self.staleLookup("Clamp.init", files: Self.projected)

        #expect(output.contains("semantic REFUSED"), "\(output)")
        #expect(Self.count(of: "Clamp.swift:9  in use()", in: output) == 1, "\(output)")
        #expect(Self.count(of: "Clamp.swift:7  pv(x:)", in: WhereStoreSiteTextTests.located(output)) == 1, "\(output)")
        #expect(Self.count(of: "Clamp.swift:7", in: WhereStoreSiteTextTests.located(output)) == 1, "\(output)")
    }

    /// A call the store recorded before its file was edited into a call of the refused initializer is still listed.
    @Test
    func aCallInAFileEditedSinceTheBuildIsNeverHiddenAsListed() async throws {
        let later = ["Sources/Probe/Use.swift": Self.use(spelling: "Clamp(wrappedValue: 3, step: 5)")]
        let output = try await Self.staleLookup("Clamp.init", files: Self.edited, thenWriting: later)

        #expect(output.contains("semantic REFUSED"), "\(output)")
        #expect(Self.count(of: "Use.swift:4  in use()", in: output) == 1, "\(output)")
        // The call on the next line reaches only the initializer the store answers, and is listed under it, since
        // the store's row for the edited file no longer lines up with it.
        #expect(Self.count(of: "Use.swift:5  in use()", in: output) == 1, "\(output)")
        #expect(Self.count(of: "Use.swift:5  in use()", in: Self.text(below: Self.reachingWrappedValue, in: output)) == 1, "\(output)")
        #expect(output.contains("1 whose labels reach only init(wrappedValue:)"), "\(output)")
    }

    /// The sub-heading the sites reaching only the wrapped-value initializer are listed under.
    static var reachingWrappedValue: String {
        "reaching only init(wrappedValue:) by their labels, with no line of their own above:"
    }

    /// The part of `output` after the first `heading`, or nothing where `heading` is absent.
    static func text(below heading: String, in output: String) -> String {
        output.components(separatedBy: heading).dropFirst().joined(separator: heading)
    }

    /// The count of sites already listed and the wording naming the spelling are stated exactly.
    @Test
    func theListedAboveCountAndWordingAreExact() async throws {
        let output = try await Self.staleLookup("Clamp.init", files: Self.clamp)

        #expect(output.contains("every call spelled \"Clamp.init\" is listed above — 3 call sites by name, 3 listed above (for init(wrappedValue:step:))"), "\(output)")
    }

    /// A wrapper with one initializer in its own declaration and one taking a step in a file of its own, whose step is defaulted where `defaulted` is set, written on two stored properties.
    static func stepped(defaulted: Bool = false) -> [String: String] {
        [
            "Sources/Probe/Clamp.swift": """
            @propertyWrapper struct Clamp {
                var wrappedValue: Int
                init(wrappedValue: Int) { self.wrappedValue = wrappedValue }
            }
            """,
            "Sources/Probe/More.swift": """
            extension Clamp {
                init(wrappedValue: Int, step: Int\(defaulted ? " = 1" : "")) { self.wrappedValue = wrappedValue * step }
            }
            """,
            "Sources/Probe/Use.swift": """
            struct Box {
                @Clamp var a = 1
                @Clamp(step: 2) var b = 1
            }
            """,
        ]
    }

    /// The file of attributes among `files`, to be written again unchanged since the build, so no row the store holds for it is trusted to list a site.
    static func rewrittenUse(_ files: [String: String]) -> [String: String] {
        ["Sources/Probe/Use.swift": files["Sources/Probe/Use.swift"] ?? ""]
    }

    /// The heading of the refused initializer's name-matched sites.
    static var refusedSites: String {
        "— for init(wrappedValue:step:)):"
    }

    /// An attribute site is listed for the refused initializer only where its written arguments reach it, and one reaching only the other initializer is listed once, beside the store's answer for that one.
    ///
    /// The file of attributes is written again since the build, so the store's row for it lists no site the name scan may leave out.
    @Test
    func anAttributeSiteIsCreditedOnlyToAnInitializerItsArgumentsReach() async throws {
        let output = try await Self.staleLookup("Clamp.init", files: Self.stepped(), thenWriting: Self.rewrittenUse(Self.stepped()))

        #expect(output.contains("semantic REFUSED for init(wrappedValue:step:)"), "\(output)")
        #expect(output.contains("\"Clamp.init\" (2 call sites by name, 1 listed above, in 1 file — for init(wrappedValue:step:)):"), "\(output)")
        #expect((output + "\n").contains("Use.swift:3  in Box.b\n"), "\(output)")
        #expect(Self.count(of: "Use.swift:2  in Box.a", in: output) == 1, "\(output)")
        #expect(Self.count(of: "Use.swift:2  in Box.a", in: Self.text(below: "\"@Clamp\" (1 call site in 1 file — for init(wrappedValue:)):", in: output)) == 1, "\(output)")
        #expect(!Self.text(below: Self.refusedSites, in: output).contains("Box.a"), "\(output)")
    }

    /// A site whose arguments reach both initializers, one through a defaulted parameter, is listed once for the type rather than credited to one, where its file was written since the build.
    @Test
    func anAttributeSiteReachingBothInitializersSaysSo() async throws {
        let files = Self.stepped(defaulted: true)
        let output = try await Self.staleLookup("Clamp.init", files: files, thenWriting: Self.rewrittenUse(files))

        #expect(output.contains("semantic REFUSED for init(wrappedValue:step:)"), "\(output)")
        #expect(Self.count(of: "Use.swift:2  in Box.a", in: output) == 1, "\(output)")
        #expect(Self.count(of: "Use.swift:2  in Box.a", in: Self.text(below: "\"@Clamp\" (1 call site in 1 file — for Probe.Clamp, no one initializer by its labels):", in: output)) == 1, "\(output)")
        #expect((output + "\n").contains("Use.swift:3  in Box.b\n"), "\(output)")
    }

    /// A site whose arguments reach neither initializer, in a file written since the build, is listed once for the type rather than credited to one.
    @Test
    func anAttributeSiteReachingNoInitializerSaysSo() async throws {
        let use = """
        struct Box {
            @Clamp var a = 1
            @Clamp(step: 2) var b = 1
            @Clamp(scale: 3) var c = 1
        }
        """
        let output = try await Self.staleLookup("Clamp.init", files: Self.stepped(), thenWriting: ["Sources/Probe/Use.swift": use])

        #expect(Self.count(of: "Use.swift:4  in Box.c", in: Self.text(below: "\"@Clamp\" (1 call site in 1 file — for Probe.Clamp, no one initializer by its labels):", in: output)) == 1, "\(output)")
        #expect((output + "\n").contains("Use.swift:3  in Box.b\n"), "\(output)")
        #expect(Self.count(of: "Use.swift:2  in Box.a", in: output) == 1, "\(output)")
        #expect(Self.count(of: "Use.swift:2  in Box.a", in: Self.text(below: "\"@Clamp\" (1 call site in 1 file — for init(wrappedValue:)):", in: output)) == 1, "\(output)")
        #expect(!Self.text(below: Self.refusedSites, in: output).contains("Box.a"), "\(output)")
    }

    /// Where every site not listed above reaches only another initializer, the line standing for the block says so rather than calling each one listed above.
    @Test
    func noSiteReachingTheRefusedInitializerIsSaidExactly() async throws {
        var files = Self.stepped()
        files["Sources/Probe/Use.swift"] = """
        func use() -> Int {
            Clamp(wrappedValue: 1).wrappedValue
        }
        """
        let output = try await Self.staleLookup("Clamp.init", files: files, thenWriting: Self.rewrittenUse(files))

        #expect(output.contains("every call spelled \"Clamp.init\" reaches only another initializer by its labels — 1 call site by name, 1 whose labels reach only init(wrappedValue:) (for init(wrappedValue:step:))"), "\(output)")
        #expect(Self.count(of: "Use.swift:2  in use()", in: Self.text(below: Self.reachingWrappedValue, in: output)) == 1, "\(output)")
    }

    /// A call and an attribute in a file written since the build, which reach only the initializer the store answers but which its answer cannot list, are listed under the initializer they reach rather than counted and lost.
    @Test
    func aSiteReachingOnlyAnotherInitializerThatTheStoreMissesIsListed() async throws {
        let brand = """
        func brand() -> Int {
            let g = Clamp(wrappedValue: 7)
            return g.wrappedValue
        }
        struct Brand {
            @Clamp var h = 2
        }
        """
        let output = try await Self.staleLookup("Clamp.init", files: Self.stepped(), thenWriting: ["Sources/Probe/Brand.swift": brand])
        let below = Self.text(below: Self.reachingWrappedValue, in: output)

        #expect(output.contains("semantic REFUSED for init(wrappedValue:step:)"), "\(output)")
        #expect(Self.count(of: Self.reachingWrappedValue, in: output) == 1, "\(output)")
        #expect(Self.count(of: "Brand.swift:2  in brand()", in: below) == 1, "\(output)")
        #expect(Self.count(of: "Brand.swift:6  in Brand.h", in: output) == 1, "\(output)")
    }

    /// A wrapper with one initializer in its own declaration and one taking a step in a file of its own, written on a function's parameter and on a stored property, and called twice from one function.
    static var recorded: [String: String] {
        [
            "Sources/Probe/Clamp.swift": """
            @propertyWrapper struct Clamp {
                var wrappedValue: Int
                init(wrappedValue: Int) { self.wrappedValue = wrappedValue }
                init(projectedValue: Clamp) { self = projectedValue }
                var projectedValue: Clamp { self }
            }
            """,
            "Sources/Probe/More.swift": """
            extension Clamp {
                init(wrappedValue: Int, step: Int) { self.wrappedValue = wrappedValue * step }
            }
            """,
            "Sources/Probe/Use.swift": """
            func pv(@Clamp x: Int) -> Int { x }
            struct Box { @Clamp var a = 1 }
            func use() -> Int {
                let p = Clamp(wrappedValue: 1)
                let q = Clamp(wrappedValue: 2)
                return p.wrappedValue + q.wrappedValue + pv($x: p)
            }
            """,
        ]
    }

    /// An attribute on a function's parameter and one on a stored property, which the store records as calls at the attribute's own name, are each listed once, as the store's callers.
    @Test
    func anAttributeTheStoreRecordsIsListedOnce() async throws {
        let output = try await Self.staleLookup("Clamp.init", files: Self.recorded)

        #expect(output.contains("semantic REFUSED for init(wrappedValue:step:)"), "\(output)")
        let located = WhereStoreSiteTextTests.located(output)
        #expect(Self.count(of: "Use.swift:1  pv(x:)", in: located) == 1, "\(output)")
        #expect(Self.count(of: "Use.swift:2  a  |", in: located) == 1, "\(output)")
        #expect(Self.count(of: "Use.swift:1", in: located) == 1, "\(output)")
        #expect(Self.count(of: "Use.swift:2", in: located) == 1, "\(output)")
    }

    /// A caller's second call, listed on a row of its own above while the block is short enough to carry each line's text, is counted as listed rather than listed again by name.
    @Test
    func aCallListedOnItsOwnRowIsNotListedAgainByName() async throws {
        let output = try await Self.staleLookup("Clamp.init", files: Self.recorded)
        let located = WhereStoreSiteTextTests.located(output)

        #expect(output.contains("    :4  use()  | let p = Clamp(wrappedValue: 1)\n    :5  use()  | let q = Clamp(wrappedValue: 2)"), "\(output)")
        #expect(Self.count(of: "Use.swift:4", in: located) == 1, "\(output)")
        #expect(Self.count(of: "Use.swift:5", in: located) == 1, "\(output)")
        #expect(Self.count(of: "Use.swift:5  in use()", in: Self.text(below: Self.reachingWrappedValue, in: output)) == 0, "\(output)")
    }
}
