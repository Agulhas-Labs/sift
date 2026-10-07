//
// Copyright © Agulhas Labs
//

import ArgumentParser
import Foundation
import SiftCore

/// `sift uninstall-hook` — the exact inverse of `install-hook`, taking this tool's registrations back out of `~/.claude/settings.json`.
///
/// It exists because the only other way out is editing the file by hand, and that file configures every session on the machine: someone who wants the nudges gone should not have to open a JSON blob they did not write to get there. Everything the install refused to touch on the way in is refused on the way out too — a foreign hook in the same event, a status line someone built themselves.
struct UninstallHookCommand: ParsableCommand {
    static var configuration: CommandConfiguration {
        CommandConfiguration(
            commandName: "uninstall-hook",
            abstract: "Remove this tool's hooks and status line from Claude Code (idempotent; leaves anything it did not register alone)."
        )
    }

    @Option(name: .customLong("settings"), help: "Settings file to edit (defaults to ~/.claude/settings.json).")
    var settings: String?

    @Flag(
        name: .customLong("only-advice"),
        help: "Remove only the PreToolUse shell hook, keeping the session primer and the status line."
    )
    var onlyAdvice = false

    @Option(name: .customLong("agent"), help: "The agent to remove the registration from: claude (default), cursor or codex.")
    var agent: InstallHookCommand.Agent = .claude

    @Option(name: .customLong("cursor-dir"), help: "With --agent cursor, the directory holding Cursor's mcp.json and hooks.json (defaults to ~/.cursor).")
    var cursorDirectory: String?

    @Option(name: .customLong("codex-dir"), help: "With --agent codex, the Codex home holding hooks.json and config.toml (defaults to $CODEX_HOME, else ~/.codex).")
    var codexDirectory: String?

    /// Where the answer goes, injected so a test can read what the uninstall printed.
    var output: CommandOutput = .standard

    /// The environment the Cursor and Codex directories are resolved from, injected so a test never reaches the real ones.
    var environment: [String: String] = ProcessInfo.processInfo.environment

    /// Who runs `codex mcp`, injected so a test never runs the real `codex`; `nil` runs the one on the PATH ``environment`` names.
    var codex: (any CodexMcpRunner)?

    func validate() throws {
        try InstallHookCommand.Agent.validate(agent, cursorDirectory: cursorDirectory, codexDirectory: codexDirectory, claudeOnly: [
            settings.map { _ in "--settings" },
            onlyAdvice ? "--only-advice" : nil,
        ])
    }

    func run() throws {
        if agent == .cursor {
            let directory = cursorDirectory.map { URL(fileURLWithPath: $0) } ?? SiftPaths.cursorDirectory(environment: environment)
            try CursorHookInstaller.uninstall(directory: directory, output: output)
            return
        }
        if agent == .codex {
            let home = CodexInstall.home(flag: codexDirectory, environment: environment)
            try CodexHookInstaller.uninstall(home: home, runner: codex ?? CodexCLI(environment: environment), output: output)
            return
        }
        let settingsURL = settings.map { URL(fileURLWithPath: $0) } ?? SiftPaths.claudeSettings(environment: environment)
        let outcome = try HookUninstall.run(settings: settingsURL, onlyAdvice: onlyAdvice)

        if !outcome.changed {
            output.emit("hook: nothing registered")
        }
        for line in outcome.removed {
            output.emit(line)
        }
        if let statusline = outcome.statusline {
            output.emit(statusline)
        }
        if let backupNote = outcome.backupNote {
            output.emit(backupNote)
        }
        output.emit("      \(SettingsFile.named(settingsURL))")
        if let stateNote = Self.stateNote {
            output.emit(stateNote)
        }
    }

    /// Uninstalling the hook is not deleting the user's data, so the logs and caches stay — but silently leaving a directory behind is how a tool gets remembered as one that did not clean up after itself.
    ///
    /// Names the directory only when it is actually on disk, and `nil` when it is not: pointing someone at a path that does not exist is the same wasted trip as not mentioning one that does.
    private static var stateNote: String? {
        guard FileManager.default.fileExists(atPath: SiftPaths.home.path) else { return nil }
        return "      ~/\(SiftPaths.directoryName) is left as it is — delete that directory to remove the logs and caches too"
    }
}

extension UninstallHookCommand {
    /// Only the flags come off the command line; ``output`` keeps its default on the parse path.
    enum CodingKeys: String, CodingKey {
        case settings
        case onlyAdvice
        case agent
        case cursorDirectory
        case codexDirectory
    }
}
