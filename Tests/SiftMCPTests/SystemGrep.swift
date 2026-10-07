//
// Copyright © Agulhas Labs
//

import Foundation

/// The greps a shell may run for a command's `grep`, run as that shell runs them, for checking what the in-process search decides against what each prints.
///
/// The system's own grep is on every machine this suite runs on. `ugrep` is what Claude Code's shell runs behind a function named `grep`: installed on its own, or embedded in the `claude` binary, which runs as `ugrep` when `ARGV0` says so. A machine with neither has no `ugrep` here, and the tests that need it are skipped rather than failed.
enum SystemGrep {
    /// The system grep under `locale`.
    case system(locale: String)
    /// `ugrep` at `executable`, told to run as `ugrep` where it is the `claude` binary.
    case ugrep(executable: URL, embedded: Bool)

    /// The flags Claude Code's shell function hands `ugrep` ahead of the command's own.
    static let shellFunctionFlags = ["-G", "--ignore-files", "--hidden", "-I"] + [".git", ".svn", ".hg", ".bzr", ".jj", ".sl"].map { "--exclude-dir=\($0)" }

    /// The `ugrep` on this machine, or `nil` where there is none.
    static let installedUgrep: SystemGrep? = {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let directories = path.split(separator: ":").map(String.init) + ["\(home)/.local/bin"]
        for (name, embedded) in [("ugrep", false), ("claude", true)] {
            for directory in directories {
                let url = URL(fileURLWithPath: directory).appendingPathComponent(name)
                guard FileManager.default.isExecutableFile(atPath: url.path) else { continue }
                let candidate = SystemGrep.ugrep(executable: url, embedded: embedded)
                if let version = try? candidate.output(["--version"]), version.hasPrefix("ugrep") {
                    return candidate
                }
            }
        }
        return nil
    }()

    /// Every grep this machine has: the system's in the C locale and in UTF-8, and `ugrep` where it is installed.
    static var everyGrep: [SystemGrep] {
        [.system(locale: "C"), .system(locale: "en_US.UTF-8")] + (installedUgrep.map { [$0] } ?? [])
    }

    /// The line numbers this grep prints for `pattern`, with `flags`, over the one file at `file`.
    func lines(_ flags: [String], _ pattern: String, _ file: URL) throws -> Set<Int> {
        let text = try output(["-n"] + flags + ["--", pattern, file.path])
        return Set(text.split(separator: "\n").compactMap { $0.split(separator: ":").first.flatMap { Int($0) } })
    }

    /// The files this grep prints a match of `pattern` in, searching `operand` recursively from `directory`, relative to `directory`.
    func files(_ pattern: String, under operand: String, in directory: URL) throws -> Set<String> {
        let text = try output(["-rl", "--", pattern, operand], in: directory)
        return Set(text.split(separator: "\n").map { $0.hasPrefix("./") ? String($0.dropFirst(2)) : String($0) })
    }

    /// Each line this grep prints for `arguments`, run in `directory`, as `path:line` with any leading `./` dropped — the `-n` output of a search that prints file names.
    func printed(_ arguments: [String], in directory: URL) throws -> Set<String> {
        let text = try output(arguments, in: directory)
        return Set(text.split(separator: "\n").compactMap { line -> String? in
            let fields = line.split(separator: ":", maxSplits: 2)
            guard fields.count == 3 else { return nil }
            let path = fields[0].hasPrefix("./") ? fields[0].dropFirst(2) : fields[0]
            return "\(path):\(fields[1])"
        })
    }

    /// What this grep prints to standard output for `arguments`, run in `directory` where one is given.
    private func output(_ arguments: [String], in directory: URL? = nil) throws -> String {
        let process = Process()
        process.currentDirectoryURL = directory
        switch self {
        case let .system(locale):
            process.executableURL = URL(fileURLWithPath: "/usr/bin/grep")
            process.arguments = arguments
            process.environment = ["LC_ALL": locale, "PATH": "/usr/bin:/bin"]
        case let .ugrep(executable, embedded):
            process.executableURL = executable
            process.arguments = arguments == ["--version"] ? arguments : Self.shellFunctionFlags + arguments
            process.environment = ["LC_ALL": "en_US.UTF-8", "PATH": "/usr/bin:/bin"].merging(embedded ? ["ARGV0": "ugrep"] : [:]) { $1 }
        }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        // The Bash tool hands every command an empty standard input, so a grep that would read it reads nothing.
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(bytes: data, encoding: .utf8) ?? ""
    }
}
