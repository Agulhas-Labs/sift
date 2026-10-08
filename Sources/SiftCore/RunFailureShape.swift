//
// Copyright © Agulhas Labs
//

import Foundation

/// What a run's test failures look like taken together: how many there are, how many distinct kinds, how far they spread, and how many of them landed in code this working tree has touched.
///
/// A number of failures is not a diagnosis; a shape of failures usually is. *666 failures reducing to 210 signatures across 53 files, none of them in a file the working tree changed* is a measurement, and it answers "is this a regression I just caused?" decisively — in one line, where reading the failures themselves takes a dozen tool calls and tens of kilobytes.
///
/// It reports that shape and **never names a cause**. There is no known-signature hint table here and there deliberately never will be: there is no corpus of incidents behind this type to draw one from, so a table of "empty accessibility trees / disk full / simulator contention" would be three guesses — and a tool that guesses a cause is eventually confidently wrong, which is precisely the failure the measurement exists to catch. The numbers say what happened; what caused it stays the reader's call.
///
/// The counting is ``RunFailureCensus``'s, held rather than reimplemented, so a build's errors are measured by the same arithmetic in ``RunErrorShape`` and only their rendering differs.
public struct RunFailureShape: Sendable {
    /// The failures this shape measured, in the order and the spelling the run reported them in.
    ///
    /// **As the run spelled them, and not as the reader will see them.** Stating a location relative to the directory the answer is being read in is a display decision, and taking it before the failures reach here would put the reader's working directory inside the measurement that decides whether they are shown every failure or one of each kind. ``paths`` does it at the moment a line is composed instead.
    public let failures: [Failure]
    /// How this answer states those locations, and what stating them that way saved.
    public let paths: RunAnswerPaths
    /// What they measure to.
    public let census: RunFailureCensus
    /// The declarations those failures happened inside, where the repository could resolve them.
    ///
    /// Empty is the ordinary state and not a degraded one: a repository with no index, a capture taken somewhere else, a filename that names two files. The block then renders exactly as it would with no resolution at all, which is what makes the resolution safe to attempt.
    public let sites: RunFailureSites
    /// What re-arming the accessibility preference found on each simulator this run put its tests on, in argv order.
    ///
    /// Empty for every run that named no simulator, which is the whole of what makes it a *measurement* here: it is the one field of this shape that says whether a device could be at fault at all, and ``RunDominantFailureClass`` states nothing about a device without it.
    public let accessibility: [SimulatorAccessibility.Restoration]
}

public extension RunFailureShape {
    /// One failed test, in the plain terms this measurement needs.
    ///
    /// Deliberately a mirror of what a test-failure record carries rather than the record type itself: everything here is arithmetic over three strings, so taking them plainly keeps the measurement independent of the shape a run report's failures grow into next.
    struct Failure: Sendable, Equatable {
        public let name: String
        /// The source location as the framework printed it — `ZonePickTests.swift:13:9` from Swift Testing, an absolute path from XCTest, `nil` when it named none.
        public let location: String?
        public let message: String
        /// The arguments a parameterized case failed under, e.g. `size → .large`; `nil` for an ordinary test.
        ///
        /// Carried here rather than left to the caller because this type renders the failures it counted, and a parameterized function fails once per case at one location — so without the arguments the listing repeats one name and one line number and never says which case went wrong, which is the question the reader opened the answer with.
        public let arguments: String?
        /// The `↳` comment the framework printed beneath the failure, when it printed one.
        public let note: String?
        /// The haystack line a failed `.contains`/`.hasPrefix`/`.hasSuffix` is printed with, already worded — see ``RunTestFailure/closestLine``.
        public let closestLine: String?

        public init(name: String, location: String?, message: String, arguments: String? = nil, note: String? = nil, closestLine: String? = nil) {
            self.name = name
            self.location = location
            self.message = message
            self.arguments = arguments
            self.note = note
            self.closestLine = closestLine
        }
    }
}

public extension RunFailureShape {
    var failureCount: Int {
        census.count
    }

    var signatureCount: Int {
        census.signatures.count
    }

    var signatures: [RunFailureCensus.SignatureCount] {
        census.signatures
    }

    var fileCount: Int {
        census.fileCount
    }

    var inChangedFiles: RunFailureCensus.ChangedFileCount {
        census.inChangedFiles
    }

