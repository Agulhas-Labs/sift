//
// Copyright © Agulhas Labs
//

import Foundation

/// The arithmetic under every shape a run's failures are served as: how many there are, how many distinct kinds they reduce to, how far they spread, and how many landed in code this working tree has touched.
///
/// It sits in a type of its own because the two things it counts count identically and print nothing alike. **A test failure is identified by its name and a compile error by its location** — one example leads with `aTest() with size → .large — File.swift:88:27` and hangs its message underneath, the other is the compiler's own `File.swift:2:15: error: …` on a single line the reader can paste into a `Read` — while underneath both, a message reduces through ``RunFailureSignature``, failures spread over files, and the working tree answers the same question about them. Making that common half a protocol or a generic would have put a type parameter in the spelling of every caller and every test for a difference of one line of rendering; holding it as a value costs each shape a stored property and leaves each free to print in its own voice.
///
/// **It counts positions, not failures.** ``SignatureCount/representative`` is an index into the array the census was taken over rather than an element of it, which is what lets one non-generic type measure two unrelated element types: the shape that owns the array is the only thing that ever has to know what is in it.
public struct RunFailureCensus: Sendable {
    /// How many *signatures* a shape illustrates with an example before it counts the rest instead.
    ///
    /// Named for what it bounds. The listing is one example per signature, so this caps signatures and never failures — five examples routinely stand for hundreds of failures, and a name promising a count of the second would deliver the first.
    ///
    /// Far below `RunOutputFilter.warningCap`, and for a measured reason: a warning is one line, while a failure is two and its message reaches 1.5 KB when a test dumps a SwiftUI view tree, so twenty of them is still tens of kilobytes. The line above them is the diagnosis; the listing is only somewhere to start reading.
    public static let signatureCap = 5

    /// How many **bytes** of one line of a failure's own words are printed before the rest is left to the raw log.
    ///
    /// A message and a note are both unbounded input and both have been measured pathological in this corpus: a Swift Testing expectation over a SwiftUI view prints the whole dumped view tree, 1.5 KB of it, and one `↳` note in the interrupted capture is a 1,000-character array of every accessibility label on the screen. Either one puts a five-line block back over a kilobyte on its own, which is the cost this block exists to remove. 240 is wide enough that no ordinary expectation is touched — the five the red capture ranks highest are all well under it — and narrow enough that a dump cannot dominate.
    ///
    /// **Bytes rather than characters, because the budget it has to reconcile with is in bytes.** ``listingBudget``'s floor is the argument that a sample cannot come out larger than the listing it refused, and it is arithmetic over the widest a sample can be — which a cap in graphemes does not bound. The clip is over arbitrary program output, and the pathological inputs cited above include localised accessibility labels: in CJK or emoji, 240 graphemes is 720 bytes to several kilobytes, so five entries could reach 15 KB and overrun the 8 KB listing they had just turned down. On the ASCII this corpus is written in the two units are the same number and nothing about the clip moves; off it, the cap means what the budget beside it means. The count of what was dropped stays in *characters*, because that is the unit a reader is missing text in and the cap's own unit never appears in the answer.
    public static let wordsCap = 240

