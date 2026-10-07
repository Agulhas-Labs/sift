//
// Copyright © Agulhas Labs
//

import Foundation
import RegexBuilder

/// What a shell pattern is read as: one name, several, a file's own spelling, or nothing the index could hold.
///
/// Its own type because it answers a different question from ``ShellQuery``, which reads a segment's argv — this reads the *pattern itself*, a string, for whether it is Swift vocabulary at all and which symbol it names if so. ``SweepPattern`` and ``SearchToolAdvice`` both classify a pattern by what this says about it. Split out when `ShellQuery.swift` outgrew a single subject; the argv reading stays there, since it is a fact about the segment rather than about the pattern text.
struct PatternReading {
    /// Whether `pattern` names nothing the index could hold — no identifier anywhere in it, of any kind.
    ///
    /// Deliberately the widest reading of "a name": keywords count, and so does a word that is nobody's symbol, because the question is whether there is *any* Swift vocabulary here rather than whether there is a symbol. `final class` and `@Test func` name no symbol and are exactly what `search` answers; what this is looking for is the pattern with nothing of the language in it at all — `0\.1\.0`, `2026-09`, `->`.
    ///
    /// **No length floor, deliberately, though ``identifier(in:certain:)`` draws one at three characters.** Borrowing that floor here would score `grep -rn "\bid\b" Sources` and `grep -rn "os" Sources` as searches the index could not have served, which takes them out of ``TranscriptTally/total`` and *raises* the reported share — the one direction `TranscriptScan` says the tally may never round. The two floors answer different questions: three characters is a bar on guessing *which* name a phrase is about, and this asks only whether there is a name here at all. `where id` answers for a declared `id`, so a search for one is a lookup the index lost.
    static func namesNothing(in pattern: String) -> Bool {
        let text = pattern
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            .replacing(Self.escapeSequence, with: " ")
        return text.firstMatch(of: IndexSuggestion.identifier) == nil
    }

    /// The one symbol a pattern names, by three rules in order of confidence.
    ///
    /// A declaration keyword names what follows it; a `(` names what precedes it; otherwise the longest identifier in the pattern. Alternation exits early — two names are being sought at once, and no single call replaces that.
    ///
    /// `certain` narrows that third rule, and the difference matters more than it looks. The longest-word fallback finds a name in almost any English: `"revisit this later"` yields `revisit`. That is harmless when the command is *already* known to be a Swift lookup and the only question is what to suggest, and far too loose when it is deciding whether a search is a lookup at all — which would refuse every tree-wide search for a phrase in a comment.
    ///
    /// **What `certain` asks is whether the pattern is nothing but names**, which is ``namesNothingElse(_:names:)``, and not whether it is one bare word. That narrower reading would refuse `Type.member`, which is among the commonest shapes anyone greps for, and `some View`, whose only non-name word is Swift's own — counting both out of the classification and, since the advisor asks the same question, losing a correct nudge with them.
    ///
    /// The three-character floor bars guessing *which* word a phrase is about, so the loose reading drops it where there is nothing to guess: a pattern that is one name and nothing else — `\bid\b` — names that name, and `where id` is the call that answers it. The strict reading keeps the floor, because it decides whether an unmarked sweep is a lookup at all.
    static func identifier(in pattern: String, certain: Bool = false) -> String? {
        var text = pattern.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        guard !text.contains("|"), !spellsAFile(text) else { return nil }
        // The pattern may spell its own member path — `DepotStore\.comparison\b`, the regex form of a
        // member access — and nothing else. Read before the escape-blanking below, which would otherwise erase
        // the `\.` the same way it erases a bare boundary, losing the qualifier a bare word then has to invent.
        // A dot with no name in front of it — `\.comparison\b` — has none to keep, and falls through unchanged.
        if let qualified = qualifiedMember(in: text) {
            return qualified
        }
        // `\b`, `\s`, `\.` are boundaries, not name characters: `\bsummary\b` is looking for `summary`.
        text = text.replacing(Self.escapeSequence, with: " ")

        // A keyword after a declaration keyword is a modifier pair, not a name: `class func` declares no `func`.
        if let declared = text.firstMatch(of: Self.declaration)?.1, !keywords.contains(String(declared)) {
            return String(declared)
        }
        if let called = text.firstMatch(of: Self.callee)?.1 {
            return String(called)
        }
        let names = text.matches(of: IndexSuggestion.identifier).map { String($0.0) }
            .filter { !keywords.contains($0) && $0.count >= 3 }
        guard certain else {
            if names.isEmpty, let lone = loneName(in: pattern) {
                return lone
            }
            return names.max(by: { $0.count < $1.count })
        }
        guard let longest = names.max(by: { $0.count < $1.count }), namesNothingElse(text) else {
            return nil
        }
        return longest
    }

