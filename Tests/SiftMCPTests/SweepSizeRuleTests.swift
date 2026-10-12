//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore
@testable import SiftMCP
import Testing

/// A sweep answered in place, word-anchored or a names search, is served only where its whole refusal is smaller than what the command's own grep prints after its cut; otherwise the grep runs, withheld as not smaller.
///
/// Most searched directories hold one file, so a cut keeps lines in the one order grep prints them; the one holding two is weighed against the fewest bytes any order of them prints.
@Suite(.temporaryDirectories)
struct SweepSizeRuleTests {
    /// A package whose `Gadget` is declared and used on many lines of the one file under a deep `Parts` directory, whose `Widget` is too under `Bits`, where a comment opens the file, and whose `Sprocket` is used on many lines of each of two files under a deep `Linkages` directory.
    private static func builtPackage() async throws -> URL {
        let root = try MCPTestRepo.make(declaring: "Alpha")
        let gadgetUses = (1 ... 28).map { "func gadget\($0)() -> Gadget { Gadget() }" }.joined(separator: "\n")
        let widgetUses = (1 ... 60).map { "func widget\($0)() -> Widget { Widget() }" }.joined(separator: "\n")
        let sprocketUses = { (first: Int) in (first ..< first + 28).map { "func sprocket\($0)() -> Sprocket { Sprocket() }" }.joined(separator: "\n") }
        let cogUses = { (first: Int) in (first ..< first + 28).map { "func turn\($0)() -> Cog { Cog() }" }.joined(separator: "\n") }
        try MCPTestRepo.add([
            "Package.swift": "// swift-tools-version: 5.9\nimport PackageDescription\nlet package = Package(name: \"App\", targets: [.target(name: \"App\")])\n",
            "Sources/App/Parts/Assemblies/Mechanisms/Gadget.swift": "public struct Gadget {\n    public init() {}\n}\n\(gadgetUses)\n",
            "Sources/App/Bits/Widget.swift": "// Widget in a comment\nstruct Widget {}\n\(widgetUses)\n",
            "Sources/App/Parts/Assemblies/Linkages/Sprocket.swift": "public struct Sprocket {\n    public init() {}\n}\n\(sprocketUses(1))\n",
            "Sources/App/Parts/Assemblies/Linkages/Spares.swift": "\(sprocketUses(29))\n",
            // Two files of uses, the second closing on a comment naming the type, which no reference locates.
            "Sources/App/Parts/Assemblies/Couplings/Cog.swift": "public struct Cog {\n    public init() {}\n}\n\(cogUses(1))\n",
            "Sources/App/Parts/Assemblies/Couplings/Teeth.swift": "\(cogUses(29))\n// Cog turns the teeth\n",
            // One short line under each directory, beside an ignored file holding one long line.
            "Sources/App/Kit/Sub/Rivet.swift": "struct Rivet {}\n",
            "Sources/App/Kit/Sub/.gitignore": "notes.txt\n",
            "Sources/App/Kit/Sub/notes.txt": "Rivet \(String(repeating: "x", count: 3000))\n",
            "Sources/App/Kit/Spare/Rivets.swift": "let rivet = Rivet()\n",
            "Sources/App/Kit/Spare/.gitignore": "notes.txt\n",
            "Sources/App/Kit/Spare/notes.txt": "Rivet \(String(repeating: "x", count: InPlaceAnswer.sizeBudget + 2000))\n",
        ], to: root)
        try MCPTestRepo.build(root)
        try await SiftEngine(directory: root).ensureFresh()
        return root
    }

    @Test
    func anAnchoredSweepIsAnsweredOnlyWhereItsRefusalIsSmallerThanTheGrep() async throws {
        let root = try await Self.builtPackage()

        // Twenty-eight long lines printed, each under its file's name: the answer is the smaller.
        let answered = try #require(try await InPlaceAnswerTests.answered("grep -rnw Gadget Sources/App/Parts/Assemblies/Mechanisms", in: root))

        #expect(answered.reason.hasPrefix("sift answered this with `where Gadget (refs: true)` instead of running it"))
        // One line printed: the refusal costs more than letting it print.
        #expect(try await InPlaceAnswerTests.outcome("grep -rnw Gadget Sources/App/Parts/Assemblies/Mechanisms | head -1", in: root) == .withheld(.notSmaller))
    }

    @Test
    func aNamesSearchWithNoProofIsWeighedAgainstItsOwnSearch() async throws {
        let root = try await Self.builtPackage()

        let answered = try #require(try await InPlaceAnswerTests.answered("grep -rn Gadget Sources/App/Parts/Assemblies/Mechanisms", in: root))

        #expect(answered.reason.hasPrefix("sift answered this with `where Gadget` instead of running it"))
        #expect(try await InPlaceAnswerTests.outcome("grep -rn Gadget Sources/App/Parts/Assemblies/Mechanisms | head -1", in: root) == .withheld(.notSmaller))
    }

