//
// Copyright © Agulhas Labs
//

import Foundation

/// Matches a query against a literal's segments with each interpolation between them read as some of the query's text, or none.
///
/// The wording a program prints is often assembled — `"truncated: \(remaining) more \(unit)"` prints "more member lines" — so no single segment holds it. Here the query is read as a suffix of one segment, then a wildcard for each interpolation crossed, with every segment between them in full, then a prefix of the segment after the last; the query may also end inside a wildcard. A wildcard is a run of the query, possibly empty since an interpolation can print nothing; a non-empty one starts and ends on a non-space; each ends on a word boundary of the query, or between a digit and a letter so `\(n)ms` matches "42ms", and starts on one unless it continues a word the literal text before it began, so `key\(s)` matches "key" and "keys" while `\(verb)ing` is matched only by a query that does not cut through that word. Some piece of literal text matched must hold a word of at least ``minimumWordLength`` letters or digits, so interpolations, spacing and short words alone never match. Case follows ``SmartCaseQuery``: any uppercase letter in the query makes it case-sensitive.
///
/// A match is listed only when its literal text holds part of at least ``listedWordCount`` words of the query, a piece holding part of a word only on ``minimumWordLength`` of its characters or the whole of a shorter word, so a letter glued to an interpolation is not part of the query's word: one shared word is what most interpolated literals have with any query, so such a match is only counted. The search prefers an alignment that lists.
///
/// Every way of splitting the query among the wildcards is tried, which is exponential in the interpolations crossed; a state already found to fail is remembered, which keeps a long pasted query against a literal of many interpolations polynomial.
struct InterpolationWildcard {
    private let query: Query
    private let segments: [[Character]]
    /// States already explored without a match that lists.
    private var failed: Set<State> = []
    /// The first match found that holds too few query words to list, returned when no alignment lists.
    private var counted: Match?

    /// How `query` matched with at least one interpolation crossed, or `nil` when it matches no way around them.
    static func match(of query: Query, in segments: [String]) -> Match? {
        guard segments.count > 1, !query.characters.isEmpty else {
            return nil
        }
        var matcher = InterpolationWildcard(
            query: query,
            segments: segments.map { Array(query.folds ? $0.lowercased() : $0) }
        )
        return matcher.match()
    }

    /// Tries each segment that has an interpolation after it as the one the query starts in, with every suffix of it the query begins with, longest first, so the literal text matched and the window centred on it are as long as the literal allows.
    private mutating func match() -> Match? {
        for start in segments.indices.dropLast() {
            let segment = segments[start]
            for length in (0 ... min(segment.count, query.characters.count)).reversed() where segment.suffix(length).elementsEqual(query.characters.prefix(length)) {
                if let found = throughInterpolation(after: start, from: length, matched: Matched.none.adding(0 ..< length, of: query, segment: start)) {
                    return found
                }
            }
        }
        return counted
    }

    /// Reads the wildcard for the interpolation after segment `index` from query offset `position`, then what follows it.
    private mutating func throughInterpolation(after index: Int, from position: Int, matched: Matched) -> Match? {
        let characters = query.characters
        let state = State(index: index, position: position, holdsAWord: matched.holdsAWord, words: matched.words)
        guard position < characters.count, !failed.contains(state) else {
            return nil
        }
        let next = segments[index + 1]
        for end in position ... characters.count where isWildcardEnd(end) && (end == position || !characters[position].isWhitespace && !characters[end - 1].isWhitespace) {
            guard end < characters.count else {
                if let found = settled(matched) {
                    return found
                }
                break
            }
            let rest = characters[end...]
            if rest.count <= next.count, next.prefix(rest.count).elementsEqual(rest), let found = settled(matched.adding(end ..< characters.count, of: query, segment: index + 1)) {
                return found
            }
            if index + 2 < segments.count, rest.count > next.count, rest.prefix(next.count).elementsEqual(next),
               let found = throughInterpolation(after: index + 1, from: end + next.count, matched: matched.adding(end ..< end + next.count, of: query, segment: index + 1))
            {
                return found
            }
        }
        failed.insert(state)
        return nil
    }

    /// A complete match that lists, or `nil` — keeping the first one that holds a word but too few query words to list, in case no alignment lists.
    private mutating func settled(_ matched: Matched) -> Match? {
        guard matched.holdsAWord else {
            return nil
        }
        let isListed = matched.words >= Self.listedWordCount
        let found = Match(
            anchor: matched.longest.trimmingCharacters(in: .whitespaces),
            segment: matched.longestSegment,
            window: nil,
            isListed: isListed,
            word: isListed ? nil : matched.firstWord.map { query.wordTexts[$0] }
        )
        if found.isListed {
            return found
        }
        counted = counted ?? found
        return nil
    }

    /// Whether offset `position` in the query falls between two words rather than inside one, the query's ends included.
    private func isWordBoundary(_ position: Int) -> Bool {
        let characters = query.characters
        return position == 0 || position == characters.count || !(Self.isWordCharacter(characters[position - 1]) && Self.isWordCharacter(characters[position]))
    }

