//
// Copyright © Agulhas Labs
//

import ArgumentParser
import SiftCore
import SiftMCP

/// `sift status` — the freshness header plus counts, size, modules, and doctor checks.
///
/// The agent-allowlist check is the one line here that is not about the index at all. It belongs to the doctor rather than to a subcommand of its own because it answers a question nobody knows to ask: an agent definition with an explicit `tools:` list spawns contexts that take every refusal this tool gives and hold none of the tools it names, and the only trace is a share that reads low. `status` is where someone already goes when the numbers look wrong, and it is re-read every time — which a one-off check at install time is not.
///
/// The hook-registration check is here for the same reason and answers the same shape of question: a binary upgraded without re-running `install-hook` keeps the matcher the old one wrote, and the only trace of *that* is a hook that does not see this server's own calls (``SiftCore/RegisteredHooks``). It says nothing at all where the settings file registers none of these hooks, which is not a fault to report.
///
/// The server line is the third of that shape and the sharpest (``SiftMCP/ServerLifecycleReport``). When the MCP face drops mid-session the four tools stop existing with no notice and no reconnect, and without a record the drop is legible from neither end: the agent discovers it by failing, and nothing else on the machine keeps an account of a server's life. This is where "is one running, and what happened to the last one?" is a question with an answer.
struct StatusCommand: AsyncParsableCommand {
    static var configuration: CommandConfiguration {
        CommandConfiguration(commandName: "status", abstract: "Report index freshness, contents, and environment health.")
    }

    @OptionGroup var rootOptions: RootOptions

    func run() async throws {
        try await StandardStreams.emit(answer())
    }

    /// The whole report, header first and any adopted-root note under it.
    func answer(registry: RootsRegistry = .standard()) async throws -> String {
        let (engine, note) = try rootOptions.makeEngine(registry: registry)
        let freshness = try await engine.ensureFresh()
        let agents = AgentAllowlistReport.text(root: engine.repoRoot.path)
        let hooks = RegisteredHooks.standard().note
        let servers = ServerLifecycleReport.text(fileURL: ServerLifecycleLog.standard().fileURL)
        let report = try ([engine.statusText(freshness: freshness), hooks, agents, servers].compactMap(\.self)).joined(separator: "\n")
        return Freshness.placing([note], under: report)
    }
}
