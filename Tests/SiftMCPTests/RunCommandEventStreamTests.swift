//
// Copyright © Agulhas Labs
//

import ArgumentParser
import Foundation
@testable import SiftCLI
import SiftCore
import Testing

/// The wiring of a wrapped `swift test`'s event stream, end to end.
@Suite(.temporaryDirectories)
struct RunCommandEventStreamTests {
    /// A wrapped `swift test` asks the `swift test` it runs for its Swift Testing event stream and reads what that wrote.
    ///
    /// The note under the totals names the endings the console lost, and the stream's directory is gone once the run is answered. Set aside the request for a stream in ``RunCommand`` and none is asked for; set aside the read in ``RunLauncher`` and none is folded. Either way the note is missing.
    @Test
    func aWrappedSwiftTestReadsItsEventStreamAndNamesTheEndingsTheConsoleLost() throws {
        let directory = try TemporaryDirectory.make("run-command-event-stream")
        defer { try? FileManager.default.removeItem(at: directory) }
        let tests = ["one()", "two()", "three()", "four()"]
        let records = tests.flatMap { name -> [String] in
            let id = "LibTests.AlphaTests/\(name)/AlphaTests.swift:3:6".replacingOccurrences(of: "/", with: #"\/"#)
            let declared = #"{"kind":"test","payload":{"id":"\#(id)","isParameterized":false,"kind":"function","name":"\#(name)"},"version":"6.4.0"}"#
            let event = { (kind: String, instant: Double) in
                #"{"kind":"event","payload":{"instant":{"absolute":\#(instant),"since1970":0},"iteration":1,"kind":"\#(kind)","messages":[],"testID":"\#(id)"},"version":"6.4.0"}"#
            }
            return [declared, event("testStarted", 1), event("testEnded", 2)]
        }
        let fixture = directory.appendingPathComponent("events.jsonl")
        try records.joined(separator: "\n").write(to: fixture, atomically: true, encoding: .utf8)
        // The console drops the third test's ending, as a relay that lost a line would.
        let console = directory.appendingPathComponent("console.txt")
        let printed = tests.filter { $0 != "three()" }.map { "✔ Test \($0) passed after 0.001 seconds." }
            + ["✔ Test run with 4 tests in 1 suite passed after 0.001 seconds."]
        try (printed.joined(separator: "\n") + "\n").write(to: console, atomically: true, encoding: .utf8)
        let shim = directory.appendingPathComponent("swift")
        try """
        #!/bin/sh
        case " $* " in *" --help-hidden "*)
            echo "  --event-stream-output-path <event-stream-output-path>"
            exit 0 ;;
        esac
        while [ $# -gt 0 ]; do
            if [ "$1" = "--event-stream-output-path" ]; then
                cp '\(fixture.path)' "$2"
            fi
            shift
        done
        cat '\(console.path)'
        exit 0

        """.write(to: shim, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shim.path)
        let streams = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".sift/run-events", isDirectory: true)
        let before = Set((try? FileManager.default.contentsOfDirectory(atPath: streams.path)) ?? [])
        let recorded = RecordedOutput()
        var command = try RunCommand.parse(["--", shim.path, "test"])
        command.log = RunUsageLog(fileURL: directory.appendingPathComponent("run.jsonl"))
        command.writesUnder = directory
        command.output = recorded.output
        // The inventory note would index the checkout this test runs in; none is wanted here.
        command.inventoryBudget = 0

        try command.run()

        let note = "  event stream: 4 Swift Testing endings, the console relayed 3 — the other 1 read from the stream"
        #expect(recorded.printed.components(separatedBy: "\n").filter { $0 == note }.count == 1)
        let after = Set((try? FileManager.default.contentsOfDirectory(atPath: streams.path)) ?? [])
        #expect(after.subtracting(before).isEmpty)
    }
}
