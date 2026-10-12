//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
import SiftCore
import Testing

/// The warning a test run on a simulator named outright prints before it starts, when the accessibility preference already reads off.
///
/// Every case scripts the device and stands in for `xcodebuild`, so nothing here touches a simulator.
@Suite(.temporaryDirectories)
struct AccessibilityBeforeRunTests {
    private static var udid: String {
        "5F0C1D5E-1A2B-4C3D-8E9F-0A1B2C3D4E5F"
    }

    private static var warning: String {
        "accessibility: off on \(udid) — the first launch will draw an empty tree; arm it and reboot the simulator first"
    }

    /// A preference that reads off is said before the wrapped command has started, and nothing is written to the device before it.
    @Test
    func anOffPreferenceIsWarnedOfBeforeTheRunStarts() throws {
        let script = try Self.run(destination: "id=\(Self.udid)", firstReading: "0")

        #expect(script.printed.filter { $0.line == Self.warning }.map(\.commandRunning) == [false])
        #expect(script.writesBeforeTheRun == 0)
    }

    /// Both test actions are read, since each one starts the session.
    @Test
    func theTestWithoutBuildingActionIsWarnedOfToo() throws {
        let script = try Self.run(destination: "id=\(Self.udid)", firstReading: "0", action: "test-without-building")

        #expect(script.printed.filter { $0.line == Self.warning }.map(\.commandRunning) == [false])
    }

    /// A preference that reads on has nothing to warn of.
    @Test
    func anOnPreferenceIsNotWarnedOf() throws {
        let script = try Self.run(destination: "id=\(Self.udid)", firstReading: "1")

        #expect(script.printed.allSatisfy { !$0.line.hasPrefix("accessibility: off on") })
        #expect(script.reads >= 1)
    }

    /// A read that fails says nothing new; the after-run check still answers for the device.
    @Test
    func anUnreadablePreferenceIsNotWarnedOf() throws {
        let script = try Self.run(destination: "id=\(Self.udid)", firstReading: nil)

        #expect(script.printed.allSatisfy { !$0.line.hasPrefix("accessibility: off on") })
        #expect(script.reads >= 1)
    }

    /// A read that throws, as one that times out does, says nothing either; it is not taken for an off preference.
    @Test
    func aThrowingReadIsNotWarnedOf() throws {
        let script = try Self.run(destination: "id=\(Self.udid)", firstReading: "0", throwingReads: true)

        #expect(script.printed.allSatisfy { !$0.line.hasPrefix("accessibility: off on") })
        #expect(script.reads >= 1)
    }

    /// A destination that names the device by name is left to the after-run check, and nothing is read before the run.
    @Test
    func aNamedDestinationIsNotReadBeforeTheRun() throws {
        let script = try Self.run(destination: "platform=iOS Simulator,name=iPhone 17", firstReading: "0")

        #expect(script.printed.allSatisfy { !$0.line.hasPrefix("accessibility: off on") })
        #expect(script.readsBeforeTheRun == 0)
    }
}

private extension AccessibilityBeforeRunTests {
    /// The error a scripted read throws.
    struct ScriptedFailure: Error {}

    /// What the scripted device was asked and what the command printed, locked because the command may call either from another thread.
    final class Script: @unchecked Sendable {
        private let lock = NSLock()
        private var requests: [[String]] = []
        private var lines: [Printed] = []
        private var beforeTheRun = 0
        private var writtenBeforeTheRun = 0

        func record(_ arguments: [String], commandRunning: Bool) {
            lock.withLock {
                requests.append(arguments)
                if arguments.contains("read"), !commandRunning {
                    beforeTheRun += 1
                }
                if arguments.contains("write"), !commandRunning {
                    writtenBeforeTheRun += 1
                }
            }
        }

        func add(_ line: String, commandRunning: Bool) {
            lock.withLock { lines.append(Printed(line: line, commandRunning: commandRunning)) }
        }

        /// Whether this is the first read asked of the device.
        func isFirstRead() -> Bool {
            lock.withLock { requests.count(where: { $0.contains("read") }) == 1 }
        }

        var printed: [Printed] {
            lock.withLock { lines }
        }

        var reads: Int {
            lock.withLock { requests.count(where: { $0.contains("read") }) }
        }

        var writesBeforeTheRun: Int {
            lock.withLock { writtenBeforeTheRun }
        }

        var readsBeforeTheRun: Int {
            lock.withLock { beforeTheRun }
        }
    }

    /// Runs `xcodebuild` on `destination` against a device whose first read is `firstReading` (`nil` fails, and every read throws when `throwingReads` is set) and whose later reads say the preference was never written, so the after-run check ends at once.
    static func run(destination: String, firstReading: String?, action: String = "test", throwingReads: Bool = false) throws -> Script {
        let directory = try TemporaryDirectory.make("accessibility-before-run")
        defer { try? FileManager.default.removeItem(at: directory) }
        let started = directory.appendingPathComponent("started")
        let xcodebuild = directory.appendingPathComponent("xcodebuild")
        try """
        #!/bin/sh
        touch '\(started.path)'
        echo '** TEST SUCCEEDED **'
        exit 0

        """.write(to: xcodebuild, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: xcodebuild.path)
        var command = try RunCommand.parse(["--", xcodebuild.path, "-scheme", "Demo", "-destination", destination, action])
        command.log = RunUsageLog(fileURL: directory.appendingPathComponent("run.jsonl"))
        command.writesUnder = directory
        command.environment = [:]
        let script = Script()
        command.output = CommandOutput(
            keepsPartMarker: false,
            emit: { script.add($0, commandRunning: FileManager.default.fileExists(atPath: started.path)) },
            emitRaw: { _ in },
            emitError: { _ in }
        )
        command.simulatorRun = { _, arguments in
            script.record(arguments, commandRunning: FileManager.default.fileExists(atPath: started.path))
            guard arguments.contains("read") else {
                return SimulatorAccessibility.Output(succeeded: true, standardOutput: "")
            }
            if throwingReads {
                throw ScriptedFailure()
            }
            if script.isFirstRead(), let firstReading {
                return SimulatorAccessibility.Output(succeeded: true, standardOutput: "\(firstReading)\n")
            }
            return SimulatorAccessibility.Output(succeeded: false, standardOutput: "", standardError: "Domain 'com.apple.Accessibility' not found.")
        }

        try command.run()

        return script
    }
}

private extension AccessibilityBeforeRunTests.Script {
    /// One printed line with whether the wrapped command had started when it was printed.
    struct Printed {
        let line: String
        let commandRunning: Bool
    }
}
