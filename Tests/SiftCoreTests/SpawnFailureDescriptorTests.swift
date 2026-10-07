//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A child `posix_spawn` refuses to start gives back every pipe end made for it, on the two paths that start children that way rather than through `Process`.
///
/// The spawn is refused by an environment past the kernel's argument limit, the one refusal a caller can force whatever the executable. The count is taken in a child process that runs nothing else, because the test runner's other suites open and close descriptors of their own beside this one (``GitContextDescriptorTests``).
@Suite(.temporaryDirectories)
struct SpawnFailureDescriptorTests {
    @Test
    func twoHundredObjectCopiesThatCannotStartLeaveTheOpenDescriptorCountWhereItWas() async throws {
        let path = try TemporaryDirectory.make("refused-spawn").path
        await #expect(processExitsWith: .success) { [path = path as String] in
            setenv("SIFT_OVERSIZED", SpawnFailureDescriptorTests.oversized, 1)
            let directory = URL(fileURLWithPath: path)
            let git = SetAsideGit(directory: directory, children: SetAsideChildren())
            let refusal = #expect(throws: SetAsideError.self) {
                try git.copyObjects(["0000000000000000000000000000000000000000"], into: directory)
            }
            #expect(refusal.map { "\($0)" }?.contains("could not start") == true, "\(String(describing: refusal))")
            let before = GitContextDescriptorTests.openDescriptors()
            for _ in 0 ..< 200 {
                try? git.copyObjects(["0000000000000000000000000000000000000000"], into: directory)
            }
            let after = GitContextDescriptorTests.openDescriptors()
            #expect(after <= before + 4, "open descriptors went from \(before) to \(after)")
        }
    }

    @Test
    func twoHundredSetAsideRunsThatCannotStartLeaveTheOpenDescriptorCountWhereItWas() async throws {
        let path = try TemporaryDirectory.make("refused-spawn").path
        await #expect(processExitsWith: .success) { [path = path as String] in
            let launcher = RunLauncher(workingDirectory: URL(fileURLWithPath: path), repositoryRoot: nil)
            let children = SetAsideChildren()
            let environment = ["SIFT_OVERSIZED": SpawnFailureDescriptorTests.oversized]
            let refusal = #expect(throws: SetAsideError.self) {
                try launcher.run(["true"], environment: environment, children: children)
            }
            #expect(refusal.map { "\($0)" }?.contains("could not start") == true, "\(String(describing: refusal))")
            let before = GitContextDescriptorTests.openDescriptors()
            for _ in 0 ..< 200 {
                _ = try? launcher.run(["true"], environment: environment, children: children)
            }
            let after = GitContextDescriptorTests.openDescriptors()
            #expect(after <= before + 4, "open descriptors went from \(before) to \(after)")
        }
    }

    /// A simulator spawn that times out while a grandchild still holds its pipes open has closed both read ends by the time the call returns.
    ///
    /// Clearing a handle's readability handler does not reliably release it, so read ends left to close on release outlived the call, a few in every fifty calls and closed moments later; the count is taken after every call and allows none, since a count taken only after the last call missed all but the leaks still open at that instant. One spawn runs before the count so that whatever the first spawn sets up for good is not read as a leak.
    @Test
    func fiftyTimedOutSpawnsLeaveTheOpenDescriptorCountWhereItWas() async {
        await #expect(processExitsWith: .success) {
            _ = try? SimulatorAccessibility.spawn("/bin/sh", ["-c", "sleep 3 & sleep 3"], deadline: 0.1)
            let before = GitContextDescriptorTests.openDescriptors()
            for _ in 0 ..< 50 {
                let output = try? SimulatorAccessibility.spawn("/bin/sh", ["-c", "sleep 3 & sleep 3"], deadline: 0.1)
                #expect(output?.standardError.contains("timed out") == true)
                let after = GitContextDescriptorTests.openDescriptors()
                #expect(after <= before, "open descriptors went from \(before) to \(after)")
            }
        }
    }

    /// A value longer than the kernel's limit on a new program's arguments and environment together, so `posix_spawn` refuses it with `E2BIG`.
    static var oversized: String {
        String(repeating: "x", count: 4 << 20)
    }
}