    /// Whether `pattern` is looking for names and nothing else: one name by the strict reading (``identifier(in:certain:)``), or an alternation of two or more (``TextSearch/alternatesBetweenNames(_:)``).
    ///
    /// The test an *unmarked* sweep is classified by, on both search surfaces — a search of a directory that turns out to hold Swift, where nothing in the arguments says "Swift" and the pattern is all there is to go on.
    ///
    /// **Why it is not ``identifier(in:certain:)`` alone.** That reading answers about *one* symbol and stops at a `|`, because two names are two questions and no single call replaces them — correct for what it returns, and wrong as a gate on whether there is Swift here at all. Used as one it dropped the whole several-names shape: `grep -rn "SimilarTarget|IndexSuggestion" Sources`, both names declared in this tree, was no lookup at all and drew nothing, while `grep -rn "SimilarTarget|IndexSuggestion" Sources --include=*.swift` beside it — the same ask, with its Swift-ness written in the arguments instead of left to the tree — was refused with one `where` per name. The pattern is the same in both; what differed was only whether the filesystem had to be probed for the answer.
    ///
    /// A pattern with no name in any branch stays out, which is the case the strict reading exists for: `SweepPattern` withholds an alternation of literals or dates whole and reads it as text, so `grep -rn "0\.1\.0\|2026-09" Sources` is no lookup here either. And a name no index declares is still withheld downstream, on the names the offer would have listed (`AdvisableName`), so widening the classification cannot widen what is actually said.
    static func namesOnly(_ pattern: String) -> Bool {
        identifier(in: pattern, certain: true) != nil || TextSearch.alternatesBetweenNames(pattern)
    }

    /// Whether `pattern` is anything one index call answers: names and nothing else (``namesOnly(_:)``), or a shape built from Swift's own declaration vocabulary (``SweepPattern/asksDeclarationVocabulary``).
    ///
    /// The test an *unmarked* sweep is classified by, on both search surfaces. ``namesOnly(_:)`` was that test until the same asymmetry it closed was found one step along: `grep -rn "final class" Sources` was let through while `grep -rn "final class" Sources --include=*.swift` beside it was refused with `search kind:class modifier:final`, on the one difference a caller never chooses for a reason — whether the sweep's Swift-ness is written in its arguments or has to be probed off the filesystem. A shape query is the thing `grep` genuinely cannot express, so it is the sweep `search` answers best.
    ///
    /// **Not `SweepPattern.reading(of:) != .text`**, which is the wider reading it looks like it should be. That reading is deliberately generous, because it answers a different question: what to *offer* for a sweep already known to be reading Swift. Used as the gate on whether there is Swift here at all it admits the prose it was never asked to judge — measured over 10,000 real searches from this machine's transcripts, it would have taken 226 more unmarked sweeps for names (`error:` as `where error`, `14 Sep 2026`, `Tests/`, `## Next`) and 52 more for shapes that are only a `name:` fragment of a markdown token. The bar for a shape is therefore `SweepPattern`'s own vocabulary test rather than its whole reading: over the same corpus that is 9 sweeps in 10,000, every one of them Swift.
    ///
    /// An alternation of names beside prose is in too (``SweepPattern/isPartial``): its names are answered and its prose is named as left to a search, so it is as much a lookup as the names alone, and a name no index declares is still withheld downstream (`AdvisableName`).
    static func answeredByOneCall(_ pattern: String) -> Bool {
        if namesOnly(pattern) {
            return true
        }
        let reading = SweepPattern.reading(of: pattern)
        return reading.asksDeclarationVocabulary || reading.isPartial
    }

