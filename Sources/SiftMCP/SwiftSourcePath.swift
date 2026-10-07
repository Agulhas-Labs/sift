//
// Copyright © Agulhas Labs
//

import Foundation

/// Whether a piece of text names a Swift *source file*.
///
/// The single definition of what `.swift` means, because a substring search is wrong in a way that fires constantly: a path through `.swiftpm/` — or any directory whose name begins the same way — contains the literal `.swift`, so every `cat` of a file under one would classify as a lookup of Swift source. And because the ledger quiets itself after a run of unheeded nudges, the mechanism would spend its credibility before it had met a single real lookup.
///
/// `.swiftmodule`, `.swiftinterface` and `.swiftdoc` are build products rather than source, and fall out of the same boundary for free.
public struct SwiftSourcePath {
    /// Whether `text` contains a path whose extension is exactly `swift`.
    public static func appearsIn(_ text: String) -> Bool {
        text.contains(extensionExpression)
    }

    /// Whether `path` is a glob — a pattern standing for every file it matches, and so never one file.
    ///
    /// `git grep pat -- '*.swift'` and `grep pat Sources/*.swift` restrict a search to Swift source, the intent `--include=*.swift` spells as a flag. Neither names a file to digest, and the stem read off one is `*`.
    ///
    /// Only `*` and `?` make one. A bracket is left out because it is as likely to be a directory's name — `Sources/App/[Old]/X.swift` — as a character class, and a bracket class with no wildcard beside it names few enough files that reading it as one path costs less than sweeping a real one.
    public static func isGlob(_ path: String) -> Bool {
        path.contains { $0 == "*" || $0 == "?" }
    }

    /// Whether `path` holds a brace expansion (`{Uses,Gizmo}.swift`) the shell would have split into several words before the search ever ran.
    ///
    /// Never one path of its own, and nothing `fnmatch`'s glob matching reads either — no answer stands in for the list of paths the shell would have produced, so a path shaped this way is left for the search itself to answer rather than misread as a glob or a literal file that is never there.
    public static func isBraceExpansion(_ path: String) -> Bool {
        path.contains(/\{[^{}]*,[^{}]*\}/)
    }

    /// `.swift` not followed by another extension character, so `.swiftpm`, `.swiftinterface` and anything else that merely begins the same way is not a Swift source file.
    ///
    /// A `Regex` rather than a pattern string: the redirect form composes this value instead of concatenating its source, so the two readings still cannot drift apart, and it is checked at compile time rather than at first use. Native `Regex` also matches against Swift's own string storage — `NSRegularExpression` bridges to `NSString` and reads it back a UTF-16 unit at a time, which a profile of a full audit put at the top of the tree.
    ///
    /// `nonisolated(unsafe)` because `Regex` is not `Sendable` — it lazily builds and caches a compiled program — and every caller here is serial: the transcript scan is single-threaded, the MCP server is an actor consuming stdin one line at a time, and the PreToolUse hook is a short-lived process of its own.
    ///
    /// Anything that ever matches these concurrently must give each task its own value rather than remove this annotation.
    nonisolated(unsafe) static let extensionExpression = /\.swift(?![0-9A-Za-z_])/.ignoresCase()
}
