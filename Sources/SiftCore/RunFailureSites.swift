//
// Copyright © Agulhas Labs
//

import Foundation

/// The declarations a run's failures happened inside, resolved against this repository's own source.
///
/// A framework reports a failure as a location and a message, and the reader's next move is always the same one: find out what is *at* that line. This answers it inside the run's own answer — `ChartGridTests.swift:22` becomes the declaration whose source range contains line 22 — and it is the one thing a wrapper around a build cannot do without an index of the code sitting beside the log. It is also where the answer stops being a summary of the transcript and starts being about the code: a build tool can say a test failed, and only something holding both can say the failing assertion is not in the test that was named.
///
/// **Everything here is syntactic, and every line it produces says so.** "Which declaration encloses this line" is answered by parsing the file, so the answer describes the bytes on disk at the moment it was composed and cannot be stale — unlike callers, conformers and overrides, which come from the build's index store and are refused when that store is behind (Docs/Design.md §2, axis 2). Nothing here opens the index store, so none of that axis applies, and nothing here may be read as a claim about what the failing line *called*: containment is not a call graph, and the distance between the two is exactly the distance between a fact and a guess.
///
/// **The index is consulted for one thing only: which file.** Swift Testing prints a bare `ChartGridTests.swift` and XCTest an absolute path from the machine that built it, so a location on its own names no file in this tree. The index's file table does, and it is opened read-only through ``ReadOnlyIndex`` — which never creates a database, never indexes, and never writes. A repository with no index therefore resolves nothing and says nothing about it, which is what keeps `run` working unchanged in any directory it is pointed at, indexed or not. Where there is one, git's live listing adds the files written since it was last brought up to date, since `run` does not refresh it.
///
/// **Declarations come from a fresh parse, not from the index's stored line ranges.** The file most likely to hold a failure is the file just edited, and a stored range is the one thing about that file guaranteed to be out of date — a confident wrong declaration attached to a real failure is the worst answer this codebase can produce. Reparsing the handful of files an answer names costs a few milliseconds and removes the staleness question rather than managing it.
///
/// **A filename naming more than one file in the repository resolves to none of them.** There is nothing in `Foo.swift:85` that says which `Foo.swift`, so both are dropped; refuse over guess, and the failure simply prints unresolved.
public struct RunFailureSites: Sendable, Equatable {
    /// Every resolved site, keyed by the `<filename>:<line>` that ``declaration(at:)`` reduces a printed location to.
    ///
    /// Keyed on the bare filename rather than the path it was printed with, because one file is named two ways by the two frameworks: a bare `ChartGridTests.swift` from Swift Testing and an absolute path from XCTest. Reducing both to the name and the line makes the lookup indifferent to which arrived — and to any third spelling a caller holds — and costs nothing that the ambiguity rule above has not already forbidden.
    private let byLine: [String: Declaration]
    /// The repository root the declarations' repo-relative paths are relative to; `nil` where nothing resolved.
    private let root: URL?
}

public extension RunFailureSites {
    /// One declaration, in the terms the answer prints it in.
    struct Declaration: Sendable, Equatable {
        /// The container chain and the member, `ChartGridTests.assertLayout(_:at:)`, without the module.
        ///
        /// Without the module because a run's answer is read inside one repository whose modules the reader already knows, and the prefix would push the range — the part that is a `Read` target — off the end of the line.
        public let name: String
        /// Repo-relative path to the file the declaration is written in.
        public let path: String
        public let startLine: Int
        public let endLine: Int
        /// Whether the declaration is written `@Test`, which is what tells a Swift Testing case from a helper that happens to share its name.
        public var isSwiftTest = false
    }

    /// Nothing resolved, and the answer says nothing about it.
    ///
    /// The absence is deliberately silent. Resolution is a bonus over an answer that was complete without it, so a line apologising for not having it would cost every unindexed repository a line of noise on every failing run, to report a capability it never asked for.
    static let none = RunFailureSites(byLine: [:], root: nil)

