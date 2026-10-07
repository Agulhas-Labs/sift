//
// Copyright © Agulhas Labs
//

import SiftCore

/// The closed set of one-file grep spellings that ask only for Swift's declaration vocabulary, which a file's digest answers with every line the grep prints accounted for as a declaration or an attribute line of one.
///
/// A list of accepted forms rather than a reading that rejects the forms it knows are wrong: every spelling here was run on the system grep and on the agent's `ugrep -G --ignore-files --hidden -I`, which print the same lines for each. Anything else — another flag, a second pattern, an anchor, a character class, context, a count, a second file — is left to the shapes it always had.
struct DeclarationVocabularyGrep {
    /// The flag words the form may open on, exactly as written: none, a line number, the extended dialect, or both.
    static let flagSpellings: [[String]] = [[], ["-n"], ["-E"], ["-nE"], ["-En"], ["-n", "-E"], ["-E", "-n"]]

    /// The keywords an alternative may be, alone or followed by one space.
    static let keywords: Set<String> = [
        "func", "init", "var", "let", "class", "struct", "enum", "actor", "protocol", "extension", "case",
        "subscript", "typealias", "deinit",
    ]

    /// Whether `arguments` — a grep's words after its command word, as the shell hands them over — are flags from ``flagSpellings``, one pattern of alternated vocabulary, and one path.
    ///
    /// The alternatives are split on `\|` in the basic dialect and on `|` in the extended one, the two spellings both tools read as alternation; the other dialect's separator is a literal both print nothing for, and is no form here. A pattern of one attribute alone, `'@Test'`, passes here yet is no lookup today: an earlier filter judges it no lookup before this form is asked, and the grep runs.
    static func accepts(_ arguments: [String]) -> Bool {
        guard arguments.count >= 2, !arguments[arguments.count - 1].hasPrefix("-") else { return false }
        let flags = Array(arguments.dropLast(2))
        guard flagSpellings.contains(flags) else { return false }
        let separator = flags.contains { $0.contains("E") } ? "|" : #"\|"#
        return arguments[arguments.count - 2].split(separator: separator, omittingEmptySubsequences: false).allSatisfy { isVocabulary(String($0)) }
    }

    /// Whether one alternative is a keyword, a keyword and one space, or an attribute's `@` and name.
    private static func isVocabulary(_ alternative: String) -> Bool {
        if alternative.wholeMatch(of: /@[A-Za-z_][A-Za-z0-9_]*/) != nil {
            return true
        }
        let keyword = alternative.hasSuffix(" ") ? String(alternative.dropLast()) : alternative
        return keywords.contains(keyword)
    }
}

extension ShellGrep {
    /// Whether this search is one of ``DeclarationVocabularyGrep``'s spellings with nothing cutting its output, so that a declaration's attribute lines and name line count among the lines its file's digest accounts for.
    var asksForDeclarationVocabulary: Bool {
        spellsDeclarationVocabulary && cut == nil
    }

    /// The lines of `file` a digest of it accounts for when this search prints them: its declarations' attribute lines and name lines as well as their first lines where the search asks for declaration vocabulary, and their first lines alone otherwise.
    func linesLocated(byDigest text: String, of file: OperandFile.Indexed, in engine: SiftEngine) throws -> Set<Int> {
        if asksForDeclarationVocabulary {
            return try ExactAnswer.declarationLinesLocated(byDigest: text, of: file.relative, source: file.lines, in: engine)
        }
        return try ExactAnswer.linesLocated(byDigest: text, of: file.relative, source: file.lines, in: engine)
    }
}
