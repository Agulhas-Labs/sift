//
// Copyright © Agulhas Labs
//

import Foundation

/// Registers the `SessionStart` hook in a Claude Code `settings.json`, as a pure transform over the file's bytes.
///
/// Deliberately not shell: `settings.json` configures the whole tool, it is shared with hooks this project does not own, and a corrupt write breaks every session on the machine. Doing the merge in the binary means one artifact to ship, no dependency on `python3` or `jq` being present on the machine it lands on, and merge rules covered by the test suite rather than by hoping `sed` held.
public struct HookRegistration {
    /// The session-start hook's own matchers.
    ///
    /// `clear` and `compact` earn their place alongside `startup` and `resume` for the same reason: each discards the context, which discards the primer with it, and the session goes on to do exactly the Swift work the primer exists for. A compaction is the one of the two nobody asks for — it arrives mid-task, and the primer survives it only if the summary happens to keep it.
    public static var defaultMatchers: [String] {
        ["startup", "resume", "clear", "compact"]
    }

    /// Every event this registers for, the subcommand each one runs, and the matchers each one needs.
    ///
    /// `SubagentStart` is here because a `SessionStart` hook does not fire for subagents and the path-scoped rule does not reach them either, which would leave the contexts doing the heaviest whole-file reading as the only ones getting no guidance at all. It takes no matcher: there is nothing to match on, and an entry without the key fires for every subagent.
    ///
    /// `PreToolUse` is a different job by a different command, which is why this is keyed on the subcommand rather than assuming one. Its matcher names every tool that can read Swift source, because a `PreToolUse` hook without a matcher runs on *every* tool call, which is a per-call cost paid on things it would never have an opinion about.
    ///
    /// The Xcode server's tools are spelled out because **matchers are anchored, not substring** — verified empirically: a matcher of `ash` does not fire for `Bash`. So `Read` would never have caught `mcp__xcode__XcodeRead`, which reads a file with the same arguments under a different name. Closing `Bash` and leaving that open teaches a detour rather than a habit, which is the same reason `Grep` and `Glob` are here at all.
    ///
    /// **This server's own tools are the exception to "every tool that can read Swift source", and they are here to be observed rather than judged.** The advice quiets itself when a run of it draws no index call, and an index call read off the modification time of two log files is machine-wide — a log line carries no conversation identity, so a parent's calls would clear its subagents' runs and the rule would never fire for the contexts it was written for. A hook payload *does* name the conversation. Firing on `mcp__sift__…` is what lets the ledger see a call and the context that made it at the same moment; the hook has no opinion about one and returns having only written it down. It is `.*` rather than the four names because a tool added to the server must not be able to become invisible here by being added, and the cost of the widest possible reading is one 7 ms hook run per index call.
    ///
    /// **A write or an edit is here to be observed too.** Either one puts the file's text in the context that made it, so a later read of that file is a revisit, and without seeing the call the hook would answer the read with a digest of a file the context has just written. The cost is one hook run per write or edit.
    ///
    /// **`PostToolUse` is the other side of the same edit — a nudge rather than an answer.** Once a `Write`, `Edit` or `MultiEdit` has already landed, there is nothing left to intercept; what a hook can still do is look at what the edit added and say, once, if it resembles something that already exists. **It also reads the answer of a `digest`** (an MCP call or a Bash `sift digest`): the `PreToolUse` note of one is made before any answer exists, and a digest that resolved nothing takes its note back here, so it excuses no later window. Its own timeout is shorter than the others' because it runs after the tool already ran, on the critical path of nothing — a slow or hung nudge is worth abandoning quickly rather than worth waiting on.
    ///
    /// **`Stop` and `SubagentStop` are the end of the same work — a gate rather than a nudge.** A context that edited Swift and is about to report done on a tree nothing has built is sent back once to build it; one command serves both, reading which event fired from its payload, and neither takes a matcher.
    public static var events: [Event] {
        [
            Event(name: "SessionStart", subcommand: "session-start", matchers: defaultMatchers, timeout: 5),
            Event(name: "SubagentStart", subcommand: "session-start", matchers: [], timeout: 5),
            Event(
                name: "PreToolUse",
                subcommand: "pre-tool-use",
                matchers: ["Bash|Read|Grep|Glob|mcp__xcode__Xcode(Read|Grep|Glob)|mcp__sift__.*|Write|Edit|MultiEdit"],
                timeout: 5
            ),
            Event(
                name: "PostToolUse",
                subcommand: "post-tool-use",
                matchers: ["Write|Edit|MultiEdit|mcp__sift__digest"],
                timeout: 3
            ),
            Event(name: "Stop", subcommand: "stop", matchers: [], timeout: 5),
            Event(name: "SubagentStop", subcommand: "stop", matchers: [], timeout: 5),
        ]
    }

