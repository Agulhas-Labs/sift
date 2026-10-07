//
// Copyright © Agulhas Labs
//

import Foundation

/// The one value most of a run's failures read, where they read one at all — the claim a census of signatures structurally cannot make.
///
/// **A signature elides exactly the thing this counts.** ``RunFailureSignature`` replaces every string literal with `"…"` so that failures written differently collapse onto one another, which is what turns 434 distinct messages into 210 kinds — and it is also what makes `labels → ""` and `labels → "Sprockets"` the same kind. So a run whose whole suite compared against an empty accessibility tree renders as hundreds of signatures with nothing in common, while the one fact that explains all of them is the value sitting inside each message, elided from every line the block prints.
///
/// **That case is the most expensive false alarm this command has measured.** A package run after a simulator boot failed 466 tests over 215 signatures; the answer compressed 14,920 lines to 31, and all 31 said the same thing in different words. The reader's next step was three more suite runs. What was missing was one line: *461 of these 466 compare against an empty read, and that is consistent with the device's accessibility preference having been off for the run*.
///
/// **It is stated generally and the accessibility clause is the special case.** What the detection asserts is arithmetic — N of M failures read one and the same value — and the value may be an empty string, an empty array, `nil`, or the same timeout sentence. Only where the shared value is an *empty* one, read as the subject of the expectation by an expression that names an accessibility tree, on a simulator this run's own restore found the preference switched off on, spread over more files than a block can illustrate and landing in nothing this working tree has changed, does the line go on to offer a reading of the empty value and whatever the reader has left to do: five independent markers, because even a *possible* device fault stated over a real regression costs the reader the suite runs this exists to save.
///
/// **What that clause offers is a consistency, never a cause**, because both readings the device marker rests on are taken after the wrapped command has returned. See ``line`` for the claim it is allowed to make and ``DeviceFault`` for the two things the reader may have left to do.
public struct RunDominantFailureClass: Sendable, Equatable {
    /// The shared value, exactly as the framework expanded it — `""`, `[]`, `nil`, a timeout sentence.
    public let value: String
    /// The expression that read it in most of those failures, which is what makes the value legible.
    ///
    /// Most rather than first, because the first is an accident of the order the run printed its failures while the commonest is the reading the reader is being asked to recognise.
    public let expression: String
    /// How many of the run's failures read it.
    public let count: Int
    /// How many failures the run recorded in all.
    public let total: Int
    /// How many distinct signatures those failures are spread over — the number that says this crosses the census rather than restating one row of it.
    public let signatures: Int
    /// Whether the failures have the shape of an empty in-process accessibility tree, whatever the device read: every marker ``deviceFault`` rests on except the device itself.
    ///
    /// Held apart from the device because the answer asks it of a simulator whose preference read on: such a device earns no clause here, but the line about it is owed only where the failures look like this.
    public let readsEmptyTree: Bool
    /// The device fault every marker of an empty in-process accessibility tree is consistent with, or `nil` where they do not all hold — which is what earns the line its reading of the empty value and whatever is left to do about it.
    public let deviceFault: DeviceFault?
}

public extension RunDominantFailureClass {
    /// What this run's own restore found on the simulator whose accessibility preference the empty reads are consistent with, and which of two things the reader has left to do.
    ///
    /// Both cases say the preference was off *when the run ended*, because that is what the restore read on the device, and the restore reads only once the wrapped command has returned; they differ only in whether it is off still. Neither says it was off *while the tests ran* — a session teardown switches it off as it ends, which reads the same — and ``line`` is worded to that limit. A run that never put a test on a simulator has neither, and that is the marker that keeps this clause off a package run entirely.
    enum DeviceFault: Sendable, Equatable {
        /// This run found the preference off and switched it back on, so nothing is left to do but run the suite again.
        case reArmed(udid: String?)
        /// This run could not switch it back on, or could not see that the write held, so the reader has to.
        case stillOff(udid: String?)
    }
}

