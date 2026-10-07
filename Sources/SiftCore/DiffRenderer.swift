//
// Copyright © Agulhas Labs
//

/// Renders `sift diff`'s answer from what `DiffGatherer` gathered: every touched file compared, the files it could not break down, the callers of what changed shape, and the tests reaching the changed files.
///
/// Holds no git or index-store access itself (Docs/Design.md's "no I/O framing" rule for anything below the two front ends), the same split `AffectedRenderer`/`DigestRenderer` keep.
///
/// **Every touched file appears.** A Swift file is broken down into its declaration changes, whatever changed outside every declaration, and — the safety net — every hunk of its line diff that neither accounts for; a file the index would not hold is listed with its line counts and the rule that keeps it out; everything else is listed with its line counts. A review answer that let a change read as "unchanged" would be worse than none, because its reader would never look.
struct DiffRenderer {
    static func render(_ input: Input) -> Output {
        if let member = input.options.member {
            return Output(body: DiffMemberRenderer.body(target: member, files: input.files, range: input.range), axis: input.axis, rawDiffBytes: nil)
        }
        let files = input.files.sorted { $0.path < $1.path }
        let entries = files.enumerated().flatMap { index, file in self.entries(for: file, index: index, range: input.range) }
        let offset = input.options.offset
        if offset > 0 {
            // A later page is a continuation of the answer the first page priced — whole, once — so it carries no
            // size line of its own: every page claiming the whole saving would count it once per page.
            var lines = ["diff: \(input.range.described)", continuationLine(offset: offset, entries: entries.count)]
            lines += declarationPage(entries, files: files, offset: offset)
            return Output(body: lines.joined(separator: "\n"), axis: input.axis, rawDiffBytes: nil)
        }
        var lines = ["diff: \(input.range.described)", summaryLine(input)]
        lines += declarationPage(entries, files: files, offset: 0)
        lines += testFileSection(input.files)
        lines += skippedSection(input.notBrokenDown)
        lines += nonSwiftSection(input.nonSwift)
        lines += callerSection(input.callers, range: input.range, workingTreeIsAfterSide: input.workingTreeIsAfterSide)
        if let tests = input.tests {
            lines += testSection(tests, range: input.range)
        }
        let laterPages = stride(from: pageCap, to: entries.count, by: pageCap).map { later in
            (["diff: \(input.range.described)", continuationLine(offset: later, entries: entries.count)]
                + declarationPage(entries, files: files, offset: later)).joined(separator: "\n")
        }
        return Output(body: lines.joined(separator: "\n"), axis: input.axis, rawDiffBytes: input.rawDiffBytes, laterPages: laterPages)
    }

    /// The whole answer as served: the header for this query's axis, any notes under it, the body — and, on a first page, the size line pricing every page.
    ///
    /// The first page prices the whole answer, every later page counted as `--offset` will serve it (header and notes included, a later page's axis being syntactic, since it reads no store); no later page prices it again.
    static func answer(_ output: Output, freshness: Freshness, notes: [String?]) -> String {
        var header = freshness
        header.semantic = output.axis
        let answer = Freshness.placing(notes, under: header.headerLine + "\n" + output.body)
        guard let rawBytes = output.rawDiffBytes else { return answer }
        var later = freshness
        later.semantic = .syntacticOnly
        let laterPageBytes = output.laterPages.map { Freshness.placing(notes, under: later.headerLine + "\n" + $0).utf8.count }
        return priced(answer, rawBytes: rawBytes, laterPageBytes: laterPageBytes)
    }

