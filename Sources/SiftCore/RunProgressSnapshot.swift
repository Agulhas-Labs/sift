//
// Copyright © Agulhas Labs
//

import Foundation

/// One state of a wrapped run as `.sift/progress.json` carries it: exactly the keys `Docs/ProgressContract.md` specifies, every one always present.
///
/// The property names are the JSON keys, so the contract's spelling is the code's. Encoding is written by hand because the synthesized form drops a nil optional, and the contract promises `null` for a value not known yet rather than a missing key. Timestamps are ISO-8601 in UTC with milliseconds, encoded here rather than through an encoder's date strategy, so any `JSONEncoder` produces the contract's form.
public struct RunProgressSnapshot: Codable, Sendable, Equatable {
    /// The version of the contract this snapshot follows; it changes only when a key is removed or changes meaning.
    public static let currentSchemaVersion = 1

    /// The longest `command` the file carries, in characters.
    public static let commandLimit = 200

    public var schemaVersion: Int
    public var runId: String
    public var pid: Int32
    public var repoRoot: String
    public var phase: Phase
    public var startedAt: Date
    public var phaseStartedAt: Date
    public var updatedAt: Date
    public var command: String
    public var scheme: String?
    public var destination: String?
    public var current: String?
    public var tests: TestCounts
    public var errors: Int
    public var warnings: Int
    public var summary: Timings?
    public var logPath: String?
    public var exitCode: Int32?
    /// The key (``TreeKey``) of the tree the run started on, where it is a build or a test of the repository the file sits in; null otherwise, and in a file an older sift wrote.
    public var tree: String?

    /// A snapshot of a run just started: `idle`, nothing counted, nothing timed.
    public init(
        runId: String,
        pid: Int32,
        repoRoot: String,
        startedAt: Date,
        command: String,
        scheme: String? = nil,
        destination: String? = nil,
        logPath: String? = nil,
        tree: String? = nil
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.runId = runId
        self.pid = pid
        self.repoRoot = repoRoot
        phase = .idle
        self.startedAt = startedAt
        phaseStartedAt = startedAt
        updatedAt = startedAt
        self.command = Self.fitted(command)
        self.scheme = scheme
        self.destination = destination
        current = nil
        tests = TestCounts()
        errors = 0
        warnings = 0
        summary = nil
        self.logPath = logPath
        exitCode = nil
        self.tree = tree
    }

    /// `command` on one line and within ``commandLimit``: line breaks become spaces, and a longer one is cut to one character short of the limit and ends in an ellipsis.
    public static func fitted(_ command: String) -> String {
        let flat = command.split(whereSeparator: \.isNewline).joined(separator: " ")
        guard flat.count > commandLimit else { return flat }
        return String(flat.prefix(commandLimit - 1)) + "…"
    }

    /// The bytes the file holds: sorted keys, slashes unescaped.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    /// Reads a snapshot back from the bytes the file holds.
    public static func decoded(from data: Data) throws -> Self {
        try JSONDecoder().decode(Self.self, from: data)
    }

