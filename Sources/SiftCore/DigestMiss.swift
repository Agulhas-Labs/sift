//
// Copyright © Agulhas Labs
//

import Foundation

/// What a `digest` answer that resolved nothing says, and the one place that says it.
///
/// A target the index could not resolve is answered with a diagnosis rather than a failure: `no symbol named X in the index`, `could not resolve the path …`, or a list of nearest symbols or members. The call succeeds (`ok` stays true, since the status line and other figures read it), and what it served locates no file, so nothing that credits a digest — the usage log's lookups, the hook's replay, the transcript scan — may credit one of these. They all ask this, and the renderers build their lines from the markers below, so a rewording changes both ends together.
public struct DigestMiss {
    /// The opening of the line that says no symbol of the name is indexed.
    public static var noSymbolPrefix: String {
        "no symbol named "
    }

    /// The end of that line.
    public static var noSymbolSuffix: String {
        " in the index"
    }

    /// The opening of the line that says a path's qualifier does not hold the name, or that a type holds no such member.
    public static var unresolvedPathPrefix: String {
        "could not resolve the path "
    }

    /// The end of the line that offers the nearest symbols to a type or member that names none.
    public static var nearestSymbolsSuffix: String {
        "; nearest symbols:"
    }

    /// The end of the line that offers a type's nearest members to a member it does not have.
    public static var nearestMembersSuffix: String {
        "; its nearest members:"
    }

    /// Whether `answer` is a digest that resolved nothing: it carries one of the miss lines and names no file under a heading, which a digest that served something always does.
    ///
    /// A several-target answer in which one target resolved is not a miss, since it located what it served.
    public static func isMiss(inAnswer answer: String) -> Bool {
        guard answer.split(whereSeparator: \.isNewline).contains(where: isMissLine) else { return false }
        return ExactAnswer.files(inSearchAnswer: answer).isEmpty && ExactAnswer.servedFile(inDigestAnswer: answer) == nil
    }

    private static func isMissLine(_ line: Substring) -> Bool {
        if line.hasPrefix(noSymbolPrefix), line.hasSuffix(noSymbolSuffix) {
            return true
        }
        if line.hasPrefix(unresolvedPathPrefix) {
            return true
        }
        return line.hasPrefix("no type") && line.hasSuffix(nearestSymbolsSuffix)
    }
}