    /// `answer` with its size line appended, priced against the raw `git diff` for the same range.
    ///
    /// The whole answer is counted — the header, any note under it, this line itself, and every later page a reader follows the `--offset` cursor to (`laterPageBytes`, each page as it will be served) — since a figure that left out part of what is sent would understate the cost in the flattering direction, and the saving is stated once, here, rather than on every page. A saving is stated in tokens at the ratio every other surface states it at (`TokenEstimate`), with the bytes both ways beside it so the arithmetic can be checked (Docs/AnswerContract.md §4); an answer larger than the raw diff says so plainly rather than as a negative percentage.
    static func priced(_ answer: String, rawBytes: Int, laterPageBytes: [Int] = []) -> String {
        guard rawBytes > 0 else { return answer }
        let later = laterPageBytes.reduce(0, +)
        var served = answer.utf8.count + later
        var line = ""
        // The line counts itself, and its own length depends on the figures in it — settle on a length that agrees.
        for _ in 0 ..< 4 {
            line = sizeLine(served: served, raw: rawBytes, pages: laterPageBytes.count + 1)
            let total = answer.utf8.count + 2 + line.utf8.count + later
            if total == served {
                break
            }
            served = total
        }
        return answer + "\n\n" + line
    }
}

extension DiffRenderer {
    /// A Swift file the index would not hold, so not broken down — listed with its counts and the rule that keeps it out.
    struct SkippedFile: Sendable {
        let path: String
        let reason: String
        let stat: GitContext.LineStat?
        var untrackedNow = false
    }

    struct NonSwiftFile: Sendable {
        let path: String
        let renamedFrom: String?
        let stat: GitContext.LineStat?
        var untrackedNow = false
    }

    struct Input {
        let range: DiffRange
        let files: [FileDiff]
        let notBrokenDown: [SkippedFile]
        let nonSwift: [NonSwiftFile]
        let callers: [DiffCallers.Report]
        /// Whether the working tree the callers are read from holds the range's after side — true for the working-tree default, and for a range ending at `HEAD` with no Swift file dirty.
        let workingTreeIsAfterSide: Bool
        /// `affected`'s own output for this same change set — `nil` on a page that does not show it.
        let tests: AffectedRenderer.Output?
        let options: DiffOptions
        let rawDiffBytes: Int
        let axis: SemanticAxis
    }

    struct Output {
        let body: String
        let axis: SemanticAxis
        /// What the answer is priced against, or `nil` for an answer that states no saving (`--member`, or a page past the first).
        let rawDiffBytes: Int?
        /// On the first page, the body of every later page as `--offset` will serve it — counted into the first page's price, never printed here.
        var laterPages: [String] = []
    }

    /// Declaration entries shown on one page before the rest are left to `--offset`.
    static var pageCap: Int {
        100
    }

    /// Files listed per section before the rest are counted instead.
    static var fileListCap: Int {
        40
    }

    /// Test names listed in the test-files section before the rest are counted instead.
    static var testNameCap: Int {
        40
    }

    /// Tests listed before the rest are counted instead — `affected` itself lists them all.
    static var testListCap: Int {
        15
    }
}

// MARK: - Summary and pricing

private extension DiffRenderer {
    static func summaryLine(_ input: Input) -> String {
        let total = input.files.count + input.notBrokenDown.count + input.nonSwift.count
        guard total > 0 else {
            return "nothing changed: no file differs between \(input.range.fromLabel) and \(input.range.to.described)"
        }
        var clauses: [String] = []
        if !input.files.isEmpty {
            let changes = input.files.flatMap(\.changes)
            var counts = [
                "\(changes.count { $0.kind == .removed }) removed",
                "\(changes.count { $0.kind == .changed }) changed",
                "\(changes.count { $0.kind == .added }) added",
            ]
            let moved = changes.count { $0.kind == .moved }
            if moved > 0 {
                counts.append("\(moved) moved")
            }
            var notes: [String] = []
            let outsideOnly = input.files.count { $0.changes.isEmpty && $0.unreadableSides == nil && !$0.identical && $0.reportsChanges }
            if outsideOnly > 0 {
                notes.append("\(outsideOnly) of \(plural(input.files.count, "file")) changed only outside declarations")
            }
            let identical = input.files.count(where: \.identical)
            if identical > 0 {
                notes.append("\(identical) with content unchanged")
            }
            let unreadable = input.files.count { $0.unreadableSides != nil }
            if unreadable > 0 {
                notes.append("\(unreadable) not UTF-8 text")
            }
            let noteText = notes.isEmpty ? "" : "; " + notes.joined(separator: "; ")
            clauses.append("\(plural(input.files.count, "Swift file")) broken down below (declarations: \(counts.joined(separator: ", "))\(noteText))")
        }
        if !input.notBrokenDown.isEmpty {
            clauses.append("\(plural(input.notBrokenDown.count, "Swift file")) not broken down")
        }
        if !input.nonSwift.isEmpty {
            clauses.append("\(plural(input.nonSwift.count, "non-Swift file"))")
        }
        return "\(plural(total, "file")) changed — " + clauses.joined(separator: "; ")
    }

