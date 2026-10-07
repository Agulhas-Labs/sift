//
// Copyright © Agulhas Labs
//

/// One line of the compiler's own timing output, read: how long, where, and which timer printed it.
public struct BuildTiming: Sendable, Equatable {
    public let milliseconds: Double
    /// The path exactly as the compiler printed it, which for a SwiftPM build is absolute.
    public let path: String
    public let line: Int
    public let column: Int
    public let kind: BuildTimingKind
    /// The compiler's own third, tab-separated field for a body line — the declaration it printed, e.g. `instance method Widget.(file).Ledger.total()@…` or `local function Widget.(file).outer().inner()@…` — or `nil` for an expression line, which carries none.
    public let declarationDescription: String?

    public init(milliseconds: Double, path: String, line: Int, column: Int, kind: BuildTimingKind, declarationDescription: String? = nil) {
        self.milliseconds = milliseconds
        self.path = path
        self.line = line
        self.column = column
        self.kind = kind
        self.declarationDescription = declarationDescription
    }
}
