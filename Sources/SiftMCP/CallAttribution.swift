//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore

/// Which context made an index call, carried from the hook that saw it to the server that logs it.
///
/// **The server cannot know this on its own, and that is the whole difficulty.** A subagent shares its parent's MCP server, `tools/call` carries nothing that names the caller, and the only conversation identity in the server's environment is `CLAUDE_CODE_SESSION_ID` — which a subagent's calls arrive under exactly as its parent's do. So on its own the server attributes every logged call to a session and none to an agent, and the tool cannot evidence the criterion it is judged on: whether it works for subagents.
///
/// The `PreToolUse` hook *does* know — its payload names `agent_id` — and it fires on this server's own tools. It fires immediately before the call, and the server logs immediately after it, so the hook leaves a slip and the server picks it up.
///
/// **One slip per call, not per session, and a slip is claimed only by a call of the shape it names.** It records the tool and the target as well as the agent, and the server takes the oldest unexpired slip whose tool and target match what it just answered. Several contexts under one session can have calls in flight at once, and a slip another context's hook run could overwrite would leave the earlier call logged with no agent — invisible to every reader that goes by a line's agent. A parent's call writes a slip too, with no agent on it, so its own call has one to claim.
///
/// **A claim is atomic.** The server reads the slips of its call's shape, then takes one by renaming it to a name of its own, and a rename succeeds for exactly one claimant: two same-shaped calls answered at once never both take one slip, and the one that loses the race moves on to the next slip rather than leaving it behind unclaimed.
///
/// **Shape is not identity, and where two calls share one the attribution can swap.** The tool and target are all there is to match on — nothing in a `tools/call` names the caller, and nothing shared between the hook run and the request could tell two `digest SummaryState` calls apart. So two contexts digesting the same type at once may each be logged under the other's name, and a slip left by a call that never happened — denied at the permission prompt — can be claimed by a later call of the same shape inside the claim window. The figure this supports stays a floor either way — an agent named made a call, and a call unnamed is only "not attributed to a subagent" — which is the claim `usage` and `report` print. A stronger one, that a given line names *that* line's caller, is not available from what the two ends can see, and is not made.
///
/// **A shell short-circuit is the same failure in the CLI's namespace.** `cliLookups(inCommand:)` reads a Bash command's statements without knowing which of them the shell will actually run, so `false && sift where A` files a slip for a lookup that never starts. That slip expires unclaimed after the window above unless an identical lookup from another context lands inside it and claims it instead — the same exposure a denied MCP call has. The alternative — skipping a `sift` statement whenever its predecessor could have failed — trades a rare mis-attribution for a common non-attribution: `cd /work && sift digest X` is the commonest shape a subagent writes, and skipping it leaves the far commoner case, a lookup that *did* run, filing no slip at all.
///
/// Nothing here is load-bearing. Every failure is silent and leaves the log exactly as it would be without this: an entry with no `agent` field, which every reader already handles, because that is what every line written without a hook looks like.
public struct CallAttribution: Sendable {
    /// How long a slip can be claimed for.
    ///
    /// Generous against a slow first call — a cold index build inside the call runs to seconds — and short enough that a hook run whose call never happened (denied at the permission prompt, or interrupted) cannot be picked up by an unrelated call of the same shape much later.
    static let claimWindow: TimeInterval = 120

    private let directory: URL
    private let now: @Sendable () -> Date

    public init(directory: URL, now: @escaping @Sendable () -> Date = { Date() }) {
        self.directory = directory
        self.now = now
    }

    /// Beside the usage log, the run log and the advice ledger — one directory a user can delete to reset everything this tool remembers.
    public static func standard() -> CallAttribution {
        CallAttribution(directory: SiftPaths.callers)
    }