    /// How many bytes of listing one answer will serve before it samples instead.
    ///
    /// **The bound is on the answer, which is what a count of failures is only ever a proxy for.** A count of five is a proxy that fails hardest exactly where a shape is worth least: a build whose nine errors reduce to nine signatures has no redundancy to compress, so a sample of five withholds four errors that every one has to be fixed, and the reader has to open the raw log anyway — which is the whole cost this command exists to remove. It does not even pay for itself. Measured on that build: the sample comes to 740 bytes and listing all eight of the real errors to 651, because the measurement line and the `+4 more signatures` line together cost more than the errors they stand in for.
    ///
    /// **One budget for the answer, spent between the two sections that can list rather than granted to each of them.** Two independent listings of this size, one per section, would make what every sentence here calls a bound on the answer a bound on a section: 90 distinct errors and 60 distinct failures over one 303-line log would render 90 error lines and 120 failure lines, 12,700 bytes against a documented 8,192. The two sections spend it in the order they print, exactly as they already share ``RunReportRenderer/allowance(of:beside:)`` — and for the same reason, since the receipt below them states one number for the whole answer and not one per block.
    ///
    /// **8 KB, and the floor under it is what makes this a number rather than a taste.** What a rejected listing falls back to is five entries, each able to carry a 240-byte message, a 240-byte note and a 240-byte set of arguments over its name and location — under 4 KB at its widest, and under 5 KB for both sections' samples together — so any budget below that lets the fallback come out *larger* than the listing it turned down, which is the one way a size gate can be incoherent. The floor is an argument about the widest an *ordinary* sample gets rather than a proof about every sample: an `Undefined symbols` block's symbol list is printed whole in both forms, deliberately, and nothing bounds a linker that dumps several hundred of them. In lines the budget is roughly a hundred, which is about as long as an answer can get before the reader is reading a log again.
    ///
    /// **Sharing it needs a second argument, because what is left when the second section is reached can be narrower than that floor.** The one that holds at any margin is structural: a sample is the listing's own entries — at most five of them, each bounded by ``wordsCap`` where the listing was not — over the same measurement line, plus at most two more lines that are themselves bounded. So refusing a listing can never enlarge the block by more than those two lines, whatever is left to refuse it with, and a narrow margin buys a smaller answer rather than a perverse one. The floor above is what makes the *first* refusal cheap in absolute terms; this is what keeps the last one honest.
    ///
    /// **The margins are over the cases this actually decides, which is not the same set as the cases that end up sampled.** ``isChieflyRepetition`` answers first and answers wholesale, so the 200-error build never reaches the budget at all — its 200 errors are one signature, and no entry is ever rendered for it. What this gate decides is everything with more kinds than a sample can show: the eight-error build lists at 0.7 KB, forty ordinary test failures at about 5 KB, a 96-error build refuses at 9.0 KB — the boundary case, a hair over — and the 666-failure run refuses by a factor of thirteen at over 100 KB. No capture in the corpus carries both sections at once, so none of them can show the budget being spent twice.
    ///
    /// **It is half the rule and never the whole of it.** A size cannot see redundancy — it sees only what redundancy costs — so 85 copies of one sentence come to 7.3 KB, fit, and would be listed one by one under a line that has already said `1 signature`. ``isChieflyRepetition`` is the other half.
    public static let listingBudget = 8192

    /// How many failures were counted.
    public let count: Int
    /// Every distinct signature, most frequent first, ties broken alphabetically so the same run always renders the same way.
    public let signatures: [SignatureCount]
    /// How many distinct source files the failures span.
    ///
    /// **Counted on the paths the run printed, not on their filenames.** The two are the same number wherever the log prints bare filenames, and they are not wherever it prints paths: two failing `HelpersTests.swift` in different targets would count as one file, understating by half the field a reader uses to judge *localized or wide* — while the `in changed files` beside it carries `(matched by name)` precisely because it has no choice. This one does have a choice wherever the compiler or XCTest printed a directory, and it takes it.
    ///
    /// What it cannot recover is what the log never said: Swift Testing prints `ZonePickTests.swift:13:9` and no directory, so a run reported entirely through it counts filenames because filenames are all there were. That is the limit of the input rather than of the count.
    public let fileCount: Int
    /// How many failures landed in a file the working tree has changed, or why that could not be established.
    public let inChangedFiles: ChangedFileCount
}

public extension RunFailureCensus {
    /// One distinct signature, and where every failure that reduced to it sits.
    struct SignatureCount: Sendable, Equatable {
        public let signature: RunFailureSignature
        /// The position of every failure that reduced to this signature, in the order the run reported them.
        ///
        /// The whole membership rather than only the first of it, because the two questions a shape asks of a signature need different halves of it and neither may re-derive its own: the listing wants one example, and a claim about where those failures *happened* wants all of them. Recomputing the membership would mean normalising 666 messages a second time — cheap, but a second normalisation is a second thing that can disagree with the first, and the positions are 666 integers.
        public let positions: [Int]

