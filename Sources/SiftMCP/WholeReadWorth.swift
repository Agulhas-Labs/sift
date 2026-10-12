//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore

/// Whether a whole read of a Swift file, or a window over most of it, is worth answering with its digest, and whether a `Read` of a narrower window is worth answering at all, judged from what the answer spares and what the turns that follow it cost (`Docs/Design.md`).
///
/// **The inequality.** With F the file's tokens, D the answer's and C the context's at the call, the digest is the answer only where `(1 − wholeReReadShare) · F − D > rangedFollowUpShare · R + anyFollowUpShare · (cacheReadWeight · C) / (cacheWriteWeight + cacheReadWeight · T)`. Left of it is what the digest spares; right of it is what the follow-ups cost, the second term being a further turn's re-read of the context stated in tokens of answer.
///
/// **A `Read` window's inequality.** With W the window's tokens, its answer is kept only where `W − D > readWindowReRunShare · (W + turn)`, the turn priced as in the first: what the answer spares against the expected cost of the identical re-run, which prints the window and pays a turn.
///
/// The whole-read constants are planning figures measured over 181 hook answers to whole reads, the window's share over answered `Read` windows, and each judgement is pure so a test pins its boundary.
public struct WholeReadWorth {
    /// The share of answers followed by a whole read of the same file, which spares the file nothing.
    public static let wholeReReadShare = 0.34
    /// The share of answers followed by a ranged read of the same file.
    public static let rangedFollowUpShare = 0.47
    /// The share of answers followed by any further turn.
    public static let anyFollowUpShare = 0.85
    /// The share of answered windows a `Read` asked for by offset and limit that are followed by the identical `Read`, measured over answered Read windows.
    ///
    /// A `sed -n` window is followed by its re-run far less often, so this share prices the `Read` form alone.
    public static let readWindowReRunShare = 0.48
    /// The median ranged follow-up, in tokens, measured over the same answers as the whole-read shares.
    public static let rangedFollowUpTokens = 1330.0
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
    /// The share of a file's lines from which a window, or several on one file, is weighed as a whole read of it is.
    ///
    /// Answered with the digest, such a window pays the same further turn as the whole read: the reader asked for the file wholesale, under a line count chosen to be safely past its end or to stop short of its tail, and the answer spares only what the window prints. A window under the share asked for a part of the file, which the window rules alone judge. Three quarters rather than all of it, since a window that leaves out a header or the last few members is still the file read in bulk, and the rule only ever lets the read run; rather than half, since a half is as likely a chosen region as the file.
    public static let windowShare = 0.75

    /// The tokens the digest spares less the tokens the follow-ups cost, for a file of so many bytes answered with a digest of so many, in a context of so many tokens (``ContextSize/defaultTokens`` where it is not known).
    public static func margin(fileBytes: Int, digestBytes: Int, contextTokens: Int?) -> Double {
        let file = Double(fileBytes) / bytesPerToken
        let digest = Double(digestBytes) / bytesPerToken
        let spared = (1 - wholeReReadShare) * file - digest
        return spared - (rangedFollowUpShare * rangedFollowUpTokens + anyFollowUpShare * turn(contextTokens: contextTokens))
    }

    /// A further turn's re-read of a context of so many tokens (``ContextSize/defaultTokens`` where it is not known), stated in tokens of answer: the context read from the cache, over what one token of answer costs as it is written once and re-read by each of ``laterTurns``.
    static func turn(contextTokens: Int?) -> Double {
        let context = Double(contextTokens ?? ContextSize.defaultTokens)
        return cacheReadWeight * context / (cacheWriteWeight + cacheReadWeight * laterTurns)
    }

    /// The tokens a `Read` window's answer spares less the expected cost of the identical re-run, for a window printing so many bytes answered with so many, in a context of so many tokens (``ContextSize/defaultTokens`` where it is not known).
    ///
    /// The re-run prints the window and pays a turn, and follows the answer in ``readWindowReRunShare`` of cases.
    public static func readWindowMargin(windowBytes: Int, answerBytes: Int, contextTokens: Int?) -> Double {
        let window = Double(windowBytes) / bytesPerToken
        let answer = Double(answerBytes) / bytesPerToken
        return window - answer - readWindowReRunShare * (window + turn(contextTokens: contextTokens))
    }

