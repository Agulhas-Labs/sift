//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftMCP
import Testing

/// Covers reading a call whose Swift name arrived under some other tool's key, and refusing clearly when it did not.
struct ArgumentAliasTests {
    // MARK: The calls a strict reading would refuse

    /// The shapes callers really send, each of which a strict reading refuses and the caller then retries seconds later with the right key.
    @Test
    func aNameUnderAnotherToolsKeyIsRead() {
        #expect(ArgumentAlias.resolve(tool: "digest", arguments: ["query": "GridComparisonBand"])
            .map(\.given) == "query")
        #expect(ArgumentAlias.resolve(tool: "digest", arguments: ["symbol_or_path": "GridBodyArrangement"])
            .map(\.given) == "symbol_or_path")
        #expect(ArgumentAlias.resolve(tool: "where", arguments: ["target": "InboundCard"])
            .map(\.given) == "target")
        #expect(ArgumentAlias.resolve(tool: "digest", arguments: ["symbol": "ParcelGateway"])
            .map(\.given) == "symbol")
    }

    /// A call that already named its argument is left alone, whatever else it carries.
    @Test
    func aCallThatNamedItsArgumentIsNotRewritten() {
        #expect(ArgumentAlias.resolve(tool: "digest", arguments: ["target": "Theme", "query": "other"]) == nil)
        #expect(ArgumentAlias.resolve(tool: "where", arguments: ["symbol": "Theme"]) == nil)
    }

    // MARK: Two keys healed by what they carry rather than by name shape

    /// `digest` reads a `path:` the way it would read one under `target:` — including a shape `isNameShaped` would refuse, since a real path is not a Swift name.
    @Test
    func digestHealsAPathSentUnderPathToTarget() {
        #expect(ArgumentAlias.resolve(tool: "digest", arguments: ["path": "Sources/Foo.swift"])
            .map(\.given) == "path")
        #expect(
            ArgumentAlias.resolve(tool: "digest", arguments: ["path": "/repo/Sources/Foo.swift"])
                .map(\.given) == "path",
            "a leading slash is not a Swift name, but it is still a path"
        )
        #expect(
            ArgumentAlias.resolve(tool: "where", arguments: ["path": "Sources/Foo.swift"]) == nil,
            "path: is digest's own miswrite, not where's"
        )
    }

    /// A call naming both `path:` and `type:`, with `target:` absent, reads `path:` — the more specific of the two donors — rather than letting `type`'s later addition to `carrying` silently steal a call that used to reach `path` alone.
    @Test
    func digestPrefersPathOverTypeWhenBothAreSent() {
        #expect(
            ArgumentAlias.resolve(tool: "digest", arguments: ["type": "Foo", "path": "Sources/Bar.swift"])
                .map(\.given) == "path"
        )
    }

    /// `strings` reads a `text:` the way it would read one under `query:` — a whole phrase included, which `isNameShaped` would refuse but is exactly what `strings` searches for.
    @Test
    func stringsHealsTextSentUnderTextToQuery() {
        #expect(ArgumentAlias.resolve(tool: "strings", arguments: ["text": "Save changes"])
            .map(\.given) == "text")
        #expect(
            ArgumentAlias.resolve(tool: "strings", arguments: ["name": "Save changes"]) == nil,
            "only text: is strings' own miswrite; the generic name-shaped donors stay digest/where's"
        )
    }

    /// `path:` belongs to `digest` alone, and `digest`'s own `target:` already accepts anything non-empty — `.` for the repo overview, a bare module name, a bare type name — so `path:` heals every one of those too, not only values that look like a real file path.
    @Test
    func pathAcceptsAnythingTargetItselfWould() {
        #expect(ArgumentAlias.resolve(tool: "digest", arguments: ["path": "."])?.given == "path")
        #expect(ArgumentAlias.resolve(tool: "digest", arguments: ["path": "SiftCore"])?.given == "path")
        #expect(
            ArgumentAlias.resolve(tool: "digest", arguments: ["path": ""]) == nil,
            "an empty value carries nothing to heal"
        )
    }

    /// The healing only ever fills an *absent* argument — a `path:` or `text:` sent alongside its tool's own key is never allowed to override it, exactly as every other donor key already cannot.
    @Test
    func pathAndTextNeverOverrideAnAlreadyNamedArgument() {
        #expect(ArgumentAlias.resolve(tool: "digest", arguments: ["target": "Theme", "path": "Sources/Foo.swift"]) == nil)
        #expect(ArgumentAlias.resolve(tool: "strings", arguments: ["query": "Save", "text": "Cancel"]) == nil)
    }

    // MARK: Where the widening deliberately stops

    /// A structural query is not a Swift name — healing it would turn a clear refusal into a hunt for a symbol called `kind:struct`.
    @Test
    func aStructuralQueryIsNotReadAsAName() {
        #expect(ArgumentAlias.resolve(tool: "digest", arguments: ["query": "kind:struct attr:Test"]) == nil)
    }

    /// A name with an instruction stapled to it is not a name either — that one is the caller's to fix.
    @Test
    func aNameWithAPhraseAttachedIsNotGuessedAt() {
        #expect(ArgumentAlias.resolve(tool: "where", arguments: ["query": "RecordService.makeObserverQuery callers"]) == nil)
    }

    /// The query-language tools are left alone: their argument is not a Swift name, so a bare name there means something else.
    @Test
    func theQueryLanguageToolsAreNotHealed() {
        #expect(ArgumentAlias.resolve(tool: "search", arguments: ["target": "Theme"]) == nil)
        #expect(ArgumentAlias.resolve(tool: "strings", arguments: ["symbol": "Theme"]) == nil)
    }

    /// Swift's own labelled forms are names, and `where` takes them — a real call can carry a five-label selector.
    ///
    /// Rejecting every colon outright would refuse exactly the calls the alias exists to rescue.
    @Test
    func aLabelledSelectorIsStillAName() {
        #expect(ArgumentAlias.isNameShaped("save(_:to:)", allowingRange: true))
        #expect(ArgumentAlias.isNameShaped("MCPServer.emit(resultID:result:)", allowingRange: true))
        #expect(ArgumentAlias.isNameShaped("ReportProducer.record(service:period:now:calendar:scanning:)", allowingRange: true))
        #expect(ArgumentAlias.resolve(tool: "where", arguments: ["target": "save(_:to:)"]).map(\.given) == "target")
        #expect(ArgumentAlias.resolve(tool: "digest", arguments: ["query": "Foo.bar(a:b:)"]).map(\.given) == "query")
    }

    /// A top-level colon is a query's `field:value` however the rest reads, so it is still refused.
    @Test
    func aTopLevelColonIsStillAQuery() {
        #expect(!ArgumentAlias.isNameShaped("kind:struct", allowingRange: true))
        #expect(!ArgumentAlias.isNameShaped("attr:Test", allowingRange: true))
        #expect(!ArgumentAlias.isNameShaped("path:Sources", allowingRange: true))
    }

    /// The query-language tools are not told their argument is a Swift name, because it is not one.
    @Test
    func aRefusalDoesNotMisdescribeTheArgumentItWants() {
        let strings = ArgumentAlias.missingArgumentMessage(
            tool: "strings", wanted: "query", arguments: ["name": "networking"]
        )
        let digest = ArgumentAlias.missingArgumentMessage(
            tool: "digest", wanted: "target", arguments: ["query": "kind:struct"]
        )

        #expect(strings.contains("strings names its argument query:"))
        #expect(!strings.contains("plain Swift name"), "display text is usually a phrase")
        #expect(digest.contains("plain Swift name"))
    }

    /// A dotted path is a name; empty, punctuation-led and whitespace-bearing values are not.
    @Test
    func nameShapeIsJudgedOnTheValue() {
        #expect(ArgumentAlias.isNameShaped("ArchiveReader.lastEntry()", allowingRange: true))
        #expect(ArgumentAlias.isNameShaped("_private", allowingRange: true))
        #expect(!ArgumentAlias.isNameShaped("", allowingRange: true))
        #expect(!ArgumentAlias.isNameShaped("**/*.swift", allowingRange: true))
        #expect(!ArgumentAlias.isNameShaped("two words", allowingRange: true))
    }

    // MARK: What a refusal says

    /// The refusal names the keys the call actually sent — the omission that otherwise sends a caller round the same loop again.
    @Test
    func aRefusalNamesWhatTheCallSent() {
        let message = ArgumentAlias.missingArgumentMessage(
            tool: "where",
            wanted: "symbol",
            arguments: ["query": "a b", "root": "/repo"]
        )

        #expect(message.contains("where needs a symbol"))
        #expect(message.contains("query:"))
        #expect(!message.contains("root:"), "the root is never the missing argument, so naming it only misleads")
    }

    /// A call that sent nothing at all keeps the short message — there is no "instead" to name.
    @Test
    func aRefusalWithNothingToNameStaysShort() {
        #expect(ArgumentAlias.missingArgumentMessage(tool: "digest", wanted: "target", arguments: [:])
            == "digest needs a target")
    }

    /// The wording still classifies as a missing argument, or the audit's failure kinds would silently drift to `other`.
    @Test
    func theImprovedRefusalStillClassifies() {
        let message = ArgumentAlias.missingArgumentMessage(
            tool: "digest",
            wanted: "target",
            arguments: ["query": "kind:struct"]
        )

        #expect(IndexFailure(tool: "digest", target: nil, reason: message).kind == .missingArgument)
    }
}
