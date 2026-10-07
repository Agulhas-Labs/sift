//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers the set-aside `run --without` stands on: every uncommitted change under a pathspec leaves the tree, and every byte of it — and the split between what was staged and what was not — comes back.
///
/// Each test runs against a real repository, because the property is a claim about what git and the filesystem say afterwards, and nothing short of asking them can check it.
@Suite(.temporaryDirectories)
struct SetAsideTests {
    /// One of every kind of uncommitted change goes, the pathspec reads as HEAD has it in the index and the files, and all of it comes back exactly.
    @Test
    func everyKindOfChangeLeavesTheTreeAndComesBackWithTheSplitIntact() throws {
        let root = try Self.repositoryWithEveryKindOfChange()
        let statusBefore = try Self.status(of: root)
        let filesBefore = try Self.files(of: root)
        let store = SetAsideStore(repositoryRoot: root)

        let record = try SetAside.capture(pathspecs: ["Sources/"], from: root, into: store)
        try Self.setAsideWhole(record, in: store)

        // Set aside: nothing staged under the pathspec, every file HEAD has is HEAD's bytes, and every path
        // HEAD lacks — the rename's new name, the untracked file and its directory, the intent-to-add — is gone.
        #expect(try TestSources.runGit(["diff", "--cached", "--name-only", "--", "Sources/"], in: root).isEmpty)
        for path in ["staged.txt", "both.txt", "unstaged.txt", "gone-staged.txt", "gone.txt", "moved.txt", "mode.sh"] {
            let head = try TestSources.runGit(["show", "HEAD:Sources/\(path)"], in: root)
            #expect(try String(contentsOf: root.appendingPathComponent("Sources/\(path)"), encoding: .utf8) == head, "Sources/\(path)")
        }
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: root.appendingPathComponent("Sources/link").path) == "staged.txt")
        let modeAside = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("Sources/mode.sh").path)
        #expect(((modeAside[.posixPermissions] as? Int) ?? 0) & 0o111 == 0)
        for path in ["Sources/renamed.txt", "Sources/new", "Sources/intended.txt"] {
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path), "\(path)")
        }
        // …and the change outside it never moved.
        #expect(try String(contentsOf: root.appendingPathComponent("outside.txt"), encoding: .utf8) == "eight, edited\n")

        let restored = try SetAside(store: store).restore(record)

        #expect(try Self.status(of: root) == statusBefore)
        #expect(try Self.files(of: root) == filesBefore)
        #expect(restored.kept.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: store.directory.path), "the record and its copies go once the check passes")
    }

    /// A pathspec means what it means where it was typed: `.` from inside `Sources/` sets aside that directory and nothing above it, and the record still names every path from the root.
    @Test
    func aPathspecIsReadFromTheDirectoryItWasWrittenIn() throws {
        let root = try Self.repositoryWithEveryKindOfChange()
        let statusBefore = try Self.status(of: root)
        let filesBefore = try Self.files(of: root)
        let store = SetAsideStore(repositoryRoot: root)

        let record = try SetAside.capture(pathspecs: ["."], from: root.appendingPathComponent("Sources"), into: store)

        #expect(record.directory == "Sources/")
        #expect(record.entries.allSatisfy { $0.path.hasPrefix("Sources/") })
        #expect(record.entries.contains { $0.path == "Sources/new/with space.txt" })
        try Self.setAsideWhole(record, in: store)
        #expect(try String(contentsOf: root.appendingPathComponent("outside.txt"), encoding: .utf8) == "eight, edited\n")
        _ = try SetAside(store: store).restore(record)
        #expect(try Self.status(of: root) == statusBefore)
        #expect(try Self.files(of: root) == filesBefore)
    }

    /// A run killed part-way through setting aside leaves a tree in no state anybody planned for — paths set aside, one moved out and not yet replaced, others not reached — and a restore from the record still puts all of it back.
    @Test
    func aHalfFinishedSetAsideStillRestoresEverything() throws {
        let root = try Self.repositoryWithEveryKindOfChange()
        let statusBefore = try Self.status(of: root)
        let filesBefore = try Self.files(of: root)
        let store = SetAsideStore(repositoryRoot: root)
        let record = try SetAside.capture(pathspecs: ["Sources/"], from: root, into: store)
        try Self.setAsideWhole(record, in: store)

        // What a set-aside stopped part-way leaves: a path it had not reached yet still holds its own bytes,
        // with nothing of it in the store, and one it had moved out has nothing in its place yet.
        let unreached = try #require(record.entries.firstIndex { $0.path == "Sources/unstaged.txt" })
        try FileManager.default.removeItem(at: store.moved.appendingPathComponent("\(unreached)"))
        try FileManager.default.removeItem(at: root.appendingPathComponent("Sources/unstaged.txt"))
        try "three, edited\n".write(to: root.appendingPathComponent("Sources/unstaged.txt"), atomically: false, encoding: .utf8)
        try FileManager.default.removeItem(at: root.appendingPathComponent("Sources/staged.txt"))

        _ = try SetAside(store: store).restore(record)

        #expect(try Self.status(of: root) == statusBefore)
        #expect(try Self.files(of: root) == filesBefore)
    }

    /// A restore whose bytes do not hash to what the record says stops, says which path, and deletes nothing — so a later restore can still finish the job.
    @Test
    func aRestoreThatDoesNotMatchStopsLoudlyAndKeepsTheRecordAndEveryCopy() throws {
        let root = try Self.repositoryWithEveryKindOfChange()
        let filesBefore = try Self.files(of: root)
        let store = SetAsideStore(repositoryRoot: root)
        let record = try SetAside.capture(pathspecs: ["Sources/"], from: root, into: store)
        try Self.setAsideWhole(record, in: store)
        let copy = try #require(Self.copy(of: "Sources/new/untracked.txt", in: record, store: store))
        // The copy no longer holds the bytes the record hashed — which is all a mismatch is, from the check's
        // side, however it came about.
        try "not what was recorded\n".write(to: copy, atomically: true, encoding: .utf8)

        do {
            _ = try SetAside(store: store).restore(record)
            Issue.record("a restore whose content hash did not match reported success")
        } catch let SetAsideError.notRestored(failure) {
            #expect(failure.reasons.contains { $0.hasPrefix("Sources/new/untracked.txt:") })
            #expect(SetAsideError.notRestored(failure).description.contains("sift run --restore"))
        }
        #expect(FileManager.default.fileExists(atPath: store.recordURL.path))
        #expect(FileManager.default.fileExists(atPath: copy.path))
        #expect(SetAsideSession.refusal(for: root) != nil, "every run refuses while the record stands")

        // The record still says what the bytes are, and once the copy holds them again a restore finishes the job.
        try "nine\n".write(to: copy, atomically: true, encoding: .utf8)
        chmod(copy.path, 0o600)
        _ = try SetAsideSession.restoreAbandoned(in: root)
        #expect(try Self.files(of: root) == filesBefore)
        #expect(SetAsideSession.refusal(for: root) == nil)
    }

    /// A restore retried after a failed check finds what its own first attempt wrote, and reads it as that — not as somebody's edit to be moved aside.
    @Test
    func aRestoreRetriedAfterAFailedCheckKeepsNothingOfItsOwn() throws {
        let root = try Self.repositoryWithEveryKindOfChange()
        let filesBefore = try Self.files(of: root)
        let store = SetAsideStore(repositoryRoot: root)
        let record = try SetAside.capture(pathspecs: ["Sources/"], from: root, into: store)
        try Self.setAsideWhole(record, in: store)
        let copy = try #require(Self.copy(of: "Sources/new/untracked.txt", in: record, store: store))
        try "damaged\n".write(to: copy, atomically: true, encoding: .utf8)
        #expect(throws: SetAsideError.self) { try SetAside(store: store).restore(record) }
        try "nine\n".write(to: copy, atomically: true, encoding: .utf8)

        let restored = try SetAside(store: store).restore(record)

        #expect(restored.kept.isEmpty, "the first attempt's own write was reported as a change made during the run")
        #expect(try Self.files(of: root) == filesBefore)
    }

    /// Something written into a recorded path while it was set aside is moved beside the path, never overwritten, and the original goes back.
    @Test
    func aChangeWrittenWhileTheTestsRanIsKeptBesideItsPath() throws {
        let root = try Self.repositoryWithEveryKindOfChange()
        let store = SetAsideStore(repositoryRoot: root)
        let record = try SetAside.capture(pathspecs: ["Sources/"], from: root, into: store)
        try Self.setAsideWhole(record, in: store)
        try "written during the run\n".write(to: root.appendingPathComponent("Sources/unstaged.txt"), atomically: true, encoding: .utf8)

        let restored = try SetAside(store: store).restore(record)

        let kept = "Sources/unstaged.txt.sift-kept-\(record.id.prefix(8))"

        #expect(restored.kept == [kept])
        #expect(try String(contentsOf: root.appendingPathComponent(kept), encoding: .utf8) == "written during the run\n")
        #expect(try String(contentsOf: root.appendingPathComponent("Sources/unstaged.txt"), encoding: .utf8) == "three, edited\n")
    }

    /// A staged object the object database lost while the index no longer named it is rebuilt from the copy taken before the tree was touched.
    @Test
    func aStagedObjectPrunedDuringTheRunIsRebuiltFromItsCopy() throws {
        let root = try Self.repositoryWithEveryKindOfChange()
        let statusBefore = try Self.status(of: root)
        let object = try TestSources.runGit(["rev-parse", ":Sources/staged.txt"], in: root)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let store = SetAsideStore(repositoryRoot: root)
        let record = try SetAside.capture(pathspecs: ["Sources/"], from: root, into: store)
        try Self.setAsideWhole(record, in: store)
        let loose = root.appendingPathComponent(".git/objects/\(object.prefix(2))/\(object.dropFirst(2))")
        try FileManager.default.removeItem(at: loose)
        #expect(throws: (any Error).self) { try TestSources.runGit(["cat-file", "-e", object], in: root) }

        _ = try SetAside(store: store).restore(record)

        #expect(try Self.status(of: root) == statusBefore)
        #expect(try TestSources.runGit(["show", ":Sources/staged.txt"], in: root) == "one, staged\n")
    }

    /// Nothing uncommitted under the pathspec is refused, and a pathspec that names nothing at all is told apart from one that names clean files.
    @Test
    func aPathspecWithNothingToSetAsideIsRefusedAndSaysWhich() throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write("one\n", to: "Sources/clean.txt", in: root)
        try TestSources.commitAll(in: root, message: "clean")
        let store = SetAsideStore(repositoryRoot: root)

        for (pathspec, matches) in [("Sources/", true), ("Nowhere/", false)] {
            do {
                _ = try SetAsideSession.begin(pathspecs: [pathspec], from: root)
                Issue.record("\(pathspec) had nothing to set aside and was not refused")
            } catch let SetAsideError.nothingUncommitted(pathspecs, matchesFiles, _, _) {
                #expect(pathspecs == [pathspec])
                #expect(matchesFiles == matches)
            }
        }

        #expect(!FileManager.default.fileExists(atPath: store.directory.path))
    }

    /// A record whose process is gone is the only copy of somebody's work, so every entry point that could build over it or delete it refuses, and only a restore clears it.
    @Test
    func aRecordLeftBehindIsRefusedByEveryEntryPointThatCouldLoseIt() throws {
        let root = try Self.repositoryWithEveryKindOfChange()
        let filesBefore = try Self.files(of: root)
        let store = SetAsideStore(repositoryRoot: root)
        // Written and set aside with no lock held: what a run leaves when it and its watcher were both killed.
        let record = try SetAside.capture(pathspecs: ["Sources/"], from: root, into: store)
        try Self.setAsideWhole(record, in: store)

        guard case let .unrestored(found)? = SetAsideSession.refusal(for: root) else {
            Issue.record("a record left behind did not make runs refuse")
            return
        }
        #expect(found.id == record.id)
        #expect(SetAsideError.unrestored(found).description.contains("sift run --restore"))
        do {
            _ = try SetAsideSession.begin(pathspecs: ["Sources/"], from: root)
            Issue.record("a second set-aside started over an unrestored record")
        } catch SetAsideError.unrestored {}
        do {
            _ = try SiftEngine.reset(directory: root)
            Issue.record("reset deleted .sift/ with an unrestored record in it")
        } catch SetAsideError.unrestored {}
        #expect(FileManager.default.fileExists(atPath: store.recordURL.path))

        let restored = try SetAsideSession.restoreAbandoned(in: root)

        #expect(restored?.record.id == record.id)
        #expect(try Self.files(of: root) == filesBefore)
        #expect(SetAsideSession.refusal(for: root) == nil)
        #expect(try SetAsideSession.restoreAbandoned(in: root) == nil, "a second restore finds nothing to do")
    }

    /// While one set-aside holds the tree, a second is refused, and so is a restore that would pull the tree out from under it.
    @Test
    func aSetAsideInProgressRefusesASecondAndARestore() throws {
        let root = try Self.repositoryWithEveryKindOfChange()
        let first = try SetAsideSession.begin(pathspecs: ["Sources/"], from: root)

        do {
            _ = try SetAsideSession.begin(pathspecs: ["Sources/"], from: root)
            Issue.record("two set-asides of one tree ran at once")
        } catch SetAsideError.busy {}
        do {
            _ = try SetAsideSession.restoreAbandoned(in: root)
            Issue.record("a restore ran under a live set-aside")
        } catch SetAsideError.busy {}
        guard case .busy? = SetAsideSession.refusal(for: root) else {
            Issue.record("a run did not refuse while a set-aside was in progress")
            return
        }

        try first.finish()

        #expect(SetAsideSession.refusal(for: root) == nil)
    }

    /// A file written after it was recorded and before it was set aside stops the set-aside: the write stays exactly as its writer left it, whatever had been set aside goes back, and the record goes.
    @Test(arguments: ["Sources/unstaged.txt", "Sources/new/untracked.txt", "Sources/both.txt"])
    func aFileWrittenAfterItWasRecordedStopsTheSetAsideAndKeepsTheWrite(_ path: String) throws {
        let root = try Self.repositoryWithEveryKindOfChange()
        let store = SetAsideStore(repositoryRoot: root)
        let record = try SetAside.capture(pathspecs: ["Sources/"], from: root, into: store)
        try "written after the record\n".write(to: root.appendingPathComponent(path), atomically: true, encoding: .utf8)
        let statusWithTheWrite = try Self.status(of: root)
        let filesWithTheWrite = try Self.files(of: root)

        let outcome = try SetAside(store: store).setAside(record)

        guard case let .stopped(changed, restored) = outcome else {
            Issue.record("a path written after it was recorded was set aside over the write")
            return
        }

        #expect(changed == [path])
        #expect(restored.kept.isEmpty)
        #expect(try Self.files(of: root) == filesWithTheWrite)
        #expect(try Self.status(of: root) == statusWithTheWrite)
        #expect(!FileManager.default.fileExists(atPath: store.directory.path))
    }

    /// A path staged after it was recorded stops the set-aside before anything in the index or the tree moves.
    @Test
    func aPathStagedAfterItWasRecordedStopsTheSetAsideBeforeAnythingMoves() throws {
        let root = try Self.repositoryWithEveryKindOfChange()
        let store = SetAsideStore(repositoryRoot: root)
        let record = try SetAside.capture(pathspecs: ["Sources/"], from: root, into: store)
        try TestSources.runGit(["add", "Sources/unstaged.txt"], in: root)
        let statusWithTheAdd = try Self.status(of: root)
        let files = try Self.files(of: root)

        let outcome = try SetAside(store: store).setAside(record)

        guard case let .stopped(changed, _) = outcome else {
            Issue.record("a path staged after it was recorded was set aside over the new stage")
            return
        }

        #expect(changed == ["Sources/unstaged.txt"])
        #expect(try Self.status(of: root) == statusWithTheAdd)
        #expect(try Self.files(of: root) == files)
        #expect(!FileManager.default.fileExists(atPath: store.directory.path))
    }

    /// HEAD moving while the changes are out — a branch switched, a pull — does not wedge the record: the restore is checked by content, the bytes and index entries come back, what the switch wrote is kept beside its path, and the new HEAD is reported.
    @Test
    func aHeadThatMovedWhileTheChangesWereOutStillGetsThemBackAndSaysSo() throws {
        let root = try Self.repositoryWithEveryKindOfChange(otherBranch: true)
        let filesBefore = try Self.files(of: root)
        let indexBefore = try Self.index(of: root)
        let store = SetAsideStore(repositoryRoot: root)
        let record = try SetAside.capture(pathspecs: ["Sources/"], from: root, into: store)
        try Self.setAsideWhole(record, in: store)
        try TestSources.runGit(["checkout", "-q", "other"], in: root)
        let other = try TestSources.runGit(["rev-parse", "HEAD"], in: root).trimmingCharacters(in: .whitespacesAndNewlines)

        let restored = try SetAside(store: store).restore(record)

        let kept = "Sources/unstaged.txt.sift-kept-\(record.id.prefix(8))"
        #expect(restored.headNow == other)
        #expect(restored.kept == [kept])
        #expect(try Self.index(of: root) == indexBefore)
        var expected = filesBefore
        expected[kept] = "mode 644: three, on the other branch\n"
        #expect(try Self.files(of: root) == expected)
        #expect(SetAsideSession.refusal(for: root) == nil, "a moved HEAD left the record standing")
    }

    /// A restore that cannot take the index lock stops with the work out of the tree, and says so in plain words: not back, nothing deleted, where the copies are, and the command that puts them back — with no absolute path in it.
    @Test
    func aRestoreThatCannotTakeTheIndexLockSaysTheWorkIsNotBackAndHowToGetItBack() throws {
        let root = try Self.repositoryWithEveryKindOfChange()
        let filesBefore = try Self.files(of: root)
        let store = SetAsideStore(repositoryRoot: root)
        let record = try SetAside.capture(pathspecs: ["Sources/"], from: root, into: store)
        try Self.setAsideWhole(record, in: store)
        let lock = root.appendingPathComponent(".git/index.lock")
        FileManager.default.createFile(atPath: lock.path, contents: Data())

        do {
            _ = try SetAside(store: store).restore(record)
            Issue.record("a restore that could not write the index reported success")
        } catch let error as SetAsideError {
            let text = error.description
            guard case let .notRestored(failure) = error else {
                Issue.record("a restore that could not write the index said: \(text)")
                return
            }
            #expect(failure.indexLocked)
            #expect(text.contains("NOT back in the working tree"), "\(text)")
            #expect(text.contains("Nothing has been deleted"))
            #expect(text.contains(".sift/set-aside/"))
            #expect(text.contains("`sift run --restore`"))
            #expect(text.contains(".git/index.lock"))
            #expect(!text.contains(root.path), "\(text)")
            #expect(!text.contains(root.resolvingSymlinksInPath().path), "\(text)")
        }
        #expect(FileManager.default.fileExists(atPath: store.recordURL.path))

        try FileManager.default.removeItem(at: lock)
        _ = try SetAsideSession.restoreAbandoned(in: root)

        #expect(try Self.files(of: root) == filesBefore)
    }

    /// A name outside ASCII comes back in the bytes it left in — composed or decomposed, whichever the file system held — not in whichever spelling a file API prefers.
    @Test
    func aNameOutsideASCIIComesBackInItsOwnBytes() throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write("one\n", to: "Sources/one.txt", in: root)
        try TestSources.commitAll(in: root, message: "base")
        let sources = root.path + "/Sources/"
        for name in ["\u{00FC}n\u{00EF}.txt", "d\u{0075}\u{0308}.txt"] {
            let descriptor = open(sources + name, O_CREAT | O_WRONLY, 0o644)
            #expect(descriptor >= 0)
            close(descriptor)
        }
        let namesBefore = Self.nameBytes(in: sources)
        let store = SetAsideStore(repositoryRoot: root)
        let record = try SetAside.capture(pathspecs: ["Sources/"], from: root, into: store)
        try Self.setAsideWhole(record, in: store)
        #expect(Self.nameBytes(in: sources) == [Array("one.txt".utf8)])

        _ = try SetAside(store: store).restore(record)

        #expect(Self.nameBytes(in: sources) == namesBefore)
    }

    /// A change under this tool's own directory is never moved, and never skipped silently either: the record carries it as left in place, and a pathspec with nothing else uncommitted says that is why there is nothing to set aside.
    @Test
    func aChangeUnderThisToolsOwnDirectoryIsLeftInPlaceAndSaid() throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write("one\n", to: "Sources/one.txt", in: root)
        try TestSources.write("{}\n", to: "\(SiftPaths.directoryName)/config.json", in: root)
        try TestSources.runGit(["add", "-f", "\(SiftPaths.directoryName)/config.json"], in: root)
        try TestSources.commitAll(in: root, message: "base")
        try TestSources.write("{\"edited\": true}\n", to: "\(SiftPaths.directoryName)/config.json", in: root)
        let store = SetAsideStore(repositoryRoot: root)

        do {
            _ = try SetAside.capture(pathspecs: ["."], from: root, into: store)
            Issue.record("a change under .sift/ alone was set aside")
        } catch let SetAsideError.nothingUncommitted(_, _, leftInPlace, _) {
            #expect(leftInPlace == ["\(SiftPaths.directoryName)/config.json"])
        }
        try TestSources.write("one, edited\n", to: "Sources/one.txt", in: root)

        let record = try SetAside.capture(pathspecs: ["."], from: root, into: store)

        #expect(record.entries.map(\.path) == ["Sources/one.txt"])
        #expect(record.leftInPlace == ["\(SiftPaths.directoryName)/config.json"])
    }

    /// The refusal while a set-aside holds the tree names whoever actually holds it — the watcher of a run that is gone, not the run's own dead pid.
    @Test
    func aBusyRefusalNamesWhoeverHoldsTheLock() throws {
        let root = try Self.repositoryWithEveryKindOfChange()
        let store = SetAsideStore(repositoryRoot: root)
        let record = try SetAside.capture(pathspecs: ["Sources/"], from: root, into: store, owner: 1)
        let lock = try #require(try SetAsideLock.take(for: store, as: .watcher))
        defer { lock.release() }

        guard case let .busy(holder, found)? = SetAsideSession.refusal(for: root) else {
            Issue.record("a record under a held lock was not refused as busy")
            return
        }
        #expect(holder == SetAsideLock.Holder(pid: getpid(), role: .watcher))
        #expect(found?.id == record.id)
        let text = SetAsideError.busy(holder: holder, record: found).description
        #expect(text.contains("its watcher (pid \(getpid())) is putting them back now"), "\(text)")
    }

    /// A record whose set-aside never began — it is written before the index or any file changes — is cleared without touching anything, so a watcher that finds one never overwrites what the caller has written since.
    @Test
    func aRecordWhoseSetAsideNeverBeganIsClearedWithoutTouchingTheTree() throws {
        let root = try Self.repositoryWithEveryKindOfChange()
        let store = SetAsideStore(repositoryRoot: root)
        let record = try SetAside.capture(pathspecs: ["Sources/"], from: root, into: store)
        try "the caller's newest edit\n".write(to: root.appendingPathComponent("Sources/unstaged.txt"), atomically: true, encoding: .utf8)
        let files = try Self.files(of: root)

        _ = try SetAside(store: store).restore(record)

        #expect(try Self.files(of: root) == files)
        #expect(!FileManager.default.fileExists(atPath: store.directory.path))
    }

    /// After a restore that failed, an interruption finds the failure again rather than nothing to do — the one answer a signal handler must never give over missing work is that the tree is as it was.
    @Test
    func anInterruptionAfterAFailedRestoreReportsTheFailureAgain() throws {
        let root = try Self.repositoryWithEveryKindOfChange()
        let filesBefore = try Self.files(of: root)
        let session = try SetAsideSession.begin(pathspecs: ["Sources/"], from: root)
        guard case .setAside? = try session.setAsideTree() else {
            Issue.record("the set-aside stopped part-way")
            return
        }
        let lock = root.appendingPathComponent(".git/index.lock")
        FileManager.default.createFile(atPath: lock.path, contents: Data())
        #expect(throws: SetAsideError.self) { try session.finish() }

        let interrupted = session.interrupt(forwarding: 0)

        guard case .failure(.notRestored) = interrupted else {
            Issue.record("an interruption after a failed restore answered \(interrupted)")
            return
        }
        session.close()
        try FileManager.default.removeItem(at: lock)
        _ = try SetAsideSession.restoreAbandoned(in: root)
        #expect(try Self.files(of: root) == filesBefore)
    }

    /// A path in the middle of a merge has no single state to put back, so it is refused before anything is copied.
    @Test
    func anUnmergedPathIsRefusedBeforeAnythingIsCopied() throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write("base\n", to: "Sources/shared.txt", in: root)
        try TestSources.commitAll(in: root, message: "base")
        try TestSources.runGit(["checkout", "-q", "-b", "other"], in: root)
        try TestSources.write("theirs\n", to: "Sources/shared.txt", in: root)
        try TestSources.commitAll(in: root, message: "theirs")
        try TestSources.runGit(["checkout", "-q", "main"], in: root)
        try TestSources.write("ours\n", to: "Sources/shared.txt", in: root)
        try TestSources.commitAll(in: root, message: "ours")
        _ = try? TestSources.runGit(["merge", "other"], in: root)
        let store = SetAsideStore(repositoryRoot: root)

        do {
            _ = try SetAside.capture(pathspecs: ["Sources/"], from: root, into: store)
            Issue.record("an unmerged path was set aside")
        } catch let SetAsideError.unsupported(path, reason, flag) {
            #expect(path == "Sources/shared.txt")
            #expect(reason.contains("merge"))
            #expect(flag == "--without")
        }

        #expect(!FileManager.default.fileExists(atPath: store.directory.path))
    }
}

