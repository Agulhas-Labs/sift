//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A swift-testing function declared at file scope, outside any suite, is reconciled like a suite's: Swift Testing logs it by its function, its literal or its raw-identifier words, so the inventory counts it as declared and the log's ending for it as expected.
@Suite(.temporaryDirectories)
struct FileScopeInventoryTests {
    /// Every file-scope shape a log names differently, beside one suite member, in the words `swift test` printed for each (measured on Swift Testing 2084).
    private static var source: String {
        """
        import Foundation
        import Testing

        @Test func countIsOne() { #expect(1 == 1) }
        @Test("A labelled gizmo") func labelled() {}
        @Test(arguments: [1, 2]) func drains(count: Int) { #expect(count > 0) }
        @Test func `stacks the pallet`() {}
        @Test func traps() {
            if getenv("GIZMO_TRAP") != nil { fatalError("trapped") }
        }

        struct PalletTests {
            @Test func member() {}
        }
        """
    }

    private static func ended(_ name: String) -> [String] {
        ["◇ Test \(name) started.", "✔ Test \(name) passed after 0.001 seconds."]
    }

    /// Every test the source declares ending as `swift test` printed it, the parameterised one with its per-case lines.
    private static var greenLines: [String] {
        ended("countIsOne()") + ended("\"A labelled gizmo\"") + ended("\"stacks the pallet\"") + ended("traps()") + ended("member()") + [
            "◇ Test drains(count:) started.",
            "◇ Test case passing 1 argument count → 1 to drains(count:) started.",
            "◇ Test case passing 1 argument count → 2 to drains(count:) started.",
            "✔ Test drains(count:) with 2 test cases passed after 0.001 seconds.",
        ]
    }

    private static func inventory(of source: String, in root: URL) throws -> TestInventory {
        let store = try TestSources.makeStore()
        let parsed = try TestSources.parsed(source, path: "Tests/GizmoTests/GizmoTests.swift", in: root)
        try store.replaceFiles([parsed]) { _ in ("GizmoTests", false) }
        return try TestInventory.read(store: store, repositoryRoot: root)
    }

    private static func reconcile(_ lines: [String], against inventory: TestInventory) -> RunReconciliation {
        var outcomes = RunTestOutcomes()
        for line in lines {
            outcomes.read(line)
        }
        return RunReconciler.reconcile(
            inventory: inventory,
            outcomes: outcomes,
            scope: RunReconciliation.Scope(manifest: "Package.swift", targets: ["GizmoTests"], conditionalTargets: false, logPath: "run.log")
        )
    }

    private static func reconcile(_ lines: [String]) throws -> RunReconciliation {
        try reconcile(lines, against: inventory(of: source, in: TemporaryDirectory.make("file-scope")))
    }

    /// A green run reports every file-scope test by the name it logs under — function, literal, raw-identifier words, parameterised function — so the line reads six declared, six reported.
    @Test
    func aGreenRunOfFileScopeTestsReportsEachOneDeclared() throws {
        let reconciliation = try Self.reconcile(Self.greenLines)

        #expect(reconciliation.counts.expected == 6)
        #expect(reconciliation.counts.ran == 6)
        #expect(reconciliation.missing.isEmpty)
        #expect(reconciliation.unclaimed.isEmpty)
        #expect(reconciliation.notes.allSatisfy { !$0.contains("file scope") })
        #expect(reconciliation.isGreen)
        #expect(RunInventoryCheck.reconciled(reconciliation).lines == ["inventory: 6 declared, 6 reported"])
    }

    /// A process that trapped in a file-scope test leaves that test, and every file-scope test it never reached, named as never reported rather than lifted out of the count.
    @Test
    func aTrappedRunNamesTheFileScopeTestsThatNeverReported() throws {
        let lines = Self.ended("countIsOne()") + ["◇ Test traps() started.", "◇ Test \"A labelled gizmo\" started.", "Tests/GizmoTests/GizmoTests.swift:9: Fatal error: trapped"]

        let reconciliation = try Self.reconcile(lines)

        #expect(reconciliation.counts.expected == 6)
        #expect(reconciliation.counts.ran == 1)
        #expect(reconciliation.missing.map(\.enumerated) == [
            "GizmoTests/(file scope)/`stacks the pallet`()",
            "GizmoTests/(file scope)/drains(count:)",
            "GizmoTests/(file scope)/labelled()",
            "GizmoTests/(file scope)/traps()",
            "GizmoTests/PalletTests/member()",
        ])
        #expect(reconciliation.isGreen == false)
        #expect(RunInventoryCheck.reconciled(reconciliation).lines.first?.hasPrefix("inventory: 6 declared, 1 reported — 5 never reported: ") == true)
    }

    /// A file-scope test that started under a passing run summary is still never reported, since no suite's pass line can vouch for a test no suite declares.
    @Test
    func aStartedFileScopeTestNoSuiteVouchesForIsNeverReported() throws {
        let lines = Self.greenLines.filter { !$0.hasPrefix("✔ Test traps()") } + ["✔ Test run with 6 tests in 1 suite passed after 0.001 seconds."]

        let reconciliation = try Self.reconcile(lines)

        #expect(reconciliation.missing.map(\.enumerated) == ["GizmoTests/(file scope)/traps()"])
        #expect(reconciliation.lost.isEmpty)
    }

    /// A real `swift test` of a package declaring the shapes above: green, every test declared is reported; trapped in a file-scope test, that test is named as never reported.
    @Test
    func aRealSwiftTestRunCountsFileScopeTestsInBothDirections() throws {
        let root = try TemporaryDirectory.make("file-scope-package")
        try TestSources.write("""
        // swift-tools-version: 6.0
        import PackageDescription

        let package = Package(name: "Gizmo", targets: [.target(name: "Gizmo"), .testTarget(name: "GizmoTests", dependencies: ["Gizmo"])])
        """, to: "Package.swift", in: root)
        try TestSources.write("public let count = 1\n", to: "Sources/Gizmo/Gizmo.swift", in: root)
        try TestSources.write(Self.source, to: "Tests/GizmoTests/GizmoTests.swift", in: root)
        let inventory = try Self.inventory(of: Self.source, in: root)

        let green = try Self.reconcile(Self.swiftTest(in: root, trapping: false), against: inventory)
        let trapped = try Self.reconcile(Self.swiftTest(in: root, trapping: true), against: inventory)

        #expect(green.counts.expected == 6)
        #expect(green.counts.ran == 6)
        #expect(green.missing.isEmpty)
        #expect(green.isGreen)
        #expect(trapped.counts.expected == 6)
        #expect(trapped.missing.map(\.enumerated).contains("GizmoTests/(file scope)/traps()"))
        #expect(trapped.isGreen == false)
    }

    /// The lines `swift test` printed in `root`, with SwiftPM's temporary directory inside the test's scope.
    private static func swiftTest(in root: URL, trapping: Bool) throws -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
        process.arguments = ["test", "--package-path", root.path]
        var environment = ProcessInfo.processInfo.environment
        environment["TMPDIR"] = try TemporaryDirectory.make("swiftpm").path + "/"
        environment["GIZMO_TRAP"] = trapping ? "1" : nil
        process.environment = environment
        let sink = Pipe()
        process.standardOutput = sink
        process.standardError = sink
        try process.run()
        let output = sink.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (String(bytes: output, encoding: .utf8) ?? "").components(separatedBy: "\n")
    }
}
