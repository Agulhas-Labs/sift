//
// Copyright © Agulhas Labs
//

import Foundation

/// A line-level diff of one file's two sides, as bytes: the runs of lines — hunks — one side had and the other has in their place.
///
/// `diff`'s structural pass names changes by what they are; this is what that pass is checked against. Every line that differs between the two sides lands in some hunk, and every hunk must meet a line the answer names (`FileDiff`'s safety net), so nothing a line diff sees can go without a line in the answer.
///
/// Lines are compared as bytes with their terminators, so a line-ending conversion, an added byte-order mark and a change of Unicode normalization are all differences — as they are to git. The algorithm is git's default one, Myers' O(ND) diff, in its linear-space form, so hunks fall where `git diff` puts them in all but the cases where equal lines leave the placement open; and it is bounded — past ``stepBudget`` the region still being searched is reported as one hunk, which can only make a hunk larger, never lose one.
struct LineDiff {
    /// How many steps of the search one file may take before the rest of it is reported as one hunk — a bound on the time a pathological pair of files can cost, not one a real edit comes near.
    static var stepBudget: Int {
        20_000_000
    }

    /// Each line of `data` with its terminator, so `abc`, `abc\n` and `abc\r\n` are three different lines.
    static func lines(of data: Data) -> [Data] {
        var lines: [Data] = []
        var start = data.startIndex
        var index = data.startIndex
        while index < data.endIndex {
            if data[index] == 0x0A {
                lines.append(data[start ... index])
                start = data.index(after: index)
            }
            index = data.index(after: index)
        }
        if start < data.endIndex {
            lines.append(data[start ..< data.endIndex])
        }
        return lines
    }

    /// The hunks between two sides' lines, in order.
    static func hunks(old oldLines: [Data], new newLines: [Data]) -> [Hunk] {
        var ids: [Data: Int] = [:]
        func id(_ line: Data) -> Int {
            if let known = ids[line] {
                return known
            }
            ids[line] = ids.count
            return ids.count - 1
        }
        let search = Search(old: oldLines.map(id), new: newLines.map(id))
        search.diff(oldRange: 0 ..< oldLines.count, newRange: 0 ..< newLines.count)
        var hunks: [Hunk] = []
        var previous = (old: -1, new: -1)
        for match in search.matches + [(old: oldLines.count, new: newLines.count)] {
            if match.old > previous.old + 1 || match.new > previous.new + 1 {
                var hunk = Hunk(old: previous.old + 1 ..< match.old, new: previous.new + 1 ..< match.new)
                if hunk.old.isEmpty {
                    (hunk.slideUp, hunk.slideDown) = slack(of: hunk.new, in: search.new)
                } else if hunk.new.isEmpty {
                    (hunk.slideUp, hunk.slideDown) = slack(of: hunk.old, in: search.old)
                }
                hunks.append(hunk)
            }
            previous = match
        }
        return hunks
    }

    /// How far a run of inserted (or deleted) lines could slide over the equal lines either side of it.
    private static func slack(of run: Range<Int>, in lines: [Int]) -> (up: Int, down: Int) {
        var up = 0
        while run.lowerBound - up - 1 >= 0, lines[run.lowerBound - up - 1] == lines[run.upperBound - up - 1] {
            up += 1
        }
        var down = 0
        while run.upperBound + down < lines.count, lines[run.lowerBound + down] == lines[run.upperBound + down] {
            down += 1
        }
        return (up, down)
    }
}

extension LineDiff {
    /// One run of changed lines: `old` is the before side's lines (0-based, half-open) and `new` the after side's; an empty side is a pure insertion or deletion at that position.
    struct Hunk: Sendable, Equatable {
        let old: Range<Int>
        let new: Range<Int>
        /// For a pure insertion or deletion, how many lines it could slide up or down over equal lines and still be the same change — `git diff` may put it at any of those places, so all of them are this hunk.
        var slideUp = 0
        var slideDown = 0

        /// The before side's lines, 1-based, or `nil` for a pure insertion.
        var oldLines: DeclarationRange? {
            old.isEmpty ? nil : DeclarationRange(line: old.lowerBound + 1, endLine: old.upperBound)
        }

        /// The after side's lines, 1-based, or `nil` for a pure deletion.
        var newLines: DeclarationRange? {
            new.isEmpty ? nil : DeclarationRange(line: new.lowerBound + 1, endLine: new.upperBound)
        }

        /// Whether a range of before-side and after-side lines meets this hunk anywhere it could sit — or, not `sliding`, where it sits.
        func meets(old oldSpan: DeclarationRange?, new newSpan: DeclarationRange?, sliding: Bool = true) -> Bool {
            let up = sliding ? slideUp : 0
            let down = sliding ? slideDown : 0
            return Self.meets(old, slideUp: up, slideDown: down, span: oldSpan) || Self.meets(new, slideUp: up, slideDown: down, span: newSpan)
        }

