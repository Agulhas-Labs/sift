//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore

/// A file a command names, resolved against the directory the command ran in and read as it stands on disk.
struct OperandFile {
    /// `path` spelled out in full, or `nil` where it is relative and there is no directory to resolve it against.
    static func absolute(_ path: String, in directory: String?) -> String? {
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path).standardizedFileURL.path
        }
        guard let directory else { return nil }
        return URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: directory, isDirectory: true)).standardizedFileURL.path
    }

    /// `path` spelled out in full where it names a regular file that is there, or `nil`.
    static func existing(_ path: String, in directory: String?) -> String? {
        guard let file = absolute(path, in: directory) else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: file, isDirectory: &isDirectory), !isDirectory.boolValue else { return nil }
        return file
    }

    /// `path` spelled out in full where it names a regular file that is there and can be read, or `nil`.
    static func readable(_ path: String, in directory: String?) -> String? {
        guard let file = existing(path, in: directory), FileManager.default.isReadableFile(atPath: file) else { return nil }
        return file
    }

    /// Whether some window on `match` reads a file holding a merge conflict marker, checked before anything is opened: a conflicted file's windows are the one read that shows both sides of the conflict.
    ///
    /// A shell window says so in `windowed`, and a ranged `Read` in its call's own windows alone, since `windowed` is what a window of a located file is dropped on and a `Read` is never dropped that way.
    static func windowsAConflict(_ match: InPlaceShape.Match) -> Bool {
        zip(match.calls, match.windowed).contains { call, isWindow in
            (isWindow || readsLines(call)) && call.readPath.map { holdsConflictMarkers($0, in: match.directory) } == true
        }
    }

    /// Whether `call` answers line windows of its file rather than the whole of it.
    private static func readsLines(_ call: InPlaceCall) -> Bool {
        guard case let .fileDigest(_, windows) = call else { return false }
        return !windows.isEmpty
    }

    /// Whether the file at `path` holds an unresolved merge conflict marker at the start of a line: seven of `<`, `=`, `>` or `|`, then a space or the line's end.
    ///
    /// Lines are split at every newline byte, a CRLF file's included: split by `Character`, `"\r\n"` is one character and never a `"\n"`, so a CRLF file read as one line whose only start is the file's.
    static func holdsConflictMarkers(_ path: String, in directory: String?) -> Bool {
        guard let file = readable(path, in: directory), let data = FileManager.default.contents(atPath: file),
              let text = String(bytes: data, encoding: .utf8)
        else {
            return false
        }
        let markers = ["<", "=", ">", "|"].map { String(repeating: $0, count: 7) }
        return lines(of: text).contains { line in
            markers.contains { marker in
                guard line.hasPrefix(marker) else { return false }
                let rest = line.dropFirst(marker.count)
                return rest.isEmpty || rest == "\r" || rest.first == " "
            }
        }
    }

    /// The bytes `windows` print of a file of `lines` whose lines are `byteLengths` bytes wide on disk, each window's lines with their newlines and several windows summed, or `nil` where there are none or a window's lines cannot be read.
    static func windowBytes(of windows: [LineWindow], in lines: [String], byteLengths: [Int]) -> Int? {
        guard !windows.isEmpty else { return nil }
        var total = 0
        for window in windows {
            guard let printed = window.lines(in: lines, byteLengths: byteLengths) else { return nil }
            total += printed.reduce(0) { $0 + byteLengths[$1 - 1] + 1 }
        }
        return total
    }

    /// The file a command named, as the index holds it — or `nil` where it is not there at exactly that path.
    static func indexed(_ path: String, in directory: String?, engine: SiftEngine) throws -> Indexed? {
        guard let file = absolute(path, in: directory),
              let relative = try ExactAnswer.indexedFile(atPath: file, in: engine),
              let data = FileManager.default.contents(atPath: file),
              let text = String(bytes: data, encoding: .utf8)
        else {
            return nil
        }
        var lines = Self.lines(of: text)
        var byteLengths = Self.byteLengths(of: data)
        if text.utf8.last == UInt8(ascii: "\n") {
            lines.removeLast()
            byteLengths.removeLast()
        }
        return Indexed(relative: relative, lines: lines, byteLengths: byteLengths, bytes: data.count)
    }

    /// The lines of `text`, split at every newline byte and each kept with any carriage return before its newline, with an empty last one where `text` ends on a newline.
    private static func lines(of text: String) -> [String] {
        text.utf8.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false).map { String(Substring($0)) }
    }

    /// Each line's width in bytes as `data` holds it on disk — a leading BOM included in the first line — split at every newline byte the same way ``lines(of:)`` splits the text decoded from it.
    private static func byteLengths(of data: Data) -> [Int] {
        data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false).map(\.count)
    }
}

extension OperandFile {
    /// A file the index holds, with its lines and each line's true width on disk in bytes.
    struct Indexed {
        /// The path the index holds the file at, relative to the repository root.
        let relative: String
        /// The file's lines, decoded, each without its newline.
        let lines: [String]
        /// Each line's width in bytes as the file holds it on disk, its own newline not counted.
        ///
        /// Read from the raw bytes, not from `lines`: a leading UTF-8 BOM, dropped by the decode that reads `lines`, still falls on the first line's width here as it does on disk.
        let byteLengths: [Int]
        /// The file's whole size on disk in bytes, what a read of all of it prints.
        let bytes: Int
    }
}
