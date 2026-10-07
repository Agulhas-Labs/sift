//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore

/// Whether a build rewritten in place to `sift run -- …` would reach the user as a permission prompt it would not have met as written.
///
/// Claude Code applies a `PreToolUse` hook's `updatedInput` before it checks its permission rules, so the rules are matched against the rewritten command: a `Bash(swift test:*)` allow rule does not cover `sift run -- swift test`. A rewrite that turned a build the user had allowed into a prompt would be worse than the refusal it replaces, so the hook rewrites only where this says no prompt can follow, and refuses with the wrapping as before everywhere else.
///
/// No prompt can follow where the session's permission mode asks nobody (`bypassPermissions`, and `auto`, whose classifier reviews a call in the user's place), or where an allow rule the hook can read covers every wrapped statement. Either way an `ask` or `deny` rule that matches anything the line runs — as written or as wrapped — keeps the rewrite from being made, since Claude Code applies those whatever a hook or a mode says. An allow rule counts only where Claude Code would apply it: a project file's only once the workspace trust dialog was accepted for that project, and nobody's but the managed files' where those set `allowManagedPermissionRulesOnly`.
///
/// The limit is the rules the hook cannot read. One it cannot see that allows only ever withholds a rewrite. One it cannot see that asks or denies — passed on the command line, granted for the session, delivered by an MDM profile, the server or an embedding host — is matched by Claude Code against the rewritten command, so the rewrite can then meet a prompt or a denial it did not foresee, and a deny rule written for the command as the user wrote it does not match the wrapped one.
public struct WrappedRunPermission: Sendable, Equatable {
    /// The `Bash` allow rules' patterns, `*` standing for any text.
    public let allowed: [String]
    /// The `Bash` ask and deny rules' patterns, either of which keeps the refusal.
    public let vetoed: [String]

    public init(allowed: [String], vetoed: [String]) {
        self.allowed = allowed
        self.vetoed = vetoed
    }

    /// The rules of the session the hook serves: its project is the directory Claude Code names in the hook's environment, else `directory`.
    public static func standard(in directory: String?) -> WrappedRunPermission {
        load(project: ProcessInfo.processInfo.environment["CLAUDE_PROJECT_DIR"] ?? directory)
    }

