//
// Copyright © Agulhas Labs
//

import ArgumentParser
import Foundation
import SiftCore
import SiftMCP

/// `sift install-hook` — registers `session-start` for `SessionStart` and `SubagentStart`, `pre-tool-use` for `PreToolUse`, `post-tool-use` for `PostToolUse` and `stop` for `Stop` and `SubagentStop`, in `~/.claude/settings.json`, and takes out the status line and band an older install left.
///
/// Called by the distribution installer, and safe to run by hand: re-running is the upgrade path, and a registration already pointing at a moved binary is repointed rather than duplicated.
struct InstallHookCommand: ParsableCommand {
    static var configuration: CommandConfiguration {
        CommandConfiguration(
            commandName: "install-hook",
            abstract: "Register the SessionStart/SubagentStart primer, the PreToolUse advice hook, the PostToolUse reuse nudge, and the Stop/SubagentStop build check with Claude Code, removing an older install's status line and band (idempotent; re-run to upgrade)."
        )
    }

    @Option(name: .customLong("settings"), help: "Settings file to edit (defaults to ~/.claude/settings.json).")
    var settings: String?

    @Option(name: .customLong("command"), help: "Hook command to register (defaults to this binary's own path).")
    var command: String?

    @Flag(
        inversion: .prefixedNo,
        help: "Add (or don't add) both blocks of allow rules, the lookups and the builds the hook wraps in `sift run`, without asking."
    )
    var allowRun: Bool?

    @Flag(name: .customLong("allow-lookups"), help: "Add only the allow rules for `sift digest`, `where`, `search` and `strings`, without asking about either block.")
    var allowLookups = false

    @Option(name: .customLong("agent"), help: "The agent to register with: claude (default), cursor or codex. Cursor and Codex support is experimental.")
    var agent: Agent = .claude

    @Option(name: .customLong("cursor-dir"), help: "With --agent cursor, the directory holding Cursor's mcp.json and hooks.json (defaults to ~/.cursor).")
    var cursorDirectory: String?

    @Option(name: .customLong("codex-dir"), help: "With --agent codex, the Codex home holding hooks.json and config.toml (defaults to $CODEX_HOME, else ~/.codex).")
    var codexDirectory: String?

    /// Where the answer goes, injected so a test can read what the install printed.
    var output: CommandOutput = .standard

    /// Who runs `codex mcp`, injected so a test never runs the real `codex`; `nil` runs the one on the PATH ``environment`` names.
    var codex: (any CodexMcpRunner)?

    /// Who runs `claude plugin` for the legacy band's removal, injected so a test never runs the real `claude` against the real settings.
    var runPlugin: @Sendable ([String: String], [String]) -> SiftUninstall.PluginRun = UninstallCommand.claudeRunsPlugin

    /// Who is asked about the allow rules, injected so a test can answer for the terminal or stand in for its absence.
    var prompt: AllowRunPrompt = .standard

    /// The state directory the lookups decline is recorded in, injected so a test never writes the user's; `nil` is `~/.sift` (or `SIFT_HOME`) under ``environment``.
    var stateDirectory: URL?

    /// The command line this process was started with, injected so a test can say how the binary was invoked.
    var arguments: [String] = CommandLine.arguments

    /// The environment the binary is looked up in, injected so a test runs the install with its own PATH and home.
    var environment: [String: String] = ProcessInfo.processInfo.environment

    /// This process's own executable, injected so a test can say which file is running.
    var executable: String? = Bundle.main.executablePath

    /// Refuses a `--command` that `uninstall-hook` would not be able to find again.
    ///
    /// Recognition is by shape — the binary's name plus the subcommand — and it is the *only* handle either the re-run path or the uninstall has on a previous registration. A command outside that shape installs a hook nothing can subsequently see: the uninstall reports a clean sweep while leaving it running, and the next install appends a second primer beside it rather than repointing the first. Validation runs before a byte is written, so the refusal costs nothing.
    func validate() throws {
        try Agent.validate(agent, cursorDirectory: cursorDirectory, codexDirectory: codexDirectory, claudeOnly: [
            settings.map { _ in "--settings" },
            command.map { _ in "--command" },
            allowRun.map { $0 ? "--allow-run" : "--no-allow-run" },
            allowLookups ? "--allow-lookups" : nil,
        ])
        if allowRun == false, allowLookups {
            throw ValidationError("--allow-lookups adds the lookup rules and --no-allow-run adds none; give one of them")
        }
        guard let command, !HookRegistration.isOurs(command) else { return }
        throw ValidationError(
            "--command must name this binary and the subcommand it runs, e.g. \"\(executableWord()) session-start\" — "
                + "a command outside that shape is one `uninstall-hook` cannot find again."
        )
    }

