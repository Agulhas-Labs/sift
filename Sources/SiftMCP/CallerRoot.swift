//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore

/// The repository an index call has to be answered from: the one the *caller* is standing in, rather than the one the server happened to be launched in.
///
/// **The failure this exists to close is a wrong answer, not a missing one.** The MCP server binds its root to its own launch directory, and a subagent shares its parent's server — so a subagent working in `…/worktrees/agent-1a2b3c4d` and asking for a digest would be served the *parent checkout's* file, line ranges and dirty count, with nothing in the answer to say so. Nothing about the content gives it away either: a worktree and its checkout share `head:` and hold the same symbol names, so the only thing that can tell them apart is the path. The cross-root self-heal in ``SiftCore/RootResolver`` never fires here, because it is triggered by a symbol being *absent*, which between a checkout and its own worktree never happens.
///
/// Every tool this server exposes already takes `root:`. The caller simply has no way to know it must pass one — nothing in a subagent's context says which directory a server it did not start is rooted in. The `PreToolUse` payload does know: it carries the caller's own `cwd`. So the hook fills in what the caller could not have said.
///
/// **Supplied rather than refused**, which is the one place this departs from `Docs/AnswerContract.md` §5. §5 governs an answer that *cannot be given honestly* — a stale store, an ambiguous target — and refuses instead of guessing. This is neither: the caller's working directory is a fact in the payload, `git rev-parse --show-toplevel` resolves it to exactly one root, and there is nothing to guess. A refusal would end with the caller re-sending the argument this could have added. An explicit `root:` still wins, whether it is the argument or a term written inside a search query, so a caller that really means the other tree keeps it.
///
/// **Left alone where it cannot change the answer.** Claude Code's auto mode judges a call the hook rewrites as a new call, and has refused some of those for want of a verdict, so an amendment is not free: it is sent only where it can make a difference. Where the server runs is not inferred: every server records its launch directory and the process that spawned it in the server lifecycle log, and the harness that spawned the server also runs the hook, so the hook looks up the newest live server spawned by its own closest ancestor (``serverDirectory(session:environment:)``). A caller whose root is the tree that server answers a rootless call from is already answered from the right tree and is left untouched, in a linked worktree as much as a main checkout. Every case this cannot settle — no live server spawned by any ancestor, a log that cannot be read, a directory in no repository — amends as before.
public struct CallerRoot {
    /// The tool input this call should run with, or `nil` when there is nothing to correct.
    ///
    /// Silent in every uncertain case, and that is the safe direction: a `PreToolUse` hook that prints nothing leaves the call exactly as it was. A caller sitting above its repositories (a session opened in a folder of checkouts) resolves to no root at all and is left to ``SiftCore/RootResolver``, which heals that case properly and would only be hobbled by a root pinned to a directory holding ten of them.
    ///
    /// `serverDirectory` is where the server lifecycle log says the live server answering this caller was launched, or `nil` where it does not say; a call the server already answers from its caller's own tree is left alone (``serves(callerRoot:from:)``).
    public static func amendment(toolName: String?, input: [String: Any], cwd: String?, serverDirectory: String? = nil) -> [String: Any]? {
        guard let toolName, IndexToolName.tool(named: toolName) != nil else { return nil }
        // An empty input is not a call to amend, and the case that matters is not a caller who sent one:
        // it is a payload whose `tool_input` was absent, or present in a shape the caller of this could not
        // read, which arrives here as `[:]` either way. Every tool of this server's takes a required
        // argument, so amending that produces `{root: …}` — a complete replacement for the call, with the
        // target dropped. Silence is the design property this hook holds to: every failure leaves the call
        // exactly as it was.
        guard !input.isEmpty else { return nil }
        // An explicit root wins, whether sent as the argument or written inline in a search query. It is the
        // caller saying which tree it means, and this knows less than it does.
        if statedRoot(toolName: toolName, input: input) != nil {
            return nil
        }
        guard let root = root(forCallerIn: cwd), !serves(callerRoot: root, from: serverDirectory) else { return nil }
        var amended = input
        amended["root"] = root
        return amended
    }

