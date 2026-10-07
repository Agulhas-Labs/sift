//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore

/// Whether the context about to read a Swift file whole has already had that file digested.
///
/// A refusal of that read would offer the digest the context was already served: it says nothing new, and the round trip it costs is priced at the whole context so far, which late in a long session is the most expensive thing the hook can do. So the hook asks this first and lets the read through.
///
/// **Served, not current: a digest does not lapse when its file changes afterwards.** The advice ledger keeps its targets with no time at all, so only the usage log's holds could ever lapse, and a file's modification time moves on a rewrite of the same text (a checkout, a patch set aside and restored, a formatter), so a lapse would refuse reads whose digest the context does hold. A read let through on a digest the file has since outgrown prints the current source, which is what the context wanted either way, and the rule it is logged under, `alreadyDigested`, says only that a digest of the file was served in this context, never that the context's copy is current.
///
/// **The evidence is the usage log**, which records every answered index call under the session that made it and — where the hook left a slip for the server to claim (``CallAttribution``) — the subagent. The hook is the only process that sees the caller, and the server the only one that sees whether the call answered, so the line they write together is the one place both facts meet. Only the session's own lines are read, nobody else's.
///
/// **Matched per context, not per session.** A subagent's window never held its parent's digest, so for it the refusal is news; ``TranscriptScanState`` draws the same line when it scores reads. A call the hook could not attribute carries no agent and reads as the parent's, so the one way this errs is towards letting a parent's read through on a subagent's digest — one refusal missed, never one made that says nothing.
///
/// **Matched to the file by the digest a refusal would offer**, and by nothing looser. A line counts only when it answered from the repository the file is in, answered with a type or file digest — the two answers that weigh themselves against source, and so the only ones that record `srcBytes` — and named either the file itself or, as its final component, the type the file is named for. A member body, a candidate list and a miss all answer a digest call without serving the file's digest, so a context holding one of them has not seen what the refusal offers. The tally (``TranscriptScan/locatedNames(in:)``) matches more generously, so every read this lets through is still one it files as read whole after its digest: withholding a refusal that has nothing to add is not a claim that nothing was lost.
public struct DigestedFiles: Sendable {
    private let fileURL: URL
    /// The suffix walks this instance's questions have already made, so each is made once per hook call.
    let suffixWalks = SameSuffixFiles()

    /// How much of the end of the log is read.
    ///
    /// The log is shared by every session on the machine and is never rotated, while the digest this looks for is one the asking context still holds — made earlier in a context that is live now, so among the most recent lines written. Two megabytes is thousands of index calls, far more than a context's lifetime of them on a busy machine. A digest older than that is missed, and a miss refuses the read as it would have been refused anyway, which is the safe side.
    static let tailBytes = 2 << 20

    /// Where the log is followed rather than read afresh for each question, as a replay reads it; `nil` for the one-shot hook.
    private let follower: UsageLogFollower?

    public init(usageLog fileURL: URL) {
        self.fileURL = fileURL
        follower = nil
    }

    private init(fileURL: URL, follower: UsageLogFollower) {
        self.fileURL = fileURL
        self.follower = follower
    }

    /// Read from `fileURL` once and followed as it grows (``UsageLogFollower``), for a process that asks many questions of one log it appends to: each answer is the one a fresh read of the tail would give.
    public static func following(usageLog fileURL: URL) -> DigestedFiles {
        DigestedFiles(fileURL: fileURL, follower: UsageLogFollower(fileURL: fileURL))
    }

    /// How many bytes of the log a followed instance has read in all; `nil` for one that reads the tail afresh.
    var bytesFollowed: Int? {
        follower?.bytesReadSoFar
    }

    /// Read from the shared usage log, `~/.sift/usage.jsonl` — or the file `SIFT_USAGE_LOG` names, the one the log is written to.
    public static func standard() -> DigestedFiles {
        DigestedFiles(usageLog: UsageLog.standardFileURL())
    }

    /// Whether `session`'s context `agent` — `nil` for the session itself — has had the digest of the file at `path` answered.
    ///
    /// Any failure to read is `false`: the read is then refused as it would have been, which is the state this only ever relaxes. So is a file in no repository, which no digest can have answered from.
    ///
    /// `resolve` is ``SiblingIndexProbe/declaringFile(named:atRoot:)`` by default — the real index, consulted where a target names no path — and injectable so a test can state what the index would resolve rather than build one to prove it.
    public func contains(
        _ path: String,
        session: String,
        agent: String?,
        resolve: (String, String) -> String? = { SiblingIndexProbe.declaringFile(named: $0, atRoot: $1) }
    ) -> Bool {
        matches(path, session: session, agent: agent, resolve: resolve, locating: false)
    }