    /// The rules of every settings file Claude Code reads for a session in `project`: the user's, the project's shared and local files, and the machine's managed file with its drop-in directory.
    ///
    /// The shared file is `project`'s own and the local file the repository root's — the main checkout's, in a linked worktree — as Claude Code reads them; ask and deny rules are also taken from both files in `project`, its repository root and the main checkout's root, wherever either one stands.
    ///
    /// The user's files are found as Claude Code finds them, under `CLAUDE_CONFIG_DIR` where `environment` sets it and under `HOME`'s `.claude` otherwise.
    public static func load(
        project: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        managed: String = "/Library/Application Support/ClaudeCode/managed-settings.json"
    ) -> WrappedRunPermission {
        let home = environment["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory()
        let configured = environment["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
        let configHome = configured ?? URL(fileURLWithPath: home).appendingPathComponent(".claude")
        let globalConfig = configured?.appendingPathComponent(".claude.json") ?? URL(fileURLWithPath: home).appendingPathComponent(".claude.json")

        let managedFile = URL(fileURLWithPath: managed)
        let dropIns = managedFile.deletingLastPathComponent().appendingPathComponent("managed-settings.d")
        let dropInFiles = ((try? FileManager.default.contentsOfDirectory(atPath: dropIns.path)) ?? [])
            .filter { $0.hasSuffix(".json") }.sorted().map { dropIns.appendingPathComponent($0) }
        let managedSettings = ([managedFile] + dropInFiles).compactMap(settings(at:))
        // Claude Code reads the shared file from the directory the session started in, and the local one from the
        // repository's root — the main checkout's, in a linked worktree. Allow rules count from exactly those two files;
        // ask and deny rules from both files in every one of those directories, since an extra veto only withholds a rewrite.
        var projectSettings: [[String: Any]] = []
        var vetoingProjectSettings: [[String: Any]] = []
        if let project {
            let roots = repositoryRoots(of: project)
            let localRoot = roots.main ?? roots.top ?? project
            let files = [
                URL(fileURLWithPath: project).appendingPathComponent(".claude/settings.json"),
                URL(fileURLWithPath: localRoot).appendingPathComponent(".claude/settings.local.json"),
            ]
            projectSettings = files.compactMap(settings(at:))
            var seen: Set<String> = []
            let directories = [project, roots.top, roots.main].compactMap(\.self).filter {
                seen.insert(URL(fileURLWithPath: $0).resolvingSymlinksInPath().standardizedFileURL.path).inserted
            }
            vetoingProjectSettings = directories.flatMap { directory in
                ["settings.json", "settings.local.json"].map { URL(fileURLWithPath: directory).appendingPathComponent(".claude/\($0)") }
            }.compactMap(settings(at:))
        }
        let userSettings = [configHome.appendingPathComponent("settings.json")].compactMap(settings(at:))

        let managedOnly = managedSettings.contains { $0["allowManagedPermissionRulesOnly"] as? Bool == true }
        let trusted = project.map { isTrusted($0, config: globalConfig) } ?? false
        let allowSources = managedOnly ? managedSettings : userSettings + managedSettings + (trusted ? projectSettings : [])
        let allowed = allowSources.flatMap { patterns(in: permissions(of: $0)["allow"]) }
        let vetoed = (userSettings + managedSettings + vetoingProjectSettings).flatMap { settings in
            let permissions = permissions(of: settings)
            return patterns(in: permissions["ask"], toolGlobs: true) + patterns(in: permissions["deny"], toolGlobs: true)
        }
        return WrappedRunPermission(allowed: allowed, vetoed: vetoed)
    }

    /// Whether running every one of `legs` — each a statement as the rewrite leaves it, `sift run -- ` in front — can reach the user as a prompt in a session in permission mode `mode`.
    public func addsNoPrompt(legs: [String], mode: String?) -> Bool {
        guard !legs.isEmpty, !legs.contains(where: vetoes(statement:)) else {
            return false
        }
        if mode == "bypassPermissions" || mode == "auto" {
            return true
        }
        return legs.allSatisfy { leg in allowed.contains { Self.matches(leg, pattern: $0) } }
    }

    /// Whether the four read-only lookups run from Bash without a prompt: each is allowed by a rule, and no ask or deny rule matches one.
    ///
    /// No permission mode is consulted, because the only reader is the session primer and Claude Code's SessionStart and SubagentStart payloads carry no `permission_mode` (probed on 2.1.291).
    public func allowsLookups() -> Bool {
        LookupAllowRules.statements.allSatisfy { addsNoPrompt(legs: [$0], mode: nil) }
    }

    /// Whether an ask or deny rule matches anything `line` runs as written: any statement or pipeline stage of it, a command substitution's included.
    ///
    /// Such a rule is the user's own say over that command, so the hook neither rewrites the line nor names another form of it to run in its place, which the rule, written for the command as the user writes it, would not match.
    public func vetoes(line: String) -> Bool {
        !vetoed.isEmpty && ShellSyntax.executedSegments(of: line).contains(where: vetoes(statement:))
    }

    /// Whether an ask or deny rule matches `statement` in any of the forms Claude Code matches it in.
    func vetoes(statement: String) -> Bool {
        Self.forms(of: statement).contains { form in vetoed.contains { Self.matches(form, pattern: $0) } }
    }

    /// The forms of `statement` an ask or deny rule is matched against: as written, past its leading variable assignments and the wrappers Claude Code strips, and each of those with its redirections set aside as well.
    static func forms(of statement: String) -> Set<String> {
        let written = statement.trimmingCharacters(in: .whitespacesAndNewlines)
        let inner = withoutGroupPunctuation(written)
        return inner == written ? forms(ofTrimmed: written) : forms(ofTrimmed: written).union(forms(ofTrimmed: inner))
    }

    /// `statement`, already trimmed, in the forms ``forms(of:)`` describes, without the group punctuation set aside.
    private static func forms(ofTrimmed written: String) -> Set<String> {
        var stages = [ShellSyntax.tokens(of: written, stripQuotes: false)]
        while let last = stages.last, let stripped = strippingPrefix(of: last), !stripped.isEmpty {
            stages.append(stripped)
        }
        var forms: Set<String> = [written]
        for words in stages {
            forms.insert(words.joined(separator: " "))
            forms.insert(withoutRedirections(words).joined(separator: " "))
        }
        return forms
    }

    /// `statement` without the punctuation and keywords a subshell, brace group, loop or conditional puts around its command — a leading `(`, `{`, `!`, `do`, `then`, `else`, `elif`, `if`, `while` or `until` and a trailing `)`, `}` or `;` — so the command inside is judged as it would be alone.
    ///
    /// Over-reading is the safe side: a form made of what a rule never sees only makes the hook stand aside more often.
    private static func withoutGroupPunctuation(_ statement: String) -> String {
        let openers: Set = ["!", "do", "then", "else", "elif", "if", "while", "until"]
        var text = statement
        while true {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let first = trimmed.first, first == "(" || first == "{" {
                text = String(trimmed.dropFirst())
            } else if let word = trimmed.split(whereSeparator: \.isWhitespace).first, openers.contains(String(word)) {
                text = String(trimmed.dropFirst(word.count))
            } else if let last = trimmed.last, last == ")" || last == "}" || last == ";" {
                text = String(trimmed.dropLast())
            } else {
                return trimmed
            }
        }
    }

    /// `words` past one leading variable assignment or one wrapper that runs the rest as its command, or `nil` where they open on neither.
    private static func strippingPrefix(of words: [String]) -> [String]? {
        guard let first = words.first else { return nil }
        if first.range(of: #"^[A-Za-z_][A-Za-z0-9_]*="#, options: .regularExpression) != nil {
            return Array(words.dropFirst())
        }
        let rest = Array(words.dropFirst())
        switch first {
        case "nohup", "builtin", "noglob":
            return rest
        case "command", "xargs":
            return rest.first?.hasPrefix("-") == true ? nil : rest
        case "time":
            return rest.first == "-p" ? Array(rest.dropFirst()) : rest
        case "nice":
            return Array(rest.dropFirst(rest.first == "-n" ? 2 : rest.first?.hasPrefix("-") == true ? 1 : 0))
        case "timeout", "stdbuf":
            var index = 0
            while index < rest.count, rest[index].hasPrefix("-") {
                index += ["-s", "-k", "--signal", "--kill-after", "-i", "-o", "-e"].contains(rest[index]) ? 2 : 1
            }
            return Array(rest.dropFirst(first == "timeout" ? index + 1 : index))
        default:
            return nil
        }
    }

    /// `words` with every redirection taken out, the operator and its target both, whether written apart (`> log`) or together (`2>&1`).
    private static func withoutRedirections(_ words: [String]) -> [String] {
        var kept: [String] = []
        var index = 0
        while index < words.count {
            let word = words[index]
            let operatorStart = word.drop { $0.isNumber }
            guard operatorStart.hasPrefix(">") || operatorStart.hasPrefix("<") || operatorStart.hasPrefix("&>") else {
                kept.append(word)
                index += 1
                continue
            }
            let target = operatorStart.drop { "<>&|".contains($0) }
            index += target.isEmpty ? 2 : 1
        }
        return kept
    }

    /// Whether the workspace trust dialog was accepted for `project`, as Claude Code records it in `config`; a record that cannot be read is no trust.
    private static func isTrusted(_ project: String, config: URL) -> Bool {
        guard let settings = settings(at: config), let projects = settings["projects"] as? [String: Any] else { return false }
        let standardized = URL(fileURLWithPath: project).standardizedFileURL.path
        return [project, standardized].contains { ((projects[$0] as? [String: Any])?["hasTrustDialogAccepted"] as? Bool) == true }
    }

    /// The root of the git working tree `project` is in, and the main checkout's root where that tree's repository keeps its common directory at `<root>/.git`; both `nil` outside a repository.
    ///
    /// One `git rev-parse`, run only when a build is on the line: the root is where Claude Code reads `settings.local.json` for a session started below it, and the main checkout's is where it reads it for a linked worktree.
    private static func repositoryRoots(of project: String) -> (top: String?, main: String?) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ProcessEnvironment.gitHardening + ["rev-parse", "--path-format=absolute", "--show-toplevel", "--git-common-dir"]
        process.currentDirectoryURL = URL(fileURLWithPath: project)
        process.environment = ProcessEnvironment.withoutGit()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        let watch = ChildDeadline.Watch(process, within: ChildDeadline.git)
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            ProcessStreams.abandon(stdout, stderr)
            return (nil, nil)
        }
        watch.arm()
        guard let (data, _) = watch.collect(stdout: stdout, stderr: stderr, exited: exited) else { return (nil, nil) }
        let lines = String(data: data, encoding: .utf8)?.split(separator: "\n").map(String.init) ?? []
        guard process.terminationStatus == 0, lines.count == 2 else { return (nil, nil) }
        let common = URL(fileURLWithPath: lines[1])
        return (lines[0], common.lastPathComponent == ".git" ? common.deletingLastPathComponent().path : nil)
    }