public extension RunDominantFailureClass {
    /// The dominant class of `messages`, measured against the census taken over the same failures in the same order, or `nil` where there is no one value to lead with.
    ///
    /// **Three terms, and each is a boundary rather than a tuned constant.** *More than half the failures* is the first: it is the only non-arbitrary point on that axis, since below it the majority of the run disagrees with the line and the line would be describing a faction. *More than ``RunFailureCensus/signatureCap`` failures* is the floor, the same one ``RunFailureCensus/isChieflyRepetition`` takes, because a run small enough for the block to name every failure has the values themselves on the page. And *more than one signature* is the term that keeps this from being a second printing of a line the block already has: within a single signature the `↳ top:` line above already names the shape, and a run that is chiefly one message does not need to be told twice.
    ///
    /// **Every tally here is over each failure's *distinct* readings**, so a message comparing `""` against `""` counts once rather than twice, a value is never made dominant by one failure mentioning it repeatedly, and — the part that decides which expression gets named — one compound `#expect(a.labels.isEmpty && b.labels.isEmpty)` casts one vote for `labels` rather than two. Counting occurrences instead would let a handful of compound assertions outvote a majority of simple ones and name the wrong expression, which is the expression the accessibility test is then applied to. Ties are broken on the value's own text so the same run always renders the same way.
    ///
    /// - Parameter accessibility: What re-arming the preference found on each simulator this run put its tests on, in argv order — empty for a run that named no simulator at all. See ``DeviceFault`` for why the clause about a device is withheld without it.
    static func of(
        _ messages: [String],
        census: RunFailureCensus,
        accessibility: [SimulatorAccessibility.Restoration] = []
    ) -> RunDominantFailureClass? {
        guard census.count > RunFailureCensus.signatureCap else {
            return nil
        }
        var signatureOfPosition: [Int: Int] = [:]
        for (rank, signature) in census.signatures.enumerated() {
            for position in signature.positions {
                signatureOfPosition[position] = rank
            }
        }
        var positions: [String: [Int]] = [:]
        var expressions: [String: [String: Int]] = [:]
        var subjects: [String: [String: Int]] = [:]
        for (position, message) in messages.enumerated() {
            var countedValues: Set<String> = []
            var countedReadings: Set<Reading> = []
            for (rank, reading) in readings(in: message).enumerated() {
                if countedValues.insert(reading.value).inserted {
                    positions[reading.value, default: []].append(position)
                }
                if countedReadings.insert(reading).inserted {
                    expressions[reading.value, default: [:]][reading.expression, default: 0] += 1
                }
                if rank == 0 {
                    subjects[reading.value, default: [:]][reading.expression, default: 0] += 1
                }
            }
        }
        guard let value = commonest(of: positions.mapValues(\.count)),
              let shared = positions[value], shared.count * 2 > census.count
        else {
            return nil
        }
        let spread = Set(shared.compactMap { signatureOfPosition[$0] })
        guard spread.count > 1, let expression = commonest(of: expressions[value] ?? [:]) else {
            return nil
        }
        let readsEmptyTree = readsEmptyTree(
            value,
            read: expression,
            subjectOf: subjects[value]?[expression] ?? 0,
            among: shared.count,
            over: census
        )
        return RunDominantFailureClass(
            value: value,
            expression: expression,
            count: shared.count,
            total: census.count,
            signatures: spread.count,
            readsEmptyTree: readsEmptyTree,
            deviceFault: readsEmptyTree ? fault(among: accessibility) : nil
        )
    }

    /// The one line, printed above the examples rather than in place of them.
    ///
    /// **It leads and never suppresses.** The signatures it covers are listed underneath exactly as they were, because a failure is identified by its name and this line carries none: a reader who has just been told that 461 of 466 failures are one fault still needs somewhere to start reading, and the five the block would have shown are as good a start as they ever were. The whole of what this changes is that the first thing read is the fault rather than the fifth spelling of it.
    ///
    /// **The device clause claims a consistency and names what it cannot rule out.** Both readings behind ``deviceFault`` are taken after the wrapped command has returned — ``SimulatorAccessibility/restore(after:run:pause:now:)`` polls for the teardown once the run ends — so a preference that was off for the whole run and one a session teardown switched off as that run ended are the same reading. Nearly every wrapped simulator run produces the second, which is why the line may say the empty reads are *consistent with* the preference having been off and may not say the preference is why they are empty, still less that the code is not: a genuine regression on a clean tree passes every marker here, and a line blaming the device over one talks the reader out of a true failure and costs the suite runs this whole clause exists to save.
    ///
    /// **What follows the clause is whatever the reader has left to do, and never what this run has already done.** Wherever this clause is earned the answer leads its failures with the device's own accessibility line, which says what the restore did and, where the preference is off still, carries the one command that re-arms it. So the device a run re-armed is named and the reader is asked to re-run, and a device left off points at that line's command rather than printing a second copy of it a line below the first.
    var line: String {
        let reading = RunFailureCensus.clipped("\(expression) → \(value)")
        guard let deviceFault else {
            return "  ↳ \(count) of \(total) failures read one and the same value (\(reading)), across \(signatures) signatures"
        }
        let clause = "  ↳ \(count) of \(total) compare against an EMPTY accessibility read (\(reading)) — consistent with the simulator's accessibility preference having been off for this run, though it was read only after the tests finished, so a teardown that switched it off at the end reads the same."
        return switch deviceFault {
        case let .reArmed(udid):
            "\(clause) This run switched it back on for \(udid ?? "<udid>"), so re-run as it stands"
        case .stillOff:
            "\(clause) Re-arm it with the command in the accessibility line leading these failures, and re-run"
        }
    }
}

