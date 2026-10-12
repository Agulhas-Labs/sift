//
// Copyright © Agulhas Labs
//

import SwiftSyntax

/// Counts the places the parser recovered from in a tree, in one walk that enters only the subtrees holding an error, without generating a diagnostic for any of them.
///
/// The diagnostics generator does work per error that grows with the errors before it, so a generated file with a hundred thousand errors holds it for hours; this count is linear, and is what decides whether the generator is run at all.
///
/// A site is an unexpected-nodes collection, a run of missing tokens with no present token between them, or a present token the lexer flagged as an error: the shapes the generator words one diagnostic for. It is close to the generator's count, not equal to it, since the generator merges some neighbouring sites into one diagnostic and words some as two.
///
/// The walk keeps its own stack rather than recursing, so a recovered tree as deep as it is long, which a run of a hundred thousand stray `.` parses to, cannot overflow the thread's.
struct ParseErrorTally {
    /// How many sites the walk found.
    let count: Int
    /// Where the first site in source order starts, `nil` when there is none.
    let first: AbsolutePosition?

    /// The tally of `tree`, walked once.
    init(walking tree: some SyntaxProtocol) {
        var count = 0
        var first: AbsolutePosition?
        // Whether the last token reached was missing, so a missing token after it continues one site rather than starting another.
        var afterMissing = false
        var pending = [Syntax(tree)]
        while let node = pending.popLast() {
            guard node.hasError else {
                // A subtree with no error holds no missing token, so any text in it is a present token that ends a run.
                if node.totalLength.utf8Length > 0 {
                    afterMissing = false
                }
                continue
            }
            let isMissingToken = node.as(TokenSyntax.self)?.presence == .missing
            if node.is(UnexpectedNodesSyntax.self) || node.is(TokenSyntax.self) {
                if !(isMissingToken && afterMissing) {
                    count += 1
                    first = first ?? node.positionAfterSkippingLeadingTrivia
                }
                afterMissing = isMissingToken
            } else {
                pending.append(contentsOf: node.children(viewMode: .all).reversed())
            }
        }
        self.count = count
        self.first = first
    }
}
