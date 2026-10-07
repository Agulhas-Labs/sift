//
// Copyright © Agulhas Labs
//

@testable import SiftCore
import SwiftParser
import SwiftSyntax
import Testing

/// Covers which written calls a declaration's labels accept: generously, since a call wrongly refused is a site dropped from an answer.
struct ParameterLabelsTests {
    private static func labels(_ signature: String, _ name: String, sourceLocation: Testing.SourceLocation = #_sourceLocation) throws -> ParameterLabels {
        try #require(ParameterLabels(signature: signature, name: name), sourceLocation: sourceLocation)
    }

    /// The arguments of the one call in a line of source.
    private static func written(_ call: String, sourceLocation: Testing.SourceLocation = #_sourceLocation) throws -> WrittenArguments {
        let tree = Parser.parse(source: call)
        let expression = try #require(tree.statements.first?.item.as(FunctionCallExprSyntax.self), sourceLocation: sourceLocation)
        return WrittenArguments(of: expression)
    }

    @Test
    func defaultedParametersMayBeLeftOutAnywhere() throws {
        let labels = try Self.labels("func run(in place: String, limit: Int = 3, quiet: Bool = false)", "run(in:limit:quiet:)")

        #expect(try labels.accepts(Self.written("x.run(in: a)")))
        #expect(try labels.accepts(Self.written("x.run(in: a, quiet: true)")))
        #expect(try labels.accepts(Self.written("x.run(in: a, limit: 1, quiet: true)")))
        #expect(try !labels.accepts(Self.written("x.run(limit: 1)")))
        #expect(try !labels.accepts(Self.written("x.run(in: a, quiet: true, limit: 1)")))
        #expect(try !labels.accepts(Self.written("x.run()")))
    }

    @Test
    func aTrailingClosureStandsForItsParameterWhateverItsLabel() throws {
        let labels = try Self.labels("func run(in place: String, limit: Int = 3, then body: () -> Void)", "run(in:limit:then:)")

        #expect(try labels.accepts(Self.written("x.run(in: a) {}")))
        #expect(try labels.accepts(Self.written("x.run(in: a, limit: 2) {}")))
        #expect(try labels.accepts(Self.written("x.run(in: a, then: {})")))
        #expect(try !labels.accepts(Self.written("x.run(in: a)")))
    }

    @Test
    func labeledTrailingClosuresMatchTheirOwnLabels() throws {
        let labels = try Self.labels("func run(in place: String, then body: () -> Void, done: () -> Void = {})", "run(in:then:done:)")

        #expect(try labels.accepts(Self.written("x.run(in: a) {} done: {}")))
        #expect(try !labels.accepts(Self.written("x.run(in: a) {} after: {}")))
    }

    @Test
    func aVariadicTakesAnyCountIncludingNone() throws {
        let labels = try Self.labels("func run(_ values: Int..., limit: Int)", "run(_:limit:)")

        #expect(try labels.accepts(Self.written("x.run(limit: 1)")))
        #expect(try labels.accepts(Self.written("x.run(1, 2, 3, limit: 1)")))
        #expect(try !labels.accepts(Self.written("x.run(1, 2)")))
    }

    @Test
    func aCompoundCalleeIsCheckedByTheLabelsItSpells() throws {
        let labels = try Self.labels("func run(in place: String, limit: Int = 3)", "run(in:limit:)")

        #expect(try labels.accepts(Self.written("x.run(in:limit:)(a, 1)")))
        #expect(try !labels.accepts(Self.written("x.run(in:)(a)")))
    }

    /// A duplicated label with a default first is still matched to the second parameter.
    @Test
    func aDefaultedParameterIsSkippedWhenItsLabelBelongsToALaterOne() throws {
        let labels = try Self.labels("func run(at first: Int = 0, at second: Int)", "run(at:at:)")

        #expect(try labels.accepts(Self.written("x.run(at: 1)")))
    }

    @Test
    func anInitializerIsRead() throws {
        let labels = try Self.labels("init(in place: String)", "init(in:)")

        #expect(try labels.accepts(Self.written("Self.init(in: a)")))
        #expect(try !labels.accepts(Self.written("Self.init(from: a)")))
    }

