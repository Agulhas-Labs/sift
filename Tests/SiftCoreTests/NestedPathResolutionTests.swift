//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers a dotted target resolved segment by segment: a member reached through a nested type, and the answer given when a path cannot be resolved at all.
///
/// The shape both defects arise in is a nested type extended by its full path — `extension Outer.Inner`, the only spelling Swift allows — whose extension row's name is one chain element spelling two. Compared unflattened it matches no qualifier list, so `Outer.Inner.member` and `Inner.member` alike dead-end on "nearest symbols" while the list underneath prints the very declaration they have just refused.
@Suite(.temporaryDirectories)
struct NestedPathResolutionTests {
    private static func fixture() throws -> (store: IndexStore, root: URL) {
        let store = try TestSources.makeStore()
        let root = try TestSources.makeTempDirectory()
        let panels = try TestSources.parsed(
            """
            enum Catalogue {
                struct Source {
                    let identifier: String
                }
            }

            extension Catalogue.Source {
                /// Every kind this source can produce.
                var objectTypes: [String] {
                    guard !identifier.isEmpty else {
                        return []
                    }
                    return [identifier, identifier + "-derived"]
                }

                func widen(by amount: Int) -> Int {
                    max(0, amount)
                }
            }

            struct Loose {
                var objectTypes: [String] {
                    ["loose"]
                }
            }
            """,
            path: "Sources/Alpha/Panels.swift",
            in: root
        )
        try store.replaceFiles([panels]) { _ in ("Alpha", false) }
        return (store, root)
    }

    /// The same fixture with one file the parser cannot finish — the state in which "declared, but not under X" can be an assertion about a declaration that was simply never indexed.
    private static func fixture(alsoBroken: Bool) throws -> (store: IndexStore, root: URL) {
        let base = try fixture()
        guard alsoBroken else { return base }
        let broken = try TestSources.parsed(
            """
            struct Truncated {
                let kept = 1
                func swallowedFromHereOn(
            }
            """,
            path: "Sources/Alpha/Broken.swift",
            in: base.root
        )
        try base.store.replaceFiles([broken]) { _ in ("Alpha", false) }
        return base
    }

    /// Declarations of one name, more than either face will list — the shape in which a cut list has to say so.
    private static let crowdedCount = 62

    private static func crowdedFixture() throws -> (store: IndexStore, root: URL) {
        let store = try TestSources.makeStore()
        let root = try TestSources.makeTempDirectory()
        let holders = (1 ... crowdedCount)
            .map { "struct Holder\($0) {\n    var flag: Bool { true }\n}" }
            .joined(separator: "\n\n")
        let parsed = try TestSources.parsed(holders, path: "Sources/Alpha/Holders.swift", in: root)
        try store.replaceFiles([parsed]) { _ in ("Alpha", false) }
        return (store, root)
    }

    /// The answer from the "could not resolve" line down, which is the part both faces promise to word identically.
    private static func diagnosis(in answer: String) -> [String] {
        let lines = answer.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let start = lines.firstIndex(where: { $0.hasPrefix("could not resolve the path") }) else { return [] }
        return Array(lines[start...]).reversed().drop { $0.isEmpty }.reversed()
    }

    private static func lookup(_ query: String) async throws -> String {
        let renderer = try WhereRenderer(store: fixture().store)
        return try await renderer.render(query: query, semantic: .inactive(note: "test run")).body
    }

    private static func digest(_ target: String) throws -> String {
        let fixture = try fixture()
        let renderer = try DigestRenderer(store: fixture.store, moduleNames: fixture.store.moduleNames(), repoRoot: fixture.root)
        return try renderer.render(target: target, options: DigestOptions())
    }

    @Test
    func aMemberOfANestedTypeResolvesByEveryQualifiedForm() async throws {
        let full = try await Self.lookup("Catalogue.Source.objectTypes")
        let partial = try await Self.lookup("Source.objectTypes")
        let labeled = try await Self.lookup("Catalogue.Source.widen(by:)")

        #expect(full.contains("declarations (1):"))
        #expect(full.contains("Alpha.Catalogue.Source.objectTypes — var"))
        #expect(partial.contains("Alpha.Catalogue.Source.objectTypes — var"))
        #expect(labeled.contains("Alpha.Catalogue.Source.widen(by:) — func"))
        // The declaration an unflattened answer lists as a "nearest symbol" while refusing to resolve it.
        #expect(!full.contains("nearest symbols"))
    }

