//
// Copyright © Agulhas Labs
//

import Foundation

/// How wide a window of a file an answer that located it may be and still be the ranged read that answer pointed at.
///
/// A `where` or `search` listing names a declaration's or a reference's line and nothing of the members around it, a module digest names the file under a heading, and a digest of a line or a member serves that much of the file and no more. The read of what they placed and its neighbours is the loop working, and no lookup; a window of hundreds of lines beside it is the file read through a window, and is judged as a cold window is. Only the file's whole digest is not held to this: it has already handed the context the member map such a window would be answered with.
public struct ListedWindow {
    /// The most lines a window may print of a file and still be excused by an answer that located it, the file's whole digest aside: two hundred, ten members of twenty lines.
    public static let widestExcused = 200

    /// Whether `windows` together print more than ``widestExcused`` lines of the file at `path` as it is on disk.
    ///
    /// `false` where the file cannot be read or a window's lines cannot be read off the command without its bytes, which leaves the window excused as it was.
    public static func isWide(_ windows: [LineWindow], ofFileAt path: String) -> Bool {
        guard !windows.isEmpty, let data = FileManager.default.contents(atPath: path) else { return false }
        var count = data.reduce(0) { $1 == 0x0A ? $0 + 1 : $0 }
        if let last = data.last, last != 0x0A {
            count += 1
        }
        var printed = Set<Int>()
        for window in windows {
            guard let lines = window.lines(inFileOf: count) else { return false }
            printed.formUnion(lines)
        }
        return printed.count > widestExcused
    }

    /// Whether the shell `command`, a windowed read of the file at `path`, prints more than ``widestExcused`` lines of it.
    ///
    /// `false` where the command is no such read or its lines cannot be worked out, which leaves the window excused as it was.
    public static func isWide(readBy command: String, ofFileAt path: String, holdsSource: ((String) -> Bool)?) -> Bool {
        guard let window = ShellInspection.window(ofWindowedRead: command, holdsSource: holdsSource) else { return false }
        return isWide([window], ofFileAt: path)
    }
}
