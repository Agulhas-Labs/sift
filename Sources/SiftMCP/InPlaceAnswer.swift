//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore

/// The refusal that carries its answer: what the hook prints where the lookup is one it answers in place (``InPlaceShape``), and how the transcript scan tells one apart afterwards.
///
/// It is still a refusal — the command does not run, and the harness delivers the text as the call's error, as it does every refusal — so it keeps the promise every refusal makes: the identical re-run passes, and gets the raw text. What changes is what the round trip buys. A refusal names a call and the context spends a turn making it, re-sending everything it holds; this makes the call and hands over the answer, so that turn is not spent.
public struct InPlaceAnswer {
    /// How long the hook spends answering before it lets the command through: three seconds, for the engine open, the freshness check, the query and the rendering together.
    ///
    /// An order of magnitude more than a warm index takes to answer from a fresh process, and still well inside the five-second timeout the hook is registered with. It is spent against an outcome that costs a turn of the model's — the answer handed over in the denial, so the call that makes it is never spent — where the alternative is the command running as it would have anyway. What overruns it is the index doing something other than answering: reindexing a large dirty set, waiting on another process's write, reading a cold volume. The call is allowed then, never refused bare, and the back-off holds the shape off in that repository for the window, so the wait is paid at most once in it. The budget bounds the one path of the hook that runs the index at all; every command the hook lets through without attempting an answer never reaches it.
    public static let timeBudget: TimeInterval = 3

    /// The most the whole refusal may hold, in UTF-8 bytes: ten thousand, the harness's own line for how much hook text it puts in front of the model.
    ///
    /// Claude Code hands a model hook-supplied context whole up to ten thousand characters and past that saves it to a file and shows a preview. A refusal's reason is delivered whole today at three times that, but a reason past the harness's own line is one change away from arriving cut, and an answer cut mid-listing reads as complete. Bytes bound characters from above, so the limit holds however much of the text is outside ASCII. A digest too long for it is served as its first page cut to fit, ending in the cursor that pages it, where one file's digest is over it and the page saves at least the window-saving floor and reaches any window asked for; any other answer too long for it lets the call run.
    public static let sizeBudget = 10000

    /// The least a window's answer must save, in UTF-8 bytes, where the answer does not show the text of the lines the window asks for: four kibibytes, about a thousand tokens.
    ///
    /// Such an answer cannot stand in for the read — the member lines it shows are not the lines asked for — so the identical re-run follows it, and that turn re-sends the whole context. A week of real sessions priced a window let through under four kibibytes cheaper than the answer that stood in for it, so the window runs instead. An answer that does show every line the window prints is held to no floor, since it is the read.
    public static let windowSavingFloor = 4096

    /// Whether `answer` shows `printed`, a window's lines, as a run of consecutive lines in the order they were printed, lines made only of punctuation and whitespace neither counting toward the match nor breaking it.
    ///
    /// A window of nothing but such lines shows nothing, since a closing brace turns up in any answer.
    static func answer(_ answer: String, showsRunOf printed: [String]) -> Bool {
        let wanted = printed.filter(carriesText)
        let shown = answer.split(whereSeparator: \.isNewline).filter(carriesText)
        guard !wanted.isEmpty, shown.count >= wanted.count else { return false }
        return (0 ... shown.count - wanted.count).contains { start in
            wanted.indices.allSatisfy { shown[start + $0].contains(wanted[$0]) }
        }
    }

    /// Whether `line` holds a letter or a digit rather than only punctuation and whitespace.
    private static func carriesText(_ line: some StringProtocol) -> Bool {
        line.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
    }

    /// How a call that lists every reference site says so when it is spelled for Bash: the CLI's flag.
    static var referencesFlag: String {
        " --refs"
    }

    /// How it says so spelled as the tool is called: the tool's own argument.
    static var referencesArgument: String {
        " (refs: true)"
    }

    /// The line an answered refusal opens with: the calls that answered, and what re-running the command is for.
    ///
    /// The subject names the lookup rather than the command where the lookup was one statement of a command that carried other work too, so that the other statements — whose output is not in the answer, and which did not run — are not read as covered. Only the words before the first call change, and the suffix where `rerun` is given: the stem between them is what tells an answered refusal apart from every other one, and is read back by the calls reader below.
    ///
    /// `note` is an aside outside the backticks, for a call spelled with less than it seems to offer — a bounded window's `digest F.swift` stands for the file's whole digest without being it, and the note is where that is said, right beside the call it qualifies.
    ///
    /// `rerun` is the size of the file a whole read asked for, where the answer is that file's digest: the suffix then says what the identical re-run costs and names the ranged read that costs less.
    static func openingLine(calls: [String], wholeCommand: Bool = true, lookups: Int = 1, note: String? = nil, rerun: (lines: Int, bytes: Int)? = nil) -> String {
        let subject = wholeCommand ? "this" : lookups > 1 ? "the lookups in this command" : "the lookup in this command"
        let aside = note.map { " (\($0))" } ?? ""
        let suffix = rerun.map { rerunSuffix(lines: $0.lines, bytes: $0.bytes) } ?? openingSuffix
        return "sift answered \(subject) with \(calls.map { "`\($0)`" }.joined(separator: ", "))\(aside) instead of running it\(suffix)"
    }

