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

    /// `computed` framed as the refusal that carries it: the opening line, the answer and a closing line stating its size against the source it stands in for.
    ///
    /// Several windows of one file share one display call, `digest F.swift`, deduplicated: the note beside it, not a second backtick, is what says there is more than one range.
    static func framed(_ computed: Computed, note: String?, under conditions: Conditions) -> (Computed, InPlaceAnswer.Refusal) {
        var seen = Set<String>()
        let displayed = computed.calls.map { $0.displaySpelled(serverGone: conditions.serverGone) }.filter { seen.insert($0).inserted }
        let written = { (source: Int?) in InPlaceAnswer.reason(calls: displayed, answer: computed.answer, source: source, standsIn: computed.standsIn, wholeCommand: conditions.wholeCommand, lookups: conditions.lookups, note: note, rerun: conditions.wholeCommand && conditions.lookups == 1 ? computed.rerun : nil) }
        let refusal = written(computed.source)
        // Only an answer that weighs a read is withheld for want of a closing line stating its own size: one
        // that stands in for a few printed lines, a declaration grep's, is still worth serving, and where no
        // line can price it truly it closes on the line that claims no saving.
        return (computed, refusal.statesItsSize || computed.weighsRead ? refusal : written(nil))
    }

    /// The first page of the file's digest cut to the most member lines that keep its whole refusal inside the size budget, or `nil` where the read does not end as `overSize`, the digest is the file's own source, or no such page may stand in for the read.
    ///
    /// Computed only where the candidates, uncut, are refused as `overSize`: a read that ends any other way renders nothing extra. The page size starts from an estimate (the page lines the room the framing leaves holds, at the whole answer's bytes per line) and widens by doubling steps until a fitting and a non-fitting size bracket it, then bisects: a page's size only grows with its lines, so the largest page that fits is the one that stays. Each probe is one render of the digest, and the closure given is told of each. Where the read is a window, the page has to reach every member the window overlaps, which a smaller page reaches no further than a larger one, so only the largest is asked.
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
        // `fits` is the largest page size known to fit, `over` the least known not to: the whole digest is a page of
        // every face's size, and it does not fit.
        var (fits, over) = (0, DigestOptions().pageSize)
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