// MARK: - A restore puts back only what the set-aside took, and only while nothing else holds the tree

extension SetAsideTests {
    /// Several pathspecs are one set-aside, not one apiece: every path under any of them goes out of the tree together under a single record, and a path under none of them is untouched.
    ///
    /// This is what lets a caller name two files instead of the directory above them, which would take every unrelated edit under it along.
    @Test
    func severalPathspecsAreOneSetAside() throws {
        let root = try Self.repositoryWithEveryKindOfChange()
        let statusBefore = try Self.status(of: root)
        let filesBefore = try Self.files(of: root)
        let store = SetAsideStore(repositoryRoot: root)

        let record = try SetAside.capture(pathspecs: ["Sources/unstaged.txt", "outside.txt"], from: root, into: store)

        #expect(record.pathspecs == ["Sources/unstaged.txt", "outside.txt"])
        #expect(record.entries.map(\.path).sorted() == ["Sources/unstaged.txt", "outside.txt"])
        try Self.setAsideWhole(record, in: store)
        #expect(try String(contentsOf: root.appendingPathComponent("Sources/unstaged.txt"), encoding: .utf8) == "three\n")
        #expect(try String(contentsOf: root.appendingPathComponent("outside.txt"), encoding: .utf8) == "eight\n")
        #expect(try String(contentsOf: root.appendingPathComponent("Sources/both.txt"), encoding: .utf8) == "two, staged, then edited\n", "a path under neither pathspec keeps its change")
        _ = try SetAside(store: store).restore(record)
        #expect(try Self.status(of: root) == statusBefore)
        #expect(try Self.files(of: root) == filesBefore)
    }

