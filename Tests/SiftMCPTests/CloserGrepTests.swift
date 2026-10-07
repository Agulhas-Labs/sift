//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore
@testable import SiftMCP
import Testing

/// An outline grep of one file with a `^}` alternative, and a grep windowed by `sed -n`: answered in place where the digest accounts for every line, and let through where it cannot.
@Suite(.temporaryDirectories)
struct CloserGrepTests {
    /// Declaration alternatives beside `^}`, on a file whose every column-0 brace closes a top-level declaration, are the file's digest, which shows each of those closing lines as its range's end.
    @Test
    func declarationsBesideAClosingBraceAreTheDigest() async throws {
        let root = try await Self.repository()

        let answered = try #require(try await InPlaceAnswerTests.answered(
            #"grep -n "^struct Runner\|^extension Runner\|^private extension Runner\|^    enum Binding\|^    struct \|^}" Sources/App/Runner.swift"#, in: root
        ))

        #expect(answered.calls.map(\.tool) == ["digest"])
        #expect(answered.calls.map(\.target) == ["Sources/App/Runner.swift"])
        for range in Self.runnerRanges {
            #expect(answered.reason.contains(range))
        }
    }

    /// `^}` alone, cut by a `tail`, is the same digest: the lines it keeps are range ends the digest names.
    @Test
    func aClosingBraceAloneUnderATailIsTheDigest() async throws {
        let root = try await Self.repository()

        let answered = try #require(try await InPlaceAnswerTests.answered(#"grep -n "^}" Sources/App/Runner.swift | tail -3"#, in: root))

        #expect(answered.calls.map(\.target) == ["Sources/App/Runner.swift"])
    }

    /// An unquoted `^}` is a zsh parse error — `grep -n ^} File.swift` never runs, so no candidate names it — while the same alternative quoted, either kind, or escaped as `\}` is the digest's closing brace.
    @Test
    func anUnquotedClosingBraceIsNoCandidateButQuotedOrEscapedIs() {
        let root = "/nowhere"

        #expect(InPlaceShape.match(forShell: "grep -n ^} Sources/App/Runner.swift", in: root) == nil)
        #expect(InPlaceShape.match(forShell: #"grep -n "^}" Sources/App/Runner.swift"#, in: root) != nil)
        #expect(InPlaceShape.match(forShell: "grep -n '^}' Sources/App/Runner.swift", in: root) != nil)
        #expect(InPlaceShape.match(forShell: #"grep -n ^\} Sources/App/Runner.swift"#, in: root) != nil)
    }

    /// A top-level closer that isn't a bare `}` — trailing text or a trailing space — withholds the answer: only a line that reads `}` alone lets a grep's `^}` stand for the digest's range end.
    @Test
    func aClosingBraceWithTrailingContentIsWithheld() async throws {
        let root = try await Self.repository()

        #expect(try await InPlaceAnswerTests.outcome(#"grep -n "^}" Sources/App/CommentedClose.swift"#, in: root) == .withheld(.notExact))
        #expect(try await InPlaceAnswerTests.outcome(#"grep -n "^}" Sources/App/TrailingSpaceClose.swift"#, in: root) == .withheld(.notExact))
    }

    /// A `sed -n` window over an outline grep's output is a cut like `head`, and the outline is answered through it.
    @Test
    func anOutlineGrepUnderASedWindowIsTheDigest() async throws {
        let root = try await Self.repository()

        let answered = try #require(try await InPlaceAnswerTests.answered(
            #"grep -n "^struct \|^extension \|^private extension " Sources/App/Runner.swift | sed -n '1,80p'"#, in: root
        ))

        #expect(answered.calls.map(\.target) == ["Sources/App/Runner.swift"])
    }

    /// A member grep with context under a `sed -n` window serves the member's source, with nothing past it when the window keeps only lines inside it.
    @Test
    func aMemberGrepWithContextUnderASedWindowIsTheMembersSource() async throws {
        let root = try await InPlaceAnswerTests.reviewedRepository()

        let answered = try #require(try await InPlaceAnswerTests.answered(
            "grep -n 'func saves' -A 10 Sources/App/Store.swift | sed -n 1,3p", in: root
        ))

        #expect(answered.calls.map(\.target) == ["Store.saves()"])
        #expect(!answered.reason.contains("the rest of the lines"))
    }

    /// A column-0 brace that no top-level range ends on — one inside a multi-line string, or one closing a closure a top-level statement passes — withholds the answer, whether or not a cut would have printed it.
    @Test
    func aClosingBraceNoTopLevelRangeEndsOnIsWithheld() async throws {
        let root = try await Self.repository()

        #expect(try await InPlaceAnswerTests.outcome(#"grep -n "^struct Banner\|^}" Sources/App/Banner.swift"#, in: root) == .withheld(.notExact))
        #expect(try await InPlaceAnswerTests.outcome(#"grep -n "^}" Sources/App/Banner.swift | tail -1"#, in: root) == .withheld(.notExact))
        #expect(try await InPlaceAnswerTests.outcome(#"grep -n "^}" Sources/App/Launch.swift | head -1"#, in: root) == .withheld(.notExact))
    }

    /// A `sed` script that is anything but one line or one range of lines is not a cut, and the grep is no candidate.
    @Test
    func aSedScriptBeyondOneRangeIsNoCandidate() {
        let root = "/nowhere"

        #expect(InPlaceShape.match(forShell: #"grep -n "^struct " Sources/App/Runner.swift | sed -n '1,80p;90p'"#, in: root) == nil)
        #expect(InPlaceShape.match(forShell: #"grep -n "^struct " Sources/App/Runner.swift | sed -n '/x/p'"#, in: root) == nil)
        #expect(InPlaceShape.match(forShell: #"grep -n "^struct " Sources/App/Runner.swift | sed -n '9,2p'"#, in: root) == nil)
        #expect(InPlaceShape.match(forShell: #"grep -n "^struct " Sources/App/Runner.swift | sed -n '1,80p' Other.swift"#, in: root) == nil)
    }

    /// A window keeps the printed lines at its positions — the file lines a match sat on — not the positions of the window itself: matches scattered at file lines 3, 7, 9 and 12, windowed to the second and third match, print those two file lines, not 2 and 3.
    @Test
    func aSedWindowKeepsThePrintedLinesAtItsPositions() throws {
        let file = try TemporaryDirectory.make("closers").appendingPathComponent("Scattered.swift")
        let closers: Set = [3, 7, 9, 12]
        let source = (1 ... 12).map { closers.contains($0) ? "}" : "// line \($0)" }
        try (source.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        var search = try #require(ShellGrep(arguments: ["-n", "^}", file.path]))
        search.cut = ShellGrep.cut(ofStage: ["sed", "-n", "2,3p"])

        guard case let .printed(lines) = search.run(in: nil) else {
            Issue.record("expected the window's lines printed")
            return
        }

        #expect(lines.map(\.line) == [7, 9])
        #expect(ShellGrep.cut(ofStage: ["sed", "-n", "4p"]) == .window(4 ... 4))
    }
}

