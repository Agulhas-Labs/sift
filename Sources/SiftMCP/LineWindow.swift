//
// Copyright © Agulhas Labs
//

import Foundation

/// The lines a window on one file prints, kept as the argv of each stage that picks them and read off against the file's length only when they are needed.
///
/// A `head`, a `tail`, a numeric `sed -n` and an `awk` program picking lines by number are read; a `cat`, `less` or `more` passes its lines on; a `head -c` reading the file itself is read to the lines its bytes print, where they end on a line's end. Anything else — a flag this does not model — reads as no window at all, and the lookup keeps the whole digest alone wherever it is answered; a shell window is answered only where every stage is proven to run only to print (`InPlaceShape`).
public struct LineWindow: Equatable, Sendable {
    /// Each stage's argv, in pipeline order: the first reads the file, every later one is handed what the one before it printed.
    public let stages: [[String]]

    public init(stages: [[String]]) {
        self.stages = stages
    }

    /// The most lines a `Read` prints where it is given no `limit`.
    public static let readDefaultLimit = 2000

    /// The window a `Read` with `offset`/`limit` is: `limit` lines from line `offset`, ``readDefaultLimit`` where no limit is given.
    public init(offset: Int?, limit: Int?) {
        self.init(stages: [["tail", "-n", "+\(max(offset ?? 1, 1))"], ["head", "-n", "\(limit ?? Self.readDefaultLimit)"]])
    }

    /// The lines the window prints of a file of `count` lines whose bytes are not known, in ascending order, or `nil` where a stage cannot be read without them — a byte count among them.
    public func lines(inFileOf count: Int) -> [Int]? {
        lines(inFileOf: count, bytes: nil)
    }

    /// The lines the window prints of the file whose lines are `fileLines`, each without its newline, in ascending order, or `nil` where a stage cannot be read.
    ///
    /// A byte count that ends part way through a line is not read: it prints part of a line, which no line window stands for. `byteLengths`, each line's true width on disk with its newline not counted, models a `head -c` boundary; where it is not given, each line's own `utf8.count` stands in for it.
    public func lines(in fileLines: [String], byteLengths: [Int]? = nil) -> [Int]? {
        lines(inFileOf: fileLines.count, bytes: (byteLengths ?? fileLines.map(\.utf8.count)).map { $0 + 1 })
    }

    /// Whether every stage is one this reads, so the lines can be worked out once the file's lines are known.
    public var isReadable: Bool {
        lines(in: []) != nil
    }

    /// The lines the window prints of a file of `count` lines, whose bytes, each line's newline included, are `bytes` where they are known.
    private func lines(inFileOf count: Int, bytes: [Int]?) -> [Int]? {
        var handed = Array(stride(from: 1, through: count, by: 1))
        for (index, stage) in stages.enumerated() {
            guard let kept = Self.pick(stage, from: handed, bytes: index == 0 ? bytes : nil) else { return nil }
            handed = kept
        }
        return Array(Set(handed)).sorted()
    }

    /// Whether any stage carries an option after its first operand, which makes the command no window at all (``placesAnOptionAfterAnOperand(_:)``).
    var placesAnOptionAfterAnOperand: Bool {
        stages.contains(where: Self.placesAnOptionAfterAnOperand)
    }

    /// Whether any `head`/`tail` stage carries a count written in digits the system binary cannot parse (``hasIllegalCount(_:)``), which makes the command no window at all: BSD `head`/`tail` exits 1 on such a count and prints nothing, so no digest stands in for it.
    var hasIllegalCount: Bool {
        stages.contains(where: Self.hasIllegalCount)
    }

    /// Every window's lines of the file whose lines are `fileLines`, joined into the fewest runs of consecutive lines, or `nil` where any window cannot be read.
    ///
    /// `byteLengths`, each line's true width on disk, is passed through to ``lines(in:byteLengths:)``.
    public static func ranges(of windows: [Self], in fileLines: [String], byteLengths: [Int]? = nil) -> [ClosedRange<Int>]? {
        var lines = Set<Int>()
        for window in windows {
            guard let picked = window.lines(in: fileLines, byteLengths: byteLengths) else { return nil }
            lines.formUnion(picked)
        }
        var runs: [ClosedRange<Int>] = []
        for line in lines.sorted() {
            if let last = runs.last, last.upperBound + 1 == line {
                runs[runs.count - 1] = last.lowerBound ... line
            } else {
                runs.append(line ... line)
            }
        }
        return runs
    }