    /// A path left as its writer left it keeps the index entry its writer staged as well: a restore that spares a path's file never puts its index entry back over somebody's staging of it.
    @Test
    func aPathStagedAgainByItsWriterKeepsThatStaging() throws {
        let root = try Self.repositoryWithEveryKindOfChange()
        let store = SetAsideStore(repositoryRoot: root)
        let record = try SetAside.capture(pathspecs: ["Sources/"], from: root, into: store)
        try Self.setAsideWhole(record, in: store)
        // What a writer did to one path while it was out: wrote it, and staged the write.
        try "written and staged by somebody\n".write(to: root.appendingPathComponent("Sources/staged.txt"), atomically: true, encoding: .utf8)
        try TestSources.runGit(["add", "Sources/staged.txt"], in: root)
        let staging = try TestSources.runGit(["ls-files", "-s", "--", "Sources/staged.txt"], in: root)

        _ = try SetAside(store: store).restore(record, sparing: ["Sources/staged.txt"])

        #expect(try TestSources.runGit(["ls-files", "-s", "--", "Sources/staged.txt"], in: root) == staging, "the writer's staging was undone")
        #expect(try String(contentsOf: root.appendingPathComponent("Sources/staged.txt"), encoding: .utf8) == "written and staged by somebody\n")
        #expect(try TestSources.runGit(["show", ":Sources/both.txt"], in: root) == "two, staged\n", "every other path's staging came back")
    }

