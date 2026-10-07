//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore

/// How a compound line's parts are printed as one answer body.
struct CompoundAnswerBody {
    /// `parts` as one body: each call's answer opening on ``SiftCore/SourcePassthrough/partMarker`` after the first, as `DigestRenderer.joinedAnswers` joins answers, under one guessed-module banner for them all.
    ///
    /// A literal is printed verbatim and carries no mark, since the mark is there only so an answer's own file headers can be told from a served body's text. Text a literal leaves without a closing newline runs straight into a literal after it, as a terminal shows it, but a call's answer after it still opens on a marked line of its own: a file header run on mid-line is one the audit cannot read back.
    static func joined(_ parts: [(isLiteral: Bool, text: String)]) -> String {
        let (texts, banner) = GuessedModuleNotice.hoisted(from: parts.map { $0.isLiteral ? "" : $0.text })
        var body = banner.map { $0 + "\n\n" } ?? ""
        var printed = false
        var runsOn = false
        for (part, text) in zip(parts, texts) where !(part.isLiteral && part.text.isEmpty) {
            if printed, !(runsOn && part.isLiteral) {
                body += part.isLiteral ? "\n\n" : "\n\n\(SourcePassthrough.partMarker)"
            }
            printed = true
            runsOn = part.isLiteral && !part.text.hasSuffix("\n")
            body += part.isLiteral ? (runsOn ? part.text : String(part.text.dropLast())) : text
        }
        return body
    }
}