    /// What one stage keeps of the lines handed to it, or `nil` where the stage is not one this reads.
    ///
    /// `bytes` are the file's line lengths, newline included, handed only to the stage that reads the file: what a later stage is handed may carry text of an earlier stage's own — `cat -n` numbers its lines — so a byte count is read only where the bytes are the file's.
    private static func pick(_ stage: [String], from handed: [Int], bytes: [Int]?) -> [Int]? {
        guard let verb = stage.first.map({ URL(fileURLWithPath: $0).lastPathComponent }), !placesAnOptionAfterAnOperand(stage) else { return nil }
        let arguments = stage.dropFirst().filter { !$0.hasPrefix("2>") }
        switch verb {
        case "cat", "less", "more":
            return arguments.allSatisfy { !$0.hasPrefix("-") || $0 == "-n" } ? handed : nil
        case "nl":
            // `nl -ba` numbers every line and drops none, as `cat -n` does; any other option may not.
            guard arguments.first == "-ba" else { return nil }
            return arguments.dropFirst().allSatisfy { !$0.hasPrefix("-") } ? handed : nil
        case "head" where byteCount(arguments) != nil:
            guard let bytes, let count = byteCount(arguments) else { return nil }
            return linesWhole(handed, printedBy: count, of: bytes)
        case "head", "tail":
            guard !hasIllegalCount(arguments), let count = lineCount(arguments) else { return nil }
            switch (verb, count) {
            case let ("head", .lines(lines)): return Array(handed.prefix(lines))
            case let ("tail", .lines(lines)): return Array(handed.suffix(lines))
            case let ("tail", .fromLine(line)): return Array(handed.dropFirst(line - 1))
            default: return nil
            }
        case "sed":
            return sedScripts(arguments).map { scripts in picked(handed) { sedPrints(scripts, position: $0, of: handed.count) } }
        case "awk":
            // A program that prints every line passes its lines on, as a `cat -n` does — only where it stands
            // alone: an option before it or a `VAR=value` operand beside it changes what prints.
            if arguments.count <= 2, let program = arguments.first,
               !arguments.dropFirst().contains(where: { $0.hasPrefix("-") || $0.prefixMatch(of: ShellQuery.assignment) != nil }),
               ShellQuery.printsEveryLine(awkProgram: program)
            {
                return handed
            }
            return awkProgram(arguments).flatMap { program in awkPicks(program, from: handed) }
        default:
            return nil
        }
    }

    /// Whether `stage` carries an option after its first operand — `head F -n 20`, `sed -n 1,5p F -n`, `cat F -n`.
    ///
    /// The system `head`, `tail`, `sed`, `cat` and `awk` stop reading options at the first word that is not one, a `sed` script or an `awk` program included, so every later word that looks like an option is one more file to open: the command prints part of what it was asked for, or none of it, and exits 1. Such a stage is no window at all, and nothing reads it as one. A `--` ends the options too, and a verb not listed here is never judged by this.
    static func placesAnOptionAfterAnOperand(_ stage: [String]) -> Bool {
        guard let verb = stage.first.map({ URL(fileURLWithPath: $0).lastPathComponent }), let valued = optionsTakingAValue[verb] else { return false }
        var optionsEnded = false
        var takesValue = false
        for word in stage.dropFirst() where !word.hasPrefix("2>") {
            if optionsEnded {
                if word.hasPrefix("-") || word.hasPrefix("+") {
                    return true
                }
            } else if takesValue {
                takesValue = false
            } else if valued.contains(word) {
                takesValue = true
            } else if word == "--" || word == "-" || !word.hasPrefix("-") {
                optionsEnded = true
            }
        }
        return false
    }

