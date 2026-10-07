//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore

/// A ``CommandOutput`` that keeps what one agent's installer printed, so `sift install` can print it under that agent's name and gather the lines every installer repeats into one summary.
///
/// Locked because the closures are `@Sendable`, like every sink a command is handed.
final class InstallCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var captured: [String] = []

    /// Every line printed, in order, stderr's among them: a line printed as several is split into several.
    var lines: [String] {
        lock.withLock { captured }
    }

    /// The sink to hand the installer.
    var output: CommandOutput {
        CommandOutput(
            keepsPartMarker: true,
            emit: { self.keep($0) },
            emitRaw: { self.keep(String(bytes: $0, encoding: .utf8) ?? "") },
            emitError: { self.keep($0) }
        )
    }

    private func keep(_ text: String) {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        lock.withLock { captured += lines }
    }
}