    /// How long the answer waits for the resolution before going out without it.
    ///
    /// **The answer is what the caller is waiting on**, and this work is optional, so the deadline is short and hard: when it passes the answer renders with no `in …` lines at all, exactly as an unindexed repository does. The thread doing the resolution is abandoned rather than cancelled — it reads a read-only database and parses files, so there is nothing for it to corrupt, and the process exits from under it moments later.
    ///
    /// Two seconds because of what the work actually is: one read-only open of an existing SQLite index, one scan of its file table, and a parse of at most ``fileCap`` files. Over this repository's own largest sources the whole of it at the cap takes a few hundred milliseconds — and the ordinary case, a failing run naming two or three files, is a tenth of that. The budget is therefore not sized against that figure but against the shapes it does not cover: a generated file tens of thousands of lines long, a cold network filesystem. It is deliberately *not* ``SiftEngine/semanticOpenBudget``, which is sized for an index-store open that can take minutes and whose whole contract is "ask again in a moment" — there is no second ask in a one-shot `run`.
    static let budget: TimeInterval = 2

    /// How many distinct files one answer will parse.
    ///
    /// The second half of the enforcement, and the deterministic half: a wall clock decides differently on a loaded machine than on an idle one, and an answer that changes with the weather is not one anybody can reason about. Files are taken in order of how many of the run's failures name them, ties broken by name, so the cap always keeps the files the answer is most about and always keeps the same ones.
    ///
    /// Thirty-two is well past what a shape's five examples can reach even when each of them spreads as widely as the corpus's worst signature does — 117 failures over 8 files — and it costs about 300 ms of parsing at the ceiling. The widest capture here spreads 666 failures over 53 files; the twenty-one it does not reach print exactly as they would unresolved.
    static let fileCap = 32

    /// Where `declaration`'s file is on disk, for stating it as an answer states paths: the repo-relative path is relative to the repository root, which is not where the reader stands when the run was started from a subdirectory.
    func absolutePath(of declaration: Declaration) -> String {
        root?.appendingPathComponent(declaration.path).path ?? declaration.path
    }

    /// The declaration enclosing `location`, or `nil` when it did not resolve.
    func declaration(at location: String) -> Declaration? {
        Self.key(of: location).flatMap { byLine[$0] }
    }

    /// Resolves each of `locations` to the declaration whose source range contains it, within `budget`.
    ///
    /// Never throws and never fails loudly: every way this can come up empty — no repository, no index, an ambiguous filename, a file that will not parse, a budget spent — returns ``none`` and leaves the answer as it would have been. `run` wraps a toolchain command in any directory, and that must not regress for a resolution nobody asked for.
    static func resolving(
        _ locations: some Sequence<String>,
        inRepositoryAt root: URL,
        within budget: TimeInterval = RunFailureSites.budget
    ) -> RunFailureSites {
        var wanted: [String: Set<Int>] = [:]
        var weight: [String: Int] = [:]
        var printed: [String: Set<String>] = [:]
        for location in locations {
            guard let site = Self.site(of: location) else {
                continue
            }
            wanted[site.file, default: []].insert(site.line)
            weight[site.file, default: 0] += 1
            printed[key(file: site.file, line: site.line), default: []].insert(site.path)
        }
        guard !wanted.isEmpty else {
            return .none
        }
        let (lines, spellings) = (wanted, printed)
        let order = wanted.keys.sorted { left, right in
            let (leftWeight, rightWeight) = (weight[left] ?? 0, weight[right] ?? 0)
            return leftWeight == rightWeight ? left < right : leftWeight > rightWeight
        }
        return Self.within(budget) {
            Self.resolve(lines: lines, printedAs: spellings, inOrder: order, atRoot: root)
        }
    }
}

public extension RunFailureSites.Declaration {
    /// `ChartGridTests.assertLayout(at:) — Tests/LibTests/ChartGridTests.swift:20-23`.
    var described: String {
        let range = startLine == endLine ? "\(startLine)" : "\(startLine)-\(endLine)"
        return "\(name) — \(path):\(range)"
    }
}

private extension RunFailureSites {
    /// What the drain of a resolution running on its own thread hands back.
    ///
    /// Unchecked because the semaphore is the ordering: the write happens before the signal and the read only ever after a successful wait. On the deadline path nothing is read at all.
    final class Resolved: @unchecked Sendable {
        var sites: RunFailureSites?
    }

