//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore

/// The stop-time validation gate: a context that edited Swift and is stopping on a tree no green `sift run` stands for is sent back, once, to build it.
///
/// Whether the tree is validated is the question `sift run --proved` asks — a ``RunLedger`` record whose ``TreeKey`` is the tree as it stands — widened to any command and to the checkout's ``RunLedger/greenBuilds(inCheckout:)``, where every green `sift run` build or test records the tree it saw however the shell around it was written. The context's own transcript is the fallback, for a run no record reached: a green `sift run` build or test after its last Swift edit, placed in its repository and vouched for by the call's result, answers it too. Every way the question cannot be put answers "no block": the gate is advice with teeth, and one that guessed would stop sessions on its own mistakes.
public struct StopBuildGate {
    /// How long the whole judgement may take before the stop goes through unremarked.
    public static let timeBudget: TimeInterval = 1

    /// The reason to block this `Stop` or `SubagentStop` payload with, or `nil` where the stop goes through.
    ///
    /// Claimed in `marks` once per context and tree, so an agent sent back is never sent back twice for the same content, and `stop_hook_active` — a stop already continued by a hook — never blocks at all.
    ///
    /// `now` is the instant a run's heartbeat is judged live against.
    public static func reason(for payload: [String: Any], marks: ReuseNudgeMarks, now: Date = Date()) -> String? {
        guard payload["stop_hook_active"] as? Bool != true,
              let sessionID = payload["session_id"] as? String, !sessionID.isEmpty,
              let transcript = transcript(of: payload),
              let scan = SwiftEditsSinceGreenRun.scan(transcript: transcript.url, skippingSidechains: !transcript.isSubagent)
        else {
            return nil
        }
        let context = AdviceContext.resolve(
            sessionID: sessionID,
            transcriptPath: payload["agent_transcript_path"] as? String ?? payload["transcript_path"] as? String,
            agentID: payload["agent_id"] as? String
        )
        for (root, files) in repositories(of: scan.files) {
            let rootURL = URL(fileURLWithPath: root)
            guard let tree = TreeKey.of(repositoryRoot: rootURL), !isValidated(tree, in: rootURL) else {
                continue
            }
            // A run of this very tree is going on in this checkout: its verdict lands on record when it ends, and the next stop judges it.
            // Nothing is claimed, so a red verdict is still advised on.
            let running = RunProgressPaths.liveRuns(inRepositoryAt: rootURL, at: now).filter { $0.tree != nil }
            guard !running.contains(where: { $0.tree == tree.value }),
                  let command = command(root: rootURL, xcodebuild: scan.xcodebuild),
                  marks.claim(context: context.key, file: root, declaration: running.isEmpty ? "stop \(tree.value)" : "stop waiting \(tree.value)")
            else {
                continue
            }
            return running.isEmpty ? reason(edited: files, command: command) : reason(edited: files, afterEarlierRunIn: command)
        }
        return nil
    }

    /// The build the block names: `swift build` where a package sits at the root, else the `sift run -- xcodebuild … build` the context already ran, else nothing.
    ///
    /// Always a build, never a test, and never a command spelled here: a scheme and a destination are the project's to name, so an `xcodebuild` is only ever one the agent wrote itself. The ledger is not a source: it records test runs, and a test is more than the block asks for.
    static func command(root: URL, xcodebuild: (command: String, directory: String?)?) -> (command: String, directory: String)? {
        if FileManager.default.fileExists(atPath: root.appendingPathComponent("Package.swift").path) {
            return ("sift run -- swift build", root.path)
        }
        guard let xcodebuild else { return nil }
        let canonicalRoot = CanonicalPath.of(root.path)
        let ranIn = xcodebuild.directory.map(CanonicalPath.of).flatMap { $0 == canonicalRoot || $0.hasPrefix(canonicalRoot + "/") ? $0 : nil }
        return (xcodebuild.command, ranIn ?? root.path)
    }
}

private extension StopBuildGate {
    /// How many of the newest records of each ledger are compared with a tree no record names exactly, one `git diff-tree` apiece.
    static let nearRecordsCompared = 4