    /// The root a call names itself, or `nil` when it names none.
    ///
    /// The non-empty `root` argument, else for `search` the last non-empty inline `root:` term of its query: exactly the root the server answers from, with the same precedence, so the argument beats the inline term. The hook reads a call's root through this wherever it needs one, so an inline term counts as explicit everywhere.
    public static func statedRoot(toolName: String?, input: [String: Any]) -> String? {
        if let stated = input["root"] as? String, !stated.isEmpty {
            return stated
        }
        guard let toolName, IndexToolName.tool(named: toolName) == "search", let query = input["query"] as? String else { return nil }
        return InlineRootLift(query: query).root
    }

    /// The repository root enclosing `cwd`, or `nil` when there is none to name.
    ///
    /// `--show-toplevel` and not `--git-common-dir`: in a linked worktree the common directory names the repository the worktree was cut from, which is the tree this whole type exists to stop answering from. The top level is the worktree itself, which is where the caller actually is.
    public static func root(forCallerIn cwd: String?) -> String? {
        guard let cwd, !cwd.isEmpty else { return nil }
        // Where git cannot answer in time, the root is still the root: a `git` that a loaded machine did not finish
        // within ``ChildDeadline/git`` would otherwise leave an offer pinned to no repository, which never matches
        // the call noted under the repository it was made in, and the ledger's verdict on a lookup would depend on
        // how busy the machine was. The walk spells the root as git does, so both sides of that match agree. A path
        // that is no directory — a file, which names no repository itself — or is gone has no root either way.
        if let root = GitContext.discoverRoot(from: URL(fileURLWithPath: cwd))?.path {
            return root
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cwd, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        return SessionPrimer.enclosingRepository(of: cwd).map(CanonicalPath.of)
    }

    /// Whether a server started in `serverDirectory` already answers a call with no root from `callerRoot`, so that naming the root changes nothing.
    ///
    /// The server resolves a call with no root from its launch directory through the same git top level, so the two agree exactly when both directories resolve to one root, a linked worktree's as much as a main checkout's. Every case this cannot settle — no directory, a relative one, one in no repository, a git that does not answer — reads as not served, which keeps the amendment.
    static func serves(callerRoot: String, from serverDirectory: String?) -> Bool {
        guard let serverDirectory, serverDirectory.hasPrefix("/"),
              let serverRoot = GitContext.discoverRoot(from: URL(fileURLWithPath: serverDirectory)) else { return false }
        return CanonicalPath.of(serverRoot.path) == CanonicalPath.of(callerRoot)
    }
}

extension CallerRoot {
    /// How many of the hook's ancestors are asked for a server at most, closest first.
    ///
    /// The harness that spawned the server runs the hook as its child, or as a shell's child where it runs it under one, so it sits one or two levels up; four leaves room for shells nested under it. The walk ends sooner, with the first ancestor that is no shell (``ancestors(of:depth:parent:name:)``), so the depth bounds a chain of shells and never reaches past the harness.
    static let ancestryDepth = 4

    /// The kernel names of the shells the ancestry walk passes through: a hook command runs under one, and nothing else stands between a hook and the harness running it.
    ///
    /// Compared exactly with the kernel's name, which is the executable's file name: macOS's `/bin/sh` is named `bash`.
    static let shells: Set<String> = ["sh", "bash", "zsh", "dash", "ksh", "mksh", "fish", "tcsh", "csh"]

