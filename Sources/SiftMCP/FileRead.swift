//
// Copyright © Agulhas Labs
//

import Foundation

/// One file one tool call reads, as ``AnswerThenRead`` pairs an answer with what follows it.
struct FileRead: Equatable {
    /// The file, spelled out against the call's working directory wherever that allows.
    let path: String

    /// Whether the call reads the file whole.
    let whole: Bool

    /// What a re-run of this reading is recognised by: the tool, the file, and the call's own reading of it.
    let reread: String
}