    /// Whether `pattern` spells a file rather than a name — a path with a separator between two words, or a name ending in a file's extension.
    ///
    /// `rules/sift.md` and `View.swift` are the text of a file's name, searched for where it is written down — a comment, a string literal, a document — none of which the index records. Read as a dotted path, `rules/sift.md` stands on the name `sift` and a member `md`, and a sweep for it would be refused with `where sift`, which nobody asked for.
    ///
    /// The extensions are the ones a Swift name almost never ends in. Those an enum case often spells — `json`, `log`, `lock`, `resolved`, `md`, `csv`, `html`, `txt`, `yaml`, `yml`, `plist`, as in `Format.json` or `Spacing.md` — are left out, and such a pattern spells a file only where it also holds a path separator: taking a member for a file would drop a real lookup from the share. A comment marker is not a path either — its slashes have no word on their left.
    static func spellsAFile(_ pattern: String) -> Bool {
        let text = pattern
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            .replacing(#"\."#, with: ".")
            .replacing(trailingAnchors, with: "")
        return text.contains(pathSeparator) || text.contains(fileExtension)
    }

    /// A `/` with a word on either side of it — `rules/sift`, `SiftMCP/Shell` — which no Swift name holds.
    nonisolated(unsafe) static let pathSeparator = /[\p{L}\p{N}_.\-]\/[\p{L}\p{N}_.\-]/

    /// A name closing on the extension of a file a Swift repository keeps beside its source.
    nonisolated(unsafe) static let fileExtension =
        /(?i)[\p{L}\p{N}_\-]\.(?:swift|markdown|jsonl|xcstrings|stringsdict|xcconfig|entitlements|pbxproj|xcscheme|xcodeproj|xcworkspace|storyboard|xib|sh|zsh|py|rb|js|toml)$/

    /// Whether `pattern` spells a metatype or a self-expression, `T.Type` or `T.self`, which reads as the type `T` alone (``qualifiedMember(in:)``).
    ///
    /// The line such a search prints may hold `T` nowhere an index records it — a comment or a string literal — so the name it reads as is answered only where the search's own lines prove to be its references (``InPlaceAnswerer``). Read wide, from the pattern's text rather than its alternatives: a pattern taken for one when it is not only asks for a proof it did not need.
    static func spellsAMetatype(_ pattern: String) -> Bool {
        pattern.contains(metatypeExpression)
    }

    /// A name followed by `.Type` or `.self`, its dot escaped or bare, with no identifier character after it.
    nonisolated(unsafe) static let metatypeExpression = /[\p{L}\p{N}_]\\?\.(?:Type|self)(?![\p{L}\p{N}_])/

    /// Whether `pattern` spells a member reached through `Self`, `self` or `super`, such as `Self.x`, which reads as the member `x` alone (``qualifiedMember(in:)``).
    ///
    /// Held to the same proof as a metatype (``spellsAMetatype(_:)``), for the same reason: a line spelling `Self.x` or `self.x` in a comment or a string literal is no reference of `x`, and `where x` says nothing about it. Read wide, a `Self` behind any character at all: a pattern taken for one when it is not only asks for a proof it did not need.
    static func spellsASelfMember(_ pattern: String) -> Bool {
        pattern.contains(selfMemberExpression)
    }

    /// `Self`, `self` or `super` followed by a dot, escaped or bare, and the first character of a name.
    nonisolated(unsafe) static let selfMemberExpression = /(?:[Ss]elf|super)\\?\.[\p{L}_]/

    /// The anchors a pattern may close on after the text it looks for — `\b`, `\>`, `$`.
    nonisolated(unsafe) static let trailingAnchors = /(?:\\[b>]|\$)+$/

    /// The pattern's one name when it is a single identifier and nothing else — `\bid\b` is `id`.
    ///
    /// Under three characters it has to be word-anchored to count: an unanchored `x` or `id` matches inside every word that holds those letters, so the search is for text, and `where x` answers a question nobody asked.
    private static func loneName(in pattern: String) -> String? {
        let text = pattern.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        guard !text.contains("|") else { return nil }
        let lone = text.replacing(Self.escapeSequence, with: " ").trimmingCharacters(in: .whitespaces)
        guard lone.wholeMatch(of: IndexSuggestion.identifier) != nil, !keywords.contains(lone) else { return nil }
        guard lone.count >= 3 || text.contains(wordBoundary) else { return nil }
        return lone
    }

    /// A word boundary — `\b`, `\<`, `\>` — which confines a short name to whole words.
    nonisolated(unsafe) static let wordBoundary = /\\[b<>]/

    /// Whether `text` is a dotted path and nothing else — `UsageWindow`, `CatalogueStore.append`, `Outer.Nested.member`, `Café.menü`.
    ///
    /// **One target however many components it has.** Nothing here splits or resolves a path — that reading belongs to the resolver — and all this asks is whether the pattern is shaped like one. Refusing them would cost the classification a shape that is everywhere in real greps, and, since the advisor asks this question too, the nudge as well.
    ///
    /// **A space is not admitted.** Accepting any phrase whose words are all Swift keywords but one sounds narrow and is not: `keywords` holds fifty of the most English-looking words in the language, so `for now`, `do nothing`, `in progress`, `guard against`, `import order` and `catch block` all read as one name with context around it. Because this decides ``ShellQuery/readsSwift(holdsSource:)`` as well, that would widen *classification* and not merely the advice: over comment-sweep spellings of `grep -rn "<phrase>" Sources` it turns a handful of lookups into most of them, and a single live refusal into many — an order of magnitude more wrong nudges, in the direction Docs/Design.md names the costlier one. `some View` is the case it would serve and is not worth it; a missed nudge on one shape costs a missed opportunity, and a run of wrong ones costs the mechanism's credibility.
    ///
    /// The separator table is the whole of the safety property: dots only, so a comment marker's trailing colon, a digit-led token (`0 1 0`, left by `0\.1\.0`), a hyphen (`2026-09`) and any phrase with a space in it all fail outright.
    private static func namesNothingElse(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespaces).wholeMatch(of: IndexSuggestion.dottedName) != nil
    }

