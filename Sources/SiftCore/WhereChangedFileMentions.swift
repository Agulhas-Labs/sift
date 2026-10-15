//
// Copyright © Agulhas Labs
//

import Foundation

/// The lines a semantic `where` adds beside the store's answer for the files written since their build whose sites the store cannot vouch for: the test files outside the build (``WhereUnbuiltMentions``), the new files no store holds a unit for, `new since last build, not in the store, mention the name: Sources/Lib/Depot.swift:1`, and the lines a changed file the store holds writes the name on more often than its build recorded, `written since the build, by name: :6`.
///
/// A new file, tracked by git or not, holds sites no store records, so its lines writing the name in code are listed, the header counts it and the judge's new set holds it, while one writing it only in a string or a comment is neither. A file the store holds keeps the store's account, with its mark where the answer cites it, and a bare-name match alone never lists it: a member name written across unrelated files would bury the answer. Only where it refers to the names in code more often, the file taken whole, than the store's occurrences of them in it at its build (``WrittenNameShape``) are its lines listed, a lower bound found by name, under its mark where the answer shows one and on a line of their own otherwise, and the judge's changed set holds it and the header counts it. The candidates are the files the judge (``OccurrenceFreshness``) finds changed or new from the index's own rows, each against its own build, so a file a later partial build skipped is read, git's view of a file plays no part, a file no build compiles is neither read nor counted, and a refused file or a test file the unbuilt line reads is never read here (Docs/Design.md §2).
struct WhereChangedFileMentions {
    /// Each repo-relative file this lists a line of by name, by the kind the judge finds it, for the header's count of stale files: a new file's lines on the not-in-the-store line, a changed one's as written since the build.
    let listedFiles: [String: FileKind]
    private let lines: [String]
    /// What each changed file the store holds refers to the names in beyond its build's account.
    private let writtenSince: [String: Surplus]
    private let listsEveryLine: Bool
    /// Whether this is the first page of a paged sweep, the only one the line of files without a mark is on.
    private let isFirstPage: Bool
    /// The lines the unbuilt line and the not-in-the-store line list, and the files holding the names they counted without reading.
    private let listed: (mentions: [NameMention], unscanned: Int)

    /// The repo-relative files no store holds a unit for that the not-in-the-store line lists.
    var newFiles: Set<String> {
        Set(listedFiles.filter { $0.value == .new }.keys)
    }

    /// What a listed line from a file the store holds is labelled with.
    static var writtenSinceLabel: String {
        "written since the build, by name: "
    }

    /// Reads the `unbuilt` test files, then the indexed files `judge` finds changed or new since their own build, less those and the `refused` ones, for `names`: every one searched for the names' bytes and the first ``WhereUnbuiltMentions/scanCap`` in path order of those holding them read, the rest holding them counted as not scanned, and, told not to read the files a store holds, none of those, with the unbuilt line and the not-in-the-store line left out of a page past the first (an offset above zero); each file it lists by name is judged again by `judge`, which puts it in the set for its kind.
    init(names: ScannedNames, unbuilt: [String], refused: Set<String>, in index: IndexStore, context: SemanticContext, judge: OccurrenceFreshness, listsEveryLine: Bool, readsStoredFiles: Bool = true, offset: Int = 0) throws {
        self.listsEveryLine = listsEveryLine
        isFirstPage = offset <= 0
        let rootPath = context.repoRoot.path
        // On the first page only, as the `file names:` row is: a later page of a paged sweep repeats neither, and this line's files are bounded while its lines per file are not.
        let unbuiltScan: (mentions: [NameMention], unscanned: Int) = offset > 0 || names.isEmpty || unbuilt.isEmpty ? ([], 0) : WhereUnbuiltMentions.mentionScan(of: names, in: unbuilt, under: rootPath, lexCap: WhereUnbuiltMentions.scanCap)
        let unbuiltLine = WhereUnbuiltMentions.line(listing: unbuiltScan.mentions, unscanned: unbuiltScan.unscanned, listsEveryLine: listsEveryLine)
        guard !names.isEmpty else {
            listedFiles = [:]
            lines = []
            writtenSince = [:]
            listed = ([], 0)
            return
        }
        let excluded = refused.union(unbuilt)
        let newer = try index.fileInventory().values
            .filter { !excluded.contains($0.path) && [.changed, .new].contains(judge.unrecordedKind(of: $0)) }
            .map(\.path)
            .sorted()
        var lexed = 0
        var unscanned = 0
        var notInStore: [NameMention] = []
        var writtenSince: [String: Surplus] = [:]
        for path in newer {
            guard let data = FileManager.default.contents(atPath: rootPath + "/" + path), names.writes(in: data) else { continue }
            // Past the cap, where stored files are read, the store's places for the file are not used: it is only counted.
            if readsStoredFiles, lexed >= WhereUnbuiltMentions.scanCap {
                unscanned += 1
                continue
            }
            let recorded = context.recordedPlaces(of: names, inFile: path)
            if recorded != nil, !readsStoredFiles {
                continue
            }
            guard lexed < WhereUnbuiltMentions.scanCap else {
                unscanned += 1
                continue
            }
            lexed += 1
            if let recorded {
                writtenSince[path] = Self.surplus(of: names, in: data, recorded: recorded)
            } else {
                let codeLines = data.withUnsafeBytes { names.hits(in: $0) }.filter { $0.place == .code }.map(\.line)
                notInStore += Set(codeLines).sorted().map { NameMention(path: path, line: $0) }
            }
        }
        var listedFiles: [String: FileKind] = [:]
        for path in Set(notInStore.map(\.path)).union(writtenSince.keys) {
            listedFiles[path] = judge.kind(ofFile: path)
        }
        self.listedFiles = listedFiles
        self.writtenSince = writtenSince
        let newLine = offset > 0 ? nil : WhereUnbuiltMentions.line(
            listing: notInStore,
            unscanned: unscanned,
            listsEveryLine: listsEveryLine,
            heading: "new since last build, not in the store, mention the name: ",
            unscannedNoun: "new or changed file"
        )
        lines = [unbuiltLine, newLine].compactMap(\.self).flatMap { ["", $0] }
        listed = offset > 0 ? ([], 0) : (unbuiltScan.mentions + notInStore, unbuiltScan.unscanned + unscanned)
    }

