//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
import SiftCore
import Testing

/// The `install` and `install-hook` flags that did less than they said: an allow flag with no Claude Code to apply to, the command a no-terminal note names, and run rules held back by lookup rules already in the file.
@Suite(.temporaryDirectories)
struct InstallFlagsTests {
    /// Runs `install-hook` with no terminal, its PATH naming `path`, against a settings file it owns.
    private static func installHook(_ arguments: [String], settings: URL, binary: String, path: String, currentDirectory: String? = nil) throws -> String {
        let home = settings.deletingLastPathComponent()
        var command = try InstallHookCommand.parse(["--settings", settings.path] + arguments)
        let recorded = RecordedOutput()
        command.output = recorded.output
        command.stateDirectory = home.appendingPathComponent("state")
        command.prompt = AllowRunPrompt(isInteractive: false, ask: { _ in nil })
        command.arguments = [binary]
        command.executable = binary
        command.currentDirectory = currentDirectory ?? command.currentDirectory
        command.environment = ["HOME": home.path, "CFFIXED_USER_HOME": home.path, "PATH": path]
        try command.run()
        return recorded.printed
    }

    private static func allowed(at settings: URL, sourceLocation: SourceLocation = #_sourceLocation) throws -> [String] {
        let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any], sourceLocation: sourceLocation)
        return ((object["permissions"] as? [String: Any])?["allow"] as? [String]) ?? []
    }

    /// With Claude Code left out, an allow flag says it applies to Claude Code only, and the rest still installs.
    @Test(arguments: ["--allow-run", "--allow-lookups"])
    func anAllowFlagWithoutClaudeCodeIsSaidToBeIgnored(flag: String) throws {
        let machine = try InstallCommandHarness(onPath: ["claude"])

        let run = try machine.run(["--agent", "cursor", flag])

        let notes = run.lines.filter { $0.contains("\(flag) applies only to Claude Code") }

        #expect(notes.count == 1)
        #expect(notes.first?.hasSuffix("so it was ignored") == true)
        #expect(run.status == 0)
        #expect(run.printed.contains("Cursor"))
        #expect(try !machine.files().keys.contains(".claude/settings.json"))
    }

    /// Given both allow flags and no Claude Code, the note names both, so the command it implies is the one meant.
    @Test
    func bothAllowFlagsWithoutClaudeCodeAreBothNamed() throws {
        let machine = try InstallCommandHarness(onPath: ["claude"])

        let run = try machine.run(["--agent", "cursor", "--allow-run", "--allow-lookups"])

        let notes = run.lines.filter { $0.contains("applies only to Claude Code") || $0.contains("apply only to Claude Code") }

        #expect(notes.count == 1)
        #expect(notes.first?.contains("--allow-run and --allow-lookups apply only to Claude Code") == true)
        #expect(notes.first?.hasSuffix("so they were ignored") == true)
        #expect(run.status == 0)
    }

    /// With Claude Code among the agents, the flag is applied and nothing is said to ignore it.
    @Test
    func anAllowFlagWithClaudeCodeIsNotSaidToBeIgnored() throws {
        let machine = try InstallCommandHarness(onPath: ["claude"])

        let run = try machine.run(["--agent", "claude", "--allow-run"])

        #expect(!run.printed.contains("applies only to Claude Code"))
    }

    /// An executable file named `sift` in a new directory `name` under `scratch`.
    private static func fakeSift(in scratch: URL, named name: String) throws -> URL {
        let directory = scratch.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("sift")
        try "#!/bin/sh\n".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        return directory
    }

    /// Off the PATH, the note names the binary by its path; on it, first, by the bare name.
    @Test
    func theNoTerminalNoteNamesTheCommandAsItMustBeTyped() throws {
        let scratch = try TemporaryDirectory.make("install-flags-note")
        let bin = try Self.fakeSift(in: scratch, named: "elsewhere/bin")
        let binary = bin.appendingPathComponent("sift").path

        let offPath = try Self.installHook([], settings: scratch.appendingPathComponent("a.json"), binary: binary, path: scratch.appendingPathComponent("other").path)
        let onPath = try Self.installHook([], settings: scratch.appendingPathComponent("b.json"), binary: binary, path: "/usr/bin:\(bin.path)")

        #expect(offPath.contains("run: \(binary) install-hook --allow-run"))
        #expect(offPath.contains("! \(binary) install-hook --allow-run"))
        #expect(offPath.contains("`\(binary) install-hook --allow-lookups`"))
        #expect(onPath.contains("run: sift install-hook --allow-run"))
        #expect(!onPath.contains("permissions: nothing added (no terminal to ask in) — to allow sift's lookups and wrapped builds without a prompt, run: \(binary)"))
    }

    /// A different `sift` earlier on the PATH than this binary's directory means the bare name would run that one, so the note prints the absolute path.
    @Test
    func aDifferentSiftEarlierOnThePathMakesTheNoteNameTheAbsolutePath() throws {
        let scratch = try TemporaryDirectory.make("install-flags-shadow")
        let other = try Self.fakeSift(in: scratch, named: "other")
        let own = try Self.fakeSift(in: scratch, named: "own")
        let binary = own.appendingPathComponent("sift").path

        let shadowed = try Self.installHook([], settings: scratch.appendingPathComponent("a.json"), binary: binary, path: "\(other.path):\(own.path)")
        let first = try Self.installHook([], settings: scratch.appendingPathComponent("b.json"), binary: binary, path: "\(own.path):\(other.path)")

        #expect(shadowed.contains("run: \(binary) install-hook --allow-run"))
        #expect(shadowed.contains("! \(binary) install-hook --allow-run"))
        #expect(first.contains("run: sift install-hook --allow-run"))
    }

    /// The shell takes a relative PATH entry, and an empty one anywhere in the list, against the current directory, so the bare name runs the `sift` there.
    @Test(arguments: [(".", "own"), ("", "own"), ("bin", "scratch"), ("bin/../bin", "scratch")])
    func aRelativeOrEmptyPathEntryIsTakenAgainstTheCurrentDirectory(entry: String, workingIn: String) throws {
        let scratch = try TemporaryDirectory.make("install-flags-relative")
        let own = try Self.fakeSift(in: scratch, named: "bin")
        let binary = own.appendingPathComponent("sift").path
        let directory = workingIn == "own" ? own.path : scratch.path

        for path in [entry, "\(entry):/usr/bin", "/usr/bin:\(entry)", "/usr/bin::\(entry)"] {
            let note = try Self.installHook([], settings: scratch.appendingPathComponent("a.json"), binary: binary, path: path, currentDirectory: directory)
            #expect(note.contains("run: sift install-hook --allow-run"), "PATH=\(path)")
        }
        let elsewhere = try Self.installHook([], settings: scratch.appendingPathComponent("b.json"), binary: binary, path: "\(entry):/usr/bin", currentDirectory: scratch.appendingPathComponent("nowhere").path)

        #expect(elsewhere.contains("run: \(binary) install-hook --allow-run"))
    }

    /// A different `sift` in the current directory, named by a relative entry ahead of this binary's own, is the one the bare name runs.
    @Test(arguments: [".", ""])
    func aDifferentSiftInTheCurrentDirectoryShadowsTheBinaryOnTheAbsolutePath(entry: String) throws {
        let scratch = try TemporaryDirectory.make("install-flags-relative-shadow")
        let other = try Self.fakeSift(in: scratch, named: "other")
        let own = try Self.fakeSift(in: scratch, named: "own")
        let binary = own.appendingPathComponent("sift").path

        let note = try Self.installHook([], settings: scratch.appendingPathComponent("a.json"), binary: binary, path: "\(entry):\(own.path)", currentDirectory: other.path)

        #expect(note.contains("run: \(binary) install-hook --allow-run"))
    }

    /// Both flags over a file already holding the lookup rules still add the run rules.
    @Test
    func theRunRulesAreAddedBesideLookupRulesAlreadyPresent() throws {
        let scratch = try TemporaryDirectory.make("install-flags-rules")
        let settings = scratch.appendingPathComponent("settings.json")
        let binary = scratch.appendingPathComponent("bin/sift").path
        let seeded = try #require(try LookupAllowRules.adding(to: nil))
        try seeded.write(to: settings)

        let printed = try Self.installHook(["--allow-run", "--allow-lookups"], settings: settings, binary: binary, path: "/usr/bin")

        #expect(try Set(Self.allowed(at: settings)) == Set(RunAllowRules.rules + LookupAllowRules.rules))
        #expect(!printed.contains("already allowed"))
    }
}
