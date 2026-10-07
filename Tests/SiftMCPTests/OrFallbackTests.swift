//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore
@testable import SiftMCP
import Testing

/// A lookup in front of a `||` whose fallback could print is answered in place exactly where the lookup's own success is proven, so the fallback provably never ran — and refused as before wherever it could have.
@Suite(.temporaryDirectories)
struct OrFallbackTests {
    /// The outcome of answering `command` in `root`, or `nil` where it matches no answered shape.
    private static func outcome(_ command: String, in root: URL, sourceLocation: SourceLocation = #_sourceLocation) async throws -> InPlaceAnswerer.Outcome? {
        guard let match = InPlaceShape.match(forShell: command, in: root.path) else { return nil }
        #expect(match.fallbackFollows, "a printing fallback leaves the lookup's success to be proven", sourceLocation: sourceLocation)
        let backoff = try InPlaceAnswerTests.backoff()
        return await InPlaceAnswerTests.onItsOwnThread {
            InPlaceAnswerer.answer(match, timeBudget: InPlaceAnswerTests.roomy, backoff: backoff)
        }
    }

    /// A read, a grep that prints, and a pipeline ending in a line window all succeed, so the fallback never ran and the lookup's answer is the line's.
    @Test(arguments: [
        ("sed -n '1,9999p' Sources/App/Depot.swift 2>/dev/null || find . -iname Depot.swift", "struct Depot"),
        ("grep -n 'func stock3()' Sources/App/Depot.swift 2>/dev/null || find Sources -iname Depot.swift", "func stock3()"),
        ("cat -n Sources/App/Depot.swift 2>/dev/null | head -500 || find . -name 'Depot*.swift' -not -path './.build/*'", "struct Depot"),
        ("cd Sources && grep -n 'func stock' App/Depot.swift 2>/dev/null | head -5 || grep -rn 'struct Depot' .", "func stock"),
        ("sed -n '1,9999p' Sources/App/Depot.swift || find . -iname Depot.swift || echo none", "struct Depot"),
    ])
    func aLookupWhoseSuccessIsProvenIsAnsweredWithItsOwnAnswer(command: String, shown: String) async throws {
        let root = try await InPlaceAnswerTests.indexedRepository(padding: InPlaceAnswerTests.pastTheFloor)

        let outcome = try #require(try await Self.outcome(command, in: root))

        guard case let .answered(answered) = outcome else {
            Issue.record("expected an answer, got \(outcome)")
            return
        }

        #expect(answered.calls.allSatisfy { $0.tool == "digest" })
        #expect(answered.reason.contains(shown))
        #expect(!answered.reason.contains("find"), "the fallback never ran, so nothing of it is read or named")
    }

    /// A grep that prints nothing exits 1, and a read of a file that is not there fails, so the fallback ran and printed what no answer accounts for: the lookup's success is not proven, and the call runs.
    @Test(arguments: [
        "grep -n 'func stock99()' Sources/App/Depot.swift 2>/dev/null || find Sources -iname Depot.swift",
        "sed -n '1,30p' Sources/App/Missing.swift 2>/dev/null || find . -iname Missing.swift",
        "cat Sources/App/Missing.swift || find . -iname Missing.swift",
        "cd Sources && sed -n '1,30p' Depot.swift || find . -iname Depot.swift",
    ])
    func aLookupWhoseSuccessIsNotProvenIsWithheld(command: String) async throws {
        let root = try await InPlaceAnswerTests.indexedRepository()

        let outcome = try #require(try await Self.outcome(command, in: root))

        #expect(outcome == .withheld(.notExact))
    }

    /// A read of a file that is not there, is a directory, or is there but cannot be opened fails in the shell, so the fallback ran; the line is withheld as not exact before any engine is opened, and a repository with no index is left without one.
    @Test
    func aReadOfAFileThatCannotBeReadBehindAFallbackIsWithheldBeforeTheEngineOpens() async throws {
        let root = try MCPTestRepo.make(declaring: "Alpha")
        let unreadable = root.appendingPathComponent("Sources/App/Alpha.swift")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Sources/App/Folder.swift"), withIntermediateDirectories: true)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: unreadable.path) }
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: unreadable.path)

        var outcomes: [String: InPlaceAnswerer.Outcome?] = [:]
        for name in ["Missing", "Folder", "Alpha"] {
            outcomes[name] = try await Self.outcome("cat Sources/App/\(name).swift || find . -iname \(name).swift", in: root)
        }