    /// A regex-escape sequence — `\b`, `\s`, `\.` — which is a boundary rather than part of a name.
    nonisolated(unsafe) static let escapeSequence = /\\./

    /// A declaration keyword and the name it introduces.
    ///
    /// Every name a pattern is read for is ``IndexSuggestion/identifier``, a Swift identifier in any script: read as ASCII, `Café` is `Caf` and `Überblick` is `berblick`, and a search for either is advised on a name nobody declared, then withheld and scored out of the share on it.
    nonisolated(unsafe) static let declaration = Regex {
        /\b(?:func|struct|class|enum|protocol|actor|extension|typealias|var|let|case)\s+\.?/
        Capture { IndexSuggestion.identifier }
    }

    /// A name with a call's open paren after it.
    nonisolated(unsafe) static let callee = Regex {
        Capture { IndexSuggestion.identifier }
        /\s*\(/
    }

    /// A type and a member joined by a dot, escaped or bare — the regex and the plain spelling of a member access — and nothing else beside an optional word boundary on either side: `DepotStore\.comparison\b`, `DepotStore.comparison`.
    nonisolated(unsafe) static let qualifiedMemberPattern = Regex {
        Anchor.startOfSubject
        Optionally { wordBoundary }
        Capture { IndexSuggestion.identifier }
        Optionally { "\\" }
        "."
        Capture { IndexSuggestion.identifier }
        Optionally { wordBoundary }
        Anchor.endOfSubject
    }

    /// `text`'s own `Type.member` path, where it spells one this literally — see ``qualifiedMemberPattern``.
    private static func qualifiedMember(in text: String) -> String? {
        guard let match = text.wholeMatch(of: qualifiedMemberPattern) else { return nil }
        let type = String(match.output.1)
        let member = String(match.output.2)
        // `Self` stands for whichever type is speaking, never a type's own name, so `Self.x` reads as the
        // member `x` alone — the reading a bare dot behind it gave before it read as a member path at all.
        if type == "Self" {
            return keywords.contains(member) ? nil : member
        }
        // `.Type` and `.self` are Swift's metatype and self-expression, never a member so named, so `T.Type`
        // and `T.self` read as the type `T` itself.
        if member == "Type" || member == "self" {
            return keywords.contains(type) ? nil : type
        }
        guard !keywords.contains(type), !keywords.contains(member) else { return nil }
        // A bare `.` is a regex's any-character, and between lowercase words it is one (`tab.about`); behind a
        // capitalised type it is the member access the pattern spells, as it is in ``TextSearch``'s reading —
        // unless the member is an extension a file's name closes on, which leaves `Depot.json` as much a file
        // as a member, and no path anyone escaped.
        guard text.contains("\\.") || type.first?.isUppercase == true && !caseLikeExtensions.contains(member.lowercased()) else {
            return nil
        }
        return "\(type).\(member)"
    }

    /// The extensions an enum case often spells — `Format.json`, `Spacing.md` — which ``fileExtension`` leaves out so a member keeps its lookup, and which make a bare-dotted pattern ambiguous with a file's name.
    private static let caseLikeExtensions: Set<String> = ["json", "log", "lock", "resolved", "md", "csv", "html", "txt", "yaml", "yml", "plist"]

    /// Swift words that are never the thing being looked for, only context around it.
    private static let keywords: Set<String> = [
        "func", "struct", "class", "enum", "protocol", "actor", "extension", "typealias", "var", "let",
        "case", "self", "init", "some", "any", "async", "await", "throws", "rethrows", "public", "private",
        "internal", "fileprivate", "package", "static", "final", "override", "where", "for", "while", "in",
        "do", "try", "catch", "switch", "guard", "return", "import", "if", "else", "nil", "true", "false",
    ]
}