    /// What a page past the first says in place of the summary: which part of the answer it is, and that the rest — the size and saving included — is on the first page.
    static func continuationLine(offset: Int, entries: Int) -> String {
        let pages = (entries + pageCap - 1) / pageCap
        let page = offset / pageCap + 1
        return "continued (page \(page) of \(pages), from declaration entry \(offset + 1) of \(entries)) — the summary, the sections after the declarations, and this answer's size and saving are stated once, on the first page: drop --offset for them"
    }

    static func sizeLine(served: Int, raw: Int, pages: Int) -> String {
        let answer = pages > 1 ? "this answer \(ByteSize.short(served)) across its \(pages) pages" : "this answer \(ByteSize.short(served))"
        let basis = "raw `git diff` \(ByteSize.short(raw)) → \(answer)"
        let ratio = "at \(TokenEstimate.bytesPerToken) bytes a token"
        guard served < raw else {
            return "size: no saving at this size — \(basis), \(TokenEstimate.short(bytes: served - raw)) more, \(ratio); a change this small costs less to read raw"
        }
        let percent = Int((1 - Double(served) / Double(raw)) * 100)
        return "size: \(TokenEstimate.short(bytes: raw - served)) saved — \(basis) (\(percent)% smaller), \(ratio)"
    }

    static func plural(_ count: Int, _ noun: String) -> String {
        "\(count) \(noun)\(count == 1 ? "" : "s")"
    }

    static func statText(_ stat: GitContext.LineStat?) -> String {
        guard let stat else { return "(no line counts)" }
        return stat.binary ? "(binary)" : "+\(stat.added)/-\(stat.removed)"
    }

    static var untrackedNowNote: String {
        "deletion staged, but the file is still on disk, untracked"
    }
}

// MARK: - The declarations page

private extension DiffRenderer {
    /// One line group on the page, and the headings it sits under.
    struct Entry {
        let file: Int
        let group: String?
        let lines: [String]
    }

    static func declarationPage(_ entries: [Entry], files: [FileDiff], offset: Int) -> [String] {
        guard !entries.isEmpty else { return [] }
        guard offset < entries.count else {
            return ["", "(--offset \(offset) is past the last of \(entries.count) declaration entries)"]
        }
        let page = entries[offset ..< min(offset + pageCap, entries.count)]
        var lines: [String] = []
        var currentFile: Int?
        var currentGroup: String?
        for entry in page {
            if entry.file != currentFile {
                lines.append("")
                lines.append(heading(for: files[entry.file]))
                currentFile = entry.file
                currentGroup = nil
            }
            if let group = entry.group, group != currentGroup {
                lines.append("  \(group):")
                currentGroup = group
            }
            lines.append(contentsOf: entry.lines)
        }
        let shown = offset + page.count
        if shown < entries.count {
            let laterFiles = Set(entries[shown...].map(\.file)).count
            lines.append("")
            lines.append("truncated: \(entries.count - shown) more declaration entries across \(plural(laterFiles, "file")) — pass --offset \(shown)")
        }
        return lines
    }

    static func heading(for file: FileDiff) -> String {
        let status = switch file.status {
        case .added: "added"
        case .deleted: "deleted"
        case .modified: "modified"
        case let .renamed(from): "renamed from \(from)"
        case .untrackedNow: untrackedNowNote
        }
        return "\(file.path) (\(status), \(statText(file.lineStat))):"
    }

