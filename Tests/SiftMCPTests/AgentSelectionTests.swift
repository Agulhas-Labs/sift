//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore
import Testing

/// Which agents `sift install` installs into for each combination of flags, detection and terminal, on a machine that exists only in the injected seams.
struct AgentSelectionTests {
    /// A detection finding exactly `agents`, each by its binary on PATH, on a machine with no files at all.
    private static func detection(_ agents: Set<InstallAgent>) -> AgentDetection {
        let binaries: [InstallAgent: String] = [.claude: "claude", .cursor: "agent", .codex: "codex"]
        let found = Set(agents.compactMap { binaries[$0] })
        return AgentDetection.detect(AgentDetection.Machine(
            environment: ["HOME": "/scratch/home", "PATH": "/scratch/bin"],
            applications: URL(fileURLWithPath: "/scratch/Applications", isDirectory: true),
            pathLookup: { found.contains($0) ? URL(fileURLWithPath: "/scratch/bin/\($0)") : nil },
            fileExists: { _ in false }
        ))
    }

    private static func picks(_ agents: [InstallAgent]) -> AgentSelection {
        .install(agents.map { AgentSelection.Pick(agent: $0) })
    }

    private typealias Flags = AgentSelection.Flags

    static let matrix: [Row] = [
        Row(flags: Flags(agents: [.codex, .claude, .codex]), detected: [.claude, .codex], interactive: false, expected: picks([.claude, .codex])),
        Row(flags: Flags(agents: [.claude], all: true, yes: true), detected: [.claude], interactive: true, expected: picks([.claude])),
        Row(flags: Flags(all: true), detected: [], interactive: false, expected: picks(InstallAgent.allCases)),
        Row(flags: Flags(all: true, yes: true), detected: [.claude], interactive: true, expected: picks(InstallAgent.allCases)),
        Row(flags: Flags(yes: true), detected: [.claude, .codex], interactive: false, expected: picks([.claude, .codex])),
        Row(flags: Flags(yes: true), detected: [.cursor], interactive: true, expected: picks([.cursor])),
        Row(flags: Flags(yes: true), detected: [], interactive: false, expected: .nothingDetected),
        Row(flags: Flags(dryRun: true), detected: [.claude], interactive: false, expected: picks([.claude])),
        Row(flags: Flags(dryRun: true), detected: [.claude], interactive: true, expected: picks([.claude])),
        Row(flags: Flags(dryRun: true), detected: [], interactive: true, expected: .nothingDetected),
        Row(flags: Flags(), detected: [.claude, .codex], interactive: true, expected: .ask([.claude, .codex])),
        Row(flags: Flags(), detected: Set(InstallAgent.allCases), interactive: true, expected: .ask(InstallAgent.allCases)),
        Row(flags: Flags(), detected: [.claude, .codex], interactive: false, expected: .needsFlags),
        Row(flags: Flags(), detected: Set(InstallAgent.allCases), interactive: false, expected: .needsFlags),
        Row(flags: Flags(), detected: [], interactive: false, expected: .nothingDetected),
        Row(flags: Flags(), detected: [], interactive: true, expected: .nothingDetected),
    ]

    @Test(arguments: matrix)
    func theSelectionMatrix(_ row: Row) {
        let selection = AgentSelection.decide(row.flags, detection: Self.detection(row.detected), isInteractive: row.interactive)

        #expect(selection == row.expected)
    }

    @Test
    func anAgentNamedButNotFoundCarriesANote() {
        let selection = AgentSelection.decide(Flags(agents: [.cursor, .claude]), detection: Self.detection([.claude]), isInteractive: false)

        #expect(selection == .install([
            AgentSelection.Pick(agent: .claude),
            AgentSelection.Pick(
                agent: .cursor,
                note: "Cursor was not found (looked for ~/.cursor, /scratch/Applications/Cursor.app, `agent` on PATH, `cursor-agent` on PATH); installing because --agent cursor named it"
            ),
        ]))
    }

    @Test
    func withNoTerminalNothingIsEverAsked() {
        let subsets: [Set<InstallAgent>] = [[], [.claude], [.cursor], [.codex], [.claude, .cursor], [.claude, .codex], [.cursor, .codex], Set(InstallAgent.allCases)]
        let flagSets = [Flags(), Flags(agents: [.codex]), Flags(all: true), Flags(yes: true), Flags(dryRun: true), Flags(all: true, yes: true, dryRun: true)]
        for detected in subsets {
            for flags in flagSets {
                let selection = AgentSelection.decide(flags, detection: Self.detection(detected), isInteractive: false)
                if case .ask = selection {
                    Issue.record("asked with no terminal: \(flags), detected \(detected)")
                }
            }
            let bare = AgentSelection.decide(Flags(), detection: Self.detection(detected), isInteractive: false)
            #expect(bare == (detected.isEmpty ? .nothingDetected : .needsFlags))
        }
    }

    @Test
    func everyAgentDeclinedIsNothingToDo() {
        #expect(AgentSelection.afterAsking(accepted: []) == .nothingToDo("every agent was declined, so nothing was installed"))
        #expect(AgentSelection.afterAsking(accepted: [.codex]) == Self.picks([.codex]))
    }

    @Test
    func theNeedsFlagsTextShowsWhatWasFoundAndTheCommandToRun() {
        let detection = Self.detection([.claude, .codex])

        let text = AgentSelection.needsFlagsText(detected: detection)

        #expect(text.hasPrefix(detection.text + "\n"))
        #expect(text.hasSuffix("""
        Nothing installed: there is no terminal to ask on. To install into what was found: sift install --yes
          or name each one: sift install --agent claude --agent codex
        """))
    }

    @Test
    func theNothingDetectedTextNamesEachSignAndTheCommandForEachAgent() {
        let text = AgentSelection.nothingDetectedText(Self.detection([]))

        #expect(text == """
        No agent found to install into. Name one to install into it anyway:
          Claude Code, found by `claude` on PATH, ~/.claude: sift install --agent claude
          Cursor, found by ~/.cursor, /scratch/Applications/Cursor.app, `agent` on PATH, `cursor-agent` on PATH: sift install --agent cursor
          Codex, found by `codex` on PATH, ~/.codex: sift install --agent codex
        Or all three: sift install --all
        """)
        #expect(AgentSelection.needsFlagsText(detected: Self.detection([])) == text)
    }
}

extension AgentSelectionTests {
    /// One cell of the selection matrix: the flags, what was detected, whether a terminal is there, and the decision expected.
    struct Row: Sendable, CustomTestStringConvertible {
        let flags: AgentSelection.Flags
        let detected: Set<InstallAgent>
        let interactive: Bool
        let expected: AgentSelection

        var testDescription: String {
            "\(flags) detected \(detected.map(\.rawValue).sorted()) interactive \(interactive)"
        }
    }
}
