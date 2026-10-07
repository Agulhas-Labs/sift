//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore

/// The Cursor step of `sift install`: the server and the hooks in the Cursor directory, through the same installer as `install-hook --agent cursor`.
struct CursorInstallStep {
    /// Installs `binary` into the Cursor directory under the home `environment` names, printing to `output`.
    static func run(binary: String, environment: [String: String], output: CommandOutput) throws -> InstallStepReport {
        let outcome = try CursorHookInstaller.install(directory: SiftPaths.cursorDirectory(environment: environment), binary: binary, output: output)
        return InstallStepReport(agent: .cursor, written: outcome.written, failures: outcome.failures)
    }
}