    static func entries(for file: FileDiff, index: Int, range: DiffRange) -> [Entry] {
        if let sides = file.unreadableSides {
            return [Entry(file: index, group: nil, lines: ["  (not UTF-8 text on the \(sides) side — nothing to parse, so not broken down)"])]
        }
        var entries: [Entry] = []
        if !file.parseErrorSides.isEmpty {
            entries.append(Entry(file: index, group: nil, lines: ["  ⚠ parse errors on the \(file.parseErrorSides.joined(separator: " and ")) side — declarations may be missing from what follows"]))
        }
        if file.identical {
            entries.append(Entry(file: index, group: nil, lines: ["  (content unchanged)"]))
        }
        let byGroup = Dictionary(grouping: file.changes, by: \.containerDisplay)
        for group in byGroup.keys.sorted() {
            let changes = (byGroup[group] ?? []).sorted {
                ($0.newRange ?? $0.oldRange)?.line ?? 0 < ($1.newRange ?? $1.oldRange)?.line ?? 0
            }
            // Two entries under one heading with one subject — overloads whose labels coincide, one removed and
            // one kept — are told apart by their signatures (Docs/AnswerContract.md §6).
            let subjects = Dictionary(grouping: changes, by: subject).filter { $0.value.count > 1 }.keys
            for change in changes {
                let lines = declarationLines(change, range: range, showSignature: subjects.contains(subject(change)))
                entries.append(Entry(file: index, group: group.isEmpty ? "(top level)" : group, lines: lines))
            }
        }
        for change in file.outside {
            for line in outsideLines(change) {
                entries.append(Entry(file: index, group: "outside declarations", lines: [line]))
            }
        }
        for line in lineChangeLines(file.lineChanges) {
            entries.append(Entry(file: index, group: "line changes", lines: [line]))
        }
        return entries
    }

    /// What an entry names: the kind and the written name — for an extension, its whole header, since `extension Array` alone does not say which one.
    static func subject(_ change: DeclarationChange) -> String {
        if change.symbolKind == .extensionKind, let signature = change.newSignature ?? change.oldSignature {
            return SourceSlicer.cut(signature, at: SourceSlicer.signatureCap)
        }
        return "\(change.symbolKind.rawValue) \(change.name)"
    }

    static func declarationLines(_ change: DeclarationChange, range: DiffRange, showSignature: Bool) -> [String] {
        let members = change.memberCount.map { " (\(plural($0, "member")))" } ?? ""
        let condition = (change.newCondition ?? change.oldCondition).map { " [\($0)]" } ?? ""
        let subject = subject(change)
        // A changed signature prints both sides below anyway; everything else carries its one signature inline.
        let inline = showSignature && !(change.kind == .changed && change.signatureChanged)
        let signature = inline ? (change.newSignature ?? change.oldSignature).map { " — \(SourceSlicer.cut($0, at: SourceSlicer.signatureCap))" } ?? "" : ""
        switch change.kind {
        case .added:
            return ["    + \(subject)  \(change.newRange?.described ?? "")\(condition)\(members)\(signature)"]
        case .removed:
            return ["    - \(subject)  \(change.oldRange?.described ?? "") (before \(range.fromLabel))\(condition)\(members)\(signature)"]
        case .moved:
            let note = change.movedIntact ? "moved among its siblings; text unchanged" : "moved among its siblings"
            return ["    ~ \(subject)  \(change.newRange?.described ?? "")\(condition) (\(note))\(signature)"]
        case .changed:
            var lines: [String] = []
            let location = change.newRange?.described ?? ""
            var notes: [String] = []
            if change.textChanged, !change.signatureChanged {
                notes.append("body changed; signature unchanged")
            }
            if let before = change.oldAccess, let after = change.newAccess, !change.signatureChanged {
                notes.append("access \(before.rawValue) → \(after.rawValue)")
            }
            if change.extentChanged {
                notes.append("where it opens or closes moved, so what it holds changed; before \(change.oldRange?.described ?? "")")
            }
            let noteText = notes.isEmpty ? "" : " (\(notes.joined(separator: "; ")))"
            if change.signatureChanged {
                let shown = displayed(old: change.oldSignature ?? "", new: change.newSignature ?? "")
                lines.append("    ~ \(subject)  \(location)\(condition)")
                lines.append("        before: \(shown.old)")
                lines.append("        after:  \(shown.new)")
                if shown.old == shown.new {
                    // Swift calls them equal and a terminal prints them alike; the bytes are what differ.
                    lines.append("        (the same characters in another Unicode normalization — alike on screen, different bytes)")
                }
            } else {
                lines.append("    ~ \(subject)  \(location)\(condition)\(noteText)\(signature)")
            }
            if change.conditionChanged {
                lines.append("        condition: \(change.oldCondition ?? "(none)") → \(change.newCondition ?? "(none)")")
            }
            return lines
        }
    }

