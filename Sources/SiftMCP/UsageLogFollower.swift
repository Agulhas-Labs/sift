//
// Copyright © Agulhas Labs
//

import Foundation

/// The usage log read once and followed as it grows, for a process that asks it the same question thousands of times: a replay, which appends to its own log as it walks.
///
/// The one-shot hook reads the log's last ``DigestedFiles/tailBytes`` afresh for each question, which is right for a process that asks once or twice and ends. A replay asks for every call it judges, and its log grows with the replay, so reading the tail afresh made each call cost more than the one before it. This reads each byte once, parses a line only where it could serve a digest question, and files it under the session it names.
///
/// **Each question sees the lines a fresh read of the tail would have seen**: every whole line that begins after the tail's first byte, or every line when the log is no longer than the tail, and a last line not yet ended as a fresh read would split it. Lines that have fallen out of the tail are dropped as they fall. A log that has shrunk since the last question is read again from its tail, as though it had never been read.
final class UsageLogFollower: @unchecked Sendable {
    private let fileURL: URL
    private let limit: UInt64
    private let lock = NSLock()
    /// The offset of the first byte not yet taken in as part of a whole line.
    private var consumed: UInt64 = 0
    private var started = false
    /// Whether the bytes before the first newline still to come are the end of a line that began before the tail, which a fresh read of the tail cuts off.
    private var skipsFragment = false
    private var bySession: [String: [FollowedUsageLine]] = [:]
    private var bytesRead = 0

    init(fileURL: URL, limit: Int = DigestedFiles.tailBytes) {
        self.fileURL = fileURL
        self.limit = UInt64(limit)
    }

    /// How many bytes of the log this has read in all, which a log read once keeps no larger than the log.
    var bytesReadSoFar: Int {
        lock.withLock { bytesRead }
    }

    /// The lines of the log's tail as it stands now that carry `session`, oldest first; `nil` where the log cannot be read.
    func lines(of session: String) -> [FollowedUsageLine]? {
        lock.withLock {
            guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return nil }
            defer { try? handle.close() }
            guard let size = try? handle.seekToEnd() else { return nil }
            let windowStart = size > limit ? size - limit : 0
            if !started || size < consumed {
                started = true
                bySession = [:]
                consumed = windowStart
                skipsFragment = windowStart > 0
            }
            var trailing: FollowedUsageLine?
            if size > consumed {
                guard (try? handle.seek(toOffset: consumed)) != nil,
                      let data = try? handle.read(upToCount: Int(size - consumed))
                else { return nil }
                bytesRead += data.count
                trailing = take(data)
            }
            // Only a fresh read's cut decides what is in the tail: a line is in it when it begins after the tail's first byte.
            let inTail = { (line: FollowedUsageLine) in windowStart == 0 || line.offset > windowStart }
            // Filed oldest first, so the lines that have fallen out of the tail are a prefix, and never come back.
            var kept = bySession[session] ?? []
            let fallen = kept.firstIndex(where: inTail) ?? kept.count
            if fallen > 0 {
                kept.removeFirst(fallen)
                bySession[session] = kept.isEmpty ? nil : kept
            }
            if let trailing, trailing.session == session, inTail(trailing) {
                kept.append(trailing)
            }
            return kept
        }
    }

    /// Takes in the whole lines of `data`, read from ``consumed``, and hands back the line it ends in where that line has no newline yet — read again next time rather than kept.
    private func take(_ data: Data) -> FollowedUsageLine? {
        var lineStart = data.startIndex
        while let newline = data[lineStart...].firstIndex(of: 0x0A) {
            let offset = consumed + UInt64(lineStart - data.startIndex)
            if skipsFragment {
                skipsFragment = false
            } else if let line = FollowedUsageLine(data[lineStart ..< newline], at: offset) {
                bySession[line.session, default: []].append(line)
            }
            lineStart = data.index(after: newline)
        }
        let offset = consumed + UInt64(lineStart - data.startIndex)
        consumed = offset
        guard !skipsFragment, lineStart < data.endIndex else { return nil }
        return FollowedUsageLine(data[lineStart...], at: offset)
    }
}
