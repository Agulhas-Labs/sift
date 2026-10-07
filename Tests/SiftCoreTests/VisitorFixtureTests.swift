//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers the visitor against the kitchen-sink fixture — the acceptance-criteria list from Docs/Design.md §7.
@Suite(.temporaryDirectories)
struct VisitorFixtureTests {
    private static func parseFixture(sourceLocation: SourceLocation = #_sourceLocation) throws -> ParsedFile {
        let url = try #require(
            Bundle.module.url(forResource: "Assorted.swift", withExtension: "txt", subdirectory: "Fixtures"),
            sourceLocation: sourceLocation
        )
        return try #require(
            FileParser.parse(absoluteURL: url, repoRelativePath: "Sources/Kitchen/Assorted.swift"),
            sourceLocation: sourceLocation
        )
    }

    private func symbol(_ name: String, _ kind: SymbolKind, in file: ParsedFile, sourceLocation: SourceLocation = #_sourceLocation) throws -> ParsedSymbol {
        try #require(
            file.symbols.first { $0.name == name && $0.kind == kind },
            "missing \(kind.rawValue) \(name)",
            sourceLocation: sourceLocation
        )
    }

    @Test
    func fixtureParsesCleanlyWithImports() throws {
        let file = try Self.parseFixture()

        #expect(file.parseErrorCount == 0)
        #expect(file.imports == ["Foundation", "HealthKit"])
    }

    @Test
    func genericStructKeepsClauseAndStoredProperties() throws {
        let file = try Self.parseFixture()

        let box = try symbol("Box", .structKind, in: file)
        #expect(box.signature.contains("public struct Box<Value: Equatable>"))
        #expect(box.docSummary == "A generic container with a where-clause method.")
        let value = try symbol("value", .variable, in: file)
        #expect(value.isStored)
        #expect(value.accessLevel == .publicLevel)
        let created = try symbol("created", .variable, in: file)
        #expect(created.accessLevel == .privateLevel)
        let map = try symbol("map(_:)", .function, in: file)
        #expect(map.signature.contains("where Other: Equatable"))
        #expect(map.endLine == map.line)
    }

    @Test
    func macroAttributedClassSurvivesWithAttributesInSignature() throws {
        let file = try Self.parseFixture()

        let store = try symbol("StoreExample", .classKind, in: file)
        #expect(store.signature.contains("@MainActor @Observable final class StoreExample"))
        #expect(store.inherited == ["NSObject", "ObservableObject"])
        #expect(AttributeScanner.customAttributeNames(in: store.signature) == ["Observable"])
        let level = try symbol("level", .variable, in: file)
        #expect(level.isStored)
        #expect(level.signature.contains("@Clamped"))
        let ping = try symbol("ping()", .function, in: file)
        #expect(ping.signature.contains("nonisolated"))
        #expect(ping.signature.contains("async throws -> String"))
        let make = try symbol("make()", .function, in: file)
        #expect(make.isStatic)
        let nested = try symbol("Nested", .structKind, in: file)
        let parentIndex = try #require(nested.parentIndex)
        #expect(file.symbols[parentIndex].name == "StoreExample")
    }

    @Test
    func actorSubscriptAndOverloadsAreLabeled() throws {
        let file = try Self.parseFixture()

        _ = try symbol("Cache", .actor, in: file)
        // `subscript(key: String)` is called `cache["k"]`: `key` is a parameter name, not a label.
        _ = try symbol("subscript(_:)", .subscriptKind, in: file)
        let overloads = file.symbols.filter { $0.name == "store(_:for:)" }

        #expect(overloads.count == 2)
    }

    /// A subscript is named by Swift's rule for subscripts: a parameter has an argument label only when one is written before its name, so `subscript(slot: Int)` — called `x[3]` — is `subscript(_:)`, the name the index store gives it.
    @Test
    func aSubscriptIsNamedByItsArgumentLabelsNotItsParameterNames() throws {
        let file = try TestSources.parsed(
            """
            struct Grid {
                subscript(slot: Int) -> Int { slot }
                subscript(slot slot: String) -> Int { 0 }
                subscript(_ row: Int, _ column: Int) -> Int { row }
                subscript(row: Int, column column: Int) -> Int { row }
            }
            """,
            path: "Sources/App/Grid.swift"
        )

        let names = file.symbols.filter { $0.kind == .subscriptKind }.map(\.name)

        #expect(names == ["subscript(_:)", "subscript(slot:)", "subscript(_:_:)", "subscript(_:column:)"])
    }

    /// An enum case with associated values is named the way the index store names it — labeled like a function, `value(_:)` — and one without keeps its bare word.
    @Test
    func anEnumCaseWithAssociatedValuesIsNamedByItsLabels() throws {
        let file = try TestSources.parsed(
            """
            enum Signal {
                case idle, busy
                case value(Int)
                case pair(left: Int, right: Int)
                case mixed(Int, label: String), plain
            }
            """,
            path: "Sources/App/Signal.swift"
        )

        let names = file.symbols.filter { $0.kind == .enumCase }.map(\.name)

        #expect(names == ["idle", "busy", "value(_:)", "pair(left:right:)", "mixed(_:label:)", "plain"])
    }

    @Test
    func protocolRequirementsInheritTheProtocolAccess() throws {
        let file = try Self.parseFixture()

        let sampler = try symbol("Sampler", .protocolKind, in: file)
        #expect(sampler.inherited == ["AnyObject"])
        _ = try symbol("Sample", .associatedType, in: file)
        let latest = try symbol("latest", .variable, in: file)
        #expect(!latest.isStored)
        let constrained = try #require(file.symbols.first { $0.kind == .extensionKind && $0.name == "Sampler" })
        #expect(constrained.signature.contains("where Sample == Int"))
        let sampleTwice = try symbol("sampleTwice(at:)", .function, in: file)
        #expect(sampleTwice.docSummary == "Default implementation in a constrained protocol extension.")
    }

    @Test
    func enumCasesAndPrivateExtensionInheritance() throws {
        let file = try Self.parseFixture()

        let caseNames = file.symbols.filter { $0.kind == .enumCase }.map(\.name)
        #expect(caseNames == ["wood", "coal", "hydrogen"])
        let renewable = try symbol("renewable", .variable, in: file)
        #expect(!renewable.isStored)
        // The member of `private extension Fuel` inherits the extension's access syntactically.
        let label = try symbol("label()", .function, in: file)
        #expect(label.accessLevel == .privateLevel)
    }

    @Test
    func freeFunctionsTypealiasOperatorAndResultBuilder() throws {
        let file = try Self.parseFixture()

        let topLevel = try symbol("topLevel(_:other:)", .function, in: file)
        #expect(topLevel.parentIndex == nil)
        #expect(topLevel.signature.contains("some Collection"))
        #expect(topLevel.signature.contains("any Equatable"))
        _ = try symbol("Grams", .typealiasKind, in: file)
        _ = try symbol("++*", .operatorKind, in: file)
        let builder = try symbol("ListBuilder", .structKind, in: file)
        #expect(builder.signature.contains("@resultBuilder"))
    }

    @Test
    func ifConfigBranchesAreBothIndexedAndTagged() throws {
        let file = try Self.parseFixture()

        let shims = file.symbols.filter { $0.name == "PlatformShim" }

        #expect(shims.count == 2)
        #expect(shims.compactMap(\.ifConfigCondition).sorted() == ["#else", "#if os(iOS)"])
    }

    @Test
    func neverAPIRegionsProduceNoSymbols() throws {
        let file = try Self.parseFixture()

        _ = try symbol("Housekeeping", .classKind, in: file)

        #expect(!file.symbols.contains { $0.name == "leakGuard" })
        #expect(!file.symbols.contains { $0.name == "previewLocal" })
        #expect(!file.symbols.contains { $0.name.contains("deinit") })
    }

    @Test
    func tuplePatternsAndObserversAreStoredProperties() throws {
        let file = try Self.parseFixture()

        let left = try symbol("leftPart", .variable, in: file)
        let right = try symbol("rightPart", .variable, in: file)
        let observed = try symbol("observedValue", .variable, in: file)

        #expect(left.isStored)
        #expect(right.isStored)
        #expect(observed.isStored)
    }

    @Test
    func attributedPrivateExtensionStillGrantsItsAccess() throws {
        let file = try Self.parseFixture()

        let label = try symbol("availabilityLabel()", .function, in: file)

        #expect(label.accessLevel == .privateLevel)
    }

    @Test
    func brokenSourceStillIndexesWithErrorCount() throws {
        let temp = try TemporaryDirectory.make("broken").appendingPathComponent("broken.swift")
        try "struct Broken {\n    let dangling = \n".write(to: temp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: temp) }
        let parsed = try #require(FileParser.parse(absoluteURL: temp, repoRelativePath: "Broken.swift"))

        #expect(parsed.parseErrorCount > 0)
        #expect(parsed.symbols.contains { $0.name == "Broken" })
    }
}