        private static func meets(_ lines: Range<Int>, slideUp: Int, slideDown: Int, span: DeclarationRange?) -> Bool {
            guard !lines.isEmpty, let span else { return false }
            // Every place a sliding hunk can sit lies inside one contiguous run, so meeting the run is meeting one of them.
            return lines.lowerBound - slideUp < span.endLine && span.line - 1 < lines.upperBound + slideDown
        }
    }
}

private extension LineDiff {
    /// One file's search: the lines as numbers, the matched pairs found so far in order, and what is left of the budget.
    final class Search {
        let old: [Int]
        let new: [Int]
        var matches: [(old: Int, new: Int)] = []
        var budget = LineDiff.stepBudget

        init(old: [Int], new: [Int]) {
            self.old = old
            self.new = new
        }

        /// Matches the common prefix and suffix directly, then splits what is between at the middle snake and recurses — appending matched pairs in order.
        func diff(oldRange: Range<Int>, newRange: Range<Int>) {
            var oldLow = oldRange.lowerBound
            var newLow = newRange.lowerBound
            var oldHigh = oldRange.upperBound
            var newHigh = newRange.upperBound
            while oldLow < oldHigh, newLow < newHigh, old[oldLow] == new[newLow] {
                matches.append((oldLow, newLow))
                oldLow += 1
                newLow += 1
            }
            var suffix = 0
            while oldLow < oldHigh, newLow < newHigh, old[oldHigh - 1] == new[newHigh - 1] {
                oldHigh -= 1
                newHigh -= 1
                suffix += 1
            }
            // A split at either corner would recurse on the same region; the search never yields one, and a region it
            // could not split is left unmatched — one hunk — rather than searched again.
            if oldLow < oldHigh, newLow < newHigh, let split = middle(old: oldLow ..< oldHigh, new: newLow ..< newHigh),
               split.old != oldLow || split.new != newLow, split.old != oldHigh || split.new != newHigh
            {
                diff(oldRange: oldLow ..< split.old, newRange: newLow ..< split.new)
                diff(oldRange: split.old ..< oldHigh, newRange: split.new ..< newHigh)
            }
            for offset in 0 ..< suffix {
                matches.append((oldHigh + offset, newHigh + offset))
            }
        }

        /// Where the furthest-reaching paths from both ends first overlap — a point on an optimal path, so the two halves either side of it diff independently.
        ///
        /// `nil` when the budget runs out first, or nothing in the region is common.
        func middle(old oldRange: Range<Int>, new newRange: Range<Int>) -> (old: Int, new: Int)? {
            let oldCount = oldRange.count
            let newCount = newRange.count
            let maxD = (oldCount + newCount + 1) / 2
            let offset = maxD
            let length = 2 * maxD + 2
            var forward = [Int](repeating: -1, count: length)
            var backward = [Int](repeating: -1, count: length)
            forward[offset + 1] = 0
            backward[offset + 1] = 0
            let delta = oldCount - newCount
            let checksForward = delta % 2 != 0
            var bounds = (forwardStart: 0, forwardEnd: 0, backwardStart: 0, backwardEnd: 0)
            for d in 0 ..< maxD {
                budget -= 2 * d + 1
                guard budget > 0 else { return nil }
                var diagonal = -d + bounds.forwardStart
                while diagonal <= d - bounds.forwardEnd {
                    let index = offset + diagonal
                    var x = diagonal == -d || (diagonal != d && forward[index - 1] < forward[index + 1]) ? forward[index + 1] : forward[index - 1] + 1
                    var y = x - diagonal
                    while x < oldCount, y < newCount, old[oldRange.lowerBound + x] == new[newRange.lowerBound + y] {
                        x += 1
                        y += 1
                        budget -= 1
                    }
                    forward[index] = x
                    if x > oldCount {
                        bounds.forwardEnd += 2
                    } else if y > newCount {
                        bounds.forwardStart += 2
                    } else if checksForward {
                        let other = offset + delta - diagonal
                        if other >= 0, other < length, backward[other] != -1, x >= oldCount - backward[other] {
                            return (oldRange.lowerBound + x, newRange.lowerBound + y)
                        }
                    }
                    diagonal += 2
                }
                diagonal = -d + bounds.backwardStart
                while diagonal <= d - bounds.backwardEnd {
                    let index = offset + diagonal
                    var x = diagonal == -d || (diagonal != d && backward[index - 1] < backward[index + 1]) ? backward[index + 1] : backward[index - 1] + 1
                    var y = x - diagonal
                    while x < oldCount, y < newCount, old[oldRange.upperBound - x - 1] == new[newRange.upperBound - y - 1] {
                        x += 1
                        y += 1
                        budget -= 1
                    }
                    backward[index] = x
                    if x > oldCount {
                        bounds.backwardEnd += 2
                    } else if y > newCount {
                        bounds.backwardStart += 2
                    } else if !checksForward {
                        let other = offset + delta - diagonal
                        if other >= 0, other < length, forward[other] != -1 {
                            let forwardX = forward[other]
                            let forwardY = offset + forwardX - other
                            if forwardX >= oldCount - x {
                                return (oldRange.lowerBound + forwardX, newRange.lowerBound + forwardY)
                            }
                        }
                    }
                    diagonal += 2
                }
            }
            return nil
        }
    }
}
