//
// Copyright © Agulhas Labs
//

import ArgumentParser
import SiftCore

/// `sift help [<topic>]` — the reference material `Sift.md` moved out of the always-loaded rule, or a subcommand's own usage when the name given is one.
///
/// `Sift.md` names each topic in one line and says when to reach for it; this is where reaching for it lands. No `--root`, no freshness header: a topic is fixed reference text, not a claim about a repository, so the Answer Contract's header rule does not apply to it (`Docs/AnswerContract.md` §1 covers query answers specifically, and names that a command may open differently).
///
/// Registering this type as a subcommand named `help` takes over the name ArgumentParser reserves for its own built-in help subcommand, so `sift help digest` would otherwise refuse — the binary's own `--help` footer still promises `sift help <subcommand>` works, and a name that resolves to neither a topic nor a subcommand has to say so honestly rather than as a topic-only miss. `resolve(_:)` is what falls through: a topic name wins first, then a registered subcommand's own usage — the same text `sift <subcommand> --help` gives — and only then the refusal.
struct HelpCommand: ParsableCommand {
    static var configuration: CommandConfiguration {
        CommandConfiguration(
            commandName: "help",
            abstract: "Reference topics for rare moments, or a subcommand's own usage.",
            discussion: """
            Omit the topic to list what exists. `Sift.md` is the always-loaded rule and stays short on \
            purpose — this is the depth it points at rather than repeats, so a long session is not paying \
            to re-read it on every `.swift` file it reloads on. A name that is a subcommand rather than a \
            topic (`sift help digest`) prints that subcommand's own usage, exactly as `sift digest --help` does.
            """
        )
    }

    @Argument(help: "A topic name, or a subcommand name for its own usage. Omit it to list every topic.")
    var topic: String?

    func run() throws {
        try StandardStreams.emit(HelpCommand.resolve(topic))
    }

    /// What `sift help <topic>` prints: a reference topic's body, a subcommand's own usage, or the listing when `topic` is `nil`.
    static func resolve(_ topic: String?) throws -> String {
        guard let topic else {
            return listing()
        }
        if let found = HelpTopics.topic(named: topic) {
            return found.body
        }
        if let subcommand = HelpCommand.subcommand(named: topic) {
            return SiftCommand.helpMessage(for: subcommand)
        }
        throw ValidationError("no help topic or subcommand named '\(topic)' — \(namesLine)")
    }

    /// A registered subcommand matched by its own configured name — every subcommand here sets `commandName` explicitly, so reading `configuration.commandName` finds it without ArgumentParser's underscored `_commandName`.
    ///
    /// `helpMessage(for:)` renders straight from a command type's own metadata and never calls back into `resolve`, so matching `HelpCommand` itself is safe: `sift help help` falls through to this command's own usage exactly like any other name, rather than refusing one of its own.
    private static func subcommand(named name: String) -> ParsableCommand.Type? {
        SiftCommand.configuration.subcommands.first { $0.configuration.commandName == name }
    }

    private static var namesLine: String {
        "topics: \(HelpTopics.all.map(\.name).joined(separator: ", ")); or any subcommand name"
    }

    private static func listing() -> String {
        (["Topics:"] + HelpTopics.all.map { "  \($0.name) — \($0.summary)" }
            + ["", "sift help <subcommand> still works, for that subcommand's own usage."]
        ).joined(separator: "\n")
    }
}
