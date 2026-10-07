//
// Copyright © Agulhas Labs
//

import Foundation

/// One compiler or linker diagnostic, carried as the toolchain wrote it.
///
/// The message is never rephrased and never summarised: an agent acts on the compiler's own words, and a paraphrase of an error is a second thing that can be wrong.
public struct RunDiagnostic: Sendable {
    public let severity: Severity
    public let path: String?
    public let line: Int?
    public let column: Int?
    public let message: String
    /// Lines that belong to this diagnostic and mean nothing without it — the symbol list under an `Undefined symbols` header.
    public let detail: [String]
    /// The source line a diagnostic raised inside a macro's expansion sits at, read from the compiler's note beneath it — `nil` for every other diagnostic, and for one whose note never arrived.
    public let expansion: ExpansionSite?

    public init(
        severity: Severity,
        path: String? = nil,
        line: Int? = nil,
        column: Int? = nil,
        message: String,
        detail: [String] = [],
        expansion: ExpansionSite? = nil
    ) {
        self.severity = severity
        self.path = path
        self.line = line
        self.column = column
        self.message = message
        self.detail = detail
        self.expansion = expansion
    }
}

public extension RunDiagnostic {
    enum Severity: String, Sendable {
        case error
        case warning
    }

    /// Where in a source file a macro expansion stands: the file and the line the compiler's `in expansion of macro … here` or `expanded code originates here` note names.
    ///
    /// The line alone, without the column, because the two diagnostic styles point at different columns of the same line — the default style at the expansion's end (`WidgetTests.swift:7:49`), `-diagnostic-style=llvm` at its `#` (`:7:25`) — and the line is what a reader opens.
    struct ExpansionSite: Hashable, Sendable {
        public let path: String
        public let line: Int

        public init(path: String, line: Int) {
            self.path = path
            self.line = line
        }
    }

    /// What makes two diagnostics the same one reported twice.
    ///
    /// `detail` is deliberately outside it: xcodebuild reports a compile error once per build phase that touched the file, and those copies must collapse to one. `expansion` is inside it: every `#require` in a file expands to a buffer named `macro expansion #require`, so two different ones failing the same way print the same location and the same message, and only the source line each expansion sits at tells them apart.
    struct Identity: Hashable, Sendable {
        public let path: String?
        public let line: Int?
        public let column: Int?
        public let message: String
        public let expansion: ExpansionSite?
    }

    var identity: Identity {
        Identity(path: path, line: line, column: column, message: message, expansion: expansion)
    }

    /// Whether this is no compiler diagnostic but an XCTest assertion failing, which XCTest prints in the compiler's shape: `File.swift:10: error: -[Suite testName] : XCTAssertEqual failed: …`.
    var isXCTestAssertion: Bool {
        severity == .error && message.hasPrefix("-[") && message.contains("] : ")
    }

    /// This diagnostic in the compiler's own `file:line:col: severity: message` form, followed by the source line its macro expansion sits at where it was raised inside one.
    ///
    /// A linker block keeps its own header wording instead: `Undefined symbols for architecture arm64:` is the linker's whole sentence, and prefixing it with a severity it never printed would be this answer putting words in its mouth. The path is stated exactly as it arrives — making it relative to the reader is the renderer's job, not the diagnostic's.
    var described: String {
        compilerLine + expansionNote
    }

    /// ``described`` without the expansion site: the compiler's own line, which is the part a clip may shorten.
    var compilerLine: String {
        if path == nil, !detail.isEmpty {
            return message
        }
        var location = ""
        if let path {
            location = path
            if let line {
                location += ":\(line)"
                if let column {
                    location += ":\(column)"
                }
            }
            location += ": "
        }
        return "\(location)\(severity.rawValue): \(message)"
    }

