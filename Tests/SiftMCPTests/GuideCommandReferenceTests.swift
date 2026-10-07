//
// Copyright © Agulhas Labs
//

import ArgumentParser
import Foundation
@testable import SiftCLI
import SiftCore
import Testing

/// The Guide's command reference names everything a user can type or set: each subcommand and its options, each hook event the installers register, each `SIFT_*` variable the sources read and each `.sift.json` key.
///
/// Every list is derived from the code — the parser's own dump of the command tree, the installers' event tables, a scan of `Sources/` for the variable names, the config type's stored properties — so a new option or variable fails here the day it lands undocumented. What is left out is left out by name, in the lists below, each with its reason.
struct GuideCommandReferenceTests {
    /// Subcommands the reference need not carry, and why.
    static let exemptSubcommands: [String: String] = [
        "stop": "the Stop and SubagentStop hooks' entry point, run by the registration install-hook writes, which install-hook's row names (#381 item 5)",
        "session-start": "the SessionStart and SubagentStart hooks' entry point, run by the registration install-hook writes",
        "pre-tool-use": "the PreToolUse hook's entry point, run by the registration install-hook writes",
        "post-tool-use": "the PostToolUse hook's entry point, run by the registration install-hook writes",
        "replay-hook": "hidden from --help: the entry point `audit --replay --against` drives in another binary",
        "scan-dump": "hidden from --help: the entry point `audit --scan-diff` drives in another binary",
    ]

    /// Options no command's row need carry, and why.
    ///
    /// An option hidden from `--help` is left out by the parser's own declaration, not listed here.
    static let exemptOptions: [String: String] = [
        "--help": "the parser's own, on every command",
        "--version": "the parser's own; the install section shows `sift --version`",
        "--root": "the line under the table says every command takes it and names the two that do not",
    ]

    /// Hook entry points whose events the Guide need not name, and why.
    static let exemptEventSubcommands: [String: String] = [:]

    /// `SIFT_*` variables the Guide need not name, and why.
    static let exemptVariables: [String: String] = [
        "SIFT_MCP_RESUME": "the handover a server passes to its own re-executed binary, never set by hand",
        "SIFT_TEST_HOLD_PUT_BACK": "a seam for the set-aside tests, never set by hand",
    ]

    /// Every subcommand the root command registers has a row of its own in the reference table.
    @Test
    func everySubcommandHasARow() throws {
        let commands = try Self.commandTree()
        let rows = try Self.referenceRows()

        #expect(Set(Self.exemptSubcommands.keys).isSubset(of: commands.map(\.name)), "an exemption names a subcommand that no longer exists")
        for command in commands where Self.exemptSubcommands[command.name] == nil {
            #expect(rows[command.name] != nil, "`sift \(command.name)` has no row in the Guide's command reference")
        }
    }

    /// Every option `--help` shows for a subcommand is on that subcommand's row of the reference table.
    @Test
    func everyOptionIsOnItsCommandsRow() throws {
        let rows = try Self.referenceRows()
        var checked = 0

        for command in try Self.commandTree() where Self.exemptSubcommands[command.name] == nil {
            let row = rows[command.name] ?? ""
            for option in command.displayedOptions where Self.exemptOptions[option] == nil {
                checked += 1

                #expect(Self.mentions(option, in: row), "`sift \(command.name) \(option)` is not on its row of the Guide's command reference")
            }
        }

        #expect(checked > 50, "only \(checked) options were checked")
    }

    /// Every hook event the Claude Code, Cursor and Codex installers register is named in the Guide.
    @Test
    func everyHookEventIsNamed() throws {
        let guide = try Self.guideText()
        let claude = HookRegistration.events.filter { Self.exemptEventSubcommands[$0.subcommand] == nil }.map(\.name)
        let cursor = CursorHooksFile.hooks.filter { Self.exemptEventSubcommands[$0.subcommand] == nil }.map(\.event)
        let codex = CodexHooksFile.hooks.filter { Self.exemptEventSubcommands[$0.subcommand] == nil }.map(\.event)

        #expect(claude.count >= 4 && !cursor.isEmpty && !codex.isEmpty)
        for event in claude + cursor + codex {
            #expect(Self.mentions(event, in: guide), "the hook event \(event) is not named in the Guide")
        }
    }

    /// Every `SIFT_*` variable a source file names is named in the Guide.
    @Test
    func everyEnvironmentVariableIsNamed() throws {
        let guide = try Self.guideText()
        let variables = try Self.variablesTheSourcesRead()

        #expect(variables.count > Self.exemptVariables.count)
        #expect(variables.isSuperset(of: Self.exemptVariables.keys), "an exemption names a variable no source reads any more")
        for variable in variables.sorted() where Self.exemptVariables[variable] == nil {
            #expect(Self.mentions(variable, in: guide), "\(variable) is read by the sources and not named in the Guide")
        }
    }