    /// The one value most of these failures read, where they read one — see ``RunDominantFailureClass``.
    var dominantClass: RunDominantFailureClass? {
        RunDominantFailureClass.of(failures.map(\.message), census: census, accessibility: accessibility)
    }

    /// The signature the most failures reduced to, or `nil` when there were no failures at all.
    var topSignature: RunFailureCensus.SignatureCount? {
        census.signatures.first
    }

    /// Measures `failures` against what the working tree has changed, against the code the repository resolved their locations to, and against what this run's restore found on the simulators it tested on, stating their locations as `paths` says to.
    static func of(
        _ failures: [Failure],
        changedFiles: RunChangedFiles,
        sites: RunFailureSites = .none,
        paths: RunAnswerPaths = .asPrinted,
        accessibility: [SimulatorAccessibility.Restoration] = []
    ) -> RunFailureShape {
        RunFailureShape(
            failures: failures,
            paths: paths,
            census: .of(failures, message: \.message, path: \.path, changedFiles: changedFiles),
            sites: sites,
            accessibility: accessibility
        )
    }
}

public extension RunFailureShape.Failure {
    /// The file the location names, with its line and column dropped — as the framework printed it, so `ZonePickTests.swift` from Swift Testing and a path from XCTest.
    ///
    /// Deliberately *not* reduced to a filename. ``RunFailureCensus/fileCount`` counts distinct files off this, and a filename throws away the only thing that tells two same-named test files apart; the reduction the changed-files match still needs is its own and lives where that comparison is.
    var path: String? {
        guard let location else {
            return nil
        }
        let path = location.prefix { $0 != ":" }
        return path.isEmpty ? nil : String(path)
    }
}

// MARK: - Rendering

public extension RunFailureShape {
    /// The classification block: the measurements, then every failure while the listing still fits — and the top signature with one example per signature once it does not.
    ///
    /// Lines rather than one string, so a caller splices it into a larger answer. Past the budget it **replaces** a listing of every failure rather than joining one — listing 666 of them is where a 70 KB answer comes from, and the line above them is what the reader actually needed.
    ///
    /// **The examples are one per signature, commonest first, and that is the whole point of having counted the signatures.** Taking the first few failures in the order the run printed them would show five near-identical messages under a line announcing 210 distinct ones — a listing that contradicts its own heading and spends the cap proving one thing five times. Ranking them means the reader gets the most common failure first, and the five lines cover five *kinds* of failure rather than five occurrences of one.
    ///
    /// **Each example that resolved says which declaration it happened in**, which is the line the reader would otherwise have spent a second round trip getting. See ``sited(_:)`` for what the two forms of it claim.
    ///
    /// **What the resolution may never do is change which form is served for its own width's sake.** Charged to ``RunFailureCensus/listingBudget`` like a line the run had printed, the `in …` line each entry gains would tip a package of 80 distinct failing tests in one file from naming all 80 to a sample of five the moment an index sat beside the log — the tool serving *less* the more it knew — and `RunFailureSites`' two-second deadline would make it worse than that: an unresolved answer is also what a loaded machine gets, so one run would have two forms decided by nothing the reader could see. ``RunFailureCensus/Entry`` carries the line as uncharged, so the size gate reads the same bytes resolved or not.
    ///
    /// **`allowance` does charge it, and the two rules are not in conflict.** The bound the log imposes is on how long the answer is, and a resolved line is a line in it — a 110-line log whose 52 failures each gained one would close on `raw: … (110 lines in, 162 out)`, a receipt stating a saving the answer had not made. Where the log is long enough for the listing it lists whatever it resolved, which is the 80-test case above and every ordinary red suite; where it is not, the block measures, and it does so because the answer would otherwise be longer than the thing it replaces. That is the one direction in which resolution may take the listing away, and it is the direction where a listing was never the honest answer.
    ///
    /// **And it is a sample only once it has to be**, which is ``RunErrorShape``'s rule applied to this side too — both of them decide on the rendered answer rather than on a count. A sample of failures loses their *names*, which no other field of the answer carries, so the block spends its whole budget listing them before it gives that up. A cap on the count would show five of six failures with distinct messages and count the sixth, and would collapse three sharing one message — which ``RunOutputFilter`` guarantees for every failure the framework declared and never explained, since they all get the identical sentence — to one signature, one name and a `×3`, with two test names gone and nothing in the answer saying so. Forty distinct failures have exactly the same problem five times over, and a count cannot tell the two cases apart because the difference between them is how much they *print*.
    ///
    /// **The clipping rule is the one thing this does not share with ``RunErrorShape``, and the asymmetry is deliberate.** There a listing prints the compiler's own sentence whole; here every line of a failure's own words is bounded by ``RunFailureCensus/wordsCap`` in *both* forms, because a message, a note and a set of arguments are arbitrary program output — a dumped SwiftUI view tree runs to 1.5 KB and one `↳` note in the corpus is a thousand characters of accessibility labels. One of those inside a listing that fits the budget is a paragraph where the reader wanted a line.
    ///
    /// - Parameter budget: What the whole answer has left of ``RunFailureCensus/listingBudget``, reduced by whatever this block lists. See ``RunErrorShape/rendered(within:spending:)``, which is the other section spending it.
    func rendered(within allowance: Int, spending budget: inout Int) -> [String] {
        renderedNaming(within: allowance, spending: &budget).lines
    }

