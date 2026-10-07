//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftMCP
import Testing

/// The ways a window over every line of a file is written, as a `Read` or a shell command.
enum WholeFileSpelling: CaseIterable, Sendable {
    case readFromTheStart, readFromLineOne, readPastTheEnd
    case shellSed, shellSedPastTheEnd, shellSedToTheEnd, shellHead, shellHeadPastTheEnd, shellTail

    /// Whether this is a `Read` rather than a shell command.
    var isRead: Bool {
        switch self {
        case .readFromTheStart, .readFromLineOne, .readPastTheEnd: true
        default: false
        }
    }

    /// The match for this window on `path` in `root`, for a file of `lines` lines.
    func match(path: String, lines: Int, in root: URL, sourceLocation: SourceLocation = #_sourceLocation) throws -> InPlaceShape.Match {
        let window: LineWindow? = switch self {
        case .readFromTheStart: LineWindow(offset: nil, limit: lines)
        case .readFromLineOne: LineWindow(offset: 1, limit: lines)
        case .readPastTheEnd: LineWindow(offset: 1, limit: 2000)
        default: nil
        }
        if let window {
            return try #require(InPlaceShape.match(forRead: path, in: root.path, window: window), sourceLocation: sourceLocation)
        }
        return try #require(InPlaceShape.match(forShell: shell(path: path, lines: lines), in: root.path), sourceLocation: sourceLocation)
    }

    /// The match for the whole read of `path` in `root` of this spelling's kind: a `Read` of no window, or a `cat`.
    func wholeMatch(path: String, in root: URL, sourceLocation: SourceLocation = #_sourceLocation) throws -> InPlaceShape.Match {
        if isRead {
            return try #require(InPlaceShape.match(forRead: path, in: root.path), sourceLocation: sourceLocation)
        }
        return try #require(InPlaceShape.match(forShell: "cat \(path)", in: root.path), sourceLocation: sourceLocation)
    }

    /// The shell command that is this window on `path`, for a file of `lines` lines.
    private func shell(path: String, lines: Int) -> String {
        switch self {
        case .shellSed: "sed -n '1,\(lines)p' \(path)"
        case .shellSedPastTheEnd: "sed -n '1,2000p' \(path)"
        case .shellSedToTheEnd: "sed -n '1,$p' \(path)"
        case .shellHead: "head -\(lines) \(path)"
        case .shellHeadPastTheEnd: "head -2000 \(path)"
        default: "tail -n +1 \(path)"
        }
    }
}
