//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// `sift diff` over a repository whose `HEAD` is unborn — `git init`, files present, nothing committed yet.
@Suite(.temporaryDirectories)
struct DiffUnbornHeadTests {
    /// An unborn `HEAD` (no commits at all) has nothing to diff against — the working-tree default reads every Swift file present, untracked or staged, as added.
    @Test func anUnbornHeadReadsUntrackedAndStagedFilesAsAdded() async throws {
        let root = try TestSources.makeTempDirectory()
        try TestSources.runGit(["init", "-q", "-b", "main"], in: root)
        try TestSources.runGit(["config", "user.email", "test@example.com"], in: root)
        try TestSources.runGit(["config", "user.name", "Tester"], in: root)
        try TestSources.write("public struct Widget {\n    public func polish() {}\n}\n", to: "Sources/Lib/Widget.swift", in: root)
        try TestSources.write("public struct Gadget {\n    public func spin() {}\n}\n", to: "Sources/Lib/Gadget.swift", in: root)
        try TestSources.runGit(["add", "Sources/Lib/Gadget.swift"], in: root)

        let output = try await DiffEngineTests.diff(root.resolvingSymlinksInPath())

        #expect(output.contains("no commits yet"))
        #expect(output.contains("Sources/Lib/Widget.swift (added, +3/-0):"))
        #expect(output.contains("Sources/Lib/Gadget.swift (added, +3/-0):"))
        #expect(output.contains("+ struct Widget  :1-3 (1 member)"))
        #expect(output.contains("+ struct Gadget  :1-3 (1 member)"))
    }
}
