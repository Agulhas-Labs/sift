//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore

/// A digest the transcript scan credits to a context: the target it asked for, the file its answer named for that target, and whether it was that file's whole digest.
///
/// A digest locates the one file its target resolved to, never a same-named file elsewhere in the repository, as the advice hook judges it. The scan reads the answer's own text first, whose header names the file it digested, and where that text names none it asks what the hook asks.
struct LocatedDigest: Sendable, Hashable, Codable {
    /// The target as the call asked for it: a type, a path, or a line range of one.
    let target: String
    /// The path the answer named for ``target``, relative to the repository it was answered from, or `nil` where the answer's text did not settle on one.
    let file: String?
    /// Whether the answer was the whole file's digest, the only one that excuses a whole read afterwards.
    let whole: Bool
    /// The directory the call was answered from — its `root`, else where it was made — against which ``file`` is spelled once that tree is gone from disk, or `nil` where the transcript does not say.
    var anchor: String?

    /// The digests one answer credits: each of `targets`, resolved against the files the answer's text names, and each file a module digest lists under its own heading (`DigestedFiles.locatedFiles`), as the hook records them.
    ///
    /// The other files that text names are not credited: the hook credits a digest only for the file its target resolved to, or a file it listed, and the scan is never more generous than the hook.
    static func credited(targets: [String], whole: Bool, answer: String, anchor: String?) -> Set<LocatedDigest> {
        // An answer that resolved nothing located nothing, however its target reads (``DigestMiss``).
        guard !DigestMiss.isMiss(inAnswer: answer) else { return [] }
        let named = files(inAnswer: answer)
        let asked = targets.filter { !$0.isEmpty }.flatMap { target -> [LocatedDigest] in
            // A glob the shell expanded reached the binary as the paths it matched, each answered under a header of
            // its own, so the files those headers name are what the digest located, whatever the command spelled.
            guard !SwiftSourcePath.isGlob(target) else {
                return headers(inAnswer: answer).filter { matches(glob: target, $0) }.map { LocatedDigest(target: $0, file: $0, whole: whole, anchor: anchor) }
            }
            // A path the renderer found nothing at is answered with the one indexed file of that name, and that
            // file is what the digest located: credited as a digest of it, since the path asked names none.
            let file = resolved(target, among: named)
            guard file == nil, let served = servedInstead(of: target, among: named) else {
                return [LocatedDigest(target: target, file: file, whole: whole, anchor: anchor)]
            }
            return [LocatedDigest(target: served + (DigestLineRange.parse(target)?.suffix ?? ""), file: served, whole: whole, anchor: anchor)]
        }
        let listed = DigestedFiles.locatedFiles(inAnswer: answer, tool: "digest").map { LocatedDigest(target: $0, file: $0, whole: false, anchor: anchor) }
        return Set(asked + listed)
    }

    /// Whether this digest locates the file at `path`, read in `repository` (`""` where that is unknown), or, where `whole` is asked, is its whole digest — which a line range never is.
    ///
    /// Judged by the hook's own rule for the target (``DigestedFiles/FileNaming``), so the two agree by construction: a path exactly where one is there, a deeper file ending in it only where no other does, and a type name only for the file named for its last component that the index resolves it to — which `resolve` asks, as the hook does — and a member's for the file its type resolves to. Where the answer named a file, that file stands in for the index's resolution, and only it is credited; where the checkout it was answered in is gone, it is spelled from the directory the call was answered from, and never names a live file of the repository the call was keyed under. Without a repository and a path spelled out in full nothing on disk can be asked, and the hook credits nothing there, so only a file the answer named is credited, matched by its end.
    func covers(
        _ path: String,
        in repository: String,
        whole: Bool,
        resolve: (String, String) -> String? = { SiblingIndexProbe.declaringFile(named: $0, atRoot: $1) }
    ) -> Bool {
        guard self.whole || !whole, DigestLineRange.parse(target) == nil || !whole else { return false }
        guard !repository.isEmpty, path.hasPrefix("/") else {
            guard let file else { return isNamedByPathTarget(path) }
            return (path == file || path.hasSuffix("/" + file)) && (!whole || isFileItself(file))
        }
        // Spelled as the repository is, through the file's directory: a path the transcript wrote through a
        // symlink would otherwise never compare equal to the same file under the repository git named.
        let standardized = URL(fileURLWithPath: path).standardizedFileURL
        let spelled = URL(fileURLWithPath: CanonicalPath.of(standardized.deletingLastPathComponent().path), isDirectory: true)
            .appendingPathComponent(standardized.lastPathComponent)
        let naming = DigestedFiles.FileNaming(file: spelled, repository: CanonicalPath.of(repository))
        guard let file else {
            // A checkout gone since holds no file the repository's index could resolve the target to, so only the
            // path the target names, spelled from where it was asked, is the file it can have meant.
            guard anchorIsOnDisk() else { return isNamedByPathTarget(standardized.path) }
            return whole ? naming.isNamed(by: target, resolvedBy: resolve) : naming.locates(by: target, resolvedBy: resolve)
        }
        guard naming.isFile(file), anchorIsOnDisk() else {
            return isSpelledFromAnchor(file, as: standardized.path) && (!whole || isFileItself(file))
        }
        return whole ? naming.isNamed(by: target, resolvedBy: { _, _ in file }) : naming.locates(by: target, resolvedBy: { _, _ in file })
    }

