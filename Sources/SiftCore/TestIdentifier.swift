//
// Copyright © Agulhas Labs
//

import Foundation

/// One test in the spelling `xcodebuild`'s enumeration uses — `Target/Type/function()` — which is the only one of the three spellings in play that names every part of a test.
///
/// **Both frameworks are enumerated the same way**, measured on the demo project (Xcode 27.0, 17 Sep 2026): `DemoUnitTests/CalculatorTests/testAddition()` for an `XCTestCase` method and `DemoUnitTests/MathSuite/addsTwoNumbers()` for a Swift Testing function, with a parameterised test listed once as `DemoUnitTests/MathSuite/doublingIsEven(_:)`. So an identifier does not say which framework declared it, and nothing here tries to read that out of one: see ``TestNameMatch`` for why the log is asked instead.
///
/// The two log spellings are both narrower than this one. XCTest prints `-[Target.Type testAddition]` or `-[Type testAddition]` — the method, its class, sometimes its target, never the argument labels. Swift Testing prints the bare function and no suite at all. Matching is therefore one-way: a log name is asked whether it names *this* test, never turned into an identifier of its own.
public struct TestIdentifier: Hashable, Sendable {
    /// The test target the test is built into — `DemoUnitTests`.
    public let target: String

    /// The `XCTestCase` subclass or Swift Testing suite that declares it — `CalculatorTests`, `MathSuite`.
    public let type: String

    /// The function as the enumeration spells it, parentheses and argument labels included — `testAddition()`, `doublingIsEven(_:)`.
    public let function: String

    /// Reads one enumerated identifier, or `nil` where it is not the three-part shape enumeration prints.
    ///
    /// Exactly three parts, none of them empty. A shorter spelling is what `--only`/`--skip` take (`Target`, `Target/Class`), and it names a set of tests rather than one — so accepting it here would let a set stand where the reconciliation counts individuals.
    public init?(enumerated: String) {
        let parts = enumerated.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty }) else {
            return nil
        }
        target = String(parts[0])
        type = String(parts[1])
        function = String(parts[2])
    }

    /// An identifier from its three parts as given, or `nil` where one is empty, for a name such as a raw-identifier function `` `x/y`() `` whose own `/` ``init(enumerated:)`` would split on.
    public init?(target: String, type: String, function: String) {
        guard !target.isEmpty, !type.isEmpty, !function.isEmpty else {
            return nil
        }
        self.target = target
        self.type = type
        self.function = function
    }
}

// MARK: - The spellings derived from it

public extension TestIdentifier {
    /// The identifier as the enumeration printed it, which every other spelling here is derived from.
    var enumerated: String {
        "\(target)/\(type)/\(function)"
    }

    /// The bare function name — no parentheses, no argument labels — which is what both frameworks' logs report a test under.
    var functionName: String {
        String(function.prefix { $0 != "(" })
    }

    /// The target's name as a Swift module name, which is not the target's name wherever the target is named something Swift cannot spell — and it is the module name, not the target, that XCTest's log qualifies a class with.
    ///
    /// **Measured on a target named `Demo Spaced Tests`** (17 Sep 2026, `ValidationProjects/README.md`): it enumerates as `Demo Spaced Tests/SpacedTests/testCountsUp()`, spaces intact, and logs `-[Demo_Spaced_Tests.SpacedTests testCountsUp]`. Xcode derives `PRODUCT_MODULE_NAME` from the product name through its `c99ext_identifier` operator — every character that is not an ASCII letter, digit or `_` becomes `_`, and a name that would begin with a digit takes a `_` in front of it. The substitution is the measured half; the leading-digit prefix is the operator's other half, which no target here is named to exercise, and it costs nothing to honour because a module name beginning with a digit is a string XCTest can never print.
    var moduleName: String {
        Self.moduleName(ofTarget: target)
    }