    /// Whether `session`'s context `agent` has had an answer that locates the file at `path` — its whole digest, a digest of some of its lines, or a `where` or `search` answer that listed the file, each of which locates it the same way its whole digest does without being it.
    ///
    /// Excuses a window of the file, never a whole read of it. A `where` or `search` line locates only through the files its answer listed (`located`), so a line written before that field existed locates nothing.
    public func locates(
        _ path: String,
        session: String,
        agent: String?,
        resolve: (String, String) -> String? = { SiblingIndexProbe.declaringFile(named: $0, atRoot: $1) }
    ) -> Bool {
        matches(path, session: session, agent: agent, resolve: resolve, locating: true)
    }

    private func matches(
        _ path: String,
        session: String,
        agent: String?,
        resolve: (String, String) -> String?,
        locating: Bool
    ) -> Bool {
        let agent = agent.flatMap { $0.isEmpty ? nil : $0 }
        let file = URL(fileURLWithPath: path).standardizedFileURL
        guard !session.isEmpty,
              let repository = SessionPrimer.enclosingRepository(of: file.deletingLastPathComponent().path)
        else { return false }
        // A file's name is not its identity: a digest answered from another repository is of another file.
        let root = CanonicalPath.of(repository)
        let named = Self.FileNaming(file: file, repository: repository, walks: suffixWalks)
        func credited(_ entry: [String: Any]) -> Bool {
            Self.isAnswered(entry, session: session, agent: agent, root: root) && Self.credits(entry, to: named, locating: locating, resolve: resolve)
        }
        if let follower {
            guard let lines = follower.lines(of: session) else { return false }
            return lines.contains { ($0.namesDigest || (locating && $0.namesLocated)) && credited($0.entry) }
        }
        guard let data = Self.tail(of: fileURL) else { return false }
        // Every line is JSON-parsed only once it carries the session's id and the tool's name: the log is shared
        // by every session on the machine, and this runs inside a hook.
        let sessionBytes = Data(session.utf8)
        let digestBytes = Data(#""digest""#.utf8)
        let locatedBytes = Data(#""located""#.utf8)
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            guard line.range(of: sessionBytes) != nil,
                  line.range(of: digestBytes) != nil || (locating && line.range(of: locatedBytes) != nil),
                  let entry = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  credited(entry)
            else { continue }
            return true
        }
        return false
    }

    /// Whether one parsed log line is an answered call of `session`'s context `agent` from the repository at `root`, before anything asks what it served.
    private static func isAnswered(_ entry: [String: Any], session: String, agent: String?, root: String) -> Bool {
        guard entry["session"] as? String == session,
              entry["ok"] as? Bool == true,
              entry["agent"] as? String == agent,
              // Compared canonically, at comparison time: the log records the root as git named it, and the path
              // this was handed may spell the same directory another way. Compared first, since crediting a
              // suffix target walks the tree.
              let answeredFrom = entry["root"] as? String
        else { return false }
        return CanonicalPath.of(answeredFrom) == root
    }

    /// Whether one answered log line serves the file `named` names: a type or file digest of it, the only answer that excuses a whole read — or, where only locating is asked, a digest of some of its lines, or a `where` or `search` answer that listed the file (`locatedFiles`), which locates it for a window without being its digest.
    private static func credits(_ entry: [String: Any], to named: FileNaming, locating: Bool, resolve: (String, String) -> String?) -> Bool {
        switch entry["tool"] as? String {
        case "digest":
            // An answer that resolved nothing located nothing, for a window of any width (``DigestMiss``).
            guard entry["miss"] as? Bool != true, let target = entry["target"] as? String else { return false }
            // A module digest lists the files it declares under headings, each of them located as a `where` answer's.
            let names = DigestSpacedTarget.names(in: target)
            if let located = entry["located"] as? [String], located.contains(where: named.isFile) {
                // A path the renderer held no file at is answered with the whole digest of the one file it served
                // instead, which its `located` names: a whole read of that file is excused as by a digest of it.
                // A whole-file path target never carries file headings of its own, so what it located is that file.
                // A target of several names never reads as one such path: what it located may be a module's files.
                if locating || (names.count == 1 && target.hasSuffix(".swift") && DigestLineRange.parse(target) == nil) {
                    return true
                }
            }
            // A target of several names answered as each name's own digest records what each name served, and a
            // read is excused only where one name's digest alone would have excused it: a window by the rule a
            // single target's is held to, a whole read never by the files `located` lists, which are a module's.
            if names.count > 1, let parts = entry["parts"] as? [[String: Any]] {
                return parts.contains { locating ? named.locates(byPart: $0, resolvedBy: resolve) : named.isServed(by: $0, resolvedBy: resolve) }
            }
            // A member's body is served without weighing any file against its source, yet it is printed at its
            // declaration, so it locates the file declaring its type all the same.
            guard entry["srcBytes"] is NSNumber else {
                return locating && named.locatesAsMember(target, resolvedBy: resolve)
            }
            return locating ? named.locates(by: target, resolvedBy: resolve) : named.isNamed(by: target, resolvedBy: resolve)
        case "where", "search":
            guard locating, let located = entry["located"] as? [String] else { return false }
            return located.contains(where: named.isFile)
        default:
            return false
        }
    }

    /// The files a `where`, `search` or module `digest` answer locates, repository-relative as the answer prints them, which the usage log records beside the call (`located`) so a later window of one of them is the loop working rather than a lookup.
    ///
    /// Read by the parsers the answer's own writers are read back by: a `where` answer's declarations and reference lines, never the sites it lists by name match alone, which are leads rather than locations, and the file headings a `search` answer and a module digest both open each file's block with (both in ``SiftCore/ExactAnswer``). A type or file digest prints no such heading, and is matched by its target instead, except a path digest the renderer answered with the one indexed file of that path's name, which locates the file its notice says it served, since its target names none; every other tool's answer locates nothing here.
    ///
    /// `parts` is what each name of a target answered as several (``SiftCore/MeasuredAnswer/parts``) served, where the caller has them: such a digest locates what the digests of its names would each have located alone, never the files its parts' headers name, which a single target's digest does not locate either.
    public static func locatedFiles(inAnswer text: String, tool: String, parts: [MeasuredAnswer.Part] = []) -> [String] {
        switch tool {
        case "where":
            Set(ExactAnswer.locations(inWhereAnswer: text).map(\.path)).sorted()
        case "search":
            ExactAnswer.files(inSearchAnswer: text).sorted()
        case "digest" where parts.isEmpty:
            ExactAnswer.files(inDigestAnswer: text)
        case "digest":
            Set(parts.flatMap(\.located)).sorted()
        default:
            []
        }
    }

    /// Whether one of `digests` — targets keyed by the repository each was answered from, as the advice ledger records them (``AdviceLedger/digests(session:)``) — is the whole-file digest of the file at `path`.
    ///
    /// A line-range target, `F.swift:30`, is not: it locates the file (``isLocated(_:among:resolve:)``) without being its whole digest.
    ///
    /// Matched by the rule ``contains(_:session:agent:resolve:)`` applies to a log line: answered from the repository the file is in, and naming the file itself or, as its final component, the type the file is named for.
    public static func isDigested(
        _ path: String,
        among digests: [String: Set<String>],
        resolve: (String, String) -> String? = { SiblingIndexProbe.declaringFile(named: $0, atRoot: $1) }
    ) -> Bool {
        matches(path, among: digests, resolve: resolve, locating: false)
    }

    /// Whether one of `digests` locates the file at `path` — its whole digest, or a digest of some of its lines, which locates it for a window the same way a whole digest does.
    public static func isLocated(
        _ path: String,
        among digests: [String: Set<String>],
        resolve: (String, String) -> String? = { SiblingIndexProbe.declaringFile(named: $0, atRoot: $1) }
    ) -> Bool {
        matches(path, among: digests, resolve: resolve, locating: true)
    }

    private static func matches(
        _ path: String,
        among digests: [String: Set<String>],
        resolve: (String, String) -> String?,
        locating: Bool
    ) -> Bool {
        let file = URL(fileURLWithPath: path).standardizedFileURL
        guard !digests.isEmpty,
              let repository = SessionPrimer.enclosingRepository(of: file.deletingLastPathComponent().path)
        else { return false }
        let root = CanonicalPath.of(repository)
        let named = FileNaming(file: file, repository: repository)
        return digests.contains { answeredFrom, targets in
            CanonicalPath.of(answeredFrom) == root
                && targets.contains { locating ? named.locates(by: $0, resolvedBy: resolve) : named.isNamed(by: $0, resolvedBy: resolve) }
        }
    }

    /// The type a member target names its member of — `Depot` for `Depot.restock(_:)`, `Depot.Shelf` for `Depot.Shelf.count` — or `nil` for a path or a bare name.
    static func memberType(of target: String) -> String? {
        guard !target.contains("/"), !target.hasSuffix(".swift") else { return nil }
        let name = target.split(separator: "(", maxSplits: 1).first.map(String.init) ?? target
        let components = name.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count >= 2, !components.contains(where: \.isEmpty) else { return nil }
        return components.dropLast().joined(separator: ".")
    }

    /// The last ``tailBytes`` of the log, from the first whole line in them; `nil` when there is nothing to read.
    static func tail(of url: URL, bytes limit: Int = tailBytes) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let start = size > UInt64(limit) ? size - UInt64(limit) : 0
        guard (try? handle.seek(toOffset: start)) != nil, let data = try? handle.readToEnd() else { return nil }
        guard start > 0 else { return data }
        // A cut mid-line leaves the end of some other line, which is not one this can read.
        guard let newline = data.firstIndex(of: 0x0A) else { return nil }
        return data.suffix(from: data.index(after: newline))
    }
}

