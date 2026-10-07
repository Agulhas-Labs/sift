//
// Copyright © Agulhas Labs
//

import Foundation

/// The per-user record of repository roots this tool has opened — `~/.sift/roots.json`.
///
/// It exists for the two setups a per-registration root breaks (Docs/Design.md §4): portfolio sessions rooted above any repo, where a rootless query has no repo to answer from, and name misses in one repo for a symbol declared in an indexed sibling. Both answers consult this list. Everything about it is best-effort — a failed write is swallowed, a vanished path is pruned on read, and a corrupt file reads as empty — because the registry is a convenience layer over queries that all work without it.
public struct RootsRegistry: Sendable {
    private let fileURL: URL
    /// Path prefixes whose repositories are too short-lived to be worth remembering; empty by default so the store stays a store, and filled in by `standard()`.
    private let ephemeralPrefixes: [String]

    public init(fileURL: URL, ephemeralPrefixes: [String] = []) {
        self.fileURL = fileURL
        self.ephemeralPrefixes = ephemeralPrefixes
    }

    /// The shared per-user registry, beside the usage log.
    public static func standard() -> RootsRegistry {
        RootsRegistry(fileURL: fileURL(in: SiftPaths.home), ephemeralPrefixes: systemEphemeralPrefixes)
    }

    /// Where the registry lives inside a per-user `~/.sift`.
    public static func fileURL(in home: URL) -> URL {
        home.appendingPathComponent("roots.json")
    }

    /// Where a repository is scratch work by construction.
    ///
    /// Both spellings of each are listed because `record` standardizes rather than canonicalises (see below), so `/tmp/…` is stored as written while `NSTemporaryDirectory()` reports the `/var/folders/…` form — and a prefix list that resolved symlinks would stop matching the paths actually stored.
    ///
    /// `NSTemporaryDirectory()` is the one entry read from the environment, and it is filtered rather than trusted: `TMPDIR=/` would reduce to an empty prefix, which `isEphemeral` reads as "every absolute path", and because every failure in this file is swallowed by design the symptom would be a permanently empty registry with no error anywhere — self-healing, the primer's roots list and the cross-root pointer all off at once. A prefix that is empty or the filesystem root can only be a mistake, so it is dropped.
    static var systemEphemeralPrefixes: [String] {
        let roots = [NSTemporaryDirectory(), "/tmp", "/var/folders"]
        return roots.flatMap { root -> [String] in
            let trimmed = root.hasSuffix("/") ? String(root.dropLast()) : root
            guard trimmed.count > 1, trimmed.hasPrefix("/") else { return [] }
            return trimmed.hasPrefix("/private") ? [trimmed, String(trimmed.dropFirst("/private".count))] : [trimmed, "/private" + trimmed]
        }
    }

    /// Whether `path` sits somewhere a repository cannot be expected to outlive the session that made it.
    ///
    /// Matched on a component boundary, so `/tmpfoo` is an ordinary directory rather than a temp one.
    private func isEphemeral(_ path: String) -> Bool {
        ephemeralPrefixes.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    /// Adds `root` (idempotently) to the registry.
    ///
    /// Deliberately standardized rather than canonicalised. Asking the filesystem for a path's true spelling also resolves symlinks, and a registry storing `/private/var/…` where every other component holds `/var/…` stops matching them — which the cross-root pointer's tests catch. Identity is reconciled where it is compared, in `SessionPrimer`, rather than by rewriting what every component stores. The cost of leaving it: one repository reached under two spellings can hold two entries here.
    public func record(_ root: String) {
        let canonical = URL(fileURLWithPath: root).standardizedFileURL.path
        guard !isEphemeral(canonical) else { return }
        var roots = storedRoots()
        guard !roots.contains(canonical) else { return }
        roots.append(canonical)
        save(roots.sorted())
    }

    /// Every recorded root still worth answering from, pruning (and persisting the prune of) those that aren't.
    ///
    /// Vanished paths are dropped here, and so are scratch ones, on read rather than only on write, so a registry already poisoned by a session that built fixtures under `/tmp` heals the first time it is consulted instead of waiting for the temp directory to be swept. That matters more than tidiness: every entry is probed by a rootless query, and a run of self-tests can leave most of a machine's roots pointing at throwaway repos — enough that `digest Widget` from a folder above them answers, confidently and with a freshness header, about a fixture.
    public func knownRoots() -> [String] {
        let stored = storedRoots()
        let surviving = stored.filter { FileManager.default.fileExists(atPath: $0) && !isEphemeral($0) }
        if surviving.count != stored.count {
            save(surviving)
        }
        return surviving
    }

    /// The same filtered view without the persisted prune — a read that can never become a write.
    ///
    /// For the PreToolUse hook, which runs concurrently with every session on the machine: a hook that rewrote the registry from its own snapshot could race a `record` and silently drop the root it never saw. The prune still happens — on the next `knownRoots()` from a path that owns the file's upkeep.
    public func currentRoots() -> [String] {
        storedRoots().filter { FileManager.default.fileExists(atPath: $0) && !isEphemeral($0) }
    }

    /// Every root the file holds, vanished and scratch ones included, read without the prune: for `uninstall`, which lists what the tool left behind rather than what is worth answering from.
    public func recordedRoots() -> [String] {
        storedRoots()
    }

    /// Every root the JSON-lines logs at `urls` recorded, one per line's `root` field, as written.
    public static func roots(inLogsAt urls: [URL]) -> Set<String> {
        var roots: Set<String> = []
        for url in urls {
            guard let data = try? Data(contentsOf: url) else { continue }
            for line in data.split(separator: 0x0A) {
                guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                      object["ts"] is String,
                      let root = object["root"] as? String
                else {
                    continue
                }
                roots.insert(root)
            }
        }
        return roots
    }

    private func storedRoots() -> [String] {
        guard let data = try? Data(contentsOf: fileURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let roots = object["roots"] as? [String]
        else {
            return []
        }
        return roots
    }

    private func save(_ roots: [String]) {
        guard let data = try? JSONSerialization.data(withJSONObject: ["roots": roots], options: [.prettyPrinted, .sortedKeys]) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Atomic, because concurrent sessions read this file mid-write — a truncated read parses as an
        // empty registry, which surfaces as a rootless answer with no error anywhere.
        try? data.write(to: fileURL, options: .atomic)
    }
}
