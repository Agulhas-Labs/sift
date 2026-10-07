//
// Copyright © Agulhas Labs
//

import Foundation

/// The lookups the index never recorded, counted by what was missing rather than pooled into one number.
///
/// One counter per ``TextSearch/Cause``, because the causes argue for different things and a reader acting on the row has to know which one they are looking at: whether the tool should record more than declarations, whether an index is missing over some tree, or neither. ``TranscriptTally/textSearches`` is the sum, so the report's row and the lines under it can never disagree.
public struct TextSearchCauses: Sendable, Equatable, Codable {
    /// Searches whose pattern names nothing the index records — a count, a literal, a merge's markers, the text of a comment.
    public var patternNamesNothing: Int
    /// Lookups standing on a name no index this machine declares.
    public var undeclaredName: Int
    /// Reads and searches of a file no index call can name.
    public var unnameableFile: Int
    /// Searches of one named file whose pattern names nothing a declaration could be, which the share counted as misses until `sift audit` scored them as the tree form is scored.
    public var patternInOneFile: Int

    public init(patternNamesNothing: Int = 0, undeclaredName: Int = 0, unnameableFile: Int = 0, patternInOneFile: Int = 0) {
        self.patternNamesNothing = patternNamesNothing
        self.undeclaredName = undeclaredName
        self.unnameableFile = unnameableFile
        self.patternInOneFile = patternInOneFile
    }

    /// Every one of them, which is the count the row above the split reports.
    public var total: Int {
        patternNamesNothing + undeclaredName + unnameableFile + patternInOneFile
    }

    /// The counter one cause is kept in, so a fold names the cause it was handed and never a field chosen by hand.
    public subscript(cause: TextSearch.Cause) -> Int {
        get {
            switch cause {
            case .patternNamesNothing: patternNamesNothing
            case .undeclaredName: undeclaredName
            case .unnameableFile: unnameableFile
            case .patternInOneFile: patternInOneFile
            }
        }
        set {
            switch cause {
            case .patternNamesNothing: patternNamesNothing = newValue
            case .undeclaredName: undeclaredName = newValue
            case .unnameableFile: unnameableFile = newValue
            case .patternInOneFile: patternInOneFile = newValue
            }
        }
    }

    public static func += (lhs: inout TextSearchCauses, rhs: TextSearchCauses) {
        lhs.patternNamesNothing += rhs.patternNamesNothing
        lhs.undeclaredName += rhs.undeclaredName
        lhs.unnameableFile += rhs.unnameableFile
        lhs.patternInOneFile += rhs.patternInOneFile
    }
}
