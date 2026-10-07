//
// Copyright © Agulhas Labs
//

import Foundation

/// One reading of a shell lookup the advice hook could answer in place: the ledger keys an answer to it is recorded under, and the names its calls carry.
///
/// The hook tries a compound line's own reading first and its ordinary reading after (``InPlaceAnswerer/firstAnswered(_:timeBudget:by:)``), and records an answer under the lookups the served reading stands for. The transcript scan sees only the answer, so it holds both readings and settles on the one the answer's opening line spells, and both ends draw the keys here.
public struct ServedReading: Sendable, Equatable, Codable {
    /// The ledger keys an answer to this reading is recorded under, one per lookup among the statements its calls stand for.
    var keys: [String]
    /// The file and symbol names this reading's calls carry, each of which an answer to it spells in its opening line.
    var names: [String]

    /// The in-place match the hook reads `command` as, every lookup whose key is in `sanctioned` riding along.
    public static func match(forShell command: String, in directory: String?, holdsSource: ((String) -> Bool)?, skipping sanctioned: Set<String>) -> InPlaceShape.Match? {
        InPlaceShape.match(forShell: command, in: directory) {
            !sanctioned.isEmpty && ShellAdvice.lookupKey(for: $0, holdsSource: holdsSource).map(sanctioned.contains) == true
        }
    }

    /// The ledger key of every statement `match` or its ordinary reading answers, drawn by `key`, for those that are lookups.
    public static func statementKeys(of match: InPlaceShape.Match?, by key: (String) -> String?) -> [String: String] {
        let readings: [InPlaceShape.Match] = [match, match?.ordinary].compactMap(\.self)
        var keys: [String: String] = [:]
        for statement in readings.flatMap({ $0.statements.flatMap(\.self) }) where keys[statement] == nil {
            keys[statement] = key(statement)
        }
        return keys
    }

    /// The keys of every statement `match`'s calls answered (``InPlaceShape/Match/statements``), in command order, among `statementKeys` — empty where it answered no lookup that is a shell statement.
    ///
    /// A lookup the answer dropped is not among them: its re-run is not the identical re-run of anything served.
    public static func keys(answeredBy match: InPlaceShape.Match, among statementKeys: [String: String]) -> [String] {
        var keys: [String] = []
        for statement in match.statements.joined() {
            if let found = statementKeys[statement], !keys.contains(found) {
                keys.append(found)
            }
        }
        return keys
    }

    /// `match` and its ordinary reading, in the order the hook tries them, each keyed by `key`.
    static func readings(of match: InPlaceShape.Match?, keyedBy key: (String) -> String?) -> [Self] {
        let statementKeys = statementKeys(of: match, by: key)
        return [match, match?.ordinary].compactMap(\.self).map { reading in
            Self(keys: keys(answeredBy: reading, among: statementKeys), names: reading.calls.flatMap(names(of:)))
        }
    }

    /// The keys the answer whose opening line names `calls`, with `note` beside them, is recorded under: those of the first of `readings` whose every name that line spells, empty where there are no readings to choose from, and `nil` where none is spelled.
    ///
    /// An answer none of the readings spells served none of the lookups they stand for, so it is remembered under none of them rather than under a guessed one.
    static func keys(servedBy calls: [String], note: String?, among readings: [Self]) -> [String]? {
        guard !readings.isEmpty else { return [] }
        let line = (calls + [note ?? ""]).joined(separator: " ")
        return readings.first { $0.names.allSatisfy { spelled(in: line, name: $0) } }?.keys
    }

    /// Whether `line` spells `name` as a run of consecutive words: `name` appears in it verbatim, set apart from whatever comes before and after by a separator that also sets one name apart from the next.
    ///
    /// A name of several words (a spaced path) must appear joined by the same spaces it was written with — a path whose components a `/` joins instead, such as `Sources/My/A.swift`, does not spell the name `My A.swift` just because both of its words appear in it.
    private static func spelled(in line: String, name: String) -> Bool {
        guard !name.isEmpty else { return true }
        let boundary = " /(),;:`'\""
        var searchStart = line.startIndex
        while let range = line.range(of: name, range: searchStart ..< line.endIndex) {
            let before = range.lowerBound == line.startIndex || boundary.contains(line[line.index(before: range.lowerBound)])
            let after = range.upperBound == line.endIndex || boundary.contains(line[range.upperBound])
            if before, after {
                return true
            }
            searchStart = line.index(after: range.lowerBound)
        }
        return false
    }

    /// The names an answer to `call` spells in its opening line: the file a digest names, or the names a `where` asks about.
    ///
    /// A member's source is spelled by the member's own name, which the command never wrote, so those calls carry none.
    private static func names(of call: InPlaceCall) -> [String] {
        switch call {
        case let .fileDigest(path, _), let .documentOutline(path), let .declarations(path, _):
            [(path as NSString).lastPathComponent]
        case let .references(name, _):
            [name]
        case let .symbols(names, _, _, _, _):
            names
        case .members, .memberRange:
            []
        }
    }
}
