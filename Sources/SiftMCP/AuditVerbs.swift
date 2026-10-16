//
// Copyright © Agulhas Labs
//

import Foundation

/// `sift audit --verbs`: what the answers sift gave cost, by kind of answer, and what the context did next.
///
/// Every other view of the audit counts the lookups sift missed. This one prices the lookups it served: one row per kind of answer (the verb and the arguments that change its shape, as the CLI spells them), its calls, its size, its price by the benchmark's rule, and the share of its calls each kind of next call followed. It names nothing in the tree, so there is nothing to redact.
public struct AuditVerbs {}

extension AuditVerbs {
    /// What the context's first call of a later request did with an answer.
    enum Next: Int, CaseIterable {
        case read, grep, sift, other, none

        var title: String {
            switch self {
            case .read: "read"
            case .grep: "grep"
            case .sift: "sift"
            case .other: "other"
            case .none: "none"
            }
        }
    }

    /// One answer: the kind it is rowed under, its size, and what the transcript shows of its price and its next call.
    struct Answer: Equatable {
        var kind: String
        var characters: Int
        /// The requests the context had made when the answer arrived, which is the index of the first request to read it.
        var requestsBefore: Int
        var next: Next = .none
        let message: String
        let words: [String]
        var command: String?
        /// Held until the answer is classified, then released.
        var text: String

        /// The answer's price in tokens in a context of `requests` requests: its characters ÷ 3, each costing 1.25 for the request that first read it and 0.1 for each later one; nothing where no request read it.
        func price(requests: Int) -> Double {
            guard requests > requestsBefore else { return 0 }
            return Double(characters) / 3 * (1.25 + 0.1 * Double(requests - 1 - requestsBefore))
        }
    }

    /// The call an answer answers: the kind it is rowed under and the words of its target.
    struct Call: Equatable {
        let kind: String
        let words: [String]
        /// For `run`, `test` and `build`: the wrapped command after `--`, else the verb's own arguments, whitespace-normalised; nil for every other call.
        var command: String?

        /// The first word of the kind: the verb or tool.
        var verb: String {
            String(kind.prefix { $0 != " " })
        }
    }

    /// A context's answers, priced.
    struct Context {
        var answers: [Answer] = []
        var requests = 0
        var isSubagent = false
        var session = ""
    }

    /// One row of the table.
    struct Row {
        let kind: String
        var calls = 0
        var characters: [Int] = []
        var price = 0.0
        var nexts: [Next: Int] = [:]
    }
}

extension AuditVerbs {
    /// The report over `snapshot` (already narrowed to the audit's scope): a header line and one aligned table.
    public static func report(snapshot: TranscriptSnapshot, since: Date?, until: Date?, window: String) -> String {
        var contexts: [Context] = []
        for session in snapshot.sessions {
            for url in [session] + snapshot.subagents(of: session) {
                let context = scan(url, snapshot: snapshot, since: since, until: until)
                if !context.answers.isEmpty {
                    contexts.append(context)
                }
            }
        }
        return render(contexts, window: window)
    }

    static func render(_ contexts: [Context], window: String) -> String {
        var rows: [String: Row] = [:]
        var total = 0.0
        var answers = 0
        for context in contexts {
            for answer in context.answers {
                let price = answer.price(requests: context.requests)
                var row = rows[answer.kind] ?? Row(kind: answer.kind)
                row.calls += 1
                row.characters.append(answer.characters)
                row.price += price
                row.nexts[answer.next, default: 0] += 1
                rows[answer.kind] = row
                total += price
                answers += 1
            }
        }
        let sessions = Set(contexts.map(\.session)).count
        let count = SessionCount(sessions: sessions, subagents: contexts.count { $0.isSubagent })
        let header = "audit --verbs: \(answers) answer\(answers == 1 ? "" : "s") in \(count.spelled), \(window); price: characters ÷ 3 in tokens, each 1.25 for the request that first read it and 0.1 for every later one in its context, nothing if none did"
        guard answers > 0 else { return header + "\nno answers from sift in the window." }
        let ordered = rows.values.sorted { ($1.price, $1.calls, $0.kind) < ($0.price, $0.calls, $1.kind) }
        var table = [["kind", "calls", "median", "p90", "price", "share"] + Next.allCases.map(\.title)]
        for row in ordered {
            let sizes = row.characters.sorted()
            table.append([
                row.kind, "\(row.calls)", "\(percentile(sizes, 0.5))", "\(percentile(sizes, 0.9))", tokens(row.price),
                total > 0 ? String(format: "%.1f%%", row.price / total * 100) : "0.0%",
            ] + Next.allCases.map { String(format: "%.0f%%", Double(row.nexts[$0] ?? 0) / Double(row.calls) * 100) })
        }
        return header + "\n" + align(table)
    }