    /// The options each verb ``placesAnOptionAfterAnOperand(_:)`` judges reads its value from the word after it, which is neither an option nor an operand.
    private static let optionsTakingAValue: [String: Set<String>] = [
        "cat": [],
        "head": ["-n", "--lines", "-c", "--bytes"],
        "tail": ["-n", "--lines", "-c", "--bytes", "-b"],
        "sed": ["-e", "--expression", "-f", "--file", "-l"],
        "awk": ["-F", "-v", "-f"],
    ]

    /// The lines the first `count` bytes of a file print, where they end on a line's end or at the file's, or `nil` where they end part way through a line.
    ///
    /// A line printed in part is priced by the members answering a window at bytes the command never printed, so the answer's weighing against the window would not be exact: such a window is not read.
    private static func linesWhole(_ handed: [Int], printedBy count: Int, of bytes: [Int]) -> [Int]? {
        var printed = 0
        var kept: [Int] = []
        for line in handed where printed < count {
            printed += bytes[line - 1]
            kept.append(line)
        }
        return printed <= count ? kept : nil
    }

    /// The count of bytes a `head` keeps where a byte count is its one option — `-c 300`, `-c300` — a whole number from 1, or `nil` for any other `head`.
    static func byteCount(_ arguments: [String]) -> Int? {
        var count: Int?
        var index = arguments.startIndex
        while index < arguments.endIndex {
            let word = arguments[index]
            var value: String?
            if word == "-c" {
                index += 1
                guard index < arguments.endIndex else { return nil }
                value = arguments[index]
            } else if word.hasPrefix("-c") {
                value = String(word.dropFirst(2))
            } else if word.hasPrefix("-") {
                return nil
            }
            if let value {
                guard count == nil, !value.isEmpty, value.allSatisfy({ $0.isASCII && $0.isNumber }), let bytes = Int(value), bytes >= 1 else { return nil }
                count = bytes
            }
            index += 1
        }
        return count
    }

    /// The elements of `handed` whose 1-based position `keeps` holds of.
    private static func picked(_ handed: [Int], keeping keeps: (Int) -> Bool) -> [Int] {
        handed.enumerated().filter { keeps($0.offset + 1) }.map(\.element)
    }

    /// Whether a `head`/`tail` stage's count is written in Unicode digits that look like a number and are not ASCII — `head -n ٣`, which the system binary reads as an illegal count and refuses, printing nothing, rather than in the ten lines a count it does not recognise at all leaves it to print.
    ///
    /// Read off the same words ``lineCount(_:)`` reads its value from, but for what that function already reads as `nil`: `Int(_:)` never parses a non-ASCII digit, so an illegal count and a flag this does not model both fail it alike, and only this tells the two apart.
    private static func hasIllegalCount(_ arguments: [String]) -> Bool {
        var index = arguments.startIndex
        while index < arguments.endIndex {
            let word = arguments[index]
            var value: String?
            if word == "-n" || word == "--lines" {
                index += 1
                guard index < arguments.endIndex else { return false }
                value = arguments[index]
            } else if word.hasPrefix("--lines=") {
                value = String(word.dropFirst("--lines=".count))
            } else if word.hasPrefix("-n") {
                value = String(word.dropFirst(2))
            } else if word.hasPrefix("-") || word.hasPrefix("+") {
                value = word.hasPrefix("-") ? String(word.dropFirst()) : word
            }
            if let value, !value.isEmpty, value.allSatisfy(\.isNumber), !value.allSatisfy(\.isASCII) {
                return true
            }
            index += 1
        }
        return false
    }

    /// The count a `head` or `tail` is given — `-20`, `-n 20`, `-n20`, `--lines=20`, or `+20` for a `tail` from a line — ten where none is, or `nil` for any other flag.
    private static func lineCount(_ arguments: [String]) -> LineCount? {
        var count = LineCount.lines(10)
        var index = arguments.startIndex
        while index < arguments.endIndex {
            let word = arguments[index]
            var value: String?
            if word == "-n" || word == "--lines" {
                index += 1
                guard index < arguments.endIndex else { return nil }
                value = arguments[index]
            } else if word.hasPrefix("--lines=") {
                value = String(word.dropFirst("--lines=".count))
            } else if word.hasPrefix("-n") {
                value = String(word.dropFirst(2))
            } else if word.hasPrefix("-") || word.hasPrefix("+") {
                value = word.hasPrefix("-") ? String(word.dropFirst()) : word
            }
            if let value {
                guard let read = LineCount(value) else { return nil }
                count = read
            }
            index += 1
        }
        return count
    }

