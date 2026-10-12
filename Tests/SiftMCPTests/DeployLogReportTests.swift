//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
@testable import SiftMCP
import Testing

/// Covers `sift report --deploys`: the installer's log read back, one line per install, newest last.
@Suite(.temporaryDirectories)
struct DeployLogReportTests {
    /// Two installs print in the order they were written, a field the installer could not name reads `unknown`, and a line that is not JSON is skipped rather than fatal.
    @Test
    func twoDeploysAndAMalformedLineRender() throws {
        let directory = try TemporaryDirectory.make("deploy-log")
        let log = directory.appendingPathComponent("deploys.jsonl")
        let lines = [
            #"{"ts":"2026-10-11T08:00:00Z","version":"0.1.4","commit":"7e1b3b25","tree":"clean","binarySize":12500000}"#,
            "this line is not json",
            #"{"ts":"2026-10-12T09:30:00Z","version":null,"commit":null,"tree":"dirty","binarySize":null}"#,
        ]
        try lines.joined(separator: "\n").write(to: log, atomically: true, encoding: .utf8)

        let page = DeployLog.render(fileURL: log)

        #expect(page.components(separatedBy: "\n") == [
            "2026-10-11T08:00:00Z  7e1b3b25  0.1.4  clean  12.5 MB",
            "2026-10-12T09:30:00Z  unknown  unknown  dirty  unknown",
        ])
    }

    /// A machine that has never installed from the bundle gets a sentence, not an empty answer.
    @Test
    func noLogSaysSo() throws {
        let directory = try TemporaryDirectory.make("deploy-log-none")

        let page = DeployLog.render(fileURL: directory.appendingPathComponent("deploys.jsonl"))

        #expect(page.hasPrefix("no deploys recorded"))
    }

    /// The log sits in the state directory `SIFT_HOME` names, and `--deploys` is a flag of `report`.
    @Test
    func theLogIsInTheStateDirectory() throws {
        let url = DeployLog.standardFileURL(environment: ["SIFT_HOME": "/scratch/state"])

        #expect(url.path == "/scratch/state/deploys.jsonl")
        #expect(try ReportCommand.parse(["--deploys"]).deploys)
    }

    /// A line that is not valid UTF-8 costs that line, not the file: the rows on either side of it are still listed.
    @Test
    func aLineOfInvalidUTF8DoesNotHideTheRowsAroundIt() throws {
        let directory = try TemporaryDirectory.make("deploy-log-bytes")
        let log = directory.appendingPathComponent("deploys.jsonl")
        var bytes = Data()
        for day in 10 ... 12 {
            bytes.append(Data(#"{"ts":"2026-10-\#(day)T08:00:00Z","version":"0.1.4","commit":"abc","tree":"clean","binarySize":1000000}"#.utf8))
            bytes.append(UInt8(ascii: "\n"))
        }
        bytes.append(contentsOf: [0xFF, 0xFE, UInt8(ascii: "\n")])
        for day in 13 ... 14 {
            bytes.append(Data(#"{"ts":"2026-10-\#(day)T08:00:00Z","version":"0.1.4","commit":"abc","tree":"clean","binarySize":1000000}"#.utf8))
            bytes.append(UInt8(ascii: "\n"))
        }
        try bytes.write(to: log)

        let rows = DeployLog.render(fileURL: log).components(separatedBy: "\n")

        #expect(rows.map { String($0.prefix(10)) } == (10 ... 14).map { "2026-10-\($0)" })
    }

    /// `--deploys` stands in for the page, so an option that shapes the page is refused rather than ignored.
    @Test
    func deploysRefusesEveryOtherReportOption() throws {
        #expect(throws: (any Error).self) { try ReportCommand.parse(["--deploys", "--since", "bogus"]) }
        #expect(throws: (any Error).self) { try ReportCommand.parse(["--deploys", "--out", "page.html"]) }
        #expect(throws: (any Error).self) { try ReportCommand.parse(["--deploys", "--no-open"]) }
        #expect(try ReportCommand.parse(["--deploys"]).deploys)
    }
}
