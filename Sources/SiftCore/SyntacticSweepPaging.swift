//
// Copyright © Agulhas Labs
//

import Foundation

/// Pages the name-matched lists of a `--refs` sweep answered with no index store, by file, on the offset cursor the store's sweep uses.
///
/// Those sites are then the whole sweep a rename has, so no list of them is cut to a sample or sent to grep; but listing them all at once put hundreds of kilobytes in one answer. So each list pages by file instead: files in path order, a file's lines never cut. **One offset is one boundary for the whole answer**: every list shows its own files `[offset, offset + N)`, N chosen once, the most files that keep every list's rows together within ``byteBudget``, at most ``WhereRenderer/listCap`` and at least one so the cursor always advances. Budgeting the lists one after another instead gave the first the budget and each later one a file, under a cursor of its own, and following either skipped the other's files.
///
/// N depends on every list of the answer, which are rendered one after another, so a list is first a slot in the answer's lines and ``settle(_:)`` fills every slot once the last list is in. A slot is a line that is nothing but indentation and a token this pager made, carrying a nonce drawn when it was created: the answer quotes source text, doc summaries included, which may hold any scalar and digits, but none written before the nonce existed can spell it. A reference type because every list of one answer registers with the same pager.
final class SyntacticSweepPaging {
    /// The rows one answer's lists may spend between them on one page.
    static var byteBudget: Int {
        5 * 1024
    }

    /// Opens a slot's token, so a slot left unfilled reads as nothing an answer otherwise says.
    private static var slotMark: Character {
        "\u{E000}"
    }

    /// Files skipped in every list, from the caller's cursor.
    let offset: Int
    /// Drawn per pager and written into every slot token, so no quoted text can stand for a slot.
    private let nonce = UUID().uuidString
    private var lists: [List] = []
    /// Each slot's token, keyed to the list it stands for.
    private var slots: [String: Int] = [:]
    /// Whether some list runs past one page, before this one or after it, so the sweep is more than this page; known once ``settle(_:)`` has run.
    private(set) var spansPages = false

    /// Whether any list was paged at all, which is what an offset is a cursor into.
    var pagedAnyList: Bool {
        !lists.isEmpty
    }

    init(offset: Int) {
        self.offset = max(0, offset)
    }

    /// The slot for one page of `sites`, each file's rendered as the name-matched block renders it.
    func rows(of sites: [SyntacticCallSite], indent: String = "  ", detail: (SyntacticCallSite) -> String) -> [String] {
        let byPath = Dictionary(grouping: sites, by: \.path)
        return page(files: byPath.keys.sorted(), indent: indent) { NameMatchedSites.rows(byPath[$0] ?? [], detail: detail) }
    }

    /// The slot for one page of `files`, already in path order, each rendered by `render`; a line whatever indentation is written before it keeps for every line it becomes, and only indentation may be.
    func page(files: [String], indent: String, render: (String) -> [String]) -> [String] {
        let skipped = min(offset, files.count)
        let window = files.dropFirst(skipped).prefix(WhereRenderer.listCap).map(render)
        let token = "\(Self.slotMark)\(nonce)-\(lists.count)"
        slots[token] = lists.count
        lists.append(List(fileCount: files.count, skipped: skipped, files: Array(window), indent: indent))
        return [token]
    }

    /// The files every list shows from the offset: the most whose rows, across every list, stay within the budget, and one at least wherever a list has one.
    private var windowSize: Int {
        let deepest = lists.map(\.files.count).max() ?? 0
        var spent = 0
        var size = 0
        while size < deepest {
            let cost = lists.reduce(0) { total, list in
                guard size < list.files.count else { return total }
                return total + list.files[size].reduce(0) { $0 + $1.utf8.count + 1 }
            }
            guard size == 0 || spent + cost <= Self.byteBudget else { break }
            spent += cost
            size += 1
        }
        return size
    }

    /// `lines` with every list's slot filled by its page of the one window, under the markers saying what lies before and after it; the first list cut carries the answer's one continuation.
    func settle(_ lines: [String]) -> [String] {
        guard !lists.isEmpty else { return lines }
        let size = windowSize
        var continued = false
        return lines.flatMap { line -> [String] in
            let prefix = String(line.prefix { $0 == " " })
            guard let index = slots[String(line.dropFirst(prefix.count))] else { return [line] }
            let list = lists[index]
            let indent = list.indent
            var rows = list.skipped > 0 ? ["\(indent)(…\(list.skipped) file\(list.skipped == 1 ? "" : "s") skipped)"] : []
            rows += Array(list.files.prefix(size).joined())
            let hidden = list.fileCount - list.skipped - min(size, list.files.count)
            if hidden > 0 {
                let onward = continued ? "continued by the same offset as above" : "pass offset \(offset + size) to continue"
                rows.append("\(indent)truncated: \(hidden) more file\(hidden == 1 ? "" : "s") — \(onward)")
                continued = true
            }
            if hidden > 0 || list.skipped > 0 {
                spansPages = true
            }
            return rows.map { prefix + $0 }
        }
    }
}

private extension SyntacticSweepPaging {
    /// One list as registered: its size and the rows of the files the window may show.
    struct List {
        let fileCount: Int
        let skipped: Int
        /// The rows of each file from the offset on, up to the file cap.
        let files: [[String]]
        let indent: String
    }
}
