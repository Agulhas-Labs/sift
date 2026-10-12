//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore

extension InPlaceAnswerer {
    /// The read of one Swift file an answer is computed for: the path it names, the line windows it prints, and the directory it runs in.
    struct DigestRead {
        let path: String
        let windows: [LineWindow]
        let directory: String?
    }

    /// A read of one Swift file, whole or through windows, answered with its digest and — where the windows' lines can be read — the members they overlap beside it, or why it is withheld.
    ///
    /// Where `conditions` is given, a whole digest whose refusal runs past the size budget is answered beside with its first page cut to fit (``pageCut(of:bounded:digest:read:engine:under:onRender:)``), and where the windows print most of the file (``WholeReadWorth/printsMost(_:ofFileAt:in:)``) every candidate carries what the whole read of it is weighed with (``wholeReadBytes(_:in:engine:freshness:under:onRender:)``).
    static func digestAnswer(_ path: String, windows: [LineWindow], in directory: String?, engine: SiftEngine, freshness: Freshness, spelling: CallSpelling, cutting conditions: Conditions? = nil, onRender: (() -> Void)? = nil) throws -> Computation {
        guard try !unparsed(path, in: directory, engine: engine) else { return .withheld(.parseError) }
        guard try !readsLinesNoDigestShows(path, windows: windows, in: directory, engine: engine, spelling: spelling) else { return .withheld(.linesNotShown) }
        guard let digest = try FileDigestParts.wholeFileDigest(path, windows: windows, in: directory, engine: engine, spelling: spelling, wholeIfWindowless: true) else { return .withheld(.notExact) }
        // Framed once the digests have read: the one that found the file stale is the one that reparsed it.
        var bounded = try FileDigestParts.windowAnswers(path, windows: windows, in: directory, engine: engine, spelling: spelling).map { parts -> Computed in
            let lines = parts.map { String($0.call.target.dropFirst(digest.call.target.count + 1)) }.joined(separator: ", ")
            let text = try engine.framing(freshness).syntacticHeaderLine + "\n" + DigestRenderer.joinedAnswers(parts.map(\.text))
            return Computed(calls: parts.map(\.call), root: engine.repoRoot.path, answer: text, standsIn: "these member lines did not weigh themselves against the lines asked for", note: "only the members of lines \(lines) are shown")
        }
        var whole = try Computed(calls: [digest.call], root: engine.repoRoot.path, answer: engine.framing(freshness).syntacticHeaderLine + "\n" + digest.text, standsIn: "this digest did not weigh itself against the file's source")
        // A window over most of the file is weighed as its whole read is: that read computed and chosen here as `cat`
        // of the file would be, and carried by every candidate, the cut included, whichever is served.
        var wholeRead: AnswerBytes?
        if let conditions, !windows.isEmpty, WholeReadWorth.printsMost(windows, ofFileAt: path, in: directory) {
            wholeRead = try wholeReadBytes(path, in: directory, engine: engine, freshness: freshness, under: conditions, onRender: onRender)
        }
        whole.wholeRead = wholeRead
        bounded?.wholeRead = wholeRead
        // A page that stops short of a window's members, or a digest naming them on their type's line alone,
        // accounts for none of what the window prints there: the members stand in, or the read runs — as it does
        // where the window prints `import` lines, which the members leave without a trace.
        guard digest.call.standsInForWindow else {
            guard var members = bounded, !members.calls.contains(where: \.overlapsImports) else { return .withheld(.notExact) }
            members.note = members.note.map { "\($0); \(FileDigestParts.whyNotStandingIn(digest.call))" }
            return .answer(members, bounded: nil)
        }
        var cut = try conditions.flatMap { try pageCut(of: whole, bounded: bounded, digest: digest, read: DigestRead(path: path, windows: windows, directory: directory), engine: engine, under: $0, onRender: onRender) }
        cut?.wholeRead = wholeRead
        return .answer(whole, bounded: bounded, cut: cut)
    }