    private static func percentile(_ sorted: [Int], _ fraction: Double) -> Int {
        guard !sorted.isEmpty else { return 0 }
        return sorted[max(0, Int((fraction * Double(sorted.count)).rounded(.up)) - 1)]
    }

    private static func tokens(_ value: Double) -> String {
        value < 1000 ? String(format: "%.0f", value) : String(format: "%.1fk", value / 1000)
    }

    /// `rows` as left-aligned columns, the kind left and every figure right.
    private static func align(_ rows: [[String]]) -> String {
        let widths = (0 ..< rows[0].count).map { column in rows.map { $0[column].count }.max() ?? 0 }
        return rows.map { row in
            row.enumerated().map { column, cell in
                let pad = String(repeating: " ", count: widths[column] - cell.count)
                return column == 0 ? cell + pad : pad + cell
            }.joined(separator: "  ")
        }.joined(separator: "\n")
    }

    // MARK: - The scan of one context
}

extension AuditVerbs {
    private struct PendingCall {
        let name: String
        let input: [String: Any]
        let message: String
        let reported: Bool
    }

    private static let apiRequestPrefix = Data(#"{"type":"api-request"#.utf8)
    private static let readMarkers = [#""type":"assistant""#, #""type": "assistant""#, #""tool_result""#].map { Data($0.utf8) }

    /// Whether a line could be an assistant message or carry a tool result, decided on raw bytes before anything parses it.
    private static func mayRead(_ line: Data) -> Bool {
        line.count > 2 && !line.starts(with: apiRequestPrefix) && readMarkers.contains { line.range(of: $0) != nil }
    }

    /// One transcript read a line at a time: its requests, its answers, and the first call of a later request after each.
    static func scan(_ url: URL, snapshot: TranscriptSnapshot, since: Date?, until: Date?) -> Context {
        var context = Context()
        if let identity = SubagentFile.identity(of: url, home: NSHomeDirectory()) {
            context.isSubagent = true
            context.session = identity.session
        } else {
            context.session = url.path
        }
        guard let lines = snapshot.lines(of: url) else { return context }
        var requestIds: Set<String> = []
        var calls: [String: PendingCall] = [:]
        var awaiting: [Int] = []
        var lineNumber = 0
        for line in lines {
            lineNumber += 1
            guard mayRead(line), let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let type = object["type"] as? String, type == "assistant" || type == "user",
                  let message = object["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]]
            else { continue }
            if type == "assistant" {
                let identifier = message["id"] as? String
                if message["usage"] != nil, let identifier, requestIds.insert(identifier).inserted {
                    context.requests += 1
                }
                let key = identifier ?? "line-\(lineNumber)"
                let stamp = (object["timestamp"] as? String).flatMap(TranscriptScan.instant)
                let reported = (since.map { start in stamp.map { $0 >= start } ?? true } ?? true)
                    && (until.map { end in stamp.map { $0 < end } ?? true } ?? true)
                for block in content where block["type"] as? String == "tool_use" {
                    guard let id = block["id"] as? String else { continue }
                    let name = block["name"] as? String ?? ""
                    let input = block["input"] as? [String: Any] ?? [:]
                    awaiting.removeAll { index in
                        guard context.answers[index].message != key else { return false }
                        context.answers[index].next = classify(name: name, input: input, answer: context.answers[index])
                        context.answers[index].text = ""
                        return true
                    }
                    calls[id] = PendingCall(name: name, input: input, message: key, reported: reported)
                }
            } else {
                for block in content where block["type"] as? String == "tool_result" {
                    guard let id = block["tool_use_id"] as? String, let call = calls.removeValue(forKey: id), call.reported else { continue }
                    let text = TranscriptScan.answerText(of: block).joined(separator: "\n")
                    let refused = block["is_error"] as? Bool == true
                    guard let answered = self.call(name: call.name, input: call.input, answerText: text, refused: refused) else { continue }
                    context.answers.append(Answer(
                        kind: answered.kind, characters: text.count, requestsBefore: context.requests,
                        message: call.message, words: answered.words, command: answered.command, text: text
                    ))
                    awaiting.append(context.answers.count - 1)
                }
            }
        }
        for index in awaiting {
            context.answers[index].text = ""
        }
        return context
    }

    // MARK: - Kinds

    /// The call a result answers: a sift call by either face, or a `Read`, `Grep` or Bash line the hook refused in place of (an error result of one of those three), rowed under the first call its opening line names with `(hook)`.
    static func call(name: String, input: [String: Any], answerText text: String, refused: Bool) -> Call? {
        if let tool = IndexToolName.tool(named: name) {
            return mcpCall(tool: tool, input: input)
        }
        if name == "Bash", let command = input["command"] as? String, let cli = cliCall(command) {
            return cli
        }
        guard refused, ["Read", "Grep", "Bash"].contains(name),
              let opening = text.split(whereSeparator: \.isNewline).first(where: { !$0.allSatisfy(\.isWhitespace) }),
              let first = InPlaceAnswer.calls(inOpeningLine: opening)?.first
        else { return nil }
        var spelled = first
        var refs = false
        for suffix in [InPlaceAnswer.referencesFlag, InPlaceAnswer.referencesArgument] where spelled.hasSuffix(suffix) {
            spelled.removeLast(suffix.count)
            refs = true
        }
        if spelled.hasPrefix("sift ") {
            spelled.removeFirst("sift ".count)
        }
        guard let parsed = cliCall(arguments: siftArguments(of: ShellQuery("sift " + spelled + (refs ? InPlaceAnswer.referencesFlag : "")))) else { return nil }
        return Call(kind: parsed.kind + " (hook)", words: parsed.words, command: parsed.command)
    }

    /// An MCP call's kind: the tool, the arguments that change the answer's shape spelled as the CLI spells them, and a digest's target shape.
    static func mcpCall(tool: String, input: [String: Any]) -> Call {
        let flags: [(String, String)] = [("refs", "--refs"), ("files", "--files"), ("decl", "--decl"), ("at", "--at"), ("all", "--all"), ("signaturesOnly", "--signatures-only")]
        var parts = [tool]
        if tool == "where" || tool == "digest" {
            for (argument, spelled) in flags where isSet(input[argument]) {
                parts.append(spelled)
            }
        }
        var targets: [String] = []
        for key in ["symbol", "target", "query"] {
            if let text = input[key] as? String {
                targets.append(text)
            }
        }
        if let several = input["targets"] as? [String] {
            targets += several
        }
        if tool == "digest" {
            parts.append("(" + digestShape(of: targets) + ")")
        }
        return Call(kind: parts.joined(separator: " "), words: words(in: targets))
    }

    private static func isSet(_ value: Any?) -> Bool {
        switch value {
        case let flag as Bool: flag
        case let text as String: !text.isEmpty
        default: false
        }
    }

    /// The call of the first segment of a Bash line that runs sift with a verb; `(no verb)` only where no segment has one.
    static func cliCall(_ command: String) -> Call? {
        var fallback: Call?
        for segment in ShellSyntax.executedSegments(of: command) {
            let query = ShellQuery(segment)
            guard query.invokesSift else { continue }
            if let call = cliCall(arguments: siftArguments(of: query)) {
                if call.kind != "(no verb)" {
                    return call
                }
                fallback = fallback ?? call
            }
        }
        return fallback
    }

    /// The words after `sift` in a segment, cut at the first redirection the shell would act on: told apart on the raw words, so `sift strings "<Settings>"` keeps its quoted argument while `sift where Gizmo > log` loses `> log`.
    static func siftArguments(of query: ShellQuery) -> ArraySlice<String> {
        guard let siftIndex = query.invocation.firstIndex(where: { URL(fileURLWithPath: $0).lastPathComponent == "sift" }) else { return [] }
        let cut = query.rawInvocation[(siftIndex + 1)...].prefix { $0.firstMatch(of: /^(\d*|&)[<>]/) == nil }.count
        return query.invocation[(siftIndex + 1)...].prefix(cut)
    }

    /// The call a `sift` command line makes, from the words after `sift`.
    static func cliCall(arguments: ArraySlice<String>) -> Call? {
        guard let verbIndex = arguments.firstIndex(where: { !$0.hasPrefix("-") }) else { return Call(kind: "(no verb)", words: []) }
        let verb = arguments[verbIndex]
        var flags: [String] = []
        var positional: [String] = []
        var rest = arguments[(verbIndex + 1)...].makeIterator()
        var wrapped: [String] = []
        var afterSeparator = false
        var sawSeparator = false
        while let word = rest.next() {
            if afterSeparator || !word.hasPrefix("-") || word == "-" {
                positional.append(word)
                if afterSeparator {
                    wrapped.append(word)
                }
            } else if word == "--" {
                afterSeparator = true
                sawSeparator = true
            } else {
                let name = String(word.split(separator: "=", maxSplits: 1).first ?? "")
                flags.append(name)
                if ["--root", "--offset", "--at"].contains(name), !word.contains("=") {
                    _ = rest.next()
                }
            }
        }
        var parts = [verb]
        if verb == "where" || verb == "digest" {
            parts += ["--refs", "--files", "--decl", "--at", "--all", "--signatures-only"].filter(flags.contains)
        }
        if verb == "digest" {
            parts.append("(" + digestShape(of: positional) + ")")
        }
        let kind = parts.joined(separator: " ")
        if wrappingVerbs.contains(verb) {
            let own = arguments[(verbIndex + 1)...].joined(separator: " ")
            return Call(kind: kind, words: [], command: sawSeparator ? wrapped.joined(separator: " ") : own)
        }
        return Call(kind: kind, words: lookupVerbs.contains(verb) ? words(in: positional) : [])
    }

    private static let wrappingVerbs: Set<String> = ["run", "test", "build"]
    private static let lookupVerbs: Set<String> = ["where", "digest", "search", "strings"]

    /// What a digest's target is: a type, a `Type.member`, a file, a cited line or range, a module or `.`, or several.
    static func digestShape(of targets: [String]) -> String {
        guard targets.count == 1, let target = targets.first else { return targets.isEmpty ? "none" : "several" }
        if target == "." || target.hasSuffix("/") {
            return "module"
        }
        if let colon = target.lastIndex(of: ":") {
            let cite = target[target.index(after: colon)...]
            if !cite.isEmpty, cite.allSatisfy({ $0.isNumber || $0 == "-" }) {
                return cite.contains("-") ? "range" : "line"
            }
        }
        if target.hasSuffix(".swift") || target.hasSuffix(".md") || target.contains("/") {
            return "file"
        }
        return target.contains(".") ? "member" : "type"
    }

    // MARK: - What came next

    /// The words of `targets` three characters or longer; a path or a cited `File.swift:12-40` contributes only its file stem, never its folders or extension.
    static func words(in targets: [String]) -> [String] {
        var seen: [String] = []
        for target in targets {
            for word in stemOrWords(of: target) where word.count >= 3 && !seen.contains(String(word)) {
                seen.append(String(word))
            }
        }
        return seen
    }

    private static func stemOrWords(of target: String) -> [Substring] {
        var path = Substring(target)
        if let colon = path.lastIndex(of: ":") {
            let cite = path[path.index(after: colon)...]
            if !cite.isEmpty, cite.allSatisfy({ $0.isNumber || $0 == "-" }) {
                path = path[..<colon]
            }
        }
        guard !path.contains(where: \.isWhitespace), path.contains("/") || path.hasSuffix(".swift") || path.hasSuffix(".md") else {
            return target.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "_" })
        }
        guard !path.hasSuffix("/") else { return [] }
        var name = (String(path) as NSString).lastPathComponent
        if name.hasSuffix(".swift") || name.hasSuffix(".md") {
            name = (name as NSString).deletingPathExtension
        }
        return [Substring(name)]
    }

    private static let readers: Set<String> = ["cat", "sed", "head", "tail", "awk", "nl"]
    private static let grepers: Set<String> = ["grep", "rg", "ugrep"]

    /// How a later call stands to `answer`: a read of a file the answer names, a grep of its target, sift on it again, or other.
    static func classify(name: String, input: [String: Any], answer: Answer) -> Next {
        let held = strings(in: input).joined(separator: "\n")
        let writes = answer.words.contains { held.contains($0) }
        if IndexToolName.tool(named: name) != nil {
            return writes ? .sift : .other
        }
        switch name {
        case "Read":
            return names(file: input["file_path"] as? String ?? "", in: answer.text) ? .read : .other
        case "Grep":
            return writes ? .grep : .other
        case "Bash":
            for segment in ShellSyntax.executedSegments(of: input["command"] as? String ?? "") {
                let query = ShellQuery(segment)
                let verb = query.invocation.first.map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""
                if query.invokesSift {
                    if let command = answer.command {
                        if let later = cliCall(segment), later.command == command, later.verb == String(answer.kind.prefix { $0 != " " }) {
                            return .sift
                        }
                    } else if let later = cliCall(segment), lookupVerbs.contains(later.verb), answer.words.contains(where: { segment.contains($0) }) {
                        return .sift
                    }
                } else if readers.contains(verb) {
                    if query.invocation.dropFirst().contains(where: { names(file: $0, in: answer.text) }) {
                        return .read
                    }
                } else if grepers.contains(verb), answer.words.contains(where: { segment.contains($0) }) {
                    return .grep
                }
            }
            return .other
        default:
            return .other
        }
    }

    private static func names(file path: String, in text: String) -> Bool {
        let last = (path as NSString).lastPathComponent
        return !path.hasPrefix("-") && last.count >= 3 && last.contains(".") && text.contains(last)
    }

    private static func strings(in value: Any) -> [String] {
        switch value {
        case let text as String: [text]
        case let list as [Any]: list.flatMap { strings(in: $0) }
        case let object as [String: Any]: object.values.flatMap { strings(in: $0) }
        default: []
        }
    }
}
