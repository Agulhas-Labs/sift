//
// Copyright © Agulhas Labs
//

import ArgumentParser
@testable import SiftCLI
import Testing

/// A command's help text is wrapped by ArgumentParser at the reader's terminal width, so a source string that breaks a sentence across lines shows up as a ragged break mid-sentence.
struct HelpNotHardWrappedTests {
    /// No subcommand's discussion continues a sentence onto the next line: a prose line that ends in a word or a comma is followed by a blank line or the end, never by more prose.
    @Test
    func noSubcommandsDiscussionBreaksASentenceAcrossLines() {
        var broken: [String] = []
        for subcommand in SiftCommand.configuration.subcommands {
            let lines = subcommand.configuration.discussion.split(separator: "\n", omittingEmptySubsequences: false)
            for (index, line) in lines.enumerated() where index + 1 < lines.count {
                let next = lines[index + 1]
                let continues = line.last.map { $0.isLetter || $0.isNumber || $0 == "," || $0 == "—" } ?? false
                // Indented lines are tables and examples, which are meant to break where they do.
                let prose = !line.hasPrefix(" ") && !next.hasPrefix(" ") && !next.isEmpty
                if continues, prose {
                    broken.append("\(subcommand.configuration.commandName ?? "?"): \(line.suffix(40))")
                }
            }
        }

        #expect(broken.isEmpty, "hard-wrapped help: \(broken)")
    }
}