    private static let timestamp = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        runId = try container.decode(String.self, forKey: .runId)
        pid = try container.decode(Int32.self, forKey: .pid)
        repoRoot = try container.decode(String.self, forKey: .repoRoot)
        phase = try container.decode(Phase.self, forKey: .phase)
        startedAt = try Self.date(container, .startedAt)
        phaseStartedAt = try Self.date(container, .phaseStartedAt)
        updatedAt = try Self.date(container, .updatedAt)
        command = try container.decode(String.self, forKey: .command)
        scheme = try container.decodeIfPresent(String.self, forKey: .scheme)
        destination = try container.decodeIfPresent(String.self, forKey: .destination)
        current = try container.decodeIfPresent(String.self, forKey: .current)
        tests = try container.decode(TestCounts.self, forKey: .tests)
        errors = try container.decode(Int.self, forKey: .errors)
        warnings = try container.decode(Int.self, forKey: .warnings)
        summary = try container.decodeIfPresent(Timings.self, forKey: .summary)
        logPath = try container.decodeIfPresent(String.self, forKey: .logPath)
        exitCode = try container.decodeIfPresent(Int32.self, forKey: .exitCode)
        tree = try container.decodeIfPresent(String.self, forKey: .tree)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(runId, forKey: .runId)
        try container.encode(pid, forKey: .pid)
        try container.encode(repoRoot, forKey: .repoRoot)
        try container.encode(phase, forKey: .phase)
        try container.encode(Self.stamp(startedAt), forKey: .startedAt)
        try container.encode(Self.stamp(phaseStartedAt), forKey: .phaseStartedAt)
        try container.encode(Self.stamp(updatedAt), forKey: .updatedAt)
        try container.encode(command, forKey: .command)
        try container.encode(scheme, forKey: .scheme)
        try container.encode(destination, forKey: .destination)
        try container.encode(current, forKey: .current)
        try container.encode(tests, forKey: .tests)
        try container.encode(errors, forKey: .errors)
        try container.encode(warnings, forKey: .warnings)
        try container.encode(summary, forKey: .summary)
        try container.encode(logPath, forKey: .logPath)
        try container.encode(exitCode, forKey: .exitCode)
        try container.encode(tree, forKey: .tree)
    }

    /// `date` in UTC to the nearest millisecond, always with three fractional digits: rounded here because the format style truncates, so a millisecond parsed back as a binary fraction a hair below it would otherwise print one less.
    static func stamp(_ date: Date) -> String {
        let milliseconds = Int64((date.timeIntervalSince1970 * 1000).rounded())
        let (seconds, fraction) = milliseconds.quotientAndRemainder(dividingBy: 1000)
        let whole = Date(timeIntervalSince1970: TimeInterval(seconds)).formatted(.iso8601)
        return "\(whole.dropLast()).\(String(format: "%03lld", fraction))Z"
    }

    private static func date(_ container: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) throws -> Date {
        let text = try container.decode(String.self, forKey: key)
        do {
            return try Date(text, strategy: timestamp)
        } catch {
            throw DecodingError.dataCorruptedError(forKey: key, in: container, debugDescription: "not an ISO-8601 timestamp: \(text)")
        }
    }
}

public extension RunProgressSnapshot {
    /// Whether a reader at `now` takes this run for going on: a phase that is not terminal, and a heartbeat no older than ``RunProgressWriter/staleAfter``.
    ///
    /// The rule `Docs/ProgressContract.md` gives a consumer and a consumer applies; a run killed without a trace leaves a live phase behind and stops being live five seconds on.
    func isLive(at now: Date) -> Bool {
        !phase.isTerminal && now.timeIntervalSince(updatedAt) <= RunProgressWriter.staleAfter
    }

    /// Where a run has got to: `idle` until a build or test line is recognised, then building and testing in any order, then exactly one terminal phase.
    enum Phase: String, Codable, Sendable, CaseIterable {
        case idle
        case building
        case testing
        case done
        case failed

        /// Whether the run is over: a terminal phase is final.
        public var isTerminal: Bool {
            self == .done || self == .failed
        }
    }

    /// The test counts so far; `planned` is null unless the run declared its tests before running them.
    struct TestCounts: Codable, Sendable, Equatable {
        public var planned: Int?
        public var passed: Int
        public var failed: Int
        public var skipped: Int

        public init(planned: Int? = nil, passed: Int = 0, failed: Int = 0, skipped: Int = 0) {
            self.planned = planned
            self.passed = passed
            self.failed = failed
            self.skipped = skipped
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(planned, forKey: .planned)
            try container.encode(passed, forKey: .passed)
            try container.encode(failed, forKey: .failed)
            try container.encode(skipped, forKey: .skipped)
        }
    }

    /// How long the run spent building, testing and in all, in milliseconds; a phase the run never entered is null.
    struct Timings: Codable, Sendable, Equatable {
        public var buildMs: Int?
        public var testMs: Int?
        public var totalMs: Int

        public init(buildMs: Int?, testMs: Int?, totalMs: Int) {
            self.buildMs = buildMs
            self.testMs = testMs
            self.totalMs = totalMs
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(buildMs, forKey: .buildMs)
            try container.encode(testMs, forKey: .testMs)
            try container.encode(totalMs, forKey: .totalMs)
        }
    }
}

extension RunProgressSnapshot {
    private enum CodingKeys: CodingKey {
        case schemaVersion
        case runId
        case pid
        case repoRoot
        case phase
        case startedAt
        case phaseStartedAt
        case updatedAt
        case command
        case scheme
        case destination
        case current
        case tests
        case errors
        case warnings
        case summary
        case logPath
        case exitCode
        case tree
    }
}

extension RunProgressSnapshot.TestCounts {
    private enum CodingKeys: CodingKey {
        case planned
        case passed
        case failed
        case skipped
    }
}

extension RunProgressSnapshot.Timings {
    private enum CodingKeys: CodingKey {
        case buildMs
        case testMs
        case totalMs
    }
}