    /// Whether a green record stands for `tree`: one of this very tree, or of one that differs from it only in files no build reads, such as a changelog edited and committed after the run.
    static func isValidated(_ tree: TreeKey, in root: URL) -> Bool {
        let ledgers = [RunLedger.inRepository(at: root), RunLedger.greenBuilds(inCheckout: root)].map { $0.records() }
        if ledgers.contains(where: { $0.contains { $0.tree == tree.value } }) {
            return true
        }
        return ledgers.flatMap { $0.prefix(nearRecordsCompared) }.contains {
            tree.sameSwiftSources(as: TreeKey(value: $0.tree), repositoryRoot: root)
        }
    }

    /// The repositories the edited files the index would take fall in, each with its files, the one edited last first.
    ///
    /// A file the index's inclusion rule keeps out, an ignored path or one under a build directory among them, is no edit, and one outside every repository has none to build.
    static func repositories(of edited: [String]) -> [(root: String, files: [String])] {
        var order: [String] = []
        var filesByRoot: [String: [String]] = [:]
        for file in edited.reversed() {
            guard let root = CallerRoot.root(forCallerIn: URL(fileURLWithPath: file).deletingLastPathComponent().path),
                  CanonicalPath.of(file).hasPrefix(CanonicalPath.of(root) + "/"),
                  EditParseCheck.indexCovers(file, under: root)
            else {
                continue
            }
            if filesByRoot[root] == nil {
                order.append(root)
            }
            filesByRoot[root, default: []].insert(file, at: 0)
        }
        return order.map { ($0, filesByRoot[$0] ?? []) }
    }

    /// The transcript of the context that is stopping, and whether it is a subagent's, or `nil` where the payload does not name one.
    ///
    /// A subagent's own file, never its parent's in its place: read as the subagent's, the parent's edits would block a subagent that made none.
    static func transcript(of payload: [String: Any]) -> (url: URL, isSubagent: Bool)? {
        guard payload["hook_event_name"] as? String == "SubagentStop" else {
            return (payload["transcript_path"] as? String).flatMap { $0.isEmpty ? nil : (URL(fileURLWithPath: $0), false) }
        }
        if let own = payload["agent_transcript_path"] as? String, !own.isEmpty {
            return (URL(fileURLWithPath: own), true)
        }
        guard let agent = payload["agent_id"] as? String, !agent.isEmpty,
              let session = payload["transcript_path"] as? String, !session.isEmpty,
              let own = ServerPresence.transcript(ofSession: session, agent: agent), own != session
        else {
            return nil
        }
        return (URL(fileURLWithPath: own), true)
    }

    /// What the model is told while a run of an earlier tree is going on in the checkout: which files it changed, that nothing has validated the tree they are in, and to run the build again once that run ends, never to start one beside it.
    ///
    /// A second build in the same `.build` collides with the live one, so the command is named for afterwards only.
    static func reason(edited: [String], afterEarlierRunIn command: (command: String, directory: String)) -> String {
        let (files, shown) = summary(of: edited)
        return "sift: you edited \(files) (\(shown)) and no green `sift run` build or test is on record for the tree as it stands. "
            + "A `sift run` of an earlier tree is in progress in \(command.directory); do not start another build beside it. "
            + "Once it ends, run `\(command.command)` again from \(command.directory) and fix what it reports before reporting done. (Asked once for this tree; SIFT_NO_ADVICE=1 turns it off.)"
    }

    /// What the model is told: which files it changed, that nothing has validated the tree they are in, and the one command that will.
    static func reason(edited: [String], command: (command: String, directory: String)) -> String {
        let (files, shown) = summary(of: edited)
        return "sift: you edited \(files) (\(shown)) and no green `sift run` build or test is on record for the tree as it stands. "
            + "Run `\(command.command)` from \(command.directory) and fix what it reports before reporting done. (Asked once for this tree; SIFT_NO_ADVICE=1 turns it off.)"
    }

    /// How many Swift files the context changed, as a phrase, and the first three by name.
    static func summary(of edited: [String]) -> (files: String, shown: String) {
        let names = edited.map { URL(fileURLWithPath: $0).lastPathComponent }
        let shown = names.count > 3 ? names.prefix(3).joined(separator: ", ") + ", …" : names.joined(separator: ", ")
        return (edited.count == 1 ? "1 Swift file" : "\(edited.count) Swift files", shown)
    }
}
