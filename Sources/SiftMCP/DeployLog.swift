//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore

/// The record of each time the bundle's installer put a binary on this machine: one JSON line per install in `~/.sift/deploys.jsonl`, written by `install.sh` and read by `sift report --deploys`.
///
/// Read-only here. The installer writes it in shell, before any binary of this build runs, so there is no writer in Swift to share a format with; a line that does not parse is skipped, because a log appended to by another program is never trusted to be whole.
public struct DeployLog {
    /// `~/.sift/deploys.jsonl`, under the state directory `environment` names.
    public static func standardFileURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        SiftPaths.home(environment: environment).appendingPathComponent("deploys.jsonl")
    }

    /// The installs in `data`, in the order they were written, which is oldest first; a line that is not valid UTF-8, or not a JSON object with a `ts`, is left out.
    ///
    /// The bytes are split on newlines before anything is decoded, so one damaged line costs that line and not the file.
    static func entries(in data: Data) -> [Entry] {
        data.split(separator: UInt8(ascii: "\n")).compactMap { bytes in
            guard String(data: Data(bytes), encoding: .utf8) != nil,
                  let object = try? JSONSerialization.jsonObject(with: Data(bytes)) as? [String: Any],
                  let time = object["ts"] as? String
            else { return nil }
            return Entry(
                time: time,
                version: object["version"] as? String,
                commit: object["commit"] as? String,
                tree: object["tree"] as? String,
                binarySize: object["binarySize"] as? Int
            )
        }
    }

    /// The page `sift report --deploys` prints: one line per install, newest last, in the columns time, commit, version, tree, size.
    ///
    /// A field the installer could not name reads `unknown`. A log with no installs says so rather than printing nothing.
    public static func render(fileURL: URL) -> String {
        let rows = entries(in: (try? Data(contentsOf: fileURL)) ?? Data())
        guard !rows.isEmpty else { return "no deploys recorded: install.sh appends to deploys.jsonl in the state directory on each install" }
        return rows.map { row in
            [
                row.time,
                row.commit ?? "unknown",
                row.version ?? "unknown",
                row.tree ?? "unknown",
                row.binarySize.map { String(format: "%.1f MB", Double($0) / 1_000_000) } ?? "unknown",
            ].joined(separator: "  ")
        }.joined(separator: "\n")
    }
}

extension DeployLog {
    /// One install: any field the installer could not learn is `nil`.
    struct Entry: Equatable {
        var time: String
        var version: String?
        var commit: String?
        var tree: String?
        var binarySize: Int?
    }
}
