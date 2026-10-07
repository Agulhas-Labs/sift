//
// Copyright © Agulhas Labs
//

import Foundation

/// A shell line that prints a Swift file whole after this context received that file's whole digest, scored as the whole `Read` of it is: read whole after its digest.
///
/// Left to the shell's own reading, such a line is a cold lookup like any other — a miss in the share, but not the miss that names the file, and not counted among the whole reads after a digest that every face states beside its saving. A whole read is the same read whichever tool made it.
///
/// The whole reads are drawn as an in-place answer's reads are (``AnswerThenRead/files(readBy:cwd:)``): the hook's own shapes — a `cat` or `cat -n` of one file, an `awk` printing every line — and a `cat` of several files, each placed where the line's literal `cd`s moved it. A window is no whole read, and the share scores `sed -n '1,$p'` as one, as it scores a ranged `Read` whatever its range: guided where an index call located the file, so never rescored here.
struct ShellReadAfterDigest {
    /// The first file `block` reads whole, spelled out in full, that this context already holds a whole digest of and that is over the digest floor — or `nil`.
    ///
    /// The floor is asked as the whole `Read` asks it, and only of a file that was digested, so a line reading files no digest touched never probes the disk for them.
    static func file(
        readBy block: [String: Any],
        cwd: String?,
        directory: String?,
        state: inout TranscriptScanState,
        belowFloor: (String) -> Bool,
        consultFilesystem: Bool
    ) -> String? {
        for read in AnswerThenRead.files(readBy: block, cwd: cwd) where read.whole && read.path.hasPrefix("/") {
            guard state.digestedWhole(read.path, in: TranscriptScan.locatingRoot(ofFile: read.path, in: directory)),
                  !TranscriptScan.isBelowFloor(read.path, state: &state, belowFloor: belowFloor, consultFilesystem: consultFilesystem)
            else {
                continue
            }
            return read.path
        }
        return nil
    }

    /// `reading` with a cold lookup rescored as a whole read of `file` after its digest, where the line read one.
    ///
    /// Only a cold lookup is rescored, as the whole `Read`'s order of verdicts has it: a re-run the hook already answered, and a lookup withheld on its worth or reach, keep what they are.
    static func rescoring(_ reading: LetThroughFallback, readingWhole file: String?) -> LetThroughFallback {
        guard let file, case .cold = reading.lookup else { return reading }
        var rescored = reading
        rescored.lookup = .readWholeAfterDigest(file: file)
        return rescored
    }
}