    /// A `sed -n` invocation's print scripts, split at `;`, or `nil` where it carries anything but `-n`, scripts and files.
    private static func sedScripts(_ arguments: [String]) -> [String]? {
        var scripts: [String] = []
        var quiet = false
        var index = arguments.startIndex
        while index < arguments.endIndex {
            let word = arguments[index]
            if word == "-n" || word == "--quiet" || word == "--silent" {
                quiet = true
            } else if word == "-E" || word == "-r" {
                // Extended expressions change how a pattern reads, never which numbered line prints.
            } else if word == "-e" || word == "--expression" {
                index += 1
                guard index < arguments.endIndex else { return nil }
                scripts.append(arguments[index])
            } else if word.hasPrefix("-") {
                return nil
            } else if word.wholeMatch(of: ShellQuery.sedWindow) != nil {
                scripts.append(word)
            }
            index += 1
        }
        guard quiet, !scripts.isEmpty else { return nil }
        return scripts.flatMap { $0.split(separator: ";").map(String.init) }
    }

    /// Whether any of the print scripts prints the line at `position` of the `total` handed to `sed`.
    private static func sedPrints(_ scripts: [String], position: Int, of total: Int) -> Bool {
        scripts.contains { script in
            let bounds = script.dropLast().split(separator: ",", maxSplits: 1).map(String.init)
            guard let start = bounds.first.flatMap({ Int($0) }) else { return false }
            guard bounds.count == 2 else { return position == start }
            let end: Int = switch bounds[1] {
            case "$": total
            case let relative where relative.hasPrefix("+"): start + (Int(relative.dropFirst()) ?? 0)
            default: max(Int(bounds[1]) ?? start, start)
            }
            return (start ... end).contains(position)
        }
    }

    /// An `awk` invocation's program, where it is the numeric window ``ShellQuery`` reads as one and nothing but a field separator rides beside it.
    private static func awkProgram(_ arguments: [String]) -> String? {
        var program: String?
        var index = arguments.startIndex
        while index < arguments.endIndex {
            let word = arguments[index]
            if word == "-F" {
                index += 1
            } else if word.hasPrefix("-F") {
                // The separator decides the fields, never which lines print.
            } else if word.hasPrefix("-") {
                return nil
            } else if program == nil {
                guard word.wholeMatch(of: ShellQuery.awkWindow) != nil else { return nil }
                program = word
            }
            index += 1
        }
        return program
    }

    /// The lines an `awk` window program prints: one comparison of `NR`, two joined by `&&`, or a range pattern `first, second` that prints from a line the first holds of through the next the second holds of.
    private static func awkPicks(_ program: String, from handed: [Int]) -> [Int]? {
        let pattern = program.split(separator: "{", maxSplits: 1).first.map(String.init) ?? program
        let comparisons = pattern.matches(of: /NR\s*(==|>=|<=|>|<)\s*([0-9]+)/).compactMap { match -> ((Int) -> Bool)? in
            guard let value = Int(match.output.2) else { return nil }
            return switch match.output.1 {
            case "==": { $0 == value }
            case ">=": { $0 >= value }
            case "<=": { $0 <= value }
            case ">": { $0 > value }
            default: { $0 < value }
            }
        }
        guard let first = comparisons.first else { return nil }
        guard comparisons.count == 2 else { return picked(handed, keeping: first) }
        let second = comparisons[1]
        guard pattern.contains(",") else { return picked(handed) { first($0) && second($0) } }
        var inside = false
        return picked(handed) { position in
            if !inside, first(position) {
                inside = true
            }
            guard inside else { return false }
            if second(position) {
                inside = false
            }
            return true
        }
    }
}
