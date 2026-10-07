//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftMCP
import Testing

/// Asking whether a directory holds Swift gives back every directory handle the walk opened, so a long-lived caller can ask for as long as it lives.
///
/// The walk stops at the first Swift file it meets, which leaves the enumerator holding a directory handle for each level it had descended into. The count is taken in a child process that runs nothing else, because the test runner's other suites open and close descriptors of their own beside this one.
@Suite(.temporaryDirectories)
struct SwiftTreeDescriptorTests {
    @Test
    func twoHundredSourceProbesLeaveTheOpenDescriptorCountWhereItWas() async throws {
        let root = try TemporaryDirectory.make("swifttree-descriptors")
        let file = root.appendingPathComponent("Sources/App/Deep/Depot.swift")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("enum Depot {}\n".utf8).write(to: file)
        let path = root.path
        await #expect(processExitsWith: .success) { [path = path as String] in
            #expect(SwiftTree.holdsSource(at: "Sources", relativeTo: path))
            let before = SwiftTreeDescriptorTests.openDescriptors()
            for _ in 0 ..< 200 {
                _ = SwiftTree.holdsSource(at: "Sources", relativeTo: path)
            }
            let after = SwiftTreeDescriptorTests.openDescriptors()
            #expect(after <= before + 4, "open descriptors went from \(before) to \(after)")
        }
    }

    @Test
    func twoHundredRefusedTreeWalksLeaveTheOpenDescriptorCountWhereItWas() async throws {
        let root = try TemporaryDirectory.make("shellgrep-descriptors")
        let deep = root.appendingPathComponent("Sources/App/Deep")
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        try Data("enum Depot {}\n".utf8).write(to: deep.appendingPathComponent("Depot.swift"))
        try FileManager.default.createSymbolicLink(at: deep.appendingPathComponent("Linked.swift"), withDestinationURL: deep.appendingPathComponent("Depot.swift"))
        let path = root.path
        await #expect(processExitsWith: .success) { [path = path as String] in
            guard let search = ShellGrep(arguments: ["-rn", "--include=*.swift", "Depot", "Sources"]) else {
                Issue.record("the search did not parse")
                return
            }
            #expect(search.run(in: path) == .undecided("tree"))
            let before = SwiftTreeDescriptorTests.openDescriptors()
            for _ in 0 ..< 200 {
                _ = search.run(in: path)
            }
            let after = SwiftTreeDescriptorTests.openDescriptors()
            #expect(after <= before + 4, "open descriptors went from \(before) to \(after)")
        }
    }

    /// The number of descriptors this process has open, read from `/dev/fd`.
    static func openDescriptors() -> Int {
        (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? 0
    }
}
