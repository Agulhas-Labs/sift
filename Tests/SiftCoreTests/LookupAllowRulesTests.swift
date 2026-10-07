//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers the lookup allow rules going into `permissions.allow` and back out beside the `sift run` rules, where the risk is taking out, or duplicating, a rule that is not theirs.
struct LookupAllowRulesTests {
    private static func settings(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    private static func allow(_ data: Data?, sourceLocation: SourceLocation = #_sourceLocation) throws -> [String] {
        let data = try #require(data, sourceLocation: sourceLocation)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any], sourceLocation: sourceLocation)
        return try #require((object["permissions"] as? [String: Any])?["allow"] as? [String], sourceLocation: sourceLocation)
    }

    /// The four read-only lookups, each as its own rule and nothing broader.
    @Test
    func theRulesAreTheFourLookupsAndNothingBroader() {
        #expect(LookupAllowRules.rules == ["Bash(sift digest:*)", "Bash(sift where:*)", "Bash(sift search:*)", "Bash(sift strings:*)"])
    }

    /// Into a file with no settings, every rule goes in; a second pass adds nothing.
    @Test
    func everyRuleIsAddedOnceWhereThereAreNone() throws {
        let added = try #require(try LookupAllowRules.adding(to: nil))

        #expect(try Self.allow(added) == LookupAllowRules.rules)
        #expect(try LookupAllowRules.adding(to: added) == nil)
    }

    /// Over a file already holding the run rules, only the lookups are added, and the run block stays whole before them.
    @Test
    func theRunRulesAreKeptAndNotRepeated() throws {
        let data = try Self.settings(["permissions": ["allow": ["Bash(ls:*)"] + RunAllowRules.rules]])

        let added = try LookupAllowRules.adding(to: data)

        #expect(try Self.allow(added) == ["Bash(ls:*)"] + RunAllowRules.rules + LookupAllowRules.rules)
    }

    /// Taking the lookups out leaves the run rules, the user's own rules and the file's other content.
    @Test
    func removalTakesOnlyTheLookupBlock() throws {
        let data = try Self.settings(["model": "x", "permissions": ["allow": ["Bash(ls:*)"] + RunAllowRules.rules + LookupAllowRules.rules, "deny": ["Bash(rm:*)"]]])

        let removed = try #require(try LookupAllowRules.removing(from: data))
        let object = try #require(JSONSerialization.jsonObject(with: removed) as? [String: Any])

        #expect(try Self.allow(removed) == ["Bash(ls:*)"] + RunAllowRules.rules)
        #expect(object["model"] as? String == "x")
        #expect((object["permissions"] as? [String: Any])?["deny"] as? [String] == ["Bash(rm:*)"])
    }

    /// A lookup rule the user wrote alone is not a block, so it stays.
    @Test
    func aRuleTheUserWroteIsNotRemoved() throws {
        let data = try Self.settings(["permissions": ["allow": ["Bash(sift where:*)"]]])

        #expect(try LookupAllowRules.removing(from: data) == nil)
        #expect(try LookupAllowRules.missing(from: data) == LookupAllowRules.rules.filter { $0 != "Bash(sift where:*)" })
    }
}
