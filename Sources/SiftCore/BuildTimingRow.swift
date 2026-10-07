//
// Copyright © Agulhas Labs
//

/// Every timing line printed for one site, folded into one row: the summed milliseconds and how many lines were summed.
///
/// A site timed more than once is one row with a count — a stored property's initializer is checked in every frontend job that needs its type, and a property's synthesized accessors are separate body lines at the property's own location.
public struct BuildTimingRow: Sendable, Equatable {
    /// Repo-relative path of the file holding the site.
    public let path: String
    public let line: Int
    public let column: Int
    public let kind: BuildTimingKind
    public let milliseconds: Double
    /// How many timing lines were folded into this row.
    public let count: Int
    /// The declaration enclosing the site, from a fresh parse of its file; `nil` when the site is in no declaration or the file could not be read.
    public let declaration: RunFailureSites.Declaration?
    /// The named shape of an expression site — `long literal chain`, `untyped mixed collection literal` or `ternary chain` — or `nil` when it is none of those, or the row is a body.
    public let shape: String?
    /// The compiler's own description of a body site's declaration, or `nil` for an expression row.
    ///
    /// Carried past folding so a nested body (`local function …`) can be told apart from a top-level one without a parse.
    public let declarationDescription: String?

    public init(
        path: String,
        line: Int,
        column: Int,
        kind: BuildTimingKind,
        milliseconds: Double,
        count: Int,
        declaration: RunFailureSites.Declaration? = nil,
        shape: String? = nil,
        declarationDescription: String? = nil
    ) {
        self.path = path
        self.line = line
        self.column = column
        self.kind = kind
        self.milliseconds = milliseconds
        self.count = count
        self.declaration = declaration
        self.shape = shape
        self.declarationDescription = declarationDescription
    }

    /// Whether the compiler printed this body as a local function, which is always nested inside its enclosing declaration's own body line and so double-counts that line's time.
    var isNestedLocalFunction: Bool {
        kind == .body && (declarationDescription?.hasPrefix("local function ") ?? false)
    }

    /// This row with its enclosing declaration and, for an expression, its named shape attached.
    func resolved(to declaration: RunFailureSites.Declaration?, shape: String? = nil) -> BuildTimingRow {
        BuildTimingRow(
            path: path,
            line: line,
            column: column,
            kind: kind,
            milliseconds: milliseconds,
            count: count,
            declaration: declaration,
            shape: shape,
            declarationDescription: declarationDescription
        )
    }
}
