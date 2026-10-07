//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
@testable import SiftCore
@testable import SiftMCP
import Testing

/// The `PostToolUse` hook blocks on an edit that left a Swift file unparseable, naming each error, once per content, and says nothing otherwise.
@Suite(.temporaryDirectories)
struct EditParseCheckTests {
    /// The block the check exists for: every error placed at `path:line:col` under the repository, then what the edit left.
    ///
    /// Outside an indexed repository the reason stops there, since there is no index whose answers the broken file could thin.
    @Test func anUnparseableEditIsBlockedWithEachErrorPlaced() async throws {
        let fixture = try EditParseFixture()
        try fixture.write(EditParseFixture.broken)

        let printed = await fixture.hook()

        #expect(try EditParseFixture.reason(of: printed) == """
        sift: syntax errors after this edit:
        Sources/App/Depot.swift:3:21 expected expression after operator
        Sources/App/Depot.swift:3:21 expected ')' to end tuple
        Sources/App/Depot.swift:4:6 expected '}' to end struct
        The edit left Sources/App/Depot.swift unparseable; fix it before going on.
        """)
    }

    /// In an indexed repository the reason says what the broken file costs: the index holds only what the parser recovered from it.
    ///
    /// The block is all that is printed. A nudge is never drawn from a file that does not parse, and the one thing worth doing next is fixing it.
    @Test func inAnIndexedRepositoryTheReasonSaysWhatTheIndexHolds() async throws {
        let fixture = try EditParseFixture()
        try await SiftEngine(directory: fixture.repo, registry: nil).ensureFresh()
        try fixture.write(EditParseFixture.broken)

        let printed = await fixture.hook()

        #expect(try EditParseFixture.reason(of: printed)?.hasSuffix(
            "fix it before going on. Until it parses again, sift indexes only what the parser recovered from it, so answers about it may be missing declarations."
        ) == true)
        #expect(!printed.contains("hookSpecificOutput"))
        #expect(printed.split(separator: "\n").count == 1)
    }

    /// A broken file the index's inclusion rule leaves out gets the block without the sentence about the index: the sentence would be false of it.
    @Test func aGitIgnoredBrokenFileIsBlockedWithoutTheIndexSentence() async throws {
        let fixture = try EditParseFixture()
        try fixture.writeAtRoot(".gitignore", "Ignored/\n")
        try await SiftEngine(directory: fixture.repo, registry: nil).ensureFresh()
        let stray = try fixture.writeAtRoot("Ignored/Stray.swift", EditParseFixture.broken)

        let reason = try await EditParseFixture.reason(of: fixture.hook(path: stray))

        #expect(reason?.hasSuffix("The edit left Ignored/Stray.swift unparseable; fix it before going on.") == true)
        #expect(reason?.contains("sift indexes only") == false)
    }

    /// A new broken file the index does not hold yet but will keeps the sentence: the rule takes it, whether or not a row exists.
    @Test func aNewIncludableBrokenFileStillGetsTheIndexSentence() async throws {
        let fixture = try EditParseFixture()
        try await SiftEngine(directory: fixture.repo, registry: nil).ensureFresh()
        let fresh = try fixture.writeAtRoot("Sources/App/Fresh.swift", EditParseFixture.broken)

        let reason = try await EditParseFixture.reason(of: fixture.hook(path: fresh))

        #expect(reason?.hasSuffix("so answers about it may be missing declarations.") == true)
    }

    /// An edit that leaves the file parsing prints nothing at all.
    @Test func aCleanParseIsSilent() async throws {
        let fixture = try EditParseFixture()
        try fixture.write("struct Depot {\n    func go() -> Int {\n        (1 + 2)\n    }\n}\n")

        #expect(await fixture.hook().isEmpty)
    }

    /// The same broken content is blocked once per context, so an edit the model cannot or will not fix goes through the second time.
    ///
    /// A change to the file is new content and can draw a block again, and another session has not been shown the first one.
    @Test func theSameBrokenContentIsBlockedOnce() async throws {
        let fixture = try EditParseFixture()
        try fixture.write(EditParseFixture.broken)

        #expect(try await EditParseFixture.reason(of: fixture.hook()) != nil)
        #expect(await fixture.hook().isEmpty)

        try fixture.write(EditParseFixture.broken + "func stray( {\n")
        #expect(try await EditParseFixture.reason(of: fixture.hook()) != nil)
        #expect(await fixture.hook().isEmpty)

        #expect(try await EditParseFixture.reason(of: fixture.hook(session: "s2")) != nil)
    }

    /// Past the cap the errors are counted rather than named, so a file broken everywhere cannot flood the model's context.
    @Test func errorsPastTheCapAreCounted() async throws {
        let fixture = try EditParseFixture()
        let source = String(repeating: "func f( {\n", count: 9)
        try fixture.write(source)
        let errors = try #require(EditParseCheck.run(file: fixture.depot, root: fixture.repo.path)).errors.count
        try #require(errors > 5)

        let lines = try #require(await EditParseFixture.reason(of: fixture.hook())).split(separator: "\n")

        #expect(lines.count { $0.hasPrefix("Sources/App/Depot.swift:") } == 5)
        #expect(lines.contains("and \(errors - 5) more"))
    }

    /// The check fails open: a path that is not Swift, a file that is missing or cannot be read as text, and a payload short of a file path or a session all draw nothing.
    @Test func whateverCannotBeCheckedDrawsNothing() async throws {
        let fixture = try EditParseFixture()
        let notes = fixture.repo.appendingPathComponent("Notes.txt").path
        try EditParseFixture.broken.write(toFile: notes, atomically: true, encoding: .utf8)
        #expect(await fixture.hook(path: notes).isEmpty)

        #expect(await fixture.hook(path: fixture.repo.appendingPathComponent("Sources/App/Gone.swift").path).isEmpty)

        try Data([0xFF, 0xFE, 0x7B, 0x0A]).write(to: URL(fileURLWithPath: fixture.depot))
        #expect(await fixture.hook().isEmpty)

        try fixture.write(EditParseFixture.broken)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: fixture.depot)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fixture.depot) }
        #expect(await fixture.hook().isEmpty)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fixture.depot)

        #expect(await fixture.hook(payload: ["tool_name": "Edit", "tool_input": [String: Any](), "session_id": "s1"]).isEmpty)
        #expect(await fixture.hook(payload: ["tool_name": "Edit", "tool_input": ["file_path": fixture.depot]]).isEmpty)
        #expect(try await EditParseFixture.reason(of: fixture.hook()) != nil)
    }

    /// A file broken on purpose, such as a parser fixture, is not blocked on an edit that adds no error to it, though the edit moved its errors and rewrote the line one sits on.
    @Test func anEditOfAFileBrokenOnPurposeThatAddsNoErrorIsSilent() async throws {
        let fixture = try EditParseFixture()
        try fixture.write(EditParseFixture.brokenAgain)

        let hunk: [String: Any] = ["oldStart": 1, "oldLines": 3, "newStart": 1, "newLines": 4, "lines": [
            "+// A parser fixture: this does not parse.", " struct Depot {", "     func go() {", "-        let x = (1 +", "+        let total = (1 +",
        ]]

        #expect(await fixture.hook(response: ["originalFile": EditParseFixture.broken, "structuredPatch": [hunk]]).isEmpty)
    }

    /// An edit that fixes an error in one hunk and adds one with the same message in another is blocked for the new one: the message-only match pairs errors within a hunk only.
    @Test func anErrorFixedInOneHunkDoesNotExcuseTheSameMessageAddedInAnother() async throws {
        let fixture = try EditParseFixture()
        let numbered = (1 ... 20).map { "let v\($0) = \($0)" }
        let before = numbered.enumerated().map { $0.offset == 8 ? "let = 3" : $0.element }
        let after = numbered.enumerated().map { $0.offset == 8 ? "let y = 3" : $0.offset == 16 ? "let = 4" : $0.element }
        try fixture.write(after.joined(separator: "\n") + "\n")
        let first: [String: Any] = ["oldStart": 6, "newStart": 6, "lines": before[5 ... 7].map { " " + $0 } + ["-let = 3", "+let y = 3"] + before[9 ... 11].map { " " + $0 }]
        let second: [String: Any] = ["oldStart": 14, "newStart": 14, "lines": before[13 ... 15].map { " " + $0 } + ["-let v17 = 17", "+let = 4"] + before[17 ... 19].map { " " + $0 }]

        let reason = try await EditParseFixture.reason(of: fixture.hook(response: ["originalFile": before.joined(separator: "\n") + "\n", "structuredPatch": [first, second]]))

        #expect(reason == """
        sift: syntax errors this edit added (the file had 1 before it):
        Sources/App/Depot.swift:17:5 expected pattern in variable
        The edit left Sources/App/Depot.swift unparseable; fix it before going on.
        """)
    }

    /// A new error with the same message as an old one, placed above it, is the one named: the old one is matched where it now stands, not by message to whichever comes first.
    @Test func aNewSameMessageErrorAboveAnOldOneIsTheOneNamed() async throws {
        let fixture = try EditParseFixture()
        try fixture.write("let a = 1\nlet = 9\nlet b = 2\nlet = 3\nlet c = 4\n")
        let hunk: [String: Any] = ["oldStart": 1, "newStart": 1, "lines": [" let a = 1", "+let = 9", " let b = 2", " let = 3", " let c = 4"]]

        let reason = try await EditParseFixture.reason(of: fixture.hook(response: ["originalFile": "let a = 1\nlet b = 2\nlet = 3\nlet c = 4\n", "structuredPatch": [hunk]]))

        #expect(reason?.contains("Sources/App/Depot.swift:2:5 expected pattern in variable") == true)
        #expect(reason?.contains("Depot.swift:4:5") == false)
    }

    /// A payload with an empty patch and no original, and no `type` to say it created the file, is read as saying nothing, so a freshly broken file is blocked with every error.
    @Test func anEmptyPatchWithoutATypeSilencesNothing() async throws {
        let fixture = try EditParseFixture()
        try fixture.write(EditParseFixture.broken)
        let unknown = try await EditParseFixture.reason(of: fixture.hook())

        let reason = try await EditParseFixture.reason(of: fixture.hook(session: "s2", response: ["originalFile": NSNull(), "structuredPatch": [Any]()]))

        #expect(reason == unknown)
        #expect(reason?.split(separator: "\n").count == 5)
    }

    /// A CRLF file edited as Claude Code sends it, the original and the patch folded to LF, matches an error twenty lines below the hunk on the text of its own line, and blocks the same-message error the edit added.
    @Test func aCRLFFileMatchesErrorsOnTheTextOfTheirOwnLine() async throws {
        let fixture = try EditParseFixture()
        let numbered = (1 ... 24).map { "let v\($0) = \($0)" }
        let before = numbered.enumerated().map { $0.offset == 22 ? "let = 23" : $0.element }
        let after = before.enumerated().map { $0.offset == 2 ? "let = 3" : $0.element }
        try fixture.write(after.joined(separator: "\r\n") + "\r\n")
        let hunk: [String: Any] = ["oldStart": 1, "newStart": 1, "lines": before[0 ... 1].map { " " + $0 } + ["-let v3 = 3", "+let = 3"] + before[3 ... 5].map { " " + $0 }]

        let reason = try await EditParseFixture.reason(of: fixture.hook(response: ["originalFile": before.joined(separator: "\n") + "\n", "structuredPatch": [hunk]]))

        #expect(reason == """
        sift: syntax errors this edit added (the file had 1 before it):
        Sources/App/Depot.swift:3:5 expected pattern in variable
        The edit left Sources/App/Depot.swift unparseable; fix it before going on.
        """)
    }

    /// Where the payload carries the patch but not the original, the patch is undone against the file to find what it held, with the same verdict.
    @Test func thePatchIsUndoneWhereTheOriginalIsNotSent() async throws {
        let fixture = try EditParseFixture()
        try fixture.write(EditParseFixture.brokenAgain)
        let hunk: [String: Any] = ["oldStart": 1, "oldLines": 3, "newStart": 1, "newLines": 4, "lines": [
            "+// A parser fixture: this does not parse.", " struct Depot {", "     func go() {", "-        let x = (1 +", "+        let total = (1 +",
        ]]

        #expect(await fixture.hook(response: ["originalFile": NSNull(), "structuredPatch": [hunk]]).isEmpty)

        let stale: [String: Any] = ["newStart": 1, "lines": [" struct Elsewhere {"]]
        #expect(try await EditParseFixture.reason(of: fixture.hook(session: "s2", response: ["originalFile": NSNull(), "structuredPatch": [stale]])) != nil)
    }

    /// A file with CRLF line endings, edited as Claude Code sends it, the original and the patch folded to LF, is reconstructed from the patch alone and from the original, and an edit that adds no error to it is silent either way.
    @Test func aCRLFFileIsReconstructedFromItsLFPayload() async throws {
        let fixture = try EditParseFixture()
        try fixture.write(EditParseFixture.brokenAgain.replacingOccurrences(of: "\n", with: "\r\n"))
        let hunk: [String: Any] = ["oldStart": 1, "oldLines": 3, "newStart": 1, "newLines": 4, "lines": [
            "+// A parser fixture: this does not parse.", " struct Depot {", "     func go() {", "-        let x = (1 +", "+        let total = (1 +",
        ]]

        #expect(await fixture.hook(response: ["originalFile": NSNull(), "structuredPatch": [hunk]]).isEmpty)
        #expect(await fixture.hook(session: "s2", response: ["originalFile": EditParseFixture.broken, "structuredPatch": [hunk]]).isEmpty)
    }

    /// A file that parsed before the edit is blocked with every error the edit left, worded as when the payload says nothing of the file's past.
    @Test func aCleanFileTheEditBrokeIsBlockedWithEveryError() async throws {
        let fixture = try EditParseFixture()
        try fixture.write(EditParseFixture.broken)

        let reason = try await EditParseFixture.reason(of: fixture.hook(response: ["originalFile": "struct Depot {\n    func go() {}\n}\n"]))

        #expect(reason?.hasPrefix("sift: syntax errors after this edit:\nSources/App/Depot.swift:3:21 expected expression after operator\n") == true)
        #expect(reason?.split(separator: "\n").count == 5)
        let created = try await EditParseFixture.reason(of: fixture.hook(session: "s2", response: ["type": "create", "originalFile": NSNull(), "structuredPatch": [Any]()]))
        #expect(created == reason)
    }

    /// An edit that adds an error to a file already broken is blocked with the added error alone, and the reason says how many the file had before.
    @Test func anEditAddingAnErrorToABrokenFileNamesOnlyThatError() async throws {
        let fixture = try EditParseFixture()
        try fixture.write(EditParseFixture.broken + "let = 3\n")
        #expect(EditParseCheck.run(file: fixture.depot, root: fixture.repo.path)?.errors.count == 4)

        let hunk: [String: Any] = ["oldStart": 2, "newStart": 2, "lines": ["     func go() {", "         let x = (1 +", "     }", "+let = 3"]]

        let reason = try await EditParseFixture.reason(of: fixture.hook(response: ["originalFile": EditParseFixture.broken, "structuredPatch": [hunk]]))

        #expect(reason == """
        sift: syntax errors this edit added (the file had 3 before it):
        Sources/App/Depot.swift:5:5 expected pattern in variable
        The edit left Sources/App/Depot.swift unparseable; fix it before going on.
        """)
    }

    /// In a file whose lines break at a lone `"\r"`, which the parser counts as lines and the line text does not, an edit that fixes an error and adds one with the same message and column further down is blocked: a line the text cannot be read for never matches.
    @Test func anErrorOnALineTheTextCannotReadIsNotMatchedByItsColumn() {
        let numbered = (1 ... 20).map { "let v\($0) = \($0)" }
        let before = numbered.enumerated().map { $0.offset == 4 ? "let = 5" : $0.element }.joined(separator: "\r") + "\r"
        let after = numbered.enumerated().map { $0.offset == 17 ? "let = 5" : $0.element }.joined(separator: "\r") + "\r"
        let earlier = FileParser.errors(inSource: before, path: "A.swift")
        let later = FileParser.errors(inSource: after, path: "A.swift")

        #expect(earlier.map(\.line) == [5] && later.map(\.line) == [18])
        #expect(EditParseCheck.added(later, in: after, beyond: earlier, in: before) == later)
    }

    /// Claude Code makes each leading tab of a patch line two spaces, so where the original is not sent the patch of a tab-indented file is undone against the file with its leading tabs made two spaces, and an edit that adds no error to it is silent.
    @Test func aTabIndentedFileIsReconstructedFromItsConvertedPatch() async throws {
        let fixture = try EditParseFixture()
        try fixture.write(EditParseFixture.brokenAgain.replacingOccurrences(of: "    ", with: "\t"))
        let hunk: [String: Any] = ["oldStart": 1, "oldLines": 3, "newStart": 1, "newLines": 4, "lines": [
            "+// A parser fixture: this does not parse.", " struct Depot {", "   func go() {", "-    let x = (1 +", "+    let total = (1 +",
        ]]

        #expect(await fixture.hook(response: ["originalFile": NSNull(), "structuredPatch": [hunk]]).isEmpty)
    }

    /// A staged edit or a timed-out diff sends the original with an empty patch, so the message-only pass has no hunk to work in: an edit that rewrites the line of an error is blocked for it, as the design says.
    @Test func anEmptyPatchWithTheOriginalBlocksARewrittenErrorLine() async throws {
        let fixture = try EditParseFixture()
        try fixture.write(EditParseFixture.brokenAgain)

        let reason = try await EditParseFixture.reason(of: fixture.hook(response: ["originalFile": EditParseFixture.broken, "structuredPatch": [Any]()]))

        #expect(reason?.contains("Sources/App/Depot.swift:4:") == true)
    }

    /// Past the budget the hook gives up in silence, on the edit that would otherwise have been blocked.
    @Test func pastTheBudgetNothingIsPrinted() async throws {
        let fixture = try EditParseFixture()
        try fixture.write(EditParseFixture.broken)

        #expect(await fixture.hook(budget: 0).isEmpty)
    }
}

private extension EditParseCheckTests {
    /// A repository holding one Swift file to break, with the hook's marks somewhere the test owns.
    struct EditParseFixture {
        /// A function left with an unfinished expression and its type unclosed: three errors on two lines.
        static var broken: String {
            "struct Depot {\n    func go() {\n        let x = (1 +\n    }\n"
        }

        /// ``broken`` edited as a fixture is: a line added above its errors and the line one sits on rewritten, adding none.
        static var brokenAgain: String {
            "// A parser fixture: this does not parse.\nstruct Depot {\n    func go() {\n        let total = (1 +\n    }\n"
        }

        let repo: URL
        let marks: ReuseNudgeMarks

        init() throws {
            repo = try MCPTestRepo.make(declaring: "Depot")
            marks = try ReuseNudgeMarks(directory: TemporaryDirectory.make("parse-marks"))
        }

        var depot: String {
            repo.appendingPathComponent("Sources/App/Depot.swift").path
        }

        /// Replaces the file under test with `source`, as an edit would.
        func write(_ source: String) throws {
            try source.write(toFile: depot, atomically: true, encoding: .utf8)
        }

        /// Writes `source` to `relative` under the repository, making its directory, and returns the absolute path.
        @discardableResult
        func writeAtRoot(_ relative: String, _ source: String) throws -> String {
            let url = repo.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try source.write(to: url, atomically: true, encoding: .utf8)
            return url.path
        }

        /// What the hook printed for an edit of `path` in `session`, with `response` as the payload's `tool_response` where given, run off the concurrency pool as the hook's main thread would.
        func hook(path: String? = nil, session: String = "s1", response: [String: Any]? = nil, budget: TimeInterval = InPlaceAnswerTests.roomy) async -> String {
            var payload: [String: Any] = ["tool_name": "Edit", "tool_input": ["file_path": path ?? depot], "session_id": session]
            payload["tool_response"] = response
            return await hook(payload: payload, budget: budget)
        }

        /// What the hook printed for `payload`, with the repository as its working directory.
        func hook(payload: [String: Any], budget: TimeInterval = InPlaceAnswerTests.roomy) async -> String {
            let recorded = RecordedOutput()
            var payload = payload
            payload["cwd"] = repo.path
            let (marks, sent) = (marks, PayloadBox(payload))
            await InPlaceAnswerTests.onItsOwnThread {
                PostToolUseCommand.answer(to: sent.payload, output: recorded.output, marks: marks, timeBudget: budget)
            }
            return recorded.printed
        }

        /// The reason a printed block hands the model, or `nil` where nothing printed is a block.
        static func reason(of printed: String) throws -> String? {
            guard !printed.isEmpty else { return nil }
            let object = try JSONSerialization.jsonObject(with: Data(printed.utf8)) as? [String: Any]
            guard object?["decision"] as? String == "block" else { return nil }
            return object?["reason"] as? String
        }
    }

    /// A hook payload carried onto the hook's own thread; never mutated once made.
    final class PayloadBox: @unchecked Sendable {
        let payload: [String: Any]

        init(_ payload: [String: Any]) {
            self.payload = payload
        }
    }
}
