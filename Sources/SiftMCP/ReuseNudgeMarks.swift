//
// Copyright © Agulhas Labs
//

import CryptoKit
import Foundation
import SiftCore

/// The reuse nudges each context has already been given, so that one context, file and declaration draws one nudge at most.
///
/// One empty file per nudge given, named by a digest of the three, created exclusively: the create is the check and the record at once, so two hooks racing over the same edit cannot both win it.
public struct ReuseNudgeMarks: Sendable {
    let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// Kept in the advice directory beside the ledger, so `SIFT_ADVICE_DIR` redirects both together.
    public static func standard() -> ReuseNudgeMarks {
        ReuseNudgeMarks(directory: AdviceLedger.standardDirectory().appendingPathComponent("reuse", isDirectory: true))
    }

    /// Claims the nudge about `declaration` in `file` for `context`, answering whether this call is the first to.
    ///
    /// A directory that cannot be prepared claims nothing: a nudge left unsaid costs nothing, where one repeated on every edit would teach the model to skip them.
    public func claim(context: String, file: String, declaration: String) -> Bool {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let digest = SHA256.hash(data: Data([context, CanonicalPath.of(file), declaration].joined(separator: "\n").utf8))
        let name = digest.prefix(16).map { String(format: "%02x", $0) }.joined()
        let descriptor = open(directory.appendingPathComponent(name).path, O_CREAT | O_EXCL | O_WRONLY, 0o644)
        guard descriptor >= 0 else { return false }
        close(descriptor)
        return true
    }
}