    /// The classification block, with the names of the tests it printed — which ``RunFailingByFile`` needs to know what the block left unsaid.
    ///
    /// A listing names every test it covers; a sample names the lead of each signature it illustrates and the few others it nests beneath it.
    func renderedNaming(within allowance: Int, spending budget: inout Int) -> (lines: [String], named: Set<String>) {
        guard !failures.isEmpty else {
            return ([], [])
        }
        if let lines = listed(within: allowance, spending: &budget) {
            return (lines, Set(failures.map(\.name)))
        }
        return measured()
    }

    /// The same block standing on its own: the whole of ``RunFailureCensus/listingBudget`` to spend, and no log bounding how long it may be.
    func rendered() -> [String] {
        var budget = RunFailureCensus.listingBudget
        return rendered(within: .max, spending: &budget)
    }
}

private extension RunFailureShape {
    /// Every failure, each with its own name — or `nil` once that listing is no longer the answer worth serving.
    func listed(within allowance: Int, spending budget: inout Int) -> [String]? {
        census.listing(of: "failure", within: allowance, spending: &budget, entries: failures.indices.lazy.map { position in
            described(failures[position], at: position, standingFor: 1)
        })
    }

    /// The measurement, then one example per signature with the rest counted.
    func measured() -> (lines: [String], named: Set<String>) {
        var lines = census.heading(of: "failure")
        var namedTests: Set<String> = []
        // A signature that occurs once is not a shape, it is just the first failure — and that is listed
        // directly below. Clipped like every other line of a failure's own words in this block: the
        // normalisation elides literals and numbers and bounds nothing else, so a message wide enough to
        // be clipped in the example beneath would otherwise print whole here, above it.
        if let top = topSignature, top.count > 1 {
            lines.append("  ↳ top: \(RunFailureCensus.clipped(top.signature.text))  ×\(top.count)")
        }
        // Beneath the top signature and above the examples, because it is the claim neither of them can
        // make: the line above names the commonest kind, and this one names what the kinds have in
        // common — which is the fault, wherever a majority of the failures read one and the same value.
        if let dominant = dominantClass {
            lines.append(dominant.line)
        }
        let shown = census.signatures.prefix(RunFailureCensus.signatureCap)
        var named = 0
        for example in shown {
            let ranked = rankedTests(in: example.positions)
            // A signature two or three tests share is worth naming all of — the shared-helper case
            // this exists for. A signature dozens or hundreds of uniquely-named failures reduce to
            // (``manyFailuresSharingOneMessageAreAShapeEvenWhereNamingThemAllWouldFit``'s case) is not:
            // there the names are standing in for one repeated problem, and naming every one of them is
            // the listing this block exists to replace. Past ``Self/testsCap`` only the tests with the
            // most of the signature's failures keep their own line — most failures first, ties broken
            // by name — and what is left past that is counted, not named, on its own line rather than
            // folded into any one test's count.
            // The example is the lead's first case in ``rankedTests(in:)``'s argument order rather than the
            // first the run printed, so its message and note are the same case's from one run to the next.
            let lead = ranked[0]
            guard ranked.count > 1 else {
                lines.append(contentsOf: described(
                    failures[lead.positions[0]],
                    at: lead.positions[0],
                    standingFor: example.count,
                    everywhere: example.positions
                ).lines)
                named += example.count
                namedTests.insert(lead.name)
                continue
            }
            lines.append(contentsOf: described(
                failures[lead.positions[0]],
                at: lead.positions[0],
                standingFor: lead.positions.count,
                everywhere: lead.positions
            ).lines)
            let others = ranked.dropFirst().prefix(Self.testsCap - 1)
            // A test an earlier line already named in full is referred back to here rather than named again:
            // its arguments are in the answer once, and its count and location under this signature still
            // are too, so the lines beneath every signature add up to its `×N`.
            lines.append(contentsOf: otherTests(others, namedAbove: namedTests))
            namedTests.formUnion([lead.name] + others.map(\.name))
            // Only the lead's own count and each named other's own count are accounted here — never the
            // signature's total — so a test past the cap is never credited to one that stayed named.
            named += lead.positions.count + others.reduce(0) { $0 + $1.positions.count }
            if let more = moreTests(beyond: Self.testsCap, of: ranked) {
                lines.append(more)
            }
        }
        if let withheld = census.withheld(beyond: shown.count, of: "failure") ?? unnamed(beyond: named) {
            lines.append(withheld)
        }
        return (lines, namedTests)
    }

