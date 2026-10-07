//
// Copyright © Agulhas Labs
//

import Foundation

/// One entry of an `llvm-cov export` file's `segments` array: a point where a counted region starts or ends.
public struct CoverageSegment: Sendable, Equatable {
    public let line: Int
    public let column: Int
    public let count: UInt64
    /// Whether the region starting here is counted at all — `false` for a region the compiler skipped.
    public let hasCount: Bool
    public let isRegionEntry: Bool
    /// A region between two statements that carries a count without being code of its own.
    public let isGapRegion: Bool

    public init(line: Int, column: Int, count: UInt64, hasCount: Bool, isRegionEntry: Bool, isGapRegion: Bool) {
        self.line = line
        self.column = column
        self.count = count
        self.hasCount = hasCount
        self.isRegionEntry = isRegionEntry
        self.isGapRegion = isGapRegion
    }
}

public extension CoverageSegment {
    /// The segment an export writes as `[line, column, count, hasCount, isRegionEntry, isGapRegion]`, or `nil` for any other shape.
    ///
    /// Exports before format 2 end at `isRegionEntry`; the missing field reads as "not a gap", which is what those versions meant.
    init?(exported fields: [Any]) {
        guard fields.count >= 5,
              let line = (fields[0] as? NSNumber)?.intValue,
              let column = (fields[1] as? NSNumber)?.intValue,
              let count = (fields[2] as? NSNumber)?.uint64Value,
              let hasCount = fields[3] as? Bool,
              let isRegionEntry = fields[4] as? Bool
        else {
            return nil
        }
        let isGapRegion = fields.count > 5 ? (fields[5] as? Bool ?? false) : false
        self.init(line: line, column: column, count: count, hasCount: hasCount, isRegionEntry: isRegionEntry, isGapRegion: isGapRegion)
    }

    /// Each line's execution count, for the lines that hold code — a line absent from the result holds none.
    ///
    /// `llvm-cov`'s own reading, so the numbers agree with `llvm-cov report`: a line is code where a counted, non-gap region starts on it or a counted region runs into it from above, unless the first segment on it opens a skipped region; its count is the largest of the region it inherits and those that start on it.
    static func lineCounts(of segments: [CoverageSegment]) -> [Int: UInt64] {
        let sorted = segments.sorted { ($0.line, $0.column) < ($1.line, $1.column) }
        guard let first = sorted.first, let last = sorted.last else {
            return [:]
        }
        var counts: [Int: UInt64] = [:]
        var wrapped: CoverageSegment?
        var index = 0
        for line in first.line ... last.line {
            var onLine: [CoverageSegment] = []
            while index < sorted.count, sorted[index].line == line {
                onLine.append(sorted[index])
                index += 1
            }
            let starts = onLine.filter { $0.hasCount && $0.isRegionEntry && !$0.isGapRegion }
            let opensSkipped = onLine.first.map { !$0.hasCount && $0.isRegionEntry } ?? false
            if !opensSkipped, wrapped?.hasCount == true || !starts.isEmpty {
                counts[line] = starts.map(\.count).reduce(wrapped?.count ?? 0, max)
            }
            if let lastOnLine = onLine.last {
                wrapped = lastOnLine
            }
        }
        return counts
    }
}
