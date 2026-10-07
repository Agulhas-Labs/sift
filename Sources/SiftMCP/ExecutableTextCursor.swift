//
// Copyright © Agulhas Labs
//

import Foundation

/// The executable text of a command, scanned only a few characters ahead of a position that moves forward through it and can skip a heredoc body.
///
/// What ``ShellSyntax/withoutHeredocBodies(_:)`` reads instead of scanning the whole command again after each body it takes out: the characters before the position never change, so the scan resumes from the state it had at the position, over the text that follows the body. Every body skipped costs the lines it skips and nothing more, where scanning the rest of the command again for each one cost the command's length times the number of heredocs in it.
struct ExecutableTextCursor {
    /// The command as written, in the coordinates every position here is given in.
    let written: [Character]

    /// The index in ``written`` of the character ``text(at:)`` reads at offset zero.
    private(set) var position = 0

    /// Whether putting two scanned characters side by side can join them into one, so a resumed scan may no longer match the text it stands for character for character.
    private let canMerge: Bool

    private var scan = ExecutableTextScan()
    private var scanned = 0
    private var ahead: [Character] = []
    private var statesAhead: [ExecutableTextScan] = []
    private var stateAtPosition = ExecutableTextScan()
    private var behind: Character?

    init(_ written: [Character]) {
        self.written = written
        canMerge = !written.allSatisfy { $0.isASCII || ("a" + String($0) + "a").count == 3 }
    }

    /// The executable text of the character `offset` places from the position, or nil before the start or past the end.
    mutating func text(at offset: Int) -> Character? {
        guard offset >= 0 else { return offset == -1 ? behind : nil }
        // The character after the one asked for is scanned too, since a `(` can change the `$` before it.
        while scanned < written.count, scanned < position + offset + 2 {
            scan.append(written[scanned], to: &ahead)
            statesAhead.append(scan)
            scanned += 1
        }
        return offset < ahead.count ? ahead[offset] : nil
    }

    /// Moves the position one character on.
    mutating func advance() {
        guard text(at: 0) != nil else { return }
        behind = ahead.removeFirst()
        stateAtPosition = statesAhead.removeFirst()
        position += 1
    }

    /// Moves the position to `end` and scans on from there as though the characters between had never been written.
    ///
    /// Returns whether the scan from `end` still stands one executable character for each character written, which is what the whole-text scan checks before it trusts its own text; always true where no two characters could join.
    mutating func skip(to end: Int) -> Bool {
        position = end
        scanned = end
        scan = stateAtPosition
        ahead = []
        statesAhead = []
        guard canMerge else { return true }
        var rest = ""
        var check = stateAtPosition
        for character in written[end...] {
            check.append(character, to: &rest)
        }
        return rest.count == written.count - end
    }
}
