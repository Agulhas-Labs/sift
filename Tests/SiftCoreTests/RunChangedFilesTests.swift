//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers the one signal that answers "is this mine?" — and the two ways it can have no answer, neither of which may be reported as zero.
@Suite(.temporaryDirectories)
struct RunChangedFilesTests {
    @Test
    func aModifiedFileIsReportedByItsName() throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write("enum A {}\n", to: "Sources/App/Catalogue.swift", in: root)
        try TestSources.commitAll(in: root, message: "add")
        try TestSources.write("enum A { static let b = 1 }\n", to: "Sources/App/Catalogue.swift", in: root)

        #expect(RunChangedFiles.inWorkingTree(at: root) == .basenames(["Catalogue.swift"]))
    }

    @Test
    func aRunningSubdirectoryAnswersForTheWholeRepository() throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write("enum A {}\n", to: "Sources/App/Catalogue.swift", in: root)
        try TestSources.commitAll(in: root, message: "add")
        try TestSources.write("enum A { static let b = 1 }\n", to: "Sources/App/Catalogue.swift", in: root)

        // Git resolves the enclosing repository, so the working directory a run happened in is enough.
        let fromSubdirectory = RunChangedFiles.inWorkingTree(at: root.appendingPathComponent("Sources/App"))

        #expect(fromSubdirectory == .basenames(["Catalogue.swift"]))
    }

    @Test
    func aFileGitHasNeverSeenIsAChange() throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write("enum New {}\n", to: "Sources/App/New.swift", in: root)

        // `git diff … HEAD` alone never names it, since there is nothing in the last commit to compare it with.
        #expect(RunChangedFiles.inWorkingTree(at: root) == .basenames(["New.swift"]))
    }

    /// The case the untracked half exists for: a new test file, failing before anyone has added it, is the session's own work.
    ///
    /// Counted from a real repository and through the same measurement the run's answer prints, so the pin is on the number a reader sees — one failure in the new file counted, one in a tracked file nothing has touched not.
    @Test
    func aFailureInANewTestFileIsInChangedFilesAndOneInAnUntouchedFileIsNot() throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write("struct BinLabelTests {}\n", to: "Tests/AppTests/BinLabelTests.swift", in: root)
        try TestSources.commitAll(in: root, message: "add")
        try TestSources.write("struct ZonePickTests {}\n", to: "Tests/AppTests/ZonePickTests.swift", in: root)

        let shape = RunFailureShape.of(
            [
                RunFailureShape.Failure(name: "zone()", location: "ZonePickTests.swift:3:9", message: "Expectation failed: zone"),
                RunFailureShape.Failure(name: "label()", location: "BinLabelTests.swift:7:9", message: "Expectation failed: label"),
            ],
            changedFiles: RunChangedFiles.inWorkingTree(at: root)
        )

        #expect(shape.inChangedFiles == .count(1))
    }

    @Test
    func aFileGitIsToldToIgnoreIsNotAChange() throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(".build/\n", to: ".gitignore", in: root)
        try TestSources.commitAll(in: root, message: "ignore")
        try TestSources.write("enum Generated {}\n", to: ".build/Generated.swift", in: root)

        #expect(RunChangedFiles.inWorkingTree(at: root) == .basenames([]))
    }

    @Test
    func aRunningSubdirectoryFindsNewFilesAcrossTheWholeRepository() throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write("enum A {}\n", to: "Sources/App/Catalogue.swift", in: root)
        try TestSources.commitAll(in: root, message: "add")
        try TestSources.write("struct ZonePickTests {}\n", to: "Tests/AppTests/ZonePickTests.swift", in: root)

        // `ls-files` answers for the directory it runs in unless told otherwise; the new file is in a sibling of it.
        let fromSubdirectory = RunChangedFiles.inWorkingTree(at: root.appendingPathComponent("Sources/App"))

        #expect(fromSubdirectory == .basenames(["ZonePickTests.swift"]))
    }

    @Test
    func aCleanTreeChangedNothingAndSaysSo() throws {
        let root = try TestSources.makeTempRepo()

        #expect(RunChangedFiles.inWorkingTree(at: root) == .basenames([]))
    }

    /// A staged rename is one change, under its new name: `status` prints the name it came from as a record of its own, and that record is not a path to count.
    @Test
    func aRenameIsReportedByItsNewNameOnly() throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write("enum A {}\n", to: "Sources/App/Catalogue.swift", in: root)
        try TestSources.commitAll(in: root, message: "add")
        try TestSources.runGit(["mv", "Sources/App/Catalogue.swift", "Sources/App/Ledger.swift"], in: root)

        #expect(RunChangedFiles.inWorkingTree(at: root) == .basenames(["Ledger.swift"]))
    }

    /// A new file staged, then deleted before it was ever committed: `HEAD` never had it and the working tree does not have it either, so there is nothing left to report — not the `AD` status names.
    @Test
    func aFileAddedThenDeletedBeforeCommittingIsNotAChange() throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write("enum A {}\n", to: "Sources/App/Catalogue.swift", in: root)
        try TestSources.commitAll(in: root, message: "add")
        try TestSources.write("struct New {}\n", to: "Sources/App/New.swift", in: root)
        try TestSources.runGit(["add", "Sources/App/New.swift"], in: root)
        try FileManager.default.removeItem(at: root.appendingPathComponent("Sources/App/New.swift"))

        #expect(RunChangedFiles.inWorkingTree(at: root) == .basenames([]))
    }

    /// A staged edit put back to `HEAD`'s own content in the working tree reads `MM` in `git status`, but the tree it names has not actually changed.
    @Test
    func aStagedEditRevertedInTheWorkingTreeIsNotAChange() throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write("enum A {}\n", to: "Sources/App/Catalogue.swift", in: root)
        try TestSources.commitAll(in: root, message: "add")
        try TestSources.write("enum A { static let b = 1 }\n", to: "Sources/App/Catalogue.swift", in: root)
        try TestSources.runGit(["add", "Sources/App/Catalogue.swift"], in: root)
        try TestSources.write("enum A {}\n", to: "Sources/App/Catalogue.swift", in: root)

        #expect(RunChangedFiles.inWorkingTree(at: root) == .basenames([]))
    }

    /// `MM` is not always a revert: a second, different edit on top of a staged one is still a real change, and must still be reported.
    @Test
    func aStagedEditFollowedByADifferentEditIsStillAChange() throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write("enum A {}\n", to: "Sources/App/Catalogue.swift", in: root)
        try TestSources.commitAll(in: root, message: "add")
        try TestSources.write("enum A { static let b = 1 }\n", to: "Sources/App/Catalogue.swift", in: root)
        try TestSources.runGit(["add", "Sources/App/Catalogue.swift"], in: root)
        try TestSources.write("enum A { static let c = 2 }\n", to: "Sources/App/Catalogue.swift", in: root)

        #expect(RunChangedFiles.inWorkingTree(at: root) == .basenames(["Catalogue.swift"]))
    }

    @Test
    func outsideARepositoryTheSignalIsUnavailableRatherThanEmpty() throws {
        let directory = try TestSources.makeTempDirectory()

        let changed = RunChangedFiles.inWorkingTree(at: directory)
        guard case let .unavailable(reason) = changed else {
            Issue.record("a directory outside every checkout must refuse, not answer nothing changed: \(changed)")
            return
        }
        // Git's own first sentence, without the `fatal:` it opens with.
        #expect(reason.contains("not a git repository"))
        #expect(!reason.contains("fatal:"))
    }

    /// A git that does not answer inside the budget leaves the signal unavailable, never at zero.
    ///
    /// By the time this runs the wrapped command has already exited, so a stalled git — an fsmonitor hook that hangs, a cold network filesystem, contention on `index.lock` — holds back an exit code the caller's verify loop is waiting on, to supply one field of one line. A budget already spent is the deterministic stand-in for that: the repository is real and its answer would be `.basenames`, and what comes back is the refusal instead.
    @Test
    func aGitThatDoesNotAnswerInTimeLeavesTheSignalUnavailable() throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write("enum A {}\n", to: "Sources/App/Catalogue.swift", in: root)
        try TestSources.commitAll(in: root, message: "add")
        try TestSources.write("enum A { static let b = 1 }\n", to: "Sources/App/Catalogue.swift", in: root)

        let changed = RunChangedFiles.inWorkingTree(at: root, within: -1)

        guard case let .unavailable(reason) = changed else {
            Issue.record("a git that never answered must refuse, not answer nothing changed: \(changed)")
            return
        }

        #expect(reason == "git did not answer in time")
        // The same repository, asked with the real budget, answers — so the refusal is the deadline and
        // not something about the fixture.
        #expect(RunChangedFiles.inWorkingTree(at: root) == .basenames(["Catalogue.swift"]))
    }

    @Test
    func twoFilesOfOneNameAreIndistinguishableAndThatIsTheWholeCaveat() {
        let changed = RunChangedFiles.of(["app/Tests/ChartGridTests.swift", "web/Tests/ChartGridTests.swift", "README.md"])

        #expect(changed == .basenames(["ChartGridTests.swift", "README.md"]))
    }

    /// One path git cannot spell in UTF-8 costs that path and nothing else — never the whole answer.
    ///
    /// Decoding the `-z` payload whole through `String(data:encoding:)` answers `nil` for the *entire* buffer if any byte in it is invalid. That falls through to an empty list and prints `0 in changed files (matched by name)` over a tree where files genuinely have changed — the one reading this type's own documentation says must never happen, since a zero is a claim and that one is wrong.
    ///
    /// **The repository is real and so is the byte.** APFS refuses to create a filename that is not valid UTF-8, so the path cannot come from the working tree — but git stores paths as raw bytes and will happily hold one written straight into its index, which is exactly the shape a checkout made on Linux, a submodule, or an archive unpacked in another encoding arrives in. `git diff` then reports it as deleted, because macOS cannot produce the file it names.
    @Test
    func onePathGitCannotSpellDoesNotTakeTheWholeListDownWithIt() throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write("enum A {}\n", to: "Sources/App/Catalogue.swift", in: root)
        try TestSources.commitAll(in: root, message: "add")
        // `\377` is written by `printf`, so nothing here needs a Swift string to hold an invalid byte.
        try Self.sh(
            "sha=$(printf 'x' | git hash-object -w --stdin) && "
                + #"printf '100644 %s\tSources/App/Bad\377Name.swift\n' "$sha" | git update-index --index-info"#,
            in: root
        )
        try TestSources.runGit(["commit", "-q", "-m", "a path this filesystem cannot spell"], in: root)
        try TestSources.write("enum A { static let b = 1 }\n", to: "Sources/App/Catalogue.swift", in: root)

        let changed = RunChangedFiles.inWorkingTree(at: root)
        guard case let .basenames(names) = changed else {
            Issue.record("one undecodable path must not make the whole signal unavailable: \(changed)")
            return
        }

        // The file that really changed is still in the answer, which it would not be if one bad byte nil'd the buffer.
        #expect(names.contains("Catalogue.swift"))
        // And the path nothing can spell is a name nothing will match, which is the truth about it: the
        // frameworks on the other side of this comparison print UTF-8 by construction.
        #expect(names.count == 2)
        #expect(!names.contains(""))
    }

    /// An `MM` path above the compare's size cap stays listed even though it matches `HEAD` — the byte compare that would settle it never runs, so the direction that was already safe for everything else this signal reports wins here too.
    @Test
    func anMMPathAboveTheSizeCapStaysListedEvenThoughItMatchesHead() throws {
        let root = try TestSources.makeTempRepo()
        let big = String(repeating: "a", count: RunChangedFiles.revertCompareSizeCap + 1)
        try TestSources.write(big, to: "Sources/App/Big.swift", in: root)
        try TestSources.commitAll(in: root, message: "add")
        try TestSources.write(big + "b", to: "Sources/App/Big.swift", in: root)
        try TestSources.runGit(["add", "Sources/App/Big.swift"], in: root)
        try TestSources.write(big, to: "Sources/App/Big.swift", in: root)

        #expect(RunChangedFiles.inWorkingTree(at: root) == .basenames(["Big.swift"]))
    }

    /// The size cap is a budget across every `MM` path, not a limit per path, so many files each under it cannot add up to a read past the deadline.
    @Test
    func mmPathsThatTogetherPassTheSizeCapLeaveTheRestListed() throws {
        let root = try TestSources.makeTempRepo()
        let half = String(repeating: "a", count: RunChangedFiles.revertCompareSizeCap / 2 + 1)
        for name in ["First", "Second"] {
            try TestSources.write(half, to: "Sources/App/\(name).swift", in: root)
        }
        try TestSources.commitAll(in: root, message: "add")
        for name in ["First", "Second"] {
            try TestSources.write(half + "b", to: "Sources/App/\(name).swift", in: root)
            try TestSources.runGit(["add", "Sources/App/\(name).swift"], in: root)
            try TestSources.write(half, to: "Sources/App/\(name).swift", in: root)
        }

        #expect(RunChangedFiles.inWorkingTree(at: root) == .basenames(["Second.swift"]))
    }

    /// An expired deadline keeps an `MM` path listed even though it would otherwise revert to `HEAD`'s content — the compare that would decide it never gets to run.
    @Test
    func anExpiredDeadlineKeepsAnMMPathListed() throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write("enum A {}\n", to: "Sources/App/Catalogue.swift", in: root)
        try TestSources.commitAll(in: root, message: "add")
        try TestSources.write("enum A { static let b = 1 }\n", to: "Sources/App/Catalogue.swift", in: root)
        try TestSources.runGit(["add", "Sources/App/Catalogue.swift"], in: root)
        try TestSources.write("enum A {}\n", to: "Sources/App/Catalogue.swift", in: root)

        let reverted = RunChangedFiles.revertedAgainstHead(["Sources/App/Catalogue.swift"], in: root, until: .now() - .seconds(1))

        #expect(reverted.isEmpty)
    }

    /// Runs one ASCII shell command in `directory`, for the one fixture that has to write bytes Swift strings cannot carry.
    private static func sh(_ command: String, in directory: URL, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.currentDirectoryURL = directory
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, sourceLocation: sourceLocation)
    }
}