extension CloserGrepTests {
    /// The ranges the runner's digest shows for its top-level declarations, each ending on a column-0 brace.
    static let runnerRanges = [":1-211", ":213-215", ":217-219"]

    /// A repository with three files long enough to be digested: a runner whose every column-0 brace closes a top-level declaration, a banner holding one inside a multi-line string, and a launch file closing a top-level statement's closure at column 0.
    static func repository() async throws -> URL {
        let root = try MCPTestRepo.make(declaring: "Alpha")
        let fillers = (0 ..< 40).flatMap { index in
            ["    func stock\(index)() -> Int {", "        let count = \(index)", "        let doubled = count * 2", "        return doubled + count", "    }"]
        }
        let runner = ["struct Runner {", "    enum Binding {", "        case one", "    }", "    struct Step {", "        let name: String", "    }", "    private struct Hidden {", "        let value: Int", "    }"]
            + fillers
            + ["}", "", "extension Runner {", "    func walk() {}", "}", "", "private extension Runner {", "    func hidden() {}", "}"]
        let banner = ["struct Banner {", "    static let text = \"\"\"", "}", "\"\"\""] + fillers + ["}"]
        let launch = ["struct Launch {"] + fillers + ["}", "", "run {", "    step()", "}"]
        let commentedClose = ["struct CommentedClose {"] + fillers + ["} // end"]
        let trailingSpaceClose = ["struct TrailingSpaceClose {"] + fillers + ["} "]
        try MCPTestRepo.add([
            "Sources/App/Runner.swift": runner.joined(separator: "\n") + "\n",
            "Sources/App/Banner.swift": banner.joined(separator: "\n") + "\n",
            "Sources/App/Launch.swift": launch.joined(separator: "\n") + "\n",
            "Sources/App/CommentedClose.swift": commentedClose.joined(separator: "\n") + "\n",
            "Sources/App/TrailingSpaceClose.swift": trailingSpaceClose.joined(separator: "\n") + "\n",
        ], to: root)
        try await SiftEngine(directory: root).ensureFresh()
        return root
    }
}