extension DigestedFiles {
    /// The targets that name one file: its path, in any spelling the renderer resolves, or the type it is named for.
    struct FileNaming {
        let file: URL
        let relative: String
        let stem: String
        let repository: URL
        let walks: SameSuffixFiles

        init(file: URL, repository: String, walks: SameSuffixFiles = SameSuffixFiles()) {
            self.file = file
            self.walks = walks
            let prefix = repository.hasSuffix("/") ? repository : repository + "/"
            relative = file.path.hasPrefix(prefix) ? String(file.path.dropFirst(prefix.count)) : file.path
            stem = TranscriptScan.stem(ofPath: file.path)
            self.repository = URL(fileURLWithPath: repository, isDirectory: true)
        }

        /// Whether a digest of `target` is this file's whole-file digest — never a line-range target, `F.swift:120-160`, which locates the file (``locates(by:)``) without being it.
        ///
        /// A path target is the file when it resolves to it from the repository root, or — only where nothing is there at that exact path — is a suffix of the repo-relative path at a component boundary: the renderer's own resolution, which settles on the exact path first and tries a suffix only for a path it has no exact match for, so a digest of a root `Shell.swift` never names a deeper file of that name. Any other target names this file only when its final component matches the file's name *and* the index at this repository resolves `target` to exactly this file — a stem alone is not identity: two files of the same name, or a nested type whose last component happens to match another file's stem, are not this file's digest. Where the index cannot resolve `target` at all — no index, an unbuilt one, a name it declares nowhere or in more than one file — this says no: under-allowing a read the digest did not in fact cover is the safe side.
        func isNamed(by target: String, resolvedBy resolve: (String, String) -> String?) -> Bool {
            matches(target, resolvedBy: resolve, allowingLineRange: false)
        }