    /// Runs `work` on a thread of its own and gives up on it when `budget` passes.
    ///
    /// A thread rather than a pooled queue, for ``BudgetedOpen``'s reason: this holds its thread for the whole of a parse run, and a global queue that hands out one of a fixed pool would have a blocked resolution competing with whatever else the process is doing.
    static func within(_ budget: TimeInterval, _ work: @escaping @Sendable () -> RunFailureSites) -> RunFailureSites {
        let resolved = Resolved()
        let finished = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            resolved.sites = work()
            finished.signal()
        }
        guard finished.wait(timeout: .now() + budget) == .success else {
            return .none
        }
        return resolved.sites ?? .none
    }

    /// Parses each wanted file once and answers every line asked about it.
    static func resolve(
        lines: [String: Set<Int>],
        printedAs spellings: [String: Set<String>],
        inOrder order: [String],
        atRoot root: URL
    ) -> RunFailureSites {
        guard let paths = indexedPaths(named: Set(order), atRoot: root) else {
            return .none
        }
        var byLine: [String: Declaration] = [:]
        for file in order.prefix(fileCap) {
            guard let path = paths[file],
                  let parsed = FileParser.parse(absoluteURL: root.appendingPathComponent(path), repoRelativePath: path)
            else {
                continue
            }
            for line in lines[file] ?? [] {
                let key = key(file: file, line: line)
                // Every spelling that reduced to this key has to be able to be this file. One that cannot
                // takes the key down with it rather than being counted out: two locations reduce to one
                // key, so a declaration recorded for either would be served for both.
                guard (spellings[key] ?? []).allSatisfy({ places($0, at: path, under: root) }) else {
                    continue
                }
                // A line inside no declaration at all — an import, a top-level statement — assigns `nil`
                // and so records nothing, which is the same absence as never having been asked about.
                byLine[key] = Declaration(enclosing: line, in: parsed)
            }
        }
        return RunFailureSites(byLine: byLine, root: root)
    }

    /// Whether the file the framework printed as `printed` can be the indexed file at `indexed`.
    ///
    /// **A bare filename constrains nothing, and everything else constrains everything.** Swift Testing prints `ChartGridTests.swift` and no directory, so there is nothing there to check and the filename is the whole of the evidence — which is what ``indexedPaths(named:atRoot:)``'s ambiguity rule already covers. XCTest prints the absolute path of the machine that compiled the file, and that path must not be *discarded*: `.build/checkouts/SomeDep/Tests/HelperTests.swift:42` reduced to `HelperTests.swift:42` would resolve to whichever `HelperTests.swift` this repository holds — printing `all 6 are in AppHelperTests.assertThing() — … (syntactic)` for failures that never touched the file. `.build` is never indexed, so the ambiguity rule cannot see the collision; only the directory the log printed can.
    ///
    /// Checked against the repository root rather than by matching tails, because a tail match accepts the dependency whose own layout happens to end the same way. An absolute path names exactly one file and either it is this one or it is not, and ``CanonicalPath`` is what makes that comparison survive a symlinked checkout. A path carrying a directory but no root is required to end the indexed path instead, which is the strongest claim such a path supports.
    static func places(_ printed: String, at indexed: String, under root: URL) -> Bool {
        let printedParts = printed.split(separator: "/")
        guard printedParts.count > 1 else {
            return true
        }
        guard !printed.hasPrefix("/") else {
            return CanonicalPath.of(printed) == CanonicalPath.of(root.appendingPathComponent(indexed).path)
        }
        let indexedParts = indexed.split(separator: "/")
        return indexedParts.count >= printedParts.count && indexedParts.suffix(printedParts.count).elementsEqual(printedParts)
    }

    /// Every wanted filename that names exactly one file in the index, mapped to its repo-relative path.
    ///
    /// `nil` — rather than an empty map — when there is no index to read, because the two are different answers and only one of them is worth distinguishing further up. The read is `ReadOnlyIndex`'s, so a repository that has never been indexed, or whose index predates the current schema, is left exactly as it was found.
    ///
    /// **The index's files are the ones it has seen, and git's listing adds the ones it will see.** `run` never brings the index up to date, so a test file written since the last query is missing from the file table — and that is the file most likely to hold a new failure, usually untracked while the fix is being proved. Git's own listing of the files it can see, tracked or untracked but not ignored, put through the same ``FileEnumerator`` rules the index is built by, is exactly what the next refresh will hold; an ignored file is never in it, and stays unresolved. A file in both counts once, so the ambiguity rule weighs files, not sightings of them.
    static func indexedPaths(named names: Set<String>, atRoot root: URL) -> [String: String]? {
        guard let database = ReadOnlyIndex.open(atRoot: root.path) else {
            return nil
        }
        let stored: Set<String>? = withExtendedLifetime(database) {
            guard let statement = try? database.prepare(RunFailureSitesStatement.allPaths.sql) else {
                return nil
            }
            var paths: Set<String> = []
            while (try? statement.step()) == true {
                paths.insert(statement.columnText(0))
            }
            return paths
        }
        guard let stored else {
            return nil
        }
        var found: [String: String] = [:]
        var ambiguous: Set<String> = []
        for path in stored.union(visiblePaths(named: names, atRoot: root)) {
            let name = String(path.split(separator: "/").last ?? "")
            guard names.contains(name) else {
                continue
            }
            if found.updateValue(path, forKey: name) != nil {
                ambiguous.insert(name)
            }
        }
        for name in ambiguous {
            found.removeValue(forKey: name)
        }
        return found
    }

    /// The `.swift` files named one of `names` that git can see at `root` and the index would hold, or none when git or the configuration cannot say.
    ///
    /// Narrowed to the wanted names before the index's rules are applied, since the link rule is an `lstat` per file and a failing run names a handful of files out of however many the tree holds.
    static func visiblePaths(named names: Set<String>, atRoot root: URL) -> [String] {
        guard let config = try? SiftConfig.load(repoRoot: root),
              let listing = try? GitContext(repoRoot: root).visibleSwiftFiles()
        else {
            return []
        }
        let enumerator = FileEnumerator(repoRoot: root, config: config)
        return listing.filter { path in
            names.contains(String(path.split(separator: "/").last ?? "")) && enumerator.isIndexable(relativePath: path)
        }
    }

    /// What a printed location amounts to: the key it reduces to, and the path it was actually written with.
    ///
    /// The two are separate because they answer different questions. The key is the filename and the line, since one file reaches this type spelled several ways — bare from Swift Testing, absolute from XCTest — and the lookup has to be indifferent to which arrived. The path is what the log *said*, which the key throws away, and it is what ``places(_:at:under:)`` checks the resolution against.
    struct Site {
        let path: String
        let file: String
        let line: Int
    }

    /// The site a printed location names — `ChartGridTests.swift:22:9`, `/Users/dev/Repo/Tests/LibTests/ChartGridTests.swift:22` and `Tests/LibTests/ChartGridTests.swift:22:9` all reduce to the same key and keep their own paths.
    static func site(of location: String) -> Site? {
        let parts = location.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 2, let line = Int(parts[1]), line > 0 else {
            return nil
        }
        let file = String(parts[0].split(separator: "/").last ?? "")
        return file.isEmpty ? nil : Site(path: String(parts[0]), file: file, line: line)
    }

    static func key(of location: String) -> String? {
        site(of: location).map { key(file: $0.file, line: $0.line) }
    }

    static func key(file: String, line: Int) -> String {
        "\(file):\(line)"
    }
}

