//
// Copyright © Agulhas Labs
//

import Foundation

/// The `not code` section a `where --refs` answer ends with: the places a rename must change that are not code, read from the working tree by ``NonCodeMentions``.
///
/// One header counting each kind over the whole tree on every page, one row per file paged on the answer's one offset, and the `file names:` row on the first page only. Every line and every file name is listed, as the section belongs to the rename sweep. Nothing found is one line saying what was read and what was not, so it never reads as "no need to grep".
struct WhereNonCodeSection {
    /// What a revision's answer says in place of the section, since a revision's comments are not read.
    static var atRevisionLine: String {
        "not code: not read at a revision"
    }

    /// Where an answer that lists code alone points for the places outside it.
    static var pointer: String {
        "where --refs lists comments, strings and Markdown under not code"
    }

    /// What the answers that carry the section themselves say in place of ``pointer``.
    static var listedBelow: String {
        "comments, strings and Markdown are listed under not code below"
    }

    /// What the tree holds of the name outside code.
    let mentions: NonCodeMentions
    /// Whether several owners or a qualified query make the bare name ambiguous, so the header says it may hold other symbols' lines.
    let isAmbiguous: Bool

    /// The name a rename respells for the query's final component, `save` of `save(_:to:)`, or `nil` where it respells none: an initializer, a deinitializer, a subscript or an operator.
    static func bareName(of component: String) -> String? {
        let name = String(component.prefix { $0 != "(" })
        guard let first = name.first, first.isLetter || first == "_", !["init", "deinit", "subscript"].contains(name) else { return nil }
        return name
    }

    /// The section's lines after a blank one: the file rows join the pager's window where asked to, as a no-store sweep's lists do, else show the store's window `[offset, offset + listCap)`.
    func lines(offset: Int, paging: SyntacticSweepPaging, joinsPager: Bool) -> [String] {
        guard !mentions.isEmpty else { return ["", noneLine] }
        var lines = ["", header]
        let files = Dictionary(uniqueKeysWithValues: mentions.files.map { ($0.path, $0) })
        let paths = mentions.files.map(\.path)
        if joinsPager {
            if !paths.isEmpty {
                lines += paging.page(files: paths, indent: "  ", spansTheSweep: false) { path in files[path].map { [row($0)] } ?? [] }
            }
        } else {
            lines += window(of: paths, offset: offset, paging: paging) { path in files[path].map(row) }
        }
        if offset <= 0, !mentions.fileNames.isEmpty {
            lines.append(fileNamesRow)
        }
        // A heading over no row on this page, the file names being on the first page only, is left out.
        return lines.count == 2 ? [] : lines
    }

    /// `not code, by written name — <counts>[; <k> of these lines are also code lines listed above]:`, kinds with none left out.
    var header: String {
        let nouns: [(NonCodeMentions.Kind, String)] = [(.docLink, "DocC-link line"), (.doc, "doc-comment line"), (.comment, "comment line"), (.string, "string-literal line"), (.markdown, "Markdown line")]
        var counts = nouns.compactMap { kind, noun in
            let count = mentions.count(of: kind)
            return count == 0 ? nil : Self.counted(count, noun)
        }
        if !mentions.fileNames.isEmpty {
            let leads = mentions.fileNames.count { $0.isLead }
            let lead = leads == 0 ? "" : leads == 1 ? " (1 a lead)" : " (\(leads) leads)"
            counts.append(Self.counted(mentions.fileNames.count, "file name") + lead)
        }
        let scope = isAmbiguous ? "; may include same-named symbols'" : ""
        let also = mentions.codeLines
        let overlap = also == 0 ? "" : also == 1 ? "; 1 of these lines is also a code line listed above" : "; \(also) of these lines are also code lines listed above"
        return "not code, by written name\(scope) — \(counts.joined(separator: ", "))\(overlap):"
    }

    /// The one line a tree holding the name nowhere outside code gets, naming what was read and what was not.
    var noneLine: String {
        "not code, by written name — none in the \(mentions.swiftFilesRead) Swift and \(mentions.markdownFilesRead) Markdown files read; storyboards, xibs, plists, string catalogs and project files not read"
    }

    /// `  <path> (<n>): DocC <line>, … · doc … · comment … · string …`; a Markdown file's lines are bare numbers after its DocC links.
    func row(_ file: NonCodeMentions.File) -> String {
        let groups: [String?] = file.isMarkdown
            ? [Self.listed(file.lines(of: .docLink)).map { "DocC " + $0 }, Self.listed(file.lines(of: .markdown))]
            : [("DocC", .docLink), ("doc", .doc), ("comment", .comment), ("string", .string)].map { (label: String, kind: NonCodeMentions.Kind) in
                Self.listed(file.lines(of: kind)).map { "\(label) \($0)" }
            }
        return "  \(file.path) (\(file.lines.count)): " + groups.compactMap(\.self).joined(separator: " · ")
    }

    /// `  file names: <path>, …`, a lead marked, every one listed: the section is the rename sweep's, which leaves no site to a count.
    private var fileNamesRow: String {
        "  file names: " + mentions.fileNames.map { $0.isLead ? "\($0.path) (a lead)" : $0.path }.joined(separator: ", ")
    }

    /// The store's window of `paths` from `offset`, under the markers saying what lies before and after it; a list past its end asks `paging` whether another list continues.
    private func window(of paths: [String], offset: Int, paging: SyntacticSweepPaging, row: (String) -> String?) -> [String] {
        let pastEnd = paging.pastEnd(ofOutsideList: paths.count)
        let skipped = min(max(0, offset), paths.count)
        var rows: [String] = []
        if PastEndLine.applies(offset: offset, count: paths.count) {
            rows.append("  " + pastEnd)
        } else if skipped > 0 {
            rows.append("  (…\(skipped) file\(skipped == 1 ? "" : "s") skipped)")
        }
        let page = paths.dropFirst(skipped).prefix(WhereRenderer.listCap)
        rows += page.compactMap(row)
        let hidden = paths.count - skipped - page.count
        if hidden > 0 {
            rows.append("  truncated: \(hidden) more file\(hidden == 1 ? "" : "s") — pass offset \(skipped + page.count) to continue")
        }
        return rows
    }

    /// Every line number, comma-separated; `nil` for none.
    private static func listed(_ lines: [Int]) -> String? {
        lines.isEmpty ? nil : lines.map(String.init).joined(separator: ", ")
    }

    private static func counted(_ count: Int, _ noun: String) -> String {
        "\(count) \(noun)\(count == 1 ? "" : "s")"
    }
}
