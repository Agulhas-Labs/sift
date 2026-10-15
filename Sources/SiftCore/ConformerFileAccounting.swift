//
// Copyright © Agulhas Labs
//

import Foundation

/// The store's conformers block's last line: every Swift file a text search for the protocol's name finds, each counted once in the first class that holds it, the classes summing to the search's count.
///
/// An agent asked for every conformer used to grep the name after the answer only to reconcile the grep's files with it (Docs/Design.md, the store's conformers block), so the line does the reconciling. Only files of the search are counted: a conformer through a typealias, whose file does not write the name, is in no class.
struct ConformerFileAccounting {
    /// The files git shows that write the name, and those it could not read.
    let search: TextSearchFiles
    /// Whether a repo-relative file was changed or created since the build, which the build's records may no longer describe.
    let changedSinceBuild: (String) -> Bool
    /// The files declaring a conformer the block counts, listed or past its cap.
    let conformers: Set<String>
    /// The files declaring the asked protocol or an extension of it.
    let declarations: Set<String>
    /// The files declaring a typealias the answer follows for it.
    let aliases: Set<String>
    /// The files of the `used by` verdict, and under `--refs` of the `references to` section.
    let uses: Set<String>
    /// The files the answer's `not code` section lists, or `nil` where it has none; a lowercase name's section keeps only the backticked mentions, so it lists fewer files than hold the name in comments or strings.
    let notCodeListed: Set<String>?
    /// Whether this is the first page; a later one gives counts and no paths.
    let firstPage: Bool

    /// Files a residue class names before the rest are counted.
    static let namedPerClass = 5

    /// `every Swift file that writes <name> is accounted for (<T>, …): <c> declare a conformer (above)[, …][; <k> could not be read: <paths>]`.
    func line(for name: String) -> String {
        var counts = Counts()
        for file in search.files {
            let path = file.path
            if changedSinceBuild(path) {
                counts.changed.append(path)
            } else if conformers.contains(path) {
                counts.conformers += 1
            } else if declarations.contains(path) {
                counts.declarations += 1
            } else if aliases.contains(path) {
                counts.aliases += 1
            } else if uses.contains(path) {
                counts.uses += 1
            } else {
                switch file.writing {
                case .commentsOrStrings: counts.commentsOrStrings.append(file)
                case .insideLongerName: counts.insideLongerName.append(path)
                case .code: counts.uncounted.append(path)
                }
            }
        }
        let manifests = search.files.contains { SwiftPMManifest.isManifestPath($0.path) } ? ", manifests included" : ""
        var classes = Self.counted(counts.conformers, "\(Self.verb(counts.conformers, "declares", "declare")) a conformer (above)")
        classes += Self.counted(counts.declarations, "\(Self.verb(counts.declarations, "declares or extends", "declare or extend")) it")
        classes += Self.counted(counts.aliases, "\(Self.verb(counts.aliases, "aliases", "alias")) it")
        classes += Self.counted(counts.uses, "\(Self.verb(counts.uses, "uses", "use")) it (used by, above)")
        classes += named(counts.changed, "changed since the build")
        classes += commentsOrStrings(counts.commentsOrStrings)
        classes += named(counts.insideLongerName, "\(Self.verb(counts.insideLongerName.count, "writes", "write")) it only inside a longer name")
        classes += named(counts.uncounted, "\(Self.verb(counts.uncounted.count, "writes", "write")) it in code not counted above")
        let unread = named(search.unreadable, "could not be read").map { "; \($0)" }.joined()
        return "every Swift file that writes \(name) is accounted for (\(search.files.count), a text search of the Swift files git shows\(manifests))\(classes.isEmpty ? "" : ": " + classes.joined(separator: ", "))\(unread)"
    }

    /// The comments-or-strings class: under `--refs` the files the `not code` section lists are counted under it and only the rest named, since that section lists only what it found, not a manifest, a directory the index leaves out, or a lowercase name's unbackticked mention.
    private func commentsOrStrings(_ files: [TextSearchFiles.File]) -> [String] {
        guard !files.isEmpty else { return [] }
        let phrase = "\(Self.verb(files.count, "writes", "write")) it only in comments or strings"
        guard let notCodeListed else { return named(files.map(\.path), phrase) }
        let unlisted = files.filter { !notCodeListed.contains($0.path) }.map(\.path)
        guard !unlisted.isEmpty else { return ["\(files.count) \(phrase) (not code, below)"] }
        let below = files.count - unlisted.count
        return named(unlisted, phrase, of: files.count, aside: below > 0 ? " (\(below) under not code, below)" : "")
    }

