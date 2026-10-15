//
// Copyright © Agulhas Labs
//

/// The files a stale header counts, by kind, and the one file's path where it counts exactly one (Docs/Design.md §2).
///
/// Every counted file is already named in the body, by its mark, its refusal or the not-in-the-store line, so the header names a path only where it counts one: that is the case where the reader would otherwise scan the whole answer for the one marked file.
public struct StaleFiles: Sendable, Equatable {
    /// Files written since their own build.
    public let changed: Int
    /// Files gone from the tree.
    public let deleted: Int
    /// Files no store holds a unit for, written since the build that would compile them.
    public let new: Int
    /// The path of the one file counted, and `nil` wherever the count is not one.
    public let path: String?

    /// The counts given, keeping `path` only where they add up to one.
    init(changed: Int = 0, deleted: Int = 0, new: Int = 0, path: String? = nil) {
        self.changed = changed
        self.deleted = deleted
        self.new = new
        self.path = changed + deleted + new == 1 ? path : nil
    }

    /// The counts of `files`, each path under its one kind; a file of a kind no header counts is left out.
    init(_ files: [String: FileKind]) {
        let counted = files.filter { $0.value < .notBuilt }
        self.init(
            changed: counted.values.count { $0 == .changed },
            deleted: counted.values.count { $0 == .deleted },
            new: counted.values.count { $0 == .new },
            path: counted.count == 1 ? counted.keys.first : nil
        )
    }

    /// How many files are counted, whatever their kind.
    public var total: Int {
        changed + deleted + new
    }

    /// These counts with `paths` added as changed, the caller passing only paths not already counted (nothing here removes a duplicate): the header's count once a reader outside the verdict finds more files it relied on written since the build.
    func addingChanged(_ paths: Set<String>) -> StaleFiles {
        adding(Dictionary(uniqueKeysWithValues: paths.map { ($0, FileKind.changed) }))
    }

    /// These counts with `files` added, each under its own kind and none checked against what is already counted, the path kept only where the total is then one.
    func adding(_ files: [String: FileKind]) -> StaleFiles {
        let added = StaleFiles(files)
        return StaleFiles(
            changed: changed + added.changed,
            deleted: deleted + added.deleted,
            new: new + added.new,
            path: total == 0 ? added.path : path
        )
    }

    /// The parenthesised part of the header, in the order changed, deleted, new.
    ///
    /// A query answer counts the files it cites and says so (`cited: true`): `1 cited file changed: Sources/A.swift`, `3 cited files changed`, `2 new cited files`, `4 cited files: 1 changed, 1 deleted, 2 new`. `status` counts every file and keeps the plain form: `1 file changed: Sources/A.swift`, `3 files changed`, `2 new files`, `4 files: 1 changed, 1 deleted, 2 new`.
    func rendered(cited: Bool) -> String {
        let kinds = [(changed, "changed"), (deleted, "deleted"), (new, "new")].filter { $0.0 > 0 }
        let noun = cited ? "cited file" : "file"
        guard kinds.count == 1, let (count, kind) = kinds.first else {
            return "\(total) \(noun)s: " + kinds.map { "\($0.0) \($0.1)" }.joined(separator: ", ")
        }
        let plural = count == 1 ? "" : "s"
        let counted = kind == "new" ? "\(count) new \(noun)\(plural)" : "\(count) \(noun)\(plural) \(kind)"
        return path.map { counted + ": " + $0 } ?? counted
    }
}
