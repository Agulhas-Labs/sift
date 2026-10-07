//
// Copyright © Agulhas Labs
//

import Foundation

/// A grep pattern read with grep's own meaning, so that the lines a command would print can be worked out without running it — or `nil` wherever that meaning cannot be pinned down.
///
/// **Only what every grep a shell may run agrees on.** The `grep` in a command can be GNU grep, BSD grep, or another implementation behind a shell function, and they read some constructs differently: `\w` and `\S`, `\d`, a backslash inside brackets, a `^` or `$` in the middle of a pattern, a `$` before an alternation, an interval that does not close, a quantifier with nothing to repeat, a letter outside ASCII under `-i`, which some fold onto an ASCII letter, `[[:punct:]]`, which `ugrep` reads as Unicode punctuation and so without ``$+<=>^`|~``, and a pattern that can match the empty string, for which `ugrep` often prints only the lines holding a non-empty match where the system grep prints every line (`x*`, `x\{0\}`). Each of those is refused. The last is a deliberate superset: `ugrep` and the system grep print the same lines for some patterns that can match the empty string — `^`, `$`, `^$`, `x*$`, `^x*$`, and `x*` or `.*` under `-x` — and those are refused too, since telling them apart is not worth the risk of a wrong answer. What is read is the common core: literals, `.`, bracket expressions with ASCII ranges and the POSIX classes but `punct`, `^` opening a branch and `$` closing the pattern, grouping, alternation, `*`, `+`, `?` and intervals in each dialect's own spelling, `\s`, `\b`, `\<` and `\>` — and the flags `-F`, `-i`, `-w` and `-x`.
///
/// **A line is decided twice.** The locale a shell runs grep under decides what a character outside ASCII is — a letter or not, one character or several bytes — and nothing in a command says which, while real implementations answer differently for the same line. So a line holding one is matched once as characters, with every class as wide as Unicode makes it, and once as bytes, with every class ASCII as the C locale has it. Where the two readings disagree the locale decides the line, and it is reported undecided rather than guessed. A line of ASCII reads the same both ways.
///
/// Written as a matcher of its own rather than handed to a regular-expression engine because the semantics are grep's: word boundaries are grep's word characters on either side, classes are decided per reading, and only whether a line holds a match matters — never which match, so leftmost-longest and leftmost-first agree.
struct GrepPattern {
    private let root: Node
    private let options: Options

    /// An ASCII run every match holds, which a line lacking it cannot match in either reading — the search's cheap first pass.
    let requiredLiteral: [UInt8]?

    /// The most matcher steps one line may take before it is reported undecided rather than decided slowly.
    static let stepLimit = 100_000

    init?(_ pattern: String, options: Options) {
        let scalars = Array(pattern.unicodeScalars)
        guard !scalars.isEmpty, !scalars.contains("\n") else { return nil }
        let parsed: Node
        if options.dialect == .fixed {
            parsed = .sequence(scalars.map { .literal($0) })
        } else {
            var parser = Parser(scalars: scalars, extended: options.dialect == .extended)
            guard let node = parser.parse() else { return nil }
            parsed = node
        }
        // Whole-word matching is read as grep documents it only where every branch opens and closes on a word
        // character: elsewhere implementations differ in which matches they retry.
        if options.wholeWords, !parsed.branches.allSatisfy(\.opensAndClosesOnAWordLiteral) {
            return nil
        }
        // A case-folded class of one case is read differently across implementations.
        if options.ignoresCase, parsed.usesCaseClass {
            return nil
        }
        // Folded, a letter outside ASCII matches one inside it in some implementations and not in others — `ı` and
        // `I`, `İ` and `i`, `ſ` and `S`, the Kelvin sign and `k` — and a line of ASCII is read as bytes alone.
        if options.ignoresCase, scalars.contains(where: { !$0.isASCII && ($0.properties.isAlphabetic || $0.properties.changesWhenCaseMapped) }) {
            return nil
        }
        // `ugrep` often prints a line only for a non-empty match, and every other grep for any match at all. Some
        // anchored patterns agree (`^$`, `^x*$`); refusing every pattern that can match nothing is a deliberate superset.
        if parsed.matchesEmpty {
            return nil
        }
        root = parsed
        self.options = options
        requiredLiteral = parsed.requiredLiteral
    }