    func run() throws {
        try install()
    }

    /// Runs the install and returns whether it changed anything: `false` is the answer that says every registration was already in place.
    @discardableResult
    func install() throws -> Bool {
        let binary = Self.binaryPath(invokedAs: arguments.first ?? SiftPaths.binaryName, environment: environment, executable: executable)
        if InvokedBinary.isInNpxCache(binary) {
            throw Self.npxCacheRefusal(binary, rerun: "sift install-hook")
        }
        if agent == .cursor {
            let directory = cursorDirectory.map { URL(fileURLWithPath: $0) } ?? SiftPaths.cursorDirectory(environment: environment)
            return try CursorHookInstaller.install(directory: directory, binary: binary, output: output).changed
        }
        if agent == .codex {
            let home = CodexInstall.home(flag: codexDirectory, environment: environment)
            return try CodexHookInstaller.install(home: home, binary: binary, runner: codex ?? CodexCLI(environment: environment), output: output).changed
        }
        let settingsURL = settings.map { URL(fileURLWithPath: $0) } ?? SiftPaths.claudeSettings(environment: environment)
        // `--command` overrides the primer's command only. The `PreToolUse` hook runs a different
        // subcommand, so it is always built from the binary's own path — an override that pointed both at
        // one command would register a primer where a permission decision is expected.
        let hookCommand = command ?? "\(executableWord()) session-start"

        // Before the read, never between it and the rewrite: `claude plugin` edits this same file, and the rewrite
        // below would put back what it took out. Skipped for a named file, as the uninstall skips it: `claude`
        // edits the user's own settings, so it would read one file and change another.
        let band = settings == nil
            ? LegacyBandCleanup.settle(settings: settingsURL) { runPlugin(environment, $0) }
            : (lines: [], removed: false)

        // A file that is there and cannot be read is refused: read as absent, the merge would replace it with sift's hooks alone.
        let original = try CursorInstall.read(settingsURL, agent: "claude", flag: "--settings")
        var merged = original
        var hookChanged = false
        var replaced: [String] = []
        for event in HookRegistration.events {
            let eventCommand = event.subcommand == "session-start" ? hookCommand : "\(executableWord()) \(event.subcommand)"
            let result = try HookRegistration.apply(
                to: merged,
                command: eventCommand,
                event: event.name,
                subcommand: event.subcommand,
                matchers: event.matchers,
                timeout: event.timeout
            )
            guard result.changed else { continue }
            merged = result.data
            hookChanged = true
            // Distinct across events as well as within one: a single moved binary is one fact to report,
            // not one per event it was registered for.
            for previous in result.replaced where !replaced.contains(previous) {
                replaced.append(previous)
            }
        }
        var current = merged ?? Data()

        let (rulesAdded, permissionNote) = try allowRunRules(in: &current)

        var statuslineNote: String?
        // Sift draws no status line any more: one an older install registered comes out, and someone else's is not
        // looked at, so it is not mentioned either.
        if case let .removed(updated, _) = try StatuslineRegistration.remove(from: current) {
            current = updated
            statuslineNote = "statusline: removed (sift no longer draws one; run sift report)"
        }

        guard hookChanged || rulesAdded || statuslineNote != nil else {
            output.emit("hook: already registered (\(hookCommand))")
            if let permissionNote {
                output.emit(permissionNote)
            }
            for line in band.lines {
                output.emit(line)
            }
            return band.removed
        }

        // Back the file up before every rewrite that changes it, overwriting the previous copy, so the
        // backup holds the state before the latest rewrite rather than the original. It is the user's whole
        // Claude Code configuration and this tool did not author it; the copy is cheap insurance against a
        // merge bug on a machine where nobody is watching.
        let backupNote = try SettingsFile.rewrite(settingsURL, with: current, original: original)

        for previous in replaced {
            output.emit("hook: replaced stale registration (\(previous))")
        }
        if hookChanged {
            output.emit("hook: registered for SessionStart (\(HookRegistration.defaultMatchers.joined(separator: ", "))) and SubagentStart — \(hookCommand)")
            let preToolUse = HookRegistration.events.first { $0.subcommand == "pre-tool-use" }
            output.emit("      registered for PreToolUse (\(preToolUse?.matchers.joined(separator: ", ") ?? "")) — \(executableWord()) pre-tool-use")
            let postToolUse = HookRegistration.events.first { $0.subcommand == "post-tool-use" }
            output.emit("      registered for PostToolUse (\(postToolUse?.matchers.joined(separator: ", ") ?? "")) — \(executableWord()) post-tool-use")
            output.emit("      registered for Stop and SubagentStop — \(executableWord()) stop")
        } else {
            output.emit("hook: already registered (\(hookCommand))")
        }
        if let statuslineNote {
            output.emit(statuslineNote)
        }
        if let permissionNote {
            output.emit(permissionNote)
        }
        output.emit("      \(SettingsFile.named(settingsURL))")
        if let backupNote {
            output.emit(backupNote)
        }
        for line in band.lines {
            output.emit(line)
        }
        Self.emitAgentAllowlistNote(to: output)
        return true
    }

