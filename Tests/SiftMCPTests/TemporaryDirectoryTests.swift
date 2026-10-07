//
// Copyright © Agulhas Labs
//

import Foundation
import Testing

/// The server tests' real-build fixture leaves `$TMPDIR` as it found it — the rest of the rule is pinned once, in `SiftCoreTests`' suite of the same name, over both targets' sources.
@Suite(.temporaryDirectories)
struct TemporaryDirectoryTests {
    /// A repository `MCPTestRepo.build` really built leaves nothing named for it in `$TMPDIR` once its scope ends.
    ///
    /// SwiftPM files a lock for the scratch path and one for the workspace state there, each named for the package's own path, and never removes either; the fixture points SwiftPM's temporary directory into its own scope, so both go with it.
    @Test func aBuiltFixtureLeavesNothingNamedForItsRepositoryInTheTemporaryDirectory() throws {
        let repository = try TemporaryDirectory.withScope {
            let root = try MCPTestRepo.make()
            try MCPTestRepo.add(
                ["Package.swift": "// swift-tools-version: 6.0\nimport PackageDescription\n\nlet package = Package(name: \"App\", targets: [.target(name: \"App\")])\n"],
                to: root
            )
            try MCPTestRepo.build(root)
            return root
        }

        let leftovers = try TemporaryDirectory.entries(containing: repository.lastPathComponent)

        #expect(!FileManager.default.fileExists(atPath: repository.path))
        #expect(leftovers.isEmpty, "left in $TMPDIR: \(leftovers.joined(separator: ", "))")
    }
}
