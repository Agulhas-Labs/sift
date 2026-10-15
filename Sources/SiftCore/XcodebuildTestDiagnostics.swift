//
// Copyright © Agulhas Labs
//

import Foundation

/// The verbose diagnostics `xcodebuild` collects from a simulator when a test fails, which `sift run` turns off.
///
/// After a failure `xcodebuild` runs `simctl diagnose` and waits on it before it exits, up to its 600 s timeout: measured 14 Oct 2026, a one-test filtered run that failed in 4 s returned after 611 s, and after 8 s with collection off. A `sift run` caller waits for the exit, so the verdict it already has is held for ten minutes.
public struct XcodebuildTestDiagnostics {
    /// The option and the value `sift run` adds.
    static var option: String {
        "-collect-test-diagnostics"
    }

    /// The line a failed run whose collection this turned off closes on.
    public static var note: String {
        "sift run: added -collect-test-diagnostics never, since after a failure xcodebuild otherwise waits up to 10 min on simctl diagnose before it exits; pass -collect-test-diagnostics on-failure to keep the diagnostics."
    }

    /// Whether `arguments` are an `xcodebuild test` or `test-without-building` that does not choose for itself, and so get collection turned off.
    public static func turnsOff(in arguments: [String]) -> Bool {
        guard RunCommandKind.recognize(arguments) == .xcodebuild, let action = RunVerdict.Contract.xcodebuildAction(of: arguments) else {
            return false
        }
        return (action == "test" || action == "test-without-building") && !arguments.contains { $0 == option || $0.hasPrefix(option + "=") }
    }

    /// `arguments` with collection turned off where ``turnsOff(in:)``.
    public static func skipping(_ arguments: [String]) -> [String] {
        turnsOff(in: arguments) ? arguments + [option, "never"] : arguments
    }
}