    /// Two signatures as printed: whole when short, cut when long — and where cutting both at the same place would print two identical lines over a difference past the cut, both are shown from shortly before the first character that differs.
    static func displayed(old: String, new: String) -> (old: String, new: String) {
        let cap = SourceSlicer.signatureCap
        let cut = (old: SourceSlicer.cut(old, at: cap), new: SourceSlicer.cut(new, at: cap))
        guard SourceText.same(cut.old, cut.new), !SourceText.same(old, new) else { return cut }
        let oldCharacters = Array(old)
        let newCharacters = Array(new)
        var common = 0
        while common < min(oldCharacters.count, newCharacters.count), oldCharacters[common].unicodeScalars.elementsEqual(newCharacters[common].unicodeScalars) {
            common += 1
        }
        let start = max(0, common - cap / 4)
        let window: ([Character]) -> String = { characters in
            SourceSlicer.cut("…" + String(characters[min(start, characters.count)...]), at: cap)
        }
        return (window(oldCharacters), window(newCharacters))
    }

    /// One line per sign per category: what was added, removed, or edited outside every declaration, with its lines.
    static func outsideLines(_ change: OutsideChange) -> [String] {
        let lines: (OutsideChange.Fragment) -> String = { DeclarationRange(line: $0.line, endLine: max($0.line, $0.endLine)).described }
        switch change.category {
        case .imports, .conditions:
            return change.edited.map { edit in
                SourceText.same(edit.old.text, edit.new.text)
                    ? "    ~ \(edit.new.text)  \(lines(edit.new)) (moved; before \(lines(edit.old)))"
                    : "    ~ \(edit.old.text) → \(edit.new.text)  \(lines(edit.new))"
            }
                + change.removed.map { "    - \($0.text)  (before \(lines($0)))" }
                + change.added.map { "    + \($0.text)  \(lines($0))" }
        case .deinitializers, .macroExpansions:
            return change.edited.map { edit in
                SourceText.same(edit.old.text, edit.new.text)
                    ? "    ~ \(edit.new.label ?? "")  \(lines(edit.new)) (moved; before \(lines(edit.old)))"
                    : "    ~ \(edit.new.label ?? "")  \(lines(edit.new))"
            }
                + change.removed.map { "    - \($0.label ?? "")  (before \(lines($0)))" }
                + change.added.map { "    + \($0.label ?? "")  \(lines($0))" }
        case .comments, .topLevelCode, .other:
            let noun = switch change.category {
            case .comments: "comments or doc comments"
            case .topLevelCode: "top-level code"
            default: "other text"
            }
            var lines: [String] = []
            if !change.removed.isEmpty {
                lines.append("    - \(noun)  (before \(lineList(change.removed.map { DeclarationRange(line: $0.line, endLine: $0.endLine) })))")
            }
            if !change.added.isEmpty {
                lines.append("    + \(noun)  \(lineList(change.added.map { DeclarationRange(line: $0.line, endLine: $0.endLine) }))")
            }
            return lines
        }
    }

