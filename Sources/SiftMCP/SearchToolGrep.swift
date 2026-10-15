//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore

/// A `Grep`'s own search, read as the grep that prints what it prints, which an in-place answer to it is weighed against (``InPlaceAnswerer``).
///
/// The tool is ripgrep behind a payload, never a command this runs: the search is made in process (``ShellGrep``), as an extended pattern over the tree the tool's path names, each line named by its path from the session's directory, as the tool prints it.
public struct SearchToolGrep: Equatable, Sendable {
    /// The search, its operand spelled from `directory` wherever it lies below it.
    let search: ShellGrep
    /// The directory the session stands in, which the operand is resolved against.
    let directory: String
    /// Whether every branch of the pattern opens on a declaration's form (``InPlaceShape/opensADeclaration(_:)``) — `enum Ends`, `func save` — and so asks where a declaration is, rather than where a name is used.
    let asksForDeclarations: Bool

    /// The most time the search may take before the answer is handed over unweighed.
    static let timeCap: TimeInterval = 0.2
    /// Bytes past the answer's own size the search is still measured to: the refusal the answer is served as adds an opening and a closing line around it, a few hundred bytes, and only a search printing more than that whole refusal leaves the answer the smaller.
    static let framingAllowance = 1024
    /// The lines the tool prints when `head_limit` is not given.
    static let defaultHeadLimit = 250
    /// The bytes of a line's text the tool prints before it stops showing it whole (`--max-columns`).
    static let columnLimit = 500

    /// The fields this reads; a call carrying any other is not weighed, since what it prints is not known here.
    private static let fields: Set<String> = ["pattern", "path", "glob", "type", "output_mode", "-n", "-i", "head_limit", "offset"]

    /// The search a `Grep` of `pattern` over `searched` makes from `directory`, or `nil` where it prints anything but matching lines, or carries a field this does not read.
    ///
    /// The tool prints at most `head_limit` lines (``defaultHeadLimit`` where none is given, all of them for 0) after skipping `offset`, none longer than ``columnLimit`` bytes of text: the search is weighed as counting just those. It numbers its lines unless `-n` says otherwise.
    init?(input: [String: Any], pattern: String, searched: String?, in directory: String?) {
        guard let directory, input["output_mode"] as? String == "content", input.keys.allSatisfy(Self.fields.contains) else { return nil }
        let type = input["type"] as? String ?? ""
        guard type.isEmpty || type == "swift" else { return nil }
        // A glob reaches here only where it picks every Swift file (`InPlaceShape.match(forSearchTool:input:in:)`).
        let swiftOnly = type == "swift" || !(input["glob"] as? String ?? "").isEmpty
        let numbers = input["-n"] as? Bool ?? (input["-n"] as? String).map { $0 != "false" } ?? true
        let base = directory.count > 1 && directory.hasSuffix("/") ? String(directory.dropLast()) : directory
        let operand = switch searched {
        case nil, base?: "."
        case let path? where path.hasPrefix(base + "/"): String(path.dropFirst(base.count + 1))
        case let path?: path
        }
        let arguments = ["-r", "-E"] + (numbers ? ["-n"] : []) + (swiftOnly ? ["--include=*.swift"] : []) + ["--", pattern, operand]
        guard var search = ShellGrep(arguments: arguments) else { return nil }
        let limit = Self.count(input["head_limit"]) ?? Self.defaultHeadLimit
        let offset = Self.count(input["offset"]) ?? 0
        // The sums saturate: a `head_limit` or `offset` near `Int.max` must not trap the hook.
        let first = offset == .max ? Int.max : offset + 1
        let sum = offset.addingReportingOverflow(limit)
        let last = sum.overflow ? Int.max : sum.partialValue
        if limit > 0 {
            search.outputWindow = offset == 0 ? .head(limit) : .window(first ... last)
        } else if offset > 0 {
            search.outputWindow = .window(first ... Int.max)
        }
        search.columnLimit = Self.columnLimit
        self.search = search
        self.directory = base
        asksForDeclarations = pattern.split(separator: /\\?\|/).allSatisfy {
            InPlaceShape.opensADeclaration(String($0).trimmingCharacters(in: CharacterSet(charactersIn: " ()")))
        }
    }

    /// A non-negative count a field holds, as a number or as the text of one.
    private static func count(_ value: Any?) -> Int? {
        let number = value as? Int ?? (value as? String).flatMap { Int($0) }
        return number.flatMap { $0 >= 0 ? $0 : nil }
    }

    /// What an answer naming `names` is weighed against: the bytes the search prints where size decides what it asks — a declaration, or names each declared once — and `nil` for a bare name declared more than once, which asks which declaration each use resolves to, which only the answer says.
    func weight(answering names: [String], in engine: SiftEngine, answerBytes: Int, deadline: InPlaceDeadline) throws -> Weight {
        guard asksForDeclarations else {
            guard try names.allSatisfy({ try ExactAnswer.declarationCount(in: engine, of: $0) == 1 }) else { return .printed(nil) }
            return .printed(printedBytes(answerBytes: answerBytes, deadline: deadline))
        }
        let measured = measured(answerBytes: answerBytes, deadline: deadline)
        return measured.outcome == .undecided("time") ? .outOfTime : .printed(Self.bytes(of: measured))
    }

    /// The bytes the search prints, or `nil` where that cannot be worked out by `deadline`'s ``timeCap`` — undecided, past its limits, or printing more than `answerBytes`, the answer's own size, by over ``framingAllowance``, beyond which the refusal is the smaller — and the answer is handed over unweighed.
    ///
    /// The walk reads the `.gitignore` files above the searched directory too (``ShellGrep/IgnoreScope/withParents``), as ripgrep does.
    func printedBytes(answerBytes: Int, deadline: InPlaceDeadline) -> Int? {
        Self.bytes(of: measured(answerBytes: answerBytes, deadline: deadline))
    }

    private func measured(answerBytes: Int, deadline: InPlaceDeadline) -> (outcome: ShellGrep.Outcome, bytes: Int) {
        let ceiling = ShellGrep.Ceiling(admits: { _ in true }, cost: { _, _ in 0 }, budget: 0, printLimit: answerBytes > Int.max - Self.framingAllowance ? Int.max : answerBytes + Self.framingAllowance)
        return search.measured(in: directory, ceiling: ceiling, skipsCache: true, stopsAt: deadline.instant(after: Self.timeCap), ignoreScope: .withParents)
    }

    private static func bytes(of measured: (outcome: ShellGrep.Outcome, bytes: Int)) -> Int? {
        guard case .printed = measured.outcome else { return nil }
        return measured.bytes
    }
}

extension SearchToolGrep {
    /// What an answer naming `names` is weighed against.
    enum Weight: Equatable {
        /// The bytes the search prints, or `nil` where the answer is handed over unweighed (``printedBytes(answerBytes:deadline:)``).
        case printed(Int?)
        /// A declaration search the time cap stopped: in every paired benchmark run on record, each declaration search an answer stood in for printed less than it (`enum Ends`, 187 bytes against 2,110), and a cold page cache is what runs the cap out, so the search runs rather than the answer being handed over unweighed.
        case outOfTime

        /// The bytes weighed, or `nil` where none were.
        var bytes: Int? {
            if case let .printed(bytes) = self {
                bytes
            } else {
                nil
            }
        }
    }
}
