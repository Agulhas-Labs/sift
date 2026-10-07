//
// Copyright © Agulhas Labs
//

/// The answer to `affected --reached <name>`: whether one test or suite is among those the walk reached, whatever the lists above cut off.
///
/// The per-test and per-suite lists stop at their caps and count the rest, which leaves no way to ask about one name. This reads the whole reached set instead, so a name in the truncated tail is answered as plainly as one in the printed prefix.
struct AffectedProbe {
    /// The most matches printed for one name, so a fragment that matches most of the answer cannot reprint it.
    static var matchCap: Int {
        AffectedRenderer.testListCap
    }

    /// The tests each whole suite among `reached` runs, as the inventory declares them, so a member the list never prints on a line of its own can be answered for.
    static func members(of reached: some Sequence<TestSymbol>, in inventory: TestInventory?) -> [TestSymbol: [TestSymbol]] {
        guard let inventory else { return [:] }
        let declared = inventory.tests.map(TestSymbol.init(declared:))
        var members: [TestSymbol: [TestSymbol]] = [:]
        for suite in reached where suite.function == nil && suite.suite != nil {
            members[suite] = declared.filter { suite.wholeSuiteRuns($0) }.sorted()
        }
        return members
    }

    /// The lines that answer for `name`, spelled as the list prints a test: `Target.Suite/function()`.
    ///
    /// A listed entry matches when it contains the name. A member of a suite reached whole matches when the inventory lists it under that suite by a name containing it, and is said to be run by the suite; a name under such a suite that the inventory does not list is said not to be a known test, rather than covered.
    static func lines(for name: String, reached: [AffectedRenderer.ReachedTest], members: [TestSymbol: [TestSymbol]], depth: Int, walkedTo: Int? = nil) -> [String] {
        let hops = "\(depth) reference hop\(depth == 1 ? "" : "s")"
        let membersBySuite = Dictionary(members.map { ($0.key.described, $0.value) }) { first, _ in first }
        var matches: [(entry: AffectedRenderer.ReachedTest, member: TestSymbol?)] = []
        for entry in reached.sorted(by: { ($0.target, $0.described) < ($1.target, $1.described) }) {
            if entry.described.contains(name) {
                matches.append((entry, nil))
            } else {
                matches += (membersBySuite[entry.described] ?? []).filter { spellings(of: $0).contains { $0.contains(name) } }.map { (entry, $0) }
            }
        }
        guard !matches.isEmpty else {
            if let suite = members.keys.sorted().first(where: { suite in spellings(of: suite).contains { name.hasPrefix($0 + "/") || name.hasPrefix($0 + ".") } }) {
                return ["", "reached? \(name) — not a known test: \(suite.described), which the walk reached whole, declares no test by that name in the inventory."]
            }
            return [
                "",
                "reached? \(name) — not reached within \(hops)\(walkedOn(depth: depth, to: walkedTo)).",
                "  that is not evidence that it is unaffected: the index found no reference to it, which the limits above list ways of being wrong about.",
            ]
        }
        var lines = ["", "reached? \(name) — \(matches.count) match\(matches.count == 1 ? "" : "es"), within \(hops):"]
        for (entry, member) in matches.prefix(matchCap) {
            var detail = ["\(entry.depth) hop\(entry.depth == 1 ? "" : "s")"]
            if entry.nameMatch {
                detail.append("name match")
            }
            if member != nil {
                detail.append("run by \(entry.described), reached whole")
            }
            lines.append("  \(member?.described ?? entry.described) — \(detail.joined(separator: ", ")) — \(entry.location)")
        }
        if matches.count > matchCap {
            lines.append("  truncated: \(matches.count - matchCap) more matches — name more of it")
        }
        return lines
    }

    /// What the walk-on adds to "not reached within": the hops it went on to from the changed files that reached no test within the bound.
    private static func walkedOn(depth: Int, to walkedTo: Int?) -> String {
        guard let walkedTo, walkedTo > depth else { return "" }
        return ", nor within the \(walkedTo) hops the walk went on to from the changed files its note names"
    }

    /// The two ways a test is written: as the list prints it, a nested Swift Testing suite slash-separated, and with the suite path dotted, as it is declared.
    private static func spellings(of test: TestSymbol) -> [String] {
        let dotted = [test.target, test.suite].compactMap(\.self).joined(separator: ".") + (test.function.map { (test.suite == nil ? "." : "/") + $0 } ?? "")
        return [test.described, dotted]
    }
}
