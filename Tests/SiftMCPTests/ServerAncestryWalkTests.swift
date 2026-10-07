//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore
@testable import SiftMCP
import Testing

/// The hook's ancestry walk passing through shells and ending with the first process that is no shell, on chains built with the names the kernel gives: Claude Code's process is named for its version, a hook command's shell for its executable.
///
/// The chains are the ones measured under a nested session: a hook run directly by an inner `claude` (`2.1.292`), which was started from the outer one's Bash tool (`zsh`) under the outer `claude` (`2.1.291`).
struct ServerAncestryWalkTests {
    /// A harness started from another harness's Bash tool, with no server of its own on record, names no directory: the outer harness's server answers some other tree.
    @Test
    func aNestedHarnessWithNoServerDoesNotTakeTheOuterOne() {
        let names: [Int32: String] = [20: "2.1.292", 30: "zsh", 40: "2.1.291"]
        let entries = [ServerRootFromLogTests.entry(pid: 900, parent: 40, root: "/outer")]

        #expect(Self.serverDirectory(from: [10: 20, 20: 30, 30: 40, 40: 1], names: names, among: entries) == nil)
    }

    /// The ordinary call: the harness running the hook directly spawned the live server, which decides.
    @Test
    func theHarnessRunningTheHookDecides() {
        let names: [Int32: String] = [20: "2.1.292", 30: "zsh", 40: "2.1.291"]
        let entries = [
            ServerRootFromLogTests.entry(pid: 900, parent: 40, root: "/outer"),
            ServerRootFromLogTests.entry(pid: 901, parent: 20, root: "/inner"),
        ]

        #expect(Self.serverDirectory(from: [10: 20, 20: 30, 30: 40, 40: 1], names: names, among: entries) == "/inner")
    }

    /// Shells between the hook and its harness are passed through, so a hook command run under a shell still reaches the harness's server.
    @Test
    func theWalkPassesThroughShellsToTheHarness() {
        let names: [Int32: String] = [20: "bash", 30: "zsh", 40: "2.1.292"]
        let entries = [ServerRootFromLogTests.entry(pid: 900, parent: 40, root: "/inner")]

        #expect(Self.serverDirectory(from: [10: 20, 20: 30, 30: 40, 40: 1], names: names, among: entries) == "/inner")
    }

    /// A process the kernel cannot name counts as no shell, so the walk ends with it and a server above it is never asked.
    @Test
    func aProcessWithNoNameEndsTheWalk() {
        let names: [Int32: String] = [30: "2.1.292"]
        let entries = [ServerRootFromLogTests.entry(pid: 900, parent: 30, root: "/inner")]

        #expect(Self.serverDirectory(from: [10: 20, 20: 30, 30: 1], names: names, among: entries) == nil)
    }

    /// The first process that is no shell is kept in the chain, and nothing past it is.
    @Test
    func theWalkEndsWithTheFirstProcessThatIsNoShell() {
        let names: [Int32: String] = [20: "bash", 30: "2.1.292", 40: "zsh", 50: "2.1.291"]

        #expect(CallerRoot.ancestors(of: 10, parent: { [10: 20, 20: 30, 30: 40, 40: 50][$0] }, name: { names[$0] }) == [20, 30])
    }

    /// The kernel names a running process for its executable's file name, which is what the walk compares with its shells, and names no pid that nothing holds.
    @Test
    func theKernelNamesAProcessForItsExecutable() throws {
        let process = Process()
        let input = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/cat")
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        defer {
            input.fileHandleForWriting.closeFile()
            process.waitUntilExit()
        }

        #expect(KernelProcess.name(of: process.processIdentifier) == "cat")
        #expect(KernelProcess.name(of: 0) == nil)
    }

    /// The server directory a hook run as pid 10 finds, with `parents` and `names` standing in for the kernel and every recorded server live.
    private static func serverDirectory(from parents: [Int32: Int32], names: [Int32: String], among entries: [ServerLifecycleEntry]) -> String? {
        let chain = CallerRoot.ancestors(of: 10, parent: { parents[$0] }, name: { names[$0] })
        return CallerRoot.serverDirectory(ancestors: chain, session: nil, among: entries) { _ in true }
    }
}
