//
// Copyright © Agulhas Labs
//

import Foundation

/// Whether a file's text may hold a `Self(x)` call, which spells no type name and no `init`: `Self`, any spaces and line breaks, then `(`.
///
/// A pre-filter ahead of a parse, so it may say yes of text that holds no call (a longer name ending in `Self`, a comment); it never says no of text that holds one.
struct SelfCallSpelling {
    /// Whether `bytes` spell `Self` followed by optional whitespace and an opening parenthesis.
    static func isWritten(in bytes: some Collection<UInt8>) -> Bool {
        var matched = 0
        var afterName = false
        for byte in bytes {
            if afterName {
                if byte == UInt8(ascii: "(") {
                    return true
                }
                if byte == UInt8(ascii: " ") || byte == UInt8(ascii: "\t") || byte == UInt8(ascii: "\n") || byte == UInt8(ascii: "\r") {
                    continue
                }
                afterName = false
                matched = 0
            }
            if byte == name[matched] {
                matched += 1
                if matched == name.count {
                    afterName = true
                    matched = 0
                }
            } else {
                matched = byte == name[0] ? 1 : 0
            }
        }
        return false
    }

    /// Whether `text` spells a `Self(x)` call, as ``isWritten(in:)`` reads it.
    static func isWritten(in text: String) -> Bool {
        isWritten(in: text.utf8)
    }

    private static let name = Array("Self".utf8)
}
