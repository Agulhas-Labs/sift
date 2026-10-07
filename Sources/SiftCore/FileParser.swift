//
// Copyright © Agulhas Labs
//

import CryptoKit
import Foundation
import SwiftParser
import SwiftParserDiagnostics
import SwiftSyntax

/// Parses one file end to end: bytes → tree → visitor → `ParsedFile`, discarding the tree before returning.
struct FileParser {
    /// Parses the file at `absoluteURL`, recording it under `repoRelativePath`; `nil` when the file cannot be read as UTF-8.
    static func parse(absoluteURL: URL, repoRelativePath: String) -> ParsedFile? {
        guard let data = try? Data(contentsOf: absoluteURL),
              let source = String(data: data, encoding: .utf8) else { return nil }
        // Statted after the read, so a write landing between the two can only make the row look newer than its bytes.
        let mtime = FileChangeStat.of(path: absoluteURL.path)?.changed ?? 0
        // Sized and hashed over the bytes on disk, never over `source`: decoding drops a UTF-8 byte-order mark,
        // and the reconcile and the reparse check both compare against the raw file — a file measured one way
        // and checked the other never matches, so it would be re-parsed on every pass and never hash-skipped.
        return parse(source: source, repoRelativePath: repoRelativePath, mtime: mtime, bytes: data, signatures: .display)
    }

    /// Parses `source` directly, for content that has no file on disk to stat — one side of a `git show <rev>:<path>` diff — with one more read of the same tree before it is discarded.
    ///
    /// For `diff`, which needs what lies outside the declarations as well as the declarations, and must not parse a file twice to get both. Its signatures are the compared form (``SymbolVisitor/Signatures/compared``): whole, never cut for display. `mtime` is zero, since there is no file to have one.
    static func parse<Extra>(
        source: String,
        repoRelativePath: String,
        alongside extra: (SourceFileSyntax, SourceLocationConverter) -> Extra
    ) -> (file: ParsedFile, extra: Extra) {
        var extraResult: Extra?
        let file = parse(source: source, repoRelativePath: repoRelativePath, mtime: 0, bytes: Data(source.utf8), signatures: .compared) { tree, converter in
            extraResult = extra(tree, converter)
        }
        // The closure above runs exactly once, inside the walk, before this line is reached.
        guard let extraResult else { preconditionFailure("the tree was walked without the extra read") }
        return (file, extraResult)
    }

    /// Parses `source` for its syntax errors alone, placed under `path`, without walking its declarations.
    static func errors(inSource source: String, path: String) -> [ParseErrorSite] {
        let tree = Parser.parse(source: source)
        return errors(in: tree, converter: SourceLocationConverter(fileName: path, tree: tree))
    }

    /// The errors the parser recovered from in `tree`, in source order, each placed by `converter`.
    ///
    /// The one reading of a parse's errors, so the index's count and the edit check's list never disagree about whether a file parses.
    private static func errors(in tree: SourceFileSyntax, converter: SourceLocationConverter) -> [ParseErrorSite] {
        guard tree.hasError else { return [] }
        return ParseDiagnosticsGenerator.diagnostics(for: tree)
            .filter { $0.diagMessage.severity == .error }
            .map { diagnostic in
                let location = diagnostic.location(converter: converter)
                return ParseErrorSite(line: location.line, column: location.column, message: diagnostic.message)
            }
    }

    /// The walk every overload shares, with `bytes` as the content the recorded size and hash describe.
    private static func parse(
        source: String,
        repoRelativePath: String,
        mtime: Double,
        bytes data: Data,
        signatures: SymbolVisitor.Signatures,
        alongside extra: (SourceFileSyntax, SourceLocationConverter) -> Void = { _, _ in }
    ) -> ParsedFile {
        let hashDigest = SHA256.hash(data: data)
        let hash = hashDigest.map { String(format: "%02x", $0) }.joined()

        let tree = Parser.parse(source: source)
        let converter = SourceLocationConverter(fileName: repoRelativePath, tree: tree)
        let errorCount = errors(in: tree, converter: converter).count
        let visitor = SymbolVisitor(converter: converter, sourceBytes: Array(source.utf8), signatures: signatures)
        visitor.walk(tree)
        extra(tree, converter)

        return ParsedFile(
            path: repoRelativePath,
            size: data.count,
            mtime: mtime,
            contentHash: hash,
            imports: visitor.imports,
            parseErrorCount: errorCount,
            symbols: visitor.symbols
        )
    }
}