    /// Whether an answer of so many bytes is worth answering a `Read` window printing so many bytes with, in a context of so many tokens.
    public static func isReadWindowWorthTheTurn(windowBytes: Int, answerBytes: Int, contextTokens: Int?) -> Bool {
        readWindowMargin(windowBytes: windowBytes, answerBytes: answerBytes, contextTokens: contextTokens) > 0
    }

    /// Whether a digest of so many bytes is worth answering a whole read of a file of so many bytes with, in a context of so many tokens.
    public static func isWorthTheTurn(fileBytes: Int, digestBytes: Int, contextTokens: Int?) -> Bool {
        margin(fileBytes: fileBytes, digestBytes: digestBytes, contextTokens: contextTokens) > 0
    }

    /// `outcome`, or the withholding `notWorthTheTurn` where it is the digest of one Swift file answering a whole read of it, or windows printing at least ``windowShare`` of its lines, and the turn after it costs more than it spares; or where it answers a narrower window a `Read` asked for and spares less than the identical re-run is expected to cost.
    ///
    /// Only those shapes are judged: a narrower window a shell command asked for, a document's outline, a line of several reads and every answer that is not that file's digest or its members keep the outcome they were given. A window printing most of the file is weighed with the inputs the whole read of the same file is weighed with, `Answered.wholeRead`: the file's bytes and what that read is served — the whole digest where it fits the size budget, its first page cut to fit otherwise — computed and chosen as the whole read is, whichever of the digest, its cut page or the members answers the window, so such a window is let through exactly where the whole read of its file is. Where that read would not be answered at all, the window keeps its outcome. A narrower `Read` window is weighed with its own answer: the bytes the window prints and the bytes served for it (``isReadWindowWorthTheTurn(windowBytes:answerBytes:contextTokens:)``). The file is read for its line count only once that answer has been built. The context's size is read only once the shape is known to be judged, so a call this does not judge never reads a transcript. A withholding prints no answer, so it writes no line to the answered log.
    public static func weighing(_ outcome: InPlaceAnswerer.Outcome, of reading: InPlaceShape.Match, payload: [String: Any]) -> InPlaceAnswerer.Outcome {
        guard case let .answered(answered) = outcome,
              reading.calls.count == 1, case let .fileDigest(path, windows) = reading.calls[0],
              !answered.calls.isEmpty, answered.calls.allSatisfy({ $0.tool == "digest" && $0.bytes.source != nil })
        else { return outcome }
        guard windows.isEmpty ? !reading.windowed.contains(true) : printsMost(windows, ofFileAt: path, in: reading.directory) else {
            guard !windows.isEmpty, payload["tool_name"] as? String == "Read" else { return outcome }
            let worth = isReadWindowWorthTheTurn(
                windowBytes: answered.calls.reduce(0) { $0 + ($1.bytes.source ?? 0) },
                answerBytes: answered.calls.reduce(0) { $0 + $1.bytes.served },
                contextTokens: ContextSize.ofCall(payload)
            )
            return worth ? outcome : .withheld(.notWorthTheTurn)
        }
        // A window answered as the whole read of the file (its windows print every line) carries that read's own bytes.
        guard let weighed = windows.isEmpty ? (answered.calls.count == 1 ? answered.calls[0].bytes : nil) : answered.wholeRead else { return outcome }
        let worth = isWorthTheTurn(fileBytes: weighed.source ?? 0, digestBytes: weighed.served, contextTokens: ContextSize.ofCall(payload))
        return worth ? outcome : .withheld(.notWorthTheTurn)
    }

    /// Whether `windows` print at least ``windowShare`` of the lines of the file at `path`, a window past its end counting to its end; false where the file or a window cannot be read.
    static func printsMost(_ windows: [LineWindow], ofFileAt path: String, in directory: String?) -> Bool {
        guard let lines = OperandFile.linesPrinted(by: windows, ofFileAt: path, in: directory), lines.total > 0 else { return false }
        return Double(lines.printed) >= windowShare * Double(lines.total)
    }
}
