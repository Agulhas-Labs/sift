//
// Copyright © Agulhas Labs
//

import Foundation
import Testing

/// Covers what `CHANGELOG.md` may carry: no reference into the maintainers' private tracker, and a shape that survives the union merge its anchor lines are set to.
///
/// A union merge keeps both sides' lines, so a bullet edited on two branches can come out repeated, cut short or with a stray continuation. The checks here read the file the way a stranger does: every line of a version section is blank, a heading, a bullet or a continuation of one, and no section opens two bullets alike.
struct ChangelogHygieneTests {
    /// The repository's `CHANGELOG.md`, split into lines.
    private static let lines: [String] = {
        let repository = URL(filePath: #filePath)
            .deletingLastPathComponent() // SiftCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // the repository root
        let text = (try? String(contentsOf: repository.appending(path: "CHANGELOG.md"), encoding: .utf8)) ?? ""
        return text.components(separatedBy: "\n")
    }()

    /// Each line from the first `## ` heading on, numbered from one, so the title and the introduction above the first version are left out.
    private static var sectionLines: [(number: Int, text: String)] {
        let numbered = lines.enumerated().map { (number: $0.offset + 1, text: $0.element) }
        return Array(numbered.drop { !$0.text.hasPrefix("## ") })
    }

    /// The file is found and has version sections, so the other checks are not passing over nothing.
    @Test
    func theChangelogIsFoundAndHasVersionSections() {
        #expect(Self.sectionLines.count > 10)
    }

    /// No line carries `#` and digits as an issue reference, since the tracker behind it is not public.
    @Test
    func noLineOfTheChangelogNamesAnIssueNumber() {
        let offending = Self.lines.enumerated()
            .filter { $0.element.contains(CommentHistoryTests.issueReference) }
            .map { "line \($0.offset + 1): \($0.element)" }

        #expect(offending.isEmpty, "issue references in CHANGELOG.md:\n\(offending.joined(separator: "\n"))")
    }

    /// Every line of a version section is blank, a heading, a bullet or a two-space continuation, so a fragment left by a merge cannot stand alone; the one paragraph a section may open with, straight under its heading, is the introduction of the first release.
    @Test
    func everyLineInAVersionSectionIsBlankAHeadingABulletOrAContinuation() {
        var stray: [String] = []
        var previousNonBlank = ""
        for line in Self.sectionLines {
            let isShaped = line.text.isEmpty || line.text.hasPrefix("## ") || line.text.hasPrefix("- ") || line.text.hasPrefix("  ")
            if !isShaped, !previousNonBlank.hasPrefix("## ") {
                stray.append("line \(line.number): \(line.text)")
            }
            if !line.text.isEmpty {
                previousNonBlank = line.text
            }
        }

        #expect(stray.isEmpty, "lines in no bullet:\n\(stray.joined(separator: "\n"))")
    }

    /// No two bullets of one section begin with the same sixty characters, which is how a union merge repeats a bullet reworded on two branches.
    @Test
    func noTwoBulletsInOneSectionShareTheirFirstSixtyCharacters() {
        var seen: [String: Int] = [:]
        var repeated: [String] = []
        for line in Self.lines.enumerated() {
            if line.element.hasPrefix("## ") {
                seen = [:]
            } else if line.element.hasPrefix("- ") {
                let opening = String(line.element.prefix(60))
                if let first = seen[opening] {
                    repeated.append("line \(line.offset + 1) repeats line \(first): \(opening)")
                } else {
                    seen[opening] = line.offset + 1
                }
            }
        }

        #expect(repeated.isEmpty, "bullets repeated within a section:\n\(repeated.joined(separator: "\n"))")
    }
}
