//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftMCP
import Testing

/// `audit --root` over a window whose sessions all ran elsewhere says the root matched none of them and where they ran, never that there are no transcripts at all.
@Suite(.temporaryDirectories)
struct TranscriptAuditRootNoSessionsTests {
    /// A projects directory holding one session per entry of `directories`, each recorded as run there.
    private static func projects(_ directories: [String]) throws -> URL {
        let root = try TemporaryDirectory.make("audit-root")
        for (index, directory) in directories.enumerated() {
            let project = root.appendingPathComponent("project-\(index)", isDirectory: true)
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            var line = TranscriptFixture.toolUse("Read", input: ["file_path": "/repo/A.swift"], cwd: directory)
            line.append(0x0A)
            try line.write(to: project.appendingPathComponent("session-\(index).jsonl"))
        }
        return root
    }

    @Test
    func aRootNoSessionRanInSaysWhereTheSessionsRan() throws {
        let projects = try Self.projects(["/scratch/Depot", "/scratch/Depot", "/scratch/Lantern"])

        let text = TranscriptAudit.render(projectsDirectory: projects, root: "/scratch/Orchard")

        #expect(!text.contains("no session transcripts found"), "\(text)")
        let lines = text.split(separator: "\n").map(String.init)
        #expect(lines.first == "no session ran in /scratch/Orchard or below it — the 3 session transcripts under \(projects.path) ran in:", "\(text)")
        #expect(lines.dropFirst().first == "     2  /scratch/Depot", "\(text)")
        #expect(lines.dropFirst(2).first == "     1  /scratch/Lantern", "\(text)")
    }

    @Test
    func aRedactedAnswerPseudonymisesTheDirectories() throws {
        let projects = try Self.projects(["/scratch/Depot"])
        let redactor = Redactor(salt: Data("salt".utf8))

        let text = TranscriptAudit.render(projectsDirectory: projects, redactor: redactor, root: "/scratch/Orchard")

        #expect(!text.contains("/scratch/Depot"), "\(text)")
        #expect(text.contains(redactor.root("/scratch/Depot")), "\(text)")
        #expect(text.contains("--unredact names them"), "\(text)")
    }
}
