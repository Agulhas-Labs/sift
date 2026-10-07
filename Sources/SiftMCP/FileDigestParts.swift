//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore

/// The parts a read of one Swift file is answered in place from: the file's whole digest, weighed against what the read prints, and the members each of its windows overlaps.
struct FileDigestParts {
    typealias ComputedCall = InPlaceAnswerer.ComputedCall

    /// Why a window's members stand in for a whole digest whose first page stops short of them, beside the note naming the lines shown.
    static var unreached: String {
        "the whole digest's first page stops short of some of them"
    }

    /// Why a window's members stand in for a whole digest that names some of them on their type's line alone, beside the note naming the lines shown.
    static var unplaced: String {
        "the whole digest names some of them without their lines"
    }

    /// Why a window's members stand in for a whole digest that would stand in for the window, beside the note naming the lines shown: they are strictly smaller.
    static var larger: String {
        "the whole digest is larger than they are"
    }

    /// Why a window's members stand in for the whole digest `call` serves, where that digest does not stand in for the window: a page stopping short of them first, since the page is all that is served.
    static func whyNotStandingIn(_ call: ComputedCall) -> String {
        call.reachesWindow ? unplaced : unreached
    }

    /// The digest of the file a read names, with the call that served it, weighed against the lines `windows` print where they can be read and against the file's source otherwise, or `nil` where the index does not hold that file at exactly that path.
    ///
    /// `pageSize` is the member lines of the page where the answer is cut to fit the size budget, and the page every face serves otherwise. Where the reach check is switched off the call is not asked whether the page reaches the window's members, and says it does.
    static func wholeFileDigest(
        _ path: String,
        windows: [LineWindow] = [],
        in directory: String?,
        engine: SiftEngine,
        spelling: CallSpelling,
        pageSize: Int? = nil,
        checkingReach: Bool = true
    ) throws -> (call: ComputedCall, text: String)? {
        guard let file = try OperandFile.indexed(path, in: directory, engine: engine),
              let digest = try ExactAnswer.fileDigest(in: engine, path: file.relative, spelling: spelling, pageSize: pageSize)
        else {
            return nil
        }
        let window = OperandFile.windowBytes(of: windows, in: file.lines, byteLengths: file.byteLengths)
        // A window read in form whose lines this file cannot tell — a byte count ending part way through a line —
        // prints what no digest of the file stands in for.
        guard windows.isEmpty || window != nil else { return nil }
        var call = ComputedCall(tool: "digest", target: file.relative, served: digest.text.utf8.count, source: window ?? file.bytes, weighsWindow: window != nil, fileLines: window == nil ? file.lines.count : nil)
        if window != nil, let ranges = LineWindow.ranges(of: windows, in: file.lines, byteLengths: file.byteLengths) {
            call.windowText = printedText(of: ranges, in: file.lines)
            // A digest served as the file's own source reaches every line; a paged one only as far as its first page
            // lists, and any only the members it gives a line of their own.
            let servedSource = SourcePassthrough.fileVerdict(in: digest.text)?.servedSource == true
            if checkingReach {
                call.reachesWindow = try servedSource || ExactAnswer.firstDigestPageReaches(ranges, in: engine, path: file.relative, spelling: spelling, pageSize: pageSize)
                call.placesWindow = try servedSource || ExactAnswer.digestPlacesEveryMember(ranges, in: engine, path: file.relative, spelling: spelling)
            }
        }
        return (call, digest.text)
    }

    /// The call as the file it names reads it: windows that together print every line of the file are the whole read, answered as a `cat` of it is, and any other call stands as it is.
    static func readingWhole(_ call: InPlaceCall, in directory: String?, engine: SiftEngine) throws -> InPlaceCall {
        guard case let .fileDigest(path, windows) = call, !windows.isEmpty,
              let file = try OperandFile.indexed(path, in: directory, engine: engine),
              let ranges = LineWindow.ranges(of: windows, in: file.lines, byteLengths: file.byteLengths),
              ranges == [1 ... file.lines.count]
        else {
            return call
        }
        return .fileDigest(path: path)
    }

    /// The members each window on the file at `path` overlaps, one call per distinct run of lines — named `digest F.swift:a-b` and weighed against those lines — or `nil` where there are no windows, a window's lines cannot be read, or the index does not hold that file at exactly that path.
    static func windowAnswers(_ path: String, windows: [LineWindow], in directory: String?, engine: SiftEngine, spelling: CallSpelling) throws -> [(call: ComputedCall, text: String)]? {
        guard !windows.isEmpty,
              let file = try OperandFile.indexed(path, in: directory, engine: engine),
              let ranges = LineWindow.ranges(of: windows, in: file.lines, byteLengths: file.byteLengths), !ranges.isEmpty,
              let answers = try engine.membersAnswers(overlapping: ranges, inFile: file.relative, options: DigestOptions(spelling: spelling)),
              answers.count == ranges.count
        else {
            return nil
        }
        return try zip(ranges, answers).map { range, text in
            let lines = range.count == 1 ? "\(range.lowerBound)" : "\(range.lowerBound)-\(range.upperBound)"
            let source = file.byteLengths[(range.lowerBound - 1) ..< range.upperBound].reduce(0) { $0 + $1 + 1 }
            var call = ComputedCall(tool: "digest", target: "\(file.relative):\(lines)", served: text.utf8.count, source: source, displayTarget: file.relative, weighsWindow: true)
            call.windowText = printedText(of: [range], in: file.lines)
            call.overlapsImports = try engine.overlapsImports([range], inFile: file.relative)
            return (call, text)
        }
    }

    /// The text of every non-blank line `ranges` print from `lines`, without its indentation, which an answer shows a window's lines by holding.
    private static func printedText(of ranges: [ClosedRange<Int>], in lines: [String]) -> [String] {
        ranges.flatMap { lines[($0.lowerBound - 1) ..< min($0.upperBound, lines.count)] }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
