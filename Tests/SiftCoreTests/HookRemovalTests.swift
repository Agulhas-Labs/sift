//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers the uninstall — the merge run backwards, where the risk is the mirror image: not corrupting `settings.json`, but taking out of it something this tool never put there.
struct HookRemovalTests {
    private static func settings(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    private static func object(_ data: Data, sourceLocation: SourceLocation = #_sourceLocation) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: data) as? [String: Any], sourceLocation: sourceLocation)
    }

    private static func hooks(_ data: Data, sourceLocation: SourceLocation = #_sourceLocation) throws -> [String: Any]? {
        try object(data, sourceLocation: sourceLocation)["hooks"] as? [String: Any]
    }

    private static func commands(
        _ data: Data,
        event: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> [String] {
        let entries = try hooks(data, sourceLocation: sourceLocation)?[event] as? [[String: Any]] ?? []
        return entries.flatMap { entry in
            (entry["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String }
        }
    }

    /// A full installation, plus a hook this project did not write sharing the `PreToolUse` event with it, plus a setting that has nothing to do with either.
    private static func installedAlongsideAForeignHook() throws -> Data {
        try settings([
            "theme": "dark",
            "statusLine": ["type": "command", "command": "/bin/sift statusline"],
            "hooks": [
                "SessionStart": [
                    ["matcher": "startup", "hooks": [["type": "command", "command": "/bin/sift session-start"]]],
                    ["matcher": "resume", "hooks": [["type": "command", "command": "/bin/sift session-start"]]],
                ],
                "SubagentStart": [["hooks": [["type": "command", "command": "/bin/sift session-start"]]]],
                "PreToolUse": [
                    [
                        "matcher": "Bash|Read|Grep|Glob|mcp__xcode__Xcode(Read|Grep|Glob)",
                        "hooks": [
                            ["type": "command", "command": "/bin/sift pre-tool-use"],
                            ["type": "command", "command": "~/.claude/hooks/audit-bash.sh"],
                        ],
                    ],
                    ["matcher": "Write", "hooks": [["type": "command", "command": "~/.claude/hooks/protect.sh"]]],
                ],
            ],
        ])
    }

    private static func removingEveryEvent(from data: Data) throws -> (data: Data, removed: [String]) {
        var current = data
        var removed: [String] = []
        for event in HookRegistration.events {
            let removal = try HookRegistration.remove(from: current, event: event.name, subcommand: event.subcommand)
            current = removal.data
            removed.append(contentsOf: removal.removed)
        }
        return (current, removed)
    }

    @Test
    func oursGoesAndTheForeignHookSharingTheEventStays() throws {
        let result = try Self.removingEveryEvent(from: Self.installedAlongsideAForeignHook())

        #expect(try Self.commands(result.data, event: "PreToolUse") == [
            "~/.claude/hooks/audit-bash.sh",
            "~/.claude/hooks/protect.sh",
        ])
        #expect(result.removed.contains("/bin/sift pre-tool-use"))
        #expect(result.removed.contains("/bin/sift session-start"))
    }

    /// Nothing this tool did not register may be disturbed, including keys it has no opinion about at all.
    @Test
    func unrelatedSettingsSurviveTheRemoval() throws {
        let result = try Self.removingEveryEvent(from: Self.installedAlongsideAForeignHook())

        #expect(try Self.object(result.data)["theme"] as? String == "dark")
        let statusLine = try Self.object(result.data)["statusLine"] as? [String: Any]
        #expect(statusLine?["command"] as? String == "/bin/sift statusline")
    }

    /// An event array emptied by the removal is deleted, not left as a `"SessionStart": []` husk that says a hook is configured when none is.
    @Test
    func anEmptiedEventArrayIsPrunedAndSoIsTheEntryThatHeldIt() throws {
        let result = try Self.removingEveryEvent(from: Self.installedAlongsideAForeignHook())
        let hooks = try #require(try Self.hooks(result.data))

        #expect(hooks["SessionStart"] == nil)
        #expect(hooks["SubagentStart"] == nil)
        // The `PreToolUse` entry that held both hooks keeps only the foreign one; ours leaves no empty entry.
        let entries = try #require(hooks["PreToolUse"] as? [[String: Any]])
        #expect(entries.count == 2)
        #expect((entries[0]["hooks"] as? [[String: Any]])?.count == 1)
    }

    /// With the last of our events gone and nothing else registered, the `hooks` object itself goes too.
    @Test
    func anEmptiedHooksObjectIsPruned() throws {
        let installed = try Self.settings([
            "theme": "dark",
            "hooks": [
                "SessionStart": [["matcher": "startup", "hooks": [["type": "command", "command": "/bin/sift session-start"]]]],
            ],
        ])

        let result = try Self.removingEveryEvent(from: installed)

        #expect(try Self.object(result.data)["hooks"] == nil)
        #expect(try Self.object(result.data)["theme"] as? String == "dark")
    }

    /// One binary registered against three matchers is one thing removed, not three lines claiming three registrations.
    @Test
    func theSameCommandAcrossEveryMatcherIsReportedOnce() throws {
        let installed = try HookRegistration.apply(to: nil, command: "/bin/sift session-start")

        let removal = try HookRegistration.remove(from: installed.data)

        #expect(removal.removed == ["/bin/sift session-start"])
    }

    @Test
    func anEventThatCarriesOnlyForeignHooksIsLeftExactlyAsItWas() throws {
        let foreign = try Self.settings([
            "hooks": ["SessionStart": [["matcher": "startup", "hooks": [["type": "command", "command": "~/.claude/hooks/mine.sh"]]]]],
        ])

        let removal = try HookRegistration.remove(from: foreign)

        #expect(removal.removed.isEmpty)
        // Unchanged means the input's own bytes, not a re-serialisation that happens to mean the same.
        #expect(removal.data == foreign)
    }

    /// One element of an unexpected shape makes a whole-array cast fail, and the failure is silent: the removal finds nothing, reports nothing registered, and leaves the hook running.
    @Test
    func aStrayElementBesideARealEntryDoesNotBlindTheRemoval() throws {
        let installed = try Self.settings([
            "hooks": [
                "SessionStart": [
                    "a stray string nothing here wrote",
                    ["matcher": "startup", "hooks": [["type": "command", "command": "/bin/sift session-start"]]],
                ],
            ],
        ])

        let removal = try HookRegistration.remove(from: installed)

        #expect(removal.removed == ["/bin/sift session-start"])
        let entries = try #require(try Self.hooks(removal.data)?["SessionStart"] as? [Any])
        #expect(entries.count == 1)
        #expect(entries.first as? String == "a stray string nothing here wrote")
    }

    /// The same hazard one level down, where junk sits in the array our own hook is in.
    @Test
    func junkBesideOurHookInsideAnEntryIsPreservedWhileOursGoes() throws {
        let installed = try Self.settings([
            "hooks": [
                "PreToolUse": [[
                    "matcher": "Bash",
                    "hooks": [
                        ["type": "command", "command": "/bin/sift pre-tool-use"],
                        42,
                        ["type": "command", "command": "~/.claude/hooks/audit.sh"],
                    ],
                ]],
            ],
        ])

        let removal = try HookRegistration.remove(from: installed, event: "PreToolUse", subcommand: "pre-tool-use")

        #expect(removal.removed == ["/bin/sift pre-tool-use"])
        let entries = try #require(try Self.hooks(removal.data)?["PreToolUse"] as? [Any])
        let inner = try #require((entries.first as? [String: Any])?["hooks"] as? [Any])
        #expect(inner.count == 2)
        #expect(inner.first as? Int == 42)
        #expect((inner.last as? [String: Any])?["command"] as? String == "~/.claude/hooks/audit.sh")
    }

    @Test
    func aSecondRunFindsNothingLeftToRemove() throws {
        let first = try Self.removingEveryEvent(from: Self.installedAlongsideAForeignHook())

        let second = try Self.removingEveryEvent(from: first.data)

        #expect(second.removed.isEmpty)
        #expect(second.data == first.data)
    }

    @Test
    func anAbsentSettingsFileHasNothingRegistered() throws {
        let removal = try HookRegistration.remove(from: nil)

        #expect(removal.removed.isEmpty)
        #expect(removal.data.isEmpty)
    }

    @Test
    func unreadableSettingsStopTheRemovalRatherThanBeingRewritten() {
        let notAnObject = Data("[1, 2, 3]".utf8)

        #expect(throws: HookRegistrationError.self) {
            try HookRegistration.remove(from: notAnObject)
        }
    }

    // MARK: - `--only-advice`

    /// The switch for someone who wants the nudges gone after a week and the rest kept.
    @Test
    func onlyAdviceNarrowsTheRemovalToThePreToolUseHook() {
        let events = HookRegistration.eventsToRemove(onlyAdvice: true)

        #expect(events.map(\.name) == ["PreToolUse"])
        #expect(HookRegistration.eventsToRemove(onlyAdvice: false) == HookRegistration.events)
    }

    @Test
    func onlyAdviceLeavesThePrimerRegistered() throws {
        var current = try Self.installedAlongsideAForeignHook()
        for event in HookRegistration.eventsToRemove(onlyAdvice: true) {
            current = try HookRegistration.remove(from: current, event: event.name, subcommand: event.subcommand).data
        }

        #expect(try Self.commands(current, event: "PreToolUse") == [
            "~/.claude/hooks/audit-bash.sh",
            "~/.claude/hooks/protect.sh",
        ])
        #expect(try Self.commands(current, event: "SessionStart") == [
            "/bin/sift session-start",
            "/bin/sift session-start",
        ])
        #expect(try Self.commands(current, event: "SubagentStart") == ["/bin/sift session-start"])
        // The status line is the half `--only-advice` exists to keep.
        #expect(try StatuslineRegistration.remove(from: current) != .absent)
    }

    // MARK: - Status line

    @Test
    func ourStatusLineIsRemovedAtAnyPath() throws {
        let command = "/anywhere/sift statusline"
        let existing = try Self.settings(["theme": "dark", "statusLine": ["type": "command", "command": command]])

        let removal = try StatuslineRegistration.remove(from: existing)

        guard case let .removed(data, removed) = removal else {
            Issue.record("expected \(command) to be recognised as ours, got \(removal)")
            return
        }

        #expect(removed == command)
        #expect(try Self.object(data)["statusLine"] == nil)
        #expect(try Self.object(data)["theme"] as? String == "dark")
    }

    /// The single slot cuts the same way on the way out: taking someone's own status line is worse than leaving ours behind.
    @Test
    func aStatusLineSomeoneElseBuiltIsLeftAlone() throws {
        let existing = try Self.settings(["statusLine": ["type": "command", "command": "~/.claude/my-statusline.sh"]])

        #expect(try StatuslineRegistration.remove(from: existing) == .notOurs(existing: "~/.claude/my-statusline.sh"))
    }

    /// A slot holding something of an unrecognised shape is reported, never emptied — it cannot be ours, so it is someone's.
    @Test
    func aStatusLineOfAnUnrecognisedShapeIsLeftAlone() throws {
        let existing = try Self.settings(["statusLine": "my-statusline.sh"])

        #expect(try StatuslineRegistration.remove(from: existing) == .notOurs(existing: "(a status line of an unrecognised shape)"))
    }

    @Test
    func anEmptySlotIsNothingToUndo() throws {
        #expect(try StatuslineRegistration.remove(from: nil) == .absent)
        #expect(try StatuslineRegistration.remove(from: Self.settings(["theme": "dark"])) == .absent)
    }

    @Test
    func removingAStatusLineTwiceIsTheSecondTimeANoOp() throws {
        let existing = try Self.settings(["statusLine": ["type": "command", "command": "/bin/sift statusline"]])

        guard case let .removed(data, _) = try StatuslineRegistration.remove(from: existing) else {
            Issue.record("expected the first removal to take it out")
            return
        }

        #expect(try StatuslineRegistration.remove(from: data) == .absent)
    }
}
