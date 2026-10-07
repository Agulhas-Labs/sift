//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
import SiftCore
@testable import SiftMCP
import Testing

/// The release-blocking case: a subagent in a worktree sharing its parent's server, asking about its own tree and being answered from another one.
@Suite(.temporaryDirectories)
struct CallerRootTests {
    /// Both spellings of a temporary directory name one place — git answers `/private/var/…` where Foundation's own resolution answers `/var/…` — so paths are compared the way the rest of the codebase compares them.
    private func canonical(_ path: Any?) -> String? {
        (path as? String).map(CanonicalPath.of)
    }

    /// The whole defect in one assertion.
    ///
    /// A worktree and the checkout it came from share `head:` and hold the same symbol names, so the path is the only thing that can tell them apart — and the caller's `cwd` is the only place the path appears.
    @Test
    func anIndexCallWithNoRootIsPinnedToTheCallersOwnWorktree() throws {
        let root = try MCPTestRepo.make()
        let worktree = try MCPTestRepo.worktree(of: root, named: "agent-1a2b3c4d")

        let amended = try #require(CallerRoot.amendment(
            toolName: "mcp__sift__digest",
            input: ["target": "Alpha"],
            cwd: worktree.path
        ))

        #expect(canonical(amended["root"]) == CanonicalPath.of(worktree.path))
        // The rest of the call is carried through untouched: this adds an argument, it does not rewrite one.
        #expect(amended["target"] as? String == "Alpha")
    }

    /// A caller standing in the same tree the server is rooted in gets the same argument, which changes nothing — and that is the point.
    ///
    /// Told nothing of where the server was started, the only rule this can apply honestly is "answer from where the caller is", every time; the hook's own run, told the project directory, is covered by `CallerRootProjectDirTests`.
    @Test
    func aCallFromTheRepositoryItselfIsPinnedToItToo() throws {
        let root = try MCPTestRepo.make()

        let amended = try #require(CallerRoot.amendment(
            toolName: "mcp__sift__where",
            input: ["symbol": "Alpha"],
            cwd: root.appendingPathComponent("Sources/App").path
        ))

        #expect(canonical(amended["root"]) == CanonicalPath.of(root.path))
    }

    /// An explicit `root:` is the caller saying which tree it means.
    ///
    /// This knows less than the caller does and must not overrule it.
    @Test
    func anExplicitRootIsNeverOverwritten() throws {
        let root = try MCPTestRepo.make()
        let worktree = try MCPTestRepo.worktree(of: root, named: "stated")

        #expect(CallerRoot.amendment(
            toolName: "mcp__sift__digest",
            input: ["target": "Alpha", "root": root.path],
            cwd: worktree.path
        ) == nil)
    }

    /// An empty string is not a stated root — it is a caller that filled the argument in with nothing, and pinning it is still the right answer.
    @Test
    func anEmptyRootIsNotAStatedOne() throws {
        let root = try MCPTestRepo.make()

        let amended = try #require(CallerRoot.amendment(
            toolName: "mcp__sift__digest",
            input: ["target": "Alpha", "root": ""],
            cwd: root.path
        ))

        #expect(canonical(amended["root"]) == CanonicalPath.of(root.path))
    }

    /// A session started above several repositories sits above them all, so its `cwd` names no repository at all.
    ///
    /// Pinning it to that directory would break the rootless self-heal that already answers this case properly; silence leaves the call exactly as it was.
    @Test
    func aCallerOutsideAnyRepositoryIsLeftAlone() throws {
        let outside = try TemporaryDirectory.make("no-repo")
        defer { try? FileManager.default.removeItem(at: outside) }

        #expect(CallerRoot.amendment(
            toolName: "mcp__sift__digest",
            input: ["target": "Alpha"],
            cwd: outside.path
        ) == nil)
        #expect(CallerRoot.amendment(toolName: "mcp__sift__digest", input: ["target": "Alpha"], cwd: nil) == nil)
    }

    /// A payload this could not read leaves the call exactly as it was, rather than replacing its arguments with a root.
    ///
    /// `tool_input` present in an unexpected shape reads as `[:]`, indistinguishable from absent — and amending that would produce an input carrying only `root:`, with the target the call was made with dropped. Every tool of this server's takes a required argument, so an empty input is never a call worth amending, and silence is the property this hook holds to on every failure.
    @Test
    func aPayloadThisCouldNotReadIsLeftAlone() throws {
        let root = try MCPTestRepo.make()

        #expect(CallerRoot.amendment(toolName: "mcp__sift__digest", input: [:], cwd: root.path) == nil)
        // The route it arrives by: the hook reads `tool_input` and gets `[:]` for a value of the wrong shape.
        #expect(PreToolUseCommand.adviceTaken(
            session: "s1",
            context: AdviceContext.resolve(sessionID: "s1", transcriptPath: nil),
            payload: ["tool_name": "mcp__sift__digest", "tool_input": "target=Alpha"],
            cwd: root.path,
            ledger: AdviceLedger(directory: root.appendingPathComponent("ledger", isDirectory: true)),
            callers: CallAttribution(directory: root.appendingPathComponent("callers", isDirectory: true))
        ) == nil)
    }

    /// The hook's matcher covers every tool that can read Swift source, so most of what reaches it is not this server's at all.
    ///
    /// None of those take a `root:` argument, and inventing one for them would corrupt a call this has no business touching.
    @Test
    func aToolThisServerDoesNotOwnIsLeftAlone() throws {
        let root = try MCPTestRepo.make()
        let unowned: [String?] = ["Read", "Bash", "Grep", "mcp__xcode__XcodeRead", "mcp__other__digest"]

        for tool in unowned + [nil] {
            #expect(CallerRoot.amendment(toolName: tool, input: ["target": "Alpha"], cwd: root.path) == nil)
        }
    }

    /// `--show-toplevel` and not `--git-common-dir`: the common directory of a linked worktree names the repository it was cut from, which is precisely the tree this must stop answering from.
    @Test
    func theRootOfAWorktreeIsTheWorktreeAndNotItsParent() throws {
        let root = try MCPTestRepo.make()
        let worktree = try MCPTestRepo.worktree(of: root, named: "toplevel")

        let resolved = try CanonicalPath.of(#require(CallerRoot.root(forCallerIn: worktree.path)))

        #expect(resolved == CanonicalPath.of(worktree.path))
        #expect(resolved != CanonicalPath.of(root.path))
    }
}
