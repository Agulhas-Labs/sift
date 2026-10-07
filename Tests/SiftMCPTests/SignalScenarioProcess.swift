//
// Copyright © Agulhas Labs
//

import Testing

/// Where a test runs the part of it that raises a signal at its own process, or changes how that process takes one: a child process of its own, which runs nothing else.
///
/// **Never the test runner.** A signal's disposition and the main thread's mask belong to the whole process, and the runner runs other suites beside this one. One signal reaches every watch armed for it, so a one-shot handler put back to `SIG_DFL` by one test's signal is the default the next signal meets, whichever test sent it — and that ends the runner mid-run, with no summary. `.serialized` orders the tests of one suite and nothing else, so it cannot rule that out; a process that runs one scenario and exits can, whatever the runner is doing at the time. What a scenario records in the child is reported at the test that asked for it.
struct SignalScenarioProcess {
    /// Runs `scenario` in a child process, and expects that process to end as `ending` says.
    static func run(_ scenario: ServerSignalWatchTests.Scenario, ending: Ending = .normally, sourceLocation: SourceLocation = #_sourceLocation) async {
        let condition: ExitTest.Condition = switch ending {
        case .normally:
            .success
        case let .bySignal(number):
            .signal(number)
        }
        await #expect(processExitsWith: condition, sourceLocation: sourceLocation) { [scenario = scenario as ServerSignalWatchTests.Scenario, sourceLocation = sourceLocation as SourceLocation] in
            try await scenario.perform(sourceLocation: sourceLocation)
        }
    }
}

extension SignalScenarioProcess {
    /// How the process a scenario runs in is expected to end.
    enum Ending: Sendable {
        case normally
        case bySignal(Int32)
    }
}
