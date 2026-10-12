//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// `where`'s one degraded note: a template per cause, each naming what was withheld, "by written name" only where a list follows, and the no-store remedy read back from the engine's own note (Docs/Design.md §2, *The degraded note*).
@Suite(.temporaryDirectories)
struct DegradedNoteTests {
    @Test func aCheckoutWithNoStoreKeepsItsHelpPointer() {
        let cause = SiftEngine.whereNoStoreCause(from: SiftEngine.noStoreNote(for: WorkingTree(repository: "Depot")))

        #expect(DegradedNote(cause: cause, withheld: .calls).line
            == "no store for callers, overrides or references; sites by written name; how to build one: sift help answers, section (index store)")
    }

    @Test func aWorktreeWithAPackageIsToldItsBuildCommand() {
        // This repository's own root, which holds a Package.swift.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let packaged = SiftEngine.noStoreNote(for: WorkingTree(repository: "Depot", worktree: "w"), root: root)
        #expect(DegradedNote(cause: SiftEngine.whereNoStoreCause(from: packaged), withheld: .calls).line
            == "no store for callers, overrides or references; sites by written name; build: sift run -- swift build --build-tests (sift help worktree-index)")
        let bare = SiftEngine.whereNoStoreCause(from: SiftEngine.noStoreNote(for: WorkingTree(repository: "Depot", worktree: "w")))
        #expect(DegradedNote(cause: bare, withheld: .calls).line.hasSuffix("; how to build one: sift help worktree-index"))
    }

    @Test func aSettingPassedOverGoesOnTheNoStoreNote() {
        let note = SiftEngine.noStoreNote(for: WorkingTree(repository: "Depot"), rejected: ["indexStorePath x is not a store"])
        let line = DegradedNote(cause: SiftEngine.whereNoStoreCause(from: note), withheld: .calls).line

        #expect(line.hasSuffix("; how to build one: sift help answers, section (index store); passed over: indexStorePath x is not a store"))
    }

    @Test func aProjectHintTakesTheBuildClausesPlace() {
        let line = DegradedNote(cause: .noStore(remedy: DegradedNote.checkoutRemedy, passedOver: [], cutShort: ""), withheld: .uses).line

        #expect(DegradedNote.withoutRemedy(line) == "no store for uses; sites by written name, an empty list is not \"unused\"")
    }

    @Test func aTypeAndAMemberTogetherNameBoth() {
        let line = DegradedNote(cause: .warming, withheld: .mixed).line

        #expect(line == "index store still loading: callers, overrides, uses or references withheld, sites by written name, an empty list is not \"unused\"; ask again shortly")
    }

    @Test func aStoreThatFailedToOpenSaysWhy() {
        let why = SiftEngine.openFailureCause(of: "index store found (.build) but failed to open: the units are unreadable")

        let store = SiftEngine.openFailureStore(of: "index store found (.build) but failed to open: the units are unreadable")

        #expect(DegradedNote(cause: .openFailed(store: store, why: why), withheld: .calls).line
            == "index store failed to open (.build: the units are unreadable): callers, overrides or references withheld, sites by written name")
    }

    @Test func aNestedPackagesPrimaryStoreIsNamedByItsLabel() {
        let note = "index store found (Kit/.build) but failed to open: no cache"

        #expect(SiftEngine.openFailureStore(of: note) == "Kit/.build")
        #expect(DegradedNote(cause: .openFailed(store: SiftEngine.openFailureStore(of: note), why: SiftEngine.openFailureCause(of: note)), withheld: .uses).line
            .hasPrefix("index store failed to open (Kit/.build: no cache): uses withheld"))
    }

    @Test func anInTreeStoreIsNamedByItsPath() {
        let note = "in-tree store .build/runner-dd failed to open: no cache"

        #expect(SiftEngine.openFailureStore(of: note) == ".build/runner-dd")
    }

    @Test func syntacticSaysNothingWasAskedFor() {
        #expect(DegradedNote(cause: .off, withheld: .calls).line == "--syntactic: callers, overrides or references not asked for, sites by written name")
        #expect(SemanticAxis.off.rendered == "off (--syntactic)")
    }

    @Test func aRevisionNamesItself() {
        #expect(DegradedNote(cause: .revision("HEAD~1"), withheld: .calls).line
            == "--at HEAD~1: callers, overrides or references not available from git, sites by written name")
    }

    @Test func aSubscriptNeverSaysByWrittenName() {
        let noStore = DegradedNote(cause: .noStore(remedy: DegradedNote.worktreeRemedy, passedOver: [], cutShort: ""), withheld: .subscripts).line
        #expect(noStore == "subscript: callers and references withheld, uses spell no name to match; no store; how to build one: sift help worktree-index")
        #expect(DegradedNote.withoutRemedy(noStore) == "subscript: callers and references withheld, uses spell no name to match; no store")
        let warming = DegradedNote(cause: .warming, withheld: .subscripts).line
        #expect(warming == "subscript: callers and references withheld, uses spell no name to match; index store still loading, ask again shortly")
        #expect(![noStore, warming].contains { $0.contains("written name") })
    }

    // MARK: Through `where`

    /// An unbuilt repository declaring `Depot`, which a function of `Shop` calls, and a subscript on `Shelf`.
    private static func unbuilt() throws -> URL {
        let root = try MCPTestRepo.make(declaring: "Alpha")
        try MCPTestRepo.add([
            "Sources/App/Kinds.swift": "struct Depot {\n    func stock() {}\n}\nstruct Shelf {\n    subscript(slot: Int) -> Int { slot }\n}\n",
            "Sources/App/Shop.swift": "struct Shop {\n    func open() {\n        Depot().stock()\n    }\n}\n",
        ], to: root)
        return root
    }

    /// The first line of `answer` that opens like a degraded note, or `nil`.
    private static func note(in answer: String) -> String? {
        answer.split(separator: "\n").map(String.init).first {
            $0.hasPrefix(DegradedNote.noStoreOpening) || $0.hasPrefix("index store ") || $0.hasPrefix("--syntactic: ") || $0.hasPrefix("--at ") || $0.hasPrefix(DegradedNote.subscriptOpening)
        }
    }

    private static func lookup(_ symbol: String, in root: URL, options: WhereOptions = WhereOptions(), openBudget: Double? = nil) async throws -> String {
        let engine = try SiftEngine(directory: root)
        if let openBudget {
            engine.openBudget = openBudget
        }
        return try await engine.lookup(symbol: symbol, freshness: engine.ensureFresh(), options: options)
    }

    @Test func aWhereOnACheckoutWithNoStoreCarriesTheNoStoreNote() async throws {
        let answer = try await Self.lookup("stock()", in: Self.unbuilt())

        #expect(Self.note(in: answer) == "no store for callers, overrides or references; sites by written name; how to build one: sift help answers, section (index store)", "\(answer)")
        #expect(!answer.contains("mode:") && !answer.contains("NOT ANSWERED"), "\(answer)")
    }

    @Test func aWarmingStoreCarriesTheWarmingNote() async throws {
        let root = try Self.unbuilt()
        try MCPTestRepo.add(["Package.swift": "// swift-tools-version: 5.9\nimport PackageDescription\nlet package = Package(name: \"App\", targets: [.target(name: \"App\")])\n"], to: root)
        try MCPTestRepo.build(root)
        let answer = try await Self.lookup("stock()", in: root, openBudget: 0)

        #expect(Self.note(in: answer) == "index store still loading: callers, overrides or references withheld, sites by written name; ask again shortly", "\(answer)")
    }

    @Test func aStoreThatFailedToOpenCarriesTheOpenFailedNote() async throws {
        let root = try Self.unbuilt()
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".build/index/store/v5/units"), withIntermediateDirectories: true)
        let engine = try SiftEngine(directory: root)
        let freshness = try await engine.ensureFresh()
        try Data("not a directory".utf8).write(to: SiftPaths.cache(in: root).appendingPathComponent("isdb"))
        let answer = try await engine.lookup(symbol: "stock()", freshness: freshness)

        let note = Self.note(in: answer) ?? ""

        #expect(note.hasPrefix("index store failed to open ("), "\(answer)")
        #expect(note.hasSuffix("): callers, overrides or references withheld, sites by written name"), "\(answer)")
    }

    @Test func syntacticCarriesTheNotAskedForNote() async throws {
        let answer = try await Self.lookup("stock()", in: Self.unbuilt(), options: WhereOptions(includeSemantic: false))

        #expect(Self.note(in: answer) == "--syntactic: callers, overrides or references not asked for, sites by written name", "\(answer)")
    }

    @Test func atARevisionCarriesTheNamedRevisionNote() async throws {
        let engine = try SiftEngine(directory: Self.unbuilt())
        let answer = try await engine.lookup(symbol: "stock()", at: "HEAD")

        #expect(Self.note(in: answer) == "--at HEAD: callers, overrides or references not available from git, sites by written name", "\(answer)")
    }

    @Test func aSubscriptAnsweredThroughWhereNeverSaysByWrittenName() async throws {
        let answer = try await Self.lookup("Shelf.subscript", in: Self.unbuilt())

        let note = Self.note(in: answer) ?? ""

        #expect(note.hasPrefix(DegradedNote.subscriptOpening), "\(answer)")
        #expect(!note.contains("written name"), "\(answer)")
    }

    @Test func aFreshStoreAnswerHasNoNoteAndNoStoresLine() async throws {
        let root = try Self.unbuilt()
        try MCPTestRepo.add(["Package.swift": "// swift-tools-version: 5.9\nimport PackageDescription\nlet package = Package(name: \"App\", targets: [.target(name: \"App\")])\n"], to: root)
        try MCPTestRepo.build(root)
        let answer = try await Self.lookup("stock()", in: root)

        #expect(answer.contains("semantic: "), "\(answer)")
        #expect(Self.note(in: answer) == nil, "\(answer)")
        #expect(!answer.contains("stores: "), "\(answer)")
    }
}