    /// Adds the lookup and `sift run` allow rules to `settings` where they are missing and the answer is yes, returning whether any were added and the line saying what happened.
    ///
    /// The answers are `--allow-run` (both blocks), `--no-allow-run` (neither), `--allow-lookups` (the lookups alone), or on a terminal one question per missing block, the lookups first and defaulting to yes (to no once it was declined, which `~/.sift` remembers until a yes or `--allow-lookups`), then the runs, defaulting to no. Never asked without a terminal, and not said when the file already holds what would be asked: where nobody can answer, nothing is added, and the line names the flags that add them.
    private func allowRunRules(in settings: inout Data) throws -> (added: Bool, note: String?) {
        // The shape of `permissions` is looked at only where rules could be added: a refusal
        // (`--no-allow-run`, or no terminal to ask on) leaves it alone, so it never blocks the hooks.
        if allowRun == false {
            return (false, "permissions: nothing added")
        }
        let asks = allowRun == nil && !allowLookups
        let lookupsMissing = try !LookupAllowRules.missing(from: settings).isEmpty
        let runsMissing = try !RunAllowRules.missing(from: settings).isEmpty
        guard lookupsMissing || (runsMissing && !allowLookups) else {
            return (false, allowLookups ? "permissions: lookups already allowed" : "permissions: wrapped builds and lookups already allowed")
        }
        if asks, !prompt.isInteractive {
            return (false, "permissions: nothing added — `sift install-hook --allow-run` lets sift's lookups and a wrapped build run without a prompt, `sift install-hook --allow-lookups` the lookups alone")
        }
        // A block already in the file is not asked about again.
        let addLookups = lookupsMissing && wantsLookups(asking: asks)
        let addRuns = runsMissing && (allowRun == true || (asks && AllowRunPrompt.accepts(prompt.ask(AllowRunPrompt.runsQuestion), defaultsTo: false)))
        // Each set is a block of its own, so an install over a file holding only one set adds only the other.
        var added: [String] = []
        if addRuns, let updated = try RunAllowRules.adding(to: settings) {
            settings = updated
            added += RunAllowRules.rules
        }
        if addLookups, let updated = try LookupAllowRules.adding(to: settings) {
            settings = updated
            added += LookupAllowRules.rules
        }
        return added.isEmpty ? (false, "permissions: nothing added") : (true, "permissions: allowed \(added.joined(separator: ", "))")
    }

    /// Whether the lookups block is to be added: yes without asking where a flag gave the answer, otherwise the answer to the question, which defaults to no after an earlier decline.
    ///
    /// A no is recorded and a yes, or a flag that adds the block, clears the record; an end of input is no answer and leaves it.
    private func wantsLookups(asking: Bool) -> Bool {
        let record = LookupsDeclineRecord(directory: stateDirectory, environment: environment)
        guard asking else {
            record.clear()
            return true
        }
        let declinedBefore = record.exists
        let answer = prompt.ask(AllowRunPrompt.lookupsQuestion(defaultingToNo: declinedBefore))
        let accepted = AllowRunPrompt.accepts(answer, defaultsTo: !declinedBefore)
        if accepted {
            record.clear()
        } else if answer != nil {
            record.write()
        }
        return accepted
    }