        /// Whether one name's part of a target answered as several, as the usage line records it, is this file's whole digest by the rule a single-target digest of that name is held to.
        ///
        /// A path that names no indexed file is credited with the file served in its place only where its own part carries the notice naming this file; any other name only where its part weighed itself against source, as a type or file digest does, its own header names this file, and the name is this file's (``isNamed(by:resolvedBy:)``), so a module or a type not named for the file credits nothing.
        func isServed(by part: [String: Any], resolvedBy resolve: (String, String) -> String?) -> Bool {
            guard let target = part["target"] as? String, let served = part["file"] as? String, isFile(served) else { return false }
            if part["servedInstead"] as? Bool == true {
                return target.hasSuffix(".swift") && DigestLineRange.parse(target) == nil
            }
            return part["srcBytes"] is NSNumber && isNamed(by: target, resolvedBy: resolve)
        }

        /// Whether one name's part of a target answered as several, as the usage line records it, locates this file by the rule a single-target digest of that name is held to, its `located` aside: a part that weighed itself against source by its name, any other as a member's body.
        ///
        /// What the part's own answer listed is already in the line's `located`, read before this. A digest of some of a file's lines weighs itself against no source, yet its own call locates the file it names, as the advice ledger credits it, so its part does too.
        func locates(byPart part: [String: Any], resolvedBy resolve: (String, String) -> String?) -> Bool {
            guard let target = part["target"] as? String else { return false }
            return part["srcBytes"] is NSNumber || DigestLineRange.parse(target) != nil
                ? locates(by: target, resolvedBy: resolve)
                : locatesAsMember(target, resolvedBy: resolve)
        }

