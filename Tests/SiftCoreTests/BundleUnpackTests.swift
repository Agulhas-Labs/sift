//
// Copyright © Agulhas Labs
//

import Foundation
import Testing

/// Covers the last step of building a bundle: the unpacked folder beside the tarball is always the build just made.
///
/// Its installer is what a local deploy runs, and one left over from an earlier extraction copies the binary beside it — the previous build — and reports success. The release build itself takes minutes, so the step is its own script and is exercised on a bundle made here; the last test pins that the release script runs it.
@Suite(.temporaryDirectories)
struct BundleUnpackTests {
    private static let repository = URL(filePath: #filePath)
        .deletingLastPathComponent() // SiftCoreTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // the repository root

    private static let script = repository.appending(path: "Distribution/unpack-bundle.sh").path

    /// Runs a command to completion from `directory`, keeping its two streams apart.
    private static func run(_ executable: String, _ arguments: [String], in directory: URL? = nil) throws -> Outcome {
        let process = Process()
        process.executableURL = URL(filePath: executable)
        process.arguments = arguments
        if let directory {
            process.currentDirectoryURL = directory
        }
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let printed = output.fileHandleForReading.readDataToEndOfFile()
        let complained = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return Outcome(
            status: process.terminationStatus,
            output: String(data: printed, encoding: .utf8) ?? "",
            errors: String(data: complained, encoding: .utf8) ?? ""
        )
    }

    /// Writes `text` to `url`, creating the directory it sits in.
    private static func write(_ text: String, to url: URL, executable: Bool = false) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        if executable {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
    }

    /// A bundle tarball under `root`, whose installer prints `installed` and whose binary says which build it is.
    private static func bundle(
        in root: URL,
        installer: Bool = true,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> URL {
        let stage = root.appending(path: "stage")
        try write("new build\n", to: stage.appending(path: "sift-dist/sift"))
        if installer {
            try write("#!/bin/sh\necho installed\n", to: stage.appending(path: "sift-dist/install.sh"), executable: true)
        }
        let tarball = root.appending(path: "sift-0.0.0-abc1234-arm64.tar.gz")
        let packed = try run("/usr/bin/tar", ["-czf", tarball.path, "-C", stage.path, "sift-dist"])
        try #require(packed.status == 0, "\(packed.errors)", sourceLocation: sourceLocation)

        return tarball
    }

    private static func scratch() throws -> URL {
        try TemporaryDirectory.make("bundle-unpack").appending(path: "bundle-unpack")
    }

    /// A folder left by an earlier extraction is replaced, not extracted over: the binary is the new one, and a file the new bundle no longer carries is gone.
    @Test
    func theUnpackedBundleIsAlwaysTheTarballJustBuilt() throws {
        let root = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let tarball = try Self.bundle(in: root)
        let out = root.appending(path: "out")
        try Self.write("old build\n", to: out.appending(path: "sift-dist/sift"))
        try Self.write("shipped once\n", to: out.appending(path: "sift-dist/retired.txt"))

        let unpacked = try Self.run("/bin/sh", [Self.script, tarball.path, out.path])

        #expect(unpacked.status == 0, "\(unpacked.errors)")
        #expect(try String(contentsOf: out.appending(path: "sift-dist/sift"), encoding: .utf8) == "new build\n")
        #expect(!FileManager.default.fileExists(atPath: out.appending(path: "sift-dist/retired.txt").path))
        #expect(FileManager.default.isExecutableFile(atPath: out.appending(path: "sift-dist/install.sh").path))
        #expect(FileManager.default.fileExists(atPath: tarball.path))
    }

    /// The command printed last installs the bundle whatever directory the caller named or stood in — absolute, and quoted so a path with a space or a quote in it survives the paste.
    @Test
    func theInstallCommandRunsFromAnywhere() throws {
        let root = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let tarball = try Self.bundle(in: root)
        let out = root.appending(path: "it's out")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        let unpacked = try Self.run("/bin/sh", [Self.script, tarball.path, "it's out"], in: root)
        let command = try #require(unpacked.output.split(separator: "\n").last.map(String.init))
        let ran = try Self.run("/bin/sh", ["-c", command], in: URL(filePath: "/"))

        #expect(unpacked.status == 0, "\(unpacked.errors)")
        #expect(command.hasPrefix("sh '/"))
        #expect(ran.status == 0, "\(command): \(ran.errors)")
        #expect(ran.output == "installed\n")
    }

    /// An empty or missing directory is refused before anything is removed, and every complaint goes to standard error.
    @Test
    func aMissingArgumentOrInstallerIsRefusedOnStandardError() throws {
        let root = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let tarball = try Self.bundle(in: root, installer: false)
        try FileManager.default.createDirectory(at: root.appending(path: "out"), withIntermediateDirectories: true)

        let empty = try Self.run("/bin/sh", [Self.script, tarball.path, ""], in: root)
        let missing = try Self.run("/bin/sh", [Self.script, tarball.path], in: root)
        let noInstaller = try Self.run("/bin/sh", [Self.script, tarball.path, "out"], in: root)

        for refused in [empty, missing, noInstaller] {
            #expect(refused.status != 0)
            #expect(refused.output.isEmpty, "\(refused.output)")
        }

        #expect(empty.errors.contains("usage: unpack-bundle.sh"))
        #expect(missing.errors.contains("usage: unpack-bundle.sh"))
        #expect(noInstaller.errors.contains("did not unpack to sift-dist/install.sh"))
    }

    /// The release script resolves its output directory before leaving the caller's, unpacks what it has just packaged before saying it has, and ends on the install command the unpack printed.
    @Test
    func theReleaseScriptEndsOnTheUnpacksInstallCommand() throws {
        let script = try String(contentsOf: Self.repository.appending(path: "Distribution/make-dist.sh"), encoding: .utf8)
        let lines = script.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let commands = lines.filter { !$0.hasPrefix("#") }

        let resolves = try #require(commands.firstIndex { $0 == #"OUT_DIR="$(cd "$OUT_DIR" && pwd -P)""# })
        let leaves = try #require(commands.firstIndex { $0 == #"cd "$REPO""# })
        let packs = try #require(commands.firstIndex { $0.hasPrefix("tar -czf") })
        let unpacks = try #require(commands.firstIndex { $0.contains("Distribution/unpack-bundle.sh") })
        let reportsUnpacked = try #require(commands.firstIndex { $0.contains("unpacked:") })

        #expect(resolves < leaves)
        #expect(packs < unpacks)
        #expect(unpacks < reportsUnpacked)
        #expect(commands.last == #"echo "$INSTALL""#)
    }
}

private extension BundleUnpackTests {
    /// What a command printed on each stream, and how it exited.
    struct Outcome {
        let status: Int32
        let output: String
        let errors: String
    }
}
