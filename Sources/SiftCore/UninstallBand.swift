//
// Copyright © Agulhas Labs
//

import Foundation

/// The uninstall's band step: the plugin `install.sh` enables in Claude Code, and the local marketplace it came from, both taken out through `claude plugin`.
///
/// The settings file is read here, never written: Claude Code owns `enabledPlugins` and `extraKnownMarketplaces`, so a registration is only ever removed by asking `claude`, and it is reported removed only once the file no longer names it. A marketplace named `sift` that is not a local folder is not the one `install.sh` made, and is left alone.
struct UninstallBand {
    /// The plugin as `claude plugin` names it: the band, in the marketplace `install.sh` writes beside it.
    static var plugin: String {
        "sift-band@sift"
    }

    /// The marketplace `install.sh` registers for the band.
    static var marketplace: String {
        "sift"
    }

    /// What the step removed, one answer line each.
    var removed: [String] = []
    /// What it named and did not remove, and why.
    var notes: [String] = []
    /// How many of the registrations it names as this tool's were not removed.
    var failures = 0

    /// The `claude` arguments that take the plugin out at user scope.
    static var uninstallArguments: [String] {
        ["plugin", "uninstall", plugin, "--scope", "user"]
    }

    /// The `claude` arguments that take the marketplace out at user scope.
    static var marketplaceRemovalArguments: [String] {
        ["plugin", "marketplace", "remove", marketplace, "--scope", "user"]
    }

    /// Takes the plugin and then its marketplace out through `claude`, each only where the settings file at `settings` registers it, silent when neither is there.
    static func settle(settings: URL, claude: ([String]) -> SiftUninstall.PluginRun) -> UninstallBand {
        var step = UninstallBand()
        let object = UninstallServers.jsonObject(at: settings)
        let pluginCommand = command(uninstallArguments)
        let marketplaceCommand = command(marketplaceRemovalArguments)

        if registersPlugin(object) {
            switch claude(uninstallArguments) {
            case .succeeded:
                if registersPlugin(UninstallServers.jsonObject(at: settings)) {
                    step.failures += 1
                    step.notes.append("band: not removed — `\(pluginCommand)` succeeded and \(settings.path) still names \(plugin)")
                    return step
                }
                step.removed.append("band: uninstalled the Claude Code plugin \(plugin)")
            case let .failed(reason):
                step.failures += 1
                step.notes.append("band: not removed — `\(pluginCommand)` failed: \(reason); then run: \(marketplaceCommand)")
                return step
            case .noClaude:
                step.failures += 1
                step.notes.append("band: not removed — `claude` is not on PATH; run: \(pluginCommand) && \(marketplaceCommand)")
                return step
            }
        }

        switch marketplaceSource(object) {
        case nil:
            break
        case let source? where source != "directory":
            step.notes.append("band: the marketplace named sift is a \(source) one, not the folder install.sh registers — left alone")
        case _?:
            switch claude(marketplaceRemovalArguments) {
            case .succeeded:
                if marketplaceSource(UninstallServers.jsonObject(at: settings)) != nil {
                    step.failures += 1
                    step.notes.append("band: not removed — `\(marketplaceCommand)` succeeded and \(settings.path) still names the marketplace \(marketplace)")
                } else {
                    step.removed.append("band: removed the Claude Code plugin marketplace \(marketplace)")
                }
            case let .failed(reason):
                step.failures += 1
                step.notes.append("band: not removed — `\(marketplaceCommand)` failed: \(reason)")
            case .noClaude:
                step.failures += 1
                step.notes.append("band: not removed — `claude` is not on PATH; run: \(marketplaceCommand)")
            }
        }
        return step
    }

    /// What ``settle(settings:claude:)`` would remove from the settings file at `settings`, one line each, read through the same checks and without running `claude`.
    static func pending(settings: URL) -> [String] {
        let object = UninstallServers.jsonObject(at: settings)
        var lines: [String] = []
        if registersPlugin(object) {
            lines.append("band: would uninstall the Claude Code plugin \(plugin)")
        }
        if marketplaceSource(object) == "directory" {
            lines.append("band: would remove the Claude Code plugin marketplace \(marketplace)")
        }
        return lines
    }

    /// `arguments` as the command a person can paste.
    private static func command(_ arguments: [String]) -> String {
        (["claude"] + arguments).joined(separator: " ")
    }

    /// Whether the settings object names the plugin, enabled or not: a disabled plugin is still installed.
    private static func registersPlugin(_ object: [String: Any]?) -> Bool {
        (object?["enabledPlugins"] as? [String: Any])?[plugin] != nil
    }

    /// The kind of source the marketplace named `sift` is declared from, or `nil` when none is.
    private static func marketplaceSource(_ object: [String: Any]?) -> String? {
        guard let entry = (object?["extraKnownMarketplaces"] as? [String: Any])?[marketplace] as? [String: Any] else {
            return nil
        }
        return (entry["source"] as? [String: Any])?["source"] as? String ?? "unrecognised"
    }
}
