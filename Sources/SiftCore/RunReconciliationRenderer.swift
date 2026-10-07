//
// Copyright © Agulhas Labs
//

import Foundation

/// Renders a reconciled ordinary run — the verdict, the counts line, and then only the residue.
///
/// The same seven words the sharded answer prints, in the same order, so a reader who has learned one answer has learned both.
public struct RunReconciliationRenderer: Sendable {
    public init() {}

    /// The whole answer below the freshness header, which the engine puts on top of it.
    public func render(_ reconciliation: RunReconciliation) -> String {
        var sections: [[String]] = [[Self.scopeLine(reconciliation.scope)]]
        sections.append([Self.headline(reconciliation), "  \(reconciliation.counts.line)"])
        sections.append(Self.section("failed", reconciliation.failed.map(\.enumerated)))
        sections.append(Self.missingSection(reconciliation))
        sections.append(Self.lostSection(reconciliation))
        sections.append(Self.section("duplicated", reconciliation.duplicated.map(Self.duplicationLine)))
        sections.append(Self.section("excluded by XCTFail — counted in nothing", reconciliation.excluded.map(Self.excludedLine)))
        let lone = reconciliation.undecided.filter { !reconciliation.undecidedInGroups.contains($0) }
        sections.append(Self.section("conditional and never reported — counted in neither direction", lone.map(\.enumerated)))
        sections.append(Self.section(CountedGroup.undecidedMembersHeading, reconciliation.undecidedInGroups.map(\.enumerated)))
        sections.append(Self.section("declared under an #if this platform does not compile — not run here, counted in neither direction", reconciliation.compiledOut.map(\.enumerated)))
        sections.append(Self.outsideScopeSection(reconciliation))
        sections.append(reconciliation.notes)

        return sections
            .filter { !$0.isEmpty }
            .map { $0.joined(separator: "\n") }
            .joined(separator: "\n\n")
    }
}

extension RunReconciliationRenderer {
    /// The declared tests lifted out of the counts before expected could reach zero — excluded by `XCTFail`, conditional and never reported, or under an `#if` this platform does not compile — named for whichever answer needs to say why nothing was expected.
    static func liftedClauses(_ reconciliation: RunReconciliation) -> [String] {
        var lifted: [String] = []
        if !reconciliation.excluded.isEmpty {
            lifted.append("\(reconciliation.excluded.count) excluded by XCTFail")
        }
        if !reconciliation.undecided.isEmpty {
            lifted.append("\(reconciliation.undecided.count) conditional and never reported")
        }
        if !reconciliation.compiledOut.isEmpty {
            lifted.append("\(reconciliation.compiledOut.count) under an #if this platform does not compile")
        }
        return lifted
    }
}

private extension RunReconciliationRenderer {
    /// What bounded the expected set, first, because every number under it is a measurement inside that bound.
    static func scopeLine(_ scope: RunReconciliation.Scope) -> String {
        "\(scope.logPath) reconciled against the index, bounded by \(scope.manifest): \(scope.targets.joined(separator: ", ")). Nothing built, nothing booted — the run is read from its output."
    }

    /// The one line the caller acts on: a pass names what it covered, and anything else names the worst thing first.
    static func headline(_ reconciliation: RunReconciliation) -> String {
        guard !reconciliation.isGreen else {
            let iterations = reconciliation.iterations > 1 ? " over \(reconciliation.iterations) iterations" : ""
            let lost = reconciliation.counts.linesLost
            let lostClause = lost > 0 ? " and \(lost) more by their suite and run summaries" : ""
            return "✔ sift test --analyse --against — \(reconciliation.counts.passed) tests passed\(lostClause), every expected test accounted for\(iterations)"
        }
        guard reconciliation.counts.expected > 0 else {
            return nothingExpectedHeadline(reconciliation)
        }
        var worst: [String] = []
        if reconciliation.counts.failed > 0 {
            worst.append("\(reconciliation.counts.failed) failed")
        }
        if reconciliation.counts.missing > 0 {
            worst.append("\(reconciliation.counts.missing) missing")
        }
        if reconciliation.counts.duplicated > 0 {
            worst.append("\(reconciliation.counts.duplicated) duplicated")
        }
        return "✘ sift test --analyse --against — \(worst.joined(separator: " · ")) — this run may not be reported as passing, whatever its own summary said"
    }