    /// ` (expanded at Tests/WidgetTests.swift:7)` for a diagnostic raised inside a macro expansion whose source line is known, and nothing otherwise.
    ///
    /// **Why it is needed.** Inside an expansion the compiler locates a diagnostic in the expansion's own buffer — `macro expansion #require:1:66`, or a generated `@__swiftmacro_….swift` — which names no file a reader can open; the source line is printed only in the note beneath. Kept apart from the message so the compiler's sentence stays its own and a signature still groups on it.
    var expansionNote: String {
        guard let expansion else {
            return ""
        }
        return " (expanded at \(expansion.path):\(expansion.line))"
    }

    /// The same diagnostic carrying `detail` as its continuation lines.
    func appending(detail extra: [String]) -> RunDiagnostic {
        RunDiagnostic(
            severity: severity,
            path: path,
            line: line,
            column: column,
            message: message,
            detail: detail + extra,
            expansion: expansion
        )
    }

    /// The same diagnostic, raised inside the macro expansion that sits at `site`.
    func expanded(at site: ExpansionSite) -> RunDiagnostic {
        RunDiagnostic(
            severity: severity,
            path: path,
            line: line,
            column: column,
            message: message,
            detail: detail,
            expansion: site
        )
    }

    /// Whether this diagnostic is located in a macro expansion's buffer rather than in a source file.
    var isInMacroExpansion: Bool {
        path.map(Self.isMacroExpansionBuffer) ?? false
    }

    /// The source file this diagnostic is about: the file its macro expansion sits in where it was raised inside one whose site is known, its own path otherwise.
    ///
    /// What counts files and asks whether a file holds tests reads this, never ``path``: a buffer such as `macro expansion #require` is not a file, and every `#require` in every file shares its name. The compiler's own location stays ``path``, as printed.
    var sourcePath: String? {
        expansion?.path ?? path
    }

    /// Whether `path` names a macro expansion's buffer: `macro expansion #require` in the compiler's default diagnostic style, a generated `@__swiftmacro_….swift` file under `-diagnostic-style=llvm`.
    static func isMacroExpansionBuffer(_ path: String) -> Bool {
        path.hasPrefix("macro expansion ") || URL(fileURLWithPath: path).lastPathComponent.hasPrefix("@__swiftmacro_")
    }

