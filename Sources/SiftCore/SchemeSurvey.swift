//
// Copyright © Agulhas Labs
//

import Foundation

/// Every scheme found under one root, and every file that looked like one and could not be read.
///
/// A survey that found nothing is different from one that was never taken, and both are said in the answer: a repository with no readable scheme is owed the weaker claim about what runs its targets, and one where a scheme would not parse is owed the file's name.
public struct SchemeSurvey: Sendable, Equatable {
    /// The schemes that parsed, by path.
    public let schemes: [SchemeFile]
    /// The files that did not, by path.
    public let unreadable: [Unreadable]

    /// The survey a caller that read no scheme at all hands over, which is what makes "no scheme was read" the default claim rather than an accident.
    public static let unread = SchemeSurvey(schemes: [], unreadable: [])
}

public extension SchemeSurvey {
    /// One file at the scheme extension that could not be read, with the sentence a caller prints for it.
    struct Unreadable: Sendable, Equatable {
        /// Where the file sits, relative to the root it was found under.
        public let path: String
        /// Why it could not be read, as ``SchemeError`` describes it.
        public let reason: String
    }
}
