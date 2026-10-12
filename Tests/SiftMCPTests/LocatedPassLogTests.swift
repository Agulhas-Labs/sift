//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
import SiftCore
@testable import SiftMCP
import Testing

/// Covers the suppression row a window let through on what located its file writes: `locatedWindow` for a window of two hundred lines or fewer, `digestHeldWindow` for a wider one the file's whole digest excuses, by either record of the digest, while a cold window writes the row it always did and neither pass prints anything.
@Suite(.temporaryDirectories) struct LocatedPassLogTests {
    /// The `rule` of every row the suppression log at `file` holds, in order, none where it was never written.
    static func rules(in file: URL) -> [String] {
        let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        return text.split(separator: "\n").compactMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])?["rule"] as? String }
    }

    /// A window of two hundred lines or fewer of a file a `where` listed is let through, printing nothing, and writes one `locatedWindow` row naming the call.
    @Test(arguments: [Window.narrowRead, .narrowShell])
    func aLocatedWindowWritesALocatedWindowRow(window: Window) throws {
        let stores = try Stores()
        stores.served("where", of: "Ledger", located: [ListedWideWindowTests.file])

        let judged = stores.judged(window)

        #expect(judged.json == nil)
        #expect(judged.verdict.token == "allowed")
        #expect(judged.rules == ["locatedWindow"])
        #expect(judged.rows.first?["call"] as? String == "toolu_w1")
        #expect(judged.rows.first?["dir"] as? String == stores.root.path)
    }

    /// A window of 520 lines after the file's whole digest is let through, printing nothing, and writes one `digestHeldWindow` row.
    @Test(arguments: [Window.wideRead, .wideShell])
    func aWideWindowAfterTheWholeDigestWritesADigestHeldRow(window: Window) throws {
        let stores = try Stores()
        stores.served("digest", of: ListedWideWindowTests.file)

        let judged = stores.judged(window)

        #expect(judged.json == nil)
        #expect(judged.verdict.token == "allowed")
        #expect(judged.rules == ["digestHeldWindow"])
        #expect(judged.rows.first?["call"] as? String == "toolu_w1")
    }

    /// The ledger's record of a digest asked for lets the same windows through with an empty usage log, and they write the same rows.
    @Test(arguments: Window.allCases)
    func theLedgersDigestWritesTheSameRows(window: Window) throws {
        let stores = try Stores()
        stores.asked(digestOf: ListedWideWindowTests.file)

        let judged = stores.judged(window)

        #expect(judged.json == nil)
        #expect(judged.verdict.token == "allowed")
        #expect(judged.rules == [window.isWide ? "digestHeldWindow" : "locatedWindow"])
    }

    /// A wide window after only a module digest is judged as a cold one: its answer withheld over size writes the `answerWithheld` row it always did, and no pass row.
    @Test(arguments: [Window.wideRead, .wideShell])
    func aColdWindowWritesItsRowUnchanged(window: Window) throws {
        let stores = try Stores()
        stores.served("digest", of: "App", located: [ListedWideWindowTests.file])

        let judged = stores.judged(window)

        #expect(judged.rules == ["answerWithheld"])
        #expect(judged.rows.first?["symbol"] as? String == InPlaceAnswerer.Withholding.overSize.rawValue)
    }

    /// A window of a file this context wrote is a revisit the scan already files, and notes nothing.
    @Test(arguments: [Window.narrowRead, .narrowShell])
    func aWindowOfAWrittenFileNotesNothing(window: Window) throws {
        let stores = try Stores()
        let path = stores.root.appendingPathComponent(ListedWideWindowTests.file).path
        _ = PreToolUseCommand.notesWrite(context: stores.context, payload: ["tool_name": "Edit", "tool_input": ["file_path": path]], cwd: stores.root.path, ledger: stores.ledger)

        let judged = stores.judged(window)

        #expect(judged.json == nil)
        #expect(judged.rules.isEmpty)
    }
}

extension LocatedPassLogTests {
    /// The four windows judged: 150 or 520 lines of the ledger file from line 400, through a ranged `Read` or a shell window.
    enum Window: String, CaseIterable, Sendable {
        case narrowRead
        case wideRead
        case narrowShell
        case wideShell

