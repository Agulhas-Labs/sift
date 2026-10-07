//
// Copyright © Agulhas Labs
//

/// One test as the index found it, in the spelling `xcodebuild -enumerate-tests` prints.
///
/// `function` is the index's own name for the declaration rather than the runner spelling `TestSymbol` carries, because what this feeds is a join against a test plan's entries and an enumeration's `Target/Type/function()` identifiers, and enumeration prints the parentheses for both frameworks.
///
/// The counts built from these are per test *function*: a `@Test(arguments:)` function is one declared test however many cases it runs, which is the unit every tally already uses.
public struct DeclaredTest: Sendable, Hashable {
    /// The test target — the index's module attribution for the declaring file, which is the spelling a test plan and an enumeration both use, spaces included.
    public let target: String
    /// True when no build file claimed the declaring file, so the target above was guessed from its first path component.
    public let targetWasGuessed: Bool
    /// The enclosing type path, `Outer.Inner` for a nested suite, and empty for a test declared at file scope.
    public let suite: String
    /// The function as the index names it: `testAddition()`, `addsTwoNumbers()`, `doublingIsEven(_:)`.
    public let function: String
    public let style: TestSymbol.Style
    /// The test's own `@Test("…")` literal, the name it logs under that no identifier carries.
    ///
    /// A suite's `@Suite("…")` name is not inherited here: it names the suite, and a test carrying it would claim a display name its own declaration never wrote.
    public let displayName: String?
    public let disposition: Disposition
    public let path: String
    public let line: Int
    /// Whether the platform this runs on compiles the declaration, as far as the `#if` clauses around it let the host prove it.
    public var compilation: Compilation = .compiled
}

public extension DeclaredTest {
    /// What the `#if` clauses around a declaration say about whether this platform compiles it.
    enum Compilation: Sendable, Hashable {
        /// Inside no `#if`, or inside clauses the host proves active.
        case compiled
        /// Inside a clause the host proves inactive, such as `#if os(Linux)` on macOS: never compiled here, so never run here.
        case compiledOut(condition: String)
        /// Inside a clause whose condition the host cannot decide, a custom flag or a version check: compiled or not by a build the index never sees.
        case undecided(condition: String)
    }
}

public extension DeclaredTest {
    /// What a declaration promises about the run — each case a different promise.
    enum Disposition: Sendable, Hashable {
        case runs
        /// Enumerated and counted as enabled, then skipped at runtime — the shape a reader mistakes for coverage.
        case disabled(reason: String?)
        /// Decided at runtime, so it is reported as undecidable rather than counted in either direction.
        case conditional(marker: String)
        /// Reports as skipped and keeps the run green with no tool's help.
        case skips(reason: String?)
        /// Reports as an ordinary failure on every surface, so nothing but a static read tells it from a real one.
        case excludedByXCTFail
    }
}

public extension DeclaredTest {
    /// The identifier this declaration carries, or `nil` for a test declared at file scope, which no `Target/Type/function` identifier can name.
    var identifier: TestIdentifier? {
        TestIdentifier(enumerated: "\(target)/\(suite)/\(function)")
    }

    /// The name a log prints this test by where its declaration wrote one: the literal in the quotes Swift Testing prints it inside, which is the spelling an ending has to be matched on.
    ///
    /// One spelling of the rule, because both reconciliations join on it — the unsharded path against the inventory it reads itself, the sharded one against the literals threaded into its plan — and two spellings of the same quoting is a join that works on one path and silently never matches on the other.
    ///
    /// A swift-testing function written as a raw identifier — backticks around words that are no identifier — prints the words it wraps when it wrote no literal, so those are the name an ending carries.
    var logName: String? {
        (displayName ?? rawIdentifierWords).map { "\"\($0)\"" }
    }

    /// The words inside the backticks of a swift-testing function named as a raw identifier, or `nil` for any other spelling, a backticked keyword included, which prints as the function.
    private var rawIdentifierWords: String? {
        guard style != .xcTest, function.first == "`", let close = function.dropFirst().firstIndex(of: "`") else { return nil }
        let words = function[function.index(after: function.startIndex) ..< close]
        let isPlainIdentifier = words.first.map { $0 == "_" || $0.isLetter } == true && words.allSatisfy { $0 == "_" || $0.isLetter || $0.isNumber }
        return words.isEmpty || isPlainIdentifier ? nil : String(words)
    }
}
