//
// Copyright © Agulhas Labs
//

import Foundation

/// A rendered answer, carrying what it cost against the source it stands in for wherever both sides were genuinely counted.
///
/// The compression floor (`SourcePassthrough`) already weighs a digest against the declaration source it summarises, to decide which of the two to serve. Spending that comparison on the decision and discarding it would leave the usage log able to say how often the index was asked and never what an answer saved. Carrying it out costs nothing — the bytes are in hand at answer time — and turns the saving into a measurement rather than a claim.
///
/// `bytes` is nil for every answer shape that has no honest alternative to measure against: a symbol lookup, a structural search, a string-catalog trace. A denominator invented for those would make the saving unfalsifiable, which is the one thing a savings number must not be.
///
/// Only the *denominator* is scarce, though, and the two halves travel separately: what an answer cost is the length of what went out, which the face counts for every call it serves whether or not this value carries any bytes at all. Nothing here needs to know that — it is exactly why the served side is settled at the framing, where the full text is in hand — but a reader of this type should not take a nil `bytes` to mean the call went unrecorded.
public struct MeasuredAnswer: Sendable, Equatable {
    public let text: String

    /// Both sides of this answer's cost, or `nil` when this shape of answer measures nothing.
    public let bytes: Bytes?

    /// Whether the target resolved to nothing at all — a plain miss, a wrong path or a list of nearest names, as against an answer about something that is there.
    ///
    /// Carried for the face, which knows what the caller typed and so can say what the miss most likely was: a `digest` target with a space in it that named nothing is usually several targets sent as one.
    public let missed: Bool

    /// The files whose rows were found stale while this answer read their source, and reparsed before it was rendered again; the face names them in the header's `dirty:` field (``Freshness/reparsedPaths``).
    public let reparsedPaths: [String]

    /// The files found stale that could not be reparsed (unreadable, not UTF-8, or gone since the read), whose old rows still stand; the face names them beside ``reparsedPaths`` (``Freshness/unreparsedPaths``).
    public let unreparsedPaths: [String]

    /// The stored count of files with parse errors, read after the reparse that changed it, where there was one; `nil` where the header's own count already stands (``Freshness/noting(_:)``).
    public let parseErrorFiles: Int?

    /// What each name of a target string answered as several (``DigestSpacedTarget``) served, one per name served, in the order given; empty for every other answer.
    ///
    /// Carried for the usage log, which credits a split answer as it would the separate single-target calls and so has to know which name served which file: the joined text cannot say, since a module's part lists files under headings and a same-named file can stand in another part.
    public let parts: [Part]

    public init(text: String, bytes: Bytes? = nil, missed: Bool = false, reparsedPaths: [String] = [], unreparsedPaths: [String] = [], parseErrorFiles: Int? = nil, parts: [Part] = []) {
        self.parseErrorFiles = parseErrorFiles
        self.parts = parts
        self.text = text
        self.bytes = bytes
        self.missed = missed
        self.reparsedPaths = reparsedPaths
        self.unreparsedPaths = unreparsedPaths
    }
}

public extension MeasuredAnswer {
    /// One answer measured against its alternative, both sides counted at answer time.
    ///
    /// Bytes, not tokens, and said that way everywhere it surfaces: this counts what was rendered, and any conversion to tokens would be an estimate wearing a measurement's clothes. A ratio of two byte counts taken the same way is reliable even where neither absolute number is.
    struct Bytes: Sendable, Equatable {
        /// The answer as served.
        ///
        /// The engine fills this in with what it rendered, and a face that frames the answer — the MCP server's freshness header, alias note and adopted-root line — restates it against the text it actually sent. Measuring the unframed answer would understate the cost by a few hundred bytes every time, and always in the flattering direction, which is the wrong direction for a number whose whole job is to be falsifiable.
        public let answer: Int

        /// The source that answer stands in for — the declaration sites a digest summarises, or the file it replaces.
        public let source: Int

        public init(answer: Int, source: Int) {
            self.answer = answer
            self.source = source
        }
    }
}

public extension MeasuredAnswer {
    /// One name's part of an answer to a target string served as several names: the name, the file its own header names, and whether that file was served in place of a path holding none.
    struct Part: Sendable, Equatable {
        /// The name as it stood in the target string.
        public let target: String

        /// The file the part's own header names: a file digest's, the file a type digest's header cites, or, where ``servedInstead``, the file served in the name's place; `nil` for a part that opens on no such header, a module's or a member body's.
        public let file: String?

        /// Whether the part opens with the notice that ``file`` was served instead of the path the name asks for, which names no indexed file.
        public let servedInstead: Bool

        /// The source the part stands in for, where it weighed itself against one: a type or file digest.
        public let source: Int?

        /// The files the part locates, exactly as the usage line of a digest of ``target`` alone records them (``ExactAnswer/files(inDigestAnswer:)``), so a split answer locates no file the separate calls would not.
        public let located: [String]

        public init(target: String, file: String?, servedInstead: Bool, source: Int?, located: [String] = []) {
            self.target = target
            self.file = file
            self.servedInstead = servedInstead
            self.source = source
            self.located = located
        }
    }
}