    /// What every answered refusal's opening line carries between its calls and its suffix, and the only part the reader below requires.
    public static var openingStem: String {
        " instead of running it — re-run the identical command"
    }

    /// How an answered refusal that offers its raw output ends: the suffix of every answer but a whole read's.
    public static var openingSuffix: String {
        " — re-run the identical command if you wanted its raw output."
    }

    /// How a whole read's answer ends: what the identical re-run prints, in lines and in tokens, and the cheaper route.
    ///
    /// The tokens are the file's bytes over ``WholeReadWorth/bytesPerToken``, the figure the rule that withholds a digest not worth the turn uses, so the line and the rule never price one file two ways.
    static func rerunSuffix(lines: Int, bytes: Int) -> String {
        " — re-run the identical command for all \(lines) lines, about \(tokens(ofBytes: bytes)) tokens, or Read just a member's line range below with offset and limit."
    }

    /// `bytes` as tokens: a whole number below a thousand, and one decimal with a `k` from there up.
    static func tokens(ofBytes bytes: Int) -> String {
        let tokens = Double(bytes) / WholeReadWorth.bytesPerToken
        let whole = Int(tokens.rounded())
        return whole < 1000 ? "\(whole)" : String(format: "%.1fk", tokens / 1000)
    }

    /// The calls an answered refusal's opening line names, or `nil` for any other line.
    public static func calls(inOpeningLine line: some StringProtocol) -> [String]? {
        parseOpeningLine(line)?.calls
    }

    /// The aside a bounded call's opening line carries outside its backticks, or `nil` where it carries none or the line is not one.
    static func note(inOpeningLine line: some StringProtocol) -> String? {
        parseOpeningLine(line)?.note
    }

    /// `calls(inOpeningLine:)` and `note(inOpeningLine:)` read the same line once: the calls' closing backtick, the optional `(note)` between it and the stem, and the stem that tells this line apart from any other.
    ///
    /// Whatever follows the stem is the suffix, in whichever form.
    private static func parseOpeningLine(_ raw: some StringProtocol) -> (calls: [String], note: String?)? {
        let line = String(raw)
        guard let open = line.firstIndex(of: "`"), let stem = line.range(of: openingStem, options: .backwards), open < stem.lowerBound else { return nil }
        var body = String(line[line.index(after: open) ..< stem.lowerBound])
        var note: String?
        if body.hasSuffix(")"), let openParen = body.range(of: " (", options: .backwards) {
            note = String(body[body.index(openParen.lowerBound, offsetBy: 2) ..< body.index(before: body.endIndex)])
            body = String(body[..<openParen.lowerBound])
        }
        guard body.hasSuffix("`") else { return nil }
        body.removeLast()
        let calls = body.components(separatedBy: "`, `")
        return calls.contains(where: \.isEmpty) ? nil : (calls, note)
    }

    /// The whole refusal: the opening line, the index answer as the calls serve it — header first — and a closing line stating its size against the source it stands in for.
    ///
    /// `source` is what the answer stands in for where the call weighed itself against source — a file's digest — and `nil` where it has nothing to weigh against. `served` is every byte the caller pays for, the opening and closing lines included, which is the number the usage log records beside `source`.
    ///
    /// The closing line prices the text it ends, itself included, so it is written at a length whose figures are the text's own: every byte count and percentage it states is the one `text.utf8.count` gives. `statesItsSize` is false where no length is — the line's figures step over their own length, as when a percentage loses a digit just as the text gains a byte — and such a refusal is never served as written, since what it says about its own size would be false.
    public static func reason(
        calls: [String],
        answer: String,
        source: Int?,
        standsIn: String,
        wholeCommand: Bool = true,
        lookups: Int = 1,
        note: String? = nil,
        rerun: (lines: Int, bytes: Int)? = nil
    ) -> Refusal {
        let framed = "\(openingLine(calls: calls, wholeCommand: wholeCommand, lookups: lookups, note: note, rerun: rerun))\n\n\(answer)\n\n"
        let fixed = framed.utf8.count
        // A length the closing line can have whose line, priced at the framing plus that length, is that long. Its
        // figures move its length by a few bytes, and a claim is never twice as long as a denial, so any such length
        // lies within twice the first draft's; past that bound there is none. The search fans out from the draft's
        // own length, nearest first and the shorter of each pair first, since that is where one almost always is.
        let draft = closingLine(source: source, served: fixed, standsIn: standsIn)
        let start = draft.utf8.count
        for offset in 0 ... start {
            for length in offset == 0 ? [start] : [start - offset, start + offset] {
                let closing = closingLine(source: source, served: fixed + length, standsIn: standsIn)
                if closing.utf8.count == length {
                    let text = framed + closing
                    return Refusal(text: text, served: text.utf8.count, statesItsSize: true)
                }
            }
        }
        let text = framed + draft
        return Refusal(text: text, served: text.utf8.count, statesItsSize: false)
    }

