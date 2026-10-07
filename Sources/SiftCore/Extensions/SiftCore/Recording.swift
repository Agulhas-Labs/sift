//
// Copyright © Agulhas Labs
//

/// Reads an ordinary wrapped run as a `TestDurationStore.Recording`, so the serial run people already do seeds the store the first sharded run would otherwise find empty.
public extension TestDurationStore.Recording {
    /// Builds a recording from `outcomes`, or `nil` where the run is not honest measurement to keep at all.
    ///
    /// A plain run has no expected set to reconcile against, so `exitCode` is the only check `missing` can make: a nonzero exit means something failed or crashed, and a timing taken beside that measures the failure rather than the test, so nothing is recorded. `retried` reads straight off `outcomes.iterations`, and each test's timing is its first attempt that carries seconds, kept with the iteration that attempt was recorded on.
    ///
    /// Only a target-qualified XCTest log name can be keyed the way the store is keyed (`Target/Type/function()`): `-[DemoUITests.ItemListUITests testSelectsFirstItem]` becomes `DemoUITests/ItemListUITests/testSelectsFirstItem()`. An unqualified `-[ItemListUITests testSelectsFirstItem]` and every Swift Testing name — a bare `function()`, with no target or suite at all — cannot name an identifier this store would recognise later, and are silently skipped rather than guessed at; Swift Testing timings arrive only with the first sharded run.
    ///
    /// **The qualifier is the log's module name, so a target Swift cannot spell is keyed under a string no identifier will ever equal**: `Demo Spaced Tests` logs `-[Demo_Spaced_Tests.SpacedTests testCountsUp]` and is keyed `Demo_Spaced_Tests/SpacedTests/testCountsUp()`, where the enumeration spells it `Demo Spaced Tests/SpacedTests/testCountsUp()`. That entry is a wasted row, never a wrong answer — a key nothing looks up seeds nothing and displaces nothing — and it is left rather than mapped back, because the substitution is not invertible: `_` in a module name stands for a space, a `-`, a `.` or an `_` itself, and picking one would key a timing onto a target that may not exist. Such a bundle's timings arrive with its first sharded run, as Swift Testing's do.
    init?(wrappedRun outcomes: RunTestOutcomes, exitCode: Int32) {
        guard exitCode == 0 else {
            return nil
        }
        var timings: [TestDurationStore.Timing] = []
        for name in outcomes.names {
            guard let attempt = outcomes.attempts[name]?.first(where: { $0.seconds != nil }),
                  let seconds = attempt.seconds,
                  let (qualifiedType, method) = TestIdentifier.xctestLogName(name),
                  let dot = qualifiedType.firstIndex(of: ".")
            else {
                continue
            }
            let target = qualifiedType[..<dot]
            let type = qualifiedType[qualifiedType.index(after: dot)...]
            timings.append(TestDurationStore.Timing(identifier: "\(target)/\(type)/\(method)()", seconds: seconds, iteration: attempt.iteration))
        }
        self.init(observations: timings, retried: outcomes.iterations > 1, missing: 0)
    }
}
