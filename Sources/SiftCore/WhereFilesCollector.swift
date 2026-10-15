//
// Copyright © Agulhas Labs
//

import Foundation

/// What a `--refs` sweep names, file by file, for its files view (`where X --files`, Docs/Design.md §3, *The files view*).
///
/// One instance is threaded through one render of the sweep, as ``SyntacticSweepPaging`` is: each section that names a file records it from its full data, before any cap or page cuts its list, so the view holds the files of every page of the sweep from a render of its first. Code lines are a set per file, never a sum, since two sections can list one line (a property's uses and its references).
final class WhereFilesCollector {
    /// Files listed on one page of the view; the same offset cursor and truncation marker as the sweep's lists.
    static var filesListCap: Int {
        100
    }

    /// Owners the heading names before it counts the rest.
    static var namedOwnerCap: Int {
        3
    }

    private(set) var files: [String: File] = [:]
    private var owners: [String] = []
    private var extensionOwners: [String] = []
    private var siblings: Set<String> = []
    private var generatedLines = 0
    private var notScanned = 0
    private var aliasFoldCapped = false
    private var lowerBoundReasons: [String] = []
    /// Whether a section listed sites matched by written name, which may include same-named symbols.
    private(set) var byWrittenName = false
    /// The declarations section's heading, kept in the view where the query has several owners.
    private(set) var declarationsHeading: String?
    /// The headings of the sections the view replaces that can print with no row under them on a page.
    private(set) var replacedHeadings: Set<String> = []

    /// Whether the sweep named any file, which is what makes its answer a sweep.
    var isEmpty: Bool {
        files.isEmpty
    }

    /// The names the heading gives the query: its declarations', else its extensions'.
    var ownerNames: [String] {
        owners.isEmpty ? extensionOwners : owners
    }

    func recordCode(path: String, lines: some Sequence<Int>, state: OccurrenceState = .live) {
        var file = files[path] ?? File()
        file.codeLines.formUnion(lines)
        if file.state.isLive {
            file.state = state
        }
        files[path] = file
    }

    /// A declaration or extension of the query, held in `path`; `owner` is its qualified name.
    func recordDeclaration(path: String, owner qualified: String?, isExtension: Bool) {
        files[path, default: File()].declares = true
        guard let qualified else { return }
        let owner = Self.owner(of: qualified)
        if isExtension {
            if !extensionOwners.contains(owner) {
                extensionOwners.append(owner)
            }
        } else if !owners.contains(owner) {
            owners.append(owner)
        }
    }

    /// The owner a qualified name counts as: the name less its parameter labels, so the overloads of one function are one owner, not several.
    static func owner(of qualified: String) -> String {
        guard qualified.hasSuffix(")"), let open = qualified.lastIndex(of: "(") else { return qualified }
        return String(qualified[..<open])
    }

    /// Every one of the query's declarations, its extensions included.
    func recordDeclarations(_ rows: [SymbolRow], qualifiedName: (SymbolRow) throws -> String) rethrows {
        for row in rows {
            try recordDeclaration(path: row.path, owner: qualifiedName(row), isExtension: row.kind == .extensionKind)
        }
    }

    func recordDeclarationsHeading(_ heading: String) {
        declarationsHeading = heading
    }

    func recordNotCode(_ mentions: NonCodeMentions) {
        for file in mentions.files {
            files[file.path, default: File()].notCodeLines += file.lines.count
        }
        // A file held only by its name gets a row of its own, which reads `file name`.
        for name in mentions.fileNames where files[name.path] == nil {
            files[name.path] = File()
        }
    }

    /// A reference block's heading facts: the wrapper siblings its lines went through and the macro-generated lines it left out.
    func recordReferenceDetails(siblings: [String], generatedLines: Int, heading: String) {
        self.siblings.formUnion(siblings)
        self.generatedLines += generatedLines
        replacedHeadings.insert(heading)
    }

    /// The typealias fold stopped at ``WhereRenderer/typealiasFoldCap``: uses written as an alias past it are in no section, so the set is a lower bound, as the verdict the view drops says.
    func recordAliasFoldCapped() {
        aliasFoldCapped = true
    }

    /// A target or test files the store never built: uses there are in no section, so the set is a lower bound, as the verdict the view drops says.
    ///
    /// The reasons are the verdict's own words.
    func recordLowerBound(_ reasons: [String]) {
        for reason in reasons where !lowerBoundReasons.contains(reason) {
            lowerBoundReasons.append(reason)
        }
    }

    /// Files holding the name that a scan counted without reading.
    func recordNotScanned(_ count: Int) {
        notScanned += count
    }

    /// Every site a name-matched section lists, past its cap and its page too, each one's file judged by `state`; matched by written name, which the heading says.
    func recordSites(_ sites: some Sequence<SyntacticCallSite>, state: (SyntacticCallSite) -> OccurrenceState = { _ in .live }) {
        for site in sites {
            byWrittenName = true
            recordCode(path: site.path, lines: [site.line], state: state(site))
        }
    }

    /// The lines a name-matched section lists in each file, past its file cap and its per-file cap too.
    func recordWrittenLines(_ linesByPath: [String: Set<Int>]) {
        for (path, lines) in linesByPath where !lines.isEmpty {
            byWrittenName = true
            recordCode(path: path, lines: lines)
        }
    }

    // MARK: Rendering

