//
// Copyright © Agulhas Labs
//

import ArgumentParser
import Foundation
import SiftCore
import SiftMCP

/// `sift mcp` — the stdio server face for Claude Code; stdout carries JSON-RPC only.
struct MCPCommand: AsyncParsableCommand {
    static var configuration: CommandConfiguration {
        CommandConfiguration(commandName: "mcp", abstract: "Run the MCP stdio server (register with: claude mcp add --transport stdio sift -- sift mcp).")
    }

    @OptionGroup var rootOptions: RootOptions

    /// Whether to read the handover in this process's environment, print it back as this binary read it, and serve nothing.
    ///
    /// How a running server whose binary has been replaced asks the replacement whether it can take the session over (``SiftMCP/ServerReexec``) — hidden, because nothing else has a use for it. Exits nonzero, with nothing on stdout, where there is no handover this build can read — an error line goes to stderr, since stdout is the only stream the asking image reads back.
    @Flag(name: .customLong("read-handover"), help: .hidden)
    var readHandover = false

    func run() async throws {
        if readHandover {
            guard let readBack = ServerHandover.readBack() else {
                StandardStreams.emitError("sift mcp: no \(ServerHandover.environmentKey) this build can read")
                throw ExitCode.failure
            }
            StandardStreams.emit(readBack)
            return
        }
        // Present only in a process that replaced its own image to pick up a new binary: the same process, carrying on a
        // session its previous image began. Taken out of the environment here, before anything could inherit it.
        let handover = ServerHandover.take(note: { StandardStreams.emitError($0) })
        // Read first, before the start line: that line is how anything outside this process knows the server is
        // up, and the parent it names is the one the watch below is armed on. Read after it, a parent that died in
        // between would be answered as launchd, and a server whose parent is the system arms no watch at all. A
        // process carrying on after an exec was read by its first image, and the watch goes back on that pid.
        let spawnedBy = handover?.parent ?? getppid()
        let lifecycle = ServerLifecycleLog.standard(note: { StandardStreams.emitError($0) })
        let pid = getpid()
        let startedAt = handover?.startedAt ?? Date()
        if handover == nil {
            lifecycle.recordStart(pid: pid, session: UsageLog.currentSession, root: rootOptions.directory.path, parent: spawnedBy)
        } else {
            lifecycle.recordReexec(pid: pid, startedAt: startedAt)
        }

        // One stop per start and one exit per stop, whichever path gets there — both watches below share this
        // one claim, because two dispatch sources on one queue can enter their handlers at the same instant
        // (``SiftMCP/ServerEnding``).
        let ending = ServerEnding(record: { stop in
            lifecycle.recordStop(pid: pid, reason: stop, startedAt: startedAt)
        })

        // Armed before the server runs, not after: the window this is here to cover is the whole life of the
        // process, and a signal arriving during a long first index build is as worth recording as any other.
        // `128 + n` is the shell's own spelling for "ended by signal n", so an exit status read from a wrapper
        // agrees with the log line.
        let signals = ServerSignalWatch.arm { number in
            ending.end(.signalled(number: number), status: 128 + number)
        }

        // Armed in the same window and for the same reason (``SiftMCP/ServerParentWatch``): the process that
        // spawned this one going away is the only orphan signal that carries no policy with it, and a server
        // holding an index open for a client that no longer exists is exactly the orphan to end. Exits 0 — the work
        // ended because there is nobody left to do it for, which is not a failure of this process.
        // A parent that died since it was read is caught by the watch's own second reading, straight after arming.
        let parent = ServerParentWatch.arm(parent: spawnedBy) { parentPid in
            ending.end(.parentExited(pid: parentPid), status: 0)
        }

        let binary = BinaryIdentity.executablePath
        let registry = RootsRegistry.standard()
        // Read once, with the primer's own predicate: the tools load up front when either the directory the session
        // started in or an explicitly passed `--root` has Swift in view, and stay deferred when neither does.
        let loadUpFront = MCPToolCatalog.loadsUpFront(
            sessionIn: FileManager.default.currentDirectoryPath,
            root: rootOptions.directory.path,
            knownRoots: registry.knownRoots()
        )
        let server = MCPServer(
            input: FileHandle.standardInput,
            output: FileHandle.standardOutput,
            defaultRoot: rootOptions.directory,
            log: { StandardStreams.emitError($0) },
            usage: .standard(note: { StandardStreams.emitError($0) }),
            registry: registry,
            binaryPath: binary,
            resuming: handover?.session,
            reexec: ServerReexec(
                path: binary,
                arguments: CommandLine.arguments,
                startedAt: startedAt,
                parent: spawnedBy,
                ending: ending
            ),
            loadToolsUpFront: loadUpFront
        )
        let stop = await server.run()
        withExtendedLifetime((signals, parent)) {
            ending.record(stop)
        }
    }
}
