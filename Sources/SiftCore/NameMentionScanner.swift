//
// Copyright © Agulhas Labs
//

import Foundation
import SwiftParser
import SwiftSyntax

/// Where a set of names is *written* across the working tree — no claim that any of them resolves to the symbol asked about.
///
/// The counterpart to `CallSiteScanner`, and deliberately not a mode of it. That one answers `where`'s question — what *calls* this — and carries the enclosing declaration with every hit; this one answers `affected`'s, where a type named as a type, a property read and a written conformance are all references a caller list could never hold, and where the enclosing declaration is resolved from the index by line rather than re-derived during the walk. Folding the two together would leave each carrying the other's machinery: this scanner needs no declaration-context stack at all, which is most of what that one is.
///
/// **A name is not a symbol**, and every rendering of these results has to say so. Same-named members of unrelated types are included, a dynamically dispatched call is missed, and a mention inside a comment or a string is not counted (those are tokens the parser classifies, not identifiers). It exists because the case that needs it is the normal one: the index store is built by the last build, so the files a working tree has *just changed* are exactly the ones it cannot be asked about, and a refusal the reader cannot act on is worse than a labelled approximation — the argument `where`'s own syntactic fallback already settled.
struct NameMentionScanner {
    let repoRoot: URL
    let enumerator: FileEnumerator

    /// Every distinct (file, line) each requested name is written on, ordered by path then line.
    ///
    /// Distinct per line rather than per occurrence: this feeds a lookup of the declaration enclosing the line, so a name written three times on one line is one answer, and keeping all three would triple the work for nothing.
    func mentions(of names: Set<String>) async -> [String: [NameMention]] {
        guard !names.isEmpty else { return [:] }
        let paths = enumerator.swiftFiles()
        guard !paths.isEmpty else { return [:] }
        let cores = ProcessInfo.processInfo.activeProcessorCount
        let rootPath = repoRoot.path
        var collected: [String: Set<NameMention>] = [:]
        await withTaskGroup(of: [String: Set<NameMention>].self) { group in
            var iterator = paths.makeIterator()
            var inFlight = 0
            while inFlight < cores, let path = iterator.next() {
                group.addTask { Self.mentions(at: path, rootPath: rootPath, names: names) }
                inFlight += 1
            }
            for await found in group {
                for (name, sites) in found {
                    collected[name, default: []].formUnion(sites)
                }
                if let path = iterator.next() {
                    group.addTask { Self.mentions(at: path, rootPath: rootPath, names: names) }
                }
            }
        }
        return collected.mapValues { $0.sorted { ($0.path, $0.line) < ($1.path, $1.line) } }
    }

    private static func mentions(at path: String, rootPath: String, names: Set<String>) -> [String: Set<NameMention>] {
        guard let data = FileManager.default.contents(atPath: rootPath + "/" + path),
              let source = String(data: data, encoding: .utf8) else { return [:] }
        // A file that never spells the name cannot mention it, and the substring check is far cheaper than a parse — the difference between scanning a monorepo and scanning the few files that could possibly match.
        guard names.contains(where: { source.contains($0) }) else { return [:] }
        let tree = Parser.parse(source: source)
        let converter = SourceLocationConverter(fileName: path, tree: tree)
        let visitor = Visitor(names: names, path: path, converter: converter)
        visitor.walk(tree)
        return visitor.found
    }
}

private extension NameMentionScanner {
    /// Records every identifier token matching one of the requested names.
    ///
    /// Token-level rather than expression-level on purpose: the shapes that matter here — `let store: ChangedType`, `ChangedEnum.case`, `: ChangedProtocol` in an inheritance clause — are not calls and have no single expression node in common. Declaration names match too, so a test target declaring its own `makeStore` while the changed symbol is also called `makeStore` is listed; that is the over-inclusive direction, which is the safe one.
    final class Visitor: SyntaxVisitor {
        private let names: Set<String>
        private let path: String
        private let converter: SourceLocationConverter
        var found: [String: Set<NameMention>] = [:]

        init(names: Set<String>, path: String, converter: SourceLocationConverter) {
            self.names = names
            self.path = path
            self.converter = converter
            super.init(viewMode: .sourceAccurate)
        }

        override func visit(_ token: TokenSyntax) -> SyntaxVisitorContinueKind {
            guard case let .identifier(text) = token.tokenKind, names.contains(text) else { return .visitChildren }
            let line = converter.location(for: token.positionAfterSkippingLeadingTrivia).line
            found[text, default: []].insert(NameMention(path: path, line: line))
            return .visitChildren
        }
    }
}
