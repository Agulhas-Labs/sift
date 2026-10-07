//
// Copyright © Agulhas Labs
//

import Foundation

/// The windows one context's scan scored, each by its call, kept only where a scan is asked for them (`sift scan-dump`); the audit's text keeps none.
///
/// Fed from the events the scan itself returns and nothing else, so the windows sum to what the audit's tally folds out of the same events: a tool call's own events as it is read, and a result's as it closes, which can rescore, retract or refuse a window and can locate files for the windows after it.
///
/// A call can hold two windows, told apart by ``ScoredWindow/part``: the `.indexed` lookup an index call — an MCP call, or a `sift` query on a Bash line — is counted as on its way out, and the lookup a read, a search or a shell line is held as. A Bash line running `sift where` beside a `grep` is both.
public struct ScanWindowLog: Sendable, Equatable, Codable {
    /// Every counted window, in the order the scan scored them.
    public private(set) var windows: [ScoredWindow] = []
    /// Each window's place in `windows`, by its key.
    private var positions: [String: Int] = [:]
    /// Each window's lookups still counted, by its key: one, or none once taken back.
    private var lookups: [String: [SwiftLookup]] = [:]
    /// The route an `.indexed` window was served by, by its key: `cli` for a Bash `sift` query, `answered` for an answer the advice hook gave in a refusal's place.
    private var routes: [String: String] = [:]
    /// The keys of the windows the advice hook refused.
    private var refused: Set<String> = []
    /// The first call to locate each file stem, by the root it was located under, keyed as `TranscriptScanState.located` is.
    private var locators: [String: [String: LocatingCall]] = [:]
    /// The call that credited each digest, by the root it was credited under, keyed as `TranscriptScanState.digests` is.
    private var digestLocators: [String: [LocatedDigest: LocatingCall]] = [:]

    public init() {}

    /// `found` — the events one counted `tool_use` block produced — unchanged, with a window opened for each lookup it carries, keyed by the block's `tool_use_id`, with the call that had located a held read's file by then.
    ///
    /// A block with no id cannot be matched to its result or to another build's window, and opens none: the harness writes an id on every call.
    static func opening(_ found: [TranscriptEvent], of block: [String: Any], in state: inout TranscriptScanState) -> [TranscriptEvent] {
        guard state.windowLog != nil, let call = block["id"] as? String else { return found }
        let indexTool = (block["name"] as? String).flatMap(IndexToolName.tool(named:)) != nil
        for (offset, event) in found.enumerated() {
            guard case let .lookup(lookup) = event else { continue }
            let onTheCLI = offset + 1 < found.count && found[offset + 1] == .cliLookup
            if indexTool || onTheCLI {
                state.windowLog?.open(call, part: ScoredWindow.indexPart, lookup: lookup, route: onTheCLI ? "cli" : nil, path: "", root: "")
            } else {
                let held = state.pendingReads[call]
                // Keyed by the file's own repository, as the read was scored, so an answer in the repository the call was
                // made from never names itself the locator of a same-named file in another.
                let root = held.map { TranscriptScan.locatingRoot(ofFile: $0.path, in: $0.directory) } ?? ""
                state.windowLog?.open(call, part: ScoredWindow.lookupPart, lookup: lookup, route: nil, path: held?.path ?? "", root: root)
            }
        }
        return found
    }

    /// Records the window `call`'s `part` as `lookup`, with the call that had located its file under `root`.
    private mutating func open(_ call: String, part: String, lookup: SwiftLookup, route: String?, path: String, root: String) {
        let key = Self.key(call, part: part)
        guard let position = positions[key] else {
            let locator = path.isEmpty ? nil : locator(of: path, in: root)
            positions[key] = windows.count
            lookups[key] = [lookup]
            routes[key] = route
            windows.append(ScoredWindow(session: "", call: call, part: part, classification: "", file: path.isEmpty ? nil : path, locator: locator))
            windows[windows.count - 1].classification = classification(of: key)
            return
        }
        lookups[key, default: []].append(lookup)
        windows[position].classification = classification(of: key)
    }

    /// What a result line for `call` finds before it is read, or `nil` where no log is kept or the call is none a result settles.
    static func mark(_ call: String, events: Int, in state: TranscriptScanState) -> WindowMark? {
        guard state.windowLog != nil else { return nil }
        let tool: String? = if let pending = state.pendingIndexCalls[call] {
            pending.tool
        } else if state.pendingShellDigests[call] != nil || state.pendingShellAnswers[call] != nil || state.pendingShellLookups.contains(call) {
            "bash"
        } else if state.pendingReads[call] != nil {
            "answer"
        } else {
            nil
        }
        return tool.map { WindowMark(call: call, tool: $0, located: state.located, digests: state.digests, events: events) }
    }