        /// How many of the run's failures reduced to this signature.
        public var count: Int {
            positions.count
        }

        /// The position of the first of them — the one the listing shows as this signature's example.
        public var representative: Int {
            positions[0]
        }
    }

    /// One entry of a listing: what it prints, and what of that the budgets are charged for.
    ///
    /// **The two differ, and the difference is the *size* budget's alone.** Whether a listing is worth serving at all is a question about the run, and a tool whose answer changes shape for reasons the reader cannot see is worse than one that always gives the same answer. Two things the reader brought with them reach an entry, and each has been reproduced.
    ///
    /// A path is printed relative to the directory the answer is being read in, which is a fact about the shell: measured in that spelling, one 85-error build would list all 85 from inside its package and be sampled to a single line from a directory that is not its parent, where the same paths are sixty characters wider — the same run, the same exit code, thirteen times the answer. ``shortening`` is what that saved, and charging it back measures every listing in the one spelling no `cd` can change.
    ///
    /// A declaration ``RunFailureSites`` resolved the entry's location to is a fact about *this checkout*, and charged, it would move the answer the same way and further. One package's 80 failing tests, same command, same exit code: with no index beside the log all 80 are named, and with one the block would sample to five and withhold 70 names, so the tool would print less the more it knew — and, because that resolution is abandoned on a two-second deadline, a loaded machine would get the listing back. ``uncharged`` is where that line goes: ``listingBudget`` is charged nothing for it.
    ///
    /// **The line allowance is charged for it, and that is not the same trade.** A byte budget asks how much of a *spelling* the answer is spending, and a spelling the reader chose has no business in it. An allowance asks how long the answer is against the log it replaces, and a line printed is a line the reader reads whoever put it there — so exempting these would make the receipt state a saving the answer had not made: a 110-line log, 52 resolving failures, a block charged 105 lines and printing 162, closing on `sift run: 110 lines in, 162 out`. See ``listing(of:within:spending:entries:)`` for which bound charges which.
    ///
    /// What the size budget gives up by that is exactness. It becomes a lower bound on the bytes served rather than a bound on them — and that is the right way round, since the failure being prevented is an answer that *shrinks* when the tool learns something.
    struct Entry: Sendable {
        /// The lines the run itself accounts for, paths and all, exactly as the reader will see them.
        public let charged: [String]
        /// The lines this repository added beneath them, which ``listingBudget`` is charged nothing for.
        public let uncharged: [String]
        /// What stating this entry's paths relative to the reader saved, in bytes.
        public let shortening: Int

        /// Everything this entry prints, in order.
        public var lines: [String] {
            charged + uncharged
        }

        public init(_ charged: [String], shortenedBy shortening: Int = 0, uncharged: [String] = []) {
            self.charged = charged
            self.uncharged = uncharged
            self.shortening = shortening
        }
    }

    /// How many failures landed in a file the working tree has changed — or why there is no such number.
    enum ChangedFileCount: Sendable, Equatable {
        /// The count, matched by filename rather than by path.
        case count(Int)
        /// Why the signal was unavailable, in git's own words — never to be read as zero.
        case unavailable(String)
    }
}

public extension RunFailureCensus {
    /// Measures `failures` against what the working tree has changed, reading each one's words and its file through the projections given.
    ///
    /// One pass, and nothing here is quadratic in the number of failures: a 1.5 KB message is normalised once, hashed once, and never compared against another message.
    ///
    /// **`path` hands over the file as the run printed it, and the reduction to a filename happens here.** A caller passing the filename would cost ``fileCount`` the directories the log had given it. Only the changed-files match needs the reduction — git reports paths and a Swift Testing issue line names none, so that comparison meets on the name and says so wherever it is printed — and doing it in one place is what stops the count and the match answering different questions about one string.
    static func of<Failure>(
        _ failures: [Failure],
        message: (Failure) -> String,
        path: (Failure) -> String?,
        changedFiles: RunChangedFiles
    ) -> RunFailureCensus {
        var occurrences: [RunFailureSignature: [Int]] = [:]
        var files: Set<String> = []
        var changed = 0
        for (position, failure) in failures.enumerated() {
            let signature = RunFailureSignature(message: message(failure))
            occurrences[signature, default: []].append(position)
            if let path = path(failure) {
                files.insert(path)
                if case let .basenames(basenames) = changedFiles, basenames.contains(name(of: path)) {
                    changed += 1
                }
            }
        }
        let ranked = occurrences
            .map { SignatureCount(signature: $0.key, positions: $0.value) }
            .sorted { left, right in
                left.count == right.count ? left.signature.text < right.signature.text : left.count > right.count
            }
        return RunFailureCensus(
            count: failures.count,
            signatures: ranked,
            fileCount: files.count,
            inChangedFiles: tally(changed, against: changedFiles)
        )
    }
}

