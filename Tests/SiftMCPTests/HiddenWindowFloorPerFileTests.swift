//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
@testable import SiftMCP
import Testing

/// A line of several parts is denied only where every window whose lines its answer does not show saves the floor on its own, so a large read beside small windows never pays for lines the answer hides.
@Suite(.temporaryDirectories)
struct HiddenWindowFloorPerFileTests {
    /// The outcome for `command` run from `root`, on a thread of its own as the hook runs it.
    private static func outcome(_ command: String, in root: URL, sourceLocation: SourceLocation = #_sourceLocation) async throws -> InPlaceAnswerer.Outcome {
        let match = try #require(InPlaceShape.match(forShell: command, in: root.path), "\(command) is not a candidate", sourceLocation: sourceLocation)
        let backoff = try InPlaceAnswerTests.backoff()
        return await InPlaceAnswerTests.onItsOwnThread {
            InPlaceAnswerer.answer(match, timeBudget: InPlaceAnswerTests.roomy, backoff: backoff)
        }
    }

    /// The indexed repository holding `Depot`, forty five-line members from line 3, beside `Crate`, `Pallet` and `Hamper`, thirty six-line members each from line 3.
    private static func repository() async throws -> URL {
        let root = try await InPlaceAnswerTests.indexedRepository(padding: 80)
        for name in ["Crate", "Pallet", "Hamper"] {
            let members = (1 ... 30).map { "    func item\($0)() -> Int {\n        let count = \($0) // \(String(repeating: "x", count: 60))\n        let doubled = count * 2\n        let tripled = count * 3\n        return doubled + tripled\n    }" }
            try ("/// A \(name.lowercased()).\nstruct \(name) {\n" + members.joined(separator: "\n") + "\n}\n")
                .write(to: root.appendingPathComponent("Sources/App/\(name).swift"), atomically: true, encoding: .utf8)
        }
        try await SiftEngine(directory: root).ensureFresh()
        return root
    }

    /// Three windows a few members long, each of which runs alone, as the reading that once hid them beside a large read put them.
    private static let smallWindows = [
        "sed -n 20,40p Sources/App/Crate.swift",
        "sed -n 50,80p Sources/App/Pallet.swift",
        "sed -n 90,115p Sources/App/Hamper.swift",
    ]

    /// Three small windows whose answer would not show their lines run beside a large read, a window or a whole one, whose own saving clears the floor many times over: the line runs as `linesNotShown`.
    ///
    /// Each small window's own bytes are weighed without the framing the line shares, so a window that runs alone can still be denied beside a large read.
    @Test(arguments: ["sed -n 1,200p Sources/App/Depot.swift", "cat Sources/App/Depot.swift"])
    func smallWindowsHidingTheirLinesRunBesideALargeRead(large: String) async throws {
        let root = try await Self.repository()
        for window in Self.smallWindows {
            let alone = try await Self.outcome(window, in: root)
            #expect(!alone.isAnswered, "\(window) alone: \(alone)")
        }
        let largeAlone = try await Self.outcome(large, in: root)
        #expect(largeAlone.isAnswered, "\(large) alone: \(largeAlone)")

        let line = (Self.smallWindows + [large]).joined(separator: "; ")
        #expect(try await Self.outcome(line, in: root) == .withheld(.linesNotShown))
    }

    /// One small window beside the large read is not paid for by it either: a single hidden window runs the line too.
    @Test
    func oneSmallWindowBesideALargeReadRunsTheLine() async throws {
        let root = try await Self.repository()

        let line = "sed -n 20,40p Sources/App/Crate.swift; sed -n 1,200p Sources/App/Depot.swift"

        #expect(try await Self.outcome(line, in: root) == .withheld(.linesNotShown))
    }

    /// Windows each of which saves the floor on its own are still answered together, the line's shared framing left out of each file's weighing.
    @Test
    func windowsEachClearingTheFloorAreAnsweredTogether() async throws {
        let root = try await Self.repository()
        let windows = ["sed -n 1,200p Sources/App/Depot.swift", "sed -n 3,180p Sources/App/Crate.swift"]
        for window in windows {
            let alone = try await Self.outcome(window, in: root)
            #expect(alone.isAnswered, "\(window) alone: \(alone)")
        }

        let outcome = try await Self.outcome(windows.joined(separator: "; "), in: root)

        guard case let .answered(answered) = outcome else {
            Issue.record("expected an answer, got \(outcome)")
            return
        }

        #expect(answered.calls.map { $0.target.hasPrefix("Sources/App/Depot.swift") } == [true, false])
    }
}

private extension InPlaceAnswerer.Outcome {
    /// Whether this outcome is an answer.
    var isAnswered: Bool {
        if case .answered = self {
            return true
        }
        return false
    }
}
