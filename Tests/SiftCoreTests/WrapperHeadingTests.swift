//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// The wrapper-attribute-sites block's heading differs by caller: `diff` keeps the paragraph it has always printed, since `diff` output must not change once written, while `where` keeps the short one, distinguishable from a plain name-matched block, and the rule behind both lives in `sift help answers`.
struct WrapperHeadingTests {
    static var site: SyntacticCallSite {
        SyntacticCallSite(path: "Sources/App/Use.swift", line: 4, enclosing: "make()")
    }

    /// `diff` (`grouped: false`, the default) prints the exact heading it has always printed, so a rewrite of the short `where` heading never changes `diff` output.
    @Test
    func theUngroupedHeadingIsTheOriginalParagraph() {
        let lines = WrapperAttributeSites.lines([Self.site], named: "Clamp", for: "init(wrappedValue:)", cap: 20)

        #expect(lines.contains(
            "syntactic call sites — by written name where the index store records no call: each is a property wrapper's @T attribute, which calls its initializer, on a line where the store records the type and no call of its initializers, as on a function's parameter; a name is not a symbol, so verify a hit — see sift help answers"
        ), "\(lines)")
    }

    /// `where` (`grouped: true`) keeps a short heading, still opening with the block reader's required prefix, but naming the rule this block follows so it reads differently from a plain name-matched block.
    @Test
    func theGroupedHeadingIsShortAndDistinguishable() {
        let lines = WrapperAttributeSites.lines([Self.site], named: "Clamp", for: "init(wrappedValue:)", cap: 20, grouped: true)

        #expect(lines.contains(
            "syntactic call sites — by written name where the index store records no call — see sift help answers (call sites)"
        ), "\(lines)")
        #expect(lines.first { $0.hasPrefix("syntactic call sites") }?.utf8.count ?? .max <= 160, "\(lines)")
    }

    /// `sift help answers` states the rule the short heading now only points at: an unrecorded `@T` attribute site is listed beside a resolved answer, kept only where the store records a reference to that very type, each under the one initializer its labels reach.
    @Test
    func helpAnswersStatesTheWrapperAttributeRule() {
        let body = HelpTopics.topic(named: "answers")?.body ?? ""

        #expect(body.contains("a property wrapper's @T attribute sites the store records no call at"), "\(body)")
    }
}