    /// The cost this carried: the member form exists to save a digest-then-Read round trip, and unflattened, for a nested type it is the round trip plus a wrong answer.
    @Test
    func digestServesTheBodyOfAMemberReachedThroughANestedType() throws {
        let output = try Self.digest("Catalogue.Source.objectTypes")

        #expect(output.contains("Alpha.Catalogue.Source.objectTypes — var"))
        #expect(output.contains("guard !identifier.isEmpty else {"))
        #expect(!output.contains("no type or member named"))
    }

    /// An unresolvable path and an absent symbol are different failures, and must not be answered identically — as nearest symbols, which reads as "you have the wrong name".
    @Test
    func anUnresolvablePathIsSaidApartFromAnAbsentName() async throws {
        let wrongPath = try await Self.lookup("Missing.objectTypes")
        let absent = try await Self.lookup("Catalogue.Source.nothingByThisName")

        #expect(wrongPath.contains("could not resolve the path Missing.objectTypes"))
        #expect(wrongPath.contains("objectTypes is declared, but not under Missing"))
        #expect(wrongPath.contains("Alpha.Catalogue.Source.objectTypes — var"))
        #expect(wrongPath.contains("Alpha.Loose.objectTypes — var"))
        #expect(!wrongPath.contains("nearest symbols"))
        #expect(!absent.contains("could not resolve the path"))
    }

    /// Both faces, compared as whole blocks rather than by headline — the test name is a claim about every line, and two lists compared only by headline can drift apart under it.
    @Test
    func digestSaysTheSameThingInTheSameWords() async throws {
        let fromDigest = try Self.digest("Missing.objectTypes")
        let fromWhere = try await Self.lookup("Missing.objectTypes")

        #expect(Self.diagnosis(in: fromDigest) == Self.diagnosis(in: fromWhere))
        #expect(Self.diagnosis(in: fromDigest).first == "could not resolve the path Missing.objectTypes — objectTypes is declared, but not under Missing:")
        #expect(Self.diagnosis(in: fromDigest).contains("  Alpha.Catalogue.Source.objectTypes — var — Sources/Alpha/Panels.swift:9-14"))
    }

    /// The list *is* the evidence in this answer, so a cut list that does not say it was cut reads as "your member is not here" — the exact conclusion the answer exists to prevent a caller from drawing wrongly.
    ///
    /// Each face keeps its own budget — a digest pages 60 declarations, `where` lists 40 — so what is pinned is that each states its own arithmetic, not that they cut at the same place.
    @Test
    func aListCutToTheCapSaysHowMuchItCut() async throws {
        let fixture = try Self.crowdedFixture()
        let digest = try DigestRenderer(store: fixture.store, moduleNames: fixture.store.moduleNames(), repoRoot: fixture.root)
            .render(target: "Missing.flag", options: DigestOptions())
        let lookup = try await WhereRenderer(store: fixture.store)
            .render(query: "Missing.flag", semantic: .inactive(note: "test run")).body

        #expect(digest.contains("could not resolve the path Missing.flag"))
        #expect(Self.diagnosis(in: digest).filter { $0.hasPrefix("  Alpha.") }.count == DigestRenderer.memberCap)
        #expect(digest.contains("  truncated: \(Self.crowdedCount - DigestRenderer.memberCap) more declarations"))
        #expect(Self.diagnosis(in: lookup).filter { $0.hasPrefix("  Alpha.") }.count == WhereRenderer.listCap)
        #expect(lookup.contains("  truncated: \(Self.crowdedCount - WhereRenderer.listCap) more declarations"))
    }

