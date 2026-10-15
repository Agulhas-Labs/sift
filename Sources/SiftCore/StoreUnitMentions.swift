//
// Copyright © Agulhas Labs
//

import Foundation

/// Whether an index store still holds a unit for a source file, read from the unit files on disk rather than from an opened store.
///
/// A build never removes the unit of a file deleted before it — SwiftPM and Xcode keep it until a clean build — so a query goes on citing that file whatever order the deletion, the build and this index noticing them came in. `status` cannot open the store (Docs/Design.md §2), so it asks the units directory instead, and only about the deleted paths its ledger already names: one listing of the directory, filed by stem once, then a read of each unit whose name begins with the file's stem, since a unit is named for its output file (`Caller.o-…`, `Caller.swift.o-…`).
///
/// A candidate counts when a path it records (``IndexUnitPaths``) is the file's own absolute path, under any spelling a build may have recorded it by (``FileSpellings``), so a same-named file in another directory never matches, nor one under a directory whose name ends the same way. It counts too when a path it records lies outside the root, ends with `/` and the file's repository-relative path, and is gone from disk: a path outside the root can only be a moved or copied checkout's, and one moved since its build leaves units recording its old place, which a query goes on citing as a deleted file. Inside the root only the whole path counts, since one there that merely ends the same way is another live file (`Sources/MyLib/Caller.swift`, a nested package's `Packages/X/Sources/Lib/Caller.swift`); outside it, a path still on disk is not this file's (a copy's original, a dependency checked out beside the store). A unit this cannot read records nothing, which leaves the file to the ledger's own dating, the reading this check adds to.
final class StoreUnitMentions {
    private let units: URL?
    private let root: URL
    private let canonicalRoot: String
    /// Each unit's name filed under every prefix a `.` ends (`Caller` and `Caller.swift` for `Caller.swift.o-…`), so a stem finds its units in one lookup instead of a scan of the listing per path.
    private lazy var unitsByStem: [String: [String]] = {
        let names = units.flatMap { try? FileManager.default.contentsOfDirectory(atPath: $0.path) } ?? []
        var byStem: [String: [String]] = [:]
        for name in names {
            for dot in name.indices where name[dot] == "." {
                byStem[String(name[..<dot]), default: []].append(name)
            }
        }
        return byStem
    }()

    private var recordedPaths: [String: [String]] = [:]
    /// How many unit files were read, which is what makes the bounded-cost claim checkable.
    private(set) var unitsRead = 0

    /// The mentions in the units directory of the store at `store`, of files in the repository at `root`; a store with no units directory mentions nothing.
    init(store: URL, root: URL) {
        units = IndexStoreDiscovery.unitsDirectory(in: store)
        self.root = root
        canonicalRoot = CanonicalPath.of(root.path)
    }

    /// Whether a unit names the source file at the repository-relative `path`.
    func names(file path: String) -> Bool {
        let stem = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        guard let units, let candidates = unitsByStem[stem] else { return false }
        let recorded = Set(candidates.flatMap { paths(recordedBy: $0, in: units) })
        var spellings = FileSpellings(ofFile: path, under: root, leading: canonicalRoot + "/" + path)
        return spellings.contains { recorded.contains($0) } || recorded.contains { isMovedCheckouts($0, file: path) }
    }

    /// Whether the recorded absolute path `recorded` is the repository-relative `path` in a checkout recorded elsewhere: outside the root under either spelling, ending at a component boundary with `path`, and gone from disk.
    private func isMovedCheckouts(_ recorded: String, file path: String) -> Bool {
        recorded.hasSuffix("/" + path)
            && ![root.path, canonicalRoot].contains { recorded.hasPrefix($0 + "/") }
            && !FileManager.default.fileExists(atPath: recorded)
    }

    /// The paths the unit named `unit` records, each unit read at most once however many paths share its stem.
    private func paths(recordedBy unit: String, in units: URL) -> [String] {
        if let known = recordedPaths[unit] {
            return known
        }
        unitsRead += 1
        let paths = (try? Data(contentsOf: units.appendingPathComponent(unit))).map(IndexUnitPaths.of) ?? []
        recordedPaths[unit] = paths
        return paths
    }
}
