//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
import SiftCore
@testable import SiftMCP
import Testing

/// The `PostToolUse` hook names an existing declaration shaped like one an edit just added, once, and says nothing otherwise.
@Suite(.temporaryDirectories)
struct PostToolUseCommandTests {
    /// The nudge the hook exists for: an edit adds a function making the same four calls as one elsewhere in the module, and the line names that one's place and the overlap.
    @Test func anEditAddingANearDuplicateNamesTheExistingDeclaration() async throws {
        let fixture = try await Fixture()
        try fixture.addRestock()
        let printed = await fixture.hook(path: fixture.catalogue)

        #expect(try Fixture.context(of: printed) == Fixture.expectedLine)
    }

    /// The same edit nudges once: a second run finds nothing new, and a context given the nudge is not given it again even where the index is set back to before the edit — while another context still is.
    @Test func theSameNudgeIsGivenOncePerContext() async throws {
        let fixture = try await Fixture()
        try fixture.addRestock()
        #expect(try await Fixture.context(of: fixture.hook(path: fixture.catalogue)) == Fixture.expectedLine)
        #expect(await fixture.hook(path: fixture.catalogue).isEmpty)

        try await fixture.setBack()
        #expect(await fixture.hook(path: fixture.catalogue).isEmpty)
        try await fixture.setBack()
        #expect(try await Fixture.context(of: fixture.hook(path: fixture.catalogue, session: "s2")) == Fixture.expectedLine)
    }

    /// A function with a single call is too thin to rank, and draws nothing.
    @Test func aThinNewFunctionDrawsNothing() async throws {
        let fixture = try await Fixture()
        try (Fixture.catalogueSource.dropLast(2) + "\n    func tally() -> Int {\n        load()\n    }\n}\n")
            .write(toFile: fixture.catalogue, atomically: true, encoding: .utf8)

        #expect(await fixture.hook(path: fixture.catalogue).isEmpty)
    }

    /// Only a write or an edit of a Swift file is looked at: a read of the same edited file draws nothing and leaves the nudge for the edit, and a document draws nothing.
    @Test func onlyAWriteOfASwiftFileIsLookedAt() async throws {
        let fixture = try await Fixture()
        try fixture.addRestock()
        #expect(await fixture.hook("Read", path: fixture.catalogue).isEmpty)
        let document = fixture.repo.appendingPathComponent("README.md").path
        try "# Depot\n".write(toFile: document, atomically: true, encoding: .utf8)
        #expect(await fixture.hook("Write", path: document).isEmpty)
        #expect(try await Fixture.context(of: fixture.hook(path: fixture.catalogue)) == Fixture.expectedLine)
    }

    /// A file the index never held adds nothing, near-duplicate or not: a first write of a whole file is not a reuse question.
    @Test func aFileTheIndexNeverHeldDrawsNothing() async throws {
        let fixture = try await Fixture()
        let crate = fixture.repo.appendingPathComponent("Sources/App/Crate.swift").path
        try ("struct Crate {\n" + Fixture.restock + "}\n").write(toFile: crate, atomically: true, encoding: .utf8)

        #expect(await fixture.hook("Write", path: crate).isEmpty)
    }

    /// Past the budget the hook gives up in silence, on the edit that would otherwise have been nudged.
    @Test func pastTheBudgetNothingIsPrinted() async throws {
        let fixture = try await Fixture()
        try fixture.addRestock()

        #expect(await fixture.hook(path: fixture.catalogue, budget: 0).isEmpty)
    }

    /// A parse error can lose the parser's grip on what a file actually declares, in either the reindex just made or the one before it that `before` was read from.
    ///
    /// An edit that leaves the file broken draws no nudge, only the block on its parse errors; the edit that repairs it draws nothing, because its `before` came from the broken parse; only the edit after that, with a real parse on both sides, can be judged.
    @Test func aParseErrorDrawsNothingUntilBothSidesParseAgain() async throws {
        let fixture = try await Fixture()

        try Fixture.brokenCatalogueSource.write(toFile: fixture.catalogue, atomically: true, encoding: .utf8)
        #expect(await !fixture.hook(path: fixture.catalogue).contains("hookSpecificOutput"))

        try Fixture.catalogueSource.write(toFile: fixture.catalogue, atomically: true, encoding: .utf8)
        #expect(await fixture.hook(path: fixture.catalogue).isEmpty)

        try fixture.addRestock()
        #expect(try await Fixture.context(of: fixture.hook(path: fixture.catalogue)) == Fixture.expectedLine)
    }

