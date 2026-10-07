//
// Copyright © Agulhas Labs
//

import Foundation

/// The index call that answers a lookup the advice hook answers itself (``InPlaceShape``), with the search it must account for where the lookup was a grep.
public enum InPlaceCall: Equatable, Sendable {
    /// The digest of one file, for a whole read of it or for line windows of it, at the path the command named.
    ///
    /// `windows` is every window the lookup reads the file through, empty for a whole read or a window whose lines cannot be read off the command: where the file's digest is over the size budget, the members those lines overlap answer in its place.
    case fileDigest(path: String, windows: [LineWindow] = [])
    /// The heading outline of one Markdown document, for a whole read of it, at the path the read named — the offer's own answer, handed over rather than proven.
    ///
    /// Nothing about a `.md` file is indexed, so there is nothing to prove an outline against: it is read live from disk by the renderer that answers `digest <path>.md`, which is the call the refusal would have named.
    case documentOutline(path: String)
    /// The digest of one file, for a grep of it for its declarations: answered only where every line the grep prints is a line the digest numbers.
    case declarations(file: String, search: ShellGrep)
    /// The source of every member whose declaration a grep of one file matches — or of several named files, a glob of them, or one searched recursively, file by file — answered only where every line it prints is inside a source served.
    case members(search: ShellGrep)
    /// The source of the one member a `sed`/`awk` pattern range prints: answered only where the lines the range prints from the file are exactly that member's lines.
    case memberRange(file: String, range: RangeRead)
    /// `where --refs` for one name, for a word-anchored sweep: answered only where every line it prints is a declaration or a reference the answer lists.
    case references(name: String, search: ShellGrep)
    /// One plain `where` per name, for a tree search whose pattern reads as a name or an alternation of names — the offer's own answer, handed over rather than proven against the search's output.
    ///
    /// The search's own path operands ride with it, spelled as the command wrote them: they are what roots the answer, and what bounds it — an answer whose every site falls outside them is withheld, since the search itself would have printed nothing.
    ///
    /// `uncovered` is the prose branches the alternation carried beside its names, as written: no `where` answers them, so the answer names each as left to the identical re-run rather than narrowing the question in silence.
    ///
    /// `proof` is the command's own search, carried where its pattern reads a name through a metatype, a self-expression or `Self` (`T.Type`, `T.self`, `Self.x`): such a line may hold the name only in a comment or a string literal, so the answer is handed over only where every line that search prints is a site the names' references locate.
    ///
    /// `unchecked` marks a tree searched with a Swift file named beside it: a line such a search prints may name the name only in a doc comment or a string literal, which a `where` answer says nothing about, and nothing here can check the lines it prints, so the answer is withheld unchecked and the search runs.
    case symbols(names: [String], paths: [String], uncovered: [String] = [], proof: ShellGrep? = nil, unchecked: Bool = false)
}

public extension InPlaceCall {
    /// Which of the six shapes a call is, without what it names — what the back-off is kept by (``InPlaceBackoff``).
    enum Shape: String, Sendable {
        case read, outline, declarations, members, sweep, symbols

        /// Whether the shape's answer is made of what the build's index store holds: a `where` lists a symbol's callers from it, and lists none without it.
        var needsIndexStore: Bool {
            self == .sweep || self == .symbols
        }
    }

    /// The path a whole read names — a Swift file's digest or a document's outline, the one kind of lookup several of which are answered together (``InPlaceShape``) — and `nil` for every other call.
    var readPath: String? {
        switch self {
        case let .fileDigest(path, _), let .documentOutline(path): path
        default: nil
        }
    }

    /// The line windows a file's digest reads it through, and none for every other call.
    var windows: [LineWindow] {
        if case let .fileDigest(_, windows) = self {
            return windows
        }
        return []
    }

    /// The shape this call is.
    var shape: Shape {
        switch self {
        case .fileDigest: .read
        case .documentOutline: .outline
        case .declarations: .declarations
        case .members, .memberRange: .members
        case .references: .sweep
        case .symbols: .symbols
        }
    }
}