    /// The line diff's hunks nothing above accounts for: those whose bytes name them (whitespace, line endings, a byte-order mark, a normalization) one line per kind, and every other one on a line of its own, with its lines.
    static func lineChangeLines(_ changes: [LineChange]) -> [String] {
        var lines: [String] = []
        let named: [(kind: LineChange.Kind, text: String)] = [
            (.byteOrderMark(added: true), "+ byte-order mark"),
            (.byteOrderMark(added: false), "- byte-order mark"),
            (.whitespace, "~ whitespace only"),
            (.normalization, "~ the same characters in another Unicode normalization"),
        ]
        let endings = changes.compactMap { change -> String? in
            if case let .lineEndings(direction) = change.kind {
                return direction
            }
            return nil
        }
        if !endings.isEmpty {
            let direction = Set(endings).count == 1 ? endings[0] : ""
            lines.append("    ~ line endings\(direction)  \(sideList(changes.filter { if case .lineEndings = $0.kind { true } else { false } }))")
        }
        for (kind, text) in named {
            let ofKind = changes.filter { $0.kind == kind }
            if !ofKind.isEmpty {
                lines.append("    \(text)  \(sideList(ofKind))")
            }
        }
        for change in changes where change.kind == .unnamed {
            lines.append("    ? other changes at \(spanText(change)) (not broken down)")
        }
        return lines
    }

    /// `lines 12–14`, `before-side lines 11–12`, or both, for one hunk.
    static func spanText(_ change: LineChange) -> String {
        let text: (DeclarationRange) -> String = { $0.line == $0.endLine ? "line \($0.line)" : "lines \($0.line)–\($0.endLine)" }
        return switch (change.old, change.new) {
        case let (old?, new?): "\(text(new)), before-side \(text(old))"
        case let (nil, new?): text(new)
        case let (old?, nil): "before-side \(text(old))"
        case (nil, nil): "no lines"
        }
    }

    /// Each hunk's after-side lines, and — for a hunk with none — its before-side lines.
    static func sideList(_ changes: [LineChange]) -> String {
        let after = changes.compactMap(\.new)
        let before = changes.filter { $0.new == nil }.compactMap(\.old)
        return [after.isEmpty ? nil : lineList(after), before.isEmpty ? nil : "(before \(lineList(before)))"].compactMap(\.self).joined(separator: " ")
    }

    /// Every line, adjacent and overlapping ones merged into one range — never cut to a count, since a line the answer does not print is a change the reader cannot find.
    static func lineList(_ ranges: [DeclarationRange]) -> String {
        var merged: [DeclarationRange] = []
        for range in ranges.sorted(by: { ($0.line, $0.endLine) < ($1.line, $1.endLine) }) {
            if let last = merged.last, range.line <= last.endLine + 1 {
                merged[merged.count - 1] = DeclarationRange(line: last.line, endLine: max(last.endLine, range.endLine))
            } else {
                merged.append(range)
            }
        }
        return merged.map(\.described).joined(separator: ", ")
    }
}

// MARK: - The sections after the page

private extension DiffRenderer {
    /// The test names added, removed and changed in test files — shape-only, and saying so in its heading.
    static func testFileSection(_ files: [FileDiff]) -> [String] {
        var lines: [String] = []
        var listed = 0
        var unlisted = 0
        for file in files.sorted(by: { $0.path < $1.path }) {
            guard TestFileRecognition.isTestFile(imports: file.newImports) || TestFileRecognition.isTestFile(imports: file.oldImports) else { continue }
            var entries: [(name: String, marker: String)] = []
            for change in file.changes where change.kind != .moved {
                if TestFileRecognition.isTestFunction(change, oldImports: file.oldImports, newImports: file.newImports) {
                    entries.append((change.name, marker(for: change.kind)))
                }
                // A wholly added/removed container (a deleted suite, say) reports as one line in the
                // declarations section, `memberCount` and all — but a deleted suite is not a suite that lost
                // no tests, so its own test names still surface here individually.
                for nested in change.nestedFunctions
                    where TestFileRecognition.isTestFunction(name: nested.name, signature: nested.signature, isTestFile: true)
                {
                    entries.append((nested.name, marker(for: change.kind)))
                }
            }
            entries.sort { $0.name == $1.name ? $0.marker < $1.marker : $0.name < $1.name }
            guard !entries.isEmpty else { continue }
            let room = max(0, testNameCap - listed)
            guard room > 0 else {
                unlisted += entries.count
                continue
            }
            lines.append("  \(file.path):")
            lines.append(contentsOf: entries.prefix(room).map { "    \($0.marker) \($0.name)" })
            listed += min(room, entries.count)
            unlisted += max(0, entries.count - room)
        }
        guard !lines.isEmpty else { return [] }
        if unlisted > 0 {
            lines.append("  truncated: \(unlisted) more test names — the declaration entries (`--offset`) carry each file's changes, and `sift digest <path>` a file's tests")
        }
        return ["", "test files — tests recognised by shape: `@Test`, or `test…` in a file importing XCTest (a test class whose base is declared elsewhere is not recognised):"] + lines
    }