// MARK: - Rendering

public extension RunFailureCensus {
    /// The one line that does the classifying, in whichever noun the caller counts in.
    ///
    /// The noun is the caller's because the same arithmetic reads as *failures* over a test run and *errors* over a build, and a block that called its errors failures would be inviting the reader to look for a test that never ran.
    func measurements(of noun: String) -> String {
        [
            Self.counted(count, noun),
            Self.counted(signatures.count, "signature"),
            Self.counted(fileCount, "file"),
            changedFiles,
        ].joined(separator: " · ")
    }

    /// ``measurements(of:)`` as the lines a block leads with: that line wherever there is more than one entry, and none for a lone one.
    ///
    /// One of anything is one signature in one file, so over a lone entry the line would restate what the entry beneath it already shows. Both forms lead with this, so a lone failure reads the same whether it was listed or sampled.
    func heading(of noun: String) -> [String] {
        count > 1 ? [measurements(of: noun)] : []
    }

    /// Whether these failures are chiefly copies of one another — the half of the listing rule a size cannot see.
    ///
    /// **A size measures what redundancy costs, never that there is any.** 85 compile errors reducing to one signature came to 7.3 KB, fit inside ``listingBudget``, and were served as 85 lines of one sentence under a measurement line that had already said `1 signature`. That is not verbosity at the margin — it is the compression this command exists for, not happening, on the case it was built for. So a shape is served whatever a listing of it would weigh, once the listing is mostly repetition.
    ///
    /// **Three terms, and each is a boundary rather than a tuned constant.** *No more kinds than ``signatureCap``* is the first, and it is the one this rule may never be stated without: a shape is lossless only where the sample it falls back to can show **every** kind, and that sample is one example per signature to a cap of five. *More than twice as many failures as kinds* is the second — the point where more than half of what the listing prints restates a kind it has already printed, the only non-arbitrary place on that axis, since below it the listing is chiefly content and above it chiefly copies. And *more than ``signatureCap`` failures* is the floor, because a sample prints up to five examples: a listing no longer than that cannot be compressed by a block of that size, and three failures that share one message are three names the answer would lose to save two lines.
    ///
    /// **The first term is what keeps this from being the defect it was written to fix.** The ratio and the floor together fire on 21 errors over 10 kinds — more than twice as many errors as kinds, comfortably past five — and the sample they hand the reader shows five of those ten and sends them to the raw log for the other five, each a separate problem needing its own fix. That is the same loss as the nine-errors-in-nine-files case the size rule replaced, one kind further along, and neither size refuses it: the listing is 22 lines and a fraction of the 8 KB budget, so nothing but this term stands between the reader and the loss. Redundancy is only worth collapsing into a shape the shape can hold.
    ///
    /// What this deliberately does not do is judge the diverse case. Eight errors over eight signatures, or forty distinct failures, have nothing to collapse — the ratio is one, the shape would be a sample of five with thirty-five names withheld, and the listing stands until ``listingBudget`` refuses it on its size alone. Both rules together are what serving the shape *when there is one* means; either on its own is half of it.
    var isChieflyRepetition: Bool {
        signatures.count <= Self.signatureCap && count > Self.signatureCap && count > 2 * signatures.count
    }