    /// `sift reset` refuses while a run holds the set-aside lock in its second pass — the tree back, no record standing — because deleting the lock with the rest would let a second run set the tree aside under the first.
    @Test
    func resetRefusesWhileARunHoldsTheLockWithNoRecord() throws {
        let root = try Self.repositoryWithEveryKindOfChange()
        let session = try SetAsideSession.begin(pathspecs: ["Sources/"], from: root)
        guard case .setAside? = try session.setAsideTree() else {
            Issue.record("the set-aside stopped part-way")
            return
        }
        try session.finish()
        let lock = SetAsideStore(repositoryRoot: root).lockURL

        do {
            _ = try SiftEngine.reset(directory: root)
            Issue.record("reset deleted .sift/ under a run's second pass")
        } catch let error as SetAsideError {
            #expect(error.description.contains("is running its tests again with the changes back in place"), "\(error)")
        }
        #expect(FileManager.default.fileExists(atPath: lock.path))

        session.close()
        _ = try SiftEngine.reset(directory: root)
        #expect(!FileManager.default.fileExists(atPath: SiftPaths.cache(in: root).path))
    }
}

/// Covers the set-aside a `--since` run stands on: the change a commit made leaves the tree, the paths read as the commit before it has them, and every byte comes back.
extension SetAsideTests {
    /// Every kind of committed change goes — an edit, a file the commit removed, a file it added — the pathspec reads as the revision has it in the index and the files, and all of it comes back exactly.
    @Test
    func aCommittedChangeIsSetAsideToItsRevisionAndComesBackExactly() throws {
        let (root, base) = try Self.repositoryWithACommittedChange()
        let statusBefore = try Self.status(of: root)
        let filesBefore = try Self.files(of: root)
        let indexBefore = try Self.index(of: root)
        let store = SetAsideStore(repositoryRoot: root)

        let record = try SetAside.capture(pathspecs: ["Sources/"], from: root, into: store, since: base)
        #expect(record.since == base)
        #expect(record.newFiles == ["Sources/added.txt"])
        try Self.setAsideWhole(record, in: store)

        // Set aside: every path under the pathspec reads as the revision has it, in the files and the index,
        // and the file the commit added is gone — a test that names what it declares cannot build.
        for (path, text) in [("Sources/edited.txt", "one\n"), ("Sources/removed.txt", "two\n"), ("Sources/kept.txt", "three\n")] {
            #expect(try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) == text, "\(path)")
        }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Sources/added.txt").path))
        #expect(try TestSources.runGit(["diff", "--cached", "--name-only", base, "--", "Sources/"], in: root).isEmpty)
        // …and the change the same commit made outside the pathspec never moved.
        #expect(try String(contentsOf: root.appendingPathComponent("outside.txt"), encoding: .utf8) == "outside, edited\n")

        let restored = try SetAside(store: store).restore(record)

        #expect(try Self.status(of: root) == statusBefore)
        #expect(try Self.files(of: root) == filesBefore)
        #expect(try Self.index(of: root) == indexBefore)
        #expect(restored.kept.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: store.directory.path), "the record and its copies go once the check passes")
    }