    /// Records for the `--files` view each file this lists a line of, a changed one marked so, and the files it counted without reading.
    func record(into collector: WhereFilesCollector) {
        for (path, mentions) in Dictionary(grouping: listed.mentions, by: \.path) {
            collector.recordCode(path: path, lines: mentions.map(\.line))
        }
        for (path, surplus) in writtenSince {
            collector.recordCode(path: path, lines: surplus.lines, state: .modifiedSinceBuild)
        }
        collector.recordNotScanned(listed.unscanned)
    }

    /// `answer` with each listed line of a file the store holds placed under that file's `(file changed since last build)` mark, the first the answer shows, then this type's own lines: the unbuilt line, the not-in-the-store line, and the files the answer shows no mark for.
    func placed(in answer: [String]) -> [String] {
        var placed = answer
        var unmarked: [NameMention] = []
        var unmarkedMoved: [String] = []
        for (path, surplus) in writtenSince.sorted(by: { $0.key < $1.key }) {
            guard let mark = Self.markRow(of: path, in: placed) else {
                if surplus.moved {
                    unmarkedMoved.append("\(path): " + rendered(surplus))
                } else {
                    unmarked += surplus.lines.map { NameMention(path: path, line: $0) }
                }
                continue
            }
            var slot = mark + 1
            while slot < placed.count, placed[slot].hasPrefix("    :") {
                slot += 1
            }
            placed.insert("    " + Self.writtenSinceLabel + rendered(surplus), at: slot)
        }
        let heading = "changed since last build, " + Self.writtenSinceLabel
        var unmarkedLine = isFirstPage ? WhereUnbuiltMentions.line(listing: unmarked, listsEveryLine: listsEveryLine, heading: heading) : nil
        if isFirstPage, !unmarkedMoved.isEmpty {
            unmarkedLine = (unmarkedLine.map { $0 + " · " } ?? heading) + unmarkedMoved.joined(separator: " · ")
        }
        return placed + lines + (unmarkedLine.map { ["", $0] } ?? [])
    }

    /// `:6, :9`, capped at ``WhereRenderer/lineListCap`` with a count of the rest except in a `--refs` sweep, and where lines have moved since the build, `1 more than the build recorded, among :3, :7`.
    private func rendered(_ surplus: Surplus) -> String {
        let cap = listsEveryLine ? Int.max : WhereRenderer.lineListCap
        let shown = surplus.lines.prefix(cap).map { ":\($0)" }.joined(separator: ", ")
        let listed = surplus.lines.count > cap ? shown + ", +\(surplus.lines.count - cap) more" : shown
        return surplus.moved ? "\(surplus.count) more than the build recorded, among " + listed : listed
    }

    /// The index of the first row naming `path` with the changed-since-the-build mark: a file's heading, `  path (n): …`, or a site's, `  caller — path:line …`.
    private static func markRow(of path: String, in answer: [String]) -> Int? {
        guard let marker = OccurrenceState.modifiedSinceBuild.marker else { return nil }
        return answer.firstIndex { row in
            row.contains(marker) && (row.hasPrefix("  \(path) (") || row.contains(" — \(path):"))
        }
    }