    /// The JSON object in the file at `url`, or `nil` where there is none.
    private static func settings(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url), !hasTrailingComma(data) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// Whether `data` has a comma with nothing but whitespace between it and the `}` or `]` closing its container.
    ///
    /// Foundation reads such JSON, but Claude Code documents it as a syntax error and skips the file, so a rule counted from it may never apply.
    private static func hasTrailingComma(_ data: Data) -> Bool {
        var inString = false
        var escaped = false
        var pendingComma = false
        for byte in data {
            if inString {
                if escaped {
                    escaped = false
                } else if byte == UInt8(ascii: "\\") {
                    escaped = true
                } else if byte == UInt8(ascii: "\"") {
                    inString = false
                }
                continue
            }
            switch byte {
            case UInt8(ascii: " "), UInt8(ascii: "\t"), UInt8(ascii: "\n"), UInt8(ascii: "\r"):
                continue
            case UInt8(ascii: "}"), UInt8(ascii: "]"):
                if pendingComma {
                    return true
                }
            case UInt8(ascii: "\""):
                inString = true
            default:
                break
            }
            pendingComma = byte == UInt8(ascii: ",")
        }
        return false
    }

    /// The `permissions` object of `settings`, empty where it has none.
    private static func permissions(of settings: [String: Any]) -> [String: Any] {
        settings["permissions"] as? [String: Any] ?? [:]
    }

