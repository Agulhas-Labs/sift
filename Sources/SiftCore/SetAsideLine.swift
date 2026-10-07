//
// Copyright © Agulhas Labs
//

import Darwin
import Foundation

public extension SetAsideRecord {
    /// The one line a `run --without-line` commented out: where it is, and what it said.
    struct MutatedLine: Codable, Sendable, Equatable {
        /// Repository-relative, as git spells it.
        public let path: String
        /// Counted from 1, as a compiler names a line.
        public let number: Int
        /// The line as written, without its line ending.
        public let text: String
        /// What the line was set aside as where it was rewritten rather than commented out (`_ = updated`), and `nil` where it was commented out — recorded because only the whole file shows which, and a record written before this field existed reads as commented out.
        public let replacement: String?

        public init(path: String, number: Int, text: String, replacement: String? = nil) {
            self.path = path
            self.number = number
            self.text = text
            self.replacement = replacement
        }
    }
}

public extension SetAsideRecord.MutatedLine {
    /// `bytes` with line `number` commented out — `// ` put after its indentation, every other byte as it was — and the line's text, or a refusal naming `path` when there is nothing there to comment out.
    ///
    /// A line that is a bare-identifier assignment (`settings = updated`) is not commented out but set aside as `_ = updated`, its target replaced and every other byte as it was: the store goes and the name keeps a reader, so a binding that line alone read does not become an unused-value error that stops the build.
    static func commentingOut(line number: Int, of bytes: Data, path: String) throws -> (text: String, mutated: Data) {
        let shown = "\(path):\(number)"
        let all = [UInt8](bytes)
        var starts = [0]
        for (offset, byte) in all.enumerated() where byte == 0x0A && offset + 1 < all.count {
            starts.append(offset + 1)
        }
        let count = all.isEmpty ? 0 : starts.count
        guard number >= 1, number <= count else {
            throw SetAsideError.unsupported(path: shown, reason: "the file has \(count == 1 ? "1 line" : "\(count) lines")", flag: "--without-line")
        }
        let start = starts[number - 1]
        let end = all[start...].firstIndex(of: 0x0A) ?? all.count
        let text = String(bytes: all[start ..< end], encoding: .utf8) ?? ""
        let indentation = all[start ..< end].prefix { $0 == 0x20 || $0 == 0x09 }.count
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else {
            throw SetAsideError.unsupported(path: shown, reason: "it is blank, so there is nothing to comment out", flag: "--without-line")
        }
        guard !body.hasPrefix("//"), !body.hasPrefix("/*") else {
            throw SetAsideError.unsupported(path: shown, reason: "it is already a comment — \"\(body)\"", flag: "--without-line")
        }
        if let assignment = bareAssignment(inFile: String(bytes: all, encoding: .utf8) ?? "", line: number) {
            let target = start + assignment.target.lowerBound ..< start + assignment.target.upperBound
            return (text, Data(all[..<target.lowerBound]) + Data("_".utf8) + Data(all[target.upperBound...]))
        }
        let cut = start + indentation
        return (text, Data(all[..<cut]) + Data("// ".utf8) + Data(all[cut...]))
    }
}