    /// A tree with anything uncommitted under the pathspec is refused, by the path that holds it: a committed change and one in the tree never go out together.
    @Test
    func aSinceCaptureRefusesAnythingUncommittedUnderThePathspec() throws {
        let (root, base) = try Self.repositoryWithACommittedChange()
        try TestSources.write("one, fixed, and edited again\n", to: "Sources/edited.txt", in: root)
        let filesBefore = try Self.files(of: root)
        let store = SetAsideStore(repositoryRoot: root)

        do {
            _ = try SetAside.capture(pathspecs: ["Sources/"], from: root, into: store, since: base)
            Issue.record("a tree with an uncommitted change under the pathspec was accepted")
        } catch let error as SetAsideError {
            #expect(error.description.contains("Sources/edited.txt"), "\(error.description)")
            #expect(error.description.contains("uncommitted"), "\(error.description)")
        }

        #expect(try Self.files(of: root) == filesBefore)
        #expect(!FileManager.default.fileExists(atPath: store.directory.path))
    }

    /// A revision nothing changed under since is refused rather than answered with an empty set-aside.
    @Test
    func aRevisionWithNoChangeUnderThePathspecIsRefused() throws {
        let (root, _) = try Self.repositoryWithACommittedChange()
        let head = try TestSources.runGit(["rev-parse", "HEAD"], in: root).trimmingCharacters(in: .whitespacesAndNewlines)
        let store = SetAsideStore(repositoryRoot: root)

        do {
            _ = try SetAside.capture(pathspecs: ["Sources/"], from: root, into: store, since: head)
            Issue.record("a revision with nothing to set aside was accepted")
        } catch let error as SetAsideError {
            #expect(error.description.contains("nothing under Sources/ changed since"), "\(error.description)")
        }

        #expect(!FileManager.default.fileExists(atPath: store.directory.path))
    }

