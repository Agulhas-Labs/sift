//
// Copyright © Agulhas Labs
//

import Foundation

/// What one image of a server hands the next when it replaces itself in place (``ServerReexec``): everything the process knows that the new code cannot learn again from outside.
///
/// The process is the same one — same pid, same pipes — so what the kernel keeps for it needs no carrying: its parent, its start time, its descriptors. What is carried is what lived only in the old image's memory: the input it had read and not answered, the protocol version the client agreed to, and what the lifecycle log has to go on saying about a process whose start line was written by other code.
///
/// It travels in the exec's environment under ``environmentKey``, as JSON, and is taken out of the environment again by the image that reads it — so nothing the new image spawns inherits it.
public struct ServerHandover: Codable, Equatable, Sendable {
    /// The layout of this record.
    ///
    /// The image that writes a handover and the image that reads it are different builds, so the new binary is asked to read the handover back before anything is handed to it (``readBack(from:)``): a build that reads another layout, or none at all, would start afresh and drop the request it was handed, and the client would wait for that answer until it timed out.
    public static let format = 1

    /// The environment variable a handover travels in.
    public static var environmentKey: String {
        "SIFT_MCP_RESUME"
    }

    public let format: Int
    /// The process that wrote it, which is the only process that can take it up.
    ///
    /// An exec keeps the pid, so a process resuming is the one that wrote the handover; a copy of the variable that anything else inherited is not addressed to it.
    public let pid: Int32
    /// When the process first started — the moment on its start line — so the stop eventually recorded says how long the whole process lasted, not its last image.
    public let startedAt: Date
    /// The pid the first image armed its parent watch on, read before its start line was written.
    public let parent: Int32
    public let session: Session

    public init(pid: Int32, startedAt: Date, parent: Int32, session: Session) {
        format = Self.format
        self.pid = pid
        self.startedAt = startedAt
        self.parent = parent
        self.session = session
    }
}

public extension ServerHandover {
    /// The conversation in progress.
    struct Session: Codable, Equatable, Sendable {
        /// The protocol version agreed at `initialize`; `nil` where the client had not initialised yet.
        public let protocolVersion: String?
        /// Input read and not yet answered, oldest first: the request that was about to be handled, and anything that arrived after it.
        public let unread: Data

        public init(protocolVersion: String?, unread: Data) {
            self.protocolVersion = protocolVersion
            self.unread = unread
        }
    }

    /// The value this travels in.
    func encoded() throws -> String {
        let data = try JSONEncoder().encode(self)
        guard let value = String(data: data, encoding: .utf8) else {
            throw EncodingError.invalidValue(self, EncodingError.Context(codingPath: [], debugDescription: "not UTF-8"))
        }
        return value
    }

    /// The handover `value` holds for process `pid`, or `nil` where it is not one this process can resume from: another layout, another process's, or unreadable.
    static func decode(_ value: String, for pid: Int32) -> ServerHandover? {
        guard let handover = decode(value), handover.pid == pid else { return nil }
        return handover
    }

    /// The handover `value` holds in the layout this build reads, whichever process it names; `nil` where it is another layout or unreadable.
    static func decode(_ value: String) -> ServerHandover? {
        guard let handover = try? JSONDecoder().decode(ServerHandover.self, from: Data(value.utf8)),
              handover.format == format
        else { return nil }
        return handover
    }

    /// The handover in `environment` as this build reads it, written out again — what a binary asked `sift mcp --read-handover` prints; `nil` where there is none, or none it can read.
    ///
    /// **This is the question a running server asks a replacement before handing it a session** (``ServerReexec``), and it is asked with the very handover the exec would carry, in the variable it would carry it in. Printing a layout number would say only that the new build *claims* to read this layout; a build that decodes it wrongly under the same number would pass that, start afresh, and drop the request it was handed. Read back and compared field for field by the image that wrote it, the answer says what the new build actually read. The process it names is not checked here: the handover is addressed to the server, and the binary answering is a child it started to ask.
    static func readBack(from environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        guard let value = environment[environmentKey], let handover = decode(value) else { return nil }
        return try? handover.encoded()
    }

    /// The handover this process was started with, if it was started with one — read out of the environment and removed from it.
    ///
    /// Removed whether or not it can be used, so that neither this process nor anything it spawns meets it again. One that cannot be used is said out loud and otherwise ignored: the process starts as a fresh server would, which is the most it can do with input it was never given. The environment and its removal are injected only so a test need not change a process-wide variable every other test in the run can see.
    static func take(
        from environment: [String: String] = ProcessInfo.processInfo.environment,
        pid: Int32 = getpid(),
        removing remove: (String) -> Void = { unsetenv($0) },
        note: (String) -> Void
    ) -> ServerHandover? {
        guard let value = environment[environmentKey] else { return nil }
        remove(environmentKey)
        guard let handover = decode(value, for: pid) else {
            note("sift mcp: ignored a \(environmentKey) this process cannot resume from, and started afresh")
            return nil
        }
        return handover
    }
}