    /// One failure's entry: what failed, what it said, and — where the repository could place it — the declaration it happened in.
    ///
    /// `standingFor` is how many failures this line speaks for, and the multiplier is what says it stands for more than itself so a reader never reads one example as one failure. `everywhere` is the whole membership of that signature, which is what lets ``sited(_:everywhere:)`` make the stronger of its two claims; a listing passes none, because a line standing only for itself has nothing to generalise over.
    ///
    /// **An ``RunFailureCensus/Entry`` rather than lines, because the site line is not the run's and may not be measured as though it were.** The three lines above it are what the framework printed; the `in …` line beneath is what this checkout's index added, and charging a listing for it would make the same red suite name 80 tests without an index and five with one. Both forms compose an entry — the sample only ever prints it — so the split is written once, where the line is built.
    func described(_ failure: Failure, at position: Int, standingFor count: Int, everywhere positions: [Int] = []) -> RunFailureCensus.Entry {
        // Clipped for the reason the message beneath it is: this is unbounded input printed inside a
        // block whose stated ceiling on a failure's own words is `wordsCap`. Swift Testing writes
        // whatever `description` the argument has, so one `@Test(arguments:)` over a type with a long
        // one puts a paragraph on the example line, a line above the cap that bounds the message.
        let arguments = argumentsLabel(for: failure, everywhere: positions)
        let location = failure.location.map { " — \(paths.shown($0))" } ?? ""
        let shared = count > 1 ? "  ×\(count)" : ""
        let heading = "  \(failure.name)\(arguments)\(location)\(shared)"
        // A note's first line is the `↳` sentence; a list printed beneath it keeps its own lines.
        let noteLines = failure.note.map { $0.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) } ?? []
        let merged = noteLines.first.flatMap { Self.merging(failure.message, with: $0) }
        var lines = [heading, "    \(RunFailureCensus.clipped(merged ?? failure.message))"]
        if let closest = failure.closestLine {
            lines.append("    \(closest)")
        }
        if let note = noteLines.first, merged == nil {
            lines.append("    ↳ \(RunFailureCensus.clipped(note)) \(Self.adjacency)")
        }
        lines.append(contentsOf: noteLines.dropFirst().map { "      \(RunFailureCensus.clipped($0))" })
        // The failing test's own body is said on the heading, as a range beside the resolved path: the
        // charge stays the unresolved heading's, so the form is decided by the run alone as it is below.
        if let own = ownBody(of: failure, at: position, everywhere: positions) {
            lines[0] = "  \(failure.name)\(arguments) — \(own)\(shared)"
            let shortening = paths.shortening(of: failure.location) + heading.utf8.count - lines[0].utf8.count
            return RunFailureCensus.Entry(lines, shortenedBy: shortening)
        }
        return RunFailureCensus.Entry(
            lines,
            shortenedBy: paths.shortening(of: failure.location),
            uncharged: sited(position, everywhere: positions).map { [$0] } ?? []
        )
    }

    /// `message` with the `↳` note's evaluation appended, where the message is exactly `Expectation failed: ` followed by the note's text up to its first ` → `, and `nil` otherwise.
    ///
    /// Swift Testing prints `Expectation failed: <expression>` and then `↳ <expression> → <value>`, so the second line repeats the first up to its arrow. Where it does, the note is attributed by its content as well as by its position, which is why the merged line carries no adjacency marker: that marker discloses that position was the whole of the evidence. The match is the whole expression, never a suffix of the message: a user's comment is printed first, as a `↳` line of its own, and a comment such as `expected → really` under `Expectation failed: value == expected` ends on the same word the message does, so a suffix match would print the comment as the expression's value.
    static func merging(_ message: String, with note: String) -> String? {
        guard let arrow = note.range(of: " → ") else {
            return nil
        }
        let expression = note[..<arrow.lowerBound]
        guard !expression.isEmpty, message == "Expectation failed: \(expression)" else {
            return nil
        }
        return message + note[arrow.lowerBound...]
    }

    /// `<path>:<line> (body :<start>-<end>)`, the path stated as the rest of the answer states paths, where the failure resolved to the failing test's own declaration, and `nil` otherwise.
    ///
    /// Only a line standing for one failure gets this form, since a line standing for a signature makes the claim ``sited(_:everywhere:)`` words. A body that belongs to the test named beside it — a declaration written `@Test`, never a helper that merely shares the name — cannot be read as more than containment, so it carries no mode marker; any other declaration keeps the `in … (syntactic)` line.
    func ownBody(of failure: Failure, at position: Int, everywhere positions: [Int]) -> String? {
        guard positions.count <= 1, let resolved = declaration(of: position),
              Self.isTheTest(resolved, named: failure.name),
              let line = failure.location?.split(separator: ":").dropFirst().first
        else {
            return nil
        }
        return "\(paths.shown(sites.absolutePath(of: resolved))):\(line) (body :\(resolved.startLine)-\(resolved.endLine))"
    }

    /// Whether `resolved` is the test a failure's log name names.
    ///
    /// **Two spellings, told apart by their shape.** A name in `-[Module.Class method]` brackets is XCTest's: the declaration is the method of that class, which no attribute says, so the class and the method are compared. Any other name is Swift Testing's, and there the declaration has to be written `@Test` — a helper with the same base name is not the test.
    static func isTheTest(_ resolved: RunFailureSites.Declaration, named name: String) -> Bool {
        guard let logged = TestIdentifier.xctestLogName(name) else {
            return resolved.isSwiftTest && (resolved.name == name || resolved.name.hasSuffix(".\(name)"))
        }
        let member = ".\(logged.method)()"
        guard resolved.name.hasSuffix(member) else {
            return false
        }
        let container = resolved.name.dropLast(member.count)
        return !container.isEmpty && (logged.qualifiedType == container || logged.qualifiedType.hasSuffix(".\(container)"))
    }

    /// How many distinct arguments this signature's own example line names before it stops naming them and says how many there are instead.
    static var argumentsCap: Int {
        3
    }

    /// How many distinct tests a shown signature may cover before this block stops naming each of them and falls back to one example standing for the whole count.
    ///
    /// Two or three tests failing the same shared helper's expectation is the case ``otherTests(_:)`` exists for — each of them is a different fault wearing the same words, and the lead's own line would otherwise be the only one of them the answer ever named. Past this many the failures are chiefly one problem printed under many names — ``RunFailureCensus/isChieflyRepetition`` has already decided that much before this block runs at all — so only the tests with the most of the signature's own failures keep a line, and ``moreTests(beyond:of:)`` counts what is left rather than folding it into any one of them.
    static var testsCap: Int {
        3
    }

    /// Every distinct test among `positions`, grouped with its own membership and ranked most failures first — ties broken by name, never by whichever of them the run printed first — so a signature past ``Self/testsCap`` names the tests that matter most rather than however many the run happened to print first.
    ///
    /// Each test's own membership is in argument order, not the order the run printed it: parallel cases of one parameterised test finish in a different order every run, and the first of them is the case the example line prints.
    func rankedTests(in positions: [Int]) -> [(name: String, positions: [Int])] {
        var order: [String] = []
        var grouped: [String: [Int]] = [:]
        for position in positions {
            let name = failures[position].name
            if grouped[name] == nil {
                order.append(name)
            }
            grouped[name, default: []].append(position)
        }
        return order
            .map { (name: $0, positions: inArgumentOrder(grouped[$0] ?? [])) }
            .sorted { $0.positions.count == $1.positions.count ? $0.name < $1.name : $0.positions.count > $1.positions.count }
    }

    /// `positions` sorted by the arguments each failure carries, a failure with none first, then by location, and failures carrying the same arguments at the same location in the order the run printed them.
    func inArgumentOrder(_ positions: [Int]) -> [Int] {
        positions.enumerated()
            .sorted { left, right in
                let leftKey = (failures[left.element].arguments ?? "", failures[left.element].location ?? "")
                let rightKey = (failures[right.element].arguments ?? "", failures[right.element].location ?? "")
                return leftKey == rightKey ? left.offset < right.offset : leftKey < rightKey
            }
            .map(\.element)
    }

    /// The `with …` fragment of a failure's label, naming what its own words were where a signature covers only one, or every distinct argument its `×N` stands for where it covers several.
    ///
    /// **A `×N` beside one argument is a claim that argument failed `N` times over — which is only true where every one of `positions` shares it.** A parameterized test's three arguments failing under the same reduced message is the case this exists for: without it the block would print the first argument's name beside the whole count and say nothing about the other two, which is a reading a reviewer once gave. Where `positions` all carry the same argument (a repeated run of one case) or there is only one position, nothing changes: the bare argument is still the honest label.
    func argumentsLabel(for failure: Failure, everywhere positions: [Int]) -> String {
        let distinct = distinctArguments(sharing: failure.name, everywhere: positions)
        guard distinct.count > 1 else {
            return failure.arguments.map { " with \(RunFailureCensus.clipped($0))" } ?? ""
        }
        let shown = distinct.prefix(Self.argumentsCap)
        let remaining = distinct.count - shown.count
        let listed = shown.joined(separator: ", ") + (remaining > 0 ? ", and \(remaining) more" : "")
        // The list itself, not the label it would fill, is held to the words cap: past it the reader is
        // better served by the count than by a line of arguments cut mid-word.
        guard listed.utf8.count <= RunFailureCensus.wordsCap else {
            return " with \(distinct.count) arguments"
        }
        return " with \(listed)"
    }

    /// Every distinct argument that `positions` carries under `name`, sorted by its text — empty where fewer than two positions share it, since one position (or none) has nothing to distinguish.
    ///
    /// **Sorted, because the order the run printed them in is not the test's.** Swift Testing runs a parameterised test's cases in parallel, so the order they fail in changes from run to run and from one signature to the next within a run; the source order of the arguments is nowhere in the log. Sorted before ``Self/argumentsCap`` takes its prefix, so which arguments are named, and not only their order, is the same every run.
    func distinctArguments(sharing name: String, everywhere positions: [Int]) -> [String] {
        guard positions.count > 1 else {
            return []
        }
        var seen: Set<String> = []
        for position in positions {
            let candidate = failures[position]
            guard candidate.name == name, let arguments = candidate.arguments else {
                continue
            }
            seen.insert(arguments)
        }
        return seen.sorted()
    }

    /// One nested line for every other named test a shown signature covers, so a test the lead's own line never names still appears by name — its own location and, where it failed more than once, its own count.
    ///
    /// A signature is normalised message text, and two different tests sharing one wording can be two different faults wearing the same words: naming only the lead would let every other test the signature covers vanish from the answer entirely. Nested beneath the lead's message rather than printed at its indent, so the expectation text above reads as what the signature means rather than as belonging only to the first name.
    ///
    /// A test in `namedAbove` already has a line of its own under an earlier signature, so here it gets a back-reference — its name, location and count, without its arguments — rather than a second full line: still a line, because its failures under this signature are this signature's to account for.
    func otherTests(_ groups: some Sequence<(name: String, positions: [Int])>, namedAbove: Set<String>) -> [String] {
        groups.map { group in
            let failure = failures[group.positions[0]]
            let isNamedAbove = namedAbove.contains(group.name)
            let arguments = isNamedAbove ? "" : argumentsLabel(for: failure, everywhere: group.positions)
            let location = failure.location.map { " — \(paths.shown($0))" } ?? ""
            let shared = group.positions.count > 1 ? "  ×\(group.positions.count)" : ""
            let reference = isNamedAbove ? " (named above)" : ""
            return "    also: \(failure.name)\(arguments)\(location)\(reference)\(shared)"
        }
    }

    /// What a signature's own tests left unnamed past the first `cap` of them, ranked most failures first — nested like ``otherTests(_:)``, since it continues the same signature's claim rather than making a new one.
    func moreTests(beyond cap: Int, of ranked: [(name: String, positions: [Int])]) -> String? {
        let remaining = ranked.dropFirst(cap)
        guard !remaining.isEmpty else {
            return nil
        }
        let tests = remaining.count
        let failures = remaining.reduce(0) { $0 + $1.positions.count }
        return "    +\(tests) more test\(tests == 1 ? "" : "s") under this signature (\(failures) failure\(failures == 1 ? "" : "s"))"
    }

    /// What a measured block counted but never named, or `nil` when it named every failure it counted.
    ///
    /// **A loss only a failure block can suffer, which is why it is here rather than in the census.** A test failure is identified by its *name*; a compile error by its location, and `N files` above already bounds where the unshown ones are. So when a signature stands for more failures than the lead and ``otherTests(_:)`` between them name — everything ``moreTests(beyond:of:)`` counted rather than named — the block counts the rest under the `×N`s but their names appear nowhere in the answer, and no field carries them.
    ///
    /// It is stated only where ``RunFailureCensus/withheld(beyond:of:)`` says nothing, which is exactly where the block looks complete and is not: every signature illustrated, every number reconciling, and the names of everything past what was actually named gone. Where signatures *were* withheld that line already says the block is a sample and names the raw log, and a second sentence beneath it would be the same disclosure twice.
    func unnamed(beyond named: Int) -> String? {
        let count = census.count - named
        guard count > 0 else {
            return nil
        }
        return "  +\(count) more failure\(count == 1 ? "" : "s") under the signatures above, not named here — see the raw log"
    }
}