    /// A signature that does not parse back to the declaration's own name cannot say which calls it takes.
    @Test
    func aSignatureThatDisagreesWithItsNameNarrowsNothing() {
        #expect(ParameterLabels(signature: "func run(in place: String, // a note limit: Int)", name: "run(in:limit:)") == nil)
        #expect(ParameterLabels(signature: "var run: Int", name: "run") == nil)
    }

    /// A parameter pack takes any number of values, none included, exactly as a variadic does.
    @Test
    func aParameterPackTakesAnyCountAsAVariadicDoes() throws {
        let bare = try Self.labels("func run<each T>(_ values: repeat each T)", "run(_:)")
        let labeled = try Self.labels("func run<each T>(values: repeat each T, limit: Int)", "run(values:limit:)")

        #expect(try bare.accepts(Self.written("x.run(1, \"a\", true)")))
        #expect(try bare.accepts(Self.written("x.run()")))
        #expect(try labeled.accepts(Self.written("run(values: 1, \"b\", limit: 2)")))
        #expect(try labeled.accepts(Self.written("run(limit: 2)")))
        #expect(try !labeled.accepts(Self.written("run(1, limit: 2)")))
    }

    /// A backticked label is the name inside the backticks, on the declaration's side and the call's, and is spelled without them.
    @Test
    func aBacktickedLabelIsTheNameItEscapes() throws {
        let escaped = try Self.labels("func run(`default`: Int, then body: () -> Void = {})", "run(default:then:)")
        let plain = try Self.labels("func run(default: Int, then body: () -> Void = {})", "run(default:then:)")

        #expect(try escaped.accepts(Self.written("run(default: 1)")))
        #expect(try plain.accepts(Self.written("run(`default`: 1)")))
        #expect(try plain.accepts(Self.written("run(`default`:`then`:)(1, {})")))
        #expect(escaped.spelled == "(default:then:)")

        let closures = try Self.labels("func run(first: () -> Void, then body: () -> Void)", "run(first:then:)")

        #expect(try closures.accepts(Self.written("run {} `then`: {}")))
    }

    /// A method named on its type and given only its instance takes its own arguments in a second call or none at all, so its labels cannot be judged.
    @Test
    func aMethodGivenItsInstanceIsKept() throws {
        let labels = try Self.labels("func run(in place: Int)", "run(in:)")
        let curried = try #require(Parser.parse(source: "Gizmo.run(gizmo)(in: 1)").statements.first?.item.as(FunctionCallExprSyntax.self))
        let inner = try #require(curried.calledExpression.as(FunctionCallExprSyntax.self))

        #expect(labels.accepts(WrittenArguments(of: inner)))
        #expect(try labels.accepts(Self.written("Gizmo.run(Gizmo())")))
        #expect(try labels.accepts(Self.written("Swift.Gizmo.run(gizmo)")))
        #expect(try !labels.accepts(Self.written("gizmo.run(1)")))
        #expect(try Self.written("Self.run(gizmo)").application == .mayBeUnappliedOnSelf)
        #expect(try !labels.accepts(Self.written("Gizmo.run(at: gizmo)")))
    }

    /// A trailing closure after the first labelled `_:` stands for an unlabeled parameter rather than being lost.
    @Test
    func aTrailingClosureLabelledUnderscoreIsKept() throws {
        let labels = try Self.labels("func run(in value: Int, _ first: () -> Void, _ second: () -> Void)", "run(in:_:_:)")

        #expect(try labels.accepts(Self.written("x.run(in: 1) {} _: {}")))
        #expect(try !labels.accepts(Self.written("x.run(in: 1) {} done: {}")))
    }

    /// A method's type spelled as `type(of:)`, a `.self` member or in parentheses may be given only its instance, just as a capitalised name may.
    @Test
    func aTypeSpelledAnotherWayMayBeGivenItsInstance() throws {
        let labels = try Self.labels("func run(in place: Int)", "run(in:)")

        #expect(try labels.accepts(Self.written("type(of: gizmo).run(gizmo)")))
        #expect(try labels.accepts(Self.written("Gizmo.self.run(gizmo)")))
        #expect(try labels.accepts(Self.written("(Gizmo).run(gizmo)")))
        #expect(try !labels.accepts(Self.written("gizmo.run(gizmo)")))
    }
}