    /// A payload with no `session_id` draws nothing.
    ///
    /// There is no context to mark the nudge against, and falling back to a shared placeholder would let one session-less payload silence every later one.
    @Test func aPayloadWithNoSessionIDDrawsNothing() async throws {
        let fixture = try await Fixture()
        try fixture.addRestock()
        let recorded = RecordedOutput()
        let (marks, cwd) = (fixture.marks, fixture.repo.path)

        await InPlaceAnswerTests.onItsOwnThread {
            let payload: [String: Any] = ["tool_name": "Edit", "tool_input": ["file_path": fixture.catalogue], "cwd": cwd]
            PostToolUseCommand.answer(to: payload, output: recorded.output, marks: marks, timeBudget: InPlaceAnswerTests.roomy)
        }

        #expect(recorded.printed.isEmpty)
    }

    /// Two test functions marked `@Test` share their callees as siblings do, and the edit adding the second draws nothing.
    @Test func aTestFunctionIsNotNudgedTowardAnotherTest() async throws {
        let fixture = try await Fixture()
        let file = try await fixture.holdSuite("import Testing\n\nstruct Checks {\n    @Test func first() {\n\(Fixture.calls)    }\n}\n")
        try "import Testing\n\nstruct Checks {\n    @Test func first() {\n\(Fixture.calls)    }\n\n    @Test func second() {\n\(Fixture.calls)    }\n}\n"
            .write(toFile: file, atomically: true, encoding: .utf8)

        #expect(await fixture.hook(path: file).isEmpty)
    }

    /// The `test` methods of an `XCTestCase` subclass are tests too, and the edit adding a second draws nothing.
    @Test func anXCTestMethodIsNotNudgedTowardAnotherTest() async throws {
        let fixture = try await Fixture()
        let file = try await fixture.holdSuite("import XCTest\n\nfinal class Checks: XCTestCase {\n    func testfirst() {\n\(Fixture.calls)    }\n}\n")
        try "import XCTest\n\nfinal class Checks: XCTestCase {\n    func testfirst() {\n\(Fixture.calls)    }\n\n    func testsecond() {\n\(Fixture.calls)    }\n}\n"
            .write(toFile: file, atomically: true, encoding: .utf8)

        #expect(await fixture.hook(path: file).isEmpty)
    }

    /// A helper in a test file is still compared: one shaped like a production function is named, and so is a test function whose best remaining hit is not a test.
    @Test func aHelperInATestFileStillDrawsANudge() async throws {
        let fixture = try await Fixture()
        let file = try await fixture.holdSuite("import Testing\n\nstruct Checks {\n    @Test func first() {\n\(Fixture.calls)    }\n}\n")
        try "import Testing\n\nstruct Checks {\n    @Test func first() {\n\(Fixture.calls)    }\n\n    func shelve() {\n\(Fixture.stockCalls)    }\n}\n"
            .write(toFile: file, atomically: true, encoding: .utf8)
        let helper = try await Fixture.context(of: fixture.hook(path: file))
        #expect(helper?.hasPrefix("sift: Checks.shelve() resembles Depot.stock()") == true)

        try "import Testing\n\nstruct Checks {\n    @Test func first() {\n\(Fixture.calls)    }\n\n    @Test func second() {\n\(Fixture.stockCalls)    }\n}\n"
            .write(toFile: file, atomically: true, encoding: .utf8)
        let test = try await Fixture.context(of: fixture.hook(path: file, session: "s2"))
        #expect(test?.hasPrefix("sift: Checks.second() resembles Depot.stock()") == true)
    }

    /// A declaration the added one calls is what it is built on, not a copy of it.
    ///
    /// A new test driving `stock()` through the same calls is not told it resembles `stock()`. The same shape without the call is still named, in `aHelperInATestFileStillDrawsANudge`.
    @Test func aDeclarationTheAddedOneCallsIsNotNamedAsItsTwin() async throws {
        let fixture = try await Fixture()
        let file = try await fixture.holdSuite("import Testing\n\nstruct Checks {\n    @Test func first() {\n\(Fixture.calls)    }\n}\n")
        try "import Testing\n\nstruct Checks {\n    @Test func first() {\n\(Fixture.calls)    }\n\n    @Test func second() {\n        stock()\n\(Fixture.stockCalls)    }\n}\n"
            .write(toFile: file, atomically: true, encoding: .utf8)

        #expect(await fixture.hook(path: file).isEmpty)
    }
}

private extension PostToolUseCommandTests {
    /// An indexed repository holding a four-call function in one file and a type to edit in another, with the hook's marks somewhere this test owns.
    struct Fixture {
        static var catalogueSource: String {
            "struct Catalogue {\n    func count() -> Int {\n        1\n    }\n}\n"
        }

