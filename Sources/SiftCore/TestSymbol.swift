//
// Copyright © Agulhas Labs
//

/// One test an answer can name, together with the two spellings a runner accepts for it.
///
/// The two spellings are not cosmetic variants. `xcodebuild` selects by identifier — `-only-testing:Target/Suite/function` — while SwiftPM's `swift test --filter` takes a **regular expression** matched against the printed test id (`Target.Suite/function()`, exactly as `swift test list` renders it), so the same test needs a slash in one and an escaped dot in the other. Emitting both is what makes this answer pasteable rather than something the reader has to translate, and translating it by hand is where a filter silently matches nothing and a green run means nothing.
///
/// Swift Testing's ids differ from XCTest's in two shapes, each measured with SwiftPM 6.4 and `xcodebuild` on macOS, where every wrong spelling ran nothing and exited 0: a file-scope `@Test` is listed as `Target.function()`, so its filter joins target and function with a dot while `-only-testing:Target/function()` keeps the slash; and a nested suite is listed as `Target.Outer/Inner/function()`, so both runners take its path slash-separated, never as the dotted `Outer.Inner`.
///
/// `suite` and `function` are optional because the answer has three grains, and the coarser two are honest rather than lazy: a reference landing in a suite's stored property affects every test in that suite, and a per-test list too long to print is replaced by its target rather than truncated into something that looks complete.
///
/// It carries **only what a runner selects on**. Where the test is declared is provenance, not identity, and holding it here would make two references into different extensions of one suite render as two entries and emit the same `-only-testing:` argument twice — a duplicated flag being the visible half of a list that has stopped counting distinct selections. The declaring site travels alongside, on `TestDeclaration`.
public struct TestSymbol: Sendable, Hashable, Comparable {
    /// The test target — the index's module attribution for the declaring file.
    let target: String
    /// The enclosing type path (`Outer.Inner`), or `nil` when the whole target is named.
    let suite: String?
    /// The function as a runner spells it, or `nil` to name the whole suite.
    ///
    /// `example()` or `example(arguments:)` for swift-testing, `testExample` for XCTest.
    let function: String?
    let style: Style

    public static func < (lhs: TestSymbol, rhs: TestSymbol) -> Bool {
        (lhs.target, lhs.suite ?? "", lhs.function ?? "") < (rhs.target, rhs.suite ?? "", rhs.function ?? "")
    }
}

extension TestSymbol {
    /// Which testing library declared it, because the two spell their identifiers differently and the reader has to know which convention they are looking at.
    public enum Style: String, Sendable, Hashable {
        case swiftTesting = "swift-testing"
        case xcTest = "XCTest"
    }

    /// The identifier `xcodebuild -only-testing:` selects this test by.
    var onlyTestingArgument: String {
        "-only-testing:" + ([target] + suitePath + [function].compactMap(\.self)).joined(separator: "/")
    }

    /// The `-only-testing:` argument for this test given the runtime names of nested XCTest cases, keyed as `TestInventory.runtimeCaseNames` keys them, or `nil` for a nested case with none.
    ///
    /// Measured with `xcodebuild test` on macOS: a case nested inside another type ran nothing as `LibTests/ChoreTasks.LampTests/testOne`, `LibTests/ChoreTasks/LampTests/testOne` or `LibTests/LampTests/testOne`, each with exit 0, and ran as `LibTests/_TtCO8LibTests10ChoreTasks9LampTests/testOne`, its mangled runtime name.
    func onlyTestingArgument(runtimeCaseNames: [String: String]) -> String? {
        guard swiftTestFilterSelectsNothing, let suite else { return onlyTestingArgument }
        guard let runtimeName = runtimeCaseNames["\(target)/\(suite)"] else { return nil }
        return "-only-testing:" + ([target, runtimeName, function].compactMap(\.self)).joined(separator: "/")
    }

    /// The `swift test --filter` pattern that selects this test, with every regex metacharacter in the identifier escaped.
    ///
    /// SwiftPM matches the pattern against the id as a *substring*, so a suite-grained or target-grained pattern selects everything beneath it without any anchoring of its own — which is exactly what the coarser grains mean.
    var swiftTestFilter: String {
        var pattern = Self.escapedForRegex(target)
        if suite != nil {
            pattern += "\\." + suitePath.map(Self.escapedForRegex).joined(separator: "/")
        }
        if let function {
            pattern += (suite == nil ? "\\." : "/") + Self.escapedForRegex(function)
        }
        return pattern
    }

    /// The same test named for a human, as `swift test list` prints it: `Target.Suite/function()`, `Target.Outer/Inner/function()` for a nested Swift Testing suite, `Target.function()` at file scope.
    var described: String {
        var text = target
        if suite != nil {
            text += "." + suitePath.joined(separator: "/")
        }
        if let function {
            text += (suite == nil ? "." : "/") + function
        }
        return text
    }

    /// The suite as the runners' ids spell its path: a nested Swift Testing suite one component per type, an XCTest case whole, since XCTest names a nested case by its dotted path.
    private var suitePath: [String] {
        guard let suite else { return [] }
        return style == .swiftTesting ? suite.split(separator: ".").map(String.init) : [suite]
    }

    /// True when the suite is itself nested inside another type.
    var suiteIsNested: Bool {
        suite?.contains(".") ?? false
    }

    /// True for a test in an XCTest case nested inside another type, which no `swift test --filter` spelling selects — see `AffectedBlindSpots.nestedXCTestCaseCaveat`.
    var swiftTestFilterSelectsNothing: Bool {
        style == .xcTest && suiteIsNested
    }

    /// The whole target as one selectable unit — what a per-test list falls back to when it would be too long to print in full.
    var targetOnly: TestSymbol {
        TestSymbol(target: target, suite: nil, function: nil, style: style)
    }

    /// The whole suite this test sits in — the selection that subsumes it.
    var suiteOnly: TestSymbol {
        TestSymbol(target: target, suite: suite, function: nil, style: style)
    }

    /// A declared test as the list names it: a Swift Testing function as written, an XCTest method by its base name.
    init(declared test: DeclaredTest) {
        self.init(
            target: test.target,
            suite: test.suite.isEmpty ? nil : test.suite,
            function: test.style == .xcTest ? String(test.function.prefix { $0 != "(" }) : test.function,
            style: test.style
        )
    }

    /// Whether selecting this whole suite runs `other`, a test or suite other than itself.
    ///
    /// A whole suite runs every test declared in it, and in Swift Testing every suite nested inside it, whose ids its filter and `-only-testing:` path are a prefix of. An XCTest case runs only its own tests: a case nested in it is a class of its own, selected by its own runtime name.
    func wholeSuiteRuns(_ other: TestSymbol) -> Bool {
        guard function == nil, let suite, let otherSuite = other.suite, other.target == target, other.style == style else { return false }
        if otherSuite == suite {
            return other.function != nil
        }
        return style == .swiftTesting && otherSuite.hasPrefix(suite + ".")
    }

    /// Escapes every character SwiftPM's `NSRegularExpression` would read as syntax, so an identifier matches literally.
    static func escapedForRegex(_ text: String) -> String {
        var escaped = ""
        for character in text {
            if #"\^$.|?*+()[]{}"#.contains(character) {
                escaped.append("\\")
            }
            escaped.append(character)
        }
        return escaped
    }
}
