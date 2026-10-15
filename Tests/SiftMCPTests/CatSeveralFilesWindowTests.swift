//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
@testable import SiftMCP
import Testing

/// A `cat` of several Swift files piped into a line window that picks only lines of the first file is decided as the window on that file alone is.
@Suite(.temporaryDirectories)
struct CatSeveralFilesWindowTests {
    /// A window on the first file is decided as that window on the first file alone: `head` is withheld as no smaller than its lines, as the single-file control is.
    @Test
    func aWindowOnTheFirstFileIsWithheldAsNoSmaller() async throws {
        let root = try await CatSeveralFilesVerdictTests.repository()

        let alone = try await Self.decided("cat Sources/App/Large.swift | head", in: root)
        let several = try await Self.decided("cat Sources/App/Large.swift Sources/App/Other.swift | head", in: root)

        #expect(alone == "allowed\t\tnotSmaller", "\(alone)")
        #expect(several == "allowed\t\tnotSmaller", "\(several)")
    }

    @Test(arguments: ["head -20", "sed -n '3,9p'"])
    func aNumberedWindowOnTheFirstFileIsDecidedAsItIsAlone(window: String) async throws {
        let root = try await CatSeveralFilesVerdictTests.repository()

        let alone = try await Self.decided("cat -n Sources/App/Large.swift | \(window)", in: root)
        let several = try await Self.decided("cat -n Sources/App/Large.swift Sources/App/Other.swift | \(window)", in: root)

        #expect(several == alone, "\(several) against \(alone)")
        #expect(!several.hasSuffix("notAnswerable"), "\(several)")
    }

    /// A window reaching past the first file, a first file whose last line runs into the next, and a file that is not there are each left as they were.
    @Test(arguments: [
        "cat Sources/App/Large.swift Sources/App/Other.swift | tail -5",
        "cat Sources/App/Large.swift Sources/App/Other.swift | head -700",
        "cat Sources/App/Unended.swift Sources/App/Other.swift | head",
        "cat Sources/App/Large.swift Sources/App/Gizmo.swift | head",
    ])
    func aWindowThatCouldPrintAnotherFileIsNotAnswered(command: String) async throws {
        let root = try await CatSeveralFilesVerdictTests.repository()
        try String(repeating: "let unended = 1\n", count: 40).appending("let last = 2")
            .write(to: root.appendingPathComponent("Sources/App/Unended.swift"), atomically: true, encoding: .utf8)

        let decided = try await Self.decided(command, in: root)

        #expect(decided == "allowed\t\tnotAnswerable", "\(decided)")
    }

    /// The verdict line the hook prints for `command` in `root`, answered by the real answerer with a roomy budget and a scratch back-off, or `none` where it gives none.
    private static func decided(_ command: String, in root: URL) async throws -> String {
        try await CatSeveralFilesVerdictTests.decide(command, in: root).verdict?.line ?? "none"
    }
}
