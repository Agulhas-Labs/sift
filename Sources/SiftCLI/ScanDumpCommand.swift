//
// Copyright © Agulhas Labs
//

import ArgumentParser
import Foundation
import SiftMCP

/// `sift scan-dump` — every window the audit's scan scores over the snapshot a request names, one JSON line each, so another build's `audit --scan-diff` can join this build's scan against its own.
///
/// The request is a ``SiftMCP/ScanDumpRequest`` read from stdin whole before anything is written. Each line carries the window's `session` and `call`, its `classification`, its `file` as the scan resolved it and the `locator` call that had located that file, `null` where there is none.
struct ScanDumpCommand: ParsableCommand {
    static var configuration: CommandConfiguration {
        CommandConfiguration(
            commandName: "scan-dump",
            abstract: "Print every window the audit's scan scores over the snapshot a request on stdin names, one JSON line each (for `audit --scan-diff`).",
            shouldDisplay: false
        )
    }

    /// How long another build's dump may run before it is stopped and counted as failed: a scan of a week of transcripts takes minutes, not this.
    static let dumpLimit: TimeInterval = 3600

    @Option(name: .customLong("request"), help: "Read the request from this file instead of stdin.")
    var request: String?

    var output: CommandOutput = .standard

    func run() throws {
        let data = try request.map { try Data(contentsOf: URL(fileURLWithPath: $0)) } ?? FileHandle.standardInput.readToEnd() ?? Data()
        guard let request = try? JSONDecoder().decode(ScanDumpRequest.self, from: data) else {
            throw ValidationError("scan-dump reads one request, the JSON `audit --scan-diff` writes, from stdin.")
        }
        for window in request.windows() {
            output.emit(window.jsonLine)
        }
    }

    /// Whether `binary` has this entry point: a build from before `audit --scan-diff` has none.
    ///
    /// Asked with a request naming no transcript, which a build with the entry point answers with nothing and a clean exit. Never with `--help`: a build without the subcommand prints its own root help for `scan-dump --help` and exits cleanly all the same. A binary that has not answered within `limit` seconds is stopped and counted as having none.
    static func isSupported(by binary: URL, within limit: TimeInterval = 10, interruptions: ReplayInterruptions? = nil) -> Bool {
        let empty = Data(#"{"sessions":[],"subagents":{},"sizes":{}}"#.utf8)
        guard let reply = ExternalReplayHook.launch(binary, arguments: ["scan-dump"], input: empty, within: limit, interruptions: interruptions) else { return false }
        return reply.status == 0 && reply.output.isEmpty
    }

    /// Every window `binary`'s scan scores over `request`, or `nil` where it could not be run, did not finish within `limit` seconds, exited non-zero or wrote a line that is not a window.
    static func windows(of binary: URL, request: ScanDumpRequest, within limit: TimeInterval = dumpLimit, interruptions: ReplayInterruptions? = nil) -> [ScoredWindow]? {
        guard let input = try? JSONEncoder().encode(request),
              let reply = ExternalReplayHook.launch(binary, arguments: ["scan-dump"], input: input, within: limit, interruptions: interruptions),
              reply.status == 0
        else {
            return nil
        }
        var windows: [ScoredWindow] = []
        for line in reply.output.split(separator: 0x0A, omittingEmptySubsequences: true) {
            guard let window = try? JSONDecoder().decode(ScoredWindow.self, from: Data(line)) else { return nil }
            windows.append(window)
        }
        return windows
    }

    /// The other build's scan and this build's over `request`, run at once, so each builds its per-run index state in the same window of time; `theirs` is `nil` where the other binary's dump failed.
    ///
    /// The other binary is started on a thread of its own while this build's scan runs here, and both are waited for before either is returned.
    static func windowsAtOnce(of binary: URL, request: ScanDumpRequest, interruptions: ReplayInterruptions? = nil) -> (theirs: [ScoredWindow]?, ours: [ScoredWindow]) {
        let theirs = ResultBox<[ScoredWindow]?>()
        let finished = DispatchGroup()
        finished.enter()
        Thread.detachNewThread {
            theirs.value = windows(of: binary, request: request, interruptions: interruptions)
            finished.leave()
        }
        let ours = request.windows()
        finished.wait()
        return (theirs: theirs.value.flatMap(\.self), ours: ours)
    }
}

extension ScanDumpCommand {
    /// Only the option comes off the command line, for the reason ``AuditCommand``'s keys give.
    enum CodingKeys: String, CodingKey {
        case request
    }
}
