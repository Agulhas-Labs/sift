//
// Copyright © Agulhas Labs
//

import Foundation

/// Every test plan found under one root, and every file that looked like one and could not be read.
///
/// A file that did not decode is named rather than dropped: "no plans found" and "three plans, one unreadable" are different answers, and a caller that could not tell them apart would report the second as the first.
public struct TestPlanSurvey: Sendable, Equatable {
    /// The plans that decoded, by name and then by path.
    public let plans: [TestPlanFile]
    /// The files that did not, by path.
    public let unreadable: [Unreadable]
}

public extension TestPlanSurvey {
    /// One file at the plan extension that could not be read, with the sentence a caller prints for it.
    struct Unreadable: Sendable, Equatable {
        /// Where the file sits, relative to the root it was found under.
        public let path: String
        /// Why it could not be read, as ``TestPlanError`` describes it.
        public let reason: String
    }
}
