//
// Copyright © Agulhas Labs
//

import Foundation

/// The uninstall's last line: what takes out the binary that ran.
///
/// Decided on the path with its links resolved, since Homebrew and npm both put a link on PATH into a tree they own, and an `rm` of the link leaves the copy and the manager's record of it. Where the resolved path is in neither tree the line is an `rm` of the path as found, never of the link's target, which can be a checkout's own build.
struct BinaryRemoval {
    /// The line for the binary at `path`, without its `binary:` label.
    static func line(for path: String) -> String {
        let resolved = resolvedPath(path)
        let components = URL(fileURLWithPath: resolved).pathComponents
        let package = UninstallServers.npmPackage
        if let npx = components.firstIndex(of: "_npx"), npx + 1 < components.count, components.contains("node_modules") {
            let copy = NSString.path(withComponents: Array(components[...(npx + 1)]))
            return "\(resolved) is npx's cached copy of \(package), which npx fetches again when next run; deleting \(copy) drops it"
        }
        if let modules = components.firstIndex(of: "node_modules") {
            let owner = NSString.path(withComponents: Array(components[..<modules]))
            if components[modules - 1] == "lib" {
                return "npm uninstall -g \(package) — \(resolved) is in npm's global packages under \(owner)"
            }
            return "npm uninstall \(package), run in \(owner) — \(resolved) is in that project's node_modules"
        }
        if let cellar = components.firstIndex(of: "Cellar"), cellar + 2 < components.count {
            return "brew uninstall \(components[cellar + 1]) — \(resolved) is in Homebrew's Cellar"
        }
        return "rm \(ShellWord.quoted(path)) — a running binary does not delete itself"
    }

    /// `path` with every link resolved, the last component's included, which a canonical path leaves as it is; as spelled when nothing is there.
    static func resolvedPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return CanonicalPath.of(path) }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
