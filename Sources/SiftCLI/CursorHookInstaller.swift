//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore

/// The Cursor half of `install-hook` and `uninstall-hook`: runs the merge in ``CursorInstall`` and says what it did.
struct CursorHookInstaller {
    /// Registers the server and the hooks in `directory` for `binary`, an absolute path, prints the answer and returns what the merge did.
    @discardableResult
    static func install(directory: URL, binary: String, output: CommandOutput) throws -> CursorInstall.Outcome {
        let outcome = try CursorInstall.install(directory: directory, binary: binary, binaryWord: ShellWord.quoted(binary))
        emit(outcome, to: output)
        if outcome.changed {
            output.emit(restart)
        }
        for line in CursorInstall.unsupported {
            output.emit(line)
        }
        output.emit(experimental)
        return outcome
    }

    /// Takes out what the install wrote in `directory` and prints the answer.
    static func uninstall(directory: URL, output: CommandOutput) throws {
        let outcome = try CursorInstall.uninstall(directory: directory)
        if outcome.lines.isEmpty {
            output.emit("cursor: nothing registered in \(directory.path)")
        }
        emit(outcome, to: output)
        if outcome.changed {
            output.emit("restart Cursor to unload the registration")
        }
    }

    /// The one manual step after an install that changed something.
    static var restart: String {
        "restart Cursor to load the registration"
    }

    /// Said on every install, since nothing yet shows the whole path working in a live Cursor.
    static var experimental: String {
        "experimental: Cursor support has not yet been verified end to end in a live Cursor"
    }

    private static func emit(_ outcome: CursorInstall.Outcome, to output: CommandOutput) {
        for line in outcome.lines {
            output.emit(line)
        }
        for file in outcome.written {
            output.emit("      \(file)")
        }
        for note in outcome.notes {
            output.emit(note)
        }
    }
}
