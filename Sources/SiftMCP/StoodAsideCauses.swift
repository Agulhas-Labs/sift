//
// Copyright © Agulhas Labs
//

import Foundation

/// The cold lookups the hook stood aside from, by cause.
///
/// A count within `cold`, never beside it (``StoodAside``).
public struct StoodAsideCauses: Sendable, Equatable, Codable {
    /// Cold lookups let through while the hook was backing a shape off after an earlier answer of it ran past its budget.
    public var backingOff = 0
    /// Cold lookups whose own answer ran out of time.
    public var overTime = 0

    public init(backingOff: Int = 0, overTime: Int = 0) {
        self.backingOff = backingOff
        self.overTime = overTime
    }

    public subscript(cause: StoodAside) -> Int {
        get {
            switch cause {
            case .backingOff: backingOff
            case .overTime: overTime
            }
        }
        set {
            switch cause {
            case .backingOff: backingOff = newValue
            case .overTime: overTime = newValue
            }
        }
    }

    /// The rows under `cold` that name each cause, printed unconditionally like `batched` above them so a diff of two audits sees each line missing for a reason rather than because it was zero.
    ///
    /// Still misses, so nothing here moves the counts above. `overruns` is the log's own count of answers that ran past their budget in the window, which the lookups' count cannot give: one overrun arms a back-off that lets many later lookups through.
    func auditLines(overruns: Int, pad: (Int) -> String) -> [String] {
        [
            "    backed off\(pad(backingOff))  of those, let through while the hook stood aside after an answer of that shape ran past its time budget (\(overruns) overrun\(overruns == 1 ? "" : "s"))",
            "    over time \(pad(overTime))  of those, a lookup whose own answer ran out of time",
        ]
    }

    public static func += (lhs: inout StoodAsideCauses, rhs: StoodAsideCauses) {
        for cause in StoodAside.allCases {
            lhs[cause] += rhs[cause]
        }
    }
}