private extension RunDominantFailureClass {
    /// One expanded subexpression as the framework printed it: what was read, and what it read.
    ///
    /// Hashable because the tallies are over a failure's *distinct* readings, and two readings are the same reading only where both halves match.
    struct Reading: Hashable {
        let expression: String
        let value: String
    }

    /// The marker Swift Testing puts between a subexpression and the value it evaluated to.
    static var expansion: Character {
        "→"
    }

    /// The values that say a read came back empty.
    ///
    /// An empty string, an empty array and an empty dictionary, and deliberately not `nil`: an accessibility tree that was never built reads as an empty collection, while `nil` is what an ordinary optional lookup misses with and is far too common a value to hang a diagnosis on. The general line still names a dominant `nil`; only the clause about the device is withheld from it.
    static var emptyReads: Set<String> {
        ["\"\"", "[]", "[:]"]
    }

    /// The names an in-process accessibility read goes by, matched on the last component of the expression.
    ///
    /// The vocabulary of the tree itself rather than of any one project: an expression holding `accessibility` anywhere along its dotted path qualifies outright, and beyond that the three plural nouns a hosted view's tree is read into. A singular `label` is pointedly absent — one label reading empty is an ordinary expectation about one view, and it is the *collection* coming back empty that says no tree was built.
    ///
    /// **These three nouns alone are the weakest marker in the set, and they carry the clause only because a device marker stands beside them.** `elements` is an XML node's children and a collection's contents as readily as a tree's; `labels` is a chart's axis and a form's fields. On their own they name a regression as often as a device, which is why nothing here decides anything without the device reading the guard below it takes.
    static var accessibilityReads: Set<String> {
        ["elements", "identifiers", "labels"]
    }

    /// Whether the value, the expression that read it and the spread of the failures together have the shape of an empty in-process accessibility tree — four of the five markers the device clause rests on, the device being the fifth, which ``fault(among:)`` reads.
    ///
    /// **Five markers, and all five are required, because the line they unlock offers the reader a reading of their whole run.** The value is empty; it was read as the *subject* of most of the failures that share it, by an expression that names an accessibility read; this run put its tests on a simulator whose accessibility preference it found switched off; the failures landed in nothing this working tree has changed; and they are spread over more files than the block could illustrate. What the five buy is a clause worth printing, not a cause: the reading behind the third is taken after the wrapped command has returned, so ``line`` states the consistency and says outright that it cannot tell a preference off for the whole run from a teardown that switched it off at the end.
    ///
    /// **The device is the marker that does the discriminating, and the only one a package run cannot satisfy by accident.** A `swift test` run names no simulator, so ``SimulatorAccessibility/restore(after:run:pause:now:)`` returns nothing for it and this clause is unreachable however its expressions are spelled — which matters because `elements`, `identifiers` and `labels` are ordinary names for ordinary collections. Nor is a simulator enough on its own: a device whose preference read on throughout, or whose domain no session has ever written, is a device the empty tree is *not* explained by, and those restorations are passed over here exactly like a run with none.
    ///
    /// **The subject marker is what keeps an expected value from being read as a reading.** Swift Testing expands both sides of a comparison, so `(bay.name → "Alpha") == (labels → "")` offers `labels → ""` to a tally that cannot see it is the value the test was *hoping for*. The empty read that says a tree was never built is the thing the expectation is about, which is the first expansion the framework printed; a constant on the far side of an `==` may still make the general line, and may not make this one.
    ///
    /// **`0 in changed files` is read strictly, and only where it is a count at all.** A signal that could not be established is never read as zero, and one failure in a changed file is enough to withhold the clause. It is the weakest of the five in the case that matters, though: a clean tree is what CI and a freshly committed branch both have, so it discriminates nothing there and the device is what the answer rests on.
    static func readsEmptyTree(
        _ value: String,
        read expression: String,
        subjectOf subjects: Int,
        among shared: Int,
        over census: RunFailureCensus
    ) -> Bool {
        emptyReads.contains(value)
            && subjects * 2 > shared
            && namesAnAccessibilityRead(expression)
            && census.inChangedFiles == .count(0)
            && census.fileCount > RunFailureCensus.signatureCap
    }

