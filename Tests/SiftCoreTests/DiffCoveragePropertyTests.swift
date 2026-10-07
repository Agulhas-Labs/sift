//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// `diff`'s overriding rule, tested as a property rather than by example: nothing a line diff sees change goes without a line in the answer.
///
/// Random edits — single and several, inserting, deleting and rewriting lines: comments, doc comments, `#if` lines, attributes, whitespace, line endings, code — are applied to Swift sources, and every hunk of the line diff between the two sides must meet a line the answer names. Where both sides parse cleanly, the structural pass must name every hunk itself: none may fall through to the safety net's "other changes". Every failure prints its seed, so it reproduces exactly.
struct DiffCoveragePropertyTests {
    /// A file shaped for the places a change can hide from a declaration's own text: a licence header over the first type, a type's doc comment, `// MARK:` lines, a nested type, a member under `#if`, multi-element cases and bindings, a protocol's accessor requirements, a `deinit`.
    private static var shaped: String {
        """
        //
        // Licence: example header
        //

        /// A widget.
        public struct Widget {
            /// Its count.
            public var count: Int
            let a = 1, b = 2

            /// A nested gadget.
            struct Gadget {
                // A note inside.
                var size = 0
            }

            #if DEBUG
            func trace() -> Int { count }
            #endif

            func polish() -> Int {
                // Inside a body.
                count + 1
            }
        }

        // MARK: - Levels

        /// Levels, in order.
        enum Level: Int {
            case low, high
            case middle
        }

        // MARK: - Conformances

        extension Widget: Equatable {
            static func == (lhs: Widget, rhs: Widget) -> Bool { lhs.count == rhs.count }
        }

        protocol Source {
            var value: Int { get }
            func read() -> Int
        }

        final class Holder {
            var items: [Int] = []
            deinit {
                items = []
            }
        }

        """
    }

    /// The repository's own Swift fixture, and the file above.
    private static func corpus(sourceLocation: SourceLocation = #_sourceLocation) throws -> [String] {
        let url = try #require(Bundle.module.url(forResource: "Assorted.swift", withExtension: "txt", subdirectory: "Fixtures"), sourceLocation: sourceLocation)
        return try [String(contentsOf: url, encoding: .utf8), shaped]
    }

    /// Whole lines an edit inserts, or rewrites a line into.
    private static let pool = [
        "", "    ", "\t", "// note", "    // indented note", "/// A doc line.", "    /// A member doc line.", "/* block */",
        "#if DEBUG", "#endif", "#else", "@MainActor", "    @available(macOS 13, *)", "// MARK: - Section",
        "    let extra = 1", "func added() -> Int { 3 }", "    func added() -> Int { 3 }", "import Combine", "emit(1)",
        "    case extra", "}", "struct Gadget {", "    var size = 0",
    ]

    /// One random edit, described for the failure message.
    private static func edit(_ lines: inout [String], using random: inout SplitMix) -> String {
        let index = lines.isEmpty ? 0 : Int.random(in: 0 ..< lines.count, using: &random)
        switch Int.random(in: 0 ..< 8, using: &random) {
        case 0, 1:
            let inserted = pool.randomElement(using: &random) ?? ""
            lines.insert(inserted + "\n", at: min(index, lines.count))
            return "insert \(inserted.debugDescription) at \(index + 1)"
        case 2:
            guard !lines.isEmpty else { return "nothing to delete" }
            let removed = lines.remove(at: index)
            return "delete line \(index + 1) \(removed.debugDescription)"
        case 3:
            guard !lines.isEmpty else { return "nothing to rewrite" }
            let replacement = pool.randomElement(using: &random) ?? ""
            lines[index] = replacement + "\n"
            return "rewrite line \(index + 1) as \(replacement.debugDescription)"
        case 4:
            guard !lines.isEmpty else { return "nothing to reindent" }
            lines[index] = (Bool.random(using: &random) ? "  " : "") + lines[index].drop { $0 == " " }
            return "reindent line \(index + 1)"
        case 5:
            guard !lines.isEmpty, lines[index].hasSuffix("\n"), !lines[index].hasSuffix("\r\n") else { return "no line ending to change" }
            lines[index] = String(lines[index].dropLast()) + "\r\n"
            return "CRLF on line \(index + 1)"
        case 6:
            guard !lines.isEmpty else { return "nothing to append to" }
            let line = lines[index].trimmingCharacters(in: .newlines)
            lines[index] = line + (Bool.random(using: &random) ? " // trailing" : " ") + "\n"
            return "append to line \(index + 1)"
        default:
            guard lines.count > 1 else { return "nothing to move" }
            let moved = lines.remove(at: index)
            let destination = Int.random(in: 0 ... lines.count, using: &random)
            lines.insert(moved, at: destination)
            return "move line \(index + 1) to \(destination + 1)"
        }
    }

    private static func lines(of source: String) -> [String] {
        var lines: [String] = []
        var current = ""
        for character in source {
            current.append(character)
            if character == "\n" || character == "\r\n" {
                lines.append(current)
                current = ""
            }
        }
        if !current.isEmpty {
            lines.append(current)
        }
        return lines
    }

