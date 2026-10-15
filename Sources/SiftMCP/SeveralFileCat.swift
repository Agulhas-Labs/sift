//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore

/// A `cat` naming several Swift files (``InPlaceShape/multiFileReads(_:)``), held to what a `cat` of one of them is held to where the line around it asks more than a whole read of each: a `||` fallback behind it.
struct SeveralFileCat {
    /// The match for a `cat` of several Swift files in front of a `||` whose fallback could print, as ``InPlaceShape``'s fallback match is for a `cat` of one: every file read whole and weighed as a `cat` of it alone is (``InPlaceShape/Match/weighsEachRead``), standing for every statement from the lookup on, or `nil` where `lookup` names no such files or names one file twice.
    ///
    /// A `cat` exits 0 exactly where every file it names is there to read, and each file's digest is read from the file at answer time: where one is missing or cannot be opened, its digest fails and the line runs, since `cat` printed the others and failed, and the fallback ran.
    static func fallbackMatch(_ lookup: String, standingFor statements: [String], in directory: String?) -> InPlaceShape.Match? {
        guard let files = InPlaceShape.multiFileReads(lookup) else { return nil }
        let resolved = files.map { InPlaceShape.resolve($0, against: directory) ?? $0 }
        guard Set(resolved).count == resolved.count else { return nil }
        var match = InPlaceShape.Match(
            calls: files.map { .fileDigest(path: $0) },
            directory: directory,
            isWholeCommand: false,
            windowed: files.map { _ in false },
            lookups: files.count,
            fallbackFollows: true,
            statements: [statements] + files.dropFirst().map { _ in [lookup] }
        )
        match.weighsEachRead = true
        match.numbersEachRead = numbersLines(lookup)
        return match
    }

    /// The call that answers a `cat` of several Swift files piped into a line window (`cat A.swift B.swift | head`) as the window on its first file alone (`cat A.swift | head`) is answered, or `nil` where the window could print a line of any other file.
    ///
    /// Answered only where every file is there to read, so `cat` prints no error and all it prints is the files joined, the first file ends on a newline, so its last line is its own, and every window picks the same lines of the files joined as of the first file alone: a window reaching past the first file is left as it was.
    static func firstFileWindow(_ statement: String, in directory: String?) -> [(call: InPlaceCall, isWindow: Bool)]? {
        let stages = ShellSyntax.segments(of: statement)
        guard stages.count > 1, let files = InPlaceShape.multiFileReads(stages[0]),
              let first = zip(ShellQuery(stages[0]).invocation, ShellQuery(stages[0]).rawInvocation).dropFirst().first(where: { $0.0 == files[0] })
        else {
            return nil
        }
        let reading = ([ShellQuery(stages[0]).rawInvocation[0]] + (numbersLines(stages[0]) ? ["-n"] : []) + [first.1]).joined(separator: " ")
        let contents = files.map { OperandFile.readable($0, in: directory).flatMap { FileManager.default.contents(atPath: $0) } }
        guard let found = InPlaceShape.call(forStatement: ([reading] + stages.dropFirst()).joined(separator: " | ")), found.isWindow,
              case let .fileDigest(_, windows) = found.call, !windows.isEmpty, contents.allSatisfy({ $0 != nil })
        else {
            return nil
        }
        let newline = UInt8(ascii: "\n")
        let joined = contents.compactMap(\.self).reduce(Data(), +)
        guard let head = contents[0], head.last == newline else { return nil }
        let firstLines = head.count(where: { $0 == newline })
        let joinedLines = joined.count(where: { $0 == newline }) + (joined.last == newline ? 0 : 1)
        guard windows.allSatisfy({ window in window.lines(inFileOf: firstLines).map { $0 == window.lines(inFileOf: joinedLines) } == true }) else { return nil }
        return [found]
    }

    /// Whether the `cat` that `lookup` is numbers its lines: its first word after the command is `-n`, the one flag ``InPlaceShape/multiFileReads(_:)`` lets a `cat` of several files carry.
    static func numbersLines(_ lookup: String) -> Bool {
        ShellQuery(lookup).invocation.dropFirst().first == "-n"
    }
}
