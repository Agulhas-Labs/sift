//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore
@testable import SiftMCP
import Testing

/// Covers the pseudonyms a shared report carries in place of names — stable on one machine, undecodable off it.
@Suite(.temporaryDirectories)
struct RedactorTests {
    private static let salt = Data("test-salt".utf8)

    /// The same name gets the same token, so two reports from one machine correlate row for row.
    @Test
    func tokensAreStableForOneSaltAndDifferentAcrossSalts() {
        let redactor = Redactor(salt: Self.salt)
        let other = Redactor(salt: Data("other-salt".utf8))

        #expect(redactor.file("CheckoutFlow.swift") == redactor.file("CheckoutFlow.swift"))
        #expect(redactor.file("CheckoutFlow.swift") != other.file("CheckoutFlow.swift"))
        #expect(redactor.file("CheckoutFlow.swift") != redactor.file("ChoreTasks.swift"))
    }

    /// The extension survives so a redacted report still reads as being about Swift files.
    @Test
    func aFileTokenKeepsItsExtension() {
        let token = Redactor(salt: Self.salt).file("CheckoutFlow.swift")

        #expect(token.hasPrefix("file-"))
        #expect(token.hasSuffix(".swift"))
        #expect(!token.contains("Checkout"))
    }

    /// The same string redacted as a file and as a target must not produce the same token — a reader could otherwise link rows across reports and recover structure.
    @Test
    func kindsAreDomainSeparated() {
        let redactor = Redactor(salt: Self.salt)

        #expect(redactor.target("View.swift") != redactor.file("View.swift"))
    }

    /// The salt is created once and reused; a second load answers with the same tokens.
    @Test
    func theStandardSaltIsCreatedOnceAndReused() throws {
        let file = try TemporaryDirectory.make("salt")
            .appendingPathComponent("salt")
        defer { try? FileManager.default.removeItem(at: file) }

        let first = Redactor.standard(saltFile: file)
        let second = Redactor.standard(saltFile: file)

        #expect(first.file("A.swift") == second.file("A.swift"))
    }

    /// A home path keeps its shape but loses the username — the sharer's name is not the report's to give away.
    @Test
    func aHomePathIsTilded() {
        let home = SiftPaths.accountHome.path

        #expect(Redactor.tilded(home + "/.claude/projects") == "~/.claude/projects")
        #expect(Redactor.tilded("/opt/projects") == "/opt/projects")
    }

    /// A transcript copied out from under a scratch `HOME` still names the account's real home in its paths, so tilding must trim the account's home rather than whatever `HOME` says right now.
    @Test
    func aRealHomePathIsTildedEvenUnderAMovedHOME() {
        let accountHome = SiftPaths.accountHome.path
        let previous = ProcessInfo.processInfo.environment["HOME"]
        setenv("HOME", "/tmp/scratch-home-that-does-not-exist", 1)
        defer {
            if let previous {
                setenv("HOME", previous, 1)
            } else {
                unsetenv("HOME")
            }
        }

        #expect(Redactor.tilded(accountHome + "/.claude/projects") == "~/.claude/projects")
    }

    // MARK: The reports under redaction

    private static func toolUse(_ name: String, id: String, input: [String: Any]) -> String {
        let object: [String: Any] = [
            "type": "assistant",
            "message": ["content": [["type": "tool_use", "id": id, "name": name, "input": input]]],
        ]
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        return String(bytes: data, encoding: .utf8) ?? ""
    }

    private static func auditFixture() throws -> URL {
        let root = try TemporaryDirectory.make("redact").appendingPathComponent("redact")
        let directory = root.appendingPathComponent("-Users-someone-Developer-SecretApp")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let lines = [
            toolUse("Read", id: "a", input: ["file_path": "/repo/Sources/ParcelGateway.swift"]),
            toolUse("Read", id: "b", input: ["file_path": "/repo/Sources/ParcelGateway.swift"]),
            toolUse("Grep", id: "c", input: ["output_mode": "content", "pattern": "ParcelGateway", "glob": "**/*.swift"]),
        ]
        try (lines.joined(separator: "\n") + "\n")
            .write(to: directory.appendingPathComponent("11112222-3333.jsonl"), atomically: true, encoding: .utf8)
        return root
    }