    /// Whether `line` holds a match — `nil` where the answer depends on the locale or the line took too long to decide.
    ///
    /// `line` is the line's bytes, without its newline; a line that is not UTF-8 is undecided, since neither reading is what a real grep does with it.
    func matches(_ line: some Collection<UInt8>) -> Bool? {
        let bytes = Array(line)
        let ascii = bytes.allSatisfy { $0 < 0x80 }
        if let literal = requiredLiteral, !(options.ignoresCase && !ascii), !Self.contains(bytes, literal, foldingCase: options.ignoresCase) {
            return false
        }
        let asBytes = Matcher(units: bytes.map(UInt32.init), reading: .bytes, options: options).matches(root)
        if ascii {
            return asBytes
        }
        guard let text = String(bytes: bytes, encoding: .utf8) else { return nil }
        let asCharacters = Matcher(units: text.unicodeScalars.map(\.value), reading: .characters, options: options).matches(root)
        guard let asBytes, let asCharacters, asBytes == asCharacters else { return nil }
        return asBytes
    }

    /// Whether `haystack` holds `needle`, folding ASCII case where asked.
    static func contains(_ haystack: [UInt8], _ needle: [UInt8], foldingCase: Bool) -> Bool {
        guard !needle.isEmpty else { return true }
        guard haystack.count >= needle.count else { return false }
        let fold: (UInt8) -> UInt8 = { foldingCase && $0 >= 0x41 && $0 <= 0x5A ? $0 + 0x20 : $0 }
        let wanted = needle.map(fold)
        for start in 0 ... haystack.count - needle.count where fold(haystack[start]) == wanted[0] {
            if (1 ..< wanted.count).allSatisfy({ fold(haystack[start + $0]) == wanted[$0] }) {
                return true
            }
        }
        return false
    }
}

extension GrepPattern {
    /// How the pattern is written.
    enum Dialect: Equatable, Sendable {
        /// A basic regular expression, grep's default (`-G`).
        case basic
        /// An extended regular expression (`-E`).
        case extended
        /// A fixed string (`-F`).
        case fixed
    }

    /// The flags that change which lines match.
    struct Options: Equatable, Sendable {
        var dialect: Dialect = .basic
        var ignoresCase = false
        var wholeWords = false
        var wholeLine = false
    }

    /// One piece of a parsed pattern.
    indirect enum Node: Equatable {
        case literal(Unicode.Scalar)
        case any
        case set(BracketSet)
        case space
        case sequence([Node])
        case alternation([Node])
        case repetition(Node, min: Int, max: Int?)
        case lineStart, lineEnd
        case wordBoundary, wordStart, wordEnd

        /// The top-level branches of the pattern.
        var branches: [Node] {
            if case let .alternation(branches) = self {
                return branches
            }
            return [self]
        }

        /// Whether this branch's first and last pieces are literal word characters.
        var opensAndClosesOnAWordLiteral: Bool {
            let pieces: [Node] = if case let .sequence(pieces) = self {
                pieces
            } else {
                [self]
            }
            guard case let .literal(first)? = pieces.first, case let .literal(last)? = pieces.last else { return false }
            return Self.isASCIIWord(first) && Self.isASCIIWord(last)
        }

        /// Whether this piece can match the empty string.
        var matchesEmpty: Bool {
            switch self {
            case .literal, .any, .set, .space:
                false
            case let .sequence(nodes):
                nodes.allSatisfy(\.matchesEmpty)
            case let .alternation(nodes):
                nodes.contains(where: \.matchesEmpty)
            case let .repetition(node, min, _):
                min == 0 || node.matchesEmpty
            case .lineStart, .lineEnd, .wordBoundary, .wordStart, .wordEnd:
                true
            }
        }

        /// Whether a class of one case appears anywhere in the pattern.
        var usesCaseClass: Bool {
            switch self {
            case let .set(set):
                set.classes.contains(.upper) || set.classes.contains(.lower)
            case let .sequence(nodes), let .alternation(nodes):
                nodes.contains(where: \.usesCaseClass)
            case let .repetition(node, _, _):
                node.usesCaseClass
            default:
                false
            }
        }

        /// The longest run of ASCII literals every match of this pattern holds, or `nil` where none is certain.
        var requiredLiteral: [UInt8]? {
            guard case let .sequence(pieces) = self else {
                if case let .literal(scalar) = self, scalar.isASCII {
                    return [UInt8(scalar.value)]
                }
                return nil
            }
            var longest: [UInt8] = []
            var run: [UInt8] = []
            for piece in pieces {
                if case let .literal(scalar) = piece, scalar.isASCII {
                    run.append(UInt8(scalar.value))
                } else {
                    run = []
                }
                if run.count > longest.count {
                    longest = run
                }
            }
            return longest.isEmpty ? nil : longest
        }

        static func isASCIIWord(_ scalar: Unicode.Scalar) -> Bool {
            scalar.isASCII && (scalar.properties.isAlphabetic || ("0" ... "9").contains(scalar) || scalar == "_")
        }
    }

