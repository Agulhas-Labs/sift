//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// `DeclarationDiff` in isolation: two parses in, the declarations that changed out.
///
/// No git, no engine — `DiffGatherer` is what gathers the two sides for real; this covers the tree diff itself, and above all the pairing: which declaration on one side is the same declaration on the other.
struct DeclarationDiffTests {
    private static func side(_ source: String) -> DiffFileSide {
        DiffFileSide.parse(source: source, path: "Widget.swift")
    }

    private static func changes(from old: String, to new: String) -> [DeclarationChange] {
        DeclarationDiff.changes(old: side(old), new: side(new))
    }

    @Test func anAddedMemberCarriesItsAfterSideRangeAndNoBeforeSide() throws {
        let changes = Self.changes(
            from: "public struct Widget {\n    public func polish() {}\n}\n",
            to: "public struct Widget {\n    public func polish() {}\n    public func shine() {}\n}\n"
        )
        let added = try #require(changes.first { $0.name == "shine()" })

        #expect(changes.count == 1)
        #expect(added.kind == .added)
        #expect(added.containerPath == "Widget")
        #expect(added.newRange?.described == ":3")
        #expect(added.oldRange == nil)
        #expect(added.oldSignature == nil)
    }

    @Test func aRemovedMemberCarriesItsBeforeSideRangeAndNoAfterSide() throws {
        let changes = Self.changes(
            from: "public struct Widget {\n    public func polish() {}\n    public func shine() {}\n}\n",
            to: "public struct Widget {\n    public func polish() {}\n}\n"
        )
        let removed = try #require(changes.first { $0.name == "shine()" })

        #expect(removed.kind == .removed)
        #expect(removed.oldRange?.described == ":3")
        #expect(removed.newRange == nil)
        #expect(removed.newSignature == nil)
    }

    @Test func aChangedSignatureIsReportedBeforeAndAfter() throws {
        let changes = Self.changes(
            from: "public struct Widget {\n    public func polish() -> Int { 1 }\n}\n",
            to: "public struct Widget {\n    public func polish() -> String { \"1\" }\n}\n"
        )
        let changed = try #require(changes.first { $0.name == "polish()" })

        #expect(changed.kind == .changed)
        #expect(changed.signatureChanged)
        #expect(changed.oldSignature == "public func polish() -> Int")
        #expect(changed.newSignature == "public func polish() -> String")
    }

    /// The signature is unchanged, so the answer must not print an arrow to itself — the body is what moved.
    @Test func aBodyOnlyEditIsChangedWithoutClaimingTheSignatureDiffered() throws {
        let changes = Self.changes(
            from: "public struct Widget {\n    public func polish() -> Int {\n        1\n    }\n}\n",
            to: "public struct Widget {\n    public func polish() -> Int {\n        2\n    }\n}\n"
        )
        let changed = try #require(changes.first { $0.name == "polish()" })

        #expect(changed.kind == .changed)
        #expect(!changed.signatureChanged)
        #expect(changed.textChanged)
    }

    @Test func anUnchangedDeclarationIsNotReportedAtAll() {
        let source = "public struct Widget {\n    public func polish() -> Int { 1 }\n}\n"

        #expect(Self.changes(from: source, to: source).isEmpty)
    }

    /// A declaration is compared by its own text, which starts at its code: a doc-comment edit is not the declaration changing — it is reported as a comment outside every declaration (`OutsideDeclarationsTests`), not dropped.
    @Test func aDocCommentOnlyEditDoesNotClaimTheDeclarationChanged() {
        let changes = Self.changes(
            from: "public struct Widget {\n    /// Old doc.\n    public func polish() {}\n}\n",
            to: "public struct Widget {\n    /// New doc.\n    public func polish() {}\n}\n"
        )

        #expect(changes.isEmpty)
    }

    /// A name shared across two different kinds (an enum replaced by a struct of the same name) is neither kind's "before" — it reads as a plain removal plus addition rather than a claimed change between two different things.
    @Test func sameNameDifferentKindReadsAsRemovalPlusAddition() {
        let changes = Self.changes(from: "public enum Options {}\n", to: "public struct Options {}\n")

        #expect(changes.count == 2)
        #expect(changes.contains { $0.kind == .removed && $0.symbolKind == .enumKind })
        #expect(changes.contains { $0.kind == .added && $0.symbolKind == .structKind })
    }

    @Test func aWhollyAddedContainerIsOneEntryNotItsMembersIndividually() throws {
        let changes = Self.changes(
            from: "public struct Widget {}\n",
            to: """
            public struct Widget {}

            public struct Brand {
                public let name: String
                public func slogan() -> String { name }
            }

            """
        )

        #expect(changes.count == 1)
        let added = try #require(changes.first)
        #expect(added.name == "Brand")
        #expect(added.kind == .added)
        #expect(added.memberCount == 2)
    }

