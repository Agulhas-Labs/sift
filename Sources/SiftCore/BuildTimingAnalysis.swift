//
// Copyright © Agulhas Labs
//

import Foundation
import SwiftOperators
import SwiftSyntax

/// A build's timing lines folded by site and by file, the slowest sites ranked and named by the declaration that encloses them.
///
/// Only the package's own sources are ranked: a site outside the package directory, or inside its `.build/` where dependencies are checked out, is counted in ``outsideMilliseconds`` and ``outsideLines`` and nowhere else. Body time and expression time are totalled apart, because a body's time already includes its expressions'.
public struct BuildTimingAnalysis: Sendable, Equatable {
    /// The slowest function-body sites, at most the `top` asked for, slowest first.
    public let bodies: [BuildTimingRow]
    /// The slowest expression sites, at most the `top` asked for, slowest first.
    public let expressions: [BuildTimingRow]
    /// Every file of the package's own sources that was timed, most body time first.
    public let files: [BuildTimingFileTotal]
    public let bodyMilliseconds: Double
    public let bodyLines: Int
    /// How many distinct body sites the body lines fold into.
    public let bodySites: Int
    /// Every body row the ranking can list, nested local functions included, which is what the listing's heading counts against.
    public let bodyRows: Int
    public let expressionMilliseconds: Double
    public let expressionLines: Int
    /// How many distinct expression sites the expression lines fold into.
    public let expressionSites: Int
    /// Body time printed for sites outside the package's own sources, never ranked.
    ///
    /// Only the bodies that are not nested are summed, because a local function's time is inside its enclosing body's; ``outsideLines`` still counts every line.
    public let outsideBodyMilliseconds: Double
    /// Expression time printed for sites outside the package's own sources that sit in no function body, such as a global or static initializer: an expression inside a body is in that body's time and is not added again.
    ///
    /// Read from a parse of the file where it can be read; where it cannot, an expression counts when its file printed no body line at all.
    public let outsideExpressionMilliseconds: Double
    public let outsideLines: Int
    /// Body time printed for a macro expansion's generated buffer (`@__swiftmacro_….swift`), which names no file of the package, so it is never ranked; a nested local function's is left out, as from every total.
    public let macroBodyMilliseconds: Double
    /// Expression time printed for a macro expansion's generated buffer, never ranked: it may sit inside a timed body, or inside the expanding expression's own line, so it is never added to anything.
    public let macroExpressionMilliseconds: Double
    public let macroLines: Int

    /// Folds `timings` from a build of the package at the given root, naming paths relative to the tree's root and keeping the `top` slowest sites of each kind.
    public init(timings: [BuildTiming], packageRoot: URL, treeRoot: URL, top: Int) {
        let folded = BuildTimingFold(timings: timings, packageRoot: packageRoot, treeRoot: treeRoot)
        let bodyRows = folded.rows(of: .body)
        let expressionRows = folded.rows(of: .expression)
        let listed = Self.resolving(Array(bodyRows.prefix(top)) + Array(expressionRows.prefix(top)), under: treeRoot)
        bodies = listed.filter { $0.kind == .body }
        expressions = listed.filter { $0.kind == .expression }
        files = folded.files
        // A local function's body row is always inside its enclosing declaration's own body row, whose time
        // already includes it, so it is left out of the totals here — it can still rank and be listed above.
        let countedBodyRows = bodyRows.filter { !$0.isNestedLocalFunction }
        bodyMilliseconds = countedBodyRows.reduce(0) { $0 + $1.milliseconds }
        bodyLines = countedBodyRows.reduce(0) { $0 + $1.count }
        bodySites = countedBodyRows.count
        self.bodyRows = bodyRows.count
        expressionMilliseconds = expressionRows.reduce(0) { $0 + $1.milliseconds }
        expressionLines = expressionRows.reduce(0) { $0 + $1.count }
        expressionSites = expressionRows.count
        outsideBodyMilliseconds = folded.outsideBodyMilliseconds
        outsideExpressionMilliseconds = Self.expressionTimeOutsideBodies(folded.outsideExpressions, filesWithBodies: folded.outsideBodyPaths)
        outsideLines = folded.outsideLines
        macroBodyMilliseconds = folded.macroBodyMilliseconds
        macroExpressionMilliseconds = folded.macroExpressionMilliseconds
        macroLines = folded.macroLines
    }

    /// The time printed outside the package's own sources, bodies and the expressions in no body, which never overlap.
    public var outsideMilliseconds: Double {
        outsideBodyMilliseconds + outsideExpressionMilliseconds
    }

    /// What the listed body rows add up to, the numerator of their share of ``bodyMilliseconds``.
    ///
    /// A nested body's own row can still be listed, but its time is excluded here too — it is already inside the row that encloses it.
    public var listedBodyMilliseconds: Double {
        bodies.filter { !$0.isNestedLocalFunction }.reduce(0) { $0 + $1.milliseconds }
    }

    /// What the listed expression rows add up to, the numerator of their share of ``expressionMilliseconds``.
    public var listedExpressionMilliseconds: Double {
        expressions.reduce(0) { $0 + $1.milliseconds }
    }
}

