//
// Copyright © Agulhas Labs
//

import CryptoKit
import Foundation
import SiftCore

/// Stable pseudonyms for the names a shared report must not carry.
///
/// The audit and usage reports are built to be pasted — into a Claude session, a ticket, a public issue — and every one prints file, project, symbol and root names from the repositories it measured. Under redaction the counts, dates and shares stay and the names become salted-hash tokens: `file-3f2a1b.swift`, `repo-9c1d4e`. The salt is per machine and reused, so the same file carries the same token in next week's report — a shared trend stays a trend instead of reading as churn — while nobody off the machine can test a guessed name against a token. Redaction is the default, so the owner decodes by re-running with `--unredact`; the two reports line up row for row.
public struct Redactor {
    private let salt: Data

    public init(salt: Data) {
        self.salt = salt
    }

    /// The redactor for this machine, backed by a salt at `~/.sift/redaction-salt` created once and reused.
    ///
    /// An unwritable salt file degrades to a fresh salt per run — tokens still hold within that report, they just stop agreeing with the next one.
    public static func standard(saltFile: URL = defaultSaltFile) -> Redactor {
        if let data = try? Data(contentsOf: saltFile), !data.isEmpty {
            return Redactor(salt: data)
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        for index in bytes.indices {
            bytes[index] = UInt8.random(in: .min ... .max)
        }
        let salt = Data(bytes)
        try? FileManager.default.createDirectory(at: saltFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? salt.write(to: saltFile, options: [.atomic])
        return Redactor(salt: salt)
    }

    public static var defaultSaltFile: URL {
        SiftPaths.home
            .appendingPathComponent("redaction-salt")
    }

    /// A file name's pseudonym, keeping the extension so the report still reads as being about Swift files.
    public func file(_ name: String) -> String {
        let extensionPart = (name as NSString).pathExtension
        let suffix = extensionPart.isEmpty ? "" : ".\(extensionPart)"
        return token("file", name) + suffix
    }

    /// A project directory's pseudonym — the first component of a transcript label.
    public func project(_ name: String) -> String {
        token("project", name)
    }

    /// A repository root's pseudonym, hashed over the whole path so same-named roots stay distinct.
    public func root(_ path: String) -> String {
        token("repo", path)
    }

    /// A declaration's pseudonym — a signature names a type and often what it inherits, both identifying.
    public func symbol(_ signature: String) -> String {
        token("symbol", signature)
    }

    /// A query target's pseudonym — targets are symbol names, file paths, or module names, all identifying.
    public func target(_ name: String) -> String {
        token("target", name)
    }

    /// A test's pseudonym — a test is named for what it asserts, so its name describes a private product's behaviour as plainly as any prose in it.
    ///
    /// Its own domain rather than reused from ``symbol(_:)``, on the rule the token function is built around: the same string under two prefixes gives two tokens, so a test that also turns up as a queried symbol cannot be linked across the two reports by anyone holding only the tokens.
    public func test(_ name: String) -> String {
        token("test", name)
    }

    /// A failure reason's pseudonym — most reasons quote the symbol that was asked about, and identical reasons share a token so grouping survives.
    public func reason(_ text: String) -> String {
        token("reason", text)
    }

    /// A machine-local path with the home directory as `~` — the username is the sharer's name, which is not the report's to give away.
    public static func tilded(_ path: String) -> String {
        let home = SiftPaths.accountHome.path
        guard path == home || path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }

    /// Domain-separated so the same string never links a file row to a target row, and 6 hex characters because a report holds tens of names, not millions.
    private func token(_ prefix: String, _ value: String) -> String {
        var data = salt
        data.append(Data("\(prefix):\(value)".utf8))
        let hex = SHA256.hash(data: data).prefix(3).map { String(format: "%02x", $0) }.joined()
        return "\(prefix)-\(hex)"
    }
}
