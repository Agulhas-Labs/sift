//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore

/// Whether a whole read of a Swift file is worth answering with its digest, judged from what the answer spares and what the turns that follow it cost (`Docs/Design.md`).
///
/// **The inequality.** With F the file's tokens, D the answer's and C the context's at the call, the digest is the answer only where `(1 − wholeReReadShare) · F − D > rangedFollowUpShare · R + anyFollowUpShare · (cacheReadWeight · C) / (cacheWriteWeight + cacheReadWeight · T)`. Left of it is what the digest spares; right of it is what the follow-ups cost, the second term being a further turn's re-read of the context stated in tokens of answer.
///
/// Every constant is a planning figure measured over 181 hook answers to whole reads, and the judgement is pure so a test pins its boundary.
public struct WholeReadWorth {
    /// The share of answers followed by a whole read of the same file, which spares the file nothing.
    public static let wholeReReadShare = 0.34
    /// The share of answers followed by a ranged read of the same file.
    public static let rangedFollowUpShare = 0.47
    /// The share of answers followed by any further turn.
    public static let anyFollowUpShare = 0.85
    /// The median ranged follow-up, in tokens.
    public static let rangedFollowUpTokens = 700.0
    /// The later turns that re-read the answer.
    public static let laterTurns = 50.0
    /// What writing a token to the cache costs against an input token.
    public static let cacheWriteWeight = 1.25
    /// What reading a token from the cache costs against an input token.
    public static let cacheReadWeight = 0.1
    /// The bytes one token stands for, which is how F and D are taken from byte counts.
    ///
    /// The same figure every other face prices with, ``TokenEstimate/bytesPerToken``, as a `Double`, because F and D are fractions here.
    public static let bytesPerToken = Double(TokenEstimate.bytesPerToken)

    /// The tokens the digest spares less the tokens the follow-ups cost, for a file of so many bytes answered with a digest of so many, in a context of so many tokens (``ContextSize/defaultTokens`` where it is not known).
    public static func margin(fileBytes: Int, digestBytes: Int, contextTokens: Int?) -> Double {
        let file = Double(fileBytes) / bytesPerToken
        let digest = Double(digestBytes) / bytesPerToken
        let context = Double(contextTokens ?? ContextSize.defaultTokens)
        let spared = (1 - wholeReReadShare) * file - digest
        let turn = cacheReadWeight * context / (cacheWriteWeight + cacheReadWeight * laterTurns)
        return spared - (rangedFollowUpShare * rangedFollowUpTokens + anyFollowUpShare * turn)
    }

    /// Whether a digest of so many bytes is worth answering a whole read of a file of so many bytes with, in a context of so many tokens.
    public static func isWorthTheTurn(fileBytes: Int, digestBytes: Int, contextTokens: Int?) -> Bool {
        margin(fileBytes: fileBytes, digestBytes: digestBytes, contextTokens: contextTokens) > 0
    }

    /// `outcome`, or the withholding `notWorthTheTurn` where it is the digest of one Swift file answering a whole read of it and the turn after it costs more than it spares.
    ///
    /// Only that one shape is judged: a window, a document's outline, a line of several reads and every answer that is not a file's digest keep the outcome they were given. The context's size is read only once a whole read's answer has been built, so a call this does not judge never reads a transcript. A withholding prints no answer, so it writes no line to the answered log.
    public static func weighing(_ outcome: InPlaceAnswerer.Outcome, of reading: InPlaceShape.Match, payload: [String: Any]) -> InPlaceAnswerer.Outcome {
        guard case let .answered(answered) = outcome,
              reading.calls.count == 1, !reading.windowed.contains(true),
              case let .fileDigest(_, windows) = reading.calls[0], windows.isEmpty,
              answered.calls.count == 1, answered.calls[0].tool == "digest",
              let source = answered.calls[0].bytes.source
        else { return outcome }
        let worth = isWorthTheTurn(fileBytes: source, digestBytes: answered.calls[0].bytes.served, contextTokens: ContextSize.ofCall(payload))
        return worth ? outcome : .withheld(.notWorthTheTurn)
    }
}
