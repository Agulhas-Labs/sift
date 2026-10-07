//
// Copyright © Agulhas Labs
//

import Foundation
import Testing

/// Covers what leaves this machine: everything a stranger receives.
///
/// Documents written as working notes become a product's documentation without anyone deciding they have — and then worked examples name private repositories, an install guide is titled for the machine it was written on, and an option's help text offers a private project as its example. Nothing catches that by reading, because the leak is invisible to the one person who already knows all the names. `Distribution/verify-private.sh` is the same check at release time — over the staged bundle and its binary, and over the tracked tree before the repository is published — and it alone knows the private names, which are discovered from the checkout's neighbours rather than committed. This one runs on every test, which is where a sentence gets caught the day it is written.
struct ShippedDocumentsTests {
    private static let repository = URL(filePath: #filePath)
        .deletingLastPathComponent() // SiftCoreTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // the repository root

    /// The tracked files the *term* check deliberately does not read, and the only exemption in this suite.
    ///
    /// Nothing is excluded quietly, and nothing named here is a file this gate has cleared of everything. One file earns it: `private-terms.txt` *is* the list of forbidden terms, so matching it against them fails the check on its own contents and on nothing else. There is no second reason, and `everyExclusionIsOneOfTheOnesWrittenDownHere` is what keeps a second one from being added quietly.
    ///
    /// **It is an exemption from the words and from nothing else.** Subtracted from both checks below, it would leave the machine's own name unlooked-for in that file too — in a file that is tracked, that ships, and whose header is prose about the sibling projects, where one added sentence or one contact address would be cleared by this suite and by the release gate together. The identity check reads it like every other tracked file; `theTermsFileIsExemptFromItsOwnWordsAndFromNothingElse` is that claim, and `Distribution/verify-private.sh` scopes its own skip the same way.
    ///
    /// A file that quotes a term from the list as an example does not earn a place here. That exemption would cover the whole file to buy one illustration, and anything else in its comments would go unread by this suite and by the release gate alike. A file that needs an illustration invents one, and is scanned like every other.
    private static let notEvidenceOfItsOwnTerms: Set<String> = [
        "Distribution/private-terms.txt",
    ]

    /// Every file git tracks, which on a public repository is the artifact — and which the identity check reads whole.
    ///
    /// A hand-kept list of paths falls behind what ships — it can claim to be everything a bundle carries while omitting a file of it. Publishing the repository makes `Sources/`, `Tests/`, `Docs/`, `.agents/` and the root files part of what a stranger reads, and a fixture naming a sibling project is exactly the sentence a hand-kept list of documents never looks at. The tree cannot fall behind itself the way a list can.
    private static func tracked() throws -> [String] {
        try TestSources.runGit(["ls-files"], in: repository)
            .split(separator: "\n")
            .map(String.init)
    }

    /// The same, minus the one file that is not evidence of its own words.
    private static func scannedForTerms() throws -> [String] {
        try tracked().filter { !notEvidenceOfItsOwnTerms.contains($0) }
    }

    /// Reading a tracked file that is not UTF-8 throws, and that is the intended direction: a file this cannot read is a file it cannot clear.
    private static func text(of path: String) throws -> String {
        try String(contentsOf: repository.appending(path: path), encoding: .utf8)
    }

    /// The generic terms, shared with the release-time gate so the two cannot drift apart.
    private static func forbiddenTerms() throws -> [String] {
        try text(of: "Distribution/private-terms.txt")
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    @Test
    func noTrackedFileNamesTheMachineOrItsOwner() throws {
        // Not the terms file's business: these are read off the machine running the test, so the check
        // travels to whoever builds rather than describing whoever wrote it.
        let identifiers = [NSHomeDirectory(), NSUserName(), NSFullUserName()].filter { $0.count > 3 }
            .map { $0.lowercased() }

        // Every tracked file, with nothing subtracted. The one exemption in this suite is from the word
        // list, and a machine's name written into the word list is a leak like a machine's name anywhere.
        for path in try Self.tracked() {
            let document = try Self.text(of: path).lowercased()
            for identifier in identifiers {
                // The result is reduced to a Bool before it is asserted on, here and below. A failure
                // otherwise prints the captured sub-expression, and the sub-expression is a file.
                let named = document.contains(identifier)
                #expect(!named, "\(path) names '\(identifier)'")
            }
        }
    }

    /// How one forbidden term is matched: whole-word, case-insensitively, on the same reading of "whole word" the release gate uses.
    ///
    /// **`.wordBoundaryKind(.simple)` is the whole of the correctness here.** Swift's default `\b` follows Unicode word breaking, which counts an apostrophe as *inside* a word: `\bgizmo\b` does not match `gizmo's`. Every term on the list is a noun, so under the default every one of them has a possessive form that walks straight through a gate reading every tracked file on every push — and the terms are phrases about a place and the things in it, which is exactly the vocabulary that reaches for a possessive. `grep -w`, which `Distribution/verify-private.sh` matches with, counts an apostrophe as a boundary, so the default would have the two halves of one gate disagree about the single thing they are written to agree about, with the Swift half the lenient one. The simple boundary kind is `grep -w`'s reading: a match must be flanked by something that is not a letter, a digit or an underscore. ``aTermMatchesAPossessiveAsGrepWouldMatchIt`` is what says so from here on.
    private static func matcher(for term: String) throws -> Regex<AnyRegexOutput> {
        try Regex("\\b\(term)\\b").ignoresCase().wordBoundaryKind(.simple)
    }

    /// A term is matched in the possessive, and still not matched inside a longer word.
    ///
    /// Exercised against an invented term rather than one off the list, for the reason every negative check in this area needs: a test naming a forbidden term to prove the check catches it is a tracked file naming a forbidden term, and the check would catch that.
    @Test
    func aTermMatchesAPossessiveAsGrepWouldMatchIt() throws {
        let pattern = try Self.matcher(for: "gizmo")

        #expect("the gizmo's label".firstMatch(of: pattern) != nil, "a possessive is a whole word followed by an apostrophe")
        #expect("a gizmo.".firstMatch(of: pattern) != nil)
        #expect("gizmo-shaped".firstMatch(of: pattern) != nil)
        #expect("two gizmos".firstMatch(of: pattern) == nil, "a term must not fire inside a longer word")
        #expect("a subgizmo".firstMatch(of: pattern) == nil)
    }

    @Test
    func noTrackedFileUsesAForbiddenTerm() throws {
        // Whole-word, because a generic term must not fire inside a longer word that contains it —
        // the distinction `Distribution/verify-private.sh` sets out where it explains its two matching
        // modes. The boundary check is the expensive half of that and the tree is megabytes, so a
        // lower-cased substring settles almost every (file, term) pair first and the regex runs only
        // where the words are present at all.
        let terms = try Self.forbiddenTerms().map { try (text: $0.lowercased(), pattern: Self.matcher(for: $0)) }

        for path in try Self.scannedForTerms() {
            let document = try Self.text(of: path)
            let lowered = document.lowercased()
            for term in terms where lowered.contains(term.text) {
                let used = document.firstMatch(of: term.pattern) != nil
                #expect(!used, "\(path) uses '\(term.text)'")
            }
        }
    }

    /// An exclusion naming a file that is no longer there is a claim about nothing, and would quietly stop being the exception it was written as.
    @Test
    func everyExclusionNamesAFileTheTreeStillTracks() throws {
        let tracked = try Set(Self.tracked())

        for path in Self.notEvidenceOfItsOwnTerms {
            #expect(tracked.contains(path), "\(path) is excluded from the term check and is not tracked")
        }
    }

    /// The set of exclusions is asserted whole, because the failure to catch is the set *growing*.
    ///
    /// Every other check here reads what the list currently says and agrees with it, so an exclusion added tomorrow arrives with its own test already passing. An equality is the only form of this claim a change has to argue with: adding a hole in the one gate that reads everything now means editing a test, in the same diff, where a reviewer sees it.
    @Test
    func everyExclusionIsOneOfTheOnesWrittenDownHere() {
        #expect(Self.notEvidenceOfItsOwnTerms == ["Distribution/private-terms.txt"])
    }

    /// The one exemption is from the word list, and the identity check has none at all.
    ///
    /// Subtracting the same set from both would make the file that holds the forbidden words the one file nobody looks in for the machine's name. The two subjects are asserted against each other rather than each against a literal: what matters is that they differ by exactly the terms file and in exactly one direction.
    @Test
    func theTermsFileIsExemptFromItsOwnWordsAndFromNothingElse() throws {
        let identity = try Set(Self.tracked())
        let terms = try Set(Self.scannedForTerms())
        // Reduced to a `Bool` before it is asserted on, for this file's usual reason turned up one
        // notch: the sub-expression here is not one file but the name of every file in the tree.
        let readsTheTermsFile = identity.contains("Distribution/private-terms.txt")
        let differByTheExemptionAlone = identity.subtracting(terms) == Self.notEvidenceOfItsOwnTerms
        let differInOneDirection = terms.subtracting(identity).isEmpty

        #expect(readsTheTermsFile, "the list of terms is not read for the machine's identity")
        #expect(differByTheExemptionAlone, "the identity check and the term check differ by more than the exemption")
        #expect(differInOneDirection, "the term check reads a path the identity check does not")
    }
}