    /// The measurements, then every entry the caller offers — while the whole of it fits what is left of `budget` and of `allowance` and the failures are not chiefly repetition, and `nil` once any of that fails.
    ///
    /// **This is the decision, and the way to make most of it is to render the answer and look at it.** How much a listing costs is a fact about the failures rather than about how many of them there are, and any predicate over the count is guessing at it; building the listing and measuring it is the same question asked directly. `nil` is the caller being told to sample.
    ///
    /// **The measurement line leads this form too wherever there is more than one entry, and is not the sampled form's disclosure.** It is the line that says whether nine errors are one problem or nine, which a reader wants over a complete listing exactly as much as over a sample — `9 errors · 9 signatures` and `9 errors · 1 signature` are different next steps over the same nine lines. Making it conditional on sampling would let the answer's shape, rather than the run's, decide whether the reader is told.
    ///
    /// **`allowance` is what the log the answer stands for has left for this block**, and it is the bound that keeps the wrapper from expanding what it exists to compress. A listed failure costs two to four lines against as few as one or two of log, so twenty Swift Testing tests recording three issues each print about 110 lines and list as 126 — a receipt reading `110 lines in, 126 out`. A fixed cap on entries bounds that only by accident; this is the bound that holds it on purpose. The caller computes it, because only the answer knows what else it is printing.
    ///
    /// **`budget` is what the *answer* has left of ``listingBudget``, and it is spent rather than merely read.** Both sections of an answer can list, so a constant consulted here is a bound on a section and not on the answer — which is how 90 errors and 60 failures would serve 12,700 bytes under a documented 8,192. It is committed only on the way out: a listing this refuses spent nothing, because nothing of it was served.
    ///
    /// **The two bounds charge different things, and the difference is the whole of ``Entry``'s subject.** `budget` is charged ``Entry/charged`` and never ``Entry/lines``, so what decides the *form* is a property of the run — the answer can print more bytes than the budget named, by exactly the resolution this checkout added and the width a `cd` saved. `allowance` is charged everything printed, because a claim about how long an answer is may not exempt lines that are in it; an answer this serves is never longer than the log it stands for.
    ///
    /// **`entries` is taken lazily and the bounds are read after each one**, so a run of 666 failures builds a handful of entries and stops rather than composing 100 KB of strings to weigh them and throw them away. The check sits after a whole entry because an entry is the unit a listing may not truncate: a failure's message without its name, or a linker header without the symbols under it, is worse than not listing it at all.
    func listing(of noun: String, within allowance: Int, spending budget: inout Int, entries: some Sequence<Entry>) -> [String]? {
        guard !isChieflyRepetition else {
            return nil
        }
        var lines = heading(of: noun)
        var bytes = lines.first.map { $0.utf8.count + 1 } ?? 0
        for entry in entries {
            lines.append(contentsOf: entry.lines)
            bytes += entry.charged.reduce(entry.shortening) { $0 + $1.utf8.count + 1 }
            guard bytes <= budget, lines.count <= allowance else {
                return nil
            }
        }
        budget -= bytes
        return lines
    }

    /// Both halves of what a block illustrating `shown` signatures left out, or `nil` when it left out nothing.
    ///
    /// The failure count is stated alongside the signature count because the signature count alone left the larger number unaccounted for anywhere in the answer: five examples standing for 247 of the failing capture's 666 failures leaves 419 that the block neither showed nor counted, under a heading that had just said 666.
    func withheld(beyond shown: Int, of noun: String) -> String? {
        let signaturesWithheld = signatures.count - shown
        guard signaturesWithheld > 0 else {
            return nil
        }
        let failuresWithheld = count - signatures.prefix(shown).reduce(0) { $0 + $1.count }
        let more = signaturesWithheld == 1 ? "signature" : "signatures"
        return "  +\(signaturesWithheld) more \(more), covering \(Self.counted(failuresWithheld, noun)) — see the raw log"
    }