    /// A pathspec that matches no file git knows of is told apart from a genuinely clean one: a typo, more likely under `--since` since it is typically typed with a longer path, must not be told nothing changed under a path that never matched anything.
    @Test
    func aSinceRevisionWithAPathspecMatchingNoFileSaysSoRatherThanNothingChanged() throws {
        let (root, base) = try Self.repositoryWithACommittedChange()
        let store = SetAsideStore(repositoryRoot: root)

        do {
            _ = try SetAside.capture(pathspecs: ["Nowhere/"], from: root, into: store, since: base)
            Issue.record("a pathspec matching no file was accepted")
        } catch let SetAsideError.nothingSince(pathspecs, _, matchesFiles, _) {
            #expect(pathspecs == ["Nowhere/"])
            #expect(!matchesFiles)
        }

        #expect(!FileManager.default.fileExists(atPath: store.directory.path))
    }
}

extension SetAsideTests {
    /// A repository whose `Sources/` holds one of every kind of uncommitted change, and one change outside it — and, when asked, a branch `other` whose one commit changes `Sources/unstaged.txt`.
    private static func repositoryWithEveryKindOfChange(otherBranch: Bool = false) throws -> URL {
        let root = try TestSources.makeTempRepo()
        let sources = root.appendingPathComponent("Sources")
        for (name, text) in [
            ("staged.txt", "one\n"), ("both.txt", "two\n"), ("unstaged.txt", "three\n"), ("gone-staged.txt", "four\n"),
            ("gone.txt", "five\n"), ("moved.txt", "six\n"), ("mode.sh", "seven\n"),
        ] {
            try TestSources.write(text, to: "Sources/\(name)", in: root)
        }
        try TestSources.write("eight\n", to: "outside.txt", in: root)
        try FileManager.default.createSymbolicLink(atPath: sources.appendingPathComponent("link").path, withDestinationPath: "staged.txt")
        try TestSources.commitAll(in: root, message: "base")
        if otherBranch {
            try TestSources.runGit(["checkout", "-q", "-b", "other"], in: root)
            try TestSources.write("three, on the other branch\n", to: "Sources/unstaged.txt", in: root)
            try TestSources.commitAll(in: root, message: "other")
            try TestSources.runGit(["checkout", "-q", "main"], in: root)
        }

        try TestSources.write("one, staged\n", to: "Sources/staged.txt", in: root)
        try TestSources.runGit(["add", "Sources/staged.txt"], in: root)
        try TestSources.write("two, staged\n", to: "Sources/both.txt", in: root)
        try TestSources.runGit(["add", "Sources/both.txt"], in: root)
        try TestSources.write("two, staged, then edited\n", to: "Sources/both.txt", in: root)
        try TestSources.write("three, edited\n", to: "Sources/unstaged.txt", in: root)
        try TestSources.runGit(["rm", "-q", "Sources/gone-staged.txt"], in: root)
        try FileManager.default.removeItem(at: sources.appendingPathComponent("gone.txt"))
        try TestSources.runGit(["mv", "Sources/moved.txt", "Sources/renamed.txt"], in: root)
        chmod(sources.appendingPathComponent("mode.sh").path, 0o755)
        try FileManager.default.removeItem(at: sources.appendingPathComponent("link"))
        try FileManager.default.createSymbolicLink(atPath: sources.appendingPathComponent("link").path, withDestinationPath: "unstaged.txt")
        try TestSources.write("nine\n", to: "Sources/new/untracked.txt", in: root)
        chmod(sources.appendingPathComponent("new/untracked.txt").path, 0o600)
        try TestSources.write("nine and a half\n", to: "Sources/new/with space.txt", in: root)
        try TestSources.write("ten\n", to: "Sources/intended.txt", in: root)
        try TestSources.runGit(["add", "-N", "Sources/intended.txt"], in: root)
        try TestSources.write("eight, edited\n", to: "outside.txt", in: root)
        return root
    }

