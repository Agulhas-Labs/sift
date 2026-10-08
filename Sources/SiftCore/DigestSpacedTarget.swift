//
// Copyright © Agulhas Labs
//

import Foundation

/// One digest target as `digest` takes it: the whole string first, exactly as written, so a path with a space in it still resolves; and only where that does not resolve as itself, the names it is made of.
///
/// A string that is one path with a space inside it (``DigestSpacedTarget/isOnePath(_:)``) is never split: its answer is the whole string's own.
///
/// A string with whitespace in it that names nothing, or only a same-named file elsewhere, is almost always several targets sent as one. Where every name resolves they are served as the targets list serves them; where only some do, those are served under one line for each that is not, so the answer never reads as complete when it is not. Where none does the answer is the whole string's own.
///
/// An offset pages one answer, so a string that would be split is refused one, as the targets list is: the truncation line of a split answer names each part's own cursor, and a cursor given back with the whole string would otherwise find nothing.
public struct DigestSpacedTarget {
    let renderer: DigestRenderer

    /// The names `target` is made of where it is split: its whitespace-separated words, or `target` alone where it is one path with whitespace inside it (``isOnePath(_:)``).
    public static func names(in target: String) -> [String] {
        isOnePath(target) ? [target] : target.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// Whether the whitespace in `target` sits inside one path rather than between names, so that the string is never split: a missed or misplaced path with a space in it is one path wrongly spelled, and its words answered on their own would serve files it never named.
    ///
    /// It is decided on the first word that holds a `/`: the string is one path where that word is no whole file of its own and no word before it is one (`Sources/My App/ContentView.swift`, `My App/Main View.swift`, a directory holding the space). A path after a bare name whose `/` word is a whole file (`Gizmo Sources/App/Orchard.swift`), a whole file before another name, and a string with no `/` at all (`Gizmo Depot.swift`, a type and a file as readily as one file name) are several names: the shape the split exists for.
    ///
    /// The one reading for every site that asks: the split here, the hook crediting what each name served, and the MCP face's note on a spaced miss.
    public static func isOnePath(_ target: String) -> Bool {
        let words = target.split(whereSeparator: \.isWhitespace)
        guard words.count > 1, let pathWord = words.firstIndex(where: { $0.contains("/") }) else { return false }
        return !namesWholeFile(words[pathWord]) && !words[..<pathWord].contains(where: namesWholeFile)
    }

    /// Whether a string the split reads as several names could as well be one file name with a space in it: it holds no `/`, and, its line range aside, it ends in `.swift` or `.md` (`Gizmo Depot.swift`, `My File.swift:12-40`).
    private static func wasTriedAsOneFile(_ target: String) -> Bool {
        let path = DigestLineRange.parse(target)?.path ?? target
        return !target.contains("/") && (path.hasSuffix(".swift") || path.hasSuffix(".md"))
    }

    /// Whether `word` is a whole file's target by itself: a Swift or Markdown path, or a line range of one.
    private static func namesWholeFile(_ word: Substring) -> Bool {
        word.hasSuffix(".swift") || word.hasSuffix(".md") || DigestLineRange.parse(String(word)) != nil
    }

    /// The answer for `target`, its names each answered on their own where the whole string does not resolve as itself.
    ///
    /// The source the answer stands in for is the sum of the source its parts stand in for, over the parts that weighed one: a part that weighs none (a member's body) adds nothing, which can only understate a saving, never overstate it.
    ///
    /// A split string with no `/` that ends in a file name (``wasTriedAsOneFile(_:)``) opens with a line saying the whole string named no file, so a split reads apart from a mistyped file name with a space in it.
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
        let tried = asOne.missed && Self.wasTriedAsOneFile(target)
            ? ["\(target) was also tried as one file name and matched nothing: its words are answered as separate targets"]
            : []
        let text = (tried + unserved + [DigestRenderer.joinedAnswers(served.map(\.answer.text))]).joined(separator: "\n")
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