    /// `text` bounded to `cap` bytes — ``wordsCap`` unless a caller names its own — ending in the count of what was left behind rather than a bare ellipsis.
    ///
    /// The count is the point: an ellipsis says a line was cut and nothing about whether the cut mattered, and this block's whole claim is that its arithmetic reconciles with the log it names. It counts *characters* while the cap counts bytes, deliberately: a reader is missing text, not storage, and the cap's own unit is nowhere in the answer to be inconsistent with.
    ///
    /// The cut lands on a character boundary inside the byte bound rather than on the bound itself, since a prefix of the UTF-8 can end mid-scalar and there is no reading of half a character worth printing. Walking the string to find it is linear in what is kept, which is at most ``wordsCap`` bytes however long the input is.
    static func clipped(_ text: String, to cap: Int = wordsCap) -> String {
        guard text.utf8.count > cap else {
            return text
        }
        var kept = 0
        var bytes = 0
        for character in text {
            bytes += character.utf8.count
            guard bytes <= cap else {
                break
            }
            kept += 1
        }
        return text.prefix(kept) + "… (+\(text.count - kept) characters — see the raw log)"
    }

    /// Whether `message` is a failed `.contains`/`.hasPrefix`/`.hasSuffix`, the one kind of failure ``closestLine(message:note:truncated:)`` has anything to say about.
    static func namesContainment(_ message: String) -> Bool {
        containmentCall(in: message) != nil
    }

    /// One continuation line of a failure's note, stripped of its marker and indentation, and whether it carried the `↳` marker — a line without one continues whatever value the line above it left open.
    struct NoteLine: Equatable {
        let text: String
        let marked: Bool
    }

    /// How much of a note is kept for ``closestLine(message:note:truncated:)`` to search: a haystack past either bound is searched as far as the bound, and said to be.
    static let closestLineNoteLimit = (lines: 2000, bytes: 200_000)

    /// How much of a needle the search compares — a run as long as this is already an unmistakable match, and the search's cost grows with it for every haystack character.
    static let closestLineNeedleLimit = 200

    /// The haystack line worth reading beside a failed `.contains`/`.hasPrefix`/`.hasSuffix`, or `nil` where the message names none of the three, the note prints no multi-line value for its receiver, or what was read cannot support an answer.
    ///
    /// Swift Testing prints the failure as `Expectation failed: reason.contains("needle")` and, beneath it, each operand's value on a `↳   reason → "…` line whose embedded newlines are real ones: the haystack's second line onwards arrive as indented lines of their own, up to the one that closes the quote. `note` is those continuation lines in full, each already stripped of its marker and indentation. The capped note a failure renders keeps only its first three, which is rarely where the line a multi-line haystack failed on is.
    ///
    /// The needle is the call's literal where it has one, and otherwise the value the note prints for the expression passed — `reason.contains(needle)` is followed by a `↳   needle → "…"` line of its own.
    ///
    /// `contains` picks the line sharing the longest run of characters with the needle, four or more of them — long enough that two lines cannot tie on a shared space or a shared "the", short enough to catch a truncated word — and says `no line shares text with it` where none does. `hasPrefix`/`hasSuffix` need no such search: the line that could have satisfied either is always the first or the last, so that is what is named. A haystack of one line is already shown whole in the note, so this answers `nil` and the note stands on its own.
    ///
    /// **`no line shares text with it` is said only over a haystack read whole, against a needle read whole.** Where the note was `truncated` at ``closestLineNoteLimit``, the value never closed its quote, or the needle ran past ``closestLineNeedleLimit``, the line the reader needs may be in the part never searched: a line found is named as the closest `in the first N lines`, and finding none says nothing, since a wrong "no line" is believed and silence is not.
    static func closestLine(message: String, note: [NoteLine], truncated: Bool = false) -> String? {
        guard let (call, line) = containmentCall(in: message) else {
            return nil
        }
        let values = printedValues(in: note)
        let receiver = message[message.startIndex ..< call.lowerBound]
        guard
            let haystack = values.first(where: { !$0.expression.isEmpty && receiver.hasSuffix($0.expression) }),
            haystack.lines.count > 1
        else {
            return nil
        }
        let lines = haystack.lines
        let whole = haystack.complete && !truncated
        let heading = whole ? "closest line" : "closest line in the first \(lines.count) lines"
        switch line {
        case .first:
            return "\(heading): \(clipped(lines[0]))"
        case .last:
            return whole ? "closest line: \(clipped(lines[lines.count - 1]))" : nil
        case .matching:
            guard let needle = needle(passedTo: call, in: message, values: values) else {
                return nil
            }
            let compared = Array(needle.text.unicodeScalars.prefix(closestLineNeedleLimit))
            guard let best = closestMatch(in: lines, to: compared), best.run >= 4 else {
                let needleWhole = needle.complete && compared.count == needle.text.unicodeScalars.count
                return whole && needleWhole ? "no line shares text with it" : nil
            }
            return "\(heading): \(clipped(lines[best.index]))"
        }
    }
}