    /// The location a compiler note about a macro expansion names, or `nil` when `raw` is not one.
    ///
    /// Two wordings, one per diagnostic style, captured from Swift 6.4: the default style prints ``- <file>:7:49: note: expanded code originates here`` directly beneath the error, naming the outermost source line however deeply the expansion nests; `-diagnostic-style=llvm` prints `<location>: note: in expansion of macro 'require' here` once per level, innermost first, so a nested expansion's first note names another expansion's buffer and a later one the source file. The same `in expansion of macro` wording also appears inside the default style's indented source excerpt, with no location — an indented line is never read here.
    static func expansionSite(inNote raw: String) -> ExpansionSite? {
        let text = raw.hasPrefix("`- ") ? String(raw.dropFirst(3)) : raw
        guard let first = text.first, !first.isWhitespace,
              let match = text.wholeMatch(of: #/(.+?):(\d+):\d+: note: (.+)/#),
              let line = Int(match.2)
        else {
            return nil
        }
        let message = match.3.trimmingCharacters(in: .whitespaces)
        guard message == "expanded code originates here" || message.hasPrefix("in expansion of macro ") else {
            return nil
        }
        return ExpansionSite(path: String(match.1), line: line)
    }

    /// Executables allowed to name themselves where a file path would otherwise stand.
    ///
    /// Without this list `ld: warning: …` and `clang: error: linker command failed` would be dropped as unlocated noise; with anything wider, a timestamped tool log line reads as a diagnostic.
    ///
    /// `xcrun` earns its place for the same reason the bare-path shape does: it is how a toolchain that cannot find the utility it was asked for says so (`xcrun: error: unable to find utility "xctest"`), and with no `/` and no `.` in the name it is neither a tool nor a path, so without this the run would fail with nothing in the answer explaining why.
    private static let toolNames: Set<String> = [
        "ld", "clang", "clang++", "swift", "swiftc", "swift-frontend", "codesign", "xcodebuild", "xcrun",
    ]

    /// The diagnostic `raw` states, or `nil` when the line is not one.
    static func parse(_ raw: String) -> RunDiagnostic? {
        // An indented line is part of a command dump or a source snippet, never the diagnostic header itself.
        guard let first = raw.first, !first.isWhitespace else {
            return nil
        }
        guard let parts = split(raw) else {
            return nil
        }
        guard let location = parseLocation(parts.prefix) else {
            return nil
        }
        if parts.prefix.isEmpty, let stated = locatedInMessage(parts.message, severity: parts.severity) {
            return stated
        }
        guard !(parts.prefix.isEmpty && namesAFailedSubcommand(parts.message)) else {
            return nil
        }
        return RunDiagnostic(
            severity: parts.severity,
            path: location.path,
            line: location.line,
            column: location.column,
            message: parts.message
        )
    }

    /// A diagnostic line cut at its severity marker: everything standing before the marker, and the message after it.
    private struct Split {
        let severity: Severity
        let prefix: String
        let message: String
    }

    /// The earliest severity marker found so far, and how many characters its spelling occupies.
    private struct Marker {
        let severity: Severity
        let index: String.Index
        let length: Int
    }

    /// Splits `raw` at whichever severity marker comes first, so a message that itself mentions an error cannot re-split the line.
    private static func split(_ raw: String) -> Split? {
        var best: Marker?
        for severity in [Severity.error, Severity.warning] {
            let candidate: (String.Index, Int)? = if raw.hasPrefix("\(severity.rawValue): ") {
                (raw.startIndex, severity.rawValue.count + 2)
            } else if let found = raw.range(of: ": \(severity.rawValue): ") {
                (found.lowerBound, severity.rawValue.count + 4)
            } else {
                nil
            }
            guard let (index, length) = candidate else {
                continue
            }
            if let current = best, current.index <= index {
                continue
            }
            best = Marker(severity: severity, index: index, length: length)
        }
        guard let best else {
            return nil
        }
        let prefix = String(raw[raw.startIndex ..< best.index])
        let messageStart = raw.index(best.index, offsetBy: best.length)
        let message = withoutFixItDump(String(raw[messageStart...])).trimmingCharacters(in: .whitespaces)
        guard !message.isEmpty else {
            return nil
        }
        return Split(severity: best.severity, prefix: prefix, message: message)
    }

    /// The opening of every fix-it SwiftPM's build system appends to a compiler message as a Swift struct dump.
    private static var fixItDumpOpening: String {
        ": FixIt(sourceRange: "
    }

    /// `message` without the fix-it SwiftPM 6.4 appends to it as a struct dump: `expected 'func' keyword in instance method declaration: FixIt(sourceRange: …)` reads as `expected 'func' keyword in instance method declaration`.
    ///
    /// The dump runs to the end of the line, one per fix-it, so everything from the first opening on is cut, and only where the text has the dump's own shape — the opening, then the qualified name of its source-range type and `(path: ` — and the line closes it: a message that merely mentions a fix-it keeps its text, and so does an XCTest failure quoting one (`XCTAssertEqual failed: ("note: FixIt(sourceRange: here)")`). The dump restates the location the diagnostic already carries and an edit the message already names, in a form no reader asked for.
    static func withoutFixItDump(_ message: String) -> String {
        guard message.hasSuffix(")") else {
            return message
        }
        var searchStart = message.startIndex
        while let opening = message.range(of: fixItDumpOpening, range: searchStart ..< message.endIndex) {
            if opensSourceRange(message[opening.upperBound...]) {
                return String(message[..<opening.lowerBound])
            }
            searchStart = opening.upperBound
        }
        return message
    }

    /// Whether `text` starts with the dump's source range: a dot-qualified type name ending `Range`, then `(path: `, as the 6.4 capture fixture spells it.
    private static func opensSourceRange(_ text: Substring) -> Bool {
        guard let parenthesis = text.firstIndex(of: "(") else {
            return false
        }
        let typeName = text[..<parenthesis]
        let isQualifiedName = typeName.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." }
        return isQualifiedName && typeName.hasSuffix("Range") && text[parenthesis...].hasPrefix("(path: ")
    }

    /// Where a diagnostic says it happened.
    ///
    /// Every part is optional because a line may spell none of them — an unlocated `error:`, or a tool naming itself.
    private struct Location {
        let path: String?
        let line: Int?
        let column: Int?
    }

    /// Reads `path:line:col`, `path:line`, an empty prefix, or a bare tool name — and rejects everything else.
    private static func parseLocation(_ prefix: String) -> Location? {
        if prefix.isEmpty {
            return Location(path: nil, line: nil, column: nil)
        }
        var components = prefix.components(separatedBy: ":")
        var column: Int?
        var line: Int?
        if components.count >= 3, let last = Int(components[components.count - 1]), let penultimate = Int(components[components.count - 2]) {
            column = last
            line = penultimate
            components.removeLast(2)
        } else if components.count >= 2, let last = Int(components[components.count - 1]) {
            line = last
            components.removeLast()
        } else {
            // No line number. Two shapes still locate a diagnostic: a tool naming itself (`ld:`, `clang:`),
            // where the tool is the last colon-separated field; and a bare path, which is how xcodebuild
            // reports a project-level failure — signing, provisioning, `Multiple commands produce`. Dropping
            // the second would leave a signing-only failure with no cause in the answer at all.
            if let tail = components.last?.trimmingCharacters(in: .whitespaces), toolNames.contains(tail) {
                return Location(path: nil, line: nil, column: nil)
            }
            guard looksLikePath(prefix) else {
                return nil
            }
            return Location(path: prefix, line: nil, column: nil)
        }
        let path = components.joined(separator: ":")
        guard !path.isEmpty else {
            return nil
        }
        return Location(path: path, line: line, column: column)
    }

    /// The diagnostic an unlocated line states when its message opens on the location — how SwiftPM's build system reports a compiler error, `error: /path/T.swift:3:8 unable to resolve module dependency: 'Sidecar'` (captured from `swift test` under Swift 6.4), with the location after the marker and a space, not a colon, before the message.
    ///
    /// Only that shape — an absolute path, a line and a column — so a message that happens to open on numbers and colons is never read as a location.
    private static func locatedInMessage(_ message: String, severity: Severity) -> RunDiagnostic? {
        guard let match = message.wholeMatch(of: #/(\/.+?):(\d+):(\d+) (.+)/#), let line = Int(match.2), let column = Int(match.3) else {
            return nil
        }
        return RunDiagnostic(severity: severity, path: String(match.1), line: line, column: column, message: String(match.4))
    }

    /// Whether an unlocated line is the build system reporting that one of its own subcommands exited nonzero, or that the build itself failed, rather than a diagnostic of its own.
    ///
    /// **`error: emit-module command failed with exit code 1 (use -v to see invocation)` is the driver's exit status, spelled as an error.** It names no file, quotes no source and adds nothing the errors above it have not already said — the subcommand that failed is exactly the one that printed them — so on a build with eight distinct errors it would be a ninth, and would take one of the five slots a shape has to illustrate them with. The exit code it reports is already the caller's: `run` passes it through untouched.
    ///
    /// **It is read on the message and only where the prefix named nothing**, which is what keeps it narrower than "drop anything without a path". `clang: error: linker command failed with exit code 1 (use -v to see invocation)` is the same sentence — it is where the shape comes from — and it stays, because `clang` naming itself *is* a location by ``toolNames``'s rule and that line is the real report of a link failure. Deciding on the message alone would have taken both.
    ///
    /// The shape is one bare word, then the fixed sentence, then a number: `emit-module`, `compile`, `link`. A word with a space in it is a sentence that happens to end this way rather than a subcommand, and a tail that does not open on a digit is not an exit code — both are cheap, and the cost of being wrong here is a dropped diagnostic, which is the failure this whole parser is built to avoid.
    ///
    /// **A second, subcommand-less shape says the same thing under `xcodebuild -quiet`.** `error: the following command failed with exit code 0 but produced no further output` precedes the real diagnostic on a captured `-quiet` build that has one — this is `-quiet`'s own heuristic flagging a subcommand it thinks looked wrong, not a diagnostic the subcommand wrote, and the exit code it quotes can be `0`, which is never a failure by itself. It names no file and quotes no source, exactly like the bare-word shape above, so it is dropped the same way and for the same reason; where the build genuinely failed, the real error sits on the very next line and is unaffected.
    ///
    /// **A third shape, from `swift build`'s own native build system under Swift 6.4, names the task rather than a bare word.** `error: SwiftCompile normal arm64 /path/File.swift failed with a nonzero exit code. Command line:     cd …` — captured from a real build — carries a multi-word task description (`SwiftCompile normal arm64 …`) in front of the same shape of sentence, so it is read on a substring rather than on the bare-word prefix the first shape requires; the real diagnostic is the very next `path:line:col: error:` line, unaffected. The same build's own final line, the bare literal `error: Build failed`, is `swift build`'s top-level announcement and equally adds nothing: it is what ``RunReport/isUsable(exitCode:)`` already assumes this filter reads as evidence of failure by the *errors it emitted*, never by restating that it failed.
    ///
    /// **A fourth, bare literal closes the same build system's failure a different way: `error: fatalError`.** Captured on `swift test` after a link error (`swift-test-linkerror.txt`, macOS 26.6.1), with no `error: Build failed` beside it — SwiftPM's own summary line for a build that failed, not a diagnostic the driver's own subcommand raised, and it names no file and quotes no source exactly like the other three. **Under Swift 6.4 the two close together instead** (`swift-test-linkerror-6.4.txt`): the same link failure ends on `error: Build failed` immediately followed by `error: fatalError`, both bare and both dropped for the same reason — so the two literals are recognised independently of each other and neither's absence, nor presence beside the other, changes what the line means.
    private static func namesAFailedSubcommand(_ message: String) -> Bool {
        if message.hasPrefix("the following command failed with exit code "), message.hasSuffix(" but produced no further output") {
            return true
        }
        if message.contains(" failed with a nonzero exit code. Command line:") {
            return true
        }
        if message == "Build failed" || message == "fatalError" {
            return true
        }
        guard let sentence = message.range(of: " command failed with exit code ") else {
            return false
        }
        let subcommand = message[..<sentence.lowerBound]
        return !subcommand.isEmpty
            && !subcommand.contains(where: \.isWhitespace)
            && message[sentence.upperBound...].first?.isNumber == true
    }

    /// Whether a location prefix carrying no line number names a file.
    ///
    /// The thing it has to be told apart from is a timestamped tool log — `YYYY-MM-DD 10:00:00.000 xcodebuild[123:456]: warning: …` — and the two are discriminable without guessing: that prefix carries whitespace and a `[pid:tid]` bracket, where a path carries neither and does carry a separator or an extension.
    ///
    /// The deliberate cost: a path containing a space is not read as one. Missing a diagnostic is recoverable — the run's exit code is unchanged and the raw log holds the line — where reading a log line as a diagnostic puts words in the toolchain's mouth.
    private static func looksLikePath(_ prefix: String) -> Bool {
        guard !prefix.contains(where: \.isWhitespace) else {
            return false
        }
        return prefix.contains("/") || prefix.contains(".")
    }
}
