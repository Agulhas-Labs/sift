//
// Copyright © Agulhas Labs
//

/// One declaration's story between two parses of the same file — added, removed, changed, or moved, with enough on each side to address its body directly.
///
/// A container matched on both sides is never reported whole: its own line is a `.changed` entry only when its *signature* or its `#if` condition differs (an access level, a conformance), and its members are diffed separately and recurse under `containerPath` extended with its name. A container present on only one side is reported as a single `.added`/`.removed` entry instead of enumerating its members one by one — `memberCount` says how many it carries — because "a new type showed up" is the fact a reviewer needs here, and `sift digest` already answers "what does it hold".
struct DeclarationChange: Sendable {
    let kind: Kind
    /// The dotted path of enclosing types/extensions this declaration sits under — `""` at file scope.
    ///
    /// What `--member` matches against.
    let containerPath: String
    /// The same path as a heading shows it, where an extension's own clause is what tells two same-named containers apart — `Array (extension where Element == Int)`.
    let containerDisplay: String
    /// The declaration's own written name — the labeled form for a function (`save(_:to:)`), so overloads are told apart the same way `digest`/`where` addressing does.
    let name: String
    let symbolKind: SymbolKind
    let oldSignature: String?
    let newSignature: String?
    let oldRange: DeclarationRange?
    let newRange: DeclarationRange?
    /// The `#if` chain each side sat under — what tells two same-named declarations in different branches apart (Docs/AnswerContract.md §6).
    let oldCondition: String?
    let newCondition: String?
    /// On a `.changed` leaf whose effective access level moved, both sides' levels — set even where its own text did not change, since `extension W` becoming `public extension W` makes every member in it public.
    let oldAccess: AccessLevel?
    let newAccess: AccessLevel?
    /// `false` on a `.changed` leaf means its signature line did not move — the text that differs is elsewhere in it.
    let signatureChanged: Bool
    /// On a `.changed` leaf, whether its own text differs at all — `false` where only its `#if` condition moved.
    let textChanged: Bool
    /// Set only on a wholly added/removed *container* — how many descendants it carries, since those are not listed individually.
    let memberCount: Int?
    /// The lines this entry answers for on each side — its whole range, except a container matched on both sides, which answers only for its own lines: its header, and its closing brace where that is what moved (its members answer for themselves).
    ///
    /// What the line-diff check measures the answer against: a hunk no entry's span meets is named on its own rather than left to read as unchanged.
    let oldSpans: [DeclarationRange]
    let newSpans: [DeclarationRange]
    /// On a `.changed` container whose header and condition did not change: where it opens or closes moved, so what it encloses changed — a closing brace moved past the next type, a header moved above two others.
    let extentChanged: Bool
    /// On a `.moved` entry, whether its whole lines are byte for byte what they were — every descendant of a moved type unchanged included — so "text unchanged" is never said of a type whose member was edited.
    let movedIntact: Bool
    /// Both sides' whole lines — kept only for the declaration a `--member` answer names, since a large range holds a great many.
    let oldBody: String?
    let newBody: String?
    /// Every function nested anywhere under a wholly added/removed *container* — empty otherwise.
    ///
    /// Not printed by the declarations section (which reports the container as one line, `memberCount` and all), but the test-files section needs the individual names even here: a deleted suite is not a suite that lost no tests.
    let nestedFunctions: [NestedFunction]
}

extension DeclarationChange {
    enum Kind: Sendable, Equatable {
        case added, removed, changed
        /// Present on both sides with the same text, but in a different place among its siblings — a reorder is a change to the file, and a review tool silent about one would read as "nothing here".
        case moved
    }

    struct NestedFunction: Sendable {
        let name: String
        let signature: String
    }

    var conditionChanged: Bool {
        kind == .changed && !SourceText.same(oldCondition, newCondition)
    }

    /// This change with both sides' bodies attached.
    func withBodies(old: String?, new: String?) -> DeclarationChange {
        DeclarationChange(
            kind: kind,
            containerPath: containerPath,
            containerDisplay: containerDisplay,
            name: name,
            symbolKind: symbolKind,
            oldSignature: oldSignature,
            newSignature: newSignature,
            oldRange: oldRange,
            newRange: newRange,
            oldCondition: oldCondition,
            newCondition: newCondition,
            oldAccess: oldAccess,
            newAccess: newAccess,
            signatureChanged: signatureChanged,
            textChanged: textChanged,
            memberCount: memberCount,
            oldSpans: oldSpans,
            newSpans: newSpans,
            extentChanged: extentChanged,
            movedIntact: movedIntact,
            oldBody: old,
            newBody: new,
            nestedFunctions: nestedFunctions
        )
    }

    /// The label `--member` and the ambiguity refusal address this declaration by: its container path and its name.
    var label: String {
        containerPath.isEmpty ? name : "\(containerPath).\(name)"
    }

    /// The line an address pins this declaration to — the after side's, or the before side's for a removal.
    var addressLine: (line: Int, before: Bool)? {
        if let newRange {
            return (newRange.line, false)
        }
        if let oldRange {
            return (oldRange.line, true)
        }
        return nil
    }
}
