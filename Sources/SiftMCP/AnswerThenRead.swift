//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore

/// Pairs each in-place answer to a read of a file with a whole read of that same file the same context makes soon after, or with the identical re-run of the call it answered, which makes the answer a miss rather than a saving.
///
/// The context paid for the answer, a round trip and then the file, so the bytes the answer's closing line weighed — its source less what it served — were never spared. A whole read counts, a `Read` with no range or a shell line that prints the file whole, and so does the identical re-run the answer offers, whatever its shape, since it fetches the very lines the answer stood in for. A ranged read or a different window afterwards is the loop working.
struct AnswerThenRead {
    /// How many tool calls, from the first of the turn after an answer's own, a whole read of its file or the re-run still makes the answer a miss.
    ///
    /// Counted from that turn because the other calls of the answer's own turn went out before the context saw it.
    static let window = 5

    /// Notes one tool call: pairs it with any answer whose file it reads whole or whose call it re-runs, and holds the files it reads so an answer to it can be matched to them.
    static func noteCall(_ block: [String: Any], cwd: String?, counted: Bool, in state: inout TranscriptScanState) -> [TranscriptEvent] {
        state.toolCalls += 1
        let call = state.toolCalls
        for index in state.openAnswers.indices where state.openAnswers[index].opens == nil {
            guard state.openAnswers[index].turn == nil || state.openAnswers[index].turn != state.turn else { continue }
            state.openAnswers[index].opens = call
        }
        state.openAnswers.removeAll { $0.opens.map { call - $0 >= window } ?? false }
        state.readingCalls = state.readingCalls.filter { call - $0.value.call <= heldCalls }
        let reads = files(readBy: block, cwd: cwd)
        // What makes an answer a miss: a file this call reads whole, or the reading it re-runs.
        let readAgain = Set([
            reads.filter(\.whole).map(\.path),
            reads.map(\.reread),
        ].joined())
        var events: [TranscriptEvent] = []
        state.openAnswers.removeAll { answer in
            guard answer.opens != nil, let shape = answer.shape, let path = answer.paths.first,
                  !readAgain.isDisjoint(with: [path] + answer.rereads)
            else {
                return false
            }
            if answer.counted {
                events.append(.answerReadAnyway(shape: shape, saving: answer.saving))
            }
            return true
        }
        if let id = block["id"] as? String, !reads.isEmpty {
            state.readingCalls[id] = OpenAnswer(paths: reads.map(\.path), rereads: reads.map(\.reread), call: call, turn: state.turn, counted: counted)
        }
        return events
    }

    /// Notes one result: where it is an in-place answer, which is always an error, to a call that read files, each file its digest calls answered opens as an answer.
    static func noteResult(id: String, block: [String: Any], failed: Bool, in state: inout TranscriptScanState) -> [TranscriptEvent] {
        guard let reading = state.readingCalls.removeValue(forKey: id), failed else { return [] }
        let text = TranscriptScan.answerText(of: block).joined(separator: "\n")
        guard let opening = text.split(whereSeparator: \.isNewline).first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
              let calls = InPlaceAnswer.calls(inOpeningLine: opening)
        else {
            return []
        }
        let note = InPlaceAnswer.note(inOpeningLine: opening)
        let answered = calls.compactMap { digestTarget(of: $0) }.compactMap { target -> (path: String, shape: AnswerShape)? in
            let path = reading.paths.first { $0 == target || $0.hasSuffix("/" + target) }
                ?? (reading.paths.count == 1 && calls.count == 1 ? reading.paths.first : nil)
            guard let path else { return nil }
            let bounded = note.map { calls.count == 1 || $0.contains(target) } ?? false
            let shape: AnswerShape = bounded ? .window : IndexCallTarget.namesOnlyDocuments(target, tool: "digest") ? .outline : .digest
            return (path, shape)
        }
        guard !answered.isEmpty else { return [] }
        // One closing line prices every call on the refusal together, so each file answered is given its share of it.
        let savings = shares(of: claimedSaving(inReason: text), among: answered.map(\.path))
        var events: [TranscriptEvent] = []
        for ((path, shape), saving) in zip(answered, savings) {
            let rereads = zip(reading.paths, reading.rereads).filter { $0.0 == path }.map(\.1)
            state.openAnswers.append(
                OpenAnswer(paths: [path], rereads: rereads, call: reading.call, turn: reading.turn, counted: reading.counted, shape: shape, saving: saving)
            )
            if reading.counted {
                events.append(.fileAnswer(shape: shape, saving: saving))
            }
        }
        return events
    }

