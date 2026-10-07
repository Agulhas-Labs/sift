//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Pins that a `name:/…/` pattern repeating a group is refused before any matching, and that every other regex is still read.
struct SearchRepeatedGroupTests {
    /// The refusal text for `query`, or nil when it parses.
    private static func refusal(_ query: String) -> String? {
        do {
            _ = try StructuralQuery(query)
            return nil
        } catch {
            return String(describing: error)
        }
    }

    /// A repeated group is refused in one line saying why, and promptly.
    @Test(arguments: ["name:/^(a+)+$/", "name:/(ab)*c/", "name:/(a|b){2,}/"])
    func aRepeatedGroupIsRefused(query: String) throws {
        let started = ContinuousClock.now
        let text = try #require(Self.refusal(query), "\(query) parsed")
        #expect(ContinuousClock.now - started < .seconds(5))
        #expect(!text.contains("\n"), "\(text)")
        #expect(text.contains("a repeated group can take unbounded time"), "\(text)")
        #expect(text.contains("write the alternatives out or repeat a character class instead"), "\(text)")
    }

    /// A refused pattern never reaches a declaration that would make it backtrack.
    @Test
    func theCatastrophicCaseReturnsAtOnce() throws {
        let started = ContinuousClock.now
        #expect(throws: EngineError.self) {
            try StructuralMatcher.matches(
                in: "func aaaaaaaaaaaaaaaaaaaaaaaac() {}",
                path: "Sources/App/Box.swift",
                query: StructuralQuery("name:/^(a+)+$/")
            )
        }
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    /// An optional group, a character class repeated, an escaped parenthesis and one inside a class are all still regexes.
    @Test(arguments: ["name:/(?i)loop|closed/", "name:/[a-z]+Name$/", "name:/(get)?Value/", #"name:/a\)+/"#, "name:/[)]+x/"])
    func otherPatternsAreStillRead(query: String) {
        #expect(Self.refusal(query) == nil, "\(query)")
    }
}
