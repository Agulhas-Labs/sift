//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore
@testable import SiftMCP
import Testing

/// An `awk` whole read and a `sed`/`awk` pattern range, answered in place only where what they print is proven.
@Suite(.temporaryDirectories)
struct RangeReadTests {
    /// The fixture's one Swift file: members whose ranges a pattern can pick out, one whose closure closes at the member's own indent, and two whose names open alike.
    private static var depot: String {
        """
        /// A depot.
        struct Depot {
            func commitAll() -> Int {
                let values = [1, 2].map { value in
                    value * 2
                }
                return values.count
            }

            static func accessibilityNotes() -> String {
                "notes"
            }

            func nested() -> Int {
                let run = {
                    1
            }
                return run()
            }

            func commit() -> Int {
                commitAll()
            }
        }

        func trailing() -> Int {
            1
        }

        """
    }

    private static func repository() async throws -> URL {
        let root = try MCPTestRepo.make(declaring: "Alpha")
        try depot.write(to: root.appendingPathComponent("Sources/App/Depot.swift"), atomically: true, encoding: .utf8)
        try await SiftEngine(directory: root).ensureFresh()
        return root
    }

    /// What the answerer makes of `command` in `root`, on a thread of its own as the hook runs it.
    private static func outcome(_ command: String, in root: URL, sourceLocation: SourceLocation = #_sourceLocation) async throws -> InPlaceAnswerer.Outcome {
        let match = try #require(InPlaceShape.match(forShell: command, in: root.path), "\(command) is not a candidate", sourceLocation: sourceLocation)
        let backoff = try InPlaceAnswerTests.backoff()
        return await InPlaceAnswerTests.onItsOwnThread {
            InPlaceAnswerer.answer(match, timeBudget: InPlaceAnswerTests.roomy, backoff: backoff)
        }
    }

    /// Lines `first` through `last` of the fixture, as `sed` would print them.
    private static func lines(_ first: Int, _ last: Int) -> String {
        depot.components(separatedBy: "\n")[(first - 1) ..< last].joined(separator: "\n")
    }

    /// An `awk` program that prints every line is a whole read, answered with the file's digest as `cat -n` is — standing alone and after a `cd`.
    ///
    /// It reads a file of forty members rather than this suite's own, whose digest is no smaller than it and so is not served for a whole read of it.
    @Test(arguments: [
        "awk '{print NR\": \"$0}' Sources/App/Depot.swift",
        "awk '{print}' Sources/App/Depot.swift",
        "awk 1 Sources/App/Depot.swift",
        "cd Sources && awk '{print NR\": \"$0}' App/Depot.swift",
    ])
    func anAwkWholeReadIsAnsweredAsARead(command: String) async throws {
        let root = try await InPlaceAnswerTests.indexedRepository()
        guard case let .answered(answered) = try await Self.outcome(command, in: root) else {
            Issue.record("\(command) was not answered")
            return
        }

        #expect(answered.calls.map(\.target) == ["Sources/App/Depot.swift"])
    }

    /// A numbering `awk` cut by `head` is a window, answered with the members it overlaps, which are smaller than the file's digest and than the lines the window prints.
    @Test
    func aNumberingAwkCutByHeadIsAnsweredWithItsMembers() async throws {
        let root = try await InPlaceAnswerTests.indexedRepository(padding: InPlaceAnswerTests.pastTheFloor)
        let command = "awk '{print NR\": \"$0}' Sources/App/Depot.swift | head -150"
        guard case let .answered(answered) = try await Self.outcome(command, in: root) else {
            Issue.record("\(command) was not answered")
            return
        }

        #expect(answered.calls.map(\.target) == ["Sources/App/Depot.swift:1-150"])
        #expect(answered.reason.contains("struct Depot"))
    }

