//
// Copyright © Agulhas Labs
//

import Foundation

/// The binary that is running, found the way the shell that started it found it: what `install-hook` records for the hooks to run and what `uninstall` names for removal.
public struct InvokedBinary: Sendable {
    private init() {}
}

public extension InvokedBinary {
    /// The path this process was started by: `argument0` itself where it holds a slash, else the first match for it on PATH, else `executable`; `nil` when none of them names a file.
    ///
    /// A match on PATH is the path as found there, a link included: Homebrew's link on PATH outlives an upgrade, where the Cellar copy it points into does not.
    static func path(invokedAs argument0: String, environment: [String: String], executable: String?) -> String? {
        if argument0.contains("/") {
            return collapsingDots(URL(fileURLWithPath: argument0).pathComponents)
        }
        if let found = onPath(argument0, environment: environment) {
            return found
        }
        return executable
    }

    /// ``path(invokedAs:environment:executable:)``, except that a match on PATH counts only where it resolves (`realpath`) to the same file as `executable`.
    ///
    /// A shell that ran a relative PATH entry, or a wrapper that exec'd with a bare name, may have started a different `sift` from the one PATH finds first, and a registration naming that one would run a binary that is not this. The match is judged by resolved path and recorded as found: the link stays the link. With no `executable` to compare against, the match stands.
    static func runningPath(invokedAs argument0: String, environment: [String: String], executable: String?) -> String? {
        guard !argument0.contains("/"), let executable, let found = onPath(argument0, environment: environment) else {
            return path(invokedAs: argument0, environment: environment, executable: executable)
        }
        return resolved(found) == resolved(executable) ? found : executable
    }

    /// An absolute path's components joined with `.` and `..` collapsed.
    ///
    /// URL standardizing is not used: it drops a leading `/private`, which would register a spelling the caller never used.
    private static func collapsingDots(_ components: [String]) -> String {
        var kept: [String] = []
        for component in components.dropFirst() {
            switch component {
            case ".", "/": continue
            case "..": _ = kept.popLast()
            default: kept.append(component)
            }
        }
        return "/" + kept.joined(separator: "/")
    }

    private static func resolved(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    /// Whether `path`, as given or with its links resolved, is inside npx's cache (`…/_npx/<hash>/node_modules/…`).
    ///
    /// npx evicts and replaces that tree per version, so a registration naming a file in it stops resolving and every hook exits 127.
    static func isInNpxCache(_ path: String) -> Bool {
        [path, URL(fileURLWithPath: path).resolvingSymlinksInPath().path].contains { candidate in
            let components = URL(fileURLWithPath: candidate).pathComponents
            guard let npx = components.firstIndex(of: "_npx") else { return false }
            return components[(npx + 1)...].contains("node_modules")
        }
    }

    /// The first executable file named `name`, never a directory, on the PATH, as spelled there: a link is followed to judge what it names, and never replaced by its target.
    ///
    /// Only absolute entries unless `currentDirectory` is given: a caller that runs what it finds must not run a file planted in the directory it was started from.
    ///
    /// With `currentDirectory`, a relative entry, and an empty one wherever it stands (which means the current directory), is taken against it, as the shell takes it, for a caller that only judges which file a bare name names.
    static func onPath(_ name: String, environment: [String: String], currentDirectory: String? = nil) -> String? {
        guard let path = environment["PATH"] else { return nil }
        for entry in path.split(separator: ":", omittingEmptySubsequences: false).map(String.init) {
            let directory: URL
            if entry.hasPrefix("/") {
                directory = URL(fileURLWithPath: entry)
            } else if let currentDirectory {
                directory = URL(fileURLWithPath: entry, relativeTo: URL(fileURLWithPath: currentDirectory, isDirectory: true))
            } else {
                continue
            }
            let candidate = directory.appendingPathComponent(name).standardizedFileURL.path
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: candidate, isDirectory: &isDirectory), !isDirectory.boolValue else { continue }
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }
}
