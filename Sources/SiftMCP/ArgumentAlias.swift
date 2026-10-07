//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore

/// Reading a call whose argument arrived under a key belonging to some other tool, or under the plain-English word for what that argument actually is.
///
/// `digest` calls its Swift-name argument `target` and `where` calls it `symbol`, so a caller coming off a run of one sends the other's key — and coming off a run of `search`, sends `query`. Every such call names exactly what it is after, and refused for spelling it is retried seconds later with the right key.
///
/// Widened deliberately narrowly, and the rule differs by key rather than by tool alone. `digest` and `where` share a set of keys healed when the value under one reads as a Swift name (`isNameShaped`) — a structural query landing under the wrong key must never be guessed at, so `digest query:"kind:struct"` still refuses rather than hunting for a symbol called `kind:struct`. `digest` alone also reads a `type:` this way, the plain word for what it names. Two more keys are healed by what they actually carry instead of by name shape: `digest` reads a `path:` as the file it names — and, named alongside a `type:` that also reads as a name, `path:` wins, since it is the more specific of the two — and `strings` reads a `text:` as the display text it searches for, a whole phrase like "Save changes" included. `search`'s argument is a real query language, where a bare name means something else, and stays unhealed.
public struct ArgumentAlias {
    /// The argument each healed tool takes its subject under.
    static let nameArgument = ["digest": "target", "where": "symbol", "strings": "query"]

    /// The key that names a call on every surface — the usage log, the audit, the tally — whether or not the tool is ever healed into it.
    ///
    /// `nameArgument` only ever lists a tool that some donor key can be healed into, so its doc promises exactly the tools that are; `search` never is — its argument is a query language, and nothing stands in for a missing one — so it stays out of `nameArgument` and is added here instead, beside the tools `nameArgument` already names. ``IndexCallTarget/of(_:tool:)`` reads this map, never `nameArgument` directly, so a call is named by the key its own tool reads even where healing never touches that tool.
    static let readArgument: [String: String] = nameArgument.merging(["search": "query"]) { current, _ in current }

    /// Tools whose healed argument is a plain Swift name and nothing else — the one clause `missingArgumentMessage` adds for them, which would misdescribe `strings`' `query:` now that a phrase or a bare key answers it too.
    static let nameOnlyArgument: Set<String> = ["digest", "where"]

    /// Every donor key, in the order they are tried — the order is the precedence when a call names more than one candidate, so `path` is tried before `type`: a `path:` sent alongside a `type:` used to be the only donor `digest` had, and naming both must still read the more specific one rather than let `type`'s later addition silently steal it.
    ///
    /// The first five are read for both `digest` and `where`, whenever the value reads as a Swift name. `type` is read for `digest` alone, under the same test: it is the plain word for what a digest names. The last two are scoped to one tool each and read by what they actually carry: `path` is a file, and `text` is whatever `strings` searches for — neither is a name standing under the wrong word, so neither is judged as one.
    static let carrying: [DonorKey] = [
        DonorKey(key: "target", tools: ["digest", "where"], isAcceptable: { isNameShaped($0, allowingRange: $1 == "digest") }),
        DonorKey(key: "symbol", tools: ["digest", "where"], isAcceptable: { isNameShaped($0, allowingRange: $1 == "digest") }),
        DonorKey(key: "query", tools: ["digest", "where"], isAcceptable: { isNameShaped($0, allowingRange: $1 == "digest") }),
        DonorKey(key: "name", tools: ["digest", "where"], isAcceptable: { isNameShaped($0, allowingRange: $1 == "digest") }),
        DonorKey(key: "symbol_or_path", tools: ["digest", "where"], isAcceptable: { isNameShaped($0, allowingRange: $1 == "digest") }),
        DonorKey(key: "path", tools: ["digest"], isAcceptable: { value, _ in isPathShaped(value) }),
        DonorKey(key: "type", tools: ["digest"], isAcceptable: { value, _ in isNameShaped(value, allowingRange: true) }),
        DonorKey(key: "text", tools: ["strings"], isAcceptable: { value, _ in isDisplayTextShaped(value) }),
    ]

    /// The key to read instead, when the wanted one is absent and another holds something name-shaped — or, for `path:` and `text:`, something shaped like what that tool's own argument actually is.
    public static func resolve(tool: String, arguments: [String: Any]) -> (given: String, wanted: String)? {
        guard let wanted = nameArgument[tool], arguments[wanted] == nil else { return nil }
        for candidate in carrying where candidate.key != wanted && candidate.tools.contains(tool) {
            guard let value = arguments[candidate.key] as? String, candidate.isAcceptable(value, tool) else { continue }
            return (given: candidate.key, wanted: wanted)
        }
        return nil
    }

