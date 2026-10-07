//
// Copyright © Agulhas Labs
//

import Foundation

/// Reads a rendered digest back into the members it listed.
public struct DigestAnswer {
    /// Every member line the digest carried, with the line range it advertised.
    ///
    /// Parsed rather than regexed: this runs over every digest answer in a month of transcripts, and the shape is fixed and simple enough that a scan is both faster and easier to reason about at the edges.
    public static func members(in answer: String) -> [DigestMember] {
        var members: [DigestMember] = []
        for line in answer.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let range = advertisedRange(in: line) else { continue }
            let head = line.prefix(range.start)
            // The declaration without the count that follows it: "struct CrateSet: Equatable — 5 members"
            // reads back as the declaration, not as the arithmetic.
            let declaration = head.range(of: " — ", options: .backwards).map { head[..<$0.lowerBound] } ?? head
            members.append(DigestMember(
                name: String(declaration).trimmingCharacters(in: .whitespaces),
                low: range.low,
                high: range.high,
                collapsed: isCollapsedContainer(line)
            ))
        }
        // A container was only "shown as a count" if the answer really withheld its children. A file digest
        // renders its top-level line in the count form and then enumerates every child on the lines below, so the
        // *line* names nothing while the *answer* names everything — and a read of one of those children, landing
        // on the container by whichever tie-break, scored the loop working as the gap the row exists to count.
        //
        // No tie-break fixes this: each one trades one class of false positive for another, which is the signal
        // that the fault is a layer down. Any listed member lying inside a container is proof its names were not
        // withheld, and it is decidable from the parsed list alone — no renderer change, and it reads the answer
        // the session was actually shown.
        for index in members.indices where members[index].collapsed {
            let container = members[index]
            let namesAChild = members.indices.contains { other in
                other != index
                    && members[other].low >= container.low
                    && members[other].high <= container.high
                    && !(members[other].low == container.low && members[other].high == container.high)
            }
            if namesAChild {
                members[index].collapsed = false
            }
        }
        return members
    }

    /// The `:12-34` (or `:12`) a digest line ends its signature with, and where in the line it began.
    ///
    /// Anchored on a space before the colon and a digit straight after it, which is what separates a line range from the colons a signature is full of — `func f(a: Int)` and `[key: 2]` both put a space after the colon, never before it.
    private static func advertisedRange(in line: Substring) -> Advertised? {
        let characters = Array(line)
        var index = 0
        while index + 1 < characters.count {
            defer { index += 1 }
            guard characters[index] == ":", index > 0, characters[index - 1] == " ",
                  characters[index + 1].isNumber else { continue }
            var cursor = index + 1
            var low = 0
            while cursor < characters.count, let digit = characters[cursor].wholeNumberValue, characters[cursor].isNumber {
                low = low * 10 + digit
                cursor += 1
            }
            var high = low
            if cursor < characters.count, characters[cursor] == "-", cursor + 1 < characters.count, characters[cursor + 1].isNumber {
                cursor += 1
                high = 0
                while cursor < characters.count, let digit = characters[cursor].wholeNumberValue, characters[cursor].isNumber {
                    high = high * 10 + digit
                    cursor += 1
                }
            }
            return Advertised(start: index, low: low, high: max(low, high))
        }
        return nil
    }

    /// Whether the line is a nested container the digest counted instead of naming.
    private static func isCollapsedContainer(_ line: Substring) -> Bool {
        guard let marker = line.range(of: " members") ?? line.range(of: " cases/members") else { return false }
        // "— 5 members" is the count form; the expanded form continues ": id stroke distance".
        let after = line[marker.upperBound...]
        guard !after.hasPrefix(":") else { return false }
        let before = line[..<marker.lowerBound]
        guard let dash = before.range(of: "— ", options: .backwards) else { return false }
        let count = before[dash.upperBound...]
        // A container with nothing in it had no names to withhold, so it is not a gap anyone can act on —
        // and "— 0 members" would otherwise be reported in the row the audit calls the actionable one.
        return !count.isEmpty && count.allSatisfy(\.isNumber) && Int(count) != 0
    }
}

private extension DigestAnswer {
    /// A line range a digest advertised, and where in the line it started.
    struct Advertised {
        let start: Int
        let low: Int
        let high: Int
    }
}