    /// The cut is what is weighed: one that keeps every line weighs them all, and one that keeps a few weighs only those.
    @Test
    func theCutIsHonoured() async throws {
        let root = try await Self.builtPackage()

        #expect(try await InPlaceAnswerTests.answered("grep -rnw Gadget Sources/App/Parts/Assemblies/Mechanisms | head -500", in: root) != nil)
        #expect(try await InPlaceAnswerTests.answered("grep -rnw Gadget Sources/App/Parts/Assemblies/Mechanisms | sed -n 1,500p", in: root) != nil)
        #expect(try await InPlaceAnswerTests.outcome("grep -rnw Gadget Sources/App/Parts/Assemblies/Mechanisms | tail -2", in: root) == .withheld(.notSmaller))
        #expect(try await InPlaceAnswerTests.outcome("grep -rnw Gadget Sources/App/Parts/Assemblies/Mechanisms | sed -n 2,3p", in: root) == .withheld(.notSmaller))
    }

    /// An anchored sweep whose proof fails falls back to the names answer, which is weighed against the anchored grep, cut included.
    @Test
    func theNamesFallbackIsWeighedAgainstTheAnchoredGrep() async throws {
        let root = try await Self.builtPackage()

        let answered = try #require(try await InPlaceAnswerTests.answered("grep -rnw Widget Sources/App/Bits", in: root))

        #expect(answered.reason.hasPrefix("sift answered this with `where Widget` instead of running it"))
        #expect(try await InPlaceAnswerTests.outcome("grep -rnw Widget Sources/App/Bits | head -1", in: root) == .withheld(.notSmaller))
    }

    /// On a line of several lookups a sweep is weighed on its own, and one that is not smaller lets the whole line run.
    @Test
    func aSweepOnALineOfSeveralIsWeighedOnItsOwn() async throws {
        let root = try await Self.builtPackage()
        let small = try #require(InPlaceShape.match(forShell: "grep -rnw Gadget Sources/App/Parts/Assemblies/Mechanisms | head -1; echo done", in: root.path))
        let large = try #require(InPlaceShape.match(forShell: "grep -rnw Gadget Sources/App/Parts/Assemblies/Mechanisms; echo done", in: root.path))
        let backoff = try InPlaceAnswerTests.backoff()
        let answer = { (match: InPlaceShape.Match) in
            await InPlaceAnswerTests.onItsOwnThread { InPlaceAnswerer.answer(match, timeBudget: InPlaceAnswerTests.roomy, backoff: backoff) }
        }

        #expect(await answer(small) == .withheld(.notSmaller))
        guard case .answered = await answer(large) else {
            Issue.record("expected the uncut line answered")
            return
        }
    }

    /// A cut across two files whose order grep leaves unfixed keeps one line whichever prints first, and no answer is smaller than the shortest line it could be.
    @Test
    func aCutAcrossFilesIsNotSmallerWhereItsAnswerOutweighsAnyOrder() async throws {
        let root = try await Self.builtPackage()

        #expect(try await InPlaceAnswerTests.outcome("grep -rn Sprocket Sources/App/Parts/Assemblies/Linkages | head -1", in: root) == .withheld(.notSmaller))
        #expect(try await InPlaceAnswerTests.outcome("grep -rnw Sprocket Sources/App/Parts/Assemblies/Linkages | head -2", in: root) == .withheld(.notSmaller))
        #expect(try await InPlaceAnswerTests.outcome("grep -rn Sprocket Sources/App/Parts/Assemblies/Linkages | tail -1", in: root) == .withheld(.notSmaller))
    }

    /// A names search whose walk passes the file or byte limit prints what nobody measured, so it is answered unweighed, as it was before it was weighed, rather than withheld.
    @Test
    func aNamesSearchPastTheWalkLimitIsAnsweredUnweighed() async throws {
        let root = try await Self.builtPackage()
        let notes = root.appendingPathComponent("Sources/App/Notes")
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        for index in 0 ... ShellGrep.fileLimit {
            try Data("note \(index)\n".utf8).write(to: notes.appendingPathComponent("note\(index).txt"))
        }
        let ledger = root.appendingPathComponent("Ledger")
        try FileManager.default.createDirectory(at: ledger, withIntermediateDirectories: true)
        try Data(repeating: 0x0A, count: ShellGrep.byteLimit + 1).write(to: ledger.appendingPathComponent("blank.txt"))

        // Each asked whatever the other answers, so a failure of one says nothing of the other.
        let pastFiles = try await InPlaceAnswerTests.answered("grep -rn Gadget Sources", in: root)
        let pastBytes = try await InPlaceAnswerTests.answered("grep -rn Gadget Sources/App/Parts Ledger", in: root)

        #expect(pastFiles?.reason.hasPrefix("sift answered this with `where Gadget` instead of running it") == true)
        #expect(pastBytes?.reason.hasPrefix("sift answered this with `where Gadget` instead of running it") == true)
        // The word-anchored sweep ran its search before it was weighed, and past the limit it still runs.
        #expect(try await InPlaceAnswerTests.outcome("grep -rnw Gadget Sources", in: root) == .withheld(.unchecked))
    }