    /// Settles what the result `mark` was taken for did: the stems it located are credited to its call, and its windows take the classes the events it produced leave them with.
    static func close(_ mark: WindowMark?, events: [TranscriptEvent], in state: inout TranscriptScanState) {
        guard let mark, state.windowLog != nil else { return }
        var found: [(root: String, stem: String)] = []
        for (root, stems) in state.located where stems.count != mark.located[root]?.count ?? 0 {
            found += stems.subtracting(mark.located[root] ?? []).map { (root: root, stem: $0) }
        }
        let locator = LocatingCall(tool: mark.tool, call: mark.call)
        for (root, stem) in found where state.windowLog?.locators[root]?[stem] == nil {
            state.windowLog?.locators[root, default: [:]][stem] = locator
        }
        for (root, digests) in state.digests {
            for digest in digests.subtracting(mark.digests[root] ?? []) where state.windowLog?.digestLocators[root]?[digest] == nil {
                state.windowLog?.digestLocators[root, default: [:]][digest] = locator
            }
        }
        state.windowLog?.settle(mark.call, events: Array(events.dropFirst(mark.events)))
    }

    /// Follows `call`'s windows through the events its result produced, exactly as the tally folds them: a retraction takes back the window holding that lookup, a lookup is what the held window became, and a refusal names it refused.
    ///
    /// A retraction beside ``TranscriptEvent/cliLookupRetracted`` is the Bash line's index lookup; any other is the held window's where it holds that lookup, and the index window's otherwise.
    private mutating func settle(_ call: String, events: [TranscriptEvent]) {
        let (index, held) = (Self.key(call, part: ScoredWindow.indexPart), Self.key(call, part: ScoredWindow.lookupPart))
        for (offset, event) in events.enumerated() {
            switch event {
            case let .lookupRetracted(lookup):
                let onTheCLI = offset + 1 < events.count && events[offset + 1] == .cliLookupRetracted
                let key = !onTheCLI && lookups[held]?.contains(lookup) == true ? held : index
                if let slot = lookups[key]?.firstIndex(of: lookup) {
                    lookups[key]?.remove(at: slot)
                }
            case let .lookup(lookup):
                if positions[held] == nil {
                    open(call, part: ScoredWindow.lookupPart, lookup: lookup, route: nil, path: "", root: "")
                } else {
                    lookups[held, default: []].append(lookup)
                }
            case .answeredInPlace:
                routes[held] = "answered"
            case .lookupRefused:
                refused.insert(held)
            default:
                break
            }
        }
        for key in [index, held] {
            if let position = positions[key] {
                windows[position].classification = classification(of: key)
            }
        }
    }

    /// The class the window `key` stands at: its lookup's name, with an `.indexed` one's route beside it, or `refused`/`retracted` once taken back.
    private func classification(of key: String) -> String {
        let live = lookups[key] ?? []
        guard !live.isEmpty else { return refused.contains(key) ? "refused" : "retracted" }
        return live.map { lookup in
            let name = ScoredWindow.classification(of: lookup)
            return lookup == .indexed ? routes[key].map { "\(name)(\($0))" } ?? name : name
        }.joined(separator: "+")
    }

    /// The first call to locate the file at `path` under `root`: by its stem, or by a digest crediting that very file, whichever call opened first.
    private func locator(of path: String, in root: String) -> LocatingCall? {
        let credited = (digestLocators[root] ?? [:]).filter { $0.key.covers(path, in: root, whole: false) }.map(\.value)
        let found = (locators[root]?[TranscriptScan.stem(ofPath: path)]).map { [$0] + credited } ?? credited
        return found.min { (opened($0), $0.call, $0.tool) < (opened($1), $1.call, $1.tool) }
    }

    /// Where `locator`'s own window sits in `windows`, which orders the calls as the transcript made them: its index window, or the lookup window of a call the hook answered in place, which holds no other.
    ///
    /// Ranked by the call's own place, never by the order the candidates were gathered in: several answers crediting one file are drawn from a dictionary, whose order differs run to run.
    private func opened(_ locator: LocatingCall) -> Int {
        positions[Self.key(locator.call, part: ScoredWindow.indexPart)]
            ?? positions[Self.key(locator.call, part: ScoredWindow.lookupPart)]
            ?? .max
    }

    /// The key a window is held under: its call and which of the call's two windows it is.
    private static func key(_ call: String, part: String) -> String {
        "\(call) \(part)"
    }
}