public extension SetAside {
    /// Records one line of a Swift file to be commented out — the file copied into the store byte for byte and the record written, touching nothing in the tree — for `run --without-line`.
    ///
    /// `written` is the file as the caller named it, from `directory`. The index is never written: the entry's commit-side entry is the index's own, so everything that reads the record's index fields finds nothing to change and nothing but the file to put back.
    static func capture(
        line number: Int,
        of written: String,
        from directory: URL,
        into store: SetAsideStore,
        children: SetAsideChildren = SetAsideChildren(),
        id: String = UUID().uuidString,
        owner: Int32 = getpid()
    ) throws -> SetAsideRecord {
        let root = store.repositoryRoot
        let git = SetAsideGit(directory: root, children: children)
        guard let head = try? git.text(["rev-parse", "--verify", "--quiet", "HEAD"]), !head.isEmpty else {
            throw SetAsideError.noCommit
        }
        let shown = "\(written):\(number)"
        guard written.hasSuffix(".swift") else {
            throw SetAsideError.unsupported(path: shown, reason: "it is not a .swift file, and the line is commented out with `//`", flag: "--without-line")
        }
        let prefix = try SetAsideGit(directory: directory, repositoryRoot: root, children: children).text(["rev-parse", "--show-prefix"])
        let path = try repositoryPath(of: written, prefix: prefix, root: root, shown: shown)
        let (lines, _) = try SetAsideStatusLine.parse(git.run(["--literal-pathspecs"] + SetAsideStatusLine.arguments([path])), flag: "--without-line")
        let index: SetAsideRecord.IndexState
        if let line = lines.first(where: { $0.path == path }) {
            if let reason = line.unsupported {
                throw SetAsideError.unsupported(path: path, reason: reason, flag: "--without-line")
            }
            index = line.indexState
        } else {
            index = try indexEntry(of: path, git: git)
        }
        let tree = SetAsideTree(root: root)
        let caseSensitive = (try? root.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]))?.volumeSupportsCaseSensitiveNames ?? false
        var listings: [String: [String]] = [:]
        let disk = tree.onDisk(path, caseSensitive: caseSensitive, cache: &listings)
        guard case .file = try SetAsideFingerprint.kind(tree.absolute(disk)) else {
            throw SetAsideError.unsupported(path: shown, reason: "no regular file stands at \(path)", flag: "--without-line")
        }
        if let existing = try store.record() {
            throw SetAsideError.unrestored(existing)
        }
        try? FileManager.default.removeItem(at: store.directory)
        do {
            try FileManager.default.createDirectory(at: store.copies, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: store.blobs, withIntermediateDirectories: true)
            let worktree = try worktreeState(of: disk, shown: path, in: tree, copyingInto: store.copies, as: "0", flag: "--without-line")
            let copied = try Data(contentsOf: store.copies.appendingPathComponent("0"))
            let text = try SetAsideRecord.MutatedLine.commentingOut(line: number, of: copied, path: path).text
            let replacement = SetAsideRecord.MutatedLine.bareAssignment(inFile: String(bytes: copied, encoding: .utf8) ?? "", line: number)?.replacement
            let staged: SetAsideRecord.IndexEntry? = if case let .entry(entry) = index {
                entry
            } else {
                nil
            }
            let entry = SetAsideRecord.Entry(
                path: path,
                disk: Array(disk.utf8) == Array(path.utf8) ? nil : disk,
                status: "",
                head: staged,
                index: index,
                worktree: worktree
            )
            let line = SetAsideRecord.MutatedLine(path: path, number: number, text: text, replacement: replacement)
            let record = SetAsideRecord(id: id, pathspecs: [shown], directory: prefix, head: head, owner: owner, entries: [entry], line: line)
            try store.writeDurably(record, to: store.recordURL)
            return record
        } catch {
            // No record was written — its rename is the last step — so everything here is a copy nobody points at.
            try? FileManager.default.removeItem(at: store.directory)
            throw error
        }
    }

    /// `written`, read from the directory `prefix` names, as a repository-relative path — refused when it leads outside the repository.
    private static func repositoryPath(of written: String, prefix: String, root: URL, shown: String) throws -> String {
        let joined: String
        if written.hasPrefix("/") {
            let base = root.standardizedFileURL.path + "/"
            guard written.hasPrefix(base) else {
                throw SetAsideError.unsupported(path: shown, reason: "it is outside this repository", flag: "--without-line")
            }
            joined = String(written.dropFirst(base.count))
        } else {
            joined = prefix + written
        }
        var parts: [Substring] = []
        for part in joined.split(separator: "/") where part != "." {
            guard part == ".." else {
                parts.append(part)
                continue
            }
            guard !parts.isEmpty else {
                throw SetAsideError.unsupported(path: shown, reason: "it is outside this repository", flag: "--without-line")
            }
            parts.removeLast()
        }
        return parts.joined(separator: "/")
    }

    /// The index's stage-0 entry for a path git reports no change at, or `.absent` where it has none — an ignored file.
    private static func indexEntry(of path: String, git: SetAsideGit) throws -> SetAsideRecord.IndexState {
        let output = try git.text(["--literal-pathspecs", "ls-files", "-s", "--", path])
        guard let tab = output.firstIndex(of: "\t") else {
            return .absent
        }
        let fields = output[..<tab].split(separator: " ").map(String.init)
        guard fields.count == 3, fields[2] == "0" else {
            throw SetAsideError.unsupported(path: path, reason: "the index holds it as a conflict", flag: "--without-line")
        }
        return .entry(SetAsideRecord.IndexEntry(mode: fields[0], object: fields[1]))
    }
}

extension SetAside {
    /// The file with its line commented out, written into the store where `target` says the commit's version would go, and what it reads as — built by this process from the copy the capture took.
    func prepareLine(_ record: SetAsideRecord, _ line: SetAsideRecord.MutatedLine, at target: (SetAsideRecord.Entry) -> String) throws -> [String: SetAsideFingerprint] {
        var prepared: [String: SetAsideFingerprint] = [:]
        for entry in record.entries {
            guard case let .file(permissions, _, copy) = entry.worktree else {
                throw SetAsideError.store("\(entry.path) was not recorded as a file")
            }
            let original = try Data(contentsOf: store.copies.appendingPathComponent(copy))
            let mutated = try SetAsideRecord.MutatedLine.commentingOut(line: line.number, of: original, path: line.path).mutated
            let url = URL(fileURLWithPath: target(entry))
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try mutated.write(to: url)
            guard chmod(url.path, mode_t(permissions)) == 0 else {
                throw SetAsideError.store("could not set the permission bits of \(entry.path)'s commented-out version: \(String(cString: strerror(errno)))")
            }
            prepared[entry.path] = try SetAsideFingerprint.read(url.path)
        }
        return prepared
    }
}
