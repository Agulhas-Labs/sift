//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftMCP
import Testing

/// A lookup teed to a file is accounted as the lookup alone: the answer filed for it, the re-run that reads it anyway, the files it locates, and a `tee` inside a command substitution.
@Suite(.temporaryDirectories)
struct TeeAccountingTests {
    private static var read: String {
        "cat /repo/Sources/App/Shell.swift"
    }

    /// An answer given to a teed lookup is filed, and the same teed line run again, or any other spelling of the tee, takes it back as a read anyway.
    @Test
    func aTeedLookupRerunIsAReadAnyway() throws {
        let ledger = try AdviceLedger(directory: TemporaryDirectory.make("tee-accounting").appendingPathComponent("advice"))
        let teed = ["command": Self.read + " 2>&1 | tee out.txt"]
        ledger.noteAnswered(session: "s1", call: "toolu_1", targets: ["Sources/App/Shell.swift"], toolName: "Bash", input: teed, cwd: "/repo")

        let again = ledger.readAnyway(session: "s1", toolName: "Bash", input: ["command": Self.read + " 2>&1 | tee -a other.txt"], cwd: "/repo")

        #expect(again.map(\.call) == ["toolu_1"])
    }

    /// The reading of a teed call is the reading of the lookup alone.
    @Test
    func aTeedCallReadsTheFilesTheLookupAloneReads() {
        let teed = AnswerThenRead.files(readBy: ["name": "Bash", "input": ["command": Self.read + " | tee out.txt"]], cwd: "/repo")
        let bare = AnswerThenRead.files(readBy: ["name": "Bash", "input": ["command": Self.read]], cwd: "/repo")

        #expect(!bare.isEmpty)
        #expect(teed.map(\.reread) == bare.map(\.reread))
        #expect(teed.map(\.path) == bare.map(\.path))
    }

    /// A teed `sift where` locates what the lookup alone does.
    @Test
    func aTeedWhereLocatesAsTheWhereAlone() throws {
        let here = try MCPTestRepo.make()
        let teed = ShellAnswerSource.of(command: "sift where Alpha 2>&1 | tee out.txt", cwd: here.path)

        #expect(teed != nil)
        #expect(teed == ShellAnswerSource.of(command: "sift where Alpha", cwd: here.path))
    }

    /// A trailing `tee` inside a command substitution is taken out as one at the top level is, and the substitution is still judged as the lookup it holds.
    @Test
    func aTeeInsideACommandSubstitutionIsTakenOut() {
        let bare = "x=$(grep -n Foo Sources/A.swift)"
        let teed = "x=$(grep -n Foo Sources/A.swift | tee out.txt)"

        #expect(ShellInspection.withoutPassThroughTees(teed) == bare)
        #expect(ShellInspection.passThroughTeeFiles(teed) == ["out.txt"])
        #expect(ShellInspection.lookupLine(bare, holdsSource: nil) != nil)
        #expect(ShellInspection.lookupLine(teed, holdsSource: nil) == bare)
        #expect(ShellInspection.withoutPassThroughTees("echo \"$(grep -n Foo A.swift | tee -a a.txt)\" | tee b.txt") == "echo \"$(grep -n Foo A.swift)\"")
        #expect(ShellInspection.withoutPassThroughTees("x=$(cat Sources/A.swift | tee Sources/B.swift)") == "x=$(cat Sources/A.swift | tee Sources/B.swift)")
    }
}
