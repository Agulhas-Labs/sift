//
// Copyright © Agulhas Labs
//

import Foundation

/// What the advice hook, as it stands now, decided about one call a transcript recorded: its outcome token, the rule that decided, the call an answer named, and how big an answer withheld over the size budget came to.
public struct ReplayVerdict: Sendable, Equatable {
    /// The rule the hook names an index call by.
    public static var indexCallRule: String {
        "adviceTaken"
    }

    /// `in-place`, `allowed`, `amended` or `deny`, as the hook's own `--verdict` line spells it.
    public let token: String
    /// The rule that decided: the one the hook's verdict names, or ``logged(_:)`` of the one its suppression log records where the verdict names none of its own (`noLookup`).
    public let rule: String
    /// The index call an in-place answer ran, where there was one.
    public let call: String?
    /// The bytes an in-place answer came to, where it was built and then withheld over the size budget.
    public let answerBytes: Int?
    /// The answer's own text — the denial reason the hook would hand the agent — where the hook still holds it.
    public let reason: String?

    public init(token: String, rule: String, call: String? = nil, answerBytes: Int? = nil, reason: String? = nil) {
        self.token = token
        self.rule = rule
        self.call = call
        self.answerBytes = answerBytes
        self.reason = reason
    }

    /// The rule a call is reported under where the hook's verdict let it through as `noLookup` but its suppression log records it withheld under `rule`, kept apart from a verdict's own rule of the same name.
    public static func logged(_ rule: String) -> String {
        "\(rule) (logged)"
    }

    /// Whether the hook would have answered the lookup in its refusal's place.
    public var recovers: Bool {
        token == "in-place"
    }

    /// Whether this call is the advice being taken — an index call — rather than a lookup the hook judged.
    public var isIndexCall: Bool {
        rule == Self.indexCallRule
    }
}