    /// A bracket expression: ASCII members, ASCII ranges and POSIX classes, possibly negated.
    struct BracketSet: Equatable {
        var negated = false
        var members: [Unicode.Scalar] = []
        var ranges: [ClosedRange<UInt32>] = []
        var classes: [CharacterClass] = []
    }

    /// The POSIX classes a bracket expression may name.
    enum CharacterClass: String, Equatable, CaseIterable {
        case alpha, digit, alnum, upper, lower, space, blank, xdigit
    }

    /// How a line's text is taken: as Unicode characters, or as bytes with only ASCII in any class.
    enum Reading {
        case characters, bytes
    }
}

private extension GrepPattern {
    /// Recursive descent over one pattern in one dialect, refusing every construct outside the common core.
    struct Parser {
        let scalars: [Unicode.Scalar]
        let extended: Bool
        var index = 0

        init(scalars: [Unicode.Scalar], extended: Bool) {
            self.scalars = scalars
            self.extended = extended
        }

        mutating func parse() -> Node? {
            guard let node = alternation(depth: 0), index == scalars.count else { return nil }
            return node
        }

        private func peek(_ offset: Int = 0) -> Unicode.Scalar? {
            index + offset < scalars.count ? scalars[index + offset] : nil
        }

        private var atAlternation: Bool {
            extended ? peek() == "|" : (peek() == "\\" && peek(1) == "|")
        }

        private var atGroupClose: Bool {
            extended ? peek() == ")" : (peek() == "\\" && peek(1) == ")")
        }

        private mutating func alternation(depth: Int) -> Node? {
            var branches: [Node] = []
            while true {
                guard let branch = branch(depth: depth) else { return nil }
                branches.append(branch)
                guard atAlternation else { break }
                index += extended ? 1 : 2
            }
            return branches.count == 1 ? branches[0] : .alternation(branches)
        }

        private mutating func branch(depth: Int) -> Node? {
            var pieces: [Node] = []
            if depth == 0, peek() == "^" {
                pieces.append(.lineStart)
                index += 1
            }
            while index < scalars.count, !atAlternation, !atGroupClose {
                if depth == 0, peek() == "$", index == scalars.count - 1 {
                    pieces.append(.lineEnd)
                    index += 1
                    break
                }
                guard let atom = atom(depth: depth) else { return nil }
                guard let piece = quantified(atom) else { return nil }
                pieces.append(piece)
            }
            // An empty branch or group is read differently across implementations.
            guard pieces.contains(where: { $0 != .lineStart && $0 != .lineEnd }) else { return nil }
            return pieces.count == 1 ? pieces[0] : .sequence(pieces)
        }

        private mutating func atom(depth: Int) -> Node? {
            guard let scalar = peek() else { return nil }
            // An operator with nothing before it to act on, and a brace no interval opened, are each read
            // differently across implementations.
            if extended, ["+", "?", "{", "}", "|", ")"].contains(scalar) {
                return nil
            }
            switch scalar {
            case "^", "$", "*":
                return nil
            case ".":
                index += 1
                return .any
            case "[":
                index += 1
                return bracket().map(Node.set)
            case "(" where extended:
                index += 1
                return group(depth: depth)
            case "\\":
                return escape(depth: depth)
            default:
                index += 1
                return .literal(scalar)
            }
        }

        private mutating func group(depth: Int) -> Node? {
            guard let inner = alternation(depth: depth + 1), atGroupClose else { return nil }
            index += extended ? 1 : 2
            return inner
        }

