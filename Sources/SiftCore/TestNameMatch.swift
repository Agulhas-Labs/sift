//
// Copyright © Agulhas Labs
//

import Foundation

/// What the names a run's log reported say about the tests one shard was given to run.
///
/// **The frameworks are told apart by how the log reported a test, never by reading the identifier.** An enumerated identifier is `Target/Type/function()` whichever framework declared it, and the superclass that would settle it is not in the enumeration at all — so a rule reading `test…()` as XCTest would misfile every Swift Testing function whose author spelled it that way. A name in `-[…]` brackets was printed by XCTest; everything else is read as Swift Testing's.
///
/// **XCTest is matched by identity, Swift Testing by function name where that name is unique.** Swift Testing's log names no suite, so where a shard expects two tests declaring `formatsUppercase()` in different suites, no reading of the log can say which one ended. Those tests are reported as ``byCountOnly`` rather than matched: a merge that guessed between them would name the wrong test as missing, and a wrong name is worse than an admitted gap.
///
/// **A reported name that claims no expected test is returned, never fatal.** It is a fact about the run — a display name the enumeration never printed, a test from a plan the shard did not expect — and the answer's job is to carry it, not to stop on it.
public struct TestNameMatch: Sendable, Equatable {
    /// Every expected test, and the reported names that named it — an empty array where nothing did, and where the test could only be reconciled by count.
    public let named: [TestIdentifier: [String]]

    /// The expected tests one function name could not be told apart by, with the reported names that carried it.
    public let byCountOnly: [Ambiguity]

    /// Reported names no expected test claimed: names matched as XCTest before names matched as Swift Testing, each half kept in `reported`'s own order — two sorted runs concatenated by framework, since `RunReconciler` passes `reported` sorted.
    public let unclaimed: [String]
}

// MARK: - The tests a name cannot be told apart by

public extension TestNameMatch {
    /// One function name that more than one of a shard's expected tests answers to, and what the log said about it.
    struct Ambiguity: Sendable, Equatable {
        /// The bare function name the log reported, which more than one expected test declares.
        public let function: String

        /// The expected tests declaring it, sorted by identifier so a plan reads the same way twice.
        public let expected: [TestIdentifier]

        /// The reported names that carried it, in the order they were given.
        public let reported: [String]

        /// The framework whose log produced this ambiguity, which decides why it could not be told apart.
        public let framework: Framework
    }

    /// The sentence the answer owes when some of this shard's tests can only be reconciled by count, or `nil` when every reported name settled on one test.
    var countOnlyNote: String? {
        guard !byCountOnly.isEmpty else {
            return nil
        }
        let frameworks = Ambiguity.Framework.allCases.filter { framework in byCountOnly.contains { $0.framework == framework } }
        return frameworks.map { framework in
            let functions = byCountOnly.filter { $0.framework == framework }.map(\.function).joined(separator: ", ")
            return "Reconciled by count only: \(functions). \(framework.countOnlyCause), so an ending cannot be matched to one of them."
        }.joined(separator: " ")
    }
}

public extension TestNameMatch.Ambiguity {
    /// The framework whose log produced one ambiguity, and so the reason it could not be told apart.
    enum Framework: String, Sendable, CaseIterable {
        case xctest = "XCTest"
        case swiftTesting = "Swift Testing"

        /// Why this framework's log leaves a function name unable to be told apart, for the sentence `countOnlyNote` owes.
        var countOnlyCause: String {
            switch self {
            case .swiftTesting:
                "Swift Testing's log names these tests by their function alone and its shard expected more than one test declaring each"
            case .xctest:
                "XCTest's log named these tests by their class without their target and its shard expected more than one target declaring that class"
            }
        }
    }
}

// MARK: - Matching