    /// The directory the live server answering this hook's caller was launched in, as the server lifecycle log records it, or `nil` where the log cannot say.
    ///
    /// Read rather than inferred, and found by process ancestry rather than by the session: every server records the process that spawned it, and the harness that spawned it also runs this hook, so that process is one of the hook's own ancestors. The ancestry asked ends with the first process that is no shell, the harness running the hook: a harness started from another harness's Bash tool with no server of its own on record leaves the call amended, rather than taking the outer harness's server. The session alone names no server: after `/clear` the conversation carries a new session id while its server's line keeps the old one, and a `sift mcp` started from a shell inherits the session while another server answers. `session` is read only for a start line written before servers recorded their parent. Read once per index call, from the file `SIFT_SERVER_LOG` or `SIFT_HOME` names where either is set.
    public static func serverDirectory(session: String?, environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        let entries = ServerLifecycleReport.entries(in: ServerLifecycleLog.standardFileURL(environment: environment))
        return serverDirectory(ancestors: ancestors(of: getpid()), session: session, among: entries)
    }

    /// The ancestors of `pid`, closest first: at most `depth` of them, ending before pid 1, after a process whose parent cannot be read, at a repeat, and with the first that is no shell.
    ///
    /// That last stop is inclusive. The first ancestor that is no shell is the harness running the hook, which is asked for a server of its own, and nothing past it is: past it lies the shell of whatever started the harness, and a harness started from another harness's Bash tool would find the outer harness's server there. A process `name` cannot name counts as no shell, so the walk ends with it.
    static func ancestors(
        of pid: Int32,
        depth: Int = ancestryDepth,
        parent: (Int32) -> Int32? = ServerLifecycleReport.parent(of:),
        name: (Int32) -> String? = KernelProcess.name(of:)
    ) -> [Int32] {
        var chain: [Int32] = []
        var current = pid
        while chain.count < depth, let next = parent(current), next > 1, next != pid, !chain.contains(next) {
            chain.append(next)
            guard shells.contains(name(next) ?? "") else { break }
            current = next
        }
        return chain
    }

    /// The launch directory of the newest live server spawned by the closest of `ancestors` that spawned one; where none did, that of the newest live server under `session` whose line names no parent.
    ///
    /// Where that ancestor's live servers record different launch directories, `nil`: a `sift mcp` a shell runs by `exec` records the harness as its parent too, as does a second registration with a root of its own, and nothing in the log says which of them answers this call. Closest first, so a harness started from another harness's shell finds its own server before the outer one's, and where it has none the outer one is never among `ancestors`, which end with the inner harness. Pid 1 is never an ancestor that counts: every process descends from it, and a server with no parent worth watching records `1`. The session fallback is closed to any line that names a parent, since a parent that is not one of the hook's ancestors is exactly a server some other process started, which is not the one answering this call. Liveness is asked newest first and only of candidates, since each check is a kernel read.
    static func serverDirectory(
        ancestors: [Int32],
        session: String?,
        among entries: [ServerLifecycleEntry],
        isRunning: (ServerLifecycleEntry) -> Bool = isServing
    ) -> String? {
        let starts = entries.reversed().filter { $0.event == "start" && $0.root != nil }
        for ancestor in ancestors where ancestor > 1 {
            let live = starts.filter { $0.parent == ancestor && isRunning($0) }
            if let newest = live.first {
                return live.allSatisfy { $0.root == newest.root } ? newest.root : nil
            }
        }
        guard let session, !session.isEmpty else { return nil }
        return starts.first { $0.parent == nil && $0.session == session && isRunning($0) }?.root
    }

    /// Whether the server a start line records is still the process that wrote it and still the child of the parent it named.
    ///
    /// The second half keeps a reused pid out: a server orphaned by its parent's end, if one ever outlives its watch, names a parent pid the kernel may since have handed to one of the hook's ancestors.
    static func isServing(_ entry: ServerLifecycleEntry) -> Bool {
        guard ServerLifecycleReport.isStillRunning(entry) else { return false }
        guard let parent = entry.parent else { return true }
        return ServerLifecycleReport.parent(of: entry.pid) == parent
    }
}
