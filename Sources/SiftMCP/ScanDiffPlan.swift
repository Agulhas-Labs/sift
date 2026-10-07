//
// Copyright © Agulhas Labs
//

import Foundation

/// What `audit --scan-diff` scans and how it lists it, from the snapshot taken and the options given.
///
/// The snapshot is narrowed to the root where one is given, and where that leaves no transcript the plan carries the plain audit's answer for it as a refusal, so a scan of nothing is not read as a scan that agreed.
public struct ScanDiffPlan {
    /// The snapshot both scans read.
    public let snapshot: TranscriptSnapshot
    /// Whether the listing lifts its cap.
    public let listsAll: Bool
    /// The line to refuse with, in place of a scan, where the root kept no transcript.
    public let refusal: String?

    public init(taken: TranscriptSnapshot, root: String?, allWindows: Bool, since: Date?, until: Date?, projectsDirectory: URL, redactor: Redactor?) {
        snapshot = root.map { taken.scoped(to: $0) } ?? taken
        listsAll = allWindows
        guard let root, snapshot.sessions.isEmpty else {
            refusal = nil
            return
        }
        let scope = since == nil && until == nil ? "" : " in that window"
        let path = redactor == nil ? projectsDirectory.path : Redactor.tilded(projectsDirectory.path)
        refusal = taken.sessions.isEmpty
            ? "no session transcripts found\(scope) under \(path)"
            : TranscriptWorkingDirectory.noneIn(root, windowed: taken.sessions, scope: scope, path: path, redactor: redactor)
    }
}