    /// A range whose lines are exactly one member's is answered with that member's source, which holds every line the command prints.
    @Test(arguments: [
        "sed -n '/static func accessibilityNotes/,/^    }/p' Sources/App/Depot.swift",
        "awk '/static func accessibilityNotes/,/^    }/' Sources/App/Depot.swift",
        "sed -n '/func commitAll()/,/^    }/p' Sources/App/Depot.swift",
        "awk '/func commitAll\\(\\)/ , /^    }/' Sources/App/Depot.swift",
    ])
    func aRangeOfOneMemberIsAnsweredWithItsSource(command: String) async throws {
        let root = try await Self.repository()
        guard case let .answered(answered) = try await Self.outcome(command, in: root) else {
            Issue.record("\(command) was not answered")
            return
        }
        let (member, printed) = command.contains("accessibilityNotes") ? ("accessibilityNotes", Self.lines(10, 12)) : ("commitAll", Self.lines(3, 8))

        #expect(answered.calls.map(\.target) == ["Depot.\(member)()"])
        #expect(answered.reason.contains(printed))
    }

    /// Every range whose printed lines are not proven to be one member's is withheld: START matching twice, END matching inside the member or past its end, and START matching no declaration.
    @Test(arguments: [
        "sed -n '/func commit/,/^    }/p' Sources/App/Depot.swift",
        "sed -n '/func nested/,/^    }/p' Sources/App/Depot.swift",
        "awk '/func nested/,/^    }/' Sources/App/Depot.swift",
        "sed -n '/static func accessibilityNotes/,/func nested/p' Sources/App/Depot.swift",
        "sed -n '/value \\* 2/,/^    }/p' Sources/App/Depot.swift",
        "sed -n '/^func trailing/,$p' Sources/App/Depot.swift",
    ])
    func aRangeNotProvenToBeOneMemberIsWithheld(command: String) async throws {
        let root = try await Self.repository()
        let outcome = try await Self.outcome(command, in: root)

        #expect(outcome == .withheld(.notExact))
    }

    /// A pattern `sed` or `awk` reads differently from the in-process matcher, or one it cannot read at all, is no candidate: BSD `sed` reads `\+` as a plus and knows no `\s`, and `awk` no `\<`.
    @Test(arguments: [
        "sed -n '/func commitAll()\\s/,/^    }/p' Sources/App/Depot.swift",
        "sed -n '/static func accessibilityNotes\\+/,/^    }/p' Sources/App/Depot.swift",
        "awk '/\\<accessibilityNotes/,/^    }/' Sources/App/Depot.swift",
        "awk '/accessibilityNotes{1}/,/^    }/' Sources/App/Depot.swift",
        "sed -n '/accessibilityNotes/,/^    }/p;p' Sources/App/Depot.swift",
        "sed -n '/accessibilityNotes/,/^    }/p' Sources/App/Depot.swift | cut -c1-5",
    ])
    func anUnreadRangeIsNoCandidate(command: String) {
        #expect(InPlaceShape.match(forShell: command, in: "/repo") == nil)
    }

    /// An `awk` whole read is no candidate where an option or a `VAR=value` operand rides beside the program: either changes what prints, so the digest offered in `awk '{print}' F`'s place no longer accounts for it.
    @Test(arguments: [
        "awk -v ORS=' ' '{print}' Sources/App/Depot.swift | head -1",
        "awk -v RS='}' '{print}' Sources/App/Depot.swift | sed -n '150,153p'",
        "awk '{print}' ORS=' ' Sources/App/Depot.swift | head -n 1",
    ])
    func anAwkWholeReadWithOptionsOrAssignmentsIsNoCandidate(command: String) {
        #expect(InPlaceShape.match(forShell: command, in: "/repo") == nil)
    }

    /// A whole read or window is no candidate where a second operand names a file that is not the one Swift file: the real command prints from both, not from the Swift one alone.
    @Test
    func aReadOfSeveralFilesWhereOnlyOneIsSwiftIsNoCandidate() {
        #expect(InPlaceShape.match(forShell: "cat Sources/App/Depot.swift README.md | tail -2", in: "/repo") == nil)
    }

    /// A `head`/`tail` count written in digits the system binary cannot parse — Unicode digits that are not ASCII — is no candidate: BSD `head`/`tail` exits 1 on such a count and prints nothing, so no digest stands in for it.
    @Test(arguments: [
        "cat Sources/App/Depot.swift | head -٣",
        "cat -n Sources/App/Depot.swift | head -n ٣",
        "awk '{print}' Sources/App/Depot.swift | head -n ٣",
    ])
    func anIllegalHeadCountIsNoCandidate(command: String) {
        #expect(InPlaceShape.match(forShell: command, in: "/repo") == nil)
    }
}