    /// Whether a wildcard may end at offset `position` in the query: on a word boundary, or between a digit and a letter, where a number printed against its unit ends.
    private func isWildcardEnd(_ position: Int) -> Bool {
        let characters = query.characters
        return isWordBoundary(position) || characters[position - 1].isNumber && characters[position].isLetter
    }

    fileprivate static var minimumWordLength: Int {
        3
    }

    /// Query words the literal text must hold part of for a match to be listed rather than counted.
    fileprivate static var listedWordCount: Int {
        2
    }

    fileprivate static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }
}

extension InterpolationWildcard {
    /// A query prepared once for every literal it is matched against: its characters, lowercased when it matches case-insensitively under ``SmartCaseQuery``, and the word each character falls in.
    struct Query {
        let characters: [Character]
        let folds: Bool
        /// For each character, the index of the run of letters or digits holding it, `nil` between words.
        let words: [Int?]
        /// Each word's text, in query order, as ``characters`` spells it.
        let wordTexts: [String]

        init(_ text: String) {
            folds = !SmartCaseQuery.isCaseSensitive(text)
            characters = Array(folds ? text.lowercased() : text)
            var words: [Int?] = []
            var count = 0
            for character in characters {
                guard InterpolationWildcard.isWordCharacter(character) else {
                    words.append(nil)
                    continue
                }
                if let word = words.last.flatMap(\.self) {
                    words.append(word)
                } else {
                    words.append(count)
                    count += 1
                }
            }
            self.words = words
            var texts: [String] = []
            for (character, word) in zip(characters, words) {
                guard let word else { continue }
                if word == texts.count {
                    texts.append("")
                }
                texts[word].append(character)
            }
            wordTexts = texts
        }
    }

    /// How a query matched a literal around its interpolations.
    struct Match: Equatable {
        /// The longest piece of literal text matched, as the literal prints it, which a display window centres on since the query itself is not in the literal's text; lowercased for a case-insensitive query, which the window's own smart-case search still finds.
        let anchor: String
        /// The index of the segment ``anchor`` came from.
        let segment: Int
        /// The characters of the literal's written text the display window centres on, found within ``segment`` (``SwiftLiteralLexer/Literal``); `nil` when that segment spells none of ``anchor``, and the literal shows from its start.
        let window: Range<Int>?
        /// Whether the site is listed: the literal text matched holds part of enough query words, or it matched on a word rare enough to list when nothing else lists (``listed()``); otherwise it is only counted.
        let isListed: Bool
        /// The one query word the literal text matched holds part of, `nil` for a match on two or more; the count of unlisted matches is broken down by it.
        let word: String?

        /// This match listed although it holds one query word only, because that word is rare in the tree and nothing else lists.
        func listed() -> Match {
            Match(anchor: anchor, segment: segment, window: window, isListed: true, word: word)
        }

        /// This match with its display window at `window` of the literal's written text.
        func located(at window: Range<Int>?) -> Match {
            Match(anchor: anchor, segment: segment, window: window, isListed: isListed, word: word)
        }
    }
}

private extension InterpolationWildcard {
    /// A point in the search: the wildcard after segment `index` starting at query offset `position`, with what the literal text matched so far holds.
    struct State: Hashable {
        let index: Int
        let position: Int
        let holdsAWord: Bool
        let words: Int
    }

    /// The literal text matched so far, reduced to what the answer needs: whether it holds a word, how many query words it holds part of (enough to list at most) and the first of them, and its longest piece with the segment it came from.
    struct Matched {
        static let none = Matched(holdsAWord: false, words: 0, firstWord: nil, longest: "", longestSegment: 0)

        let holdsAWord: Bool
        let words: Int
        let firstWord: Int?
        let longest: String
        let longestSegment: Int

        /// Adds the literal text at `range` of the query; two pieces share a word only where a wildcard between them ends between a digit and a letter, and each piece is weighed on its own.
        func adding(_ range: Range<Int>, of query: Query, segment: Int) -> Matched {
            let piece = String(query.characters[range])
            let holdsOne = piece.split { !InterpolationWildcard.isWordCharacter($0) }.contains { $0.count >= InterpolationWildcard.minimumWordLength }
            var held: [Int: Int] = [:]
            for word in query.words[range].compactMap(\.self) {
                held[word, default: 0] += 1
            }
            let touched = Set(held.filter { $0.value >= min(InterpolationWildcard.minimumWordLength, query.wordTexts[$0.key].count) }.keys)
            let isLonger = piece.count > longest.count
            return Matched(
                holdsAWord: holdsAWord || holdsOne,
                words: min(words + touched.count, InterpolationWildcard.listedWordCount),
                firstWord: firstWord ?? touched.min(),
                longest: isLonger ? piece : longest,
                longestSegment: isLonger ? segment : longestSegment
            )
        }
    }
}