    /// A "declared, but not under X" line is an assertion of *non*-membership, and a file the parser could not finish produces exactly that — with the file that would disprove it absent from the paths cited, which is why this banner is the one that goes repo-wide.
    @Test
    func theAbsenceClaimCarriesTheParseErrorBannerWhereverTheBrokenFileIs() async throws {
        let fixture = try Self.fixture(alsoBroken: true)
        let digest = try DigestRenderer(store: fixture.store, moduleNames: fixture.store.moduleNames(), repoRoot: fixture.root)
            .render(target: "Missing.objectTypes", options: DigestOptions())
        let lookup = try await WhereRenderer(store: fixture.store)
            .render(query: "Missing.objectTypes", semantic: .inactive(note: "test run")).body

        // The repo-wide wording, not the answer-scoped one: these are files the answer never drew on, and an
        // instruction to open them "because the answer came from them" would be false in both faces.
        #expect(digest.contains("parse errors elsewhere in this repo"))
        #expect(digest.contains("Sources/Alpha/Broken.swift"))
        #expect(!digest.contains("declarations may be missing from:"))
        #expect(lookup.contains("parse errors elsewhere in this repo"))
        #expect(lookup.contains("Sources/Alpha/Broken.swift"))
        // Above the claim it qualifies, not below it — a caveat read after the decision is not a caveat.
        let lines = digest.split(separator: "\n").map(String.init)
        let banner = try #require(lines.firstIndex { $0.hasPrefix("⚠ parse errors") })
        let claim = try #require(lines.firstIndex { $0.hasPrefix("could not resolve the path") })
        #expect(banner < claim)
    }

    /// A wrong *label* under a right path is the other failure, and it keeps the candidate list: the qualifiers resolved, so "not under Catalogue.Source" would be false.
    @Test
    func aWrongLabelUnderARightPathIsNotReportedAsAWrongPath() throws {
        let output = try Self.digest("Catalogue.Source.widen(amount:)")

        #expect(!output.contains("could not resolve the path"))
        #expect(output.contains("nearest symbols"))
        #expect(output.contains("widen(by:)"))
    }
}

// MARK: A declared name is never external

/// A type this repository declares is never answered as one declared outside it — not even when the only thing a missed qualifier turns up is that type's own extension.
///
/// The shape is a nested type extended by its full path: `digest Loose.Source` misses on its qualifier, and the extension rows matched on the bare name are `Catalogue.Source`'s own, which is no evidence at all of a type from somewhere else. The external answer itself has to survive the rule, so the fixture extends a type no file here declares beside it.
extension NestedPathResolutionTests {
    private static func digestWithExternalExtension(_ target: String) throws -> String {
        let fixture = try fixture()
        let text = try TestSources.parsed(
            """
            extension String {
                var slug: String {
                    lowercased()
                }
            }
            """,
            path: "Sources/Alpha/Text.swift",
            in: fixture.root
        )
        try fixture.store.replaceFiles([text]) { _ in ("Alpha", false) }
        let renderer = try DigestRenderer(store: fixture.store, moduleNames: fixture.store.moduleNames(), repoRoot: fixture.root)
        return try renderer.render(target: target, options: DigestOptions())
    }

    @Test
    func aNestedTypeUnderTheWrongParentIsNotCalledExternal() async throws {
        let fromDigest = try Self.digestWithExternalExtension("Loose.Source")
        let fromWhere = try await Self.lookup("Loose.Source")

        #expect(!fromDigest.contains("declared outside this repo"))
        #expect(Self.diagnosis(in: fromDigest).first == "could not resolve the path Loose.Source — Source is declared, but not under Loose:")
        #expect(Self.diagnosis(in: fromDigest).contains("  Alpha.Catalogue.Source — struct — Sources/Alpha/Panels.swift:2-4"))
        // The same answer `where` already gives, in the same words.
        #expect(Self.diagnosis(in: fromDigest) == Self.diagnosis(in: fromWhere))
    }

    @Test
    func aTypeNoFileHereDeclaresIsStillCalledExternal() throws {
        let bare = try Self.digestWithExternalExtension("String")
        let qualified = try Self.digestWithExternalExtension("Swift.String")

        #expect(bare.contains("String — declared outside this repo (or not indexed); 1 local extension:"))
        #expect(bare.contains("var slug: String"))
        // A qualifier naming no repo module is a miss too, and still reaches the external answer rather than the wrong-path one.
        #expect(qualified.contains("String — declared outside this repo (or not indexed); 1 local extension"))
        #expect(qualified.contains("var slug: String"))
        #expect(!qualified.contains("could not resolve the path"))
    }
}

// MARK: A nested name is not the extended one