    /// Every key `.sift.json` is read into is named in the Guide's configuration table.
    @Test
    func everyConfigKeyIsInTheConfigurationTable() throws {
        let guide = try Self.guideText()
        let keys = Mirror(reflecting: SiftConfig()).children.compactMap(\.label)

        #expect(!keys.isEmpty)
        for key in keys {
            #expect(guide.contains("| `\(key)` |"), "the .sift.json key \(key) is not in the Guide's configuration table")
        }
    }
}

extension GuideCommandReferenceTests {
    /// The repository root, from this file's own path.
    static var repositoryRoot: URL {
        URL(filePath: #filePath)
            .deletingLastPathComponent() // SiftMCPTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent()
    }

    /// `Docs/Guide.md` as written.
    static func guideText() throws -> String {
        try String(contentsOf: repositoryRoot.appendingPathComponent("Docs/Guide.md"), encoding: .utf8)
    }

    /// The reference table's rows, keyed by the subcommand each opens with; a subcommand with several rows gets them joined.
    static func referenceRows(sourceLocation: SourceLocation = #_sourceLocation) throws -> [String: String] {
        let guide = try guideText()
        let start = try #require(guide.range(of: "## 11. Command reference"), sourceLocation: sourceLocation)
        let section = guide[start.upperBound...]
        let end = section.range(of: "\n## ")?.lowerBound ?? section.endIndex
        var rows: [String: String] = [:]
        for line in section[..<end].split(separator: "\n") where line.hasPrefix("| `sift ") {
            let name = line.dropFirst("| `sift ".count).prefix { $0 != " " && $0 != "`" }
            rows[String(name), default: ""] += line + "\n"
        }
        return rows
    }

    /// The root command's subcommands, as the parser itself describes them, each once.
    static func commandTree(sourceLocation: SourceLocation = #_sourceLocation) throws -> [Command] {
        var json = ""
        do {
            _ = try SiftCommand.parseAsRoot(["--experimental-dump-help"])
        } catch {
            json = SiftCommand.fullMessage(for: error)
        }
        let dump = try JSONDecoder().decode(Dump.self, from: Data(json.utf8))
        var seen = Set<String>()
        let commands = (dump.command.subcommands ?? []).filter { seen.insert($0.name).inserted }
        try #require(commands.count > 20, "the parser's dump listed \(commands.count) subcommands", sourceLocation: sourceLocation)
        return commands
    }

    /// Every `"SIFT_…"` string literal in a Swift file under `Sources/`.
    static func variablesTheSourcesRead() throws -> Set<String> {
        let sources = repositoryRoot.appendingPathComponent("Sources")
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" } ?? []
        var variables = Set<String>()
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for match in text.matches(of: /"(SIFT_[A-Z0-9_]+)"/) {
                variables.insert(String(match.1))
            }
        }
        return variables
    }

    /// Whether `name` stands in `text` as a whole token: not the front or back of a longer option, variable or identifier.
    static func mentions(_ name: String, in text: some StringProtocol) -> Bool {
        let text = String(text)
        return text.ranges(of: name).contains { range in
            let before = range.lowerBound == text.startIndex ? nil : text[text.index(before: range.lowerBound)]
            let after = range.upperBound == text.endIndex ? nil : text[range.upperBound]
            return !continuesAName(before) && !continuesAName(after)
        }
    }

    /// Whether a neighbouring character would make the match part of a longer name.
    static func continuesAName(_ character: Character?) -> Bool {
        guard let character else { return false }
        return character == "-" || character == "_" || character.isLetter || character.isNumber
    }

    /// The parts of the parser's `--experimental-dump-help` JSON these checks read.
    struct Dump: Decodable {
        let command: Command
    }

    /// One command in the dump.
    struct Command: Decodable {
        let name: String
        let subcommands: [Command]?
        let arguments: [Argument]?

        /// Each long option `--help` shows, spelled with its dashes.
        var displayedOptions: [String] {
            (arguments ?? [])
                .filter { $0.kind != "positional" && $0.shouldDisplay != false }
                .flatMap { $0.names ?? [] }
                .filter { $0.kind == "long" }
                .map { "--\($0.name)" }
        }
    }

    /// One argument in the dump.
    struct Argument: Decodable {
        let kind: String
        let shouldDisplay: Bool?
        let names: [Name]?
    }

    /// One of an argument's spellings in the dump.
    struct Name: Decodable {
        let kind: String
        let name: String
    }
}

private extension GuideCommandReferenceTests.Command {
    /// The dump's keys, the command's name under the parser's own key.
    enum CodingKeys: String, CodingKey {
        case name = "commandName"
        case subcommands
        case arguments
    }
}
