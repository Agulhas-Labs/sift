//
// Copyright © Agulhas Labs
//

import Foundation

/// A catalog key read as the literal text around its format specifiers, so an interpolated Swift literal can be matched to the key the compiler extracts from it.
///
/// `"Hello %@"` is the pieces `["Hello ", ""]`; a literal `"Hello \(name)"` has the printed segments `["Hello ", ""]`, and each interpolation stands for one specifier. The match is by position and text only: the interpolation's type is not known to a syntactic read, so `%@`, `%lld` and `%f` each stand for any one interpolation.
struct FormatKeyPieces {
    /// The conversion characters a specifier may end on.
    private static let conversions: Set<Character> = ["@", "d", "D", "i", "u", "U", "x", "X", "o", "O", "f", "F", "e", "E", "g", "G", "c", "C", "s", "S", "p"]

    /// The literal text between the specifiers of `key`, one more piece than specifiers; `nil` when the key holds no specifier.
    static func pieces(of key: String) -> [String]? {
        let characters = Array(key)
        var pieces: [String] = []
        var current = ""
        var index = 0
        while index < characters.count {
            if characters[index] == "%", index + 1 < characters.count, characters[index + 1] == "%" {
                current.append("%")
                index += 2
            } else if characters[index] == "%", let end = specifierEnd(in: characters, from: index) {
                pieces.append(current)
                current = ""
                index = end
            } else {
                current.append(characters[index])
                index += 1
            }
        }
        guard !pieces.isEmpty else {
            return nil
        }
        return pieces + [current]
    }

    /// The index after the specifier starting at `start` (a `%`), `nil` when what follows is not one: `%@`, `%lld`, `%1$@`, `%.2f`, `%-5d`.
    ///
    /// A `%%` is no specifier (a pair is read as a literal `%` before this is asked), and a space is no flag: Xcode never writes one into a key, and `50% off` is plain text.
    private static func specifierEnd(in characters: [Character], from start: Int) -> Int? {
        var index = start + 1
        func skip(while predicate: (Character) -> Bool) {
            while index < characters.count, predicate(characters[index]) {
                index += 1
            }
        }
        let digitsStart = index
        skip { $0.isASCII && $0.isNumber }
        if index > digitsStart, index < characters.count, characters[index] == "$" {
            index += 1
        } else {
            index = digitsStart
        }
        skip { "-+0#".contains($0) }
        skip { $0.isASCII && $0.isNumber }
        if index < characters.count, characters[index] == "." {
            index += 1
            skip { $0.isASCII && $0.isNumber }
        }
        skip { "lhqztj".contains($0) }
        guard index < characters.count, Self.conversions.contains(characters[index]) else {
            return nil
        }
        return index + 1
    }
}