    /// The declarations section reports a deleted suite as one line — but a deleted suite is not a suite that lost no tests, and the test-files section needs the individual names even here.
    @Test func aWhollyRemovedSuiteStillNamesItsTestsIndividually() throws {
        let changes = DeclarationDiff.changes(
            old: Self.side("""
            import Testing

            struct WidgetTests {
                @Test func testPolishes() {}
                @Test func shineDoublesTheCount() {}
            }
            """),
            new: nil
        )
        let removed = try #require(changes.first { $0.name == "WidgetTests" })

        #expect(removed.kind == .removed)
        #expect(removed.nestedFunctions.map(\.name).sorted() == ["shineDoublesTheCount()", "testPolishes()"])
    }

    @Test func nestedContainersRecurseUnderADottedContainerPath() throws {
        let changes = Self.changes(
            from: "public struct Widget {\n    public struct Options {\n        public var count = 1\n    }\n}\n",
            to: "public struct Widget {\n    public struct Options {\n        public var count = 2\n    }\n}\n"
        )
        let changed = try #require(changes.first)

        #expect(changed.containerPath == "Widget.Options")
        #expect(changed.name == "count")
    }

    @Test func anAddedFileReadsAsEveryDeclarationAdded() {
        let changes = DeclarationDiff.changes(old: nil, new: Self.side("public struct Widget {\n    public func polish() {}\n}\n"))

        #expect(changes.count == 1)
        #expect(changes.allSatisfy { $0.kind == .added })
    }

    @Test func aDeletedFileReadsAsEveryDeclarationRemoved() {
        let changes = DeclarationDiff.changes(old: Self.side("public struct Widget {\n    public func polish() {}\n}\n"), new: nil)

        #expect(changes.count == 1)
        #expect(changes.allSatisfy { $0.kind == .removed })
    }

    /// `FileParser`'s in-memory overload (a diff side pulled from git, with no file on disk to stat) walks the same visitor as the disk-based one.
    @Test func inMemoryParsingAgreesWithDiskBasedParsingOnDeclarationCount() throws {
        let source = "public struct Widget {\n    public func polish() {}\n    public func shine() {}\n}\n"
        let fromDisk = try TestSources.parsed(source, path: "Widget.swift")
        let fromMemory = FileParser.parse(source: source, repoRelativePath: "Widget.swift") { _, _ in () }.file

        #expect(fromDisk.symbols.count == fromMemory.symbols.count)
        #expect(fromDisk.parseErrorCount == fromMemory.parseErrorCount)
        #expect(fromMemory.mtime == 0)
    }

    // MARK: Signatures are compared whole

    /// A `where` clause edited past where a signature is cut for display is still an edit to the header, and still reported — alongside the member edit that was the only thing said before.
    @Test func aContainerHeaderEditPastTheDisplayCutIsReported() throws {
        let clause = (1 ... 12).map { "T\($0): Equatable" }.joined(separator: ", ")
        let changes = Self.changes(
            from: "struct Widget<T1, T2, T3, T4, T5, T6, T7, T8, T9, T10, T11, T12> where \(clause), T12: Sendable {\n    func f() -> Int { 1 }\n}\n",
            to: "struct Widget<T1, T2, T3, T4, T5, T6, T7, T8, T9, T10, T11, T12> where \(clause), T12: Codable {\n    func f() -> Int { 2 }\n}\n"
        )
        let header = try #require(changes.first { $0.symbolKind == .structKind })

        #expect(header.kind == .changed)
        #expect(header.signatureChanged)
        #expect(header.newSignature?.hasSuffix("T12: Codable") == true)
    }

    /// A long function whose return type became optional changed its signature, however far along the line the change is.
    @Test func aReturnTypeEditPastTheDisplayCutChangesTheSignature() throws {
        let parameters = (1 ... 12).map { "argument\($0): Int" }.joined(separator: ", ")
        let changes = Self.changes(
            from: "struct W {\n    func configure(\(parameters)) -> Int { 1 }\n}\n",
            to: "struct W {\n    func configure(\(parameters)) -> Int? { 1 }\n}\n"
        )
        let changed = try #require(changes.first)

        #expect(changed.signatureChanged)
        #expect(changed.newSignature?.hasSuffix("-> Int?") == true)
    }