    /// A repository whose second commit edits a file under `Sources/`, removes another, adds a third and changes one outside it — and the commit before that one, which a `--since` run sets it aside to.
    private static func repositoryWithACommittedChange() throws -> (root: URL, base: String) {
        let root = try TestSources.makeTempRepo()
        for (name, text) in [("edited.txt", "one\n"), ("removed.txt", "two\n"), ("kept.txt", "three\n")] {
            try TestSources.write(text, to: "Sources/\(name)", in: root)
        }
        try TestSources.write("outside\n", to: "outside.txt", in: root)
        try TestSources.commitAll(in: root, message: "base")
        let base = try TestSources.runGit(["rev-parse", "HEAD"], in: root).trimmingCharacters(in: .whitespacesAndNewlines)

        try TestSources.write("one, fixed\n", to: "Sources/edited.txt", in: root)
        try FileManager.default.removeItem(at: root.appendingPathComponent("Sources/removed.txt"))
        try TestSources.write("four\n", to: "Sources/added.txt", in: root)
        try TestSources.write("outside, edited\n", to: "outside.txt", in: root)
        try TestSources.commitAll(in: root, message: "the fix")
        return (root, base)
    }

    /// git's own reading of the tree, whole: the split for every tracked path and every untracked file, less this tool's own directory, where a set-aside keeps its store.
    private static func status(of root: URL) throws -> String {
        try TestSources.runGit(["status", "--porcelain=v2", "--untracked-files=all", "--", ".", ":(exclude)\(SiftPaths.directoryName)"], in: root)
    }

