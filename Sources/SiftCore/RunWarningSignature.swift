//
// Copyright © Agulhas Labs
//

import Foundation

/// What two of a build's or a test run's warnings must share to be listed as one line with a count.
///
/// **Narrower than ``RunFailureSignature``, on purpose.** That signature elides digits and string literals because a test failure's message is about values; a warning located at a line is a separate thing to fix at that site, so `unused value 19` and `unused value 20` stay two lines. A located warning is therefore grouped on its message verbatim, and only with another warning carrying exactly the same words.
///
/// **An unlocated warning is grouped with each absolute path in its message elided whole.** With no line to tell two reports apart, the file the message names is the only thing that varies between copies of one fault: a release build passing `-ffile-prefix-map` prints `warning: <dir>/<Module>-<hash>.pcm: No such file or directory` once per module per pass, every line different text saying one thing. The hash sits in the path, so it goes with it. A relative or `@rpath/` path is kept, and so is a bare hash outside a path, since no capture shows one.
///
/// A located warning never shares a signature with an unlocated one, whatever their words, and an unlocated warning reported against a file shares one only with another against the same file.
struct RunWarningSignature: Hashable {
    /// Whether the warning names a line, which decides how much of its message is compared.
    let located: Bool
    /// The message as compared: verbatim for a located warning, its absolute paths elided for an unlocated one.
    let text: String
    /// The file an unlocated warning is reported against, compared verbatim: a project or package named before `warning:` is the one thing the listing prints of it, so two of them never fold into one.
    let unlocatedPath: String?

    init(_ warning: RunDiagnostic) {
        located = warning.line != nil
        text = located ? warning.message : Self.elidingAbsolutePaths(warning.message)
        unlocatedPath = located ? nil : warning.path
    }
}

extension RunWarningSignature {
    /// One line of the warnings listing: the first warning of a signature, and how many the log carried.
    struct Group {
        let example: RunDiagnostic
        let count: Int
    }

    /// `warnings` as one group per signature, in the order each signature first appears.
    ///
    /// Log order rather than most frequent first, so a run where nothing repeats lists exactly what it printed, in the order it printed it.
    static func grouped(_ warnings: [RunDiagnostic]) -> [Group] {
        var order: [RunWarningSignature] = []
        var groups: [RunWarningSignature: Group] = [:]
        for warning in warnings {
            let signature = RunWarningSignature(warning)
            if let group = groups[signature] {
                groups[signature] = Group(example: group.example, count: group.count + 1)
            } else {
                order.append(signature)
                groups[signature] = Group(example: warning, count: 1)
            }
        }
        return order.compactMap { groups[$0] }
    }
}

private extension RunWarningSignature {
    /// Characters a path may be followed by without their being part of it.
    static let trailingPunctuation: Set<Character> = [":", ",", ";", ".", ")", "]", "'", "\"", "`"]
    /// Characters after which a `/` opens a path rather than sitting inside a word.
    static let pathOpeners: Set<Character> = ["'", "\"", "`", "(", "["]

    /// `message` with every absolute path replaced by `…`, its trailing punctuation kept.
    ///
    /// A path opens on `/` at the message's start or after whitespace, a quote, `(` or `[`, and runs to the next whitespace, so `and/or` and `@rpath/XCTest` are not paths.
    static func elidingAbsolutePaths(_ message: String) -> String {
        var output = ""
        var rest = message[...]
        var previous: Character?
        while let character = rest.first {
            let opensPath = character == "/" && (previous.map { $0.isWhitespace || pathOpeners.contains($0) } ?? true)
            guard opensPath else {
                output.append(character)
                previous = character
                rest = rest.dropFirst()
                continue
            }
            let token = rest.prefix { !$0.isWhitespace }
            let punctuation = token.reversed().prefix { trailingPunctuation.contains($0) }
            output += "…" + String(punctuation.reversed())
            previous = token.last
            rest = rest.dropFirst(token.count)
        }
        return output
    }
}