/// A type declared *nested* under some name says nothing about a top-level type of that name, so it must not stand between a missed qualifier and the external type's extensions.
///
/// Swift puts every extension at file scope, so the path an extension is written with is the whole of what it extends: `extension Color` is the top-level `Color` — in a file importing SwiftUI, SwiftUI's — while `extension Theme.Color` is the nested one. Only an extension whose written path is a local declaration's is evidence against an external type; the bare name matching at some other depth is not. The fixture holds all three shapes at once, because the rule has to tell them apart in one repository: an external type whose name the repo also nests, a framework type nested under a framework parent beside a local type of the same leaf name, and a local nested type reached through the wrong parent.
extension NestedPathResolutionTests {
    private static func nestedNameDigest(_ target: String) throws -> String {
        let store = try TestSources.makeStore()
        let root = try TestSources.makeTempDirectory()
        let theme = try TestSources.parsed(
            """
            import SwiftUI

            enum Theme {
                struct Color {
                    let name: String
                }
            }

            extension Theme.Color {
                var label: String {
                    name.uppercased()
                }
            }

            extension Color {
                static let brand = Color(red: 0.1, green: 0.3, blue: 0.5)
            }
            """,
            path: "Sources/Alpha/Theme.swift",
            in: root
        )
        let loader = try TestSources.parsed(
            """
            import Foundation

            enum Loader {
                struct Configuration {
                    let retries: Int
                }
            }

            extension URLSession.Configuration {
                var lenient: Bool {
                    true
                }
            }
            """,
            path: "Sources/Alpha/Loader.swift",
            in: root
        )
        let tracker = try TestSources.parsed(
            """
            enum Tracker {
                struct Change {
                    let summary: String
                }
            }

            extension Tracker.Change {
                var isEmpty: Bool {
                    summary.isEmpty
                }
            }
            """,
            path: "Sources/Alpha/Tracker.swift",
            in: root
        )
        let names = try TestSources.parsed(
            """
            import Foundation

            enum Keys {
                struct Name {
                    let raw: String
                }
            }

            extension Notification.Name {
                static let refreshed = Notification.Name("refreshed")
            }
            """,
            path: "Sources/Alpha/Names.swift",
            in: root
        )
        try store.replaceFiles([theme, loader, tracker, names]) { _ in ("Alpha", false) }
        let renderer = try DigestRenderer(store: store, moduleNames: store.moduleNames(), repoRoot: root)
        return try renderer.render(target: target, options: DigestOptions())
    }

    /// A top-level `extension Color` extends the framework's type, and a nested `Theme.Color` does not make it local — so `digest SwiftUI.Color` reaches its members, which is the only digest that can, since a bare `digest Color` resolves to the nested type.
    @Test
    func aNestedTypeOfTheSameNameDoesNotHideTheExternalOne() throws {
        let answer = try Self.nestedNameDigest("SwiftUI.Color")

        #expect(answer.contains("Color — declared outside this repo (or not indexed); 1 local extension"))
        #expect(answer.contains("static let brand"))
        #expect(!answer.contains("could not resolve the path"))
        // The nested type's own extension extends a type written here, so it is no part of the external answer — and the answer says where it went rather than dropping it in silence.
        #expect(!answer.contains("var label: String"))
        #expect(answer.contains("(+1 extension of Alpha.Theme.Color, which this repo declares — digest Alpha.Theme.Color serves it)"))
    }

    /// A framework type nested under a framework parent, beside a local type of the same leaf name — the common case, since a name like `Configuration` is nested all over a codebase.
    @Test
    func aCommonNestedNameDoesNotHideAFrameworkTypeOfTheSameName() throws {
        let answer = try Self.nestedNameDigest("URLSession.Configuration")

        #expect(answer.contains("Configuration — declared outside this repo (or not indexed); 1 local extension:"))
        #expect(answer.contains("var lenient: Bool"))
        #expect(!answer.contains("could not resolve the path"))
    }

    /// The case the local-declaration rule was written for still holds beside the other two: a nested type extended by its full path, reached through the wrong parent, is a wrong path and not an external type.
    @Test
    func aLocalNestedTypeUnderTheWrongParentIsStillAWrongPath() throws {
        let answer = try Self.nestedNameDigest("Loader.Change")

        #expect(!answer.contains("declared outside this repo"))
        #expect(Self.diagnosis(in: answer).first == "could not resolve the path Loader.Change — Change is declared, but not under Loader:")
        #expect(Self.diagnosis(in: answer).contains("  Alpha.Tracker.Change — struct — Sources/Alpha/Tracker.swift:2-4"))
    }

