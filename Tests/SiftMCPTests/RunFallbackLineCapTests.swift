//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
import SiftCore
import Testing

/// Covers the one bound the raw-log fallback puts on what it prints: every line of the transcript, but no line past the answer's line cap.
@Suite(.temporaryDirectories)
struct RunFallbackLineCapTests {
    /// A failure the filter cannot explain serves the transcript whole, save a line of tens of kilobytes, which is cut and marked while the lines around it pass untouched.
    @Test
    func theRawFallbackCutsALineOfTensOfKilobytesAndKeepsTheRest() throws {
        let directory = try TemporaryDirectory.make("run-fallback-line-cap")
        defer { try? FileManager.default.removeItem(at: directory) }
        let wide = "/usr/bin/tool" + String(repeating: " /Users/dev/Widget/Sources/Widget/Widget.swift", count: 1300)
        let payload = directory.appendingPathComponent("transcript.txt")
        try "Building for production...\n\(wide)\nsomething went wrong\n".write(to: payload, atomically: true, encoding: .utf8)
        let swift = directory.appendingPathComponent("swift")
        try "#!/bin/sh\ncat '\(payload.path)'\nexit 1\n".write(to: swift, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: swift.path)
        let outcome = try RunLauncher(workingDirectory: directory, repositoryRoot: nil, runLogDirectory: directory).run([swift.path, "build"])
        let recorded = RecordedOutput()
        var command = try RunCommand.parse(["--", swift.path, "build"])
        command.output = recorded.output

        _ = command.report(outcome, workingDirectory: directory, accessibility: [], bundles: .undetermined, selector: nil)

        #expect(recorded.errors == ["sift run: the filter found nothing that explains the failure — raw output follows."])
        let lines = recorded.printed.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(lines.first == "Building for production...")
        #expect(lines.dropFirst(2).first == "something went wrong")
        #expect(lines.map(\.utf8.count).max() ?? 0 <= RunReportRenderer.lineCap + 500)
        let logPath = try #require(outcome.log?.url.path)
        #expect(lines.dropFirst().first?.hasSuffix("bytes — the raw log keeps this line whole: \(logPath))") == true)
    }
}