    /// Nothing expected has two causes that send the reader to opposite places, so the headline says which one this was.
    ///
    /// Where the index declares tests in this container and the expected set is still empty, every one of them was lifted out of the counts — switched off in source, or conditional and never reported — and the sections naming them are what to read. Where it declares none at all, the log and the index are about different code, and where the log came from is what to check.
    static func nothingExpectedHeadline(_ reconciliation: RunReconciliation) -> String {
        let lifted = liftedClauses(reconciliation)
        guard lifted.isEmpty else {
            return "✘ sift test --analyse --against — nothing expected — every test the index declares in the targets \(reconciliation.scope.manifest) bounds was lifted out of the counts (\(lifted.joined(separator: " · "))), so nothing was checked either way and this log cannot be reported as passing. The sections below name them."
        }
        return "✘ sift test --analyse --against — nothing expected — the index declares no test in the targets \(reconciliation.scope.manifest) bounds, so this log was reconciled against nothing and cannot be reported as passing. Check the log came from this repository."
    }

    /// Everything expected that the run reported no ending for, which is the case the whole join exists for.
    static func missingSection(_ reconciliation: RunReconciliation) -> [String] {
        guard !reconciliation.missing.isEmpty || !reconciliation.shortfalls.isEmpty else {
            return []
        }
        var lines = ["missing — expected to report an ending, and did not:"]
        lines.append(contentsOf: reconciliation.missing.map { "  \($0.enumerated)" })
        lines.append(contentsOf: reconciliation.shortfalls.map { "  \($0.function): \($0.sentence)" })
        return lines
    }

    /// Every expected test whose own result line was lost, in a run that printed its suite passing and a passing summary, which is neither missing nor reported.
    static func lostSection(_ reconciliation: RunReconciliation) -> [String] {
        guard !reconciliation.lost.isEmpty || !reconciliation.lostByCount.isEmpty else {
            return []
        }
        var lines = ["result lines lost — started with no result line, in a Swift Testing run that printed the suite passing and a passing summary:"]
        lines.append(contentsOf: reconciliation.lost.map { "  \($0.enumerated)" })
        lines.append(contentsOf: reconciliation.lostByCount.map { "  \($0.function): \($0.lostSentence)" })
        return lines
    }

    static func duplicationLine(_ duplication: RunReconciliation.Duplication) -> String {
        "  \(duplication.test.enumerated) ended \(duplication.endings) times within iteration \(duplication.iteration)"
    }

    static func excludedLine(_ excluded: RunReconciliation.Excluded) -> String {
        guard let ending = excluded.ending else {
            return "  \(excluded.test.enumerated) — the run reported nothing for it"
        }
        return "  \(excluded.test.enumerated) — the run reported it \(Self.word(ending)), and nothing but this static read tells that from a real one"
    }

    static func word(_ ending: RunTestOutcomes.Ending) -> String {
        switch ending {
        case .passed: "passed"
        case .failed: "failed"
        case .skipped: "skipped"
        }
    }

    /// The targets this answer was never about, named so their absence from the counts is a fact rather than a gap.
    static func outsideScopeSection(_ reconciliation: RunReconciliation) -> [String] {
        guard !reconciliation.outsideScope.isEmpty else {
            return []
        }
        let total = reconciliation.outsideScope.reduce(0) { $0 + $1.declared }
        return ["outside this run's container (\(reconciliation.outsideScope.count) targets, \(total) declared tests) — judged by nothing here:"]
            + reconciliation.outsideScope.map { "  \($0.target) — \($0.declared) declared tests" }
    }

    static func section(_ heading: String, _ lines: [String]) -> [String] {
        guard !lines.isEmpty else {
            return []
        }
        return ["\(heading) (\(lines.count)):"] + lines.map { $0.hasPrefix("  ") ? $0 : "  \($0)" }
    }
}
