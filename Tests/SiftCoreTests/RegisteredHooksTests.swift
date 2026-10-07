//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers the check that lets a binary tell whether the hooks firing into it are its own, which it answers by reading the settings file rather than a record of what an installer wrote.
///
/// The case it exists for is an upgrade that does not re-run the installer — a `brew upgrade`, an `npm i -g` — which leaves the settings file holding the previous version's matchers while the new binary assumes its own. The cases it is written *this* way for are the three a record gets wrong: a file hand-edited after the install, a file the install never touched, and a file whose registration outlived the record describing it.
@Suite(.temporaryDirectories)
struct RegisteredHooksTests {
    /// A settings file this binary has just installed into holds this binary's registration, and there is nothing for the doctor to say about it.
    @Test
    func aSettingsFileThisBinaryInstalledIntoReadsAsCurrent() throws {
        let file = try Self.temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        try Self.installed().write(to: file)
        let hooks = RegisteredHooks(settings: file)

        #expect(hooks.registered == HookRegistration.fingerprint)
        #expect(hooks.isCurrent)
        #expect(hooks.note == nil)
    }

    /// A matcher narrowed by hand after the install reads as stale, which is the whole reason the file is read rather than a record of what was written to it.
    ///
    /// Dropping `mcp__sift__.*` to spare the hook run on every index call is a reasonable thing for someone to do, and it is exactly what stops the hook reporting an index call. A record written by the install survives that edit untouched and goes on answering "current" — the unsafe direction, since the gate then admits the diagnosis on evidence the registration could never have gathered.
    @Test
    func aMatcherNarrowedByHandAfterTheInstallReadsAsStale() throws {
        let file = try Self.temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        try Self.narrowed(
            Self.installed(),
            to: "Bash|Read|Grep|Glob|mcp__xcode__Xcode(Read|Grep|Glob)"
        ).write(to: file)
        let hooks = RegisteredHooks(settings: file)

        #expect(hooks.registered != nil)
        #expect(!hooks.isCurrent)
        #expect(hooks.note?.contains("not this version's") == true)
        #expect(hooks.note?.contains("sift install-hook") == true)
    }

    /// An install into one settings file says nothing about another, which is what a machine-wide record could not express.
    ///
    /// With a record, `sift install-hook --settings /tmp/scratch.json` would write this binary's fingerprint to a record every later check consults, while the file the machine's sessions actually load keeps whatever it had. Read back per file, the question can only be asked of a file, so it can only be answered about that one.
    @Test
    func anInstallIntoOneFileSaysNothingAboutAnother() throws {
        let directory = try TemporaryDirectory.make("registered-hooks")
        defer { try? FileManager.default.removeItem(at: directory) }
        let installed = directory.appendingPathComponent("scratch.json")
        let loaded = directory.appendingPathComponent("settings.json")
        try Self.installed().write(to: installed)
        try Self.narrowed(
            Self.installed(),
            to: "Bash|Read|Grep|Glob|mcp__xcode__Xcode(Read|Grep|Glob)"
        ).write(to: loaded)

        #expect(RegisteredHooks(settings: installed).isCurrent)
        #expect(!RegisteredHooks(settings: loaded).isCurrent)
    }

    /// A settings file holding hooks this tool did not write registers nothing of ours, and the doctor says nothing about it.
    ///
    /// The case a standing "no registration recorded" note would be wrong about: a first-run public user, CI, anyone who never installed these hooks or has just uninstalled them. Three lines about a diagnosis they do not use is how doctor output becomes something people skim past.
    @Test
    func aSettingsFileRegisteringNothingOfOursIsSilent() throws {
        let file = try Self.temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let foreign = #"{"theme":"dark","hooks":{"PreToolUse":[{"matcher":"Write","hooks":[{"type":"command","command":"~/.claude/protect.sh"}]}]}}"#
        try foreign.write(to: file, atomically: true, encoding: .utf8)
        let hooks = RegisteredHooks(settings: file)

        #expect(hooks.registered == nil)
        #expect(!hooks.isCurrent)
        #expect(hooks.note == nil)
    }

    /// A settings file that is not there registers nothing — and is not read as a current registration either.
    @Test
    func anAbsentSettingsFileRegistersNothingAndIsNotTakenForACurrentOne() throws {
        let file = try Self.temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let hooks = RegisteredHooks(settings: file)

        #expect(hooks.registered == nil)
        #expect(!hooks.isCurrent)
        #expect(hooks.note == nil)
    }

    /// An uninstall takes the registration out of the file, which is the whole of what there is to forget.
    @Test
    func anUninstallLeavesNothingRegistered() throws {
        let file = try Self.temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        var current: Data? = try Self.installed()
        for event in HookRegistration.events {
            current = try HookRegistration.remove(
                from: current,
                event: event.name,
                subcommand: event.subcommand
            ).data
        }
        try #require(current).write(to: file)

        #expect(RegisteredHooks(settings: file).registered == nil)
        #expect(!RegisteredHooks(settings: file).isCurrent)
    }