    /// An extension written under another parent says nothing about the path asked for: `extension Notification.Name` is evidence for `Notification.Name` and for no other `Name`, so `digest Wrong.Name` beside a local `Keys.Name` is a wrong path, not an external type.
    @Test
    func anExtensionUnderAnotherParentDoesNotHideAWrongPath() throws {
        let answer = try Self.nestedNameDigest("Wrong.Name")

        #expect(!answer.contains("declared outside this repo"))
        #expect(!answer.contains("static let refreshed"))
        #expect(Self.diagnosis(in: answer).first == "could not resolve the path Wrong.Name — Name is declared, but not under Wrong:")
        #expect(Self.diagnosis(in: answer).contains("  Alpha.Keys.Name — struct — Sources/Alpha/Names.swift:4-6"))
    }

    /// A written path the asked one ends with is the same type under a fuller spelling: `extension Notification.Name` is Foundation's `Notification.Name`, so `digest Foundation.Notification.Name` is its external answer, local `Keys.Name` or not.
    ///
    /// The qualifier in front is the framework the extension's file leaves unwritten, so it is no wrong parent.
    @Test
    func aWrittenPathTheAskedOneEndsWithIsEvidenceForIt() throws {
        let answer = try Self.nestedNameDigest("Foundation.Notification.Name")

        #expect(answer.contains("Name — declared outside this repo (or not indexed); 1 local extension"))
        #expect(answer.contains("static let refreshed"))
        #expect(!answer.contains("could not resolve the path"))
        #expect(!answer.contains("let raw: String"))
    }

    /// The same rule for a name nested all over a codebase: `extension URLSession.Configuration` is no evidence that `Settings.Configuration` is declared elsewhere, while the local `Loader.Configuration` is evidence the path is wrong.
    @Test
    func aFrameworkExtensionOfACommonNameDoesNotHideAWrongPath() throws {
        let answer = try Self.nestedNameDigest("Settings.Configuration")

        #expect(!answer.contains("declared outside this repo"))
        #expect(!answer.contains("var lenient: Bool"))
        #expect(Self.diagnosis(in: answer).first == "could not resolve the path Settings.Configuration — Configuration is declared, but not under Settings:")
        #expect(Self.diagnosis(in: answer).contains("  Alpha.Loader.Configuration — struct — Sources/Alpha/Loader.swift:4-6"))
    }
}

extension NestedPathResolutionTests {
    /// One type with a few members of its own, and a crowd of other types each declaring the name being asked for.
    private static func crowdedMemberDigest(_ target: String) throws -> String {
        let store = try TestSources.makeStore()
        let root = try TestSources.makeTempDirectory()
        let others = (1 ... 40)
            .map { "struct Holder\($0) {\n    func read(_ value: Int) -> Int { value }\n}" }
            .joined(separator: "\n\n")
        let source = """
        struct Filter {
            func consume(line: String) {}
            func flush() {}
            func reset() {}
        }

        \(others)
        """
        let parsed = try TestSources.parsed(source, path: "Sources/Alpha/Holders.swift", in: root)
        try store.replaceFiles([parsed]) { _ in ("Alpha", false) }
        let renderer = try DigestRenderer(store: store, moduleNames: store.moduleNames(), repoRoot: root)
        return try renderer.render(target: target, options: DigestOptions())
    }

    /// A miss on `Type.member` is a question about the type: its own nearest members answer it, and the same-named declarations elsewhere are a count and a pointer, not a list that grows with the repository.
    @Test
    func aMemberMissOnAResolvedTypeNamesItsOwnMembersAndNotEveryHomonym() throws {
        let answer = try Self.crowdedMemberDigest("Filter.read(_:)")
        let byteCap = 1500

        #expect(answer.utf8.count < byteCap)
        #expect(answer.contains("Filter has no member read"))
        #expect(answer.contains("  consume(line:) — func — Sources/Alpha/Holders.swift:2"))
        #expect(answer.contains("  flush() — func"))
        #expect(!answer.contains("Holder1"))
        #expect(answer.contains("read is declared 40 times on other types — where read lists them"))
    }

    /// A type that does not resolve is said not to, with the candidates bounded by the page cap rather than the repository.
    @Test
    func aMemberMissOnAnUnresolvedTypeStaysCapped() throws {
        let answer = try Self.crowdedMemberDigest("Missing.read(_:)")

        #expect(answer.contains("read is declared, but not under Missing"))
        #expect(answer.split(separator: "\n").filter { $0.hasPrefix("  Alpha.") }.count <= DigestRenderer.memberCap)
    }
}