extension RunFailureSites.Declaration {
    /// The innermost declaration in `file` whose source range contains `line`, or `nil` when the line sits outside every declaration.
    ///
    /// Innermost by span, and ties go to the later declaration: symbols arrive in pre-order, so a container always precedes what it contains and the deeper of two equally wide ranges is the one written second. Function bodies hold no recorded declarations of their own, which is what makes the answer for a line inside a test the test itself rather than something nested in it.
    init?(enclosing line: Int, in file: ParsedFile) {
        var chosen: (index: Int, span: Int)?
        for (index, symbol) in file.symbols.enumerated() where symbol.line <= line && line <= symbol.endLine {
            let span = symbol.endLine - symbol.line
            if let chosen, chosen.span < span {
                continue
            }
            chosen = (index, span)
        }
        guard let chosen else {
            return nil
        }
        var names: [String] = []
        var cursor: Int? = chosen.index
        while let index = cursor {
            names.append(file.symbols[index].name)
            cursor = file.symbols[index].parentIndex
        }
        let symbol = file.symbols[chosen.index]
        self.init(
            name: names.reversed().joined(separator: "."),
            path: file.path,
            startLine: symbol.line,
            endLine: symbol.endLine,
            isSwiftTest: AttributeScanner.attributeNames(in: symbol.signature).contains("Test")
        )
    }
}