    /// An uninstall of the advice alone is a decision, and the doctor must not describe it as another version's registration whose remedy is the command that reverses the decision.
    ///
    /// `uninstall-hook --only-advice` is documented, and is what someone reaches for a week in when the shell nudges have outstayed their welcome and the primer has not. It leaves the two session events registered — this binary's own registration, one event short of all of it — which compares unequal to the fingerprint, correctly, since the advice hook really is not firing and the diagnosis really must stay withheld.
    @Test
    func removingOnlyTheAdviceIsNotReportedAsAnotherVersionsRegistration() throws {
        let file = try Self.temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        var current: Data? = try Self.installed()
        for event in HookRegistration.eventsToRemove(onlyAdvice: true) {
            current = try HookRegistration.remove(
                from: current,
                event: event.name,
                subcommand: event.subcommand
            ).data
        }
        try #require(current).write(to: file)
        let hooks = RegisteredHooks(settings: file)
        let note = try #require(hooks.note)

        #expect(hooks.registered == HookRegistration.fingerprintWithoutAdvice)
        // Unchanged, and the reason the note has to carry the difference instead: the gate is right to
        // refuse a diagnosis no registered hook could have gathered the evidence for.
        #expect(!hooks.isCurrent)
        #expect(!note.contains("not this version's"))
        #expect(!note.contains("re-run"))
        #expect(note.contains("--only-advice"))
        #expect(note.contains("No lookup is then answered in place"))
    }

    /// The fingerprint is derived from the registration, so a matcher that changes makes every settings file already on disk stale without anyone remembering to bump a number.
    @Test
    func theFingerprintNamesEveryEventAndItsMatchers() {
        let fingerprint = HookRegistration.fingerprint

        for event in HookRegistration.events {
            #expect(fingerprint.contains(event.name))
            #expect(fingerprint.contains(event.subcommand))
            for matcher in event.matchers {
                #expect(fingerprint.contains(matcher))
            }
        }
        // The one matcher the whole check exists for: a registration without it never fires on an index
        // call, so nothing can say a context reached the index.
        #expect(fingerprint.contains("mcp__sift__"))
    }

    /// A second registration beside ours — the shape a matcher change can leave behind — is not this binary's registration, because the hook then fires twice.
    @Test
    func aDuplicateRegistrationIsNotThisBinarysRegistration() throws {
        let duplicated = try Self.narrowed(Self.installed(), to: nil, duplicating: true)

        #expect(HookRegistration.fingerprint(of: duplicated) != HookRegistration.fingerprint)
    }

    /// Hooks this tool did not write are not part of the fingerprint, however many of them sit in the same file.
    @Test
    func foreignHooksAreNotPartOfTheFingerprint() throws {
        let ours = try Self.installed()
        let alongside = try HookRegistration.apply(
            to: ours,
            command: "~/.claude/protect.sh",
            event: "PreToolUse",
            subcommand: "protect.sh",
            matchers: ["Write"]
        ).data

        #expect(HookRegistration.fingerprint(of: alongside) == HookRegistration.fingerprint)
    }
}

private extension RegisteredHooksTests {
    static func temporaryFile() throws -> URL {
        try TemporaryDirectory.make("registered-hooks").appendingPathComponent("settings.json")
    }

    /// A settings file as `install-hook` leaves it, written by the merge itself rather than by hand.
    static func installed(sourceLocation: SourceLocation = #_sourceLocation) throws -> Data {
        var current: Data?
        for event in HookRegistration.events {
            current = try HookRegistration.apply(
                to: current,
                command: "/bin/sift \(event.subcommand)",
                event: event.name,
                subcommand: event.subcommand,
                matchers: event.matchers
            ).data
        }
        return try #require(current, sourceLocation: sourceLocation)
    }

    /// The same file with our `PreToolUse` entry rewritten under a different matcher — the hand edit, and the duplicate.
    static func narrowed(
        _ data: Data,
        to matcher: String?,
        duplicating: Bool = false,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> Data {
        var settings = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any], sourceLocation: sourceLocation)
        var hooks = try #require(settings["hooks"] as? [String: Any], sourceLocation: sourceLocation)
        var entries = try #require(hooks["PreToolUse"] as? [[String: Any]], sourceLocation: sourceLocation)
        let ours: [String: Any] = ["type": "command", "command": "/bin/sift pre-tool-use", "timeout": 5]
        if let matcher {
            entries = [["matcher": matcher, "hooks": [ours]]]
        }
        if duplicating {
            entries.append(["matcher": "Read", "hooks": [ours]])
        }
        hooks["PreToolUse"] = entries
        settings["hooks"] = hooks
        return try JSONSerialization.data(withJSONObject: settings)
    }
}
