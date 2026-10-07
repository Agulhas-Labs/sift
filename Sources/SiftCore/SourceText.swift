//
// Copyright © Agulhas Labs
//

/// How `diff` compares two pieces of source text: as the bytes git compares, never as Swift strings.
///
/// Swift's `String` equality is canonical equivalence, so a composed and a decomposed `é` compare equal — and a review tool built on it says "unchanged" about a change git shows. The one difference folded away is a line terminator: `\r\n` and `\n` compare equal here, so a line-ending conversion is not reported as every multi-line declaration's body changing; the line diff underneath the answer still sees it, and names it for what it is.
struct SourceText {
    /// Whether two texts are the same bytes, line terminators aside.
    static func same(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.elementsEqual(rhs.utf8) || bytes(lhs) == bytes(rhs)
    }

    /// The same for text that may be absent on either side: two absences are the same, an absence and a text are not.
    static func same(_ lhs: String?, _ rhs: String?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): true
        case let (lhs?, rhs?): same(lhs, rhs)
        default: false
        }
    }

    /// The text's UTF-8 bytes, every `\r\n` read as `\n`.
    static func bytes(_ text: String) -> [UInt8] {
        var folded: [UInt8] = []
        folded.reserveCapacity(text.utf8.count)
        for byte in text.utf8 {
            if byte == 0x0A, folded.last == 0x0D {
                folded.removeLast()
            }
            folded.append(byte)
        }
        return folded
    }
}
