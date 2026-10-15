//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore

/// One file of a `cat` of several Swift files, weighed as a `cat` of that file alone is (``InPlaceShape/Match/weighsEachRead``).
struct WeighedRead {
    typealias ComputedCall = InPlaceAnswerer.ComputedCall

    /// One file of a `cat` of several, weighed as a `cat` of it alone is: its `digest` where that is worth the turn, which sets `paid`, and its own source otherwise, numbered as `cat -n` prints it where the `cat` asks for numbers.
    ///
    /// The source stands under the note a digest served as source carries, so the part prints what the read would have and the scan reads it as served source. A digest the floor already served as source is that source, and is served again numbered where the `cat` asks for numbers, since a `cat -n` of that file alone runs and prints them.
    static func part(
        _ digest: (call: ComputedCall, text: String),
        of path: String,
        in directory: String?,
        under terms: Terms,
        paid: inout Bool
    ) -> (calls: [ComputedCall], text: String) {
        let call = digest.call
        let floorServed = SourcePassthrough.fileVerdict(in: digest.text)?.servedSource == true
        guard !floorServed || terms.numbersLines else { return (calls: [call], text: digest.text) }
        guard floorServed || !terms.worth(call.source ?? 0, call.served) else {
            paid = true
            return (calls: [call], text: digest.text)
        }
        guard let file = OperandFile.absolute(path, in: directory),
              let source = try? String(contentsOfFile: file, encoding: .utf8),
              let text = SourcePassthrough.servingSource(
                  insteadOf: digest.text,
                  source: terms.numbersLines ? numbered(source) : source,
                  reason: floorServed ? "a digest of this file costs more than its source" : "a digest of this file is not worth the turn it costs"
              )
        else {
            return (calls: [call], text: digest.text)
        }
        var served = ComputedCall(tool: call.tool, target: call.target, served: text.utf8.count, source: call.source)
        served.fileLines = call.fileLines
        served.readBytes = call.readBytes
        return (calls: [served], text: text)
    }

    /// `source` as macOS `cat -n` prints it: each line, the last one too where no newline ends it, after its number right-aligned in six columns and a tab, counting from 1.
    static func numbered(_ source: String) -> String {
        guard !source.isEmpty else { return source }
        var lines = source.components(separatedBy: "\n")
        let ended = lines.last == ""
        if ended {
            lines.removeLast()
        }
        let numbered = lines.enumerated().map { place, line in
            let number = String(place + 1)
            return String(repeating: " ", count: max(0, 6 - number.count)) + number + "\t" + line
        }
        return numbered.joined(separator: "\n") + (ended ? "\n" : "")
    }
}

extension WeighedRead {
    /// What each file of a `cat` of several is held to: whether its digest is worth the turn, and whether the `cat` numbers its lines (``InPlaceShape/Match/numbersEachRead``).
    struct Terms: Sendable {
        /// Whether one file's whole read, of so many bytes answered with a digest of so many, is worth the turn.
        let worth: @Sendable (_ fileBytes: Int, _ digestBytes: Int) -> Bool
        /// Whether a file served as its source is numbered as `cat -n` numbers it.
        let numbersLines: Bool
    }
}