    /// Whether any of `windows` on the file at `path` reads lines no digest shows — only lines of a declaration's leading doc comment, which a digest carries the summary of at most, or lines whose members answer would name one member and nothing else, which the reader who chose the window already knew — so that window is never answered in place, whatever an answer would save.
    static func readsLinesNoDigestShows(_ path: String, windows: [LineWindow], in directory: String?, engine: SiftEngine, spelling: CallSpelling) throws -> Bool {
        guard !windows.isEmpty,
              let file = try OperandFile.indexed(path, in: directory, engine: engine),
              let ranges = LineWindow.ranges(of: windows, in: file.lines, byteLengths: file.byteLengths)
        else {
            return false
        }
        return try ranges.contains { try engine.liesInLeadingDocComment($0, inFile: file.relative) || engine.namesOneMember($0, inFile: file.relative, options: DigestOptions(spelling: spelling)) }
    }

    /// The bytes the whole read of the file at `path` is weighed with: that read's own answer, computed by ``digestAnswer(_:windows:in:engine:freshness:spelling:cutting:onRender:)`` and chosen by ``served(_:under:)`` as a `cat` of the file is under `conditions` — the whole digest where it fits the size budget, its first page cut to fit otherwise — or `nil` where that read would not be answered.
    static func wholeReadBytes(_ path: String, in directory: String?, engine: SiftEngine, freshness: Freshness, under conditions: Conditions, onRender: (() -> Void)?) throws -> AnswerBytes? {
        // A trial: an answer it finds over the budget is reported by the read that serves it, not by this one.
        let trial = conditions.withoutOversizedReport
        let computation = try digestAnswer(path, windows: [], in: directory, engine: engine, freshness: freshness, spelling: trial.spelling, cutting: trial, onRender: onRender)
        guard case let .success((computed, reason)) = served(computation, under: trial) else { return nil }
        return wholeReadBytes(of: computed, served: reason.served)
    }

    /// What ``WholeReadWorth`` weighs `computed`, served in `served` bytes, with: the whole read's bytes it carries where it answers windows over most of a file, its own where it is a whole read of one file, and `nil` otherwise.
    static func wholeReadBytes(of computed: Computed, served: Int) -> AnswerBytes? {
        if let wholeRead = computed.wholeRead {
            return wholeRead
        }
        guard computed.calls.count == 1, computed.calls[0].fileLines != nil else { return nil }
        return AnswerBytes(served: served, source: computed.calls[0].source)
    }

    /// `computed` framed as the refusal that carries it: the opening line, the answer and a closing line stating its size against the source it stands in for.
    ///
    /// Several windows of one file share one display call, `digest F.swift`, deduplicated: the note beside it, not a second backtick, is what says there is more than one range.
    static func framed(_ computed: Computed, note: String?, under conditions: Conditions) -> (Computed, InPlaceAnswer.Refusal) {
        var seen = Set<String>()
        let displayed = computed.calls.map { $0.displaySpelled(serverGone: conditions.serverGone) }.filter { seen.insert($0).inserted }
        let written = { (source: Int?) in InPlaceAnswer.reason(calls: displayed, answer: computed.answer, source: source, standsIn: computed.standsIn, wholeCommand: conditions.wholeCommand, lookups: conditions.lookups, note: note, rerun: conditions.wholeCommand && conditions.lookups == 1 ? computed.rerun : nil, teed: conditions.teedFiles) }
        let refusal = written(computed.source)
        // Only an answer that weighs a read is withheld for want of a closing line stating its own size: one
        // that stands in for a few printed lines, a declaration grep's, is still worth serving, and where no
        // line can price it truly it closes on the line that claims no saving.
        return (computed, refusal.statesItsSize || computed.weighsRead ? refusal : written(nil))
    }

