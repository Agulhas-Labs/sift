//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore
import Testing

/// Covers what `sift run --without` keeps and leaves alone: bytes it did not write, and anything the run left running.
@Suite(.temporaryDirectories)
struct RunWithoutKeptBytesTests {
    typealias Fixture = RunWithoutCommandTests.Fixture
    typealias ScratchVolume = RunWithoutCommandTests.ScratchVolume
    typealias Racer = RunWithoutCommandTests.Racer

    // MARK: - Nothing is removed or replaced on the strength of an earlier look

    /// A write landing on a path that goes back to being deleted, while the restore waits for another git's index lock, is kept beside it — never deleted on the strength of a look taken before the wait.
    @Test
    func aWriteLandingWhileTheRestoreWaitsForTheIndexLockIsKept() throws {
        let fixture = try Fixture()
        try fixture.commit(["Sources/gone.txt": "gone\n", "Sources/gone-staged.txt": "gone, staged\n"])
        try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("Sources/gone.txt"))
        try fixture.git(["rm", "-q", "Sources/gone-staged.txt"])
        let index = try fixture.index()
        let proceed = fixture.beside("go")
        let running = try fixture.launch(holdingAt: "without", environment: ["SIFT_HOLD_UNTIL": proceed.path])
        _ = try running.waitUntilTheTestsAreRunning()

        let lock = fixture.root.appendingPathComponent(".git/index.lock")
        FileManager.default.createFile(atPath: lock.path, contents: Data())
        FileManager.default.createFile(atPath: proceed.path, contents: Data())
        // The restore starts as the tests end, and waits for the lock: these land while it does.
        sleep(1)
        let written = "written while the restore waited for the index lock\n"
        try fixture.write(written, to: "Sources/gone.txt")
        try fixture.write(written, to: "Sources/gone-staged.txt")
        usleep(500_000)
        try FileManager.default.removeItem(at: lock)
        let result = try running.finish()