        /// Whether a digest of `target` locates this file — its whole digest, or a digest of some of its lines, which locates the file the same way its whole digest does.
        ///
        /// Excuses a window of the file, never its whole read.
        func locates(by target: String, resolvedBy resolve: (String, String) -> String?) -> Bool {
            matches(target, resolvedBy: resolve, allowingLineRange: true) || locatesAsMember(target, resolvedBy: resolve)
        }

        /// Whether a digest of `target`, a member of a type (`Depot.restock(_:)`), locates this file: the one the index resolves its type to, where the member's body is printed.
        ///
        /// A member declared in an extension elsewhere is not credited to that other file: only the type is resolved, as a type target is. Excuses a window of the file, never its whole read.
        func locatesAsMember(_ target: String, resolvedBy resolve: (String, String) -> String?) -> Bool {
            guard let type = DigestedFiles.memberType(of: target) else { return false }
            return matches(type, resolvedBy: resolve, allowingLineRange: false)
        }

        /// Whether `path`, as an answer printed it — relative to the repository it was answered from, or absolute — is this file, compared canonically and by nothing looser: an answer names every file it located in full.
        func isFile(_ path: String) -> Bool {
            CanonicalPath.of(URL(fileURLWithPath: path, relativeTo: repository).standardizedFileURL.path) == CanonicalPath.of(file.path)
        }

        private func matches(_ target: String, resolvedBy resolve: (String, String) -> String?, allowingLineRange: Bool) -> Bool {
            // A digest of some of the file's lines, `F.swift:120-160`, locates the file as its whole digest does —
            // but only where the caller is asking about locating rather than about the whole-file digest itself.
            let target = allowingLineRange ? (DigestLineRange.parse(target)?.path ?? target) : target
            guard target.contains("/") || target.hasSuffix(".swift") else {
                guard target.split(separator: ".").last.map(String.init) == stem else { return false }
                guard let declaringFile = resolve(target, repository.path) else { return false }
                let resolved = URL(fileURLWithPath: declaringFile, relativeTo: repository).standardizedFileURL.path
                return CanonicalPath.of(resolved) == CanonicalPath.of(file.path)
            }
            let resolved = URL(fileURLWithPath: target, relativeTo: repository).standardizedFileURL.path
            if CanonicalPath.of(resolved) == CanonicalPath.of(file.path) {
                return true
            }
            // The renderer resolves a path exactly before it tries a suffix, so a target naming a file that is there
            // from the root was that file's digest, and never a same-named file's deeper in the tree.
            guard !target.hasPrefix("/"), !FileManager.default.fileExists(atPath: resolved) else { return false }
            guard relative.hasSuffix("/" + target) else { return false }
            // The renderer shows no file at all where several indexed files end in `target` — "ambiguous" — so
            // a suffix match only credits this file where no other file under the repository also ends in it;
            // several files agreeing to hold nothing than one, wrongly, is worse than crediting the true one late.
            return noOtherFile(endingIn: target)
        }

        /// Whether no Swift file under `repository`, other than `file` itself, also ends in `target` at a component boundary — the same notion of "ambiguous" the renderer applies over the indexed inventory, read here from disk (bounded, ``SameSuffixFiles``) since a hook or a scan cannot reach the store as cheaply.
        ///
        /// Enumeration failing, or the bound running out, says no — an other file might be there and this cannot confirm otherwise — so the caller credits nothing: under-crediting a file the renderer would in fact have shown is the safe side.
        private func noOtherFile(endingIn target: String) -> Bool {
            guard let found = walks.files(endingIn: target, under: repository) else { return false }
            let own = CanonicalPath.of(file.path)
            return found.allSatisfy { $0 == own }
        }
    }
}
