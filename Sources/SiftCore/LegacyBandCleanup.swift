//
// Copyright © Agulhas Labs
//

import Foundation

/// The install's cleanup of the band an older `install.sh` enabled: the uninstall's own band step, reported as an install reports it.
public struct LegacyBandCleanup {
    /// Takes the band plugin and its local marketplace out through `claude`, each only where the settings file at `settings` names it, returning the lines to print and whether anything came out.
    ///
    /// A missing or failing `claude` is a note naming the commands to run, never a failure of the install. A marketplace named `sift` that is not a local folder is left alone and, unless a removal also failed, unmentioned: it is someone else's, and an install that runs on every upgrade should not keep naming it.
    public static func settle(settings: URL, claude: ([String]) -> SiftUninstall.PluginRun) -> (lines: [String], removed: Bool) {
        let step = UninstallBand.settle(settings: settings, claude: claude)
        return (step.removed + (step.failures > 0 ? step.notes : []), !step.removed.isEmpty)
    }

    /// What ``settle(settings:claude:)`` would take out at `settings`, one line each and none where nothing is there, read without running `claude`.
    public static func pending(settings: URL) -> [String] {
        UninstallBand.pending(settings: settings)
    }
}