private extension RunFailureShape {
    /// How a `↳` note says what its attribution is worth, on the line it qualifies.
    ///
    /// ``RunTestFailure/note``'s own doc argues that "an approximation nobody states is the one that gets read as a fact", and a note printed with nothing on it would be exactly that — while the two claims beside it carry `(matched by name)` and `(syntactic)` inline for the same reason. Nothing in a log says which failure a continuation line belongs to, so adjacency is the whole of the evidence: the note is the sentence printed *directly beneath* this failure, and `xcodebuild` interleaving two runners' output can put a neighbour's there instead.
    ///
    /// It is a disclosure and not a warning, which is why the marker is this small: measured on the red capture, 3 of 634 attached notes are misattributed. The reading it wards off is that the sentence was matched to the failure by something.
    static var adjacency: String {
        "(by adjacency)"
    }

    /// Where this signature's failures happened, in the strongest form the resolution actually supports.
    ///
    /// **Two forms, and the difference between them is a claim about all of the failures rather than one of them.** The bare form describes the example printed directly above it and nothing else. The `all N` form says every failure that reduced to this signature is inside one declaration — which is the answer to the question a `×117` raises and never settles: 117 broken tests, or one helper that 117 tests reach through. Where a run's own report gives a name and a line that disagree, that line is the whole finding, and it is the thing no tool holding only the log can produce.
    ///
    /// **`all` means all, so one unresolved failure withdraws it.** ``declaration(of:)`` answers `nil` for a failure that named no location, for one whose file the repository could not identify, and for one past the resolution's own caps — and `nil` never equals the example's declaration, so the claim drops to the bare form rather than being made over a population that was only partly counted.
    ///
    /// **`(syntactic)` is on the line and not in a legend somewhere**, because a marker that can be separated from the claim it qualifies eventually is. It says the declaration was found by parsing the file and asking which range contains the line — a question about the bytes on disk, which is why it is never stale — and it warns the reader off the semantic reading standing right beside it: this is not what the failing line *called*, and it is not the build's index store talking.
    ///
    /// A listing passes no `positions` and so only ever gets the bare form, which is right: each of its lines stands for one failure, and there is no population to generalise over.
    func sited(_ position: Int, everywhere positions: [Int]) -> String? {
        guard let resolved = declaration(of: position) else {
            return nil
        }
        let everywhere = positions.count > 1 && positions.allSatisfy { declaration(of: $0) == resolved }
        let lead = everywhere ? "all \(positions.count) are in" : "in"
        return "    \(lead) \(resolved.described) (syntactic)"
    }

    /// The declaration the failure at `position` happened in.
    func declaration(of position: Int) -> RunFailureSites.Declaration? {
        failures[position].location.flatMap(sites.declaration(at:))
    }
}
