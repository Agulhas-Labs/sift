//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftMCP
import Testing

/// A grep pattern read with grep's meaning: checked line by line against the system's own grep in both locales a shell may run it under, and against `ugrep` where the machine has it, and refused wherever implementations disagree.
@Suite(.temporaryDirectories)
struct GrepPatternTests {
    /// Lines chosen to sit on every edge the readings differ on: words against non-ASCII letters, case, anchors, literal operators.
    private static let corpus = [
        "func save() {}",
        "    public func go()",
        "static let now = 1",
        "case pending",
        "ab+c",
        "abbc",
        "a?b",
        "foo_bar baz",
        "foo-bar",
        "\tstruct Box",
        "café Gadget",
        "Gadgeté",
        "gadgeté",
        "éGadget",
        "x{2}",
        "xx",
        "b|c",
        "[a]",
        "a.b",
        "AXB",
        "Gadget",
        "gadget",
        " Gadget_2",
        "\u{212A} kelvin",
        "naïve save",
    ]

    /// Every pattern and flag set the matcher reads.
    private static let cases: [Case] = {
        func each(_ patterns: [String], _ options: GrepPattern.Options, _ flags: [String]) -> [Case] {
            patterns.map { Case(pattern: $0, options: options, flags: flags) }
        }
        return each([
            "save", "func save", "^func", #"^\s*public"#, "save()", #"ab\+c"#, #"a\?b"#, #"x\{2\}"#, "x{2}", #"\(ab\)\+"#,
            "b|c", #"\[a\]"#, #"a\.b"#, "a.b", "[[:space:]]struct", "[^a-z]save", "[a-c]b", "sav[e]", #"\bgadget\b"#,
            #"\<Gadget\>"#, "Gadget$", "^Gadget$", #"func\|case"#, #"^func\|^case"#, "g.dget", "[[:alpha:]]adget",
            "[[:upper:]]X", "na.ve", "[]a]", "x*x",
        ], GrepPattern.Options(), [])
            + each(["ab+c", "ab?c", "(ab)+c", "func|case", "x{2}", #"a\|b"#, "^(func|case)", "(Gadget|gadget)$"], GrepPattern.Options(dialect: .extended), ["-E"])
            + each(["a.b", "x{2}", "[a]", "b|c"], GrepPattern.Options(dialect: .fixed), ["-F"])
            + each(["gadget", "axb", "k kelvin", "[a-c]B"], GrepPattern.Options(ignoresCase: true), ["-i"])
            + each(["Gadget", "foo", "func save", "save"], GrepPattern.Options(wholeWords: true), ["-w"])
            + each(["xx", "Gadget", "a.b"], GrepPattern.Options(wholeLine: true), ["-x"])
    }()

    /// Wherever the matcher decides a line, both locales' grep agree with it; every line of ASCII is decided; and the lines the locale decides are reported undecided rather than guessed.
    @Test
    func everyDecidedLineAgreesWithTheSystemGrepInEitherLocale() throws {
        let directory = try TemporaryDirectory.make("grep")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("corpus.txt")
        try (Self.corpus.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        var undecided = 0

        for testCase in Self.cases {
            let pattern = try #require(GrepPattern(testCase.pattern, options: testCase.options), "\(testCase.pattern) was refused")
            let inC = try SystemGrep.system(locale: "C").lines(testCase.flags, testCase.pattern, file)
            let inUTF8 = try SystemGrep.system(locale: "en_US.UTF-8").lines(testCase.flags, testCase.pattern, file)
            for (offset, line) in Self.corpus.enumerated() {
                let number = offset + 1
                guard let decided = pattern.matches(Array(line.utf8)) else {
                    let ascii = line.utf8.allSatisfy { $0 < 0x80 }
                    #expect(!ascii, "\(testCase.pattern) left the ASCII line \(line.debugDescription) undecided")
                    undecided += 1
                    continue
                }
                #expect(decided == inC.contains(number), "\(testCase.flags) \(testCase.pattern) on \(line.debugDescription): C grep says \(inC.contains(number))")
                #expect(decided == inUTF8.contains(number), "\(testCase.flags) \(testCase.pattern) on \(line.debugDescription): UTF-8 grep says \(inUTF8.contains(number))")
            }
        }
        // The readings do disagree somewhere, or the test would prove nothing about them.
        #expect(undecided > 0)
    }

    /// Wherever the matcher decides a line, `ugrep` run as Claude Code's shell runs it agrees too — the `grep` an agent's command actually reaches there.
    @Test(.enabled(if: SystemGrep.installedUgrep != nil, "no ugrep on this machine"))
    func everyDecidedLineAgreesWithUgrep() throws {
        let ugrep = try #require(SystemGrep.installedUgrep)
        let directory = try TemporaryDirectory.make("ugrep")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("corpus.txt")
        try (Self.corpus.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)

        for testCase in Self.cases {
            let pattern = try #require(GrepPattern(testCase.pattern, options: testCase.options), "\(testCase.pattern) was refused")
            let printed = try ugrep.lines(testCase.flags, testCase.pattern, file)
            for (offset, line) in Self.corpus.enumerated() {
                guard let decided = pattern.matches(Array(line.utf8)) else { continue }
                #expect(decided == printed.contains(offset + 1), "\(testCase.flags) \(testCase.pattern) on \(line.debugDescription): ugrep says \(printed.contains(offset + 1))")
            }
        }
    }

    /// Under `-i` a letter outside ASCII is refused, and without `-i`, or with only ASCII letters under it, the pattern is read.
    ///
    /// The system grep folds each of these onto an ASCII letter, so an ASCII line — read as bytes alone — would print where the matcher says it does not.
    @Test(arguments: ["func ıd", "İd", "ſave", "\u{212A}ind"])
    func aLetterOutsideASCIIIsRefusedUnderCaseFolding(pattern: String) {
        #expect(GrepPattern(pattern, options: GrepPattern.Options(ignoresCase: true)) == nil)
        #expect(GrepPattern(pattern, options: GrepPattern.Options(dialect: .fixed, ignoresCase: true)) == nil)
        #expect(GrepPattern(pattern, options: GrepPattern.Options()) != nil)
        #expect(GrepPattern("func id", options: GrepPattern.Options(ignoresCase: true)) != nil)
    }

    /// A word boundary asks whether a letter outside ASCII is a word character, which is a POSIX class membership no table here is sure of — so every line one falls in, whether or not it decides the match, is undecided.
    @Test
    func aBoundaryAgainstANonASCIILetterIsUndecided() throws {
        let anchored = try #require(GrepPattern(#"\bgadget\b"#, options: GrepPattern.Options()))
        let whole = try #require(GrepPattern("Gadget", options: GrepPattern.Options(wholeWords: true)))

        #expect(anchored.matches(Array("gadgeté".utf8)) == nil)
        #expect(whole.matches(Array("éGadget".utf8)) == nil)
        #expect(anchored.matches(Array("é gadget".utf8)) == nil)
        #expect(anchored.matches(Array("gadgets é".utf8)) == nil)
    }

    /// A POSIX class tested against a scalar outside ASCII is undecided, whatever the class says — `ʕ` (U+0295) reads as `[[:lower:]]` under a real `grep` though neither the alphabetic nor the lowercase Unicode property agrees, and that was the only miss a sweep of every class over U+0080–U+2FFFF found.
    @Test
    func aPOSIXClassAgainstANonASCIIScalarIsUndecided() throws {
        let lower = try #require(GrepPattern("let [[:lower:]]", options: GrepPattern.Options()))

        #expect(lower.matches(Array("let a = 1".utf8)) == true)
        #expect(lower.matches(Array("let ʕ = 2".utf8)) == nil)
    }

    /// Every construct implementations read differently is refused, never guessed.
    @Test(arguments: [
        (#"\wbar"#, GrepPattern.Dialect.basic),
        (#"\Sbar"#, .basic),
        (#"\d"#, .basic),
        (#"\(a\)\1"#, .basic),
        (#"a\{2"#, .basic),
        ("a{2", .extended),
        ("[[=a=]]", .basic),
        (#"[\]]"#, .basic),
        (#"save$\|^case"#, .basic),
        ("a$b", .basic),
        ("a^b", .basic),
        ("*x", .basic),
        ("+x", .extended),
        ("x**", .basic),
        ("(|a)", .extended),
        ("()", .extended),
        ("[z-a]", .basic),
        ("[a-Z]", .basic),
        ("[é]", .basic),
        ("a)", .extended),
    ])
    func constructsImplementationsDisagreeOnAreRefused(pattern: String, dialect: GrepPattern.Dialect) {
        #expect(GrepPattern(pattern, options: GrepPattern.Options(dialect: dialect)) == nil)
    }

    /// Whole-word matching is read only where every branch opens and closes on a word character, and a case-folded class of one case not at all.
    @Test
    func flagsWhoseMeaningVariesAreRefused() {
        #expect(GrepPattern(".foo", options: GrepPattern.Options(wholeWords: true)) == nil)
        #expect(GrepPattern("foo(", options: GrepPattern.Options(wholeWords: true)) == nil)
        #expect(GrepPattern("[[:upper:]]x", options: GrepPattern.Options(ignoresCase: true)) == nil)
    }
}

private extension GrepPatternTests {
    /// One pattern, the options the matcher reads it with, and the grep flags that ask the same.
    struct Case {
        let pattern: String
        let options: GrepPattern.Options
        let flags: [String]
    }
}