    /// Whether `path` is the very file this digest's path target names, as written or spelled from ``anchor``: where nothing on disk can be asked and the answer named no file, that path is the one file the target can have meant.
    private func isNamedByPathTarget(_ path: String) -> Bool {
        let asked = DigestLineRange.parse(target)?.path ?? target
        guard asked.contains("/") || asked.hasSuffix(".swift") else { return isNamedForType(asked, inGoneCheckoutAs: path) }
        guard asked.hasPrefix("/") || path.hasPrefix("/") else { return path == asked }
        let spelled = asked.hasPrefix("/") ? asked : anchor.map { ($0 as NSString).appendingPathComponent(asked) }
        return spelled.map { URL(fileURLWithPath: $0).standardizedFileURL.path } == URL(fileURLWithPath: path).standardizedFileURL.path
    }

    /// Whether `path`, gone from disk, lies under ``anchor`` and is named for the type `asked` names, or the type a member of it belongs to: the file the hook's own rule resolved it to in the checkout it was asked in, where no index is left to ask.
    private func isNamedForType(_ asked: String, inGoneCheckoutAs path: String) -> Bool {
        guard let anchor, path.hasPrefix("/"), !FileManager.default.fileExists(atPath: path) else { return false }
        let file = URL(fileURLWithPath: path).standardizedFileURL.path
        guard file.hasPrefix(URL(fileURLWithPath: anchor).standardizedFileURL.path + "/") else { return false }
        let stem = TranscriptScan.stem(ofPath: file)
        return [asked, DigestedFiles.memberType(of: asked)].contains { $0?.split(separator: ".").last.map(String.init) == stem }
    }

    /// Whether the answer's `file` was this digest's whole file rather than the one declaring the type a member target belongs to.
    private func isFileItself(_ file: String) -> Bool {
        let target = DigestLineRange.parse(target)?.path ?? target
        return target.contains("/") || target.hasSuffix(".swift") || target.split(separator: ".").last.map(String.init) == TranscriptScan.stem(ofPath: file)
    }

    /// Whether the directory this digest was answered from is still on disk, so the file its answer named relative to that checkout can be a live one; with no ``anchor`` to go on, the repository the call was keyed under is the one it was answered in.
    ///
    /// A checkout removed since — an agent's worktree — takes its directory with it, and the repository its call was keyed under holds a same-named file that answer never named.
    private func anchorIsOnDisk() -> Bool {
        anchor.map { FileManager.default.fileExists(atPath: $0) } ?? true
    }

    /// Whether `path`, gone from disk, is the answer's relative `file` spelled from ``anchor`` or a directory above it.
    ///
    /// A checkout removed since — an agent's worktree, or a scratch checkout outside the repository the read is keyed to — resolves to some other repository or none, against which the file the answer named relative to that checkout is some other path. Where the file is still on disk its own repository settles it, so this never widens a live judgement.
    private func isSpelledFromAnchor(_ file: String, as path: String) -> Bool {
        guard let anchor, !file.hasPrefix("/"), path.hasSuffix("/" + file), !FileManager.default.fileExists(atPath: path) else { return false }
        // Compared by the directory the file hangs from, which may still be there where the file is not, so both
        // sides are spelled as the filesystem spells them.
        let base = CanonicalPath.of(String(path.dropLast(file.count + 1)))
        let directory = CanonicalPath.of(anchor)
        return directory == base || directory.hasPrefix(base + "/")
    }

