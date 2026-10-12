//
// Copyright © Agulhas Labs
//

import SwiftParser
import SwiftSyntax

/// The way every parse of Swift source is made: on a ``ParseThread``, after a check that keeps from the parser the one shape it would take exponential time on.
///
/// Deciding whether a `[` opens a type, the parser looks ahead twice at every `[` that follows another (once for an inline array, once for any other type), and the lookahead stops neither at its nesting cap nor in linear time: twenty `[` in a row take minutes. Generic arguments, prefix keywords such as `try` and `await`, function arrows, `else if` arms and `#if` blocks are nestings the cap does not reach: the parser descends once per `Name<`, keyword, arrow, arm or `#if` for as long as they go on (a generic lookahead in time that grows with the square of the depth), until even a parse thread's stack runs out. So they are measured first, by one pass over the bytes (``NestingScan``), and a file past one of the limits here is not parsed: the index records it as a file with a parse error and no declarations, and every other read treats it as holding nothing. Any other depth is the parse thread's to take.
struct NestingGate {
    /// The longest run of `[` that is parsed, counting those with nothing but whitespace, `(` and a generic type's `Name<` between them.
    static let maximumTypeChain = 10

    /// The deepest generic arguments that are parsed, counting each `Name<` (a name written directly against its `<`, not a `<<` or `<=`) not yet closed by a `>`, between one `{`, `}` or `;` and the next.
    ///
    /// A debug build's parse thread survives some 4000 levels of `Dictionary<A, Array<B, …` (8000 `Name<`), and its lookahead takes seconds past a few hundred, as it does for an array of a few hundred unspaced comparisons (`a<b,`) it cannot tell from them.
    static let maximumGenericDepth = 512

    /// The longest chain parsed of prefix keywords in a row (`try`, `try?`, `await`, `unsafe`, `consume` and the like), of function arrows in one declaration, and of `else if` arms in one block.
    ///
    /// Each takes the parser one recursion, which a debug build's parse thread survives past 20000 of, a release build's past 40000; real code has a handful.
    static let maximumChain = 4096

    /// The deepest `#if` blocks that are parsed, which a debug build's parse thread survives some 10000 of.
    static let maximumConditionDepth = 256

    /// The message a refused file's one parse error carries.
    static var message: String {
        "nesting too deep for sift to parse"
    }

    /// `read` applied to the tree of `source`, on a parse thread, or `nil` where the source nests past a limit.
    static func parse<Result>(_ source: String, _ read: (SourceFileSyntax) -> Result) -> Result? {
        guard admits(source) else { return nil }
        return ParseThread.parse(source, read)
    }

    /// `read` applied to `source` parsed as a type alone, on a parse thread, or to a missing type's, which has an error, where the source nests past a limit.
    static func parseTypeOrMissing<Result>(_ source: String, _ read: (TypeSyntax) -> Result) -> Result {
        ParseThread.parseType(admits(source) ? source : "", read)
    }

    /// `read` applied to the tree of `source`, or to an empty file's where the source nests past a limit: for a read that looks for something in the tree and finds nothing in a file it could not parse.
    static func parseOrEmpty<Result>(_ source: String, _ read: (SourceFileSyntax) -> Result) -> Result {
        ParseThread.parse(admits(source) ? source : "", read)
    }

    /// Whether `source` stays within both limits.
    static func admits(_ source: String) -> Bool {
        var scan = NestingScan()
        var text = source
        return text.withUTF8 { scan.run($0) }
    }
}