    /// The bytes an answered refusal's closing line weighs as spared — the source it states less what it served — or zero where it states no smaller size.
    ///
    /// Read back from the rounded figures the line prints, so it is as close as they are: a tenth of a kilobyte below ten, a kilobyte above.
    static func claimedSaving(inReason text: String) -> Int {
        guard let closing = text.split(whereSeparator: \.isNewline).last,
              let match = closing.firstMatch(of: #/([0-9.]+) (B|kB|MB) of source → ([0-9.]+) (B|kB|MB) served/#),
              let source = bytes(match.1, unit: match.2),
              let served = bytes(match.3, unit: match.4)
        else {
            return 0
        }
        return max(0, source - served)
    }

    /// The audit's rows for answers to reads, under `answered`: the misses by shape, and the saving that stands without them.
    static func auditLines(_ tally: AnswerMissTally, pad: (Int) -> String) -> [String] {
        guard tally.answerCount > 0 else { return [] }
        let shapes = AnswerShape.allCases.compactMap { shape -> String? in
            let answers = tally.answers[shape] ?? 0
            guard answers > 0 else { return nil }
            let misses = tally.misses[shape] ?? 0
            return "\(shape.rawValue) \(misses) of \(answers) (\(misses * 100 / answers)%)"
        }
        let withdrawn = tally.withdrawn > 0 ? ", \(TokenEstimate.short(bytes: tally.withdrawn)) the misses claimed withdrawn" : ""
        return [
            "    read anyway\(pad(tally.missCount))  of \(tally.answerCount) answers to a read, the file then read whole or the call re-run within \(window) calls — a miss, not a saving: \(shapes.joined(separator: ", "))",
            "    saving      \(TokenEstimate.saved(bytes: tally.saved)), as those answers' closing lines priced it\(withdrawn)",
        ]
    }

    /// Splits one closing line's claimed saving among the files its answer covered, in proportion to each file's size on disk where every one of them can be sized, and evenly where any cannot.
    ///
    /// An even split would let a miss on a small file withdraw as much as a large file's answer saved, since a file's source is most of what its answer stood in for.
    static func shares(of saving: Int, among paths: [String], size: (String) -> Int? = sourceSize(of:)) -> [Int] {
        guard !paths.isEmpty else { return [] }
        let sizes = paths.compactMap(size)
        let total = sizes.reduce(0, +)
        guard sizes.count == paths.count, total > 0 else { return paths.map { _ in saving / paths.count } }
        return sizes.map { Int(Double(saving) * Double($0) / Double(total)) }
    }

    /// The size in bytes of the file at `path` as it is on disk now, or `nil` where it cannot be read.
    private static func sourceSize(of path: String) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int
    }

    /// How many calls a call that read files is held for while its result is awaited — far more than one turn's calls ever are.
    private static let heldCalls = 64

    /// The files one tool call reads, each spelled out against its working directory, whether it reads each whole, and what a re-run of that reading is recognised by.
    ///
    /// The re-run is the same tool asking the same of the same file: a `Read` with its own range, or a shell statement with the reading stage the hook keys a lookup's re-run by (``ShellAdvice/lookupKey(for:holdsSource:skipping:)``), the whole statement where it draws none.
    static func files(readBy block: [String: Any], cwd: String?) -> [FileRead] {
        let input = block["input"] as? [String: Any] ?? [:]
        switch LookupTool.rule(for: block["name"] as? String ?? "") {
        case "Read":
            guard let path = LookupTool.readPath(in: input) else { return [] }
            let range = [input["offset"], input["limit"]].map { ($0 as? NSNumber).map { "\($0.intValue)" } ?? "-" }
            let resolved = InPlaceShape.resolve(path, against: cwd) ?? path
            return [FileRead(path: resolved, whole: range == ["-", "-"], reread: "Read \(resolved) \(range.joined(separator: " "))")]
        case "Bash":
            guard let command = input["command"] as? String,
                  let statements = InPlaceShape.statementDirectories(of: command, from: cwd, requiringDirectories: false)
            else {
                return []
            }
            return statements.flatMap { statement, directory -> [FileRead] in
                let key = ShellAdvice.lookupKey(for: statement, holdsSource: nil) ?? AdviceLedger.key(forShell: statement)
                let read = { (path: String, whole: Bool) -> FileRead in
                    let resolved = InPlaceShape.resolve(path, against: directory) ?? path
                    return FileRead(path: resolved, whole: whole, reread: "Bash \(resolved) \(key)")
                }
                let printed = printedWhole(by: statement)
                guard printed.isEmpty else { return printed.map { read($0, true) } }
                guard let found = InPlaceShape.call(forStatement: statement), let path = found.call.readPath else { return [] }
                return [read(path, !found.isWindow)]
            }
        default:
            return []
        }
    }

    /// The files one shell statement prints whole and alone: each file of a `cat`, of an `nl -ba`, or of a `sed -n '1,$p'`, and none for any other statement.
    ///
    /// Read here rather than by the hook's shapes, which answer a `cat` of one file only and take the other two for a window or for no lookup at all.
    private static func printedWhole(by statement: String) -> [String] {
        let stages = ShellSyntax.segments(of: statement).map(ShellQuery.init)
        guard stages.count == 1, let stage = stages.first, !stage.writesOutputToAFile, let verb = stage.invocation.first else { return [] }
        let options = stage.invocation.dropFirst().filter { $0.hasPrefix("-") }
        let printsWhole = switch verb {
        case "cat": stage.printsWholeFiles
        case "nl": options.allSatisfy { $0 == "-ba" }
        case "sed": options == ["-n"] && stage.invocation.contains("1,$p")
        default: false
        }
        return printsWhole ? stage.readPaths.filter { $0 != "1,$p" } : []
    }

    /// The target of one `digest` call as an opening line spells it, in either the tool's spelling or the CLI's, unquoted — `nil` for any other call.
    private static func digestTarget(of call: String) -> String? {
        var spelled = call.hasPrefix("sift ") ? String(call.dropFirst("sift ".count)) : call
        guard spelled.hasPrefix("digest ") else { return nil }
        spelled.removeFirst("digest ".count)
        if spelled.count >= 2, spelled.hasPrefix("'"), spelled.hasSuffix("'") {
            spelled = String(spelled.dropFirst().dropLast()).replacing(#"'\''"#, with: "'")
        }
        return spelled
    }

    /// A byte count as ``ByteSize`` prints it, read back.
    private static func bytes(_ figure: Substring, unit: Substring) -> Int? {
        guard let value = Double(figure) else { return nil }
        let scale: Double = switch unit {
        case "kB": 1000
        case "MB": 1_000_000
        default: 1
        }
        return Int((value * scale).rounded())
    }
}