    /// A cut across two files that keeps more lines than the answer outweighs, in whatever order the files print, is answered.
    @Test
    func aCutAcrossFilesIsAnsweredWhereItsAnswerIsSmallerThanAnyOrder() async throws {
        let root = try await Self.builtPackage()

        let answered = try #require(try await InPlaceAnswerTests.answered("grep -rn Sprocket Sources/App/Parts/Assemblies/Linkages | head -40", in: root))

        #expect(answered.reason.hasPrefix("sift answered this with `where Sprocket` instead of running it"))
    }

    /// A cut across files smaller than its floor is answered only where the references locate every line any order prints, the comment one order's cut would leave out included.
    @Test
    func aCutAcrossFilesLocatesEveryLineAnyOrderPrints() async throws {
        let root = try await Self.builtPackage()
        // Case-folded, a sweep never falls back to the names answer, so the failed proof is what comes back.
        let outcome = try await InPlaceAnswerTests.outcome("grep -rnwi Cog Sources/App/Parts/Assemblies/Couplings | head -40", in: root)

        #expect(outcome == .withheld(.notExact))
    }

    /// A line of a file the ignore rules skip prints under the system grep and not under the grep Claude Code's shell runs, so it is not counted: the one short line left outweighs no refusal.
    @Test
    func anIgnoredFileIsNotCounted() async throws {
        let root = try await Self.builtPackage()
        // The ignore rules are read by a git of this test's own repository.
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(".git/HEAD").path))

        // Its long line outweighs the refusal, and is left out of the bytes weighed.
        #expect(try await InPlaceAnswerTests.outcome("grep -rn Rivet Sources/App/Kit/Sub", in: root) == .withheld(.notSmaller))
        // Its line passes the size budget, past which the search stops unless the line is left out there too.
        #expect(try await InPlaceAnswerTests.outcome("grep -rn Rivet Sources/App/Kit/Spare", in: root) == .withheld(.notSmaller))
    }

    /// Below an operand of `.`, spelled so or left out, the leading `./` the system grep prints is not counted, since the grep Claude Code's shell runs drops it; any other operand is counted as written.
    @Test
    func theLeadingDotSlashIsNotCountedUnderTheWorkingDirectory() throws {
        let directory = try TemporaryDirectory.make("sweep-dot")
        let sub = directory.appendingPathComponent("Sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try Data("struct Widget {}\nlet widget = Widget()\n".utf8).write(to: sub.appendingPathComponent("B.swift"))
        let bytes = { (arguments: [String]) in ShellGrep(arguments: arguments)?.measured(in: directory.path).bytes }
        let printed = "Sub/B.swift:1:struct Widget {}\nSub/B.swift:2:let widget = Widget()\n".utf8.count

        #expect(bytes(["-rn", "Widget", "."]) == printed)
        #expect(bytes(["-rn", "Widget", "./"]) == printed)
        #expect(bytes(["-rn", "Widget"]) == printed)
        #expect(bytes(["-rn", "Widget", "./Sub"]) == printed + 4)
    }

    /// The bytes measured for a search are the bytes the system grep prints for it, name, number, text and newline each counted to the byte.
    @Test
    func theMeasuredBytesAreWhatTheSystemGrepPrints() throws {
        let directory = try TemporaryDirectory.make("sweep-bytes")
        let nested = directory.appendingPathComponent("Kit/Sub")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let uses = (1 ... 12).map { "func part\($0)() -> Widget { Widget() }\nlet spare\($0) = 0" }.joined(separator: "\n")
        try Data("struct Widget {}\n\(uses)\n".utf8).write(to: directory.appendingPathComponent("Kit/A.swift"))
        try Data("// none here\n\(uses)\n".utf8).write(to: nested.appendingPathComponent("B.swift"))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/grep")
        process.arguments = ["-rn", "Widget", "Kit"]
        process.currentDirectoryURL = directory
        process.environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let printed = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let measured = try #require(ShellGrep(arguments: ["-rn", "Widget", "Kit"])).measured(in: directory.path)

        #expect(printed.count > 1000)
        guard case let .printed(lines) = measured.outcome else {
            Issue.record("expected the search worked out, got \(measured.outcome)")
            return
        }
        #expect(lines.count == 25)
        #expect(measured.bytes == printed.count)
    }
}
