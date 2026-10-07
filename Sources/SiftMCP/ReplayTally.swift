//
// Copyright © Agulhas Labs
//

import Foundation

/// What the current hook would do with the cold lookups of one context, or of several pooled.
public struct ReplayTally: Sendable, Equatable {
    /// Cold lookups the hook would now answer in place, by the rule that decided and the call it would run.
    public var recovered: [String: Int] = [:]
    /// Cold lookups the hook would still let through, by the rule that let each through.
    public var stillCold: [String: Int] = [:]
    /// Cold lookups the hook would let through because its answer would be no smaller than what the command prints, by the rule that let each through, out of the share.
    public var notWorth: [String: Int] = [:]
    /// Cold lookups whose directory, their own or the one their command opens by moving to, is not on disk now, so the hook cannot be asked about them.
    public var unreplayable = 0
    /// Cold lookups that became located reads of a file only an answer in place located, out of the share as a guided read is.
    public var located = 0
    /// Cold lookups that became whole reads of a file only an answer in place located, in the share as a read whole after its digest is.
    public var readWholeAfterAnswer = 0
    /// Cold lookups the hook's log records letting run on worth, which the audit's own tally holds as not worth rather than cold, so outside its total until the replay puts them back to judge them itself.
    public var loggedOnWorth = 0
    /// The calls behind ``stillCold``, by the rule that let each through, each counted once per cold lookup it carried.
    var stillColdCalls: [String: [ReplayColdCall: Int]] = [:]

    public init() {}

    /// Every cold lookup replayed, whatever became of it.
    public var cold: Int {
        recoveredCount + stillColdCount + notWorthCount + unreplayable + located + readWholeAfterAnswer
    }

    /// How many the hook would now answer in place.
    public var recoveredCount: Int {
        recovered.values.reduce(0, +)
    }

    /// How many the hook would still let through.
    public var stillColdCount: Int {
        stillCold.values.reduce(0, +)
    }

    /// How many the hook would let through as not worth answering.
    public var notWorthCount: Int {
        notWorth.values.reduce(0, +)
    }

    /// How many of `rule`'s still-cold lookups have no call behind them to group by structure — the gap between ``stillCold`` and the calls ``stillColdCalls`` holds, e.g. a lookup counted before its call could be resolved.
    public func ungroupedStillCold(for rule: String) -> Int {
        let grouped = stillColdCalls[rule]?.values.reduce(0, +) ?? 0
        return (stillCold[rule] ?? 0) - grouped
    }

    /// Adds `delta` lookups under `outcome`, made by `call` where one is known, taking them away again for a negative one.
    mutating func count(_ outcome: ReplayOutcome, call: ReplayColdCall? = nil, by delta: Int = 1) {
        switch outcome {
        case let .recovered(key):
            recovered[key, default: 0] += delta
            if recovered[key] == 0 {
                recovered[key] = nil
            }
        case let .stillCold(rule):
            stillCold[rule, default: 0] += delta
            if stillCold[rule] == 0 {
                stillCold[rule] = nil
            }
            guard let call else { return }
            var calls = stillColdCalls[rule] ?? [:]
            calls[call, default: 0] += delta
            if calls[call] == 0 {
                calls[call] = nil
            }
            stillColdCalls[rule] = calls.isEmpty ? nil : calls
        case let .notWorth(rule):
            notWorth[rule, default: 0] += delta
            if notWorth[rule] == 0 {
                notWorth[rule] = nil
            }
        case .unreplayable:
            unreplayable += delta
        case .located:
            located += delta
        case .readWholeAfterAnswer:
            readWholeAfterAnswer += delta
        }
    }

    public static func += (lhs: inout ReplayTally, rhs: ReplayTally) {
        lhs.recovered.merge(rhs.recovered, uniquingKeysWith: +)
        lhs.stillCold.merge(rhs.stillCold, uniquingKeysWith: +)
        lhs.notWorth.merge(rhs.notWorth, uniquingKeysWith: +)
        lhs.unreplayable += rhs.unreplayable
        lhs.located += rhs.located
        lhs.readWholeAfterAnswer += rhs.readWholeAfterAnswer
        lhs.loggedOnWorth += rhs.loggedOnWorth
        lhs.stillColdCalls.merge(rhs.stillColdCalls) { $0.merging($1, uniquingKeysWith: +) }
    }
}