    /// What to say when the name argument is missing and nothing stood in for it.
    ///
    /// Naming the keys the call *did* send is the whole point: "where needs a symbol" sends a caller round the same loop, because it never says which key it wanted or what it had been given instead.
    public static func missingArgumentMessage(tool: String, wanted: String, arguments: [String: Any]) -> String {
        let given = arguments.keys.sorted().filter { $0 != "root" }
        guard !given.isEmpty else {
            return "\(tool) needs a \(wanted)"
        }
        var message = "\(tool) needs a \(wanted) — the call sent \(given.map { "\($0):" }.joined(separator: " ")). "
        message += "\(tool) names its argument \(wanted):"
        // Said only for the tools whose argument really is a Swift name and nothing else. `search`'s is a
        // query language and `strings`' is display text or a key — telling either caller to send a plain
        // Swift name would steer them into a second wrong call to fix the first.
        if nameOnlyArgument.contains(tool) {
            message += ", and takes a plain Swift name rather than a phrase or a query"
        }
        return message + "."
    }

    /// Whether a value reads as a Swift name rather than as a query or a sentence.
    ///
    /// A dotted path (`ArchiveReader.lastEntry()`) is a name, and so is a labelled one (`save(_:to:)`); `kind:struct` is a structural query, and `RecordService.makeObserverQuery callers` is a name with an instruction stapled to it. Neither of the last two is something to guess at.
    ///
    /// The colon is what separates them, but only by where it sits. Rejecting every colon outright would throw out Swift's own labelled forms, and `where` takes those: `where symbol:"ArchiveReader.save(_:to:)"` is an ordinary call. So a colon inside parentheses is part of a selector and fine, and a colon at the top level is a query's `field:value` and is not.
    ///
    /// A line-range target (`File.swift:12-40`, `File.swift:12:5`) is a name too, though its colons sit at the top level: it is exactly the shape a `where` answer or a compiler diagnostic hands back. Only `digest` resolves one — a range is a `digest` target and nothing else, so healing it into `where`'s `symbol:` would turn a refusal into a lookup that answers "no declarations found" rather than the truth, that `where` was never the tool for a range at all.
    static func isNameShaped(_ value: String, allowingRange: Bool) -> Bool {
        guard !value.isEmpty, value.count <= 200 else { return false }
        guard !value.contains(where: \.isWhitespace) else { return false }
        guard let first = value.first, first.isLetter || first == "_" else { return false }
        if allowingRange, DigestLineRange.parse(value) != nil {
            return true
        }
        var depth = 0
        for character in value {
            switch character {
            case "(": depth += 1
            case ")": depth = max(0, depth - 1)
            case ":" where depth == 0: return false
            default: continue
            }
        }
        return true
    }

    /// Whether a value is anything `digest`'s own `target:` would accept — which is anything non-empty: a real path, `.` for the repo overview, a bare module name, a bare type name.
    ///
    /// `path:` is `digest`'s own miswrite and nothing else's, so there is no name-shaped donor to protect by narrowing this further; requiring a slash or a `.swift` suffix rejected exactly the targets that carry neither.
    static func isPathShaped(_ value: String) -> Bool {
        !value.isEmpty
    }

    /// Whether a value is anything `strings` can be asked about — display text or a key, which is anything non-empty; its argument carries no shape narrower than that.
    static func isDisplayTextShaped(_ value: String) -> Bool {
        !value.isEmpty
    }
}

extension ArgumentAlias {
    /// A sift tool call's arguments as the server resolved them before answering, with the healing that did it.
    ///
    /// The wanted key is healed from a donor (``resolve(tool:arguments:)``), then an inline `root:` is lifted out of a `search` query (``InlineRootLift``). The two touch disjoint tools, so their order changes nothing.
    ///
    /// The one reading every surface names a call by. The server answers from it and the usage log records it, and the transcript audit reads a call's failure target and the files it located from it — so a healed call is logged and scored as the call it became on every surface, and none of them can drift from the others by healing a call its own way.
    ///
    /// The arguments as sent still matter in one place, and only there: the `PreToolUse` hook's slip names a call as the model sent it, so claiming a slip reads the call before this has run (`MCPServer.recordUsage`).
    static func resolved(tool: String, arguments sent: [String: Any]) -> (arguments: [String: Any], healed: (given: String, wanted: String)?) {
        var arguments = sent
        let healed = resolve(tool: tool, arguments: arguments)
        if let healed {
            arguments[healed.wanted] = arguments[healed.given]
        }
        // A root: term inside a search query is the root argument, misplaced — lifted out rather than refused as
        // "unknown field root", and an explicit root argument still wins.
        if tool == "search", let query = arguments["query"] as? String, query.contains("root:") {
            let lifted = InlineRootLift(query: query)
            arguments["query"] = lifted.query
            if arguments["root"] == nil, let root = lifted.root {
                arguments["root"] = root
            }
        }
        return (arguments, healed)
    }

    /// One key a caller has been seen to send the wanted argument under: which tools it is read for, and the shape a value under it must have.
    struct DonorKey {
        let key: String
        let tools: Set<String>
        /// `(value, tool)`: a line-range value is only name-shaped for `digest`, so a shared key's own acceptance can differ by which tool is asking.
        let isAcceptable: @Sendable (String, String) -> Bool
    }
}
