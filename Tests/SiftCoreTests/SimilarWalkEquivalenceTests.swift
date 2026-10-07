//
// Copyright © Agulhas Labs
//

@testable import SiftCore
import Testing

/// What each of a fingerprint's three axes reads, and from which part of the declaration: callees and control flow from the body alone, type names from the parameters and return alone.
struct SimilarWalkEquivalenceTests {
    private static var loader: String {
        """
        enum Probe {
            @MainActor
            static func load<Item: Decodable>(_ url: URL, retries: Int = Policy.limit(), decoder: JSONDecoder = JSONDecoder()) async throws(CrateData) -> [Item] where Item: Sendable {
                let cache: DepotStore = DepotStore()
                guard let data = try? fetch(url) else { throw CrateData.missing }
                for attempt in 0 ..< retries {
                    do {
                        return try decoder.decode([Item].self, from: data)
                    } catch {
                        log(attempt)
                    }
                }
                let items = cache.items.map { entry in
                    if entry.isEmpty { return trim(entry) }
                    return entry
                }
                func helper() -> Int {
                    while true { repeat { tick() } while false }
                    return 0
                }
                defer { finish() }
                switch items.count { case 0: return [] default: break }
                return items
            }
        }
        """
    }

    private static var accessors: String {
        """
        struct Ledger {
            init(rows: [Row] = Row.defaults()) {
                if rows.isEmpty { seed() }
                self.rows = rows
            }
            subscript(index: Index) -> Entry {
                get { guard valid(index) else { fatalError() }; return entries[index] }
                set { store(index) }
            }
            var total: Total {
                get { sum(parts) }
                set { apply(parts) }
            }
        }
        """
    }

    private static func fingerprint(_ name: String, in source: String, sourceLocation: SourceLocation = #_sourceLocation) -> DeclarationFingerprint? {
        let found = FingerprintScanner.fingerprints(in: source, path: "Sources/Probe.swift").first { $0.declaration.qualifiedName == name }
        if found == nil {
            Issue.record("no fingerprint named \(name)", sourceLocation: sourceLocation)
        }
        return found
    }

    /// Calls written in a default argument are not the body's, and a nested closure's or local function's are.
    @Test
    func calleesComeFromTheWholeBodyAndNothingElse() throws {
        let subject = try #require(Self.fingerprint("Probe.load(_:retries:decoder:)", in: Self.loader))

        #expect(subject.callees == ["DepotStore", "fetch", "decode", "log", "map", "trim", "tick", "finish"])
    }

    /// Control flow is read in source order through closures and local functions, and nothing in the signature adds to it.
    @Test
    func theSkeletonIsTheBodysControlFlowInSourceOrder() throws {
        let subject = try #require(Self.fingerprint("Probe.load(_:retries:decoder:)", in: Self.loader))

        #expect(subject.skeleton == [
            .guardToken, .throwToken, .forToken, .doToken, .returnToken, .catchToken,
            .ifToken, .returnToken, .returnToken,
            .whileToken, .repeatToken, .returnToken,
            .deferToken, .switchToken, .returnToken, .returnToken,
        ])
    }

    /// Only the parameter and return types count: not an attribute, a generic constraint, a typed throw, or a type the body names.
    @Test
    func typeNamesComeFromParametersAndReturnOnly() throws {
        let subject = try #require(Self.fingerprint("Probe.load(_:retries:decoder:)", in: Self.loader))

        #expect(subject.typeNames == ["URL", "Int", "JSONDecoder", "Item"])
    }

    /// An initializer, a subscript and a computed property read their axes from the same places a function does.
    @Test
    func accessorBodiesAndInitializersReadTheSameAxes() throws {
        let initializer = try #require(Self.fingerprint("Ledger.init(rows:)", in: Self.accessors))
        let subscriptDecl = try #require(Self.fingerprint("Ledger.subscript(_:)", in: Self.accessors))
        let total = try #require(Self.fingerprint("Ledger.total", in: Self.accessors))

        #expect(initializer.callees == ["seed"])
        #expect(initializer.skeleton == [.ifToken])
        #expect(initializer.typeNames == ["Row"])
        #expect(subscriptDecl.callees == ["valid", "fatalError", "store"])
        #expect(subscriptDecl.skeleton == [.guardToken, .returnToken])
        #expect(subscriptDecl.typeNames == ["Index", "Entry"])
        #expect(total.callees == ["sum", "apply"])
        #expect(total.skeleton.isEmpty)
        #expect(total.typeNames == ["Total"])
    }

    /// A skeleton longer than the cap keeps its first tokens, in order, and no more.
    @Test
    func aLongSkeletonIsCutAtTheCap() throws {
        let statements = (0 ..< 40).map { "    if flag\($0) { return }" }.joined(separator: "\n")
        let source = "func long() {\n\(statements)\n}\n"
        let subject = try #require(Self.fingerprint("long()", in: source))
        let pairs = SimilarityScore.skeletonCap / 2

        #expect(subject.skeleton == Array(repeating: [DeclarationFingerprint.ControlToken.ifToken, .returnToken], count: pairs).flatMap(\.self))
    }
}