    private static func verb(_ count: Int, _ singular: String, _ plural: String) -> String {
        count == 1 ? singular : plural
    }

    /// `<k> <phrase>`, or nothing for a class with no file.
    private static func counted(_ count: Int, _ phrase: String) -> [String] {
        count == 0 ? [] : ["\(count) \(phrase)"]
    }

    /// `<total> <phrase><aside>: <paths>`, at most ``namedPerClass`` of them and then `+<k> more`; on a later page the count alone.
    private func named(_ paths: [String], _ phrase: String, of total: Int? = nil, aside: String = "") -> [String] {
        guard !paths.isEmpty else { return [] }
        let head = "\(total ?? paths.count) \(phrase)\(aside)"
        guard firstPage else { return [head] }
        let rest = paths.count - Self.namedPerClass
        let listed = paths.prefix(Self.namedPerClass).joined(separator: ", ") + (rest > 0 ? ", +\(rest) more" : "")
        return ["\(head): \(listed)"]
    }
}

private extension ConformerFileAccounting {
    struct Counts {
        var changed: [String] = []
        var conformers = 0
        var declarations = 0
        var aliases = 0
        var uses = 0
        var commentsOrStrings: [TextSearchFiles.File] = []
        var insideLongerName: [String] = []
        var uncounted: [String] = []
    }
}

extension ConformerFileAccounting {
    /// What the answer lists for a protocol that its block's accounting counts: the merged conformers block, and the files of the `used by` verdict (under `--refs` with those of `references to`) and of the typealiases it follows.
    struct Listed {
        /// The merged block, or `nil` where the protocol has none of its own: a second protocol of the name keeps the store's block, which carries no line.
        let block: ConformersOnce?
        var uses: Set<String> = []
        var aliases: Set<String> = []
    }
}

extension WhereRenderer {
    /// The last line of the protocol `row`'s merged conformers block; none in the `--files` view, at a revision, which reads no working tree, or where the text search passed its bounds.
    func fileAccounting(of row: SymbolRow, usr: String, listed: ConformerFileAccounting.Listed, options: WhereOptions, context: SemanticContext, occurrences: OccurrenceFreshness) -> [String] {
        guard let block = listed.block, filesCollector == nil, revision == nil, let search = textSearchFiles?(row.name) else { return [] }
        // The `not code` section is keyed on the query's bare name, which is the protocol's own; its files are read from the same reads the search made.
        var notCodeListed: Set<String>?
        if listsNonCode(query: row.name, options: options), let nonCodeMentions {
            notCodeListed = Set(nonCodeMentions(row.name).files.map(\.path))
        }
        let accounting = ConformerFileAccounting(
            search: search,
            changedSinceBuild: occurrences.writtenSinceBuild(file:),
            conformers: block.conformerPaths,
            declarations: Set([row.path] + context.store.extensionSites(ofUSR: usr).map { context.relativePath($0.path) }),
            aliases: listed.aliases,
            uses: listed.uses,
            notCodeListed: notCodeListed,
            firstPage: options.offset <= 0
        )
        return [accounting.line(for: row.name)]
    }

    /// Hands the renderer the working tree's Swift files for the conformers block's file accounting and the `not code` section of `--refs`, each file read once per answer and shared by both.
    mutating func readsWorkingTree(under repoRoot: URL, enumerator: FileEnumerator, bounds: TextSearchFiles.Bounds) {
        let reads = TextSearchFiles.Reads()
        textSearchFiles = { name in
            // Git's listing, not the index's narrowed one; where git cannot list the tree there is no text search to account for.
            guard let listing = try? enumerator.gitListing?() else { return nil }
            return TextSearchFiles.scan(name: name, listing: listing, under: repoRoot, bounds: bounds, reads: reads)
        }
        nonCodeMentions = { name in
            NonCodeMentions.scan(name: name, swiftFiles: enumerator.swiftFiles(), markdownFiles: enumerator.markdownFiles(), under: repoRoot, reads: reads)
        }
    }
}