        var input: [String: Any] {
            switch self {
            case .narrowRead: ["file_path": ListedWideWindowTests.file, "offset": 400, "limit": 150]
            case .wideRead: ["file_path": ListedWideWindowTests.file, "offset": 400, "limit": 520]
            case .narrowShell: ["command": "sed -n '400,549p' \(ListedWideWindowTests.file)"]
            case .wideShell: ["command": "sed -n '400,919p' \(ListedWideWindowTests.file)"]
            }
        }

        var isWide: Bool {
            self == .wideRead || self == .wideShell
        }
    }

    /// What the hook made of one call: what it would print, its verdict, and every row it wrote.
    struct Judged {
        let json: String?
        let verdict: PreToolUseCommand.Verdict
        let rows: [[String: Any]]

        var rules: [String] {
            rows.compactMap { $0["rule"] as? String }
        }
    }

    /// The scratch stores of one context: its usage log, its ledger and its suppression log.
    struct Stores {
        let root: URL
        let usageLog: URL
        let ledger: AdviceLedger
        let suppressions: URL

        init() throws {
            root = try ListedWideWindowTests.repository()
            let scratch = try TemporaryDirectory.make("located-pass")
            usageLog = scratch.appendingPathComponent("usage.jsonl")
            ledger = AdviceLedger(directory: scratch.appendingPathComponent("advice"))
            suppressions = scratch.appendingPathComponent("suppressions.jsonl")
        }

        var context: AdviceContext {
            AdviceContext.resolve(sessionID: "s1", transcriptPath: nil, agentID: "")
        }

        /// The usage log of a context whose one index call was `tool` of `target`, as the server records it.
        func served(_ tool: String, of target: String, located: [String] = []) {
            UsageLog(fileURL: usageLog).record(tool: tool, target: target, root: root.path, milliseconds: 1, succeeded: true, answer: AnswerBytes(served: 2000, source: 48000), session: "s1", located: located)
        }

        /// The hook seeing a digest of `target` asked for in this context, which its ledger notes before any answer.
        func asked(digestOf target: String) {
            _ = PreToolUseCommand.adviceTaken(
                session: "s1",
                context: context,
                payload: ["tool_name": "mcp__sift__digest", "tool_input": ["target": target]],
                cwd: root.path,
                ledger: ledger,
                callers: CallAttribution(directory: suppressions.deletingLastPathComponent().appendingPathComponent("callers"))
            )
        }

        /// The hook judging `window` as it decides one: the lookup, then its outcome, with an answerer that withholds every answer over size.
        func judged(_ window: Window) -> Judged {
            var payload = ListedWideWindowTests.payload(window.input, in: root)
            payload["tool_use_id"] = "toolu_w1"
            let log = SuppressionLog(fileURL: suppressions)
            let outcome: (json: String?, verdict: PreToolUseCommand.Verdict) = PreToolUseCommand.lookup(
                command: nil,
                payload: payload,
                in: root.path,
                noting: log,
                digested: DigestedFiles(usageLog: usageLog),
                couldAnswer: { _, _ in true },
                resolvingDigests: { name, _ in name == "Ledger" ? ListedWideWindowTests.file : nil }
            ).map { lookup in
                PreToolUseCommand.outcome(
                    to: lookup,
                    session: "s1",
                    context: context,
                    payload: payload,
                    cwd: root.path,
                    ledger: ledger,
                    usage: UsageLog(fileURL: usageLog),
                    suppressions: log,
                    answerer: { _, _, _ in .withheld(.overSize) },
                    serverPresence: { _, _ in false },
                    couldAnswer: { _, _ in true }
                )
            } ?? (nil, PreToolUseCommand.Verdict(token: "allowed", rule: "noLookup"))
            let text = (try? String(contentsOf: suppressions, encoding: .utf8)) ?? ""
            let rows = text.split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
            return Judged(json: outcome.json, verdict: outcome.verdict, rows: rows)
        }
    }
}