private extension RunFailureCensus {
    /// How each call ``closestLine(message:note:truncated:)`` recognises picks its line.
    enum ContainmentLine {
        case first, last, matching
    }

    /// One operand the note printed a value for — `reason → "…"` — its lines as the log broke them, and whether the note reached the quote that closes it.
    struct PrintedValue {
        let expression: String
        var lines: [String]
        var complete: Bool
    }

    static let containmentShapes: [(name: String, line: ContainmentLine)] = [
        ("contains", .matching),
        ("hasPrefix", .first),
        ("hasSuffix", .last),
    ]

    /// Where `message` calls one of ``containmentShapes`` — the range of `.name(` — and how that call picks its line.
    static func containmentCall(in message: String) -> (Range<String.Index>, ContainmentLine)? {
        for shape in containmentShapes {
            if let call = message.range(of: ".\(shape.name)(") {
                return (call, shape.line)
            }
        }
        return nil
    }

    /// The needle a `contains` call was passed: its literal, or the value the note printed for the expression in its place.
    static func needle(passedTo call: Range<String.Index>, in message: String, values: [PrintedValue]) -> (text: String, complete: Bool)? {
        guard let argument = matchedParenthesis(after: call.upperBound, in: message) else {
            return nil
        }
        let expression = argument.trimmingCharacters(in: .whitespaces)
        if expression.count > 1, expression.hasPrefix("\""), expression.hasSuffix("\"") {
            return (String(expression.dropFirst().dropLast()), true)
        }
        return values.first { $0.expression == expression }.map { ($0.lines.joined(separator: "\n"), $0.complete) }
    }

    /// Every `expression → "value"` the note's lines print, a value running on across unmarked lines until one that ends in a quote and is not followed by another unmarked line.
    ///
    /// A value's own line can end in a quote — `qwv "k"` — so a quote closes the value only where the next line starts something else: a `↳` line, or the end of the note. The line reporting the call itself — `reason.contains("x") → false` — prints no quoted value and is passed over. A value the note ends inside, or a `↳` line cuts off, is kept as far as it got and marked incomplete.
    static func printedValues(in note: [NoteLine]) -> [PrintedValue] {
        var values: [PrintedValue] = []
        var open: PrintedValue?
        for (offset, line) in note.enumerated() {
            let continued = offset + 1 < note.count && !note[offset + 1].marked
            if var value = open, !line.marked {
                let closes = line.text.hasSuffix("\"") && !continued
                value.lines.append(closes ? String(line.text.dropLast()) : line.text)
                value.complete = closes
                if closes {
                    values.append(value)
                }
                open = closes ? nil : value
                continue
            }
            if let cut = open {
                values.append(cut)
                open = nil
            }
            guard let arrow = line.text.range(of: " → \"") else {
                continue
            }
            let expression = line.text[line.text.startIndex ..< arrow.lowerBound].trimmingCharacters(in: .whitespaces)
            let rest = line.text[arrow.upperBound...]
            if rest.hasSuffix("\""), !continued {
                values.append(PrintedValue(expression: expression, lines: [String(rest.dropLast())], complete: true))
            } else {
                open = PrintedValue(expression: expression, lines: [String(rest)], complete: false)
            }
        }
        if let open {
            values.append(open)
        }
        return values
    }

