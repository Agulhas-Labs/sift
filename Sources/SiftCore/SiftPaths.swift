//
// Copyright © Agulhas Labs
//

import Foundation

/// Where Sift keeps its files: the names it owns on disk, and the places they sit.
public struct SiftPaths {
    /// The directory the tool owns, both under `$HOME` and inside a repository.
    public static var directoryName: String {
        ".sift"
    }

    /// The index database inside a cache directory.
    ///
    /// Named here because it is what makes a directory *the* cache: the tool writes other things beside it — `runs/`, the semantic store — and a directory holding only those is a directory the index is not in.
    public static var indexFileName: String {
        "index.db"
    }

    /// The executable's name.
    public static var binaryName: String {
        "sift"
    }

    /// The per-repository configuration file.
    public static var configFileName: String {
        ".sift.json"
    }

    /// Whether a registered shell `command` is this tool's binary running `subcommand` and nothing else: its first shell word is a path whose last component is ``binaryName``, followed by exactly that subcommand.
    ///
    /// The first word is read the way a shell reads it, quoting and escapes included, so `"/opt/wrap" "/x/sift" pre-tool-use` is `/opt/wrap` running something and `python3 tools/sift pre-tool-use` is `python3` running a script: a command whose first word is any other program is never this tool's. A path that merely contains the name (`/opt/siftscience/x`) is someone else's too, and so is a subcommand with anything after it. A path with a space in it is claimed quoted, as `install-hook` writes it, or unquoted only as an older install did (see the legacy rule below).
    public static func runsThisTool(_ command: String, subcommand: String) -> Bool {
        let command = command.trimmingCharacters(in: .whitespaces)
        if let (executable, rest) = firstShellWord(of: command),
           rest.trimmingCharacters(in: .whitespaces) == subcommand,
           (executable as NSString).lastPathComponent == binaryName
        {
            return true
        }
        return namesAnInstalledBinaryUnquoted(command, subcommand: subcommand)
    }

    /// The shape an older `install-hook` wrote for a binary under a directory with a space in it.
    ///
    /// It had no quoting, so the first word is only part of the path. Claimed only when everything before the subcommand is an absolute path to an existing regular file named ``binaryName``, which `/opt/wrap /x/sift` is not.
    private static func namesAnInstalledBinaryUnquoted(_ command: String, subcommand: String) -> Bool {
        guard command.hasSuffix(" " + subcommand), !command.contains(where: { "'\"\\".contains($0) }) else { return false }
        let path = command.dropLast(subcommand.count + 1).trimmingCharacters(in: .whitespaces)
        var isDirectory: ObjCBool = false
        return path.hasPrefix("/")
            && (path as NSString).lastPathComponent == binaryName
            && FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
    }

    /// The first word of `command` with its quoting removed, and everything after it; `nil` for an empty command or an unterminated quote.
    ///
    /// Read by scalar, not by `Character`: a quote followed by a combining mark is one `Character` but still a quote to a shell.
    private static func firstShellWord(of command: String) -> (word: String, rest: String)? {
        let scalars = Array(command.unicodeScalars)
        var word = String.UnicodeScalarView()
        var index = 0
        while index < scalars.count, !Character(scalars[index]).isWhitespace {
            let scalar = scalars[index]
            index += 1
            switch scalar {
            case "'":
                guard let close = scalars[index...].firstIndex(of: "'") else { return nil }
                word.append(contentsOf: scalars[index ..< close])
                index = close + 1
            case "\"":
                var closed = false
                while index < scalars.count, !closed {
                    let inner = scalars[index]
                    index += 1
                    if inner == "\"" {
                        closed = true
                    } else if inner == "\\", index < scalars.count, "\\\"$`".unicodeScalars.contains(scalars[index]) {
                        word.append(scalars[index])
                        index += 1
                    } else {
                        word.append(inner)
                    }
                }
                guard closed else { return nil }
            case "\\":
                guard index < scalars.count else { return nil }
                word.append(scalars[index])
                index += 1
            default:
                word.append(scalar)
            }
        }
        guard !word.isEmpty else { return nil }
        var rest = String.UnicodeScalarView()
        rest.append(contentsOf: scalars[index...])
        return (String(word), String(rest))
    }

    /// `~/.sift` — one directory across every repository, since the usage log, the run log, the roots registry and the salt are all per-user rather than per-repo.
    public static var home: URL {
        home(environment: ProcessInfo.processInfo.environment)
    }