    /// The Swift files an index call's answer names, as it prints them: relative to the repository it answered from, or in full.
    ///
    /// Read from the lines and by the tokens the scan reads an answer's stems from, keeping each file's path rather than its stem, so a digest's credit can tell two files of one name apart (``LocatedDigest``).
    static func files(inAnswer text: String) -> Set<String> {
        var files: Set<String> = []
        for marked in NameMatchedSites.linesOutside(answer: text) where !TranscriptScan.isNotice(marked) {
            // Every file after the first in a several-target answer opens on the renderer's part marker, which
            // is no part of its path.
            let line = marked.first == SourcePassthrough.partMarker ? marked.dropFirst() : marked
            // A file digest's header, `Sources/My App/Depot.swift — module: App`, names its path whole, spaces
            // and all, where the tokens below would split it.
            if let dash = line.range(of: " — "), line[..<dash.lowerBound].hasSuffix(".swift"), line.first?.isWhitespace == false {
                files.insert(String(line[..<dash.lowerBound]))
            }
            for token in line.split(whereSeparator: { $0.isWhitespace || $0 == "," }) {
                guard let path = path(inToken: token) else { continue }
                files.insert(path)
            }
        }
        return files
    }

    /// The files an answer opens a part on, by the path its header names: one per file a several-target digest answered.
    static func headers(inAnswer text: String) -> [String] {
        text.split(separator: "\n").compactMap { marked in
            let line = marked.first == SourcePassthrough.partMarker ? marked.dropFirst() : marked
            guard let dash = line.range(of: " — "), line.first?.isWhitespace == false, line[..<dash.lowerBound].hasSuffix(".swift") else { return nil }
            return String(line[..<dash.lowerBound])
        }
    }

    /// Whether the repository-relative `file` is one the shell glob `pattern` matched, compared over as many trailing components as the pattern has past any climb, since the shell expanded it from wherever the line ran.
    private static func matches(glob pattern: String, _ file: String) -> Bool {
        let wanted = pattern.split(separator: "/").reversed().prefix { $0 != ".." && $0 != "." }.reversed()
        let named = file.split(separator: "/")
        guard !wanted.isEmpty, named.count >= wanted.count else { return false }
        return fnmatch(wanted.joined(separator: "/"), named.suffix(wanted.count).joined(separator: "/"), FNM_PATHNAME) == 0
    }

    /// The targets a digest call asked for, read from the call as the server resolved it, as ``TranscriptScan/locatedNames(in:tool:)`` reads a digest's.
    static func targets(in input: [String: Any]) -> [String] {
        let resolved = ArgumentAlias.resolved(tool: "digest", arguments: input).arguments
        return ((resolved["target"] as? String).map { [$0] } ?? []) + (resolved["targets"] as? [String] ?? [])
    }

    /// The one file among `files` sharing its last path component with the path `target` asks for, which the renderer serves in place of a path it holds nothing at.
    ///
    /// Nil for a type or member target, and where no file or several share the name.
    private static func servedInstead(of target: String, among files: Set<String>) -> String? {
        let path = DigestLineRange.parse(target)?.path ?? target
        guard path.contains("/") || path.hasSuffix(".swift") else { return nil }
        let name = (path as NSString).lastPathComponent
        let named = files.filter { ($0 as NSString).lastPathComponent == name }
        return named.count == 1 ? named.first : nil
    }

    /// The path to a Swift file a token names, or `nil` when the token is not one, held to the rule the scan holds a token to where it reads its stem.
    private static func path(inToken token: Substring) -> String? {
        guard let extensionRange = token.range(of: ".swift") else { return nil }
        if let following = token[extensionRange.upperBound...].first, following.isLetter || following.isNumber {
            return nil
        }
        let path = token[token.startIndex ..< extensionRange.upperBound].drop { "([\"'`".contains($0) }
        guard let name = path.split(separator: "/").last, name != ".swift" else { return nil }
        return String(path)
    }

    /// The one file among `files` an answer to `target` was about, resolved the way the renderer resolves a target: a path exactly where the answer names it, else by the one file whose path ends in it, and a type name by the one file named for its last component — the hook's own rule; a member's, `Depot.restock(_:)`, by the one file named for its type.
    private static func resolved(_ target: String, among files: Set<String>) -> String? {
        let target = DigestLineRange.parse(target)?.path ?? target
        let candidates: Set<String> = if target.contains("/") || target.hasSuffix(".swift") {
            files.contains(target) ? [target] : files.filter { $0.hasSuffix("/" + target) }
        } else {
            files.filter { TranscriptScan.stem(ofPath: $0) == target.split(separator: ".").last.map(String.init) }
        }
        // A member's answer is printed at its declaration, in the file named for the type it belongs to.
        if candidates.isEmpty, let type = DigestedFiles.memberType(of: target) {
            let named = files.filter { TranscriptScan.stem(ofPath: $0) == type.split(separator: ".").last.map(String.init) }
            return named.count == 1 ? named.first : nil
        }
        return candidates.count == 1 ? candidates.first : nil
    }
}