    /// The text between the `(` ending at `index` and its matching `)`, skipping past whatever a quoted literal in between contains — parentheses included.
    static func matchedParenthesis(after index: String.Index, in message: String) -> Substring? {
        var depth = 1
        var scan = index
        while scan < message.endIndex {
            switch message[scan] {
            case "\"":
                var literalEnd = message.index(after: scan)
                while literalEnd < message.endIndex, message[literalEnd] != "\"" {
                    literalEnd = message[literalEnd] == "\\"
                        ? message.index(literalEnd, offsetBy: 2, limitedBy: message.endIndex) ?? message.endIndex
                        : message.index(after: literalEnd)
                }
                scan = literalEnd < message.endIndex ? message.index(after: literalEnd) : literalEnd
                continue
            case "(":
                depth += 1
            case ")":
                depth -= 1
                if depth == 0 {
                    return message[index ..< scan]
                }
            default:
                break
            }
            scan = message.index(after: scan)
        }
        return nil
    }

    /// The line of `lines` sharing the longest run of scalars with `needle`, or `nil` for an empty needle.
    ///
    /// A tie in that run goes to the line whose longest common *subsequence* with `needle` is longer, and a further tie to the earlier line.
    ///
    /// Dynamic programming over two rows the length of the needle, allocated once and reused for every line and every character, so the memory is the needle's and the time is the haystack's length times the needle's. The subsequence score, needed only to break a run tie, is recomputed on demand rather than kept for every line.
    static func closestMatch(in lines: [String], to needle: [Unicode.Scalar]) -> (index: Int, run: Int)? {
        guard !needle.isEmpty else {
            return nil
        }
        var previous = [Int](repeating: 0, count: needle.count + 1)
        var current = previous
        var best: (index: Int, run: Int)?
        var bestSubsequence: Int?
        for (index, line) in lines.enumerated() {
            for column in previous.indices {
                previous[column] = 0
            }
            var longest = 0
            for scalar in line.unicodeScalars {
                for column in needle.indices {
                    let run = scalar == needle[column] ? previous[column] + 1 : 0
                    current[column + 1] = run
                    longest = max(longest, run)
                }
                swap(&previous, &current)
            }
            if let currentBest = best {
                if longest > currentBest.run {
                    best = (index, longest)
                    bestSubsequence = nil
                } else if longest == currentBest.run {
                    let existing = bestSubsequence ?? longestCommonSubsequence(lines[currentBest.index].unicodeScalars, needle)
                    let candidate = longestCommonSubsequence(line.unicodeScalars, needle)
                    bestSubsequence = existing
                    if candidate > existing {
                        best = (index, longest)
                        bestSubsequence = candidate
                    }
                }
            } else {
                best = (index, longest)
            }
        }
        return best
    }

    /// The length of the longest common subsequence between `text` and `needle`, taken in order but not necessarily contiguous.
    static func longestCommonSubsequence(_ text: some Sequence<Unicode.Scalar>, _ needle: [Unicode.Scalar]) -> Int {
        var previous = [Int](repeating: 0, count: needle.count + 1)
        for scalar in text {
            var current = [Int](repeating: 0, count: needle.count + 1)
            for column in needle.indices {
                current[column + 1] = scalar == needle[column] ? previous[column] + 1 : max(previous[column + 1], current[column])
            }
            previous = current
        }
        return previous[needle.count]
    }
}

private extension RunFailureCensus {
    /// Always states that the match was by filename, because it was.
    var changedFiles: String {
        switch inChangedFiles {
        case let .count(count):
            "\(count) in changed files (matched by name)"
        case let .unavailable(reason):
            "changed files unknown — \(reason)"
        }
    }

    static func counted(_ number: Int, _ noun: String) -> String {
        "\(number) \(noun)\(number == 1 ? "" : "s")"
    }

    /// The bare filename `path` ends on — the only form the changed-files signal can be compared on.
    static func name(of path: String) -> String {
        String(path.split(separator: "/").last ?? "")
    }

    static func tally(_ changed: Int, against changedFiles: RunChangedFiles) -> ChangedFileCount {
        switch changedFiles {
        case .basenames:
            .count(changed)
        case let .unavailable(reason):
            .unavailable(reason)
        }
    }
}
