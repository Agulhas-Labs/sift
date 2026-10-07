//
// Copyright © Agulhas Labs
//

import Foundation
import Testing

/// A suite run leaves `$TMPDIR` as it found it: every temporary directory a test makes goes through `TemporaryDirectory`, and goes away with the scope that made it.
@Suite(.temporaryDirectories)
struct TemporaryDirectoryTests {
    private static let tests = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    /// The one file in each test target allowed to reach the temporary directory itself.
    private static let helpers = ["SiftCoreTests/TemporaryDirectory.swift", "SiftMCPTests/TemporaryDirectory.swift"]

    /// The files each test target carries its own copy of, because a test target cannot share a source file.
    private static let copies = [helpers, ["SiftCoreTests/TemporaryDirectoriesTrait.swift", "SiftMCPTests/TemporaryDirectoriesTrait.swift"]]

    /// Every spelling that reaches the machine's temporary directory without the helper: the property on `FileManager` and on `URL`, the Foundation function, the C calls, the replacement-directory lookup, and the `confstr`/`getconf` name.
    ///
    /// Written with `[.]`, `[(]` and `[_]` so that the patterns, as this file spells them, match none of themselves.
    private static var bypass: Regex<Substring> {
        /[.]temporaryDirectory\b|\bNSTemporaryDirectory[(]|\bmkdtemp[(]|\bmkstemp[(]|[.]itemReplacementDirectory\b|DARWIN_USER_TEMP[_]DIR/
    }

    /// A plain substring look first, so the pattern runs only over the few hundred lines that could match it rather than every line of the suite.
    private static func mightBypass(_ line: String) -> Bool {
        ["emporary", "mkdtemp", "mkstemp", "eplacement", "DARWIN_USER"].contains { line.contains($0) }
    }

    /// Every Swift file under `Tests/` a test is written in, repository-relative to `Tests/` — the fixtures directories hold sources the suite parses, not code it runs.
    private static func testSources() throws -> [String] {
        let manager = FileManager.default
        guard let walk = manager.enumerator(at: tests, includingPropertiesForKeys: [.isDirectoryKey]) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        var sources: [String] = []
        for case let url as URL in walk {
            if url.lastPathComponent == "Fixtures" {
                walk.skipDescendants()
            } else if url.pathExtension == "swift" {
                sources.append(String(url.standardizedFileURL.path.dropFirst(tests.standardizedFileURL.path.count + 1)))
            }
        }
        return sources.sorted()
    }

    /// No test reaches the temporary directory except through the helper, which is the only way a directory made there is also taken away.
    ///
    /// Comment lines are skipped — naming the API is not calling it.
    @Test func everyTemporaryDirectoryATestMakesGoesThroughTheHelper() throws {
        var bypasses: [String] = []
        for source in try Self.testSources() where !Self.helpers.contains(source) {
            let text = try String(contentsOf: Self.tests.appendingPathComponent(source), encoding: .utf8)
            for (index, line) in text.components(separatedBy: "\n").enumerated() where Self.mightBypass(line) {
                guard !line.trimmingCharacters(in: .whitespaces).hasPrefix("//"), line.contains(Self.bypass) else { continue }
                bypasses.append("Tests/\(source):\(index + 1): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }

        #expect(bypasses.isEmpty, "make these through `TemporaryDirectory.make` instead:\n\(bypasses.joined(separator: "\n"))")
    }

    /// Each test target carries its own copy of the helper and of its trait, and the copies are one helper only while each pair is the same bytes.
    @Test func bothTestTargetsCarryTheSameHelper() throws {
        let drifted = try Self.copies.filter { pair in
            try Set(pair.map { try Data(contentsOf: Self.tests.appendingPathComponent($0)) }).count != 1
        }

        #expect(drifted.isEmpty, "drifted apart: \(drifted.map { $0.joined(separator: " and ") }.joined(separator: "; "))")
    }

    /// A scope removes what was made in it on the way out of a throw as well as a return.
    @Test func aScopeRemovesWhatWasMadeInItWhenItsBodyThrows() throws {
        struct Planted: Error {}
        var made: URL?
        #expect(throws: Planted.self) {
            try TemporaryDirectory.withScope {
                let directory = try TemporaryDirectory.make("thrown")
                try Data("contents\n".utf8).write(to: directory.appendingPathComponent("file.txt"))
                made = directory
                throw Planted()
            }
        }
        let directory = try #require(made)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    /// A real `swift build` in a fixture repository leaves nothing in `$TMPDIR` once its scope ends.
    ///
    /// SwiftPM files a lock for the scratch path and one for the workspace state there, each named for the package's own path (`…_sift-repo-<UUID>_.build.lock`), and never removes either; removing the repository leaves both behind. The fixture points SwiftPM's temporary directory into its own scope, so the lock files — and the driver's `TemporaryDirectory.*` — go with it. Read by name fragment rather than by the two derived names, so a lock SwiftPM starts filing under a third name is caught too.
    @Test func aRealBuildLeavesNothingNamedForItsRepositoryInTheTemporaryDirectory() async throws {
        let repository = try await TemporaryDirectory.withScope {
            let root = try TestSources.makeTempRepo()
            try TestSources.write(
                "// swift-tools-version: 6.0\nimport PackageDescription\n\nlet package = Package(name: \"Lib\", targets: [.target(name: \"Lib\")])\n",
                to: "Package.swift",
                in: root
            )
            try TestSources.write("public struct Gadget {}\n", to: "Sources/Lib/Gadget.swift", in: root)
            try await TestSources.swiftBuildSuspending(packageAt: root)
            return root
        }

        let leftovers = try TemporaryDirectory.entries(containing: repository.lastPathComponent)

        #expect(!FileManager.default.fileExists(atPath: repository.path))
        #expect(leftovers.isEmpty, "left in $TMPDIR: \(leftovers.joined(separator: ", "))")
    }
}