    /// A fingerprint of everything this binary registers — every event, the subcommand it runs, and the matchers it needs.
    ///
    /// Compared against ``fingerprint(of:)`` of a settings file (``RegisteredHooks``) so that a binary can tell whether the registration firing into it is its own. Derived from ``events`` rather than being a version number for the reason a version number is a bad instrument here: it has to be remembered, and a change like widening the `PreToolUse` matcher to cover this server's own tools is exactly the kind that gets made without anyone thinking about a stamp. A fingerprint makes every settings file already on disk stale by construction the moment `events` changes.
    ///
    public static var fingerprint: String {
        fingerprint(events)
    }

    /// The same fingerprint of everything *except* the advice hook — what a settings file holds after `uninstall-hook --only-advice`.
    ///
    /// **A partial uninstall is a decision, not a discrepancy, and it needs a name because it does not compare equal to ``fingerprint``.** It should not: the advice hook really is gone, and ``RegisteredHooks/isCurrent`` is right to answer `false`. What must not follow is the wrong sentence built on that answer — someone who ran the documented command being told their settings belong to a different version and that the cure is the one command that puts back what they had just removed.
    ///
    /// Derived by removing exactly what the flag removes (``eventsToRemove(onlyAdvice:)``) rather than by naming the events that survive it, so an event added to ``events`` is covered here without anyone remembering that this exists.
    public static var fingerprintWithoutAdvice: String {
        let advice = eventsToRemove(onlyAdvice: true)
        return fingerprint(events.filter { !advice.contains($0) })
    }

    /// A set of this binary's events reduced to one comparable value — the only place the ordering and the join are decided, so the two properties above cannot spell the same identity differently.
    ///
    /// Sorted, so the order the events happen to be written in is not part of the identity. Joined on newlines because the value is compared and never parsed, and a matcher is a regex that may hold any punctuation a separator could be mistaken for.
    private static func fingerprint(_ events: [Event]) -> String {
        events
            .map { line(event: $0.name, subcommand: $0.subcommand, matchers: $0.matchers) }
            .sorted()
            .joined(separator: "\n\n")
    }

    /// The same fingerprint, taken of what a settings file *actually* registers for this tool — empty when it registers nothing.
    ///
    /// **The half that makes the comparison mean anything.** A fingerprint of ``events`` alone describes what this binary *would* write, which is a fact about the binary and not about the machine: it answers `true` for a `settings.json` that was hand-narrowed after the install, for one an install into a different file never touched, and for one an older binary wrote and a newer one was recorded over. Every one of those is a hook that may not fire where the advice assumes it does. Read back, there is nothing left to be wrong about: the file says what it says.
    ///
    /// Read from the file rather than remembered because the file is the thing that decides, and read at the moment of asking — by `status`, which is off the hook's path.
    ///
    /// Built from what is registered rather than from ``events``, so an entry this binary would not write is seen: a duplicate registration under a second matcher, an event a previous version registered and this one does not. Anything it cannot read is skipped rather than refused — this is a check, not a merge, and the safe answer to "I could not read that" is a fingerprint that fails to match.
    ///
    /// **What it still cannot see is whether the registered command runs.** A registration naming a binary that has since been deleted or replaced fingerprints identically to one that works, and this reports it as current. That is the one gap left in the gate, and it is narrower than the one it replaces: the command is matched by shape at any path (``isOurs(_:subcommand:)``) precisely because the binary is expected to move.
    public static func fingerprint(of data: Data?) -> String {
        guard let settings = try? parse(data), let hooks = settings["hooks"] as? [String: Any] else {
            return ""
        }
        let subcommands = Set(events.map(\.subcommand))
        // event → subcommand → the matchers that event registers that subcommand against. Two levels
        // because both are part of the identity and neither alone identifies a registration: one event
        // can run two subcommands, and one subcommand can be registered for two events.
        var found: [String: [String: [String]]] = [:]
        for (event, value) in hooks {
            for element in value as? [Any] ?? [] {
                guard let entry = element as? [String: Any] else { continue }
                // Absent is how an event with no matcher concept is written, and it is a matcher list of
                // none rather than a missing one — the same reading `apply` writes with.
                let matcher = entry["matcher"] as? String
                for hook in entry["hooks"] as? [Any] ?? [] {
                    let command = (hook as? [String: Any])?["command"] as? String
                    for subcommand in subcommands where isOurs(command, subcommand: subcommand) {
                        var matchers = found[event]?[subcommand] ?? []
                        if let matcher {
                            matchers.append(matcher)
                        }
                        found[event, default: [:]][subcommand] = matchers
                    }
                }
            }
        }
        return found
            .flatMap { event, bySubcommand in
                bySubcommand.map { line(event: event, subcommand: $0.key, matchers: $0.value) }
            }
            .sorted()
            .joined(separator: "\n\n")
    }