extension TestNameMatch {
    /// Matches the names a shard's log reported against the tests the plan gave that shard.
    ///
    /// Two passes, in that order, because the first is what decides the second's population. XCTest names are read first and the tests they claim are XCTest's; what is left over is the shard's *Swift Testing* set, and uniqueness of a function name is asked only within it — which is what the rule says, and it cannot be asked before the frameworks have been separated.
    ///
    /// **The XCTest pass is itself tiered.** A name is matched exactly first — `Module.Class/method`, `moduleName` derived from the target's own name — and only where a target claimed nothing exactly does its class-and-method-alone form (``TestIdentifier/matchesByClassAndMethod(xctestLogName:)``) get asked of the names still unclaimed, for a bundle whose `PRODUCT_MODULE_NAME` is neither the target's name nor derivable from it. The risk this carries is bounded but real: two targets that both claimed nothing exactly and both declare a same-named class read the same loose name as ambiguous between them, same as any other name two tests could answer to — the existing `byCountOnly` path, not a wrong guess — while a target that matched even one test exactly is never offered the loose tier at all, so two targets with a same-named class still reconcile exactly wherever either of them logs its own qualifier.
    public static func reconcile(expected: [TestIdentifier], reported: [String]) -> TestNameMatch {
        var named = Dictionary(uniqueKeysWithValues: Set(expected).map { ($0, [String]()) })
        var unclaimed: [String] = []
        var ambiguous: [Ambiguity.Framework: [String: Ambiguity]] = [:]

        func record(_ name: String, owners: [TestIdentifier], framework: Ambiguity.Framework) {
            guard let first = owners.first else {
                unclaimed.append(name)
                return
            }
            guard owners.count > 1 else {
                named[first, default: []].append(name)
                return
            }
            let standing = ambiguous[framework]?[first.functionName]
            ambiguous[framework, default: [:]][first.functionName] = Ambiguity(
                function: first.functionName,
                expected: union(standing?.expected ?? [], owners),
                reported: (standing?.reported ?? []) + [name],
                framework: framework
            )
        }

        // Every rule below requires the log name's function to be the test's bare function name, so a
        // name is asked only of the tests declaring that function, in expected order: the owners a
        // scan of every expected test would find, at the cost of a lookup rather than the scan.
        let byFunction = Dictionary(grouping: expected, by: \.functionName)
        let xctestNames = reported.compactMap { name in TestIdentifier.xctestLogName(name).map { (name: name, method: $0.method) } }
        let exactMatches = xctestNames.map { name, method in
            byFunction[method, default: []].filter { $0.matches(xctestLogName: name) }
        }
        let unmatchedTargets = Set(expected.map(\.target)).subtracting(exactMatches.flatMap { $0.map(\.target) })

        var claimed: Set<TestIdentifier> = []
        for ((name, method), exact) in zip(xctestNames, exactMatches) {
            var owners = exact
            if owners.isEmpty, !unmatchedTargets.isEmpty {
                owners = byFunction[method, default: []].filter {
                    unmatchedTargets.contains($0.target) && $0.matchesByClassAndMethod(xctestLogName: name)
                }
            }
            claimed.formUnion(owners)
            record(name, owners: owners, framework: .xctest)
        }

        for name in reported where TestIdentifier.xctestLogName(name) == nil {
            let function = String(RunOutputFilter.undecorated(name).prefix { $0 != "(" })
            let owners = byFunction[function, default: []].filter { !claimed.contains($0) && $0.matches(swiftTestingLogName: name) }
            record(name, owners: owners, framework: .swiftTesting)
        }

        // A test named unambiguously by one line and ambiguously by another is still a test this
        // shard cannot settle — two lines claiming it is exactly the doubt the group exists for — so
        // the whole group's matches are dropped rather than one of them kept.
        for ambiguity in ambiguous.values.flatMap(\.values) {
            for test in ambiguity.expected {
                named[test] = []
            }
        }
        let byCountOnly = ambiguous.values.flatMap(\.values).sorted {
            $0.function == $1.function ? $0.framework.rawValue < $1.framework.rawValue : $0.function < $1.function
        }
        return TestNameMatch(named: named, byCountOnly: byCountOnly, unclaimed: unclaimed)
    }

    /// `owners` added to `standing`, each test once, in identifier order — so an ambiguity reads the same way whichever line reached it first.
    private static func union(_ standing: [TestIdentifier], _ owners: [TestIdentifier]) -> [TestIdentifier] {
        var seen = Set(standing)
        var result = standing
        for test in owners where seen.insert(test).inserted {
            result.append(test)
        }
        return result.sorted { $0.enumerated < $1.enumerated }
    }
}

extension TestNameMatch.Ambiguity {
    /// The tests one `@Test("…")` literal names, which a log printing only that literal cannot tell apart: the group a quoted ending is reconciled over by count where more than one test still waiting to report declares it.
    init(sharedLiteral literal: String, declaredBy tests: [TestIdentifier]) {
        self.init(function: literal, expected: tests.sorted { $0.enumerated < $1.enumerated }, reported: [literal], framework: .swiftTesting)
    }
}

extension TestNameMatch {
    /// The sentence the answer owes for the literals it reconciled by count because more than one test declares each, or `nil` where it reconciled none.
    ///
    /// One spelling for both reconciliations, the unsharded one and the sharded merge, because both join a quoted ending on its literal and both meet the same shared one.
    static func sharedLiteralNote(_ literals: [String]) -> String? {
        guard !literals.isEmpty else {
            return nil
        }
        return "Reconciled by count only: \(literals.joined(separator: ", ")). \(sharedLiteralCause), so an ending cannot be matched to one of them."
    }

    /// Why a literal more than one waiting test declares is reconciled by count.
    static var sharedLiteralCause: String {
        "Swift Testing's log names a test carrying a @Test literal by that literal alone, and more than one test waiting to report declares each of these"
    }

    /// The one sentence a sharded answer owes for every group reconciled by count for `cause`, the names grouped by the shard that reconciled them.
    static func countOnlyNote(byShard groups: [(shard: Int, names: [String])], cause: String) -> String {
        let named = groups.map { "shard \($0.shard): \($0.names.joined(separator: ", "))" }.joined(separator: "; ")
        return "Reconciled by count only — \(named). \(cause), so an ending cannot be matched to one of them."
    }
}

public extension TestNameMatch.Ambiguity {
    /// How this group's endings are counted: per name, each iteration's endings taking the place of the worst that stood before them.
    ///
    /// An iteration is a pass over the tests, so the fullest one says how many tests the name covers — counting every attempt instead would report a group of two that was retried once as three. A retry re-runs what did not pass, so a later iteration's endings displace the worst standing ones rather than being added to them or thrown away: that is what makes a retried test count as its retry's outcome, for a group of any size rather than only for a group of one.
    func endings(in outcomes: RunTestOutcomes) -> [RunTestOutcomes.Ending] {
        reported.sorted().flatMap { name -> [RunTestOutcomes.Ending] in
            let byIteration = Dictionary(grouping: outcomes.attempts[name] ?? [], by: \.iteration)
            var standing: [RunTestOutcomes.Ending] = []
            for iteration in byIteration.keys.sorted() {
                let endings = byIteration[iteration]?.map(\.ending) ?? []
                standing = endings.count >= standing.count
                    ? endings
                    : RunTestOutcomes.worstFirst(standing).dropFirst(endings.count) + endings
            }
            return standing
        }
    }
}
