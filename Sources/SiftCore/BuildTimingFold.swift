//
// Copyright © Agulhas Labs
//

import Foundation

/// The single pass that sorts every timing line into its site and its file, and sets aside what is not the package's own.
struct BuildTimingFold {
    private var sites: [String: BuildTimingRow] = [:]
    private var perFile: [String: BuildTimingFileTotal] = [:]
    /// Body time of the lines outside the package, without a nested local function's, which is inside its enclosing body's.
    private(set) var outsideBodyMilliseconds: Double = 0
    /// The expression lines outside the package, which a body's time may or may not include: only a parse of the file says.
    private(set) var outsideExpressions: [BuildTiming] = []
    /// The printed paths of the files outside the package that had a body line.
    private(set) var outsideBodyPaths: Set<String> = []
    private(set) var outsideLines = 0
    /// Body time of the lines in a macro expansion's generated buffer, without a nested local function's.
    private(set) var macroBodyMilliseconds: Double = 0
    /// Expression time of the lines in a macro expansion's generated buffer, which may sit inside a timed body or the expanding expression's own line.
    private(set) var macroExpressionMilliseconds: Double = 0
    private(set) var macroLines = 0

    init(timings: [BuildTiming], packageRoot: URL, treeRoot: URL) {
        let package = CanonicalPath.of(packageRoot.path)
        let tree = CanonicalPath.of(treeRoot.path)
        var relative: [String: String?] = [:]
        for timing in timings {
            // A generated buffer is printed as a bare `@__swiftmacro_….swift`, which resolved against the working directory reads as a file at the package's root.
            if RunDiagnostic.isMacroExpansionBuffer(timing.path) {
                addMacroBuffer(timing)
                continue
            }
            let own: String?
            if let known = relative[timing.path] {
                own = known
            } else {
                own = Self.ownPath(timing.path, package: package, tree: tree)
                relative[timing.path] = .some(own)
            }
            guard let path = own else {
                addOutside(timing)
                continue
            }
            add(timing, at: path)
        }
    }

    /// The site rows of one kind, slowest first, ties in path and position order so the ranking never moves between runs.
    func rows(of kind: BuildTimingKind) -> [BuildTimingRow] {
        sites.values.filter { $0.kind == kind }.sorted { left, right in
            guard left.milliseconds == right.milliseconds else {
                return left.milliseconds > right.milliseconds
            }
            return (left.path, left.line, left.column) < (right.path, right.line, right.column)
        }
    }

    /// Every file's totals, most body time first, then most expression time, then by path.
    var files: [BuildTimingFileTotal] {
        perFile.values.sorted { left, right in
            guard left.bodyMilliseconds == right.bodyMilliseconds else {
                return left.bodyMilliseconds > right.bodyMilliseconds
            }
            guard left.expressionMilliseconds == right.expressionMilliseconds else {
                return left.expressionMilliseconds > right.expressionMilliseconds
            }
            return left.path < right.path
        }
    }
}

private extension BuildTimingFold {
    mutating func addOutside(_ timing: BuildTiming) {
        outsideLines += 1
        guard timing.kind == .body else {
            outsideExpressions.append(timing)
            return
        }
        outsideBodyPaths.insert(timing.path)
        let row = BuildTimingRow(path: timing.path, line: timing.line, column: timing.column, kind: .body, milliseconds: timing.milliseconds, count: 1, declarationDescription: timing.declarationDescription)
        // A local function's time is inside its enclosing body's, so only the bodies that are not nested are summed.
        if !row.isNestedLocalFunction {
            outsideBodyMilliseconds += timing.milliseconds
        }
    }

    mutating func addMacroBuffer(_ timing: BuildTiming) {
        macroLines += 1
        guard timing.kind == .body else {
            macroExpressionMilliseconds += timing.milliseconds
            return
        }
        let row = BuildTimingRow(path: timing.path, line: timing.line, column: timing.column, kind: .body, milliseconds: timing.milliseconds, count: 1, declarationDescription: timing.declarationDescription)
        // A local function's time is inside its enclosing body's, in a buffer as in a source file.
        if !row.isNestedLocalFunction {
            macroBodyMilliseconds += timing.milliseconds
        }
    }

    mutating func add(_ timing: BuildTiming, at path: String) {
        let key = "\(timing.kind == .body ? "b" : "e"):\(path):\(timing.line):\(timing.column)"
        let earlier = sites[key]
        let row = BuildTimingRow(
            path: path,
            line: timing.line,
            column: timing.column,
            kind: timing.kind,
            milliseconds: (earlier?.milliseconds ?? 0) + timing.milliseconds,
            count: (earlier?.count ?? 0) + 1,
            declarationDescription: timing.declarationDescription
        )
        sites[key] = row
        let file = perFile[path] ?? BuildTimingFileTotal(path: path, bodyMilliseconds: 0, bodyLines: 0, expressionMilliseconds: 0, expressionLines: 0)
        let isBody = timing.kind == .body
        // A local function's body line is always nested inside the enclosing declaration's own body line, whose
        // time already includes it — so it is left out of the file's body sum to avoid counting it twice.
        let isCountedBody = isBody && !row.isNestedLocalFunction
        perFile[path] = BuildTimingFileTotal(
            path: path,
            bodyMilliseconds: file.bodyMilliseconds + (isCountedBody ? timing.milliseconds : 0),
            bodyLines: file.bodyLines + (isCountedBody ? 1 : 0),
            expressionMilliseconds: file.expressionMilliseconds + (isBody ? 0 : timing.milliseconds),
            expressionLines: file.expressionLines + (isBody ? 0 : 1)
        )
    }

    /// `printed` relative to `tree` when it is one of the package's own sources, or `nil` when it is outside the package or under the package's `.build/`.
    static func ownPath(_ printed: String, package: String, tree: String) -> String? {
        let canonical = CanonicalPath.of(printed)
        guard canonical.hasPrefix(package + "/"), !canonical.hasPrefix(package + "/.build/"), canonical.hasPrefix(tree + "/") else {
            return nil
        }
        return String(canonical.dropFirst(tree.count + 1))
    }
}
