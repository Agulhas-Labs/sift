//
// Copyright © Agulhas Labs
//

public extension StructuralQuery {
    /// How a `name:` value is matched against a declaration's name: one case-insensitive substring, any of several, or a regular expression.
    ///
    /// The two pattern forms are the ones callers write first when they want several names at once — `name:open|close` and `name:/open|close/` — and refusing them sent every such call back to grep. Both stay case-insensitive and unanchored, like the plain substring they generalise, so a word typed in lowercase still finds a capitalized declaration.
    ///
    /// `@unchecked` for the regex alone: `Regex` is not declared `Sendable`, but a compiled one is never mutated after parsing, and ``compiled(_:)`` builds its matcher program before the query is shared, so files scanned in parallel only read it.
    enum NamePattern: @unchecked Sendable {
        case substring(String)
        case anyOf([String])
        case regex(Regex<AnyRegexOutput>)

        /// Reads a `name:` value into the form it spells; throws when a `/…/` value does not compile.
        ///
        /// A value made only of operator characters is an operator's name (`||`, `|=`) and stays a literal substring, as it did before either pattern form existed.
        init(_ value: String, field: String = "name") throws {
            if let pattern = Self.regexBody(value) {
                guard !Self.repeatsAGroup(pattern) else {
                    throw EngineError.malformedQuery("\"\(field):\(value)\" is not read as a regex — a repeated group can take unbounded time; write the alternatives out or repeat a character class instead")
                }
                self = try .regex(Self.compiled(pattern))
            } else if value.contains("|"), !Self.isOperatorName(value) {
                self = .anyOf(value.split(separator: "|").map(String.init))
            } else {
                self = .substring(value)
            }
        }

        /// Whether `name` is matched by this pattern.
        func matches(_ name: String) -> Bool {
            switch self {
            case let .substring(value): name.range(of: value, options: .caseInsensitive) != nil
            case let .anyOf(values): values.contains { name.range(of: $0, options: .caseInsensitive) != nil }
            case let .regex(regex): name.contains(regex) || Self.baseName(name).contains(regex)
            }
        }

        /// Whether `text`, a file path or a signature rather than a declaration name, holds this pattern; no base-name reading of an argument list.
        func found(in text: String) -> Bool {
            switch self {
            case let .regex(regex): text.contains(regex)
            default: matches(text)
            }
        }

        /// Whether this pattern matches all of `name` rather than part of it: an alternative equal to the name, or a regex matching it from start to end, either without the argument list as ``matches(_:)`` allows.
        ///
        /// A plain substring never says, so a single bare word keeps its path-then-line order; only the pattern forms, where short alternatives turn up inside many longer names, put whole matches first.
        func matchesWhole(_ name: String) -> Bool {
            switch self {
            case .substring: false
            case let .anyOf(values): values.contains { Self.baseName(name).caseInsensitiveCompare($0) == .orderedSame }
            case let .regex(regex): name.wholeMatch(of: regex) != nil || Self.baseName(name).wholeMatch(of: regex) != nil
            }
        }

        /// A function's, initializer's or subscript's name without its argument list, so a regex's `$` can end at `finish` as well as after `finish()`.
        private static func baseName(_ name: String) -> Substring {
            name.prefix { $0 != "(" }
        }

        /// How the echo line says a pattern was read, or `nil` for a plain substring, whose echo needs no gloss.
        var reading: String? {
            switch self {
            case .substring: nil
            case let .anyOf(values): "any of \(values.joined(separator: ", "))"
            case .regex: "a case-insensitive regex"
            }
        }

        /// The pattern inside a `/…/` value, a leading `(?i)` dropped since every name pattern ignores case; `nil` when the value is not written that way.
        ///
        /// A body made of operator characters (`/.*/`, `/.+/`) is still a regex: an operator name never starts and ends with `/`.
        static func regexBody(_ value: String) -> String? {
            guard value.count > 2, value.hasPrefix("/"), value.hasSuffix("/") else { return nil }
            let body = value.dropFirst().dropLast()
            return String(body.hasPrefix("(?i)") ? body.dropFirst(4) : body)
        }

        /// Whether `pattern` repeats a group — a `)` straight before `*`, `+` or `{` — which backtracks without a time limit.
        ///
        /// A `)` escaped as `\)` or inside a character class closes no group, and a group followed by `?` is at most optional.
        static func repeatsAGroup(_ pattern: String) -> Bool {
            var escaped = false
            var inClass = false
            var previousClosesGroup = false
            for character in pattern {
                if previousClosesGroup, "*+{".contains(character) {
                    return true
                }
                previousClosesGroup = false
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if inClass {
                    inClass = character != "]"
                } else if character == "[" {
                    inClass = true
                } else if character == ")" {
                    previousClosesGroup = true
                }
            }
            return false
        }

        /// Compiles `pattern` case-insensitively, throwing the regex engine's own reason when it does not compile.
        ///
        /// Matched once here, against an empty string, so the program `Regex` builds on first use exists before files scanned in parallel share it.
        static func compiled(_ pattern: String) throws -> Regex<AnyRegexOutput> {
            let regex = try Regex(pattern).ignoresCase()
            _ = "".contains(regex)
            return regex
        }

        /// The literal words an uncompilable pattern plainly spells — its `|` alternatives once grouping parentheses are dropped — or `nil` when any alternative is more than a word.
        ///
        /// Only grouping is read away: a character class such as `[Oo]pen` does not plainly spell one word, so a pattern holding one gets no fallback rather than a guessed one.
        static func literalAlternatives(_ pattern: String) -> [String]? {
            let words = pattern.replacingOccurrences(of: "(", with: "").replacingOccurrences(of: ")", with: "").split(separator: "|").map(String.init)
            guard !words.isEmpty, words.allSatisfy({ word in word.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" } }) else { return nil }
            return words
        }

        /// Whether `value` is made only of operator characters, and so names an operator rather than spelling a pattern.
        static func isOperatorName(_ value: String) -> Bool {
            value.allSatisfy(Set("/=-+!*<>&|^~%.?").contains)
        }
    }
}
