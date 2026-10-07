//
// Copyright © Agulhas Labs
//

import Darwin
import Foundation
@testable import SiftCore
import Testing

/// Covers the edges a set-aside meets outside the tree's own contents: a name with no room for a suffix, a watcher that has gone, a volume that is full.
@Suite(.temporaryDirectories)
struct SetAsideEdgeTests {
    /// A name with room for the suffix takes it whole; one without keeps as much of itself as fits and a hash of the whole, so it still fits the 255 bytes a name may hold, still says whose it is, and is still told apart from a name that shares its start.
    @Test
    func aNameWithNoRoomForTheSuffixIsShortenedButStillSaysWhoseItIs() {
        let suffix = ".sift-kept-01234567"
        let long = String(repeating: "n", count: 244)
        let longer = long + "x"
        let decomposed = String(repeating: "u\u{0308}", count: 90)

        #expect(SetAsideTree.fitted("short.txt", suffix: suffix) == "short.txt" + suffix)
        let fitted = SetAsideTree.fitted(long, suffix: suffix)
        #expect(fitted.utf8.count <= 255)
        #expect(fitted.hasPrefix(String(repeating: "n", count: 200)))
        #expect(fitted.hasSuffix(suffix))
        #expect(fitted != SetAsideTree.fitted(longer, suffix: suffix))
        let shortened = SetAsideTree.fitted(decomposed, suffix: suffix)
        #expect(shortened.utf8.count <= 255)
        #expect(shortened.hasPrefix("u\u{0308}"), "a name is cut between characters, never inside one")
    }

    /// Keeping bytes beside a path whose name has no room for a suffix still keeps them, beside it, under a name the file system takes.
    @Test
    func bytesBesideAPathWithNoRoomForASuffixAreStillKept() throws {
        let root = try TestSources.makeTempRepo()
        let tree = SetAsideTree(root: root)
        let name = "Sources/" + String(repeating: "n", count: 250)
        try TestSources.write("the path's own\n", to: name, in: root)
        try TestSources.write("somebody's\n", to: "elsewhere.txt", in: root)

        let kept = try tree.keep(tree.absolute("elsewhere.txt"), beside: name, id: "0123456789")

        #expect(kept.hasPrefix("Sources/"))
        #expect(try String(contentsOf: root.appendingPathComponent(kept), encoding: .utf8) == "somebody's\n")
        #expect(try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8) == "the path's own\n")
    }

    /// A keep never lands on a name somebody else holds: it passes over it for the next.
    @Test
    func aKeepPassesOverANameSomebodyHolds() throws {
        let root = try TestSources.makeTempRepo()
        let tree = SetAsideTree(root: root)
        let taken = tree.keptName(for: "one.txt", id: "0123456789")
        try TestSources.write("already here\n", to: taken, in: root)
        try TestSources.write("somebody's\n", to: "two.txt", in: root)

        let kept = try tree.keep(tree.absolute("two.txt"), beside: "one.txt", id: "0123456789")

        #expect(kept != taken)
        #expect(try String(contentsOf: root.appendingPathComponent(taken), encoding: .utf8) == "already here\n")
        #expect(try String(contentsOf: root.appendingPathComponent(kept), encoding: .utf8) == "somebody's\n")
    }

    /// A watcher that has gone is learned of at the next byte written to it — a probe, or the release — rather than never.
    ///
    /// Gone means nothing holds the pipe's other end, and closing this test's own copy does not make that true by itself: a child that another test in this process is spawning at that moment holds a copy of every descriptor not marked close-on-exec until its spawn completes, and while it does the pipe still has a reader and the byte is taken. So the check waits for the kernel's own word that the last reader has left — the end-of-file an owner's pipe carries once its watcher is dead.
    @Test
    func aHandleWhoseWatcherIsGoneSaysSo() throws {
        var ends: [Int32] = [0, 0]
        try #require(pipe(&ends) == 0)
        _ = fcntl(ends[1], F_SETNOSIGPIPE, 1)
        let handle = SetAsideGuardian.Handle(descriptor: ends[1])

        #expect(handle.isWatching(), "a watcher still reading was taken for gone")
        close(ends[0])
        try #require(Self.lastReaderLeft(ends[1]), "the pipe still had a reader long after the test closed its own end")

        #expect(!handle.isWatching())
        #expect(!handle.release())
    }

