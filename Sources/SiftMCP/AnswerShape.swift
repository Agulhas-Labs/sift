//
// Copyright © Agulhas Labs
//

import Foundation

/// What an in-place answer to a read of one file handed back in the read's place, as the audit's miss rate is split.
public enum AnswerShape: String, Sendable, Equatable, Codable, CodingKeyRepresentable, CaseIterable {
    /// A Markdown document's heading outline, for a whole read of it.
    case outline

    /// A Swift file's whole digest, for a whole read of it or for a window the digest answers as a whole read.
    case digest

    /// The members a line window falls in, bounded to those lines.
    case window
}
