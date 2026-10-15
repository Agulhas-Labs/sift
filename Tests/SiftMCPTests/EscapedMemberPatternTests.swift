//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftMCP
import Testing

/// A regex-escaped member spelling — `Depot\.pending\(` — read as the qualified name it spells, on the sweep reading both search surfaces share, so a search for a member's calls is answered by `where Depot.pending`, which names the function around each call the raw lines do not.
struct EscapedMemberPatternTests {
    /// A member and the call paren after it, escaped, bare or with the first argument's label, is that member's qualified name.
    @Test(arguments: [#"Depot\.pending"#, #"Depot\.pending\("#, #"Depot\.pending("#, #"Depot\.pending\(for:"#, #"\<Depot\.pending\>"#])
    func aMemberSpellingIsTheQualifiedName(pattern: String) {
        #expect(SweepPattern.reading(of: pattern) == .names(["Depot.pending"]))
    }

    /// Two branches spelling one member, with and without its call paren, are one question asked once.
    @Test
    func branchesOfOneMemberAreOneName() {
        #expect(SweepPattern.reading(of: #"Depot\.pending\(|Depot\.pending"#) == .names(["Depot.pending"]))
    }

    /// A type's own call paren is the type, beside the member the other branch spells.
    @Test
    func aTypesCallParenIsTheType() {
        #expect(SweepPattern.reading(of: #"Depot\.pending|Depot\("#) == .names(["Depot.pending", "Depot"]))
    }

    /// A call with no type in front of it names nothing to ask about, and stays prose beside the member the other branch names, with or without its label.
    @Test
    func aCallWithNoTypeIsLeftToASearch() {
        #expect(SweepPattern.reading(of: #"Depot\.pending\(|\.pending\(for:"#) == .partial(names: ["Depot.pending"], prose: [#"\.pending\(for:"#]))
        #expect(SweepPattern.reading(of: #"Depot\.pending|\.pending\("#) == .partial(names: ["Depot.pending"], prose: [#"\.pending\("#]))
    }

    /// A bare dot behind a capitalised type reads as the member, as it did before, and a real wildcard keeps the pattern text.
    @Test
    func aBareDotAndAWildcardReadAsBefore() {
        #expect(SweepPattern.reading(of: "Depot.pending") == .names(["Depot.pending"]))
        #expect(SweepPattern.reading(of: #"a\.b.*c"#) == .text)
    }

    /// The `Grep` tool's search for a member's calls is answered in place by that member's `where`.
    @Test
    func aGrepForAMembersCallsIsTheQualifiedWhere() {
        let input: [String: Any] = ["pattern": #"Depot\.pending\("#, "glob": "*.swift", "output_mode": "content"]
        let match = InPlaceShape.match(forSearchTool: "Grep", input: input, in: "/repo")

        guard case let .symbols(names, paths, uncovered, _, _, _, _)? = match?.call else {
            Issue.record("no names call for the Grep")
            return
        }
        #expect(names == ["Depot.pending"])
        #expect(paths.isEmpty)
        #expect(uncovered.isEmpty)
    }

    /// The shell's search for the same calls is the same `where`, carrying the search it stands in for.
    @Test(arguments: [#"grep -rn 'Depot\.pending\(' Sources --include=*.swift"#, #"grep -rnE 'Depot\.pending\(|Depot\.pending' Sources"#])
    func aShellSearchForAMembersCallsIsTheQualifiedWhere(command: String) {
        guard case let .symbols(names, paths, uncovered, proof, _, _, _)? = InPlaceShape.match(forShell: command, in: "/repo")?.call else {
            Issue.record("no names call for \(command)")
            return
        }

        #expect(names == ["Depot.pending"])
        #expect(uncovered.isEmpty)
        #expect(paths == ["Sources"])
        #expect(proof != nil)
    }
}