    /// Every hunk the answer must answer for, checked against what the answer holds.
    static func check(old: Data, new: Data, seed: UInt64, edits: [String], sourceLocation: SourceLocation = #_sourceLocation) {
        let file = FileDiff.compare(path: "Sources/Lib/Widget.swift", status: .modified, lineStat: nil, bytes: (old, new))
        let oldLines = LineDiff.lines(of: old)
        let newLines = LineDiff.lines(of: new)
        let hunks = LineDiff.hunks(old: oldLines, new: newLines)
        let context = "seed \(seed): \(edits.joined(separator: "; "))"
        #expect(file.identical == (old == new), "\(context)", sourceLocation: sourceLocation)

        // Reported entries, by the lines each answers for.
        var spans: [(old: DeclarationRange?, new: DeclarationRange?)] = file.changes.flatMap { change in
            change.oldSpans.map { ($0, nil) } + change.newSpans.map { (nil, $0) }
        }
        for change in file.outside {
            let range: (OutsideDeclarations.Fragment) -> DeclarationRange = { DeclarationRange(line: $0.line, endLine: max($0.line, $0.endLine)) }
            spans += change.removed.map { (range($0), nil) } + change.added.map { (nil, range($0)) } + change.edited.map { (range($0.old), range($0.new)) }
        }
        spans += file.lineChanges.map { (old: $0.old, new: $0.new) }
        let pairs = DeclarationDiff.compare(
            old: String(data: old, encoding: .utf8).map { DiffFileSide.parse(source: $0, path: "W.swift") },
            new: String(data: new, encoding: .utf8).map { DiffFileSide.parse(source: $0, path: "W.swift") },
            hunks: hunks
        ) { _ in false }.pairs
        for hunk in hunks where !spans.contains(where: { hunk.meets(old: $0.old, new: $0.new) }) {
            // The one hunk left unnamed on purpose: lines of declarations present on both sides, byte for byte the
            // same, that a line diff happened to align as moved.
            let intact = pairs.filter { pair in
                pair.old.endLine - pair.old.line == pair.new.endLine - pair.new.line && pair.old.endLine <= oldLines.count && pair.new.endLine <= newLines.count
                    && oldLines[(pair.old.line - 1) ..< pair.old.endLine].elementsEqual(newLines[(pair.new.line - 1) ..< pair.new.endLine])
            }
            let unexplainedOld = hunk.old.filter { index in !intact.contains { $0.old.line - 1 <= index && index < $0.old.endLine } }
            let unexplainedNew = hunk.new.filter { index in !intact.contains { $0.new.line - 1 <= index && index < $0.new.endLine } }
            #expect(unexplainedOld.isEmpty && unexplainedNew.isEmpty, "\(context) — hunk \(hunk) is named nowhere in the answer", sourceLocation: sourceLocation)
        }

        // What the answer names, it prints.
        let range = DiffRange(from: "HEAD", to: .workingTree, described: "working tree vs HEAD")
        let rendered = DiffRenderer.render(DiffRenderer.Input(
            range: range,
            files: [file],
            notBrokenDown: [],
            nonSwift: [],
            callers: [],
            workingTreeIsAfterSide: true,
            tests: nil,
            options: DiffOptions(range: range),
            rawDiffBytes: 0,
            axis: .syntacticOnly
        )).body
        let unnamed = file.lineChanges.filter { $0.kind == .unnamed }
        #expect(rendered.components(separatedBy: "other changes at ").count - 1 == unnamed.count, "\(context)", sourceLocation: sourceLocation)
        if !hunks.isEmpty {
            #expect(rendered.contains("Sources/Lib/Widget.swift (modified"), "\(context)", sourceLocation: sourceLocation)
        }

        // Where both sides parse, the structural pass names every hunk itself.
        if file.parseErrorSides.isEmpty {
            #expect(unnamed.isEmpty, "\(context) — fell through to the safety net: \(unnamed)", sourceLocation: sourceLocation)
        }
    }

    /// One seed's two sides: a corpus file, and that file after one to four random edits.
    static func sample(seed: UInt64, sourceLocation: SourceLocation = #_sourceLocation) throws -> Sample {
        let corpus = try corpus(sourceLocation: sourceLocation)
        var random = SplitMix(state: seed)
        let source = corpus[Int(seed) % corpus.count]
        var lines = lines(of: source)
        var edits: [String] = []
        for _ in 0 ..< Int.random(in: 1 ... 4, using: &random) {
            edits.append(edit(&lines, using: &random))
        }
        var new = Data(lines.joined().utf8)
        if Int.random(in: 0 ..< 20, using: &random) == 0 {
            new = Data([0xEF, 0xBB, 0xBF]) + new
            edits.append("byte-order mark")
        }
        return Sample(old: Data(source.utf8), new: new, edits: edits)
    }

    @Test func everyChangedHunkIsNamedInTheAnswer() throws {
        for seed in UInt64(1) ... 240 {
            let sample = try Self.sample(seed: seed)
            Self.check(old: sample.old, new: sample.new, seed: seed, edits: sample.edits)
        }
    }
}

extension DiffCoveragePropertyTests {
    /// A deterministic generator, so a failing seed can be replayed.
    struct SplitMix: RandomNumberGenerator {
        var state: UInt64

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var value = state
            value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
            value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
            return value ^ (value >> 31)
        }
    }

    /// One seed's two sides, and the edits that made the second from the first.
    struct Sample {
        let old: Data
        let new: Data
        let edits: [String]
    }
}