    /// A protocol requirement's accessors are what conformers must provide and callers may use: `{ get }` becoming `{ get set }` is a signature change.
    @Test func aRequirementsAccessorsArePartOfItsSignature() {
        let changes = Self.changes(
            from: "protocol P {\n    var v: Int { get }\n    subscript(i: Int) -> Int { get }\n}\n",
            to: "protocol P {\n    var v: Int { get set }\n    subscript(i: Int) -> Int { get set }\n}\n"
        )

        let everySignatureChanged = changes.allSatisfy(\.signatureChanged)

        #expect(changes.count == 2)
        #expect(everySignatureChanged)
        #expect(changes.first { $0.name == "v" }?.newSignature == "var v: Int { get set }")
    }

    // MARK: Pairing

    /// An extension whose header changed is the same extension: its members are compared, not hidden inside a removal and an addition — and a member it made public says so.
    @Test func anExtensionWhoseHeaderChangedPairsAsOneHeaderChange() throws {
        let changes = Self.changes(
            from: "struct W {}\n\nextension W {\n    func a() {}\n    func c() -> Int { 1 }\n}\n",
            to: "struct W {}\n\npublic extension W {\n    func a() {}\n    func c() -> Int { 2 }\n}\n"
        )
        let header = try #require(changes.first { $0.symbolKind == .extensionKind })
        let edited = try #require(changes.first { $0.name == "c()" })
        let publicized = try #require(changes.first { $0.name == "a()" })

        #expect(!changes.contains { $0.kind == .added || $0.kind == .removed })
        #expect(header.kind == .changed)
        #expect(header.newSignature == "public extension W")
        #expect(edited.textChanged)
        #expect(publicized.oldAccess == .internalLevel)
        #expect(publicized.newAccess == .publicLevel)
    }

    /// The elements of one `case a, b` share a line and a column; their order is still their order, and swapping them — which swaps their raw values — is a change.
    @Test func reorderingTheElementsOfOneCaseIsAMove() {
        let changes = Self.changes(from: "enum Level: Int {\n    case low, high\n}\n", to: "enum Level: Int {\n    case high, low\n}\n")

        #expect(!changes.isEmpty)
        #expect(changes.allSatisfy { $0.kind == .moved })
    }

    /// "Text unchanged" is said of a moved type only when nothing in it changed.
    @Test func aMovedTypeWithAnEditedMemberIsNotSaidToBeUnchanged() throws {
        let file = FileDiff.compare(
            path: "Widget.swift",
            status: .modified,
            lineStat: nil,
            bytes: (
                Data("struct A {\n    func f() -> Int { 1 }\n}\nstruct B {\n    func g() -> Int { 1 }\n}\n".utf8),
                Data("struct B {\n    func g() -> Int { 1 }\n}\nstruct A {\n    func f() -> Int { 2 }\n}\n".utf8)
            )
        )
        let movedA = try #require(file.changes.first { $0.name == "A" && $0.kind == .moved })
        let movedBIsIntact = file.changes.filter { $0.name == "B" }.allSatisfy(\.movedIntact)

        #expect(!movedA.movedIntact)
        #expect(file.changes.contains { $0.name == "f()" && $0.kind == .changed })
        #expect(movedBIsIntact)
    }

    // MARK: Pairing

    /// A new extension inserted above two same-named ones must not shift the pairing: nothing untouched reads as removed and re-added, and the one member edited reads as changed, not removed.
    @Test func anExtensionInsertedAboveSameNamedOnesPairsEachWithItself() throws {
        let changes = Self.changes(
            from: "extension W {\n    func a() -> Int { 1 }\n}\n\nextension W {\n    func b() -> Int { 1 }\n}\n",
            to: "extension W {\n    func c() -> Int { 0 }\n}\n\nextension W {\n    func a() -> Int { 1 }\n}\n\nextension W {\n    func b() -> Int { 2 }\n}\n"
        )

        #expect(changes.count == 2)
        #expect(changes.contains { $0.kind == .added && $0.symbolKind == .extensionKind && $0.newRange?.line == 1 })
        let edited = try #require(changes.first { $0.name == "b()" })
        #expect(edited.kind == .changed)
        #expect(!changes.contains { $0.name == "a()" })
    }

    /// Two extensions told apart only by their `where` clauses pair by that clause, wherever they sit — so each member is compared with its own counterpart, and the swap itself reads as a move.
    @Test func extensionsPairByTheirWholeHeaderNotByPosition() {
        let changes = Self.changes(
            from: "extension Array where Element == Int {\n    func total() -> Int { 1 }\n}\n\nextension Array where Element == String {\n    func total() -> Int { 2 }\n}\n",
            to: "extension Array where Element == String {\n    func total() -> Int { 2 }\n}\n\nextension Array where Element == Int {\n    func total() -> Int { 1 }\n}\n"
        )

        #expect(!changes.contains { $0.name == "total()" })
        #expect(!changes.contains { $0.kind == .changed })
        #expect(changes.contains { $0.kind == .moved && $0.symbolKind == .extensionKind })
    }