    static func marker(for kind: DeclarationChange.Kind) -> String {
        switch kind {
        case .added: "+"
        case .removed: "-"
        case .changed, .moved: "~"
        }
    }

    static func skippedSection(_ files: [SkippedFile]) -> [String] {
        guard !files.isEmpty else { return [] }
        let sorted = files.sorted { $0.path < $1.path }
        var lines = ["", "swift files not broken down (\(files.count)) — the index never holds them, so their declarations are not compared:"]
        lines += sorted.prefix(fileListCap).map { file in
            let note = file.untrackedNow ? " (\(untrackedNowNote))" : ""
            return "  \(file.path)  \(statText(file.stat))\(note) — not indexed: \(file.reason)"
        }
        if sorted.count > fileListCap {
            lines.append("  truncated: \(sorted.count - fileListCap) more files")
        }
        return lines
    }

    static func nonSwiftSection(_ files: [NonSwiftFile]) -> [String] {
        guard !files.isEmpty else { return [] }
        let sorted = files.sorted { $0.path < $1.path }
        var lines = ["", "non-swift files (\(files.count)):"]
        lines += sorted.prefix(fileListCap).map { file in
            let note = file.untrackedNow ? " (\(untrackedNowNote))" : ""
            return "  \(file.path)  \(statText(file.stat))\(file.renamedFrom.map { " (renamed from \($0))" } ?? "")\(note)"
        }
        if sorted.count > fileListCap {
            lines.append("  truncated: \(sorted.count - fileListCap) more files")
        }
        return lines
    }