        #expect(outcomes.values.allSatisfy { $0 == .withheld(.notExact) }, "\(outcomes)")
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".sift").path))
    }

    /// Wherever the fallback, or anything after it, could run whatever the lookup did — a `;` or an `&&` after it, a ride-along whose status is unknown in front, the whole list backgrounded — or the lookup is no answered shape, or a lone name grep whose success no answer shows, nothing is matched, and the call is refused exactly as it was.
    @Test(arguments: [
        "sed -n '1,30p' Sources/App/Depot.swift || find . -iname Depot.swift; find . -name '*.swift' | xargs wc -l",
        "sed -n '1,30p' Sources/App/Depot.swift || find . -iname Depot.swift && ls",
        "echo start && sed -n '1,30p' Sources/App/Depot.swift || find . -iname Depot.swift",
        "ls Sources; sed -n '1,30p' Sources/App/Depot.swift || find . -iname Depot.swift",
        "sed -n '1,30p' Sources/App/Depot.swift || find . -iname Depot.swift &",
        "sed -n '1,30p' Sources/App/notes.txt || find . -iname Depot.swift",
        "grep -rn 'Depot' Sources || find . -iname Depot.swift",
        "cd \"$DIR\" && sed -n '1,30p' Sources/App/Depot.swift || find . -iname Depot.swift",
    ])
    func aFallbackThatCouldRunIsRefusedAsBefore(command: String) {
        #expect(InPlaceShape.match(forShell: command, in: "/repo") == nil)
    }

    /// A name grep that ends in a line window succeeds whatever it prints, since the pipeline's status is the window's, so it is matched as it is alone.
    @Test
    func aNameGrepEndingInAWindowIsMatched() throws {
        let match = try #require(InPlaceShape.match(forShell: "grep -rn 'Depot' Sources | head -20 || find . -iname Depot.swift", in: "/repo"))

        #expect(match.fallbackFollows)
        #expect(match.call == InPlaceShape.match(forShell: "grep -rn 'Depot' Sources | head -20", in: "/repo")?.call)
    }

    /// A fallback proven silent needs no proof, so a lookup in front of `true` is matched without one, as it always was.
    @Test
    func aSilentFallbackNeedsNoProof() throws {
        let match = try #require(InPlaceShape.match(forShell: "sed -n '1,30p' Sources/App/Depot.swift || true", in: "/repo"))

        #expect(!match.fallbackFollows)
    }

    /// A leading `!` negates the list's exit status: a lookup that failed would read as though it succeeded, and one that succeeded would read as failed, so neither proves the lookup's own success and the match is refused.
    @Test(arguments: [
        "! sed -n '1,5p' Sources/App/Depot.swift || echo X",
        "! cat Sources/App/Depot.swift | head -5 || echo X",
        "! head -5 Sources/App/Depot.swift || echo X",
    ])
    func aLeadingNegationIsRefused(command: String) {
        #expect(InPlaceShape.match(forShell: command, in: "/repo") == nil)
    }

    /// A window a real shell would refuse on a bad option prints nothing an answer can stand on, so behind a fallback it is refused rather than read as the whole file's digest — the safe superset that same window answers with outside a fallback, but not proof here.
    @Test(arguments: [
        "head -n -5 Sources/App/Depot.swift || echo X",
        "head -n abc Sources/App/Depot.swift || echo X",
        "head --bogus Sources/App/Depot.swift || echo X",
        "tail -n x Sources/App/Depot.swift || echo X",
        "sed -n --bogus '1,5p' Sources/App/Depot.swift || echo X",
        "cat Sources/App/Depot.swift | head -n -5 || echo X",
    ])
    func aWindowOnABadOptionIsRefused(command: String) {
        #expect(InPlaceShape.match(forShell: command, in: "/repo") == nil)
    }

    /// An `awk` body that can act rather than only print — here an `exit` — may print nothing for a line the picking alone would have kept, so it is refused rather than trusted to have printed it.
    @Test
    func anAwkBodyThatCanActIsRefused() {
        #expect(InPlaceShape.match(forShell: "awk 'NR<=5{exit 1}' Sources/App/Depot.swift || echo X", in: "/repo") == nil)
    }

    /// A whole-line sweep behind a fallback prints nothing a `where` answer could stand in for, so it is never matched at all.
    @Test
    func aWholeLineSweepBehindAFallbackIsNotMatched() {
        #expect(InPlaceShape.match(forShell: "grep -rnwx Depot Sources || echo X", in: "/repo") == nil)
    }

    // The closed list of window stages the fallback proof accepts (``FallbackProof``), each run under zsh against a real
    // file with this machine's BSD tools and seen to exit 0. The stage that reads the file names it and nothing else; a
    // later stage names no file. Each stage may carry `2>/dev/null` or `2>&1` and no other redirection.
    //   cat   [-n]
    //   head  at most one of -N, -n N, -nN, --lines=N, --lines N, with N in 1...2147483647
    //   tail  at most one of -N, -n N, -nN, --lines=N, --lines N (N any number), -n +N, --lines=+N
    //   sed   -n with print windows only (-e S, or the first bare word without -e), no address 0, no long option
    //   awk   no option; NR comparisons, then no body, or {print} followed only by $0, $N (up to eight digits), NR,
    //         FNR and "strings" without \ or ", separated by spaces, commas or nothing
    // Everything else is refused, and a lookup piped into a cut is proven by its last stage alone, on the same list.

    /// Every form on the closed list is matched behind a fallback, the pipeline's last stage proven to exit 0 — where an `awk` action prints each line whole, since one that prints text of its own is no window the digest answers at all.
    @Test(arguments: [
        "tail -0 Sources/App/Depot.swift || echo X",
        #"awk 'NR<=5{print NR": "$0}' Sources/App/Depot.swift || echo X"#,
        "awk 'NR<=5{print $0}' Sources/App/Depot.swift || echo X",
        "awk 'NR==2,NR==4' Sources/App/Depot.swift || echo X",
        "head -n 2147483647 Sources/App/Depot.swift 2>/dev/null || echo X",
        "head --lines=5 Sources/App/Depot.swift || echo X",
        "tail --lines=+5 Sources/App/Depot.swift || echo X",
        "sed -n -e '1,5p' -e '7p' Sources/App/Depot.swift || echo X",
        "cat -n Sources/App/Depot.swift | tail -n +3 | head -2 || echo X",
        "head -5 Sources/App/Depot.swift | cat -n || echo X",
        "grep -rn Depot Sources | tail -n 0 || echo X",
    ])
    func aWindowOnTheClosedListIsMatched(command: String) throws {
        let match = try #require(InPlaceShape.match(forShell: command, in: "/repo"))

        #expect(match.fallbackFollows)
    }

    /// A `head` of zero lines exits 1 on the system `head`, wherever it stands in the pipeline and whatever reads in front of it, so the fallback ran and the match is refused — the names shape's cut included.
    @Test(arguments: [
        "head -0 Sources/App/Depot.swift || echo X",
        "head -n 0 Sources/App/Depot.swift || echo X",
        "head -n 00 Sources/App/Depot.swift || echo X",
        "head --lines=0 Sources/App/Depot.swift || echo X",
        "cat Sources/App/Depot.swift | head -0 || echo X",
        "cat -n Sources/App/Depot.swift | head -0 || echo X",
        "head -1 Sources/App/Depot.swift | head -0 || echo X",
        "cat Sources/App/Depot.swift | sed -n '1,50p' | head -0 || echo X",
        "grep -rn Depot Sources | head -0 || echo X",
    ])
    func aHeadOfZeroLinesIsRefused(command: String) {
        #expect(InPlaceShape.match(forShell: command, in: "/repo") == nil)
    }

    /// An `awk` body beyond `print` and its allowlisted terms can write, pipe, fail or print something else, so it is refused.
    @Test(arguments: [
        #"awk 'NR<=5{print > "/nonexistent/x"}' Sources/App/Depot.swift || echo X"#,
        #"awk 'NR<=5{print >> "/nonexistent/x"}' Sources/App/Depot.swift || echo X"#,
        "awk 'NR<=5{print 1/0}' Sources/App/Depot.swift || echo X",
        #"awk 'NR<=5{print | "false"}' Sources/App/Depot.swift || echo X"#,
        "awk 'NR<=5{print getline}' Sources/App/Depot.swift || echo X",
        #"awk 'NR<=5{print system("false")}' Sources/App/Depot.swift || echo X"#,
        "awk 'NR<=5{print $0,}' Sources/App/Depot.swift || echo X",
        "awk 'NR<=5{print $99999999999}' Sources/App/Depot.swift || echo X",
        #"awk 'NR<=5{print "a\"b"}' Sources/App/Depot.swift || echo X"#,
    ])
    func anAwkBodyBeyondPrintAndItsTermsIsRefused(command: String) {
        #expect(InPlaceShape.match(forShell: command, in: "/repo") == nil)
    }

    /// Every other way off the closed list fails on the system tools with the file there to read — a second operand, a long `sed` option, a script read as a file, a field separator, a count past `head`'s bound, a second count — so each is refused.
    @Test(arguments: [
        "head -5 Sources/App/Depot.swift nothere.txt || echo X",
        "sed -n '1,5p' Sources/App/Depot.swift nothere.txt || echo X",
        "sed -n '1,5p' '2p' Sources/App/Depot.swift || echo X",
        "sed -n --expression '1,5p' Sources/App/Depot.swift || echo X",
        "awk 'NR<=5' Sources/App/Depot.swift nothere.txt || echo X",
        "awk -F '[(' 'NR<=5{print $1}' Sources/App/Depot.swift || echo X",
        "head -n 2147483648 Sources/App/Depot.swift || echo X",
        "tail -0 -n +5 Sources/App/Depot.swift || echo X",
        "grep -rn Depot Sources | head -n 99999999999 || echo X",
    ])
    func aStageOffTheClosedListIsRefused(command: String) {
        #expect(InPlaceShape.match(forShell: command, in: "/repo") == nil)
    }

    /// The system tools stop reading options at the first operand, so an option after the file is one more file to open and the command exits 1, and a digit outside ASCII in a `sed` address is no address at all — each is refused.
    @Test(arguments: [
        "head Sources/App/Depot.swift -n 20 || find . -iname Depot.swift",
        "tail Sources/App/Depot.swift -n 20 || echo X",
        "tail Sources/App/Depot.swift -n +5 || echo X",
        "sed -n 1,200p Sources/App/Depot.swift -n || echo X",
        "sed -n '1,\u{0665}p' Sources/App/Depot.swift || echo X",
    ])
    func aStageTheSystemToolsFailOnIsRefused(command: String) {
        #expect(InPlaceShape.match(forShell: command, in: "/repo") == nil)
    }

    /// A read of a file that cannot be read fails, so the fallback ran, and the read is withheld.
    @Test
    func aReadOfAFileThatCannotBeReadIsWithheld() async throws {
        let root = try await InPlaceAnswerTests.indexedRepository()
        let path = root.appendingPathComponent("Sources/App/Depot.swift").path
        chmod(path, 0o000)
        defer { chmod(path, 0o644) }

        let outcome = try #require(try await Self.outcome("cat Sources/App/Depot.swift || echo X", in: root))

        #expect(outcome == .withheld(.notExact))
    }

    /// A sweep over a directory holding one it cannot list is withheld, alone or behind a fallback: every grep reports the directory and exits 2 whatever it printed from the rest, so the output is not the lines the readable files hold, and the fallback ran.
    @Test(arguments: ["grep -rnw Gadget Sources/App/Parts", "grep -rnw Gadget Sources/App/Parts || echo X"])
    func aSweepOverADirectoryItCannotListIsWithheld(command: String) async throws {
        let root = try Self.gadgetRepository(parts: [
            "Sources/App/Parts/Plain.swift": "struct Plain {\n    let gadget = Gadget()\n}\n",
            "Sources/App/Parts/Sealed/Uses.swift": "struct Holder {\n    func make() -> Gadget { Gadget() }\n}\n",
        ])
        let sealed = root.appendingPathComponent("Sources/App/Parts/Sealed").path
        chmod(sealed, 0o311)
        defer { chmod(sealed, 0o755) }

        #expect(try await Self.anyOutcome(command, in: root) == .withheld(.unchecked))
    }

    /// A sweep over a file it cannot read is withheld, alone or behind a fallback, for the same reason.
    @Test(arguments: ["grep -rnw Gadget Sources/App/Parts", "grep -rnw Gadget Sources/App/Parts || echo X"])
    func aSweepOverAFileItCannotReadIsWithheld(command: String) async throws {
        let root = try Self.gadgetRepository(parts: [
            "Sources/App/Parts/Plain.swift": "struct Plain {\n    let gadget = Gadget()\n}\n",
            "Sources/App/Parts/Uses.swift": "struct Holder {\n    func make() -> Gadget { Gadget() }\n}\n",
        ])
        let locked = root.appendingPathComponent("Sources/App/Parts/Uses.swift").path
        chmod(locked, 0o000)
        defer { chmod(locked, 0o644) }

        #expect(try await Self.anyOutcome(command, in: root) == .withheld(.unchecked))
    }

    /// A sweep whose proof fails is read loosely behind a fallback where its search, run to its end, prints a line: grep then exits 0 and the fallback never runs, so the shell prints what the sweep alone prints — here a comment spelling the name, which no `where` answer accounts for, fails the proof.
    @Test
    func aSweepWhoseProofFailsIsReadLooselyBehindAFallbackWhereItPrints() async throws {
        let root = try Self.gadgetRepository(parts: [
            "Sources/App/Parts/Uses.swift": "// Gadget is spoken of here\nstruct Holder {\n    func make() -> Gadget { Gadget() }\n}\n",
        ])

        let alone = try await Self.anyOutcome("grep -rnw Gadget Sources/App/Parts", in: root)
        let behindAFallback = try await Self.anyOutcome("grep -rnw Gadget Sources/App/Parts || echo X", in: root)

        guard case let .answered(answeredAlone) = alone, case let .answered(answeredBehind) = behindAFallback else {
            Issue.record("both are read loosely: alone \(alone), behind a fallback \(behindAFallback)")
            return
        }

        #expect(answeredBehind.reason.hasPrefix("sift answered the lookup in this command with `where Gadget` instead of running it"))
        #expect(answeredBehind.calls.map(\.target) == answeredAlone.calls.map(\.target))
    }

    /// A sweep not proven to print is still not read loosely behind a fallback: one that prints nothing exits 1 and the fallback runs, and one stopped at a line no `where` answer can locate — a prose file — never reached the files after it, any of which could make grep exit 2.
    @Test
    func aSweepNotProvenToPrintIsNotReadLooselyBehindAFallback() async throws {
        let root = try Self.gadgetRepository(parts: [
            "Sources/App/Parts/Notes.md": "Gadget is spoken of here\n",
            "Sources/App/Parts/Uses.swift": "struct Holder {\n    func make() -> Gadget { Gadget() }\n}\n",
            "Sources/App/Quiet/Plain.swift": "struct Plain {}\n",
        ])

        let stoppedAlone = try await Self.anyOutcome("grep -rnw Gadget Sources/App/Parts", in: root)
        let answeredAlone = if case .answered = stoppedAlone {
            true
        } else {
            false
        }

        #expect(answeredAlone, "the loose reading answers the stopped sweep alone, so only the fallback withholds it: \(stoppedAlone)")
        #expect(try await Self.anyOutcome("grep -rnw Gadget Sources/App/Parts || echo X", in: root) == .withheld(.notExact))
        #expect(try await Self.anyOutcome("grep -rnw Gadget Sources/App/Quiet || echo X", in: root) == .withheld(.notExact))
    }

    /// A built package declaring `Gadget`, with `parts` beside it.
    private static func gadgetRepository(parts: [String: String]) throws -> URL {
        let root = try MCPTestRepo.make(declaring: "Alpha")
        try MCPTestRepo.add([
            "Package.swift": "// swift-tools-version: 5.9\nimport PackageDescription\nlet package = Package(name: \"App\", targets: [.target(name: \"App\")])\n",
            "Sources/App/Gadget.swift": "public struct Gadget {\n    public init() {}\n}\n",
        ].merging(parts) { $1 }, to: root)
        try MCPTestRepo.build(root)
        return root
    }

    /// The outcome of answering `command` in `root`, whether or not a fallback follows it.
    private static func anyOutcome(_ command: String, in root: URL, sourceLocation: SourceLocation = #_sourceLocation) async throws -> InPlaceAnswerer.Outcome {
        try await SiftEngine(directory: root).ensureFresh()
        let match = try #require(InPlaceShape.match(forShell: command, in: root.path), sourceLocation: sourceLocation)
        let backoff = try InPlaceAnswerTests.backoff()
        return await InPlaceAnswerTests.onItsOwnThread {
            InPlaceAnswerer.answer(match, timeBudget: InPlaceAnswerTests.roomy, backoff: backoff)
        }
    }
}