private extension BuildTimingAnalysis {
    /// `rows` with each one's enclosing declaration attached, and each expression's shape named, parsing each file they name once.
    ///
    /// A fresh parse rather than the index's stored ranges: the build just compiled these bytes, and a stored range is the one thing about a just-edited file that can be stale. Only the files of listed rows are parsed, one parse per file giving both the declaration and the tree an expression's shape is read from.
    static func resolving(_ rows: [BuildTimingRow], under treeRoot: URL) -> [BuildTimingRow] {
        var files: [String: ParsedFile?] = [:]
        var trees: [String: BuildTimingParsedTree?] = [:]
        return rows.map { row in
            // A local function holds no declaration of its own in the parsed file's symbol table — only its
            // enclosing declaration does — so `Declaration(enclosing:)` would misname this row with the outer
            // one. The compiler's own description already carries the nested name, e.g. `outer().inner()`.
            if row.isNestedLocalFunction, let description = row.declarationDescription, let name = Self.nestedBodyName(description) {
                let declaration = RunFailureSites.Declaration(name: name, path: row.path, startLine: row.line, endLine: row.line)
                return row.resolved(to: declaration)
            }
            let file: ParsedFile?
            let tree: BuildTimingParsedTree?
            if let known = files[row.path], let knownTree = trees[row.path] {
                (file, tree) = (known, knownTree)
            } else {
                (file, tree) = Self.parse(row.path, under: treeRoot)
                files[row.path] = .some(file)
                trees[row.path] = .some(tree)
            }
            guard let file else {
                return row
            }
            var declaration = RunFailureSites.Declaration(enclosing: row.line, in: file)
            if let enclosing = declaration, let tree, let deinitializer = BuildTimingDeinitializers.range(containing: row.line, in: tree.tree, converter: tree.converter) {
                // The enclosing declaration of a line inside a `deinit` is its type, which the row would then read as the type itself.
                // A local class is no declaration of its own, so what encloses its `deinit` is the function that holds the class: the class is named instead.
                let isLocalType = deinitializer.owner.map { enclosing.name != $0 && !enclosing.name.hasSuffix("." + $0) } ?? false
                let typeName = isLocalType ? deinitializer.owner ?? enclosing.name : enclosing.name
                declaration = RunFailureSites.Declaration(name: typeName + ".deinit", path: row.path, startLine: deinitializer.lines.lowerBound, endLine: deinitializer.lines.upperBound)
            }
            let shape = row.kind == .expression ? tree.flatMap {
                BuildTimingExpressionShape.name(atLine: row.line, column: row.column, in: $0.tree, converter: $0.converter)
            } : nil
            return row.resolved(to: declaration, shape: shape)
        }
    }

    /// What `expressions` add up to once those inside a function body are left out, because the body's time already holds them.
    ///
    /// Each file is parsed once for its bodies' spans; a file that cannot be read is judged by whether it printed a body line.
    static func expressionTimeOutsideBodies(_ expressions: [BuildTiming], filesWithBodies: Set<String>) -> Double {
        var spans: [String: [BuildTimingBodySpans.Span]?] = [:]
        var total = 0.0
        for expression in expressions {
            if spans[expression.path] == nil {
                spans[expression.path] = .some(Self.bodySpans(of: expression.path))
            }
            if let cached = spans[expression.path], let known = cached {
                total += known.contains { $0.holds(line: expression.line, column: expression.column) } ? 0 : expression.milliseconds
            } else {
                total += filesWithBodies.contains(expression.path) ? 0 : expression.milliseconds
            }
        }
        return total
    }

    /// The function bodies of the Swift file at the absolute `path`, or `nil` when it cannot be read as UTF-8.
    static func bodySpans(of path: String) -> [BuildTimingBodySpans.Span]? {
        guard let data = FileManager.default.contents(atPath: path), let source = String(data: data, encoding: .utf8) else {
            return nil
        }
        return BuildTimingBodySpans.spans(in: source)
    }

    /// The qualified declaration name from the compiler's own description — `outer().inner()` out of `local function Widget.(file).outer().inner()@…` — or `nil` when the description does not carry the `.(file).…@` shape this parses.
    static func nestedBodyName(_ description: String) -> String? {
        guard let fileMarker = description.range(of: ".(file)."),
              let atSign = description.range(of: "@", range: fileMarker.upperBound ..< description.endIndex)
        else {
            return nil
        }
        return String(description[fileMarker.upperBound ..< atSign.lowerBound])
    }

    /// Reads and parses `path` under the tree root, or `nil` for both when it cannot be read as UTF-8.
    static func parse(_ path: String, under treeRoot: URL) -> (file: ParsedFile?, tree: BuildTimingParsedTree?) {
        guard let data = try? Data(contentsOf: treeRoot.appendingPathComponent(path)),
              let source = String(data: data, encoding: .utf8)
        else {
            return (nil, nil)
        }
        let (file, extra) = FileParser.parse(source: source, repoRelativePath: path) { tree, converter in (tree, converter) }
        // Sequence expressions arrive flat, precedence unresolved; folded once here so a `+` chain or a
        // ternary chain reads as the nested tree it is, rather than a sequence no shape can be read off.
        let folded = OperatorTable.standardOperators.foldAll(extra.0) { _ in }
        let tree = folded.as(SourceFileSyntax.self) ?? extra.0
        return (file, BuildTimingParsedTree(tree: tree, converter: extra.1))
    }
}
