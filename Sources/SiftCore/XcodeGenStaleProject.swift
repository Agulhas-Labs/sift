//
// Copyright © Agulhas Labs
//

import Foundation

/// The note a `sift run` of `xcodebuild` owes when the generated project it reads predates a Swift file its XcodeGen spec holds.
///
/// A gitignored `.xcodeproj` is only as current as the last `xcodegen generate`, and a build or test of a stale one runs fewer files' worth of code without any error. The property checked is "the project lists the files its spec holds", never a modification time, which a checkout rewrites. It is a note and never a verdict: every failure to read anything yields no line.
public struct XcodeGenStaleProject {
    private init() {}

    /// The most files a spec's sources may hold before the check is skipped, which keeps its cost bounded.
    static let fileLimit = 5000

    /// ``line(for:from:repositoryRoot:)`` as the lines a run prints: none, or the one.
    public static func lines(for arguments: [String], from directory: String, repositoryRoot: URL) -> [String] {
        line(for: arguments, from: directory, repositoryRoot: repositoryRoot).map { [$0] } ?? []
    }

    /// The one-line note for a run of `arguments` from `directory`, or `nil` when nothing is stale or anything could not be read.
    ///
    /// Only an `xcodebuild` build or test is checked. A `-workspace` is not resolved, and without a `-project` the one `.xcodeproj` in the built directory is read.
    public static func line(for arguments: [String], from directory: String, repositoryRoot: URL) -> String? {
        guard RunCommandKind.recognize(arguments) == .xcodebuild, RunCommandKind.buildsOrTests(arguments) else { return nil }
        guard !arguments.contains("-workspace"), !arguments.contains(where: { $0.hasPrefix("-workspace=") }) else { return nil }
        guard let built = RunCommandKind.builtDirectory(of: arguments, from: directory) else { return nil }
        let builtURL = URL(fileURLWithPath: built, isDirectory: true)
        let project: URL
        if let named = arguments.firstIndex(of: "-project"), named + 1 < arguments.count {
            project = builtURL.appendingPathComponent((arguments[named + 1] as NSString).lastPathComponent)
        } else {
            let entries = (try? FileManager.default.contentsOfDirectory(atPath: built)) ?? []
            let projects = entries.filter { $0.hasSuffix(".xcodeproj") }
            guard projects.count == 1, let only = projects.first else { return nil }
            project = builtURL.appendingPathComponent(only)
        }
        return line(project: project, repositoryRoot: repositoryRoot)
    }

    /// The note for `project` (an `.xcodeproj` directory) against the `project.yml` beside it, or `nil` when the project lists every Swift file the spec holds.
    public static func line(project: URL, repositoryRoot: URL) -> String? {
        let spec = project.deletingLastPathComponent().appendingPathComponent("project.yml")
        guard project.pathExtension == "xcodeproj",
              let text = try? String(contentsOf: spec, encoding: .utf8),
              case let .spec(targets, _) = XcodeGenSpec.read(at: spec, text: text),
              let pbxproj = try? String(contentsOf: project.appendingPathComponent("project.pbxproj"), encoding: .utf8),
              let held = swiftFiles(of: targets, fromRepositoryRoot: readsFromRepositoryRoot(targets), repositoryRoot: repositoryRoot)
        else { return nil }
        let referenced = referencedNames(in: pbxproj)
        let missing = Set(held.map(\.lastPathComponent)).subtracting(referenced).sorted()
        guard !missing.isEmpty else { return nil }
        let noun = missing.count == 1 ? "file" : "files"
        // The style of `RunInventoryCheck.listing`, which is private to that file.
        let shown = missing.prefix(RunInventoryCheck.listedNames)
        let rest = missing.count - shown.count
        let listed = shown.joined(separator: ", ") + (rest > 0 ? ", +\(rest) more" : "")
        return "project: \(relative(project, to: repositoryRoot)) does not list \(missing.count) Swift \(noun) its spec \(relative(spec, to: repositoryRoot)) holds (\(listed)) — run xcodegen generate"
    }

    /// Whether the spec's sources are read against the repository root rather than the directory each was declared in.
    ///
    /// XcodeGen reads them against `--project-root`, which defaults to the spec's directory but is often the repository's root (`xcodegen generate --spec Apps/project.yml --project-root .`), and the spec does not say which. So, as ``ModuleResolver`` elects the base for the same spec, the spec's directory is taken where any target's source exists below it, and the repository root otherwise.
    private static func readsFromRepositoryRoot(_ targets: [XcodeGenSpec.Target]) -> Bool {
        !targets.contains { target in
            target.sources.contains { FileManager.default.fileExists(atPath: target.declaringDirectory.appendingPathComponent($0.path).path) }
        }
    }

