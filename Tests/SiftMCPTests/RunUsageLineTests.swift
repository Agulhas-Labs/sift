//
// Copyright © Agulhas Labs
//

import ArgumentParser
@testable import SiftCLI
import Testing

/// What `sift run --help` draws as the usage line: `--without-line` takes one value, so it is not drawn as repeatable.
struct RunUsageLineTests {
    /// The usage line, on one line.
    private static var usage: String {
        RunCommand.usageString().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// `--without` repeats and says so with its `...`; `--without-line` is refused when given twice and has none.
    @Test
    func theUsageLineShowsWithoutLineAsNonRepeatable() {
        #expect(Self.usage.contains("[--without-line <file:line>]"), "\(Self.usage)")
        #expect(!Self.usage.contains("[--without-line <file:line> ...]"), "\(Self.usage)")
        #expect(Self.usage.contains("[--without <without> ...]"), "\(Self.usage)")
    }

    /// Every `--long` option in the OPTIONS section of `sift run --help`, which the command's own declarations produce.
    private static var declaredOptions: [String] {
        var inOptions = false
        var names: [String] = []
        for line in RunCommand.helpMessage().split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("OPTIONS:") {
                inOptions = true
                continue
            }
            guard inOptions else { continue }
            if let first = line.first, !first.isWhitespace {
                break
            }
            let trimmed = line.drop(while: \.isWhitespace)
            guard trimmed.hasPrefix("-"),
                  let long = trimmed.split(whereSeparator: { $0 == " " || $0 == "," }).first(where: { $0.hasPrefix("--") })
            else { continue }
            names.append(String(long))
        }
        return names
    }

    /// The usage line is written out by hand, so a flag it forgets is caught here: the options are read off the command's own help, so one added to the command fails this until the line names it.
    @Test
    func theUsageLineNamesEveryOption() {
        let options = Self.declaredOptions.filter { $0 != "--help" }

        #expect(options.count >= 7, "options read from help: \(options)")
        for option in options {
            #expect(Self.usage.contains("[\(option)"), "\(option) missing from: \(Self.usage)")
        }

        #expect(Self.usage.hasPrefix("sift run [<command> ...]"), "\(Self.usage)")
    }
}
