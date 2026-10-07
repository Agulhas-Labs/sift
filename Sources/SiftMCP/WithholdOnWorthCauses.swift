//
// Copyright © Agulhas Labs
//

import Foundation

/// The lookups the index owned and lost on a judgement of worth, counted by which rule made that judgement rather than pooled into one number.
///
/// One counter per ``TextSearch/Rule``, mirroring ``TextSearchCauses`` for the other half: the rules argue for different things — `contextLines` and `severalNames` are the index giving a weaker answer than was asked, `filteredOutput` is a pipeline asking for lines no index answer prints, `retryAllowed` is a refusal whose identical re-run the hook already let through, `notSmaller` is a window whose answer would have cost no less than the lines it prints, `linesNotShown` is a window whose answer would not show the lines it asks for, `notWorthTheTurn` is a whole read whose digest spares less than the turn after it costs — and a reader acting on the row has to know which one they are looking at. ``TranscriptTally/withheldOnWorth`` is the sum, so the report's row and the lines under it can never disagree.
public struct WithholdOnWorthCauses: Sendable, Equatable, Codable {
    /// A grep of one named file printing context around its matches, where the pattern is not a member's declaration.
    public var contextLines: Int
    /// An alternation of two or more names, confined to the files the search names.
    public var severalNames: Int
    /// A read or search whose output a later stage of the same pipeline filters.
    public var filteredOutput: Int
    /// A lookup the hook refused, whose identical re-run it then allowed.
    public var retryAllowed: Int
    /// A name search of the Swift files it names outright, which the hook lets run.
    public var namedFiles: Int
    /// A read the hook let run — a line window or a whole file — its index answer no smaller than what it prints.
    public var notSmaller: Int
    /// A window the hook let run, its answer not showing the lines asked for.
    public var linesNotShown: Int
    /// A search printing only the names of the files it matches.
    public var filesOnly: Int
    /// A whole read of a Swift file the hook let run, its digest sparing less than the turn after it costs.
    public var notWorthTheTurn: Int

    public init(contextLines: Int = 0, severalNames: Int = 0, filteredOutput: Int = 0, retryAllowed: Int = 0, notSmaller: Int = 0, linesNotShown: Int = 0, filesOnly: Int = 0, notWorthTheTurn: Int = 0, namedFiles: Int = 0) {
        self.contextLines = contextLines
        self.severalNames = severalNames
        self.filteredOutput = filteredOutput
        self.retryAllowed = retryAllowed
        self.notSmaller = notSmaller
        self.linesNotShown = linesNotShown
        self.filesOnly = filesOnly
        self.notWorthTheTurn = notWorthTheTurn
        self.namedFiles = namedFiles
    }

    /// Every one of them, which is the count the row above the split reports.
    public var total: Int {
        contextLines + severalNames + filteredOutput + retryAllowed + notSmaller + linesNotShown + filesOnly + notWorthTheTurn + namedFiles
    }

    /// The counter one rule is kept in, so a fold names the rule it was handed and never a field chosen by hand.
    public subscript(rule: TextSearch.Rule) -> Int {
        get {
            switch rule {
            case .contextLines: contextLines
            case .severalNames: severalNames
            case .filteredOutput: filteredOutput
            case .retryAllowed: retryAllowed
            case .notSmaller: notSmaller
            case .linesNotShown: linesNotShown
            case .filesOnly: filesOnly
            case .notWorthTheTurn: notWorthTheTurn
            case .namedFiles: namedFiles
            }
        }
        set {
            switch rule {
            case .contextLines: contextLines = newValue
            case .severalNames: severalNames = newValue
            case .filteredOutput: filteredOutput = newValue
            case .retryAllowed: retryAllowed = newValue
            case .notSmaller: notSmaller = newValue
            case .linesNotShown: linesNotShown = newValue
            case .filesOnly: filesOnly = newValue
            case .notWorthTheTurn: notWorthTheTurn = newValue
            case .namedFiles: namedFiles = newValue
            }
        }
    }

    public static func += (lhs: inout WithholdOnWorthCauses, rhs: WithholdOnWorthCauses) {
        lhs.contextLines += rhs.contextLines
        lhs.severalNames += rhs.severalNames
        lhs.filteredOutput += rhs.filteredOutput
        lhs.retryAllowed += rhs.retryAllowed
        lhs.notSmaller += rhs.notSmaller
        lhs.linesNotShown += rhs.linesNotShown
        lhs.filesOnly += rhs.filesOnly
        lhs.notWorthTheTurn += rhs.notWorthTheTurn
        lhs.namedFiles += rhs.namedFiles
    }
}