    @Test func aMemberUnderAnExtensionIsHeadedByItsClause() throws {
        let changes = Self.changes(
            from: "extension Array where Element == Int {\n    func total() -> Int { 1 }\n}\n",
            to: "extension Array where Element == Int {\n    func total() -> Int { 2 }\n}\n"
        )
        let changed = try #require(changes.first)

        #expect(changed.containerPath == "Array")
        #expect(changed.containerDisplay == "Array (extension where Element == Int)")
    }

    /// Of two overloads sharing a label, the one whose signature is unchanged is the same declaration; the other was removed — never "Int became String".
    @Test func anOverloadThatLostItsSiblingIsNotReportedAsTheSiblingChangingIntoIt() throws {
        let changes = Self.changes(
            from: "struct W {\n    func f(_ x: Int) -> Int { x }\n    func f(_ x: String) -> Int { 0 }\n}\n",
            to: "struct W {\n    func f(_ x: String) -> Int { 1 }\n}\n"
        )
        let removed = try #require(changes.first { $0.kind == .removed })
        let changed = try #require(changes.first { $0.kind == .changed })

        #expect(removed.oldSignature == "func f(_ x: Int) -> Int")
        #expect(changed.newSignature == "func f(_ x: String) -> Int")
        #expect(!changed.signatureChanged)
    }

    /// Same-named declarations under different `#if` branches carry their conditions, so the two are told apart (Docs/AnswerContract.md §6).
    @Test func declarationsUnderDifferentConditionsCarryThem() {
        let changes = Self.changes(
            from: "#if os(iOS)\nfunc f() -> Int { 1 }\n#else\nfunc f() -> Int { 2 }\n#endif\n",
            to: "#if os(iOS)\nfunc f() -> Int { 10 }\n#else\nfunc f() -> Int { 20 }\n#endif\n"
        )

        #expect(changes.count == 2)
        #expect(Set(changes.compactMap(\.newCondition)) == ["#if os(iOS)", "#else"])
    }

    /// A condition that changes around an untouched declaration is that declaration's change — its text is not, and says so.
    @Test func aChangedConditionIsAChangeEvenWhenTheTextIsNot() throws {
        let changes = Self.changes(
            from: "#if os(iOS)\nfunc f() -> Int { 1 }\n#else\nfunc f() -> Int { 2 }\n#endif\n",
            to: "#if os(macOS)\nfunc f() -> Int { 1 }\n#else\nfunc f() -> Int { 2 }\n#endif\n"
        )
        let changed = try #require(changes.first)

        #expect(changes.count == 1)
        #expect(changed.oldCondition == "#if os(iOS)")
        #expect(changed.newCondition == "#if os(macOS)")
        #expect(changed.conditionChanged)
        #expect(!changed.textChanged)
    }

    /// `let a = 1, b = 3` is two declarations; an edit to `b` is not reported against `a`.
    @Test func oneBindingOfSeveralIsComparedByItsOwnText() {
        let changes = Self.changes(from: "struct W {\n    let a = 1, b = 2\n}\n", to: "struct W {\n    let a = 1, b = 3\n}\n")

        #expect(changes.count == 1)
        #expect(changes.first?.name == "b")
    }

    /// `case a(Int), b(Int)` is two declarations named as the store names them; an edit to `b` is not reported against `a`.
    @Test func oneCaseWithAssociatedValuesOfSeveralIsComparedByItsOwnText() {
        let changes = Self.changes(from: "enum W {\n    case a(Int), b(Int)\n}\n", to: "enum W {\n    case a(Int), b(String)\n}\n")

        #expect(changes.count == 1)
        #expect(changes.first?.name == "b(_:)")
    }

    @Test func aReorderIsReportedAsAMove() {
        let changes = Self.changes(
            from: "struct W {\n    func a() -> Int { 1 }\n    func b() -> Int { 2 }\n}\n",
            to: "struct W {\n    func b() -> Int { 2 }\n    func a() -> Int { 1 }\n}\n"
        )

        #expect(changes.count == 1)
        #expect(changes.first?.kind == .moved)
    }

    /// A summary never needs bodies, and a large range holds many — they are kept only when asked for.
    @Test func bodiesAreDroppedUnlessKept() throws {
        let old = Self.side("struct W {\n    func a() -> Int { 1 }\n}\n")
        let new = Self.side("struct W {\n    func a() -> Int { 2 }\n}\n")

        let summary = try #require(DeclarationDiff.changes(old: old, new: new, keepBodies: false).first)
        let member = try #require(DeclarationDiff.changes(old: old, new: new, keepBodies: true).first)

        #expect(summary.oldBody == nil)
        #expect(member.newBody == "    func a() -> Int { 2 }")
    }
}
