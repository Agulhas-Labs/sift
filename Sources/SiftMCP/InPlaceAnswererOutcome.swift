//
// Copyright © Agulhas Labs
//

import Foundation

public extension InPlaceAnswerer {
    /// An answer ready to print, with what the usage log records for it.
    struct Answered: Sendable, Equatable {
        /// The whole refusal, answer included.
        public let reason: String
        /// The calls that answered, one usage line each.
        public let calls: [Call]
        /// The repository the answer was computed from.
        public let root: String
        /// How long answering took, the engine open and the search included.
        public let milliseconds: Int

        public init(reason: String, calls: [Call], root: String, milliseconds: Int) {
            self.reason = reason
            self.calls = calls
            self.root = root
            self.milliseconds = milliseconds
        }
    }

    /// One call an answer is made of, as the usage log records it.
    struct Call: Sendable, Equatable {
        /// `digest` or `where`.
        public let tool: String
        /// What the call was asked about.
        public let target: String
        /// What it served — every byte of the refusal is charged to one call — and the source it stands in for, where the call weighed one.
        public let bytes: AnswerBytes

        public init(tool: String, target: String, bytes: AnswerBytes) {
            self.tool = tool
            self.target = target
            self.bytes = bytes
        }
    }

    /// Why an answer was not given, and the refusal stood instead.
    enum Withholding: String, Sendable, Equatable, Error {
        /// No repository behind the call.
        case noRepository
        /// The operands of a sweep name more than one repository.
        case outsideRoot
        /// A sweep in a repository with no index store, where no `where` answer lists a reference.
        case noStore
        /// The shape ran out of time in the repository within the back-off window (``InPlaceBackoff``).
        case backingOff
        /// Every site the answer locates lies outside the subtrees the search named, so the search itself would have printed nothing.
        case outsideSearch
        /// The search the command makes could not be reproduced exactly.
        case unchecked
        /// The answer does not account for every line the command would print, or resolved to something else.
        case notExact
        /// An answer is no smaller than the source it stands in for — a window's digest or the members it overlaps against the lines the window prints, a whole read's digest against the file — or a read's closing line can state no size that is its own, so running the command costs less.
        case notSmaller
        /// A window's file holds an unresolved merge conflict marker at a line start, which nothing but the raw text resolves.
        case conflicted
        /// The file a read names holds a parse error, so its digest is what the broken parse produced rather than the file, and only the raw text shows the error.
        case parseError
        /// Another statement on the line prints what the answer does not reproduce, so answering one part would leave the rest to a re-run of the whole line.
        case otherStatementsRun
        /// A document's heading outline is more than a third of the document's size, so it is no answer worth a turn.
        case outlineTooLarge
        /// A window's answer would not show the text of the lines it asks for — lines in a declaration's leading doc comment, lines whose answer would name one member's declaration and nothing else (no view outline), or any lines where it saves less than ``InPlaceAnswer/windowSavingFloor`` — so the identical re-run would follow it, and the window runs.
        case linesNotShown
        /// A whole read of a Swift file whose digest spares less than the turn that follows it costs, judged by ``WholeReadWorth`` from the file's size, the answer's and the context's, so the read runs.
        case notWorthTheTurn
        /// The repository cannot be written, so its index would be held in memory and built by parsing the whole tree for this one call, which the hook, a process of its own per call, would pay on every call (``SiftEngine/wouldKeepIndexInMemory(root:)``).
        case treeNotWritable
        case failed, overTime, overSize
    }

    /// An answer, or why the refusal stood.
    enum Outcome: Sendable, Equatable {
        case answered(Answered)
        case withheld(Withholding)
    }
}