    /// Callers of the members whose signature changed or that were removed — resolved or name-matched, and saying which on every member.
    static func callerSection(_ reports: [DiffCallers.Report], range: DiffRange, workingTreeIsAfterSide: Bool) -> [String] {
        guard !reports.isEmpty else { return [] }
        let tree = workingTreeIsAfterSide
            ? "read from the working tree, whose Swift files are this range's after side"
            : "read from the working tree as it stands, which is not \(range.to.described), so callers there may differ"
        var lines = ["", "callers of the \(plural(reports.count, "member")) this range removed or changed the signature of — \(tree):"]
        // In path order whatever order they were gathered in: the cap keeps the first twenty, and which twenty must
        // not depend on which file finished parsing first.
        let ordered = reports.sorted { ($0.target.path, $0.target.label, $0.target.line) < ($1.target.path, $1.target.label, $1.target.line) }
        for report in ordered.prefix(DiffCallers.memberCap) {
            let sign = report.target.removed ? "-" : "~"
            // A property, a subscript or an enum case is used rather than called; a subscript's sites come from the store alone — it has no name-matched fallback — so they are always uses.
            let uses = report.target.kind.isUsedRatherThanCalled
            let noun = uses ? (one: "use", many: "uses") : (one: "call site", many: "call sites")
            let count = report.sites.count == 1 ? "1 \(noun.one)" : "\(report.sites.count) \(noun.many)"
            if let reason = report.unresolvedBecause {
                if let searched = report.searchedName {
                    lines.append("  \(sign) \(report.target.label) — name-matched on \"\(searched)\" (\(reason)): \(count)")
                } else {
                    lines.append("  \(sign) \(report.target.label) — not resolved (\(reason)), and no name to match: a subscript is used as x[…], which spells no name")
                }
            } else {
                lines.append("  \(sign) \(report.target.label) — resolved by the index store: \(count)")
            }
            for site in report.sites.prefix(DiffCallers.siteCap) {
                lines.append(report.unresolvedBecause == nil
                    ? "      \(site.enclosing) — \(site.path):\(site.line)\(site.through.map { " — via \($0)" } ?? "")\(site.marker)"
                    : "      \(site.path):\(site.line)  in \(site.enclosing)")
            }
            if report.sites.count > DiffCallers.siteCap {
                lines.append("      truncated: \(report.sites.count - DiffCallers.siteCap) more — `sift where \(report.target.label)` lists them all")
            }
            // As `where` says it: with no site listed, "0 call sites" of a function reached only as `x.f` reads as unused.
            if report.sites.isEmpty {
                lines += SyntacticCallerFallback.nameOnlyLines(
                    report.nameOnly,
                    cap: DiffCallers.siteCap,
                    truncationPointer: "`sift where \(report.target.label)` lists them all",
                    initializerOf: report.target.kind == .initializer ? report.searchedName : nil
                ).map { "      \($0)" }
            }
            // The store records no call where a property wrapper is written on a function's parameter, so those attribute sites are listed by name beside a resolved initializer's answer, and "0 call sites" is never the whole story over one.
            if let type = report.searchedName {
                let marker = { (site: SyntacticCallSite) in report.staleFiles.contains(site.path) ? OccurrenceState.modifiedSinceBuild.marker ?? "" : "" }
                let blocks = WrapperAttributeSites.lines(report.wrapperSites, named: type, for: report.target.label, cap: DiffCallers.siteCap, marker: marker)
                    + WrapperAttributeSites.lines(report.unassignedWrapperSites, named: type, for: WrapperAttributeSites.unassignedOwner(report.wrapperTypePath ?? type), cap: DiffCallers.siteCap, marker: marker)
                lines += blocks.filter { !$0.isEmpty }.map { "      \($0)" }
            }
        }
        if reports.count > DiffCallers.memberCap {
            lines.append("  truncated: \(reports.count - DiffCallers.memberCap) more members — `sift where <Type.member>` answers each")
        }
        if reports.contains(where: { $0.unresolvedBecause != nil && $0.searchedName != nil }) {
            lines.append("  a name match is not a symbol: same-named members of other types, and locals and parameters of that name, are included; dynamically dispatched calls are missed")
        }
        // The gap `where` states beside a property's or a case's uses: "resolved by the index store: 0 uses" of a field
        // only a Codable conformance encodes reads as dead code.
        if reports.contains(where: { $0.unresolvedBecause == nil && ($0.target.kind == .variable || $0.target.kind == .enumCase) }) {
            lines.append("  a use the index store resolves is one written in code: a synthesized conformance's (Equatable, Hashable, Codable, CaseIterable, init(rawValue:)) and one made by name at runtime are not recorded, so a count of uses is not proof a member is unused")
        }
        return lines
    }

    /// The tests `affected` found reaching the changed files, in a bounded section that says exactly what it is — and points at the command whose answer carries the limits and the runner arguments.
    static func testSection(_ tests: AffectedRenderer.Output, range: DiffRange) -> [String] {
        let walkedOn = AffectedBlindSpots.walkedOnClause(tests.walkedOn)
        let source = "from `sift affected`: every declaration in each changed file, not only the changed lines, followed \(plural(tests.depth, "hop"))\(walkedOn)"
        guard !tests.reached.isEmpty else {
            return [
                "",
                "tests reaching the changed files — \(source) — none found, which is not evidence that none is affected: `\(range.affectedCommand)` lists the \(tests.limitCount) ways its walk can miss one.",
            ]
        }
        let targets = Set(tests.reached.map(\.target)).count
        var lines = [
            "",
            "tests reaching the changed files (\(plural(tests.reached.count, "test")) in \(plural(targets, "target"))) — \(source) — a lower bound, never a list of what is safe to skip:",
        ]
        for test in tests.reached.prefix(testListCap) {
            var detail = [plural(test.depth, "hop")]
            if test.nameMatch {
                detail.append("name match")
            }
            lines.append("  \(test.described) — \(detail.joined(separator: ", ")) — \(test.location)")
        }
        if tests.reached.count > testListCap {
            lines.append("  truncated: \(tests.reached.count - testListCap) more tests")
        }
        lines.append("what this walk cannot see (\(tests.limitCount) ways), and the runner arguments: `\(range.affectedCommand)`")
        return lines
    }
}
