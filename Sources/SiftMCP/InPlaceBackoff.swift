//
// Copyright © Agulhas Labs
//

import CryptoKit
import Foundation
import SiftCore

/// How long the hook leaves one shape of answer alone in a repository after answering it in place ran out of time there (``InPlaceAnswerer``).
///
/// An answer that runs out of time costs the whole budget and still ends in the refusal, and one that runs out once usually runs out again — a large dirty set to reindex, a store another process holds, a tree too large to search inside the budget. So after one overrun the hook refuses that shape there without trying, for ``window``, and the most a shape whose answers never fit can cost is one budget per window: a second of waiting in every five minutes of lookups, rather than a second on each.
///
/// **Kept by repository and shape** (``InPlaceCall/Shape``), because the shapes cost different things: a sweep searches a tree and a whole read digests one file, so a sweep that ran out of time says nothing about whether the next whole read will, and letting it switch off the cheapest answer for the window would be the back-off costing more than it saves.
///
/// One small file per repository and shape, named by a hash of the repository's canonical path and the shape, in the advice directory. Every failure is silent and reads as no back-off, which only ever costs the budget the back-off exists to save.
public struct InPlaceBackoff: Sendable {
    /// How long a shape is left alone in a repository after an overrun.
    public static let window: TimeInterval = 300

    let directory: URL
    let now: @Sendable () -> Date

    public init(directory: URL, now: @escaping @Sendable () -> Date = { Date() }) {
        self.directory = directory
        self.now = now
    }

    /// Kept in the advice directory, beside the ledger whose refusals it leaves standing.
    public static func standard() -> InPlaceBackoff {
        InPlaceBackoff(directory: AdviceLedger.standardDirectory().appendingPathComponent("backoff", isDirectory: true))
    }

    /// Whether answering `shape` in `root` ran out of time within the window.
    public func isBackingOff(root: String, shape: InPlaceCall.Shape) -> Bool {
        guard let data = try? Data(contentsOf: file(for: root, shape: shape)),
              let entry = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let stamp = entry["ts"] as? TimeInterval
        else {
            return false
        }
        let elapsed = now().timeIntervalSince1970 - stamp
        return elapsed >= 0 && elapsed < Self.window
    }

    /// Records that answering `shape` in `root` ran out of time now.
    public func noteOverrun(root: String, shape: InPlaceCall.Shape) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let entry: [String: Any] = ["root": root, "shape": shape.rawValue, "ts": now().timeIntervalSince1970]
        guard let data = try? JSONSerialization.data(withJSONObject: entry) else { return }
        try? data.write(to: file(for: root, shape: shape), options: .atomic)
    }

    private func file(for root: String, shape: InPlaceCall.Shape) -> URL {
        // Canonical, so a root spelled through a symlinked parent shares its back-off.
        let digest = SHA256.hash(data: Data(CanonicalPath.of(root).utf8))
        let name = digest.prefix(12).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("\(name)-\(shape.rawValue).json")
    }
}
