//
// Copyright © Agulhas Labs
//

import Foundation

/// A Swift compiler crash read out of a build log: the pass and function it crashed in, and the diagnostic it stopped on.
///
/// **A crash explains the failure with no `error:` line of its own worth listing.** The frontend's last words are a stack dump: a numbered frame list naming what it was doing, a symbolised backtrace, and the `Failed frontend command:` it ran, which is one line holding every source path the job compiled, often tens of kilobytes. The one sentence `error:`-shaped among them (`<unknown>:0: error: fatal error encountered during compilation; …`) says only that it crashed, and a signal crash prints not even that. So the filter reads the dump here, before any other reader sees its lines, and keeps the three things a reader acts on: the deepest pass frame, the function it names, and any `Error!` line the compiler's verifier printed.
///
/// **The frontend command and the program arguments are never kept.** Both stay in the raw log; the answer quotes neither, so its size does not move with the size of the module being compiled.
public struct RunCompilerCrash: Sendable, Equatable {
    /// The frame the answer names: the deepest `While running pass …` of the first stack dump, else its deepest `While …` frame, with the frame number taken off.
    public private(set) var frame: String?
    /// The ` for 'name()' (at path:line:col)` line the compiler printed directly beneath ``frame``, trimmed.
    public private(set) var frameSite: String?
    /// The first `Error! …` line the compiler's verifier printed.
    public private(set) var diagnostic: String?
    /// The `Value: …` line directly beneath ``diagnostic``, trimmed.
    public private(set) var diagnosticValue: String?

    public init() {}
}

// MARK: - Reading

public extension RunCompilerCrash {
    /// Reads a build log a line at a time, claiming the lines of a compiler crash.
    struct Reader: Sendable {
        private var crash = RunCompilerCrash()
        private var crashed = false
        private var stackDumps = 0
        private var passFrameSeen = false
        private var previous = Previous.other
        private var droppingCommandLine = false

        public init() {}

        /// The crash the log reported, or `nil` when it reported none.
        public var result: RunCompilerCrash? {
            crashed ? crash : nil
        }

        /// Whether `line` belongs to a compiler crash and must reach no other reader — every such line is claimed, whether or not anything of it is kept.
        public mutating func read(_ line: String) -> Bool {
            let last = previous
            previous = .other
            if droppingCommandLine {
                droppingCommandLine = false
                return true
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if Self.marksACrash(line) {
                crashed = true
                return true
            }
            // Printed under a plain compile error as well as a crash, so it marks nothing: it and the command beneath it are only never passed on.
            if trimmed == "Failed frontend command:" {
                droppingCommandLine = true
                return true
            }
            if line.hasPrefix("Stack dump") {
                if trimmed == "Stack dump:" {
                    stackDumps += 1
                }
                return true
            }
            if trimmed.hasPrefix("Error! ") {
                if crash.diagnostic == nil {
                    crash.diagnostic = trimmed
                    previous = .diagnostic
                }
                return true
            }
            if last == .diagnostic, trimmed.hasPrefix("Value:") {
                crash.diagnosticValue = trimmed
                return true
            }
            if last == .keptFrame, trimmed.hasPrefix("for '") {
                crash.frameSite = trimmed
                return true
            }
            guard stackDumps > 0, let frame = Self.frameText(trimmed) else {
                return false
            }
            if stackDumps == 1, frame.hasPrefix("While ") {
                keep(frame)
            }
            return true
        }

        /// Keeps `frame` where it is deeper than, or more telling than, the one already kept: a pass frame over any other, and among equals the later.
        private mutating func keep(_ frame: String) {
            let isPass = frame.hasPrefix("While running pass ")
            guard isPass || !passFrameSeen else {
                return
            }
            passFrameSeen = passFrameSeen || isPass
            crash.frame = frame
            crash.frameSite = nil
            previous = .keptFrame
        }

        /// Whether `line` is one of the two lines only a crashing compiler prints, each enough on its own to say this log holds a crash.
        ///
        /// Anchored at the head of the line, never matched anywhere in it: a test's message or note can quote either sentence, and a failure quoting a crash is not one. The fatal-error line counts only as the frontend prints it, at `<unknown>:0:`; a bare `error: fatal error …` is any program's text.
        private static func marksACrash(_ line: String) -> Bool {
            line.hasPrefix("Please submit a bug report (https://swift.org/contributing")
                || line.hasPrefix("<unknown>:0: error: fatal error encountered during compilation")
        }

        /// A stack dump frame's text — `4.<tab>While running pass …` read as `While running pass …` — or `nil` where `line` is not one.
        private static func frameText(_ line: String) -> String? {
            guard let dot = line.firstIndex(of: "."), dot > line.startIndex,
                  line[..<dot].allSatisfy(\.isASCIIDigit)
            else {
                return nil
            }
            let rest = line[line.index(after: dot)...]
            guard rest.first == "\t" || rest.first == " " else {
                return nil
            }
            return rest.trimmingCharacters(in: .whitespaces)
        }
    }
}

private extension RunCompilerCrash.Reader {
    /// What the line before this one was, for the two readings that belong only to the line directly beneath.
    enum Previous: Sendable {
        case other
        case keptFrame
        case diagnostic
    }
}

// MARK: - Rendering

public extension RunCompilerCrash {
    /// The lines this crash adds to an answer, indented beneath its headline: the frame with its function demangled, the site beneath it, and the `Error!` line with its value.
    ///
    /// Each is clipped to ``RunFailureCensus/wordsCap``: a request frame can spell a whole pass pipeline, and a `Value:` line a whole SIL instruction, and neither is worth more than its opening words here.
    func lines(demangling demangle: (String) -> String? = RunCompilerCrash.demangled) -> [String] {
        var lines: [String] = []
        if let frame {
            lines.append("  \(RunFailureCensus.clipped(Self.naming(frame, demangling: demangle)))")
        }
        if let frameSite {
            lines.append("    \(RunFailureCensus.clipped(frameSite))")
        }
        if let diagnostic {
            lines.append("  \(RunFailureCensus.clipped(diagnostic))")
        }
        if let diagnosticValue {
            lines.append("    \(RunFailureCensus.clipped(diagnosticValue))")
        }
        return lines
    }

    /// `frame` with its `on SILFunction "@$s…".` spelled as the function it mangles — `on RunCommand.run()` — where the demangler reads it, and exactly as printed where it does not.
    internal static func naming(_ frame: String, demangling demangle: (String) -> String?) -> String {
        let head = " on SILFunction \"@"
        guard let start = frame.range(of: head),
              let end = frame[start.upperBound...].firstIndex(of: "\"")
        else {
            return frame
        }
        let symbol = String(frame[start.upperBound ..< end])
        guard let name = demangle(symbol), !name.isEmpty, name != symbol else {
            return frame
        }
        return "\(frame[..<start.lowerBound]) on \(name)"
    }

    /// `symbol` in its simplified demangled form, from the toolchain's own `swift-demangle`, or `nil` where it could not be asked or could not read it.
    ///
    /// Asked of `xcrun`, the same route every toolchain lookup here takes, on a short deadline: a demangler that cannot be found leaves the mangled name standing, which is still the name the compiler printed.
    static func demangled(_ symbol: String) -> String? {
        guard let output = try? SimulatorAccessibility.spawn("/usr/bin/xcrun", ["swift-demangle", "--simplified", "--compact", symbol], deadline: 5),
              output.succeeded
        else {
            return nil
        }
        let name = output.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }
}

private extension Character {
    var isASCIIDigit: Bool {
        isASCII && isNumber
    }
}