    /// Every file under the root but git's and this tool's own directories: its permission bits and bytes, or a link's target.
    private static func files(of root: URL) throws -> [String: String] {
        var found: [String: String] = [:]
        func walk(_ relative: String) throws {
            let directory = relative.isEmpty ? root : root.appendingPathComponent(relative)
            for name in try FileManager.default.contentsOfDirectory(atPath: directory.path) {
                if relative.isEmpty, name == ".git" || name == SiftPaths.directoryName {
                    continue
                }
                let path = relative.isEmpty ? name : "\(relative)/\(name)"
                let item = root.appendingPathComponent(path)
                var info = stat()
                guard lstat(item.path, &info) == 0 else {
                    continue
                }
                switch info.st_mode & S_IFMT {
                case S_IFDIR:
                    found[path] = "directory"
                    try walk(path)
                case S_IFLNK:
                    found[path] = try "link to \(FileManager.default.destinationOfSymbolicLink(atPath: item.path))"
                default:
                    found[path] = try "mode \(String(info.st_mode & 0o7777, radix: 8)): \(String(contentsOf: item, encoding: .utf8))"
                }
            }
        }
        try walk("")
        return found
    }

    /// Every index entry, with its mode, object and stage — what a restore puts back whatever HEAD has become.
    private static func index(of root: URL) throws -> String {
        try TestSources.runGit(["ls-files", "-s"], in: root)
    }

    /// The names in a directory, in the bytes the file system holds them under, sorted.
    private static func nameBytes(in directory: String) -> [[UInt8]] {
        guard let stream = opendir(directory) else {
            return []
        }
        defer { closedir(stream) }
        var names: [[UInt8]] = []
        while let entry = readdir(stream) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) { Array($0.prefix(Int(entry.pointee.d_namlen))) }
            if name != Array(".".utf8), name != Array("..".utf8) {
                names.append(name)
            }
        }
        return names.sorted { $0.lexicographicallyPrecedes($1) }
    }

    /// Sets `record` aside, failing the test unless every path went.
    private static func setAsideWhole(_ record: SetAsideRecord, in store: SetAsideStore, sourceLocation: SourceLocation = #_sourceLocation) throws {
        guard case .setAside = try SetAside(store: store).setAside(record) else {
            Issue.record("the set-aside stopped part-way", sourceLocation: sourceLocation)
            return
        }
    }

    /// Where the store keeps its copy of `path`, when the record holds a file for it.
    private static func copy(of path: String, in record: SetAsideRecord, store: SetAsideStore) -> URL? {
        guard case let .file(_, _, copy)? = record.entries.first(where: { $0.path == path })?.worktree else {
            return nil
        }
        return store.copies.appendingPathComponent(copy)
    }
}