        /// `catalogueSource` with `restock()` added, wrapped in an unclosed enclosing type: the parser's recovery folds the whole file into one declaration under it, `Half.absorb()`, which reads the calls meant for `restock()` as its own — and would rank as a false near-duplicate of `Depot.stock()` if a parse error were not screened out.
        static var brokenCatalogueSource: String {
            """
            struct Half {
                func absorb() {
            struct Catalogue {
                func count() -> Int {
                    1
                }
                func restock() -> Int {
                    let crates = load()
                    let weight = weigh(crates)
                    label(crates, weight)
                    return ship(crates)
                }
            }

            """
        }

        static var restock: String {
            """
                func restock() -> Int {
                    let crates = load()
                    let weight = weigh(crates)
                    label(crates, weight)
                    return ship(crates)
                }

            """
        }

        static var expectedLine: String {
            "sift: Catalogue.restock() resembles Depot.stock() — Sources/App/Depot.swift:3 (overlap 1.00); compare with sift similar 'Catalogue.restock()'"
        }

        /// Four calls no other function in the fixture makes, as a function body.
        static var calls: String {
            "        let text = open()\n        let tree = parse(text)\n        check(tree, text)\n        return emit(tree)\n"
        }

        /// The four calls `Depot.stock()` makes, as a function body.
        static var stockCalls: String {
            "        let crates = load()\n        let weight = weigh(crates)\n        label(crates, weight)\n        return ship(crates)\n"
        }

        let repo: URL
        let marks: ReuseNudgeMarks

        init() async throws {
            repo = try MCPTestRepo.make(declaring: "Depot")
            let depot = """
            /// The test type.
            struct Depot {
                func stock() -> Int {
                    let crates = load()
                    let weight = weigh(crates)
                    label(crates, weight)
                    return ship(crates)
                }
            }

            """
            try MCPTestRepo.add(["Sources/App/Depot.swift": depot, "Sources/App/Catalogue.swift": Self.catalogueSource], to: repo)
            try await SiftEngine(directory: repo, registry: nil).ensureFresh()
            marks = try ReuseNudgeMarks(directory: TemporaryDirectory.make("nudge-marks"))
        }

        var catalogue: String {
            repo.appendingPathComponent("Sources/App/Catalogue.swift").path
        }

        /// Adds a file of `source` to the module, indexes it, and returns its path.
        func holdSuite(_ source: String) async throws -> String {
            try MCPTestRepo.add(["Sources/App/Suite.swift": source], to: repo)
            try await SiftEngine(directory: repo, registry: nil).ensureFresh()
            return repo.appendingPathComponent("Sources/App/Suite.swift").path
        }

        /// The edit under test: a function shaped exactly like `Depot.stock()` added to the catalogue.
        func addRestock() throws {
            try (Self.catalogueSource.dropLast(2) + "\n" + Self.restock + "}\n").write(toFile: catalogue, atomically: true, encoding: .utf8)
        }

        /// Sets the index back to before the edit and makes the edit again, so the added function is new to the index once more and only a mark can keep the hook quiet.
        func setBack() async throws {
            try Self.catalogueSource.write(toFile: catalogue, atomically: true, encoding: .utf8)
            try await SiftEngine(directory: repo, registry: nil).ensureFresh()
            try addRestock()
        }

        /// What the hook printed for `tool` on `path` in `session`, run off the concurrency pool as the hook's main thread would.
        func hook(_ tool: String = "Edit", path: String, session: String = "s1", budget: TimeInterval = InPlaceAnswerTests.roomy) async -> String {
            let recorded = RecordedOutput()
            let (marks, cwd) = (marks, repo.path)
            await InPlaceAnswerTests.onItsOwnThread {
                let payload: [String: Any] = ["tool_name": tool, "tool_input": ["file_path": path], "session_id": session, "cwd": cwd]
                PostToolUseCommand.answer(to: payload, output: recorded.output, marks: marks, timeBudget: budget)
            }
            return recorded.printed
        }

        /// The line a printed `PostToolUse` envelope hands the model.
        static func context(of printed: String, sourceLocation: SourceLocation = #_sourceLocation) throws -> String? {
            let object = try JSONSerialization.jsonObject(with: Data(printed.utf8)) as? [String: Any]
            let output = object?["hookSpecificOutput"] as? [String: Any]
            #expect(output?["hookEventName"] as? String == "PostToolUse", sourceLocation: sourceLocation)
            return output?["additionalContext"] as? String
        }
    }
}
