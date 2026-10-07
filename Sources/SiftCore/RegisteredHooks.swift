//
// Copyright © Agulhas Labs
//

import Foundation

/// What a Claude Code settings file registers for this tool, read back out of it, so a binary can tell whether the hooks firing into it are its own.
///
/// **What the advice hook remembers about a context rests on a hook firing.** The index calls a context makes are seen only by the `PreToolUse` hook firing on `mcp__sift__…`, and they are what lets a later answer skip a call the context has already made and a whole read of a file it already holds the digest of go through. A registration whose matcher does not cover this server's own tools never fires on those calls, so none of that is remembered. Upgrading the binary without re-running the installer — a `brew upgrade`, an `npm i -g` — is exactly how a machine arrives in that state.
///
/// **The check reads the settings file rather than a record of what the installer wrote.** A record is a claim about the binary; the question is about the machine, and the two come apart in three ways that are all reachable: a `settings.json` hand-narrowed after the install, an install into a settings file other than the one this machine loads, and a record that survives every edit made to the file it describes. Reading it back leaves nothing to be wrong about.
///
/// The one gap left is stated where it can be acted on (``HookRegistration/fingerprint(of:)``): a registration naming a binary that has been deleted or replaced fingerprints exactly like one that runs.
public struct RegisteredHooks {
    private let settings: URL

    public init(settings: URL) {
        self.settings = settings
    }

    /// The settings file every session on this machine loads, whatever repository it is in.
    ///
    /// The layered files Claude Code also reads — a project's own `.claude/settings.json`, a `settings.local.json` — are deliberately not consulted. A registration in one of those does fire, so a machine installed that way reads as stale here: a doctor line too many, which is the direction this is allowed to be wrong in.
    public static func standard() -> RegisteredHooks {
        RegisteredHooks(settings: SiftPaths.claudeSettings)
    }

    /// The registration that file holds, fingerprinted as ``HookRegistration/fingerprint`` fingerprints this binary's — or `nil` when it registers nothing for this tool.
    ///
    /// Unreadable and absent are one answer on purpose: both mean this cannot show that the hooks firing are this binary's, and every use of that answer is one-sided.
    public var registered: String? {
        let found = HookRegistration.fingerprint(of: try? Data(contentsOf: settings))
        return found.isEmpty ? nil : found
    }

    /// Whether what that file registers is what this binary registers.
    public var isCurrent: Bool {
        registered == HookRegistration.fingerprint
    }

    /// What `status` should say about the registration, or `nil` when there is nothing to say.
    ///
    /// It says what is withheld as well as what to run, because a check that reports a discrepancy without naming its consequence is a line people learn to skip.
    ///
    /// **Silent where the file registers nothing of ours at all**, which is not a discrepancy and never was: a first run, a machine that deliberately never installed the hooks, CI, someone who has run the full `uninstall-hook`. Nothing is missing for a reader who never asked for the mechanism, and three lines about a hook they do not use is exactly how doctor output becomes something people skim past.
    ///
    /// **A partial uninstall gets a sentence of its own rather than either of those two.** `uninstall-hook --only-advice` removes the advice hook and leaves the primer, which is a documented thing to do; reporting that registration as "not this version's — re-run `sift install-hook`" would be false about the registration and would tell someone to run the command that reinstalls what they deliberately took out. Silence is the other wrong answer: it would make a machine with the advice off indistinguishable here from one with it on. So it is reported as what it is, with what would undo it named as a fact rather than prescribed.
    public var note: String? {
        guard let registered, registered != HookRegistration.fingerprint else { return nil }
        if registered == HookRegistration.fingerprintWithoutAdvice {
            return "hooks: the session primer is registered and the shell advice is not — what `sift "
                + "uninstall-hook --only-advice` leaves. No lookup is then answered in place, which is what "
                + "removing the advice asked for; `sift install-hook` registers it again."
        }
        return "hooks: the registration in your Claude Code settings is not this version's — re-run `sift "
            + "install-hook`. Until then the hook may not see this server's own calls, so an answer in place "
            + "can repeat what a context already holds."
    }
}
