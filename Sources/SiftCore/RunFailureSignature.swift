//
// Copyright © Agulhas Labs
//

import Foundation

/// A failure message with everything that varies between two failures of the same kind elided, so failures that are the same thing collapse onto one another.
///
/// A count of failures is not a diagnosis; a *shape* of failures usually is — and no shape can appear while every message is unique. Four elisions produce one: a double-quoted string literal becomes `"…"`, a hex address `0x…`, a run of digits `…`, and a run of whitespace a single space. Everything else survives verbatim — the call, the operator, the property names — because that is the half of the message that says what *kind* of failure it was.
///
/// The normalisation is deliberately conservative and deliberately untuned. It was measured before it was written and it stays where the measurement left it: over the 666 failures of `xcodebuild-test-execute-failure-environmental` it yields 210 signatures from 434 distinct messages, the largest covering 117 of them. Loosening it until the number flattered the tool would make the signature count a claim about this normaliser rather than a measurement of the run.
///
/// Two things it pointedly does not do. It never strips a location, because a failure record carries one separately, and a location that leaks into a message normalises to `File.swift:…:…:` regardless — two failures at different lines of one file still collapse. And it leaves a zero-width space (U+200B) alone: the captures carry 306 of them, none inside a message, and Unicode does not classify one as whitespace — a rule for a character this corpus has never put in a message would be tuning against nothing.
public struct RunFailureSignature: Hashable, Sendable {
    /// The normalised message, which is what the classification block prints.
    public let text: String

    public init(message: String) {
        text = Self.normalised(message)
    }
}

private extension RunFailureSignature {
    /// One left-to-right pass, because the elisions compose: a number inside a string literal belongs to the literal, and the `0` of an address is not a number of its own.
    static func normalised(_ message: String) -> String {
        var output = String.UnicodeScalarView()
        output.reserveCapacity(message.utf8.count)
        var rest = message.unicodeScalars[...]
        while let scalar = rest.first {
            switch scalar {
            case "\"":
                // An unclosed quote is left as an ordinary character rather than swallowing the tail: interleaved output is the only way one arrives, and the rest of the message is still worth keeping.
                if let afterLiteral = skippingStringLiteral(rest) {
                    output.append(contentsOf: "\"…\"".unicodeScalars)
                    rest = afterLiteral
                } else {
                    output.append(scalar)
                    rest = rest.dropFirst()
                }
            case "0" where startsAddress(rest):
                output.append(contentsOf: "0x…".unicodeScalars)
                rest = rest.dropFirst(2).drop(while: \.properties.isASCIIHexDigit)
            case _ where isDigit(scalar):
                output.append("…")
                rest = rest.drop(while: isDigit)
            case _ where scalar.properties.isWhitespace:
                output.append(" ")
                rest = rest.drop(while: \.properties.isWhitespace)
            default:
                output.append(scalar)
                rest = rest.dropFirst()
            }
        }
        return String(output).trimmingCharacters(in: .whitespaces)
    }

    /// Everything after the closing quote of the literal `scalars` opens on, or `nil` when it never closes.
    static func skippingStringLiteral(_ scalars: Substring.UnicodeScalarView) -> Substring.UnicodeScalarView? {
        var index = scalars.index(after: scalars.startIndex)
        while index < scalars.endIndex {
            switch scalars[index] {
            case "\\":
                index = scalars.index(index, offsetBy: 2, limitedBy: scalars.endIndex) ?? scalars.endIndex
            case "\"":
                return scalars[scalars.index(after: index)...]
            default:
                index = scalars.index(after: index)
            }
        }
        return nil
    }

    /// Whether `scalars` opens on `0x` followed by at least one hex digit — a bare `0` is a number, not an address.
    static func startsAddress(_ scalars: Substring.UnicodeScalarView) -> Bool {
        var index = scalars.index(after: scalars.startIndex)
        guard index < scalars.endIndex, scalars[index] == "x" else {
            return false
        }
        index = scalars.index(after: index)
        return index < scalars.endIndex && scalars[index].properties.isASCIIHexDigit
    }

    static func isDigit(_ scalar: Unicode.Scalar) -> Bool {
        ("0" ... "9").contains(scalar)
    }
}