    /// The module name a target named `target` builds, spelt as ``moduleName`` spells it.
    internal static func moduleName(ofTarget target: String) -> String {
        let substituted = String(target.map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") ? $0 : "_" })
        guard let first = substituted.first, first.isNumber else {
            return substituted
        }
        return "_" + substituted
    }

    /// The `-only-testing:` argument that selects this one test.
    ///
    /// **The enumeration's own spelling, unchanged, because that is the spelling Xcode itself printed.** The two frameworks were measured to want different things and only one of them was measured both ways: XCTest ran from `-only-testing:DemoUnitTests/CalculatorTests/testAddition` without parentheses, and Swift Testing needed `-only-testing:DemoLogicTests/DemoLogicTests/evenNumbersAreEven()` with them (17 Sep 2026). XCTest was then measured to accept the parenthesised form too, and a parameterised test its `name(_:)` spelling (same day), so passing on what the enumeration said is right for both — and composing a spelling would be a guess in the one place a guess silently runs nothing: a misspelt identifier selects no test and `xcodebuild` still exits 0.
    ///
    /// **A target whose module name differs from its name is selected by its name, not its module name**: `-only-testing:Demo Spaced Tests/SpacedTests/testCountsUp()` ran that test, and the ``moduleName`` spelling was refused outright — `Tests in the target “Demo_Spaced_Tests” can’t be run because “Demo_Spaced_Tests” isn’t a member of the specified test plan or scheme.`, exit 70 (17 Sep 2026). So the enumeration's spelling, unchanged, is right here too, spaces and all — and a wrong *target* is the one selection mistake `xcodebuild` does not make quietly.
    var onlyTestingArgument: String {
        "-only-testing:\(enumerated)"
    }
}

// MARK: - Reading XCTest's log spelling

public extension TestIdentifier {
    /// The qualified type and the method an XCTest log name carries — `-[DemoUnitTests.CalculatorTests testAddition]` gives `DemoUnitTests.CalculatorTests` and `testAddition` — or `nil` where the name is not that shape.
    ///
    /// **The shape is what tells the frameworks apart**, which is the only reliable signal there is: an identifier cannot say whether its type subclasses `XCTestCase`, because nothing in the enumeration names a superclass and `test…()` is a spelling either framework may use. A name in `-[…]` brackets was printed by XCTest and nothing else prints it.
    ///
    /// **A case nested in another type is logged under its mangled runtime name** — `-[_TtCC8LibTests11WidgetTests10GizmoTests testTwo]` — and is read back to `LibTests.WidgetTests.GizmoTests` by ``MangledClassName``, so every reader of a log name matches it to the dotted name the inventory declares; a mangled name outside that one family is returned as printed.
    static func xctestLogName(_ name: String) -> (qualifiedType: String, method: String)? {
        guard name.hasPrefix("-["), name.hasSuffix("]") else {
            return nil
        }
        let body = name.dropFirst(2).dropLast()
        guard let space = body.firstIndex(of: " ") else {
            return nil
        }
        let qualifiedType = body[..<space]
        let method = body[body.index(after: space)...]
        guard !qualifiedType.isEmpty, !method.isEmpty, !method.contains(" ") else {
            return nil
        }
        return (MangledClassName.demangled(qualifiedType) ?? String(qualifiedType), String(method))
    }

    /// Whether an XCTest log name names this test.
    ///
    /// **Both measured spellings are accepted, target-qualified or not.** One bundle's log prints `-[DemoUnitTests.CalculatorTests testAddition]` and another's the bare `-[CalculatorTests testAddition]`, and which one arrives is not a property of the test. Unqualified, the name is matched on type and method alone — which can name more than one test where two targets declare the same class, and ``TestNameMatch`` is where that ambiguity is answered rather than guessed at.
    ///
    /// **The qualifier is the module name, and the enumeration prints the target name**, so ``moduleName`` is accepted beside ``target``: a target Swift cannot spell — `Demo Spaced Tests` — enumerates under its own name and logs under `Demo_Spaced_Tests`, and comparing the two directly reports every test of that bundle missing over a green run. Where the target's name is already an identifier the two are the same string and this arm decides nothing.
    func matches(xctestLogName name: String) -> Bool {
        guard let parsed = TestIdentifier.xctestLogName(name), parsed.method == functionName else {
            return false
        }
        return parsed.qualifiedType == type
            || parsed.qualifiedType == "\(target).\(type)"
            || parsed.qualifiedType == "\(moduleName).\(type)"
    }

    /// Whether an XCTest log name names this test by class and method alone, only its module qualifier set aside.
    ///
    /// **The second tier `TestNameMatch.reconcile` falls to when a target's module name is neither its target name nor the derived ``moduleName``** — a `PRODUCT_MODULE_NAME` set by hand. `matches(xctestLogName:)` already accepts the derived spelling; this drops only the leading module component and compares what is left to ``type`` — never just the last component, which a nested type's dotted name shares with a same-named top-level type and would let either claim the other's log line.
    func matchesByClassAndMethod(xctestLogName name: String) -> Bool {
        guard let parsed = TestIdentifier.xctestLogName(name), parsed.method == functionName else {
            return false
        }
        if parsed.qualifiedType == type {
            return true
        }
        guard let moduleSeparator = parsed.qualifiedType.firstIndex(of: ".") else {
            return false
        }
        return parsed.qualifiedType[parsed.qualifiedType.index(after: moduleSeparator)...] == type
    }

    /// Whether a Swift Testing log name names this test — the function, with whatever decoration the line carried in front of it stripped.
    ///
    /// **The name is undecorated through ``RunOutputFilter/undecorated(_:)``**, the same reader the filter takes a Swift Testing line apart with: a line may begin with U+200B, and a test that ran behind one is not a different test.
    ///
    /// **Compared on the bare function name, up to the opening parenthesis.** The enumeration writes a parameterised test's labels as declared (`doublingIsEven(_:)`) and the log writes what the framework holds, which is not measured to be the same string; the part in front of the parenthesis is the part both were measured to agree on.
    ///
    /// **A quoted display name is deliberately not matched**, and it is recognised by the quote standing in the decoration `undecorated` dropped — the same span ``RunTestOutcomes/swiftTestingEvent(in:)`` reads a continuation marker out of. A display name names nothing the enumeration printed, so an author who wrote one that happens to read like the function is reporting a name this cannot claim, and it is left to be counted as a name that claimed no test rather than guessed onto one.
    func matches(swiftTestingLogName name: String) -> Bool {
        let bare = RunOutputFilter.undecorated(name)
        guard !name[name.startIndex ..< bare.startIndex].contains("\"") else {
            return false
        }
        return bare.prefix { $0 != "(" } == functionName
    }
}