    /// Records who is about to make this call.
    ///
    /// `agent` absent is a fact worth writing, not a reason to skip: it says this call is the session's own, and gives that call a slip of its own to claim rather than one of a subagent's.
    public func note(session: String, agent: String?, tool: String, target: String?) {
        guard let prefix = prefix(for: session) else { return }
        let stamp = now().timeIntervalSince1970
        var entry: [String: Any] = ["tool": tool, "ts": stamp]
        if let target {
            entry["target"] = target
        }
        if let agent, !agent.isEmpty {
            entry["agent"] = agent
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? JSONSerialization.data(withJSONObject: entry) else { return }
        // A name of its own per slip, so no hook run can overwrite another context's slip before it is claimed.
        let name = "\(prefix)\(Int(stamp * 1000))-\(UUID().uuidString.prefix(8)).json"
        try? data.write(to: directory.appendingPathComponent(name), options: .atomic)
        // On every slip written, and the cost of that is stated rather than wished away. The advice ledger's
        // rule — prune only when the write *created* the file, a listing where a write has already been paid
        // for — cannot hold here: every slip is a new file, so "created" would be true every time. What is
        // left is one `contentsOfDirectory` of a directory holding a file per call in flight on the machine —
        // a handful of entries, on a hook run already priced at 7 ms.
        pruneSlips(olderThan: Self.claimWindow)
    }

    /// The agent behind the call just answered, consuming the slip that named it.
    ///
    /// `nil` covers four different situations and deliberately does not distinguish them, because the log's answer is the same in all four: no `agent` field. The hook is not installed; the caller is the session itself; no slip of this call's shape was written; the slip is older than the claim window. A slip is removed when it is claimed, and one past the window when it is found, so none can be claimed twice or be claimed stale; a slip of another shape is left where it is for the call it belongs to.
    public func take(session: String, tool: String, target: String?) -> String? {
        guard let prefix = prefix(for: session) else { return nil }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let moment = now().timeIntervalSince1970
        var candidates: [Slip] = []
        for name in names where name.hasPrefix(prefix) && name.hasSuffix(".json") {
            let url = directory.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url),
                  let entry = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  entry["tool"] as? String == tool,
                  entry["target"] as? String == target
            else { continue }
            guard let stamp = entry["ts"] as? TimeInterval, moment - stamp <= Self.claimWindow else {
                try? FileManager.default.removeItem(at: url)
                continue
            }
            candidates.append(Slip(url: url, stamp: stamp, agent: entry["agent"] as? String))
        }
        // Oldest first: the one whose hook ran first, and so the call answered first — the order a queue of
        // same-shaped calls is served in. A slip another claimant renamed first is gone, and the next is tried.
        for slip in candidates.sorted(by: { $0.stamp < $1.stamp }) {
            let claim = directory.appendingPathComponent("claimed-\(UUID().uuidString)-\(slip.url.lastPathComponent)")
            guard rename(slip.url.path, claim.path) == 0 else { continue }
            try? FileManager.default.removeItem(at: claim)
            return slip.agent
        }
        return nil
    }

    /// Forgets slips too old to be claimed.
    ///
    /// **An unclaimed slip is ordinary, not exceptional.** The server returns before it takes one whenever the call recorded no usage, and a hook run whose call never happened — denied at the permission prompt, interrupted, or a tool this server does not answer for — leaves one behind too. Nothing else removes them, so without this the directory would grow by a file per session and never shrink, which is the shape of leak that gets a tool uninstalled.
    ///
    /// Pruned at the claim window rather than at some longer retention, because ``take(session:tool:target:)`` already refuses anything older than that: a file past it is unclaimable by construction, so this only ever removes what is already dead.
    ///
    /// Run on every slip written rather than once per session — see ``note(session:agent:tool:target:)`` for why the once-per-session rule could not hold and what this costs instead.
    func pruneSlips(olderThan age: TimeInterval) {
        let cutoff = now().addingTimeInterval(-age)
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        for entry in entries where entry.pathExtension == "json" {
            let modified = try? entry.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            guard let modified, modified < cutoff else { continue }
            try? FileManager.default.removeItem(at: entry)
        }
    }

    /// What every slip of a session is named from, the session id and a dot, where the id is a name this tool did not author.
    ///
    /// The id arrives in a hook payload, so it is untrusted input on a path — `nil` for anything that is not plainly a name, rather than a sanitised approximation of one, since two ids that sanitise alike would silently share their slips. The dot closes the id, so one session's prefix is never the start of another's; a slip written by a build that kept one per session, `<session>.json`, carries it too, and is read like any other.
    private func prefix(for session: String) -> String? {
        guard !session.isEmpty, session.count <= 128,
              session.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
        else {
            return nil
        }
        return "\(session)."
    }
}

public extension CallAttribution {
    /// The tool a CLI lookup's slip is filed under — a name no server tool has, so neither face can ever claim a slip the other left.
    ///
    /// **This is what makes attribution safe for the CLI.** A subagent's `sift where Foo` in Bash and an MCP `where Foo` in flight under the same session have the same tool and target; filed under one name, the CLI process could take the server's slip, and the MCP call would be logged under nobody. Filed under the face, each is claimable only by a call of its own face, and the one swap left is the one the server already has: two same-shaped calls of one face at once.
    static var cliFace: String {
        "cli"
    }

    /// Records who is about to run a CLI lookup, named by the words the binary will be started with after its own name.
    func note(session: String, agent: String?, arguments: [String]) {
        note(session: session, agent: agent, tool: Self.cliFace, target: Self.cliTarget(arguments))
    }

    /// The agent behind the CLI lookup started with `arguments`, consuming the slip the hook left for it — `nil` in every situation ``take(session:tool:target:)`` returns it for.
    func take(session: String, arguments: [String]) -> String? {
        take(session: session, tool: Self.cliFace, target: Self.cliTarget(arguments))
    }

    /// The argv joined by a separator no argument typed at a shell carries, so `where "A B"` and `where A B` stay two calls.
    private static func cliTarget(_ arguments: [String]) -> String {
        arguments.joined(separator: "\u{1F}")
    }
}

private extension CallAttribution {
    /// One slip found on disk: where it is, when its hook ran, and the agent it names.
    struct Slip {
        let url: URL
        let stamp: TimeInterval
        let agent: String?
    }
}