    /// Names any agent definition whose `tools:` allowlist would spawn contexts these hooks cannot reach.
    ///
    /// Here as well as in `status` because this is the moment the wiring is being done, and a hook installed into a machine that already holds such a definition is a hook that will be refusing lookups into a context holding nothing it names — for as long as it takes someone to wonder why the share is low. Silent when there is nothing to name, like everything else this prints.
    private static func emitAgentAllowlistNote(to output: CommandOutput) {
        // The repository, not the directory the installer happened to be run from: definitions live at
        // `<repo>/.claude/agents`, and an install run from a subdirectory would otherwise look in a
        // directory that does not exist and report that nothing is in scope.
        let root = CallerRoot.root(forCallerIn: FileManager.default.currentDirectoryPath)
        guard let text = AgentAllowlistReport.text(root: root) else { return }
        output.emit(text)
    }

    /// The binary as the first word of every command this registers: shell-quoted where its path holds a space or anything else a shell reads, because Claude Code runs each one through `sh -c`.
    private func executableWord() -> String {
        ShellWord.quoted(Self.binaryPath(invokedAs: arguments.first ?? SiftPaths.binaryName, environment: environment, executable: executable))
    }

    /// The refusal of a `binary` in npx's cache, which npx evicts, naming `rerun` as the command to run again from a lasting install.
    static func npxCacheRefusal(_ binary: String, rerun: String) -> ValidationError {
        ValidationError(
            "this sift is running from npx's cache (\(binary)), which npx evicts and replaces per version — hooks registered there would exit 127 after the next eviction. "
                + "Install the binary first (`brew install`, `install.sh`, or `npm install -g @agulhas-labs/sift`), then run `\(rerun)` from that install."
        )
    }

    /// The binary the hooks run: the path the shell found this one by, a link on PATH kept as the link, so the registration survives an install to a non-default `SIFT_DEST` and a Homebrew upgrade.
    ///
    /// Never the bare name, which a hook's shell might resolve differently; the conventional install location only where nothing resolves at all.
    static func binaryPath(invokedAs argument0: String, environment: [String: String], executable: String?) -> String {
        InvokedBinary.runningPath(invokedAs: argument0, environment: environment, executable: executable)
            ?? SiftPaths.userHome(environment: environment).appendingPathComponent(".local/bin/sift").path
    }
}

extension InstallHookCommand {
    /// Only the flags come off the command line; ``output`` and ``prompt`` keep their defaults on the parse path.
    enum CodingKeys: String, CodingKey {
        case settings
        case command
        case allowRun
        case allowLookups
        case agent
        case cursorDirectory
        case codexDirectory
    }

    /// The agent `install-hook` and `uninstall-hook` register with, and which of their flags each one takes.
    enum Agent: String, ExpressibleByArgument, CaseIterable, Sendable {
        case claude
        case cursor
        case codex

        /// The harness's name as a refusal spells it.
        var harness: String {
            switch self {
            case .claude:
                "Claude Code"
            case .cursor:
                "Cursor"
            case .codex:
                "Codex"
            }
        }

        /// Refuses a flag the chosen agent has no use for, so a `--settings` given with `--agent cursor` is never silently ignored.
        static func validate(_ agent: Agent, cursorDirectory: String?, codexDirectory: String?, claudeOnly: [String?]) throws {
            for (flag, owner) in [(cursorDirectory.map { _ in "--cursor-dir" }, Agent.cursor), (codexDirectory.map { _ in "--codex-dir" }, .codex)] {
                guard let flag, owner != agent else { continue }
                throw ValidationError("\(flag) applies only with --agent \(owner.rawValue)")
            }
            let given = claudeOnly.compactMap(\.self)
            guard agent != .claude, !given.isEmpty else { return }
            throw ValidationError(
                "\(given.joined(separator: ", ")) configure\(given.count == 1 ? "s" : "") Claude Code, not \(agent.harness) — drop \(given.count == 1 ? "it" : "them") with --agent \(agent.rawValue)"
            )
        }
    }
}
