//
// Copyright © Agulhas Labs
//

import Foundation

/// One digest target as `digest` takes it: the whole string first, exactly as written, so a path with a space in it still resolves; and only where that does not resolve as itself, the names it is made of.
///
/// A string with whitespace in it that names nothing, or only a same-named file elsewhere, is almost always several targets sent as one. Where every name resolves they are served as the targets list serves them; where only some do, those are served under one line for each that is not, so the answer never reads as complete when it is not. Where none does the answer is the whole string's own.
///
/// An offset pages one answer, so a string that would be split is refused one, as the targets list is: the truncation line of a split answer names each part's own cursor, and a cursor given back with the whole string would otherwise find nothing.
public struct DigestSpacedTarget {
    let renderer: DigestRenderer

    /// The names `target` is made of where it is split: its whitespace-separated words.
    public static func names(in target: String) -> [String] {
        target.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// The answer for `target`, its names each answered on their own where the whole string does not resolve as itself.
    ///
    /// The source the answer stands in for is the sum of the source its parts stand in for, over the parts that weighed one: a part that weighs none (a member's body) adds nothing, which can only understate a saving, never overstate it.
    func measured(_ target: String, options: DigestOptions) throws -> MeasuredAnswer {
        let asOne = try renderer.measured(target: target, options: options)
        let names = Self.names(in: target)
        guard names.count > 1, asOne.missed || ExactAnswer.opensWithServedNotice(asOne.text, asked: target) else {
            return asOne
        }
        guard options.offset == 0 else {
            throw EngineError.offsetWithSeveralTargets(count: names.count)
        }
        let answers = try names.map { name in
            try (name: name, answer: renderer.measured(target: name, options: options))
        }
        let served = answers.filter { !$0.answer.missed }
        guard !served.isEmpty else { return asOne }
        let unserved = answers.filter(\.answer.missed).map { "\($0.name) was not served: pass it as its own target" }
        let text = (unserved + [DigestRenderer.joinedAnswers(served.map(\.answer.text))]).joined(separator: "\n")
        let sources = served.compactMap(\.answer.bytes?.source)
        let bytes = sources.isEmpty ? nil : MeasuredAnswer.Bytes(answer: text.utf8.count, source: sources.reduce(0, +))
        return MeasuredAnswer(text: text, bytes: bytes, parts: served.map { Self.part($0.name, answer: $0.answer) })
    }
}

public extension DigestSpacedTarget {
    /// The files a digest answer opens its parts on, by the header each part names its file in: a file digest's, or a type digest's.
    ///
    /// Read off one name's own answer where a string was split (``names(in:)``), for the file its part records: a member's body has no such header and so names none, and a module digest names its files under headings, which ``ExactAnswer/files(inDigestAnswer:)`` reads. The first header in each part counts and the rest of its lines are its body, whose lines never open a part.
    static func servedFiles(inAnswer text: String) -> [String] {
        var files: [String] = []
        var awaitingHeader = true
        var previousWasBlank = false
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let opensPart = raw.first == SourcePassthrough.partMarker && previousWasBlank
            previousWasBlank = raw.isEmpty
            awaitingHeader = awaitingHeader || opensPart
            guard awaitingHeader else { continue }
            let line = opensPart ? raw.dropFirst() : raw
            if let file = line.wholeMatch(of: SourcePassthrough.fileHeader)?.output.1 ?? line.wholeMatch(of: typeHeader)?.output.1 {
                if !files.contains(String(file)) {
                    files.append(String(file))
                }
                awaitingHeader = false
            }
        }
        return files
    }

    /// What the digest of `name` served, read off its own answer before it was joined to the others: the file it served in the name's place where it opens with the notice saying so, else the file its first header names, and the files it locates as a digest of `name` alone would record them.
    private static func part(_ name: String, answer: MeasuredAnswer) -> MeasuredAnswer.Part {
        let instead = ExactAnswer.opensWithServedNotice(answer.text, asked: name) ? ExactAnswer.servedFile(inDigestAnswer: answer.text) : nil
        return MeasuredAnswer.Part(
            target: name,
            file: instead ?? servedFiles(inAnswer: answer.text).first,
            servedInstead: instead != nil,
            source: answer.bytes?.source,
            located: ExactAnswer.files(inDigestAnswer: answer.text)
        )
    }

    /// A type digest's header, `<name> — <module> — <path>.swift:<first>-<last>` and its extension count where it has one, capturing the path.
    private static var typeHeader: Regex<(Substring, Substring)> {
        /^\S.* — \S+ — (\S+\.swift):\d+(?:-\d+)?(?: \(\+\d+ extensions?\))?$/
    }
}
