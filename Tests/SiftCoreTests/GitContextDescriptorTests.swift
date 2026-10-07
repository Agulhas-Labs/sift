//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A git read gives back every descriptor it opened, so a long-lived caller can spawn git for as long as it lives.
///
/// Each read makes a pipe for stdout, one for stderr and, with input, one for stdin: four to six descriptors in this process. Left open, a replay that spawns git per lookup had thousands of them within a minute, and once the pipe pool ran out every spawn threw and every root read as none. The count is taken in a child process that runs nothing else, because the test runner's other suites open and close descriptors of their own beside this one.
@Suite(.temporaryDirectories)
struct GitContextDescriptorTests {
    @Test
    func twoHundredRootLookupsLeaveTheOpenDescriptorCountWhereItWas() async throws {
        let root = try TestSources.makeTempRepo()
        let path = root.path
        await #expect(processExitsWith: .success) { [path = path as String] in
            let directory = URL(fileURLWithPath: path)
            #expect(GitContext.discoverRoot(from: directory) != nil)
            let before = GitContextDescriptorTests.openDescriptors()
            for _ in 0 ..< 200 {
                _ = GitContext.discoverRoot(from: directory)
            }
            let after = GitContextDescriptorTests.openDescriptors()
            #expect(after <= before + 4, "open descriptors went from \(before) to \(after)")
        }
    }

    /// A read that cannot start, because the directory it would run in is gone, gives back the pipes it made for the child that never ran.
    @Test
    func twoHundredLookupsFromAGoneDirectoryLeaveTheOpenDescriptorCountWhereItWas() async throws {
        let gone = try TemporaryDirectory.make("gone-directory").appendingPathComponent("gone")
        let path = gone.path
        await #expect(processExitsWith: .success) { [path = path as String] in
            let directory = URL(fileURLWithPath: path)
            #expect(GitContext.discoverRoot(from: directory) == nil)
            let before = GitContextDescriptorTests.openDescriptors()
            for _ in 0 ..< 200 {
                _ = GitContext.discoverRoot(from: directory)
            }
            let after = GitContextDescriptorTests.openDescriptors()
            #expect(after <= before + 4, "open descriptors went from \(before) to \(after)")
        }
    }

    @Test
    func aHundredTreeHashesLeaveTheOpenDescriptorCountWhereItWas() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write("enum Depot {}\n", to: "Sources/App/Depot.swift", in: root)
        try TestSources.commitAll(in: root, message: "add")
        let path = root.path
        await #expect(processExitsWith: .success) { [path = path as String] in
            let repository = URL(fileURLWithPath: path)
            #expect(TreeContentHash.of(repositoryRoot: repository) != nil)
            let before = GitContextDescriptorTests.openDescriptors()
            for _ in 0 ..< 100 {
                _ = TreeContentHash.of(repositoryRoot: repository)
            }
            let after = GitContextDescriptorTests.openDescriptors()
            #expect(after <= before + 4, "open descriptors went from \(before) to \(after)")
        }
    }

    /// The number of descriptors this process has open, read from `/dev/fd`.
    static func openDescriptors() -> Int {
        (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? 0
    }
}
