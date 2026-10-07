//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftMCP
import Testing

/// The two ways a window is asked for: a shell `sed -n a,bp`, and a `Read` with `offset`/`limit`.
enum WindowReadSpelling: CaseIterable, Sendable {
    case shell, read

    /// The match for lines `lines` of `path` in `root`, spelled this way.
    func match(path: String, lines: ClosedRange<Int>, in root: URL, sourceLocation: SourceLocation = #_sourceLocation) throws -> InPlaceShape.Match {
        switch self {
        case .shell:
            try #require(InPlaceShape.match(forShell: "sed -n '\(lines.lowerBound),\(lines.upperBound)p' \(path)", in: root.path), sourceLocation: sourceLocation)
        case .read:
            try #require(InPlaceShape.match(forRead: path, in: root.path, window: LineWindow(offset: lines.lowerBound, limit: lines.count)), sourceLocation: sourceLocation)
        }
    }
}