    /// One registration reduced to a fingerprint line: the event, the subcommand it runs, and the matchers it fires on.
    ///
    /// Matchers sorted for the same reason the lines are. The order they are listed in is not part of what is registered, and the two sides of the comparison are written by different things — one by ``events``, the other by whatever last wrote the settings file.
    private static func line(event: String, subcommand: String, matchers: [String]) -> String {
        ([event, subcommand] + matchers.sorted()).joined(separator: "\n")
    }

    /// Merges the hook into `data` (nil or empty meaning "no settings file yet"), leaving everything else untouched.
    ///
    /// Every array is walked as `[Any]` and judged element by element, for a reason that costs more here than it does in `remove`. Casting a whole array to `[[String: Any]]` fails outright on one element of an unexpected shape; a `?? []` fallback would then hand the merge an *empty* array to build on, and writing that back would delete every hook the event already had — silently, on a file this tool did not author. So anything unreadable is carried through verbatim, and a container of the wrong shape entirely is refused rather than replaced.
    public static func apply(
        to data: Data?,
        command: String,
        event: String = "SessionStart",
        subcommand: String = "session-start",
        matchers: [String] = defaultMatchers,
        timeout: Int = 5
    ) throws -> Result {
        var settings = try parse(data)
        var hooks = try object(settings["hooks"], key: "hooks")
        var registered = try array(hooks[event], key: event)
        var changed = false
        var replaced: [String] = []

        // A matcher is part of the registration, not a key it can be looked up by. Widening `Bash|Read` to
        // `Bash|Read|Grep` finds no entry to update, appends a second one, and the hook then runs *twice* on
        // every Bash call — the same duplicate-registration bug as a moved binary, wearing different clothes.
        // So drop ourselves from every entry this install is not about to write to, before writing any.
        let wanted = Set(matchers.isEmpty ? [nil] : matchers.map(Optional.init))
        for index in registered.indices.reversed() {
            guard let entry = registered[index] as? [String: Any],
                  !wanted.contains(entry["matcher"] as? String)
            else { continue }

            var kept: [Any] = []
            var tookSomething = false
            for hook in try array(entry["hooks"], key: "\(event) hooks") {
                guard let ours = hook as? [String: Any],
                      isOurs(ours["command"] as? String, subcommand: subcommand)
                else {
                    kept.append(hook)
                    continue
                }
                tookSomething = true
            }

            guard tookSomething else { continue }
            changed = true
            if kept.isEmpty {
                registered.remove(at: index)
            } else {
                var trimmed = entry
                trimmed["hooks"] = kept
                registered[index] = trimmed
            }
        }

        // No matchers means one entry that matches everything, which is how an event without a matcher
        // concept is written: the key is simply absent.
        for matcher in matchers.isEmpty ? [nil] : matchers.map(Optional.init) {
            let ours: [String: Any] = ["type": "command", "command": command, "timeout": timeout]

            // Both halves check the element is a dictionary, and the second is the one that has to.
            // `($0 as? [String: Any])?["matcher"] as? String` is nil for a stray element *and* for the
            // matcher-less entry `SubagentStart` legitimately uses, so on that event the lookup alone
            // would select the first stray it met; the re-bind below then fails and appends a fresh entry
            // instead of merging into it. The predicate's own check keeps the search honest — it looks for
            // an entry, not for anything whose absent matcher reads as a match.
            let match = registered.indices.first { index in
                guard let entry = registered[index] as? [String: Any] else { return false }
                return entry["matcher"] as? String == matcher
            }
            guard let index = match, var entry = registered[index] as? [String: Any] else {
                var fresh: [String: Any] = ["hooks": [ours]]
                if let matcher {
                    fresh["matcher"] = matcher
                }
                registered.append(fresh)
                changed = true
                continue
            }

            var inner = try array(entry["hooks"], key: "\(event) hooks")

            // Identify a previous install by shape, not by exact path: the whole point of re-running the
            // installer is that the binary may have moved, and matching on the old path would leave the
            // stale registration in place beside the new one.
            let existing = inner.firstIndex { hook in
                guard let hook = hook as? [String: Any] else { return false }
                return isOurs(hook["command"] as? String, subcommand: subcommand)
            }
            if let existing {
                let previous = (inner[existing] as? [String: Any])?["command"] as? String ?? ""
                guard previous != command else { continue }
                // Distinct, not per-matcher: one moved binary is one fact to report, not three.
                if !replaced.contains(previous) {
                    replaced.append(previous)
                }
                inner[existing] = ours
            } else {
                inner.append(ours)
            }

            entry["hooks"] = inner
            registered[index] = entry
            changed = true
        }

        guard changed else {
            return Result(data: data ?? Data(), changed: false, replaced: [])
        }

        hooks[event] = registered
        settings["hooks"] = hooks
        let encoded = try JSONSerialization.data(
            withJSONObject: settings,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        return Result(data: encoded, changed: true, replaced: replaced)
    }

    /// The events an uninstall covers, narrowed to the shell advice when only that is being removed.
    ///
    /// Named here rather than filtered at the call site so what `--only-advice` means is one fact the test suite can pin, instead of a predicate living in a command that has no tests of its own.
    public static func eventsToRemove(onlyAdvice: Bool) -> [Event] {
        onlyAdvice ? events.filter { $0.subcommand == "pre-tool-use" } : events
    }

    /// Removes this tool's registration for one event, leaving every hook it did not write untouched.
    ///
    /// The exact inverse of `apply`, and it has to be as careful: `settings.json` is shared with hooks this project does not own, so a foreign entry in the same event array survives, and so does a foreign hook sitting beside ours inside one entry. Removal prunes what it empties — an entry that existed only for us, an event array left with nothing in it, and the `hooks` object itself — because a file that accumulates `"SessionStart": []` husks is one an uninstall did not really finish.
    ///
    /// Reports the commands it took out rather than a bare flag: an uninstaller that cannot say which registration it found is asking to be trusted about the one thing worth checking.
    ///
    /// Every array is walked as `[Any]` and judged element by element. Casting a whole array to `[[String: Any]]` fails outright on one element of an unexpected shape, and the failure is silent: the removal would find nothing, report nothing registered, and leave the registration in place. Anything this cannot read is carried through verbatim — it is certainly not something this tool wrote.
    ///
    /// It reads its two containers through the same ``object(_:key:)`` and ``array(_:key:)`` that `apply` does, so an unreadable one refuses here exactly as it does there. The distinction they draw is the whole point: absent means nothing is registered, and *present but the wrong shape* means this could not tell — reporting "nothing registered" for the second is the one answer an uninstaller must never give, since it is indistinguishable from a clean sweep over a registration that is still sitting in the file.
    public static func remove(
        from data: Data?,
        event: String = "SessionStart",
        subcommand: String = "session-start"
    ) throws -> Removal {
        var settings = try parse(data)
        var hooks = try object(settings["hooks"], key: "hooks")
        let registered = try array(hooks[event], key: event)
        guard !registered.isEmpty else {
            return Removal(data: data ?? Data(), removed: [])
        }

        var kept: [Any] = []
        var removed: [String] = []
        for element in registered {
            guard let entry = element as? [String: Any] else {
                kept.append(element)
                continue
            }

            var survivors: [Any] = []
            var tookSomething = false
            for hook in entry["hooks"] as? [Any] ?? [] {
                guard let ours = hook as? [String: Any],
                      isOurs(ours["command"] as? String, subcommand: subcommand)
                else {
                    survivors.append(hook)
                    continue
                }
                tookSomething = true
                // Distinct: one binary registered against three matchers is one thing removed, not three.
                let command = ours["command"] as? String ?? ""
                if !removed.contains(command) {
                    removed.append(command)
                }
            }

            guard tookSomething else {
                kept.append(entry)
                continue
            }
            guard !survivors.isEmpty else { continue }
            var trimmed = entry
            trimmed["hooks"] = survivors
            kept.append(trimmed)
        }

        guard !removed.isEmpty else {
            return Removal(data: data ?? Data(), removed: [])
        }

        if kept.isEmpty {
            hooks.removeValue(forKey: event)
        } else {
            hooks[event] = kept
        }
        if hooks.isEmpty {
            settings.removeValue(forKey: "hooks")
        } else {
            settings["hooks"] = hooks
        }
        let encoded = try JSONSerialization.data(
            withJSONObject: settings,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        return Removal(data: encoded, removed: removed)
    }

    /// Whether a registered command is this subcommand's sift hook, at any path.
    ///
    /// Matched on shape rather than exact path — the whole point of re-running the installer is that the binary may have moved — and on the subcommand as well as the binary, so the two hooks this registers can never be mistaken for one another and repointed onto the same event. The shape is exact (``SiftPaths/runsThisTool(_:subcommand:)``): an executable named `sift` running this subcommand alone, so a foreign hook whose path merely contains the name is left to its owner by both the install and the uninstall.
    public static func isOurs(_ command: String?, subcommand: String = "session-start") -> Bool {
        guard let command else { return false }
        return SiftPaths.runsThisTool(command, subcommand: subcommand)
    }

    private static func parse(_ data: Data?) throws -> [String: Any] {
        guard let data, !data.isEmpty else { return [:] }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HookRegistrationError.settingsNotAnObject
        }
        return object
    }

    /// Reads a container that a merge is about to build on, refusing anything it would have to replace.
    ///
    /// Absent is the ordinary case and means "start from empty". Present but the wrong shape is the case that must not silently become empty: whatever is there is someone's configuration, and a merge that treats it as nothing writes over it. This is the whole difference between a missing key and an unreadable one, and conflating them is how a stray array element costs an event every hook it has.
    private static func object(_ value: Any?, key: String) throws -> [String: Any] {
        guard let value else { return [:] }
        guard let object = value as? [String: Any] else {
            throw HookRegistrationError.hooksNotMergeable(key: key)
        }
        return object
    }

    private static func array(_ value: Any?, key: String) throws -> [Any] {
        guard let value else { return [] }
        guard let array = value as? [Any] else {
            throw HookRegistrationError.hooksNotMergeable(key: key)
        }
        return array
    }
}

public extension HookRegistration {
    /// One hook event, the subcommand it runs, and what it matches on.
    struct Event: Equatable, Sendable {
        public let name: String
        public let subcommand: String
        /// Empty for an event with no matcher concept, which is written as an entry with no `matcher` key.
        public let matchers: [String]
        /// Seconds Claude Code waits for this hook before moving on; each event picks its own.
        public let timeout: Int
    }

    /// What a removal took out, for an uninstaller that should name the registration it found rather than claim success blandly.
    struct Removal: Equatable, Sendable {
        public let data: Data
        /// The commands removed, distinct; empty means this event carried no registration of ours and `data` is the input unchanged.
        public let removed: [String]
    }

    /// The outcome of a merge, for an installer that should say what it did rather than claim success blandly.
    struct Result: Equatable, Sendable {
        public let data: Data
        /// False when the file already had exactly this registration — the re-run and upgrade case.
        public let changed: Bool
        /// Commands this replaced, i.e. a previous install at a different path.
        public let replaced: [String]
    }
}