    /// `~/.sift` under the home directory `environment` names, or the directory `SIFT_HOME` names.
    ///
    /// `SIFT_HOME` replaces the whole `~/.sift` directory, so a probe or a worktree run can keep out of the user's roots registry, logs and ledgers without moving `HOME`, which would hide the agent settings too. Honoured only when non-empty and absolute; anything else is unset.
    public static func home(environment: [String: String]) -> URL {
        if let override = environment["SIFT_HOME"], override.hasPrefix("/") {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return userHome(environment: environment).appendingPathComponent(directoryName, isDirectory: true)
    }

    /// The home directory every per-user path is built on: `CFFIXED_USER_HOME`, then `HOME`, each only when it holds an absolute path, and otherwise the account's home.
    ///
    /// Foundation's own lookup of the current user's home reads the account record and ignores `HOME`, so a process run under a moved `HOME` — a probe, a review, a test — would still write into the real `~/.claude` and `~/.sift`. `CFFIXED_USER_HOME` goes first because that API honours it too, and it is the variable this tool already sets to move another build's home.
    public static func userHome(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        for key in ["CFFIXED_USER_HOME", "HOME"] {
            if let value = environment[key], value.hasPrefix("/") {
                return URL(fileURLWithPath: value, isDirectory: true)
            }
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    /// The home the system's own tools use whatever `HOME` says: DerivedData and crash reports land here even under a moved `HOME`.
    public static var accountHome: URL {
        FileManager.default.homeDirectoryForCurrentUser
    }

    /// `~/.sift/callers` — where the `PreToolUse` hook leaves the identity of the context about to make an index call, for the server to stamp onto the log line.
    ///
    /// Per-user like the logs, and for the same reason: one server serves every repository a session touches, and the hook that names the caller has nothing repository-shaped to key on.
    public static var callers: URL {
        home.appendingPathComponent("callers", isDirectory: true)
    }

    /// `~/.claude/settings.json` — the settings file every session on this machine loads, whatever repository it is in.
    ///
    /// Named here rather than rebuilt at each site that needs it, because two of those sites have to agree exactly: `install-hook` writes the registration into this file, and `status` reads it back out of the same one (``RegisteredHooks``). A second copy of the path that drifted would let the check answer about a file the installer never wrote.
    ///
    /// Not under ``home``: this file is Claude Code's, not this tool's. It is named here because it is a path the tool depends on, and every such path is named in one place.
    ///
    /// Resolved through ``claudeDirectory(environment:)``, so a moved `HOME` or a `CLAUDE_CONFIG_DIR` moves it too: `install-hook` rewrites this file, and a probe run under a scratch `HOME` must never reach the live one every session on the machine loads.
    public static var claudeSettings: URL {
        claudeSettings(environment: ProcessInfo.processInfo.environment)
    }

    /// `settings.json` in `CLAUDE_CONFIG_DIR` when `environment` sets it, since Claude Code then reads its settings there, else `~/.claude/settings.json` under the home directory it names.
    public static func claudeSettings(environment: [String: String]) -> URL {
        claudeDirectory(environment: environment).appendingPathComponent("settings.json")
    }

    /// Claude Code's own `.claude.json`, where `claude mcp add --scope user` records a server: in `CLAUDE_CONFIG_DIR` when `environment` sets it, else in the home directory it names.
    public static func claudeConfig(environment: [String: String]) -> URL {
        let directory = claudeConfigDirectory(environment: environment) ?? userHome(environment: environment)
        return directory.appendingPathComponent(".claude.json")
    }

    /// The agent rule the install copies in: `rules/sift.md` in `CLAUDE_CONFIG_DIR` when `environment` sets it, since Claude Code then reads its rules there, else in `~/.claude`.
    public static func claudeRule(environment: [String: String]) -> URL {
        claudeDirectory(environment: environment).appendingPathComponent("rules", isDirectory: true).appendingPathComponent("sift.md")
    }

    /// Claude Code's configuration directory: `CLAUDE_CONFIG_DIR` when `environment` sets it, else `~/.claude` under the home directory it names.
    public static func claudeDirectory(environment: [String: String]) -> URL {
        claudeConfigDirectory(environment: environment)
            ?? userHome(environment: environment).appendingPathComponent(".claude", isDirectory: true)
    }

    /// `CLAUDE_CONFIG_DIR` when `environment` sets it to something, which moves Claude Code's whole configuration directory.
    private static func claudeConfigDirectory(environment: [String: String]) -> URL? {
        guard let value = environment["CLAUDE_CONFIG_DIR"], !value.isEmpty else { return nil }
        return URL(fileURLWithPath: value, isDirectory: true)
    }

    /// `~/.cursor` under the home directory `environment` names — where Cursor keeps its user-level `mcp.json` and `hooks.json`.
    public static func cursorDirectory(environment: [String: String]) -> URL {
        userHome(environment: environment).appendingPathComponent(".cursor", isDirectory: true)
    }

    /// Codex's home as Codex itself finds it: `CODEX_HOME` when `environment` sets it, else `~/.codex` under the home directory it names.
    public static func codexDirectory(environment: [String: String]) -> URL {
        if let codexHome = environment["CODEX_HOME"], !codexHome.isEmpty {
            return URL(fileURLWithPath: codexHome, isDirectory: true)
        }
        return userHome(environment: environment).appendingPathComponent(".codex", isDirectory: true)
    }

    /// `<repoRoot>/.sift` — this repository's index cache, its run logs, and its semantic store.
    public static func cache(in repoRoot: URL) -> URL {
        repoRoot.appendingPathComponent(directoryName, isDirectory: true)
    }

    /// `<repoRoot>/.sift.json` — this repository's configuration file, whether or not it exists.
    public static func config(in repoRoot: URL) -> URL {
        repoRoot.appendingPathComponent(configFileName)
    }
}