    /// The first page of the file's digest cut to the most member lines that keep its whole refusal inside the size budget, or `nil` where the read does not end as `overSize`, the digest is the file's own source, or no such page may stand in for the read.
    ///
    /// Computed only where the candidates, uncut, are refused as `overSize`, so a read that ends any other way renders nothing extra for its own answer; a window over most of its file is asked once more for the whole read it is weighed against (``WholeReadWorth``), and pays that read's renders, a page cut included where the whole read's answer needs one. The page size starts from an estimate (the page lines the room the framing leaves holds, at the whole answer's bytes per line) and widens by doubling steps until a fitting and a non-fitting size bracket it, then bisects: a page's size only grows with its lines, so the largest page that fits is the one that stays. Each probe is one render of the digest, and the closure given is told of each. Where the read is a window, the page has to reach every member the window overlaps, which a smaller page reaches no further than a larger one, so only the largest is asked.
    static func pageCut(
        of whole: Computed,
        bounded: Computed?,
        digest: (call: ComputedCall, text: String),
        read: DigestRead,
        engine: SiftEngine,
        under conditions: Conditions,
        onRender: (() -> Void)? = nil
    ) throws -> Computed? {
        guard case .failure(.overSize) = chosen([whole] + (bounded.map { [$0] } ?? []), under: conditions.withoutOversizedReport),
              SourcePassthrough.fileVerdict(in: digest.text)?.servedSource != true
        else { return nil }
        // Whatever stands above the digest in the whole answer, the freshness header, stands above the page.
        let header = String(whole.answer.dropLast(digest.text.count))
        let probe = { (size: Int) -> Computed? in
            onRender?()
            return try FileDigestParts.wholeFileDigest(read.path, windows: read.windows, in: read.directory, engine: engine, spelling: conditions.spelling, pageSize: size, checkingReach: false).map { paged in
                Computed(calls: [paged.call], root: whole.root, answer: header + paged.text, standsIn: whole.standsIn)
            }
        }
        // `fits` is the largest page size known to fit, `over` the least known not to: the whole digest does not fit, and
        // is a page of every member line it lists where the read names no window, of every face's size otherwise.
        var (fits, over) = (0, read.windows.isEmpty ? max(digest.text.split(separator: "\n").count, 2) : DigestOptions().pageSize)
        let framing = framed(whole, note: whole.note, under: conditions).1.served - whole.answer.utf8.count
        let room = max(conditions.sizeBudget - framing, 0)
        var size = min(max(over * room / max(whole.answer.utf8.count, 1), 1), over - 1)
        var step = 1
        var cut: Computed?
        while over - fits > 1 {
            if !(fits + 1 ... over - 1).contains(size) {
                size = (fits + over) / 2
            }
            if let page = try probe(size), framed(page, note: nil, under: conditions).1.served <= conditions.sizeBudget {
                (fits, cut) = (size, page)
                size += step
            } else {
                over = size
                size -= step
            }
            step *= 2
        }
        guard var cut else { return nil }
        // A window is reached once, by the page that stays: no smaller page reaches further.
        if !read.windows.isEmpty {
            guard let file = try OperandFile.indexed(read.path, in: read.directory, engine: engine),
                  let ranges = LineWindow.ranges(of: read.windows, in: file.lines, byteLengths: file.byteLengths)
            else { return nil }
            var call = cut.calls[0]
            call.reachesWindow = try ExactAnswer.firstDigestPageReaches(ranges, in: engine, path: file.relative, spelling: conditions.spelling, pageSize: fits)
            call.placesWindow = digest.call.placesWindow
            guard call.standsInForWindow else { return nil }
            cut = Computed(calls: [call], root: cut.root, answer: cut.answer, standsIn: cut.standsIn)
        }
        return cut
    }

    /// Whether the file a read names is indexed with a parse error — never answered in place, whole or bounded, since its digest is not the file and the read is the one look that shows the error.
    static func unparsed(_ path: String, in directory: String?, engine: SiftEngine) throws -> Bool {
        guard let file = OperandFile.absolute(path, in: directory), let relative = try ExactAnswer.indexedFile(atPath: file, in: engine) else { return false }
        return try ExactAnswer.hasParseErrors(in: engine, path: relative)
    }

    /// The cut page framed as the answer served, where it may stand in for the read the whole digest was over the budget for; `nil` where it may not.
    ///
    /// It has to state its own size and fit the budget, leave no `import` line a window prints without a trace, and save at least ``InPlaceAnswer/windowSavingFloor`` against the source it weighed: a page that does not show every line the read asks for is followed by a further call, and a smaller saving does not pay for it.
    static func servedCut(_ cut: Computed?, under conditions: Conditions) -> (Computed, (text: String, served: Int))? {
        guard let cut else { return nil }
        let (computed, refusal) = framed(cut, note: nil, under: conditions)
        guard refusal.statesItsSize, refusal.served <= conditions.sizeBudget,
              !computed.calls.map(\.overlapsImports).contains(true),
              let source = computed.source, source - refusal.served >= InPlaceAnswer.windowSavingFloor
        else { return nil }
        return (computed, (refusal.text, refusal.served))
    }
}

extension InPlaceAnswerer.Conditions {
    /// These conditions with no size report, for a trial run of the choice whose outcome is reported where it is made for good.
    var withoutOversizedReport: InPlaceAnswerer.Conditions {
        var copy = self
        copy.oversized = nil
        return copy
    }
}
