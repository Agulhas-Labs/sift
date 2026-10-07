//
// Copyright © Agulhas Labs
//

import ArgumentParser
@testable import SiftCLI
import SiftCore
import Testing

/// `sift help` names both reference topics and every registered subcommand, and must not shadow ArgumentParser's own `<tool> help <subcommand>` convention — the binary's own `--help` footer still promises it.
struct HelpCommandTests {
    /// A topic name resolves to that topic's own text, not a subcommand's.
    @Test
    func aTopicNameResolvesToItsOwnBody() throws {
        let resolved = try HelpCommand.resolve("answers")

        #expect(resolved == HelpTopics.topic(named: "answers")?.body)
    }

    /// The regression this whole fix is for.
    ///
    /// `run` used to be a topic name and collided with the `run` subcommand. Renaming the topic to `run-output` means `sift help run` now falls through to `RunCommand`'s own usage, exactly as `sift run --help` gives.
    @Test
    func aSubcommandNameFallsThroughToThatSubcommandsUsage() throws {
        let resolved = try HelpCommand.resolve("run")

        #expect(resolved == SiftCommand.helpMessage(for: RunCommand.self))
        #expect(HelpTopics.topic(named: "run") == nil, "the topic must have moved, not merely be shadowed")
    }

    /// Every registered subcommand falls through the same way — not just `digest` and `where`, and `help` itself included, since matching it back to its own usage is safe (see `helpItselfFallsThroughToItsOwnUsage`).
    @Test
    func everyRegisteredSubcommandFallsThrough() throws {
        for subcommand in SiftCommand.configuration.subcommands {
            let name = try #require(subcommand.configuration.commandName)
            #expect(
                try HelpCommand.resolve(name) == SiftCommand.helpMessage(for: subcommand),
                "sift help \(name) did not fall through to its own usage"
            )
        }
    }

    /// No topic name ever collides with a subcommand's own name — `resolve` checks topics first, so a collision would silently and permanently hide that subcommand's usage behind the topic's body.
    @Test
    func topicNamesNeverCollideWithSubcommandNames() {
        // Not `\.configuration.commandName`: a key path through this existential metatype crashes the
        // Swift 6.3.3 compiler while lowering this file specifically (signal 5, reproduced in isolation).
        // swiftformat:disable:next preferKeyPath
        let subcommandNames = Set(SiftCommand.configuration.subcommands.compactMap { $0.configuration.commandName })

        for topic in HelpTopics.all {
            #expect(!subcommandNames.contains(topic.name), "topic '\(topic.name)' collides with a registered subcommand name")
        }
    }

    /// A name that is neither a topic nor a subcommand refuses, and the refusal names both places an answer could have come from.
    @Test
    func anUnknownNameRefusesAndNamesWhereToLook() throws {
        #expect(throws: ValidationError.self) {
            try HelpCommand.resolve("not-a-real-topic")
        }
        do {
            _ = try HelpCommand.resolve("not-a-real-topic")
            Issue.record("expected a refusal")
        } catch let error as ValidationError {
            #expect(error.message.contains("topics:"))
            #expect(error.message.contains("subcommand"))
        }
    }

    /// `sift help help` falls through to `HelpCommand`'s own usage, exactly like any other subcommand name — `helpMessage(for:)` never calls back into `resolve`, so matching `help` to itself here cannot recurse into its own refusal.
    @Test
    func helpItselfFallsThroughToItsOwnUsage() throws {
        let resolved = try HelpCommand.resolve("help")

        #expect(resolved == SiftCommand.helpMessage(for: HelpCommand.self))
    }

    /// Omitting the topic lists every topic, and still says the subcommand path works.
    @Test
    func noTopicListsTopicsAndMentionsSubcommandFallthrough() throws {
        let listing = try HelpCommand.resolve(nil)

        for topic in HelpTopics.all {
            #expect(listing.contains(topic.name))
        }

        #expect(listing.contains("sift help <subcommand>"))
    }
}