        private mutating func escape(depth: Int) -> Node? {
            guard let next = peek(1) else { return nil }
            index += 2
            if extended, ["+", "?", "(", ")", "{", "}", "|"].contains(next) {
                return .literal(next)
            }
            return switch next {
            case "(" where !extended: group(depth: depth)
            case "s": .space
            case "b": .wordBoundary
            case "<": .wordStart
            case ">": .wordEnd
            case ".", "*", "[", "]", "^", "$", "\\", "/": .literal(next)
            default: nil
            }
        }

        private mutating func quantified(_ atom: Node) -> Node? {
            guard let found = quantifier() else { return atom }
            guard let bounds = found else { return nil }
            // A quantifier on an assertion, or on another quantifier, is read differently across implementations.
            guard ![.lineStart, .lineEnd, .wordBoundary, .wordStart, .wordEnd].contains(atom), quantifier() == nil else {
                return nil
            }
            return .repetition(atom, min: bounds.0, max: bounds.1)
        }

        /// The quantifier at the cursor: `nil` where there is none, `.some(nil)` where it is malformed.
        private mutating func quantifier() -> (Int, Int?)?? {
            switch peek() {
            case "*":
                index += 1
                return .some((0, nil))
            case "+" where extended:
                index += 1
                return .some((1, nil))
            case "?" where extended:
                index += 1
                return .some((0, 1))
            case "{" where extended:
                index += 1
                return .some(interval(closing: ["}"]))
            case "\\" where !extended:
                switch peek(1) {
                case "+":
                    index += 2
                    return .some((1, nil))
                case "?":
                    index += 2
                    return .some((0, 1))
                case "{":
                    index += 2
                    return .some(interval(closing: ["\\", "}"]))
                default:
                    return nil
                }
            default:
                return nil
            }
        }

        /// `m`, `m,` or `m,n` and its closing, each at most 255 and in order.
        private mutating func interval(closing: [Unicode.Scalar]) -> (Int, Int?)? {
            func number() -> Int? {
                var digits = ""
                while let scalar = peek(), ("0" ... "9").contains(scalar) {
                    digits.unicodeScalars.append(scalar)
                    index += 1
                }
                return Int(digits)
            }
            guard let min = number(), min <= 255 else { return nil }
            var max: Int? = min
            if peek() == "," {
                index += 1
                max = number()
            }
            guard closing.indices.allSatisfy({ peek($0) == closing[$0] }) else { return nil }
            index += closing.count
            if let max, max < min || max > 255 {
                return nil
            }
            return (min, max)
        }

        /// A bracket expression, the cursor just past its `[`.
        private mutating func bracket() -> BracketSet? {
            var set = BracketSet()
            if peek() == "^" {
                set.negated = true
                index += 1
            }
            var first = true
            while let scalar = peek() {
                if scalar == "]", !first {
                    index += 1
                    return set
                }
                first = false
                if scalar == "[" {
                    guard peek(1) == ":" else {
                        // `[=` and `[.` name collation, which differs by locale; a lone `[` is itself.
                        guard peek(1) != "=", peek(1) != "." else { return nil }
                        set.members.append(scalar)
                        index += 1
                        continue
                    }
                    guard let named = characterClass() else { return nil }
                    set.classes.append(named)
                    continue
                }
                // A backslash in brackets is a literal to POSIX and an escape to others; anything outside ASCII
                // is one member to a character reading and several bytes to a byte reading.
                guard scalar != "\\", scalar.isASCII else { return nil }
                if peek(1) == "-", let upper = peek(2), upper != "]" {
                    guard Self.isRange(scalar, upper) else { return nil }
                    set.ranges.append(scalar.value ... upper.value)
                    index += 3
                    continue
                }
                set.members.append(scalar)
                index += 1
            }
            return nil
        }

        private mutating func characterClass() -> CharacterClass? {
            let start = index + 2
            var end = start
            while end + 1 < scalars.count, !(scalars[end] == ":" && scalars[end + 1] == "]") {
                end += 1
            }
            guard end + 1 < scalars.count else { return nil }
            let name = String(String.UnicodeScalarView(scalars[start ..< end]))
            guard let named = CharacterClass(rawValue: name) else { return nil }
            index = end + 2
            return named
        }

