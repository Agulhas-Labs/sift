//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers the `sift run` allow rules going into `permissions.allow` and back out, where the risk is taking out a rule the user wrote.
struct RunAllowRulesTests {
    private static func settings(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    private static func object(_ data: Data?, sourceLocation: SourceLocation = #_sourceLocation) throws -> [String: Any] {
        let data = try #require(data, sourceLocation: sourceLocation)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any], sourceLocation: sourceLocation)
    }

    /// Into a file with no settings at all, every rule goes in, under a `permissions.allow` made for it.
    @Test
    func everyRuleIsAddedWhereThereAreNone() throws {
        let added = try Self.object(RunAllowRules.adding(to: nil))

        #expect((added["permissions"] as? [String: Any])?["allow"] as? [String] == RunAllowRules.rules)
    }

    /// Adding and then removing leaves the settings as they were — the absent `permissions` key included, and every other key and rule untouched.
    @Test(arguments: [
        "{}",
        #"{"model": "opus"}"#,
        #"{"permissions": {"deny": ["Bash(rm:*)"]}}"#,
        #"{"permissions": {"allow": ["Bash(ls:*)", 7], "deny": []}, "hooks": {}}"#,
    ])
    func addingThenRemovingIsAnExactInverse(original: String) throws {
        let data = Data(original.utf8)
        let added = try #require(try RunAllowRules.adding(to: data))
        let removed = try RunAllowRules.removing(from: added) ?? added

        #expect(try NSDictionary(dictionary: Self.object(removed)) == NSDictionary(dictionary: Self.object(data)))
    }

    /// A rule the user wrote, one of the set but not the whole of it, stays: only the whole set is recognised as the install's.
    @Test
    func aRuleTheUserWroteSurvivesRemoval() throws {
        let data = try Self.settings(["permissions": ["allow": ["Bash(sift run -- swift test:*)", "Bash(sift run:*)"]]])

        #expect(try RunAllowRules.removing(from: data) == nil)
        #expect(try RunAllowRules.missing(from: data) == RunAllowRules.rules.filter { $0 != "Bash(sift run -- swift test:*)" })
    }

    /// Where the rules are all there already, nothing is added, so the file is not rewritten.
    @Test
    func nothingIsAddedWhereEveryRuleIsPresent() throws {
        let data = try Self.settings(["permissions": ["allow": RunAllowRules.rules]])

        #expect(try RunAllowRules.adding(to: data) == nil)
        #expect(try RunAllowRules.missing(from: data).isEmpty)
    }

    /// A `permissions` or `allow` of the wrong shape is refused, never replaced.
    @Test
    func aContainerOfTheWrongShapeIsRefused() throws {
        #expect(throws: HookRegistrationError.permissionsNotMergeable(key: "permissions")) {
            try RunAllowRules.adding(to: Self.settings(["permissions": ["Bash"]]))
        }
        #expect(throws: HookRegistrationError.permissionsNotMergeable(key: "allow")) {
            try RunAllowRules.removing(from: Self.settings(["permissions": ["allow": "Bash"]]))
        }
    }

    /// A rule of the set the user wrote — one of them, all four scattered, or one written twice — is still there, and only once, after an install and an uninstall.
    @Test(arguments: [
        #"["Bash(sift run -- swift test:*)", "Bash(ls -a)"]"#,
        #"["Bash(sift run -- swift build:*)", "Bash(ls)", "Bash(sift run -- swift test:*)", "Bash(sift run -- xcodebuild:*)", "Bash(sift run -- swiftlint:*)"]"#,
        #"["Bash(sift run -- swift test:*)", "Bash(ls)", "Bash(sift run -- swift test:*)"]"#,
    ])
    func theUsersOwnCopiesSurviveAnInstallAndRemoval(allow: String) throws {
        let data = Data(#"{"permissions": {"allow": \#(allow)}}"#.utf8)
        let added = try RunAllowRules.adding(to: data) ?? data
        let removed = try RunAllowRules.removing(from: added) ?? added

        #expect(try NSDictionary(dictionary: Self.object(removed)) == NSDictionary(dictionary: Self.object(data)))
    }
}