    /// What `data` refers to `names` in code beyond `recorded`, the store's places for them at the build, the file taken whole; `nil` where it refers to them no more often now than the build recorded, so a file written back byte for byte, which no record tells apart otherwise, lists nothing.
    ///
    /// References are set against references (``WrittenNameShape``): a declaration is left out, in a file binding a name anywhere, a local, a parameter, a tuple pattern's element or a stored property, only the member accesses are counted, since its bare hits may name what the store never records the uses of (it records a parameter's declaration but none of its uses), and in a file labelling a tuple's element with it, none of those either. A name scanned in a call's shape (``ScannedNames``) takes neither rule, since no local, parameter or tuple label is written that way, and both sides count one population: a recorded place the file still writes one of those names at counts only where that hit is one the scan counts, so a use the scan cannot see, `f` handed on alone, cannot cancel a new call, and only a place whose text has moved since is judged by the symbol recorded there, one place counted once whichever names were recorded at it.
    private static func surplus(of names: ScannedNames, in data: Data, recorded: [String: [ScannedNames.RecordedPlace]]) -> Surplus? {
        var written: [Int] = []
        var stored: [Int] = []
        var shapedPlaces: [ShapedPlace: (resolved: Bool?, guessed: Bool)] = [:]
        let lineStarts = Self.lineStarts(of: data)
        for name in names.names {
            let needle = Array(name.utf8)
            let hits = data.withUnsafeBytes { source in
                names.hits(of: name, in: source).filter { $0.place == .code }.map { (line: $0.line, offset: $0.offset, shape: WrittenNameShape(at: $0.offset, length: needle.count, in: source)) }
            }
            guard names.isBare(name) else {
                let counted = hits.filter { !$0.shape.isDeclaration }
                written += counted.map(\.line)
                let countedOffsets = Set(counted.map(\.offset))
                let writtenOffsets = Set(data.withUnsafeBytes { SwiftMentionLexer.hits(writing: [needle], in: $0) }.map(\.offset))
                for place in recorded[name] ?? [] {
                    let key = ShapedPlace(line: place.line, column: place.column)
                    var judged = shapedPlaces[key] ?? (resolved: nil, guessed: false)
                    if let offset = Self.offset(of: place, lineStarts: lineStarts, count: data.count), writtenOffsets.contains(offset) {
                        judged.resolved = judged.resolved == true || countedOffsets.contains(offset)
                    } else {
                        judged.guessed = judged.guessed || place.isTakenByName
                    }
                    shapedPlaces[key] = judged
                }
                continue
            }
            let bindsLocally = hits.contains { $0.shape.isBinding }
            let labelsTuple = hits.contains { $0.shape.isTupleLabel }
            written += hits.filter { !$0.shape.isDeclaration && (!bindsLocally || $0.shape.isMemberAccess) && !(labelsTuple && $0.shape.isMemberAccess) }.map(\.line)
            stored += recorded[name]?.map(\.line) ?? []
        }
        stored += shapedPlaces.filter { $0.value.resolved ?? $0.value.guessed }.map(\.key.line)
        guard written.count > stored.count else { return nil }
        var excess: [Int: Int] = [:]
        for line in written {
            excess[line, default: 0] += 1
        }
        for line in stored {
            excess[line, default: 0] -= 1
        }
        let gained = excess.filter { $0.value > 0 }
        return Surplus(count: written.count - stored.count, lines: gained.keys.sorted(), moved: gained.values.reduce(0, +) > written.count - stored.count)
    }
}

extension WhereChangedFileMentions {
    /// A place the store recorded a reference at, by its 1-based line and UTF-8 column.
    private struct ShapedPlace: Hashable {
        let line: Int
        let column: Int
    }

    /// The byte offset each 1-based line of `data` starts at, the first line's at index 0.
    private static func lineStarts(of data: Data) -> [Int] {
        var starts = [0]
        for (offset, byte) in data.enumerated() where byte == UInt8(ascii: "\n") {
            starts.append(offset + 1)
        }
        return starts
    }

    /// The byte offset in a file of `count` bytes that `place` names, or `nil` where the file has no such line.
    private static func offset(of place: ScannedNames.RecordedPlace, lineStarts: [Int], count: Int) -> Int? {
        guard place.line >= 1, place.line <= lineStarts.count, place.column >= 1 else { return nil }
        let offset = lineStarts[place.line - 1] + place.column - 1
        return offset < count ? offset : nil
    }
}

extension WhereChangedFileMentions {
    /// How many more references a changed file the store holds writes than its build recorded, and on which lines.
    ///
    /// Where every line the store recorded a reference on still holds as many, the lines holding more are the ones written since, and are listed as such. Where they hold more than the surplus between them, a line has moved, a cited call pushed down by a line written above it among them, and which of them are new no count can say, so they are listed as the lines the surplus is among, and a cited call is never listed as written since.
    private struct Surplus {
        /// The references written now beyond the build's.
        let count: Int
        /// The lines holding more references now than the build recorded on them, ascending.
        let lines: [Int]
        /// Whether those lines hold more than ``count`` between them, so they are where the surplus is rather than what it is.
        let moved: Bool
    }
}