    /// Every `.swift` file under the targets' `sources`, or `nil` where the walk passes ``fileLimit``.
    ///
    /// A source is read against the directory its spec was declared in, or against `repositoryRoot` where the spec's sources are written from there, and a `Source.excludes` entry is a glob against the path below that source.
    private static func swiftFiles(of targets: [XcodeGenSpec.Target], fromRepositoryRoot: Bool, repositoryRoot: URL) -> [URL]? {
        var found: [URL] = []
        var visited = 0
        for target in targets {
            for source in target.sources {
                let root = (fromRepositoryRoot ? repositoryRoot : target.declaringDirectory).appendingPathComponent(source.path).standardizedFileURL
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory) else { continue }
                guard isDirectory.boolValue else {
                    if root.pathExtension == "swift" {
                        found.append(root)
                    }
                    continue
                }
                // A folder reference and an Xcode 16 synchronized folder are each one entry in the project, never a list of its files.
                if source.type == "folder" || source.type == "syncedFolder" {
                    continue
                }
                let excludes = source.excludes.compactMap(glob)
                let includes = source.includes.compactMap(glob)
                guard let walk = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { continue }
                for case let file as URL in walk {
                    visited += 1
                    if visited > fileLimit {
                        return nil
                    }
                    if (try? file.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                        if singleReferenceExtensions.contains(file.pathExtension) {
                            walk.skipDescendants()
                        }
                        continue
                    }
                    guard file.pathExtension == "swift" else { continue }
                    let below = String(file.standardizedFileURL.path.dropFirst(root.path.count + 1))
                    let wanted = includes.isEmpty || includes.contains { matches($0, below) }
                    if wanted, !excludes.contains(where: { matches($0, below) }) {
                        found.append(file)
                    }
                }
            }
        }
        return found
    }

    /// The directory extensions XcodeGen adds as one reference, so nothing below one is a source of its own.
    private static let singleReferenceExtensions: Set<String> = ["playground", "docc", "xcassets", "bundle", "framework", "xcframework", "xcdatamodeld", "xcstrings", "app", "appex"]

    /// The file names a `project.pbxproj` references: the last path component of each `path = …;` and `name = …;` value, quoted or bare.
    private static func referencedNames(in pbxproj: String) -> Set<String> {
        guard let pattern = try? NSRegularExpression(pattern: #"\b(?:path|name) = (?:"((?:[^"\\]|\\.)*)"|([^;\s"]+));"#) else { return [] }
        let text = pbxproj as NSString
        var names: Set<String> = []
        pattern.enumerateMatches(in: pbxproj, range: NSRange(location: 0, length: text.length)) { match, _, _ in
            guard let match else { return }
            let range = match.range(at: 1).location != NSNotFound ? match.range(at: 1) : match.range(at: 2)
            let value = text.substring(with: range)
            names.insert(value.split(separator: "/").last.map(String.init) ?? value)
        }
        return names
    }

    /// `pattern` as a regular expression with XcodeGen's globbing: `**/` spans zero or more directories, and `*` and `?` stay within one path segment.
    private static func glob(_ pattern: String) -> NSRegularExpression? {
        var expression = "^"
        var characters = Substring(pattern)
        if characters.hasPrefix("./") {
            characters = characters.dropFirst(2)
        }
        // `Generated/` names the directory, which `matches` takes in by its path.
        while characters.count > 1, characters.hasSuffix("/") {
            characters = characters.dropLast()
        }
        while let character = characters.first {
            characters = characters.dropFirst()
            switch character {
            case "*" where characters.first == "*":
                characters = characters.drop { $0 == "*" }
                if characters.first == "/" {
                    characters = characters.dropFirst()
                    expression += "(?:.*/)?"
                } else {
                    expression += ".*"
                }
            case "*": expression += "[^/]*"
            case "?": expression += "[^/]"
            case "[" where characters.contains("]"):
                // A bracket class, `[mh]` or `[0-2]` or `[!a]`, as XcodeGen's own examples write them.
                let body = characters.prefix { $0 != "]" }
                characters = characters.dropFirst(body.count + 1)
                let negated = body.first == "!" || body.first == "^"
                let members = (negated ? body.dropFirst() : body).replacingOccurrences(of: "\\", with: "\\\\")
                expression += "[" + (negated ? "^/" : "") + members + "]"
            default: expression += NSRegularExpression.escapedPattern(for: String(character))
            }
        }
        return try? NSRegularExpression(pattern: expression + "$")
    }

    /// Whether `glob` matches `path` or a directory above it, since a glob naming a directory takes in everything below.
    private static func matches(_ glob: NSRegularExpression, _ path: String) -> Bool {
        var prefix = ""
        for component in path.split(separator: "/") {
            prefix += (prefix.isEmpty ? "" : "/") + component
            if glob.firstMatch(in: prefix, range: NSRange(location: 0, length: (prefix as NSString).length)) != nil {
                return true
            }
        }
        return false
    }

    /// `url`'s path below `root`, or the whole path where it is not below it.
    private static func relative(_ url: URL, to root: URL) -> String {
        let path = url.standardizedFileURL.path
        let base = root.standardizedFileURL.path
        return path.hasPrefix(base + "/") ? String(path.dropFirst(base.count + 1)) : path
    }
}