    /// The patterns of the `Bash` rules in `rules`: a bare `Bash` is every command, and the legacy `prefix:*` is the prefix alone or followed by a space and anything.
    ///
    /// For ask and deny rules, a tool-name glob that matches `Bash` — `*`, say — is every command too; Claude Code skips such a glob in an allow rule.
    static func patterns(in rules: Any?, toolGlobs: Bool = false) -> [String] {
        (rules as? [String] ?? []).flatMap { rule -> [String] in
            let rule = rule.trimmingCharacters(in: .whitespaces)
            if rule == "Bash" || (toolGlobs && !rule.contains("(") && rule.contains("*") && matches("Bash", pattern: rule)) {
                return ["*"]
            }
            guard rule.hasPrefix("Bash("), rule.hasSuffix(")") else { return [] }
            let body = String(rule.dropFirst("Bash(".count).dropLast())
            guard body.hasSuffix(":*") else { return [body] }
            let prefix = String(body.dropLast(2))
            return [prefix, prefix + " *"]
        }
    }

    /// Whether `command` matches `pattern` whole, each `*` standing for any run of characters, none included.
    ///
    /// A pattern whose one wildcard is a trailing ` *` also matches the command before it bare, as Claude Code's own `Bash(ls *)` matches `ls`.
    static func matches(_ command: String, pattern: String) -> Bool {
        if pattern.hasSuffix(" *"), pattern.filter({ $0 == "*" }).count == 1, command == String(pattern.dropLast(2)) {
            return true
        }
        let text = Array(command)
        let parts = pattern.split(separator: "*", omittingEmptySubsequences: false).map(Array.init)
        guard let first = parts.first, text.starts(with: first) else { return false }
        guard parts.count > 1 else { return text.count == first.count }
        var cursor = first.count
        for part in parts.dropFirst().dropLast() {
            guard let found = firstIndex(of: part, in: text, from: cursor) else { return false }
            cursor = found + part.count
        }
        let last = parts[parts.count - 1]
        return text.count - cursor >= last.count && text.suffix(last.count).elementsEqual(last)
    }

    /// Where `part` first occurs in `text` at or after `start`.
    private static func firstIndex(of part: [Character], in text: [Character], from start: Int) -> Int? {
        guard !part.isEmpty else { return start }
        guard text.count >= part.count else { return nil }
        var index = start
        while index + part.count <= text.count {
            if text[index ..< index + part.count].elementsEqual(part) {
                return index
            }
            index += 1
        }
        return nil
    }
}