    /// Whether the expression names an accessibility read: `accessibility` anywhere along its dotted path, or one of ``accessibilityReads`` as the name it ends on.
    ///
    /// The whole path rather than the last component, because a path may spell the tree out halfway along it and end on a name this set does not carry.
    static func namesAnAccessibilityRead(_ expression: String) -> Bool {
        let lowered = expression.lowercased()
        guard !lowered.contains("accessibility") else {
            return true
        }
        return accessibilityReads.contains(lowered.split(separator: ".").last.map(String.init) ?? lowered)
    }

    /// What this run's restores amount to as one fault, or `nil` where nothing they found says the preference was off when the run ended.
    ///
    /// **Only the two states that *read* the preference off count.** A device this run restored was seen off and put back; a device it failed to restore is known off. Everything else is a device the empty tree is not evidence about — read on, never switched off, out of reach, or a reading that could not be taken at all — and not even a clause claiming a consistency may be built on any of them. A device that was never reached is the clearest of those: an unreachable device says nothing whatever about the preference, so widening the set to admit it would print the clause over a reading that does not exist. The cost of leaving it out is named in `Docs/Design.md`.
    ///
    /// A device left off outranks one this run re-armed, however argv ordered them, because it is the one the reader still has to do something about.
    static func fault(among restorations: [SimulatorAccessibility.Restoration]) -> DeviceFault? {
        var reArmed: DeviceFault?
        for restoration in restorations {
            switch restoration.state {
            case .failed:
                return .stillOff(udid: restoration.udid)
            case .restored:
                if reArmed == nil {
                    reArmed = .reArmed(udid: restoration.udid)
                }
            case .alreadyOn, .neverSwitchedOff, .unreached, .unconfirmed, .undetermined:
                continue
            }
        }
        return reArmed
    }

    /// The commonest key of `tally`, ties broken on the key's own text so one run always renders one way.
    static func commonest<Key: Comparable>(of tally: [Key: Int]) -> Key? {
        tally.max { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }?.key
    }

    /// Every `subexpression → value` the framework expanded inside `message`, in the order it printed them.
    ///
    /// **Bounded by the parentheses the framework already put there.** Swift Testing prints an expansion inside the parentheses of the expression it belongs to — `(labels → "").contains(bay.signage → "Sprockets")` — so the open paren enclosing the marker is where the subexpression starts and its matching close is where the value ends. Reading the value forward to the end of the line instead would make every expansion in a compound expectation a value of its own, none of which any other failure could share.
    ///
    /// String literals are skipped whole, because a parenthesis or a marker inside one is text rather than structure. A marker with no enclosing paren, and a paren that never closes, are both passed over: interleaved output is the only way either arrives, and there is no bound to read a value to.
    static func readings(in message: String) -> [Reading] {
        var readings: [Reading] = []
        var frames: [(open: String.Index, marker: String.Index?)] = []
        var index = message.startIndex
        while index < message.endIndex {
            switch message[index] {
            case "\"":
                index = afterLiteral(in: message, openingAt: index)
                continue
            case "(":
                frames.append((open: message.index(after: index), marker: nil))
            case ")":
                if let frame = frames.popLast(), let marker = frame.marker {
                    readings.append(Reading(
                        expression: trimmed(message[frame.open ..< marker]),
                        value: trimmed(message[message.index(after: marker) ..< index])
                    ))
                }
            case Self.expansion:
                if let frame = frames.last, frame.marker == nil {
                    frames[frames.count - 1].marker = index
                }
            default:
                break
            }
            index = message.index(after: index)
        }
        return readings
    }

    /// Everything after the closing quote of the literal opening at `index`, or the character after the quote itself where it never closes.
    static func afterLiteral(in message: String, openingAt index: String.Index) -> String.Index {
        var scan = message.index(after: index)
        while scan < message.endIndex {
            switch message[scan] {
            case "\\":
                scan = message.index(scan, offsetBy: 2, limitedBy: message.endIndex) ?? message.endIndex
            case "\"":
                return message.index(after: scan)
            default:
                scan = message.index(after: scan)
            }
        }
        return message.index(after: index)
    }

    static func trimmed(_ text: Substring) -> String {
        text.trimmingCharacters(in: .whitespaces)
    }
}