        #expect(result.status == 0, "\(result.stdout)\(result.stderr)")
        for path in ["Sources/gone.txt", "Sources/gone-staged.txt"] {
            let kept = fixture.kept(in: "Sources").filter { $0.hasPrefix("\(path).sift-kept-") }
            #expect(kept.count == 1, "\(path) — kept: \(fixture.kept(in: "Sources"))")
            #expect(kept.first.flatMap { fixture.contents(of: $0) } == written)
            #expect(result.stdout.contains("kept rather than overwritten: \(kept.first ?? path)"), "\(result.stdout)")
            #expect(fixture.contents(of: path) == nil, "\(path) should be deleted again, as it was")
        }
        #expect(try fixture.index() == index)
        #expect(!fixture.recordExists)
    }

    /// A write landing on a path that goes back to being deleted, a second into the restore of many paths, is never deleted — whether it lands before the path is put back, and is kept beside it, or after, and stays.
    @Test
    func aWriteLandingWhileManyPathsGoBackIsNeverDeleted() throws {
        let fixture = try Fixture()
        var committed = ["Sources/gone.txt": "gone\n"]
        for number in 0 ..< 600 {
            committed["Sources/many/\(number).txt"] = "\(number)\n"
        }
        try fixture.commit(committed)
        for number in 0 ..< 600 {
            try fixture.write("\(number), staged\n", to: "Sources/many/\(number).txt")
        }
        try fixture.git(["add", "Sources/many"])
        try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("Sources/gone.txt"))
        let done = fixture.beside("pass-done")
        let running = try fixture.launch(Fixture.proof, environment: ["SIFT_PASS_DONE": done.path])
        try fixture.wait("the run without the change ending", upTo: 120) { FileManager.default.fileExists(atPath: done.path) }

        usleep(1_000_000)
        let written = "written a second into the restore\n"
        try fixture.write(written, to: "Sources/gone.txt")
        let result = try running.finish()

        let kept = fixture.kept(in: "Sources").filter { $0.hasPrefix("Sources/gone.txt.sift-kept-") }
        let survived = fixture.contents(of: "Sources/gone.txt") == written || kept.contains { fixture.contents(of: $0) == written }

        #expect(survived, "the write was deleted — \(result.stdout)\(result.stderr)")
        #expect(result.status == 0, "\(result.stdout)\(result.stderr)")
        #expect(!fixture.recordExists)
    }

    /// On a volume that cannot clone — HFS+, where putting a file back means copying it — an editor saving the file while its copy is being made is never overwritten: the copy is built whole in the store and put in place by a move that brings out whatever stands at the path, which is kept.
    @Test
    func aSaveLandingWhileAFileIsBeingPutBackIsKeptOnAVolumeThatCannotClone() throws {
        let volume = try ScratchVolume()
        defer { volume.detach() }
        let fixture = try Fixture(under: volume.mountPoint)
        let large = String(repeating: "the original, uncommitted and large\n", count: 500_000)
        try fixture.commit(["Sources/large.dat": "small\n"])
        try fixture.write(large, to: "Sources/large.dat")
        let saved = "saved by an editor while the file was being put back\n"
        let sources = fixture.root.appendingPathComponent("Sources").path
        let staging = SetAsideStore(repositoryRoot: fixture.root).directory.appendingPathComponent("staging").path
        // The restore holds its built copy out of the tree while this exists, so the save lands before the move by construction rather than by winning a poll against the copy.
        let hold = fixture.beside("hold").path
        FileManager.default.createFile(atPath: hold, contents: Data())
        let racer = Racer(until: { !Racer.names(in: staging).isEmpty }, then: {
            Racer.save("\(sources)/large.dat", holding: saved)
            unlink(hold)
        })

        let result = try fixture.sift(Fixture.proof, environment: ["SIFT_TEST_HOLD_PUT_BACK": hold])
        let raced = racer.stop()

        #expect(raced, "the save never landed, so nothing was tested")
        let standing = fixture.contents(of: "Sources/large.dat")
        let kept = fixture.kept(in: "Sources").filter { $0.hasPrefix("Sources/large.dat.sift-kept-") }
        #expect(standing == saved || kept.contains { fixture.contents(of: $0) == saved }, "the save was overwritten — \(result.stdout)\(result.stderr)")
        #expect(standing == large || standing == saved, "the original never came back")
        #expect(result.status == 0, "\(result.stdout)\(result.stderr)")
    }

    // MARK: - Nothing the run left running outlives its restore

    /// A writer the run left behind that ignores `SIGTERM`, and a `--restore` started the moment the run is killed: whichever of the watcher and the restore takes the lock ends the writer before putting anything back, so its write lands in the set-aside tree and is kept — never over the restored one.
    @Test
    func aWriterThatIgnoresSIGTERMIsEndedBeforeAnImmediateRestore() throws {
        let fixture = try Fixture()
        let index = try fixture.index()
        let running = try fixture.launch(holdingAt: "without", environment: ["SIFT_TEST_STUBBORN": "1"])
        _ = try running.waitUntilTheTestsAreRunning()

        kill(running.process.processIdentifier, SIGKILL)
        _ = try running.finish()
        let restore = try fixture.sift(["run", "--restore"])
        try fixture.wait("the tree being put back") { !fixture.recordExists }
        // Past the moment the writer would have written.
        sleep(2)

        #expect(restore.status == 0 || restore.status == 2, "\(restore.stdout)\(restore.stderr)")
        #expect(fixture.contents(of: "Sources/feature.txt") == "fixed\n", "the writer wrote over the restored tree")
        #expect(try fixture.index() == index)
        let kept = fixture.kept(in: "Sources")
        #expect(kept.contains { fixture.contents(of: $0) == "written by a process that ignored SIGTERM\n" }, "\(kept)")
    }

    /// Killed together with its watcher, a run leaves nobody to end what it started — so `run --restore` does, from the sessions the run wrote into the store, before it puts anything back, and says so.
    @Test
    func aRestoreAfterTheRunAndItsWatcherWereKilledEndsWhatTheyLeftRunning() throws {
        let fixture = try Fixture()
        let before = try fixture.snapshot()
        let running = try fixture.launch(holdingAt: "without", environment: fixture.leavingAWriter)
        _ = try running.waitUntilTheTestsAreRunning()
        let watcher = try #require(try fixture.watcher(), "no watcher was found for the run")

        // The watcher first: killed after its run, it would already be putting the tree back.
        kill(watcher, SIGKILL)
        try fixture.wait("the watcher dying") { kill(watcher, 0) != 0 }
        kill(running.process.processIdentifier, SIGKILL)
        _ = try running.finish()
        let restored = try fixture.sift(["run", "--restore"])
        try fixture.waitForTheWriterToEnd()

        #expect(restored.status == 0, "\(restored.stdout)\(restored.stderr)")
        #expect(restored.stdout.contains("the run had left running, before putting the changes back"), "\(restored.stdout)")
        #expect(try fixture.snapshot() == before)
    }

    /// A watcher that died while the changes were out is said in the answer: nothing was lost, but for part of the run a kill would have left them out of the tree.
    @Test
    func aWatcherThatDiedWhileTheChangesWereOutIsSaid() throws {
        let fixture = try Fixture()
        let before = try fixture.snapshot()
        let proceed = fixture.beside("go")
        let running = try fixture.launch(holdingAt: "without", environment: ["SIFT_HOLD_UNTIL": proceed.path])
        _ = try running.waitUntilTheTestsAreRunning()
        let watcher = try #require(try fixture.watcher(), "no watcher was found for the run")

        kill(watcher, SIGKILL)
        try fixture.wait("the watcher dying") { kill(watcher, 0) != 0 }
        FileManager.default.createFile(atPath: proceed.path, contents: Data())
        let result = try running.finish()

        #expect(result.status == 0, "\(result.stdout)\(result.stderr)")
        #expect(result.stdout.contains("the watcher that puts the changes back if this process is killed had stopped"), "\(result.stdout)")
        #expect(try fixture.snapshot() == before)
    }

    // MARK: - Somebody's bytes are kept, or the run stops saying where they are

    /// An original whose name is too long to take a `.sift-kept-` suffix, whose path somebody took again while it was being set aside, is kept beside the path under a shorter name that still says whose it is — never lost with the store.
    @Test
    func anOriginalWhoseNameTakesNoSuffixIsKeptUnderAShorterOne() throws {
        let fixture = try Fixture()
        let name = "Sources/" + String(repeating: "n", count: 244)
        try fixture.commit([name: "committed\n"])
        try fixture.makeLarge(name, bytes: 256 << 20, startingWith: "the uncommitted change\n")
        let path = fixture.root.appendingPathComponent(name).path
        let racer = Racer(until: { !Racer.exists(path) }, then: { Racer.create(path, holding: "written by somebody else\n") })

        let result = try fixture.sift(Fixture.proof)
        let raced = racer.stop()

        #expect(raced, "the path was never taken, so nothing was tested")
        #expect(result.status == 2, "\(result.stdout)\(result.stderr)")
        #expect(fixture.contents(of: name) == "written by somebody else\n")
        let kept = fixture.kept(in: "Sources")
        #expect(kept.count == 1, "\(kept)")
        if let original = kept.first {
            #expect(fixture.size(of: original) == 256 << 20, "the original is not what was kept")
            #expect((original.split(separator: "/").last?.utf8.count ?? 256) <= 255)
            #expect(result.stderr.contains("kept rather than overwritten: \(original)"), "\(result.stderr)")
        }
        #expect(!fixture.recordExists)
    }

    /// An original that cannot be kept beside its path — somebody took the path again and made its directory read-only — stops the run saying the work is not back and where the original is, with the record kept; once the directory can be written again, `run --restore` puts it back.
    @Test
    func anOriginalThatCannotBeKeptStopsTheRunWithTheWorkNotBack() throws {
        let fixture = try Fixture()
        try fixture.commit(["Large/large.dat": "committed\n"])
        try fixture.makeLarge("Large/large.dat", bytes: 256 << 20, startingWith: "the uncommitted change\n")
        let directory = fixture.root.appendingPathComponent("Large").path
        let path = directory + "/large.dat"
        let racer = Racer(until: { !Racer.exists(path) }, then: {
            Racer.create(path, holding: "written by somebody else\n")
            chmod(directory, 0o555)
        })
        defer { chmod(directory, 0o755) }

        let result = try fixture.sift(["run", "--without", "Sources/", "--without", "Large/", "--", "swift", "test", "--filter", "WidgetTests"])
        let raced = racer.stop()

        #expect(raced, "the path was never taken, so nothing was tested")
        #expect(result.status == 3, "\(result.stdout)\(result.stderr)")
        #expect(result.stderr.contains("are NOT back in the working tree"), "\(result.stderr)")
        #expect(result.stderr.contains("it is at .sift/set-aside/moved/"), "\(result.stderr)")
        #expect(fixture.recordExists)
        try fixture.wait("the watcher letting go", upTo: 60) {
            if case .unrestored? = SetAsideSession.refusal(for: fixture.root) {
                return true
            }
            return false
        }

        chmod(directory, 0o755)
        let restored = try fixture.sift(["run", "--restore"])

        #expect(restored.status == 0, "\(restored.stdout)\(restored.stderr)")
        #expect(fixture.size(of: "Large/large.dat") == 256 << 20, "the original did not come back")
        #expect(fixture.kept(in: "Large").contains { fixture.contents(of: $0) == "written by somebody else\n" })
        #expect(fixture.contents(of: "Sources/feature.txt") == "fixed\n")
    }

    /// A file whose name is too long to take a suffix comes back whole: what a restore puts back is built in the store, never beside the path under a longer name.
    @Test
    func aFileWhoseNameTakesNoSuffixComesBack() throws {
        let fixture = try Fixture()
        let name = "Sources/" + String(repeating: "n", count: 250)
        try fixture.commit([name: "committed\n"])
        try fixture.write("changed\n", to: name)
        let before = try fixture.snapshot()

        let result = try fixture.sift(Fixture.proof)

        #expect(result.status == 0, "\(result.stdout)\(result.stderr)")
        #expect(try fixture.snapshot() == before)
    }
}
