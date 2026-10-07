//
// Copyright © Agulhas Labs
//

import ArgumentParser
import Foundation
import SiftCore

/// The Codex half of `install-hook` and `uninstall-hook`: runs ``CodexInstall`` and says what it did, starting with the Codex home it used.
struct CodexHookInstaller {
    /// Registers the hooks and the server in `home` for `binary`, an absolute path, and prints the answer; exits 1 when the server could not be registered.
    @discardableResult
    static func install(home: CodexInstall.Home, binary: String, runner: any CodexMcpRunner, output: CommandOutput) throws -> CursorInstall.Outcome {
        let outcome = try installing(home: home, binary: binary, runner: runner, output: output)
        try exit(outcome)
        return outcome
    }

    /// The install without the exit: prints the answer and returns what it did, a server that could not be registered among its failures.
    static func installing(home: CodexInstall.Home, binary: String, runner: any CodexMcpRunner, output: CommandOutput) throws -> CursorInstall.Outcome {
        output.emit(home.line)
        let outcome = try CodexInstall.install(home: home, binary: binary, binaryWord: ShellWord.quoted(binary), runner: runner)
        emit(outcome, to: output)
        output.emit(restart)
        for line in CodexInstall.unsupported {
            output.emit(line)
        }
        output.emit(experimental)
        return outcome
    }

    /// Takes out what the install wrote in `home` and prints the answer; exits 1 when the server could not be removed.
    static func uninstall(home: CodexInstall.Home, runner: any CodexMcpRunner, output: CommandOutput) throws {
        output.emit(home.line)
        let outcome = try CodexInstall.uninstall(home: home, runner: runner)
        if outcome.lines.isEmpty, outcome.notes.isEmpty, outcome.failures.isEmpty {
            output.emit("codex: nothing registered in \(home.directory.path)")
        }
        emit(outcome, to: output)
        if outcome.changed {
            output.emit("restart Codex to unload the hooks; removing sift's hooks moves any hook after them, so Codex asks you to trust those again when it next opens")
        }
        try exit(outcome)
    }

    /// The one manual step after an install: Codex asks to trust hooks it has not seen the moment it opens, so nothing needs typing.
    static var restart: String {
        "restart Codex: it asks you to trust the sift hooks the first time it opens; approve them (again after a repoint; /hooks is where to review them)"
    }

    /// Said on every install, since nothing yet shows the whole path working in a live Codex.
    static var experimental: String {
        "experimental: Codex support has not yet been verified end to end in a live Codex session"
    }

    private static func emit(_ outcome: CursorInstall.Outcome, to output: CommandOutput) {
        for line in outcome.lines {
            output.emit(line)
        }
        for file in outcome.written {
            output.emit("      \(file)")
        }
        for note in outcome.notes + outcome.failures {
            output.emit(note)
        }
    }

    private static func exit(_ outcome: CursorInstall.Outcome) throws {
        guard outcome.failures.isEmpty else { throw ExitCode(1) }
    }
}