    /// The audit's counts and structure survive redaction; the project and file names do not.
    @Test
    func aRedactedAuditNamesNoFileOrProject() throws {
        let report = try TranscriptAudit.render(projectsDirectory: Self.auditFixture(), redactor: Redactor(salt: Self.salt))

        #expect(!report.contains("ParcelGateway"))
        #expect(!report.contains("SecretApp"))
        #expect(report.contains("file-"))
        #expect(report.contains("project-"))
        #expect(report.contains("cold"))
    }

    /// Rendered twice, a redacted report is byte-identical — pseudonyms that drifted between runs would make one week's trend read as churn.
    @Test
    func aRedactedAuditIsStableAcrossRenders() throws {
        let fixture = try Self.auditFixture()

        #expect(TranscriptAudit.render(projectsDirectory: fixture, redactor: Redactor(salt: Self.salt))
            == TranscriptAudit.render(projectsDirectory: fixture, redactor: Redactor(salt: Self.salt)))
    }

    /// The section naming what the misses were reaching for is identical redacted and not — the property that makes the actionable half of the audit the half that is always safe to share.
    ///
    /// It holds because a ``MissedCall`` is a verb and never the query that produced it. Recording the suggestion's full call instead — `where ParcelGateway` — would read just as well here and would put the symbol back into the report, which is the whole thing `--redact` exists to take out. Asserting the section is byte-identical is what stops that from being a comfortable claim rather than a true one.
    @Test
    func theMissedCallSectionIsUnchangedByRedaction() throws {
        let fixture = try Self.auditFixture()
        let heading = "what the searches were reaching for"

        let plain = TranscriptAudit.render(projectsDirectory: fixture)
        let redacted = TranscriptAudit.render(projectsDirectory: fixture, redactor: Redactor(salt: Self.salt))

        #expect(plain.contains(heading))
        #expect(Self.section(heading, of: plain) == Self.section(heading, of: redacted))
        #expect(!Self.section(heading, of: redacted).contains("ParcelGateway"))
    }

    /// The lines of `report` from the one beginning `heading` to the next blank line.
    private static func section(_ heading: String, of report: String) -> String {
        let lines = report.split(separator: "\n", omittingEmptySubsequences: false)
        guard let start = lines.firstIndex(where: { $0.hasPrefix(heading) }) else { return "" }
        let rest = lines[start...]
        let end = rest.firstIndex(where: { $0.isEmpty }) ?? rest.endIndex
        return rest[..<end].joined(separator: "\n")
    }

    /// The usage report's roots, targets and failure reasons are all pseudonymised; the counts, days and latencies stay.
    @Test
    func aRedactedUsageReportNamesNoRootTargetOrReason() throws {
        let log = try TemporaryDirectory.make("usage")
            .appendingPathComponent("usage.jsonl")
        defer { try? FileManager.default.removeItem(at: log) }
        let entries = [
            #"{"ts":"2026-08-13T10:00:00Z","tool":"digest","target":"ParcelGateway","root":"/work/SecretRepo","ms":12,"ok":true}"#,
            #"{"ts":"2026-08-13T10:01:00Z","tool":"where","target":"ParcelGateway","root":"/work/SecretRepo","ms":9,"ok":false,"err":"no symbol named ParcelGateway"}"#,
        ]
        try (entries.joined(separator: "\n") + "\n").write(to: log, atomically: true, encoding: .utf8)

        let report = UsageReport.render(fileURL: log, redactor: Redactor(salt: Self.salt))

        #expect(!report.contains("ParcelGateway"))
        #expect(!report.contains("SecretRepo"))
        #expect(report.contains("repo-"))
        #expect(report.contains("target-"))
        #expect(report.contains("reason-"))
        #expect(report.contains("by tool:"))
        #expect(report.contains("2026-08-13"))
    }
}