    /// While another process still holds a copy of the watcher's end the pipe is still being read, and the handle says so; once the last copy has gone, the next byte says the watcher has gone — the moment a loaded run once caught between a test closing its end and probing, made to happen every time.
    @Test
    func aWatcherEndAnotherProcessStillHoldsIsStillBeingRead() throws {
        var ends: [Int32] = [0, 0]
        try #require(pipe(&ends) == 0)
        _ = fcntl(ends[1], F_SETNOSIGPIPE, 1)
        let handle = SetAsideGuardian.Handle(descriptor: ends[1])
        let holder = try Self.suspendedHolder(of: ends[0])
        defer {
            // Not reaped until here, so the pid is still this test's child and cannot name anybody else.
            kill(holder, SIGKILL)
            var status: Int32 = 0
            waitpid(holder, &status, 0)
        }
        close(ends[0])

        #expect(handle.isWatching(), "a copy of the watcher's end that another process holds was taken for gone")
        #expect(!Self.lastReaderLeft(ends[1], within: 0.2), "the pipe was said to have no reader while another process held its end")
        kill(holder, SIGKILL)
        try #require(Self.lastReaderLeft(ends[1]), "the pipe still had a reader long after the process holding its end was killed")

        #expect(!handle.isWatching())
        #expect(!handle.release())
    }

    /// A restore stopped by a full volume says so, and says how to get past it — which retrying alone will not.
    @Test
    func aFullVolumeIsNamedWithTheWayPastIt() {
        let full = SetAsideError.NotRestored(
            reasons: ["could not rebuild Sources/large.dat from its copy: \(String(cString: strerror(ENOSPC)))"],
            invocation: "--without Sources/",
            store: ".sift/set-aside/",
            id: "0123456789"
        )
        let other = SetAsideError.NotRestored(reasons: ["Sources/a.txt: expected a file, found nothing"], invocation: "--without Sources/", store: ".sift/set-aside/", id: "0123456789")

        #expect(SetAsideError.notRestored(full).description.contains("The volume holding this repository is full. Free some space on it"))
        #expect(SetAsideError.notRestored(full).description.contains("then run `sift run --restore`"))
        #expect(!SetAsideError.notRestored(other).description.contains("is full"))
    }
}

private extension SetAsideEdgeTests {
    /// Whether the kernel says, within `seconds`, that nothing holds the reading end of the pipe `descriptor` writes into — whoever else had a copy of it.
    static func lastReaderLeft(_ descriptor: Int32, within seconds: TimeInterval = 30) -> Bool {
        let queue = kqueue()
        guard queue >= 0 else {
            return false
        }
        defer { close(queue) }
        // Cleared after each report: a writing end is writable from the start, which a level-triggered filter reports
        // on every call; cleared, it reports again only when the pipe changes, as when its last reader goes.
        var change = kevent(ident: UInt(descriptor), filter: Int16(EVFILT_WRITE), flags: UInt16(EV_ADD | EV_CLEAR), fflags: 0, data: 0, udata: nil)
        guard kevent(queue, &change, 1, nil, 0, nil) == 0 else {
            return false
        }
        let deadline = Date().addingTimeInterval(seconds)
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else {
                return false
            }
            var event = kevent()
            let whole = remaining.rounded(.down)
            var limit = timespec(tv_sec: Int(whole), tv_nsec: Int((remaining - whole) * 1_000_000_000))
            if kevent(queue, nil, 0, &event, 1, &limit) > 0, event.flags & UInt16(EV_EOF) != 0 {
                return true
            }
        }
    }

    /// A process that holds a copy of `descriptor` and never runs an instruction, so the copy stays until the test kills it.
    static func suspendedHolder(of descriptor: Int32, sourceLocation: SourceLocation = #_sourceLocation) throws -> pid_t {
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Nothing else of this process goes with it: every descriptor but the one named closes on exec.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_START_SUSPENDED | POSIX_SPAWN_CLOEXEC_DEFAULT))
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addinherit_np(&actions, descriptor)
        let arguments: [UnsafeMutablePointer<CChar>?] = [strdup("/usr/bin/true"), nil]
        defer { free(arguments[0]) }
        var pid = pid_t()
        let spawned = posix_spawn(&pid, "/usr/bin/true", &actions, &attributes, arguments, environ)
        try #require(spawned == 0, "could not start a process to hold the watcher's end: \(String(cString: strerror(spawned)))", sourceLocation: sourceLocation)
        return pid
    }
}