        /// A range every locale collates alike: both ends digits, both lowercase or both uppercase ASCII, in order.
        private static func isRange(_ lower: Unicode.Scalar, _ upper: Unicode.Scalar) -> Bool {
            guard lower.value <= upper.value else { return false }
            let spans: [ClosedRange<Unicode.Scalar>] = ["0" ... "9", "a" ... "z", "A" ... "Z"]
            return spans.contains { $0.contains(lower) && $0.contains(upper) }
        }
    }

    /// Backtracking over one line in one reading, bounded in steps.
    final class Matcher {
        private let units: [UInt32]
        private let reading: Reading
        private let options: Options
        private var steps = 0
        private var exhausted = false
        /// Set once a POSIX class is asked of a scalar outside ASCII, under the `.characters` reading — a locale's own class membership for one is not what any Unicode property table says, ``ʔ`` (U+0295) matching `[[:lower:]]` under a real `grep` included, so the answer is never trusted, whichever way it falls.
        private var undecidedClass = false

        init(units: [UInt32], reading: Reading, options: Options) {
            self.units = units
            self.reading = reading
            self.options = options
        }

        /// Whether the line holds a match, or `nil` past the step limit or once a POSIX class was asked of a scalar outside ASCII.
        func matches(_ root: Node) -> Bool? {
            let node = lowered(root)
            let starts = options.wholeLine ? [0] : Array(0 ... units.count)
            for start in starts {
                if options.wholeWords, start > 0 {
                    let precededByWord = isWord(units[start - 1])
                    if undecidedClass {
                        return nil
                    }
                    if precededByWord {
                        continue
                    }
                }
                let found = match(node, at: start) { end in
                    if self.options.wholeLine {
                        return end == self.units.count
                    }
                    if self.options.wholeWords {
                        return end == self.units.count || !self.isWord(self.units[end])
                    }
                    return true
                }
                if exhausted || undecidedClass {
                    return nil
                }
                if found {
                    return true
                }
            }
            return false
        }

        /// The node with every literal outside ASCII spelled as the units this reading sees: one scalar, or its bytes.
        private func lowered(_ node: Node) -> Node {
            switch node {
            case let .literal(scalar) where !scalar.isASCII && reading == .bytes:
                .sequence(String(scalar).utf8.map { .literal(Unicode.Scalar($0)) })
            case let .sequence(nodes):
                .sequence(nodes.map(lowered))
            case let .alternation(nodes):
                .alternation(nodes.map(lowered))
            case let .repetition(inner, min, max):
                .repetition(lowered(inner), min: min, max: max)
            default:
                node
            }
        }

        private func match(_ node: Node, at position: Int, _ next: (Int) -> Bool) -> Bool {
            steps += 1
            guard steps <= GrepPattern.stepLimit else {
                exhausted = true
                return false
            }
            switch node {
            case let .literal(scalar):
                guard position < units.count, equal(units[position], scalar.value) else { return false }
                return next(position + 1)
            case .any:
                return position < units.count && next(position + 1)
            case let .set(set):
                guard position < units.count, contains(set, units[position]) else { return false }
                return next(position + 1)
            case .space:
                guard position < units.count, isSpace(units[position]) else { return false }
                return next(position + 1)
            case let .sequence(nodes):
                return sequence(nodes[...], at: position, next)
            case let .alternation(nodes):
                return nodes.contains { !exhausted && match($0, at: position, next) }
            case let .repetition(inner, min, max):
                return repeated(inner, min: min, max: max, count: 0, at: position, next)
            case .lineStart:
                return position == 0 && next(position)
            case .lineEnd:
                return position == units.count && next(position)
            case .wordBoundary:
                return wordBefore(position) != wordAfter(position) && next(position)
            case .wordStart:
                return !wordBefore(position) && wordAfter(position) && next(position)
            case .wordEnd:
                return wordBefore(position) && !wordAfter(position) && next(position)
            }
        }

        private func sequence(_ nodes: ArraySlice<Node>, at position: Int, _ next: (Int) -> Bool) -> Bool {
            guard let first = nodes.first else { return next(position) }
            return match(first, at: position) { self.sequence(nodes.dropFirst(), at: $0, next) }
        }

