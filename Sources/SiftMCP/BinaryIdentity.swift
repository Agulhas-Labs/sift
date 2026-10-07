//
// Copyright © Agulhas Labs
//

import Foundation

/// The on-disk identity of the executable this process is running — detects the binary being replaced underneath a long-lived server.
///
/// An upgrade installs by `rm` + `cp` (a fresh inode, deliberately — copying over the old inode gets the new code SIGKILLed by the kernel's signature cache), but a running server keeps executing the unlinked old code until something restarts it. Such a server can stay alive for days, answering from a superseded binary with nothing marking the answers as stale. Comparing inode + mtime *by path* is exactly the check that notices: after an upgrade the path names a different file than the one this process loaded.
public struct BinaryIdentity: Equatable, Sendable {
    let inode: UInt64
    let mtime: Double

    /// The identity currently on disk at `path`, or nil when nothing is there.
    public static func capture(at path: String) -> BinaryIdentity? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value,
              let mtime = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970
        else {
            return nil
        }
        return BinaryIdentity(inode: inode, mtime: mtime)
    }

    /// The path this process is executing from.
    public static var executablePath: String {
        Bundle.main.executablePath ?? CommandLine.arguments.first ?? ""
    }

    /// The warning a tool answer carries once the binary at `path` is no longer `original`; nil while they still match (or when the original was never capturable).
    ///
    /// One `stat` per call — cheap enough to run on every request, which is the point: the alternative is a server that serves superseded answers for days and never says so. A server takes a replacement over in place where it can (``ServerReexec``), and the new image's original is then the new file, so this is only ever seen where that could not happen.
    public static func replacementNotice(path: String, original: BinaryIdentity?) -> String? {
        guard let original else { return nil }
        if capture(at: path) == original {
            return nil
        }
        return "⚠ the sift binary was replaced on disk after this server started — these answers come from the old code. Restart the Claude session (or reconnect the sift MCP server) to load the new binary."
    }
}