    /// What of the sweep's own answer the view keeps: every line that is no row and heads none (the notes saying the answer is degraded or incomplete), less the `used by` verdict and the headings it replaces; the declarations block too where the query has several owners.
    func kept(from answer: [String]) -> [String] {
        let keepsDeclarations = ownerNames.count > 1
        var kept: [String] = []
        var inDeclarations = false
        for (index, line) in answer.enumerated() {
            if line.hasPrefix("  ") {
                if inDeclarations {
                    kept.append(line)
                }
                continue
            }
            inDeclarations = keepsDeclarations && line == declarationsHeading
            let heads = index + 1 < answer.count && answer[index + 1].hasPrefix("  ")
            if inDeclarations || line.isEmpty || !heads && !replacedHeadings.contains(line) && !line.hasPrefix("used by ") {
                kept.append(line)
            }
        }
        return Self.trimmed(kept)
    }

    /// The view's lines for the page starting at `offset`, under `kept`.
    func lines(query: String, kept: [String], offset: Int, cap: Int = WhereFilesCollector.filesListCap) -> [String] {
        let paths = files.keys.sorted()
        var block = kept + ["", heading(query: query, count: paths.count)]
        let skipped = min(max(0, offset), paths.count)
        if PastEndLine.applies(offset: offset, count: paths.count) {
            block.append("  " + PastEndLine.text(offset: offset, count: paths.count, noun: "files"))
        } else if skipped > 0 {
            block.append("  (…\(skipped) file\(skipped == 1 ? "" : "s") skipped)")
        }
        let page = paths.dropFirst(skipped).prefix(cap)
        block += page.map(row)
        let hidden = paths.count - skipped - page.count
        if hidden > 0 {
            block.append("  truncated: \(hidden) more file\(hidden == 1 ? "" : "s") — pass offset \(skipped + page.count) to continue")
        }
        return block
    }

    private func heading(query: String, count: Int) -> String {
        let names = ownerNames
        var subject = names.first ?? query
        if names.count > 1 {
            let more = names.count - Self.namedOwnerCap
            subject = "\(query), \(names.count) owners: " + names.prefix(Self.namedOwnerCap).joined(separator: ", ") + (more > 0 ? ", and \(more) more" : "")
        }
        let code = files.values.count { !$0.codeLines.isEmpty }
        let mentions = files.values.count { $0.notCodeLines > 0 }
        var details = ["\(count) file\(count == 1 ? "" : "s"): \(code) with code sites, \(mentions) with not-code mentions"]
        if !siblings.isEmpty {
            details.append("including \(siblings.sorted().joined(separator: " and "))")
        }
        details += WhereRenderer.driftDetails(states: files.values.map(\.state))
        if generatedLines > 0 {
            details.append("\(generatedLines) more line\(generatedLines == 1 ? "" : "s") a macro generated, not listed")
        }
        if byWrittenName {
            details.append("by written name")
        }
        if notScanned > 0 {
            details.append("\(notScanned) more file\(notScanned == 1 ? "" : "s") holding the name not scanned")
        }
        if aliasFoldCapped {
            details.append("a lower bound: more typealiases than the \(WhereRenderer.typealiasFoldCap) followed")
        }
        if !lowerBoundReasons.isEmpty {
            details.append("a lower bound (\(lowerBoundReasons.joined(separator: "; ")))")
        }
        return "files naming \(subject) (\(details.joined(separator: ", "))):"
    }

    /// `  path (8)`, `  path (52, declares)`, `  path (12, not code 1)`, `  path (file name)`, a stale file's mark after it.
    private func row(_ path: String) -> String {
        let file = files[path] ?? File()
        var parts: [String] = []
        if !file.codeLines.isEmpty {
            parts.append(String(file.codeLines.count))
        }
        if file.declares {
            parts.append("declares")
        }
        if file.notCodeLines > 0 {
            parts.append("not code \(file.notCodeLines)")
        }
        if parts.isEmpty {
            parts.append("file name")
        }
        return "  \(path) (\(parts.joined(separator: ", ")))" + (file.state.marker ?? "")
    }

    /// `lines` without blank runs or blank ends.
    private static func trimmed(_ lines: [String]) -> [String] {
        var result: [String] = []
        for line in lines where !(line.isEmpty && (result.last?.isEmpty ?? true)) {
            result.append(line)
        }
        while result.last?.isEmpty == true {
            result.removeLast()
        }
        return result
    }
}

extension WhereFilesCollector {
    /// What the sweep names in one file.
    struct File: Equatable {
        var codeLines: Set<Int> = []
        var notCodeLines = 0
        var declares = false
        var state = OccurrenceState.live
    }
}

extension WhereRenderer {
    /// The `--files` answer: one render of the sweep's first page with a ``WhereFilesCollector`` attached, which every section records its whole list into, then the collector's files paged; the sweep's own answer wherever it names no file or is not a sweep (`--syntactic`, `--at`).
    func filesOutput(query: String, semantic: SemanticInput, options: WhereOptions, cap: Int = WhereFilesCollector.filesListCap) async throws -> Output {
        var sweep = options
        sweep.filesOnly = false
        sweep.includeReferences = true
        if case .inactive = semantic {
            return try await render(query: query, semantic: semantic, options: sweep)
        }
        guard revision == nil else {
            return try await render(query: query, semantic: semantic, options: sweep)
        }
        let collector = WhereFilesCollector()
        var recording = self
        recording.filesCollector = collector
        sweep.offset = 0
        let first = try await recording.render(query: query, semantic: semantic, options: sweep)
        guard !collector.isEmpty else {
            guard options.offset != 0 else { return first }
            sweep.offset = options.offset
            return try await render(query: query, semantic: semantic, options: sweep)
        }
        let kept = collector.kept(from: first.body.components(separatedBy: "\n"))
        return Output(body: collector.lines(query: query, kept: kept, offset: options.offset, cap: cap).joined(separator: "\n"), axis: first.axis)
    }
}