        /// Greedy, backtracking, and never looping on a body that matched nothing.
        private func repeated(_ inner: Node, min: Int, max: Int?, count: Int, at position: Int, _ next: (Int) -> Bool) -> Bool {
            if max.map({ count < $0 }) ?? true {
                let more = match(inner, at: position) { end in
                    guard end != position || count < min else { return false }
                    return self.repeated(inner, min: min, max: max, count: count + 1, at: end, next)
                }
                if more {
                    return true
                }
            }
            return count >= min && !exhausted && next(position)
        }

        private func wordBefore(_ position: Int) -> Bool {
            position > 0 && isWord(units[position - 1])
        }

        private func wordAfter(_ position: Int) -> Bool {
            position < units.count && isWord(units[position])
        }

        private func equal(_ unit: UInt32, _ wanted: UInt32) -> Bool {
            if unit == wanted {
                return true
            }
            guard options.ignoresCase else { return false }
            if reading == .bytes || unit < 0x80 && wanted < 0x80 {
                return unit < 0x80 && wanted < 0x80 && Self.asciiLower(unit) == Self.asciiLower(wanted)
            }
            guard let left = Unicode.Scalar(unit), let right = Unicode.Scalar(wanted) else { return false }
            return left.properties.lowercaseMapping == right.properties.lowercaseMapping
        }

        private func contains(_ set: BracketSet, _ unit: UInt32) -> Bool {
            var candidates = [unit]
            if options.ignoresCase {
                if unit < 0x80 {
                    candidates = [Self.asciiLower(unit), Self.asciiUpper(unit)]
                } else if reading == .characters, let scalar = Unicode.Scalar(unit) {
                    candidates += [scalar.properties.lowercaseMapping, scalar.properties.uppercaseMapping]
                        .compactMap { $0.unicodeScalars.count == 1 ? $0.unicodeScalars.first?.value : nil }
                }
            }
            let inside = candidates.contains { candidate in
                set.members.contains { $0.value == candidate }
                    || set.ranges.contains { $0.contains(candidate) }
                    || set.classes.contains { isMember(candidate, of: $0) }
            }
            return inside != set.negated
        }

        private func isMember(_ unit: UInt32, of named: CharacterClass) -> Bool {
            if unit < 0x80 {
                return Self.asciiMember(unit, of: named)
            }
            // Outside ASCII, the byte reading holds nothing: no POSIX class matches a raw byte under the C locale,
            // which is exact. The character reading has no such table — a real locale's own class membership does
            // not track Unicode's property tables (`ʔ`, U+0295, reads as `[[:lower:]]` under a real `grep` though
            // neither the alphabetic nor the lowercase property says so) — so it is never decided here.
            guard reading == .characters else { return false }
            undecidedClass = true
            return false
        }

        private func isWord(_ unit: UInt32) -> Bool {
            isMember(unit, of: .alnum) || unit == 0x5F || (reading == .characters && unit >= 0x80
                && Unicode.Scalar(unit)?.properties.generalCategory == .connectorPunctuation)
        }

        private func isSpace(_ unit: UInt32) -> Bool {
            isMember(unit, of: .space)
        }

        private static func asciiMember(_ unit: UInt32, of named: CharacterClass) -> Bool {
            let upper = (0x41 ... 0x5A).contains(unit)
            let lower = (0x61 ... 0x7A).contains(unit)
            let digit = (0x30 ... 0x39).contains(unit)
            return switch named {
            case .alpha: upper || lower
            case .digit: digit
            case .alnum: upper || lower || digit
            case .upper: upper
            case .lower: lower
            case .space: unit == 0x20 || (0x09 ... 0x0D).contains(unit)
            case .blank: unit == 0x20 || unit == 0x09
            case .xdigit: digit || (0x41 ... 0x46).contains(unit) || (0x61 ... 0x66).contains(unit)
            }
        }

        private static func asciiLower(_ unit: UInt32) -> UInt32 {
            (0x41 ... 0x5A).contains(unit) ? unit + 0x20 : unit
        }

        private static func asciiUpper(_ unit: UInt32) -> UInt32 {
            (0x61 ... 0x7A).contains(unit) ? unit - 0x20 : unit
        }
    }
}
