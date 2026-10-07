//
// Copyright © Agulhas Labs
//

import Foundation

/// What a build is doing, read off the one progress line that says so: the text a live view shows while the compiler runs.
struct RunBuildStep {
    /// The step `line` reports the build taking, or `nil` where it reports none.
    ///
    /// SwiftPM numbers its steps — `[4/6] Compiling MixedTests Modern.swift`, `[5/6] Linking WidgetTests` — and from Swift 6.4 names only the target, between thin spaces — `[32 / 55] Pallet` — and prints the counter bare as often as not, which names nothing and so leaves the step it last named standing. `xcodebuild` names a Swift file per line — `SwiftCompile normal arm64 /path/Gizmo.swift (in target 'Gizmo' from project 'Gizmo')` — which is given in SwiftPM's shape, target then file.
    static func named(in line: String) -> String? {
        if line.hasPrefix("[") {
            return swiftPMStep(in: line)
        }
        if line.hasPrefix("SwiftCompile ") || line.hasPrefix("CompileSwift ") {
            return xcodebuildCompile(in: line)
        }
        return nil
    }

    /// Whether `line` is a SwiftPM step counter and nothing else (`[54 / 76]`), which names no step but shows a build is running: SwiftPM prints it bare as often as not, and a build that fails before it names anything has still built.
    static func isBareCounter(_ line: String) -> Bool {
        guard line.hasPrefix("["), let close = counterEnd(in: line) else {
            return false
        }
        return RunLineScan.trimmingWhitespace(line[line.index(after: close)...]).isEmpty
    }

    /// Where the `]` closing a SwiftPM step counter stands, or `nil` for a line that opens on no counter.
    private static func counterEnd(in line: String) -> String.Index? {
        guard let close = line.firstIndex(of: "]") else {
            return nil
        }
        let counter = line[line.index(after: line.startIndex) ..< close]
        guard counter.contains("/"), counter.allSatisfy({ $0.isNumber || $0 == "/" || $0.isWhitespace }) else {
            return nil
        }
        return close
    }

    /// The text after a SwiftPM step counter, without its `Compiling` verb, or `nil` for a line that opens on no counter or whose counter is all it prints.
    private static func swiftPMStep(in line: String) -> String? {
        guard let close = counterEnd(in: line) else {
            return nil
        }
        var step = RunLineScan.trimmingWhitespace(line[line.index(after: close)...])
        if step.hasPrefix("Compiling ") {
            step = step.dropFirst("Compiling ".count)
        }
        return step.isEmpty ? nil : String(step)
    }

    /// `Target File.swift` for an `xcodebuild` Swift compile line: the file is the last path component the line names before its target clause, with the backslash its spaces are escaped by removed.
    private static func xcodebuildCompile(in line: String) -> String? {
        if RunLineScan.isPlainASCII(line[...]) {
            return plainXcodebuildCompile(in: line)
        }
        var body = Substring(line)
        var target: Substring?
        if let clause = line.range(of: " (in target '", options: .backwards) {
            body = line[..<clause.lowerBound]
            let rest = line[clause.upperBound...]
            target = rest.range(of: "'").map { rest[..<$0.lowerBound] }
        }
        guard let slash = body.lastIndex(of: "/") else {
            return nil
        }
        let file = body[body.index(after: slash)...].replacingOccurrences(of: "\\ ", with: " ")
        guard !file.isEmpty else {
            return nil
        }
        return target.map { "\($0) \(file)" } ?? file
    }

    /// ``xcodebuildCompile(in:)`` for a line of printable ASCII, where a byte is a character, read off its bytes rather than through Foundation's searches, which every compile line of a long `xcodebuild` log would otherwise pay for.
    private static func plainXcodebuildCompile(in line: String) -> String? {
        var body = Substring(line)
        var target: Substring?
        if let clause = lastRange(of: " (in target '", in: line) {
            body = line[..<clause.lowerBound]
            let rest = line[clause.upperBound...]
            target = rest.utf8.firstIndex(of: UInt8(ascii: "'")).map { rest[..<$0] }
        }
        guard let slash = body.utf8.lastIndex(of: UInt8(ascii: "/")) else {
            return nil
        }
        let name = body[body.utf8.index(after: slash)...]
        let file = name.utf8.contains(UInt8(ascii: "\\")) ? name.replacingOccurrences(of: "\\ ", with: " ") : String(name)
        guard !file.isEmpty else {
            return nil
        }
        return target.map { "\($0) \(file)" } ?? file
    }

    /// The last place `needle` stands in `line`, compared byte for byte; for ASCII text only.
    private static func lastRange(of needle: String, in line: String) -> Range<String.Index>? {
        let bytes = line.utf8
        let length = needle.utf8.count
        guard bytes.count >= length else {
            return nil
        }
        var start = bytes.index(bytes.endIndex, offsetBy: -length)
        while true {
            if bytes[start...].starts(with: needle.utf8) {
                return start ..< bytes.index(start, offsetBy: length)
            }
            guard start > bytes.startIndex else {
                return nil
            }
            start = bytes.index(before: start)
        }
    }
}
