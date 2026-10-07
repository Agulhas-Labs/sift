//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore
@testable import SiftMCP
import Testing

/// A window whose answer does not show its lines is answered only where it saves four kibibytes, so one saving a little or a good deal under that runs and one clear of it is still answered.
@Suite(.temporaryDirectories) struct WindowSavingFloorTests {
    /// The command whose window, lines 50-54 of the depot, is padded to a chosen size.
    private static var command: String {
        "sed -n '50,54p' Sources/App/Depot.swift"
    }

    /// Writes the depot of forty five-line functions with its line 50 carrying a trailing comment of `padding` bytes.
    private static func write(padding: Int, in root: URL) throws {
        var lines = ["/// A depot.", "struct Depot {"]
        for index in 1 ... 40 {
            lines += ["    func stock\(index)() -> Int {", "        let count = \(index)", "        let doubled = count * 2", "        return doubled + count", "    }"]
        }
        lines += ["}"]
        lines[49] += " //" + String(repeating: "x", count: padding)
        try (lines.joined(separator: "\n") + "\n").write(to: root.appendingPathComponent("Sources/App/Depot.swift"), atomically: true, encoding: .utf8)
    }

    /// What the hook does with the window as the file stands now.
    private static func outcome(in root: URL, sourceLocation: SourceLocation = #_sourceLocation) async throws -> InPlaceAnswerer.Outcome {
        let match = try #require(InPlaceShape.match(forShell: command, in: root.path), sourceLocation: sourceLocation)
        let backoff = try InPlaceAnswerTests.backoff()
        return await InPlaceAnswerTests.onItsOwnThread {
            InPlaceAnswerer.answer(match, timeBudget: InPlaceAnswerTests.roomy, deadline: .unbounded, backoff: backoff)
        }
    }

    /// The floor is four kibibytes.
    @Test
    func theFloorIsFourKibibytes() {
        #expect(InPlaceAnswer.windowSavingFloor == 4096)
    }

    /// A window saving about one and then about three kibibytes, over the old floor and under the new, runs as `linesNotShown`; one saving about eight is answered.
    @Test
    func aSavingUnderFourKibibytesRunsAndOneAboveIsAnswered() async throws {
        let root = try MCPTestRepo.make(declaring: "Alpha")
        try Self.write(padding: 8000, in: root)
        guard case let .answered(roomy) = try await Self.outcome(in: root) else {
            Issue.record("a window of 8 kB is answered")
            return
        }
        // The window's source is its listing plus the saving, whatever the framing about the listing weighs.
        let served = roomy.reason.utf8.count

        for saving in [1500, 3000] {
            try Self.write(padding: served + saving, in: root)
            let outcome = try await Self.outcome(in: root)
            #expect(outcome == .withheld(.linesNotShown), "a window saving about \(saving) B: \(outcome)")
        }
        try Self.write(padding: served + 8000, in: root)
        let above = try await Self.outcome(in: root)

        #expect(above.answeredReason != nil, "a window saving about 8000 B: \(above)")
    }
}

private extension InPlaceAnswerer.Outcome {
    /// The reason of an answer, `nil` where the outcome is not one.
    var answeredReason: String? {
        if case let .answered(answered) = self {
            return answered.reason
        }
        return nil
    }
}