    /// The line naming each branch of an alternation the answer does not cover, verbatim, and the re-run that sweeps for them — `nil` where it covers every branch.
    static func caveat(uncovered: [String]) -> String? {
        guard !uncovered.isEmpty else { return nil }
        let branches = uncovered.map { "\"\($0)\"" }.joined(separator: ", ")
        return "This answer does not cover \(branches); re-run the identical command to sweep for \(uncovered.count == 1 ? "that" : "those")."
    }

    /// The number of branches the caveat line inside `text` names, or `nil` where it carries none.
    ///
    /// Read directly off the reason a refusal answered in place carries — the same text ``TranscriptScan`` already has in hand — rather than off the answer extracted separately, so the caller is spared extracting the answer only to search it again. Counted by quote pairs rather than by splitting on the branches' own separator, so a branch that happens to hold a comma is still one branch.
    static func uncoveredBranchCount(inReason text: String) -> Int? {
        let marker = "This answer does not cover "
        guard let markerRange = text.range(of: marker) else { return nil }
        let rest = text[markerRange.upperBound...]
        guard let semicolon = rest.firstIndex(of: ";") else { return nil }
        return rest[..<semicolon].count(where: { $0 == "\"" }) / 2
    }

    /// The index answer inside an answered refusal — what stands between its opening and closing lines — or `nil` for any other text.
    ///
    /// The transcript scan reads a digest's floor verdict and the tree that answered it out of this, as it reads them out of an index call's own answer.
    public static func answer(inReason text: String) -> String? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard let first = lines.first, calls(inOpeningLine: first) != nil, lines.count >= 5 else { return nil }
        return lines[2 ..< lines.count - 2].joined(separator: "\n")
    }

    /// Whether the refusal `text` closes by saying it saved nothing against the source it measured, which an answer weighed against a window is never served saying.
    ///
    /// The closing line prices the text it ends, so near the break-even point it cannot settle: the line stating a smaller size can make the refusal no smaller than its source, where the line denying a saving makes it smaller again. Such a refusal saves nothing it can state, so the weighing reads the verdict off the line itself rather than off a byte count the line no longer agrees with.
    static func deniesSaving(inReason text: String) -> Bool {
        text.split(separator: "\n").last?.hasPrefix(noSaving) == true
    }

    /// How a closing line that measured its source and found no saving opens.
    private static var noSaving: String {
        "No saving: "
    }

    /// The closing line: the source the answer stands in for and what it served, as sizes — `8.5 kB of source → 1.7 kB served (80% smaller).`
    ///
    /// **Sizes, never a saving in tokens.** When the answer is given nobody knows whether the source will be read anyway, so a token figure here would read as a measurement it is not; the usage log records the same two byte counts and prices them with their baseline. Nor does it say what the re-run costs: the opening line names it as the way to the raw output, and it costs that output. The percentage is rounded down, so the compression is at least what it says.
    private static func closingLine(source: Int?, served: Int, standsIn: String) -> String {
        guard let source else {
            return "No saving is claimed: \(standsIn), so there is nothing measured to set it against."
        }
        guard source > served else {
            return "\(noSaving)\(ByteSize.short(served)) served for \(ByteSize.short(source)) of source."
        }
        let smaller = (source - served) * 100 / source
        return "\(ByteSize.short(source)) of source → \(ByteSize.short(served)) served (\(smaller == 0 ? "<1" : "\(smaller)")% smaller)."
    }
}

public extension InPlaceAnswer {
    /// A whole refusal as ``InPlaceAnswer/reason(calls:answer:source:standsIn:wholeCommand:lookups:note:rerun:)`` writes it.
    struct Refusal: Sendable, Equatable {
        /// The refusal's text, opening line through closing line.
        public let text: String
        /// Every byte the caller pays for: the text's own UTF-8 count.
        public let served: Int
        /// Whether the closing line's figures are the text's own, without which the refusal is never served as written.
        public let statesItsSize: Bool
    }
}
