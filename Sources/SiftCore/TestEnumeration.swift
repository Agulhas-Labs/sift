//
// Copyright © Agulhas Labs
//

import Foundation

/// The set of tests one plan will run, as `xcodebuild` itself enumerated them before anything ran.
///
/// Read from `xcodebuild … -enumerate-tests -test-enumeration-style flat -test-enumeration-format json`, whose document is `{"errors":[],"values":[{"testPlan":"Default","enabledTests":[{"identifier":"…"}],"disabledTests":[]}]}`. **This is the inventory the whole sharded answer is reconciled against** — the counts in that answer are taken against this set rather than off the last tally a runner printed, because a sharded run has no closing line worth believing.
///
/// ``disabledTests`` is not the same thing as a skip: measured on the demo project (17 Sep 2026), a `.disabled` Swift Testing test is listed as *enabled*, because switching it off is a decision taken at run time rather than an exclusion the plan carries.
public struct TestEnumeration: Sendable, Equatable {
    /// The plan that will run, as the enumeration named it.
    public let testPlan: String

    /// The tests the plan will run — the expected set.
    public let enabledTests: [TestIdentifier]

    /// The tests the plan carries with its own exclusion switched on, which will not run.
    public let disabledTests: [TestIdentifier]
}

// MARK: - Reading the document

extension TestEnumeration {
    /// Reads one enumeration document, or throws the sentence saying why it cannot be read as one plan's set of tests.
    ///
    /// **Several plans, no plan, or a non-empty `errors` each stop the run**, because each one means the expected set is not the thing this reader was handed. One plan per run is the design's rule: shards that mixed plans would put a combination of targets on one device that no serial run ever exercised, and the plan's own exclusions live in the `.xctestrun` file a shard runs from.
    public static func read(_ data: Data) throws -> TestEnumeration {
        let document: Document
        do {
            document = try JSONDecoder().decode(Document.self, from: data)
        } catch {
            throw TestEnumerationError.unreadable("\(error)")
        }
        let errors = document.errors ?? []
        guard errors.isEmpty else {
            throw TestEnumerationError.reported(errors.map(\.text))
        }
        let values = document.values ?? []
        guard let value = values.first else {
            throw TestEnumerationError.noTestPlan
        }
        guard values.count == 1 else {
            throw TestEnumerationError.severalTestPlans(values.map(\.testPlan))
        }
        let enabled = try identifiers(of: value.enabledTests ?? [])
        let disabled = try identifiers(of: value.disabledTests ?? [])
        return TestEnumeration(testPlan: value.testPlan, enabledTests: enabled, disabledTests: disabled)
    }

    private static func identifiers(of tests: [Document.TestEntry]) throws -> [TestIdentifier] {
        try tests.map { test in
            guard let identifier = TestIdentifier(enumerated: test.identifier) else {
                throw TestEnumerationError.unreadableIdentifier(test.identifier)
            }
            return identifier
        }
    }

    /// The document as `xcodebuild` writes it, decoded no more deeply than this reader needs.
    ///
    /// Every collection is optional, so a document that simply omits one is read as empty rather than as unreadable — the distinction that matters is *no plan* against *several*, and both of those are answered above. The two lists of tests carry the same element shape, which is measured: `disabledTests` was empty in every capture, and its entries are `{"identifier": "…"}` like `enabledTests`'.
    fileprivate struct Document: Decodable {
        let errors: [Entry]?
        let values: [Value]?
    }
}

// MARK: - The document's own shapes

extension TestEnumeration.Document {
    /// One test plan's entry: the plan's name and the two lists of tests it carries.
    struct Value: Decodable {
        let testPlan: String
        let enabledTests: [TestEnumeration.Document.TestEntry]?
        let disabledTests: [TestEnumeration.Document.TestEntry]?
    }

    /// One test, in the one field either list carries — measured: `disabledTests` was empty in every capture, and its entries take `enabledTests`' shape.
    struct TestEntry: Decodable {
        let identifier: String
    }

    /// One entry of `errors`, read permissively because its shape was never observed non-empty.
    ///
    /// **Three readings, and the third one always succeeds.** A string is taken as it stands; an object is read for its string-valued fields, which is the shape a message and a code would most plausibly arrive in; anything else becomes a stand-in that says an entry was there. Refusing to decode the document over an error entry would turn `xcodebuild` reporting a problem into sift reporting a parse failure — and the problem, not the parse, is what the caller has to act on.
    struct Entry: Decodable {
        let text: String

        init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let string = try? container.decode(String.self) {
                text = string
            } else if let fields = try? container.decode([String: String].self), !fields.isEmpty {
                text = fields.keys.sorted().map { "\($0): \(fields[$0] ?? "")" }.joined(separator: ", ")
            } else {
                text = "an unreadable entry"
            }
        }
    }
}
