//
// Copyright © Agulhas Labs
//

import Foundation

/// The lines of a source file a Swift Testing test function's event-stream declaration covers: from the line it was declared on up to, not including, the line of the next test or suite the stream declared in the same file, which holds the test's body and anything written after it there.
///
/// **The stream says where a test is declared, never where it ends**, so the stretch is an upper bound: a helper written between two tests falls in the earlier one's.
public struct DeclaredTestSource: Sendable, Equatable {
    /// The file as `#fileID` spells it, `Module/File.swift`.
    public let fileID: String
    /// The file as `#filePath` spells it, or `nil` where the stream gave none.
    public let filePath: String?
    public let lines: Range<Int>

    /// Whether `line` of `file`, in either spelling a trap message prints, falls inside.
    func holds(file: Substring, line: Int) -> Bool {
        lines.contains(line) && (file == fileID || filePath.map { file == $0 } == true)
    }
}

extension DeclaredTestSource {
    /// One test or suite the stream declared, with where its declaration sits.
    struct Site: Sendable, Equatable {
        let id: String
        let isFunction: Bool
        let fileID: String
        let filePath: String?
        let line: Int

        /// The declaration a stream's `test` record carries, or `nil` where it names no identifier or location.
        init?(_ payload: [String: Any]) {
            guard let id = payload["id"] as? String, let location = payload["sourceLocation"] as? [String: Any],
                  let fileID = location["fileID"] as? String, let line = location["line"] as? Int
            else {
                return nil
            }
            self.id = id
            isFunction = payload["kind"] as? String == "function"
            self.fileID = fileID
            filePath = location["filePath"] as? String
            self.line = line
        }
    }

    /// The stretch of each test function in `ids` that `sites` declares, ordered by file and line.
    static func stretches(of ids: Set<String>, among sites: [Site]) -> [DeclaredTestSource] {
        sites.filter { $0.isFunction && ids.contains($0.id) }.map { site in
            let next = sites.filter { $0.fileID == site.fileID && $0.line > site.line }.map(\.line).min() ?? Int.max
            return DeclaredTestSource(fileID: site.fileID, filePath: site.filePath, lines: site.line ..< next)
        }
        .sorted { ($0.fileID, $0.lines.lowerBound) < ($1.fileID, $1.lines.lowerBound) }
    }
}
