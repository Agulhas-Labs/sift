//
// Copyright © Agulhas Labs
//

import Foundation
import SwiftParser
import SwiftSyntax

/// The names a by-name scan of `where` looks for, each with the shape a written hit of it must take to be a use of what was asked about.
///
/// A property, a case or a type is used by its name alone, so any whole word counts. A function or an initializer is reached by a call or a reference, and its base name is often a common word that a local or a parameter elsewhere also spells, so a bare-name scan for it lists every line writing the word. Its hits count where the name is followed by `(` and the label of an argument a call can open with, `(` straight into an argument where that one is unlabelled, `()` where every parameter can be left out, `{` or `() {` where it takes any parameter a trailing closure might fill, or nothing of those where it is reached as a member, `Type.f` handed on unapplied; whitespace, line breaks and comments inside the parenthesis are skipped, so a call written across lines and a compound reference are both kept. An initializer's type name is scanned in the same shape, `Box(label:)` calling it as `Box.init(label:)` does. An unapplied reference written without its labels or its owner, `f` alone, is the one use this does not see. Where several declarations share a name, a hit counts if any of their shapes takes it, and a bare one takes every hit.
struct ScannedNames: ExpressibleByArrayLiteral {
    private var shapes: [String: CallShape] = [:]

    /// Names matched as bare words, as every scan matched them before shapes were told apart.
    init(arrayLiteral names: String...) {
        for name in names {
            shapes[name] = .bare
        }
    }

    /// The base names of `rows`, each with the shape its declarations' signatures allow, and an initializer's type name, read from its container in `index`, with the initializer's.
    init(rows: [SymbolRow], in index: IndexStore) throws {
        for row in rows {
            let shape = CallShape(row: row)
            add(shape, as: row.baseName)
            guard row.kind == .initializer, !shape.isBare, let parentID = row.parentID, let parent = try index.symbol(withID: parentID),
                  let typeName = parent.name.split(separator: ".").last.map({ String($0.prefix { $0 != "<" }) }), !typeName.isEmpty else { continue }
            add(shape.asTypeName, as: typeName)
        }
    }

    var names: Set<String> {
        Set(shapes.keys)
    }

    var isEmpty: Bool {
        shapes.isEmpty
    }

    /// Whether `name` is matched as a bare word, its hits counted wherever they fall.
    func isBare(_ name: String) -> Bool {
        shapes[name]?.isBare ?? true
    }

    /// Whether `data` holds one of the names as a whole word at all: the byte search alone, before any lexing or shape check.
    func writes(in data: Data) -> Bool {
        data.withUnsafeBytes { !SwiftMentionLexer.wordHits(of: shapes.keys.map { Array($0.utf8) }, in: $0).isEmpty }
    }

    /// The hits of each name in `source` that take its shape, in byte order.
    func hits(in source: UnsafeRawBufferPointer) -> [SwiftMentionLexer.Hit] {
        shapes.keys.flatMap { hits(of: $0, in: source) }.sorted { $0.offset < $1.offset }
    }

    /// The hits of `name` alone in `source` that take its shape.
    func hits(of name: String, in source: UnsafeRawBufferPointer) -> [SwiftMentionLexer.Hit] {
        let needle = Array(name.utf8)
        let shape = shapes[name] ?? .bare
        return SwiftMentionLexer.hits(writing: [needle], in: source).filter { shape.accepts(hitAt: $0.offset, length: needle.count, in: source) }
    }

    /// Whether a symbol the store records as `symbolName`, `path(invokedAs:)` or `path`, is one `name`'s shape takes, read as its compound name is spelled: the guess for a recorded place whose text has moved since.
    func accepts(symbolNamed symbolName: String, as name: String) -> Bool {
        guard let shape = shapes[name], !shape.isBare else { return true }
        let bytes = Array(symbolName.utf8)
        let end = bytes.firstIndex(of: UInt8(ascii: "(")) ?? bytes.count
        return bytes.withUnsafeBytes { shape.accepts(hitAt: 0, length: end, in: $0) }
    }

    private mutating func add(_ shape: CallShape, as name: String) {
        shapes[name] = shapes[name].map { $0.merged(with: shape) } ?? shape
    }
}

extension ScannedNames {
    /// A place the store recorded a symbol of a scanned name referenced at, at the build.
    struct RecordedPlace: Equatable {
        /// The 1-based line.
        let line: Int
        /// The 1-based UTF-8 column the reference starts at.
        let column: Int
        /// Whether a symbol recorded there is one the name's shape takes by its compound name (``ScannedNames/accepts(symbolNamed:as:)``).
        var isTakenByName: Bool
    }

    /// What may follow a written name for the hit to be a call of, or a reference to, the declarations behind it.
    private struct CallShape {
        static let bare = CallShape(isBare: true)

        private static let typeDeclaringKeywords: Set<String> = ["struct", "class", "enum", "actor", "extension", "protocol"]

        var isBare = false
        /// The argument labels a call can open with.
        var openingLabels: Set<String> = []
        /// Whether a call can open with an unlabelled argument.
        var opensUnlabelled = false
        /// Whether a call can pass nothing, `name()`.
        var opensEmpty = false
        /// Whether there is a parameter a trailing closure might fill, `name { … }` or `name() { … }`, its type a closure's or a typealias for one.
        var takesParameters = false
        /// Whether a hit reached as a member, `Type.name`, is a reference with nothing after it: true for a function or an initializer, false for an initializer's type name, which a member access names as the type.
        var takesMemberAccess = true
        /// Whether the name can be followed by generic arguments before its call, `Box<Int>(label:)`.
        var takesGenericArguments = false

        /// The shape `row` is called in: bare for anything but a function or an initializer, or for one whose signature does not parse back to its name.
        init(row: SymbolRow) {
            guard row.kind == .function || row.kind == .initializer else {
                isBare = true
                return
            }
            self = NestingGate.parseOrEmpty(row.signature) { Self(row: row, parsed: $0) }
        }

        /// The shape of `row`, read from its signature's parse `tree` on the parse thread that made it.
        private init(row: SymbolRow, parsed tree: SourceFileSyntax) {
            guard let list = Self.parameters(of: row, in: tree) else {
                isBare = true
                return
            }
            let labels = ParameterLabels(list)
            opensEmpty = true
            takesParameters = !list.isEmpty
            for parameter in labels.parameters {
                if let label = parameter.label {
                    openingLabels.insert(label)
                } else {
                    opensUnlabelled = true
                }
                guard parameter.isSkippable else {
                    opensEmpty = false
                    break
                }
            }
        }

        private init(isBare: Bool) {
            self.isBare = isBare
        }

        /// This shape for an initializer's type name: called as the initializer is, never reached as a member, and taking generic arguments.
        var asTypeName: CallShape {
            var shape = self
            shape.takesMemberAccess = false
            shape.takesGenericArguments = true
            return shape
        }

        func merged(with other: CallShape) -> CallShape {
            var merged = self
            merged.isBare = isBare || other.isBare
            merged.openingLabels.formUnion(other.openingLabels)
            merged.opensUnlabelled = opensUnlabelled || other.opensUnlabelled
            merged.opensEmpty = opensEmpty || other.opensEmpty
            merged.takesParameters = takesParameters || other.takesParameters
            merged.takesMemberAccess = takesMemberAccess || other.takesMemberAccess
            merged.takesGenericArguments = takesGenericArguments || other.takesGenericArguments
            return merged
        }

        /// Whether the hit `length` bytes long at `start` in `source`, with what surrounds it, is a use of this shape.
        func accepts(hitAt start: Int, length: Int, in source: UnsafeRawBufferPointer) -> Bool {
            guard !isBare else { return true }
            var index = start + length
            if index < source.count, source[index] == UInt8(ascii: "`") {
                index += 1
            }
            if takesGenericArguments {
                index = Self.skippingGenericArguments(from: index, in: source)
            }
            index = Self.skipping(from: index, in: source, lineBreaks: false)
            guard index < source.count else { return takesMemberAccess && Self.isMemberAccess(at: start, in: source) }
            if source[index] == UInt8(ascii: "{") {
                return takesParameters && !Self.typeDeclaringKeywords.contains(Self.word(endingBefore: start, in: source))
            }
            guard source[index] == UInt8(ascii: "(") else { return takesMemberAccess && Self.isMemberAccess(at: start, in: source) }
            guard !opensUnlabelled else { return true }
            index = Self.skipping(from: index + 1, in: source, lineBreaks: true)
            guard index < source.count else { return false }
            if source[index] == UInt8(ascii: ")") {
                let after = Self.skipping(from: index + 1, in: source, lineBreaks: false)
                return opensEmpty || (takesParameters && after < source.count && source[after] == UInt8(ascii: "{"))
            }
            var label: [UInt8] = []
            while index < source.count, Self.isLabelByte(source[index]) {
                if source[index] != UInt8(ascii: "`") {
                    label.append(source[index])
                }
                index += 1
            }
            index = Self.skipping(from: index, in: source, lineBreaks: true)
            guard index < source.count, source[index] == UInt8(ascii: ":") else { return false }
            return String(bytes: label, encoding: .utf8).map(openingLabels.contains) ?? false
        }

        /// The parameter clause `row`'s signature, parsed as `tree`, declares, or `nil` where it does not parse back to the row's own name.
        private static func parameters(of row: SymbolRow, in tree: SourceFileSyntax) -> FunctionParameterListSyntax? {
            guard !tree.hasError, let item = tree.statements.first?.item else { return nil }
            if let function = item.as(FunctionDeclSyntax.self) {
                let list = function.signature.parameterClause.parameters
                return SymbolNaming.labeledName(base: SymbolNaming.name(of: function.name), parameters: list) == row.name ? list : nil
            }
            if let initializer = item.as(InitializerDeclSyntax.self) {
                let list = initializer.signature.parameterClause.parameters
                return SymbolNaming.labeledName(base: "init", parameters: list) == row.name ? list : nil
            }
            return nil
        }

        /// Whether the hit at `start` follows a single `.`, through a backtick, whitespace and line breaks, whose receiver is a type, `self`, `Self` or nothing (a leading-dot implicit member), and not a range's `...`: a lowercase value's property of the same name is not a reference to the function.
        private static func isMemberAccess(at start: Int, in source: UnsafeRawBufferPointer) -> Bool {
            var index = start - 1
            if index >= 0, source[index] == UInt8(ascii: "`") {
                index -= 1
            }
            while index >= 0, isSpace(source[index], lineBreaks: true) {
                index -= 1
            }
            guard index >= 0, source[index] == UInt8(ascii: "."), index == 0 || source[index - 1] != UInt8(ascii: ".") else { return false }
            var end = index
            while end > 0, isSpace(source[end - 1], lineBreaks: true) {
                end -= 1
            }
            guard end > 0 else { return true }
            if source[end - 1] == UInt8(ascii: ">") {
                end = skippingGenericArgumentsBackward(from: end, in: source)
            }
            let receiver = word(endingBefore: end, in: source)
            if let first = receiver.unicodeScalars.first {
                return receiver == "self" || first.properties.isUppercase
            }
            return end > 0 && [UInt8(ascii: "("), UInt8(ascii: ","), UInt8(ascii: ":"), UInt8(ascii: "=")].contains(source[end - 1])
        }

        /// The offset of the `<` opening the generic argument clause that closes just before `end`, or `end` where none opens.
        private static func skippingGenericArgumentsBackward(from end: Int, in source: UnsafeRawBufferPointer) -> Int {
            var depth = 0
            var index = end - 1
            while index >= 0 {
                switch source[index] {
                case UInt8(ascii: ">"):
                    depth += 1
                case UInt8(ascii: "<"):
                    depth -= 1
                    if depth == 0 {
                        return index
                    }
                case UInt8(ascii: ","), UInt8(ascii: "."), UInt8(ascii: "["), UInt8(ascii: "]"), UInt8(ascii: "?"), UInt8(ascii: ":"), UInt8(ascii: " "):
                    break
                default:
                    guard isLabelByte(source[index]) else { return end }
                }
                index -= 1
            }
            return end
        }

        /// The identifier ending, through spaces, just before `start`, or `""`.
        private static func word(endingBefore start: Int, in source: UnsafeRawBufferPointer) -> String {
            var end = start
            while end > 0, isSpace(source[end - 1], lineBreaks: true) {
                end -= 1
            }
            var begin = end
            while begin > 0, isLabelByte(source[begin - 1]) {
                begin -= 1
            }
            return String(bytes: UnsafeRawBufferPointer(rebasing: source[begin ..< end]), encoding: .utf8) ?? ""
        }

        /// The byte after a generic argument clause starting at `start`, `<Int, [String]>`, or `start` where none closes there.
        private static func skippingGenericArguments(from start: Int, in source: UnsafeRawBufferPointer) -> Int {
            guard start < source.count, source[start] == UInt8(ascii: "<") else { return start }
            var depth = 0
            var index = start
            while index < source.count {
                switch source[index] {
                case UInt8(ascii: "<"):
                    depth += 1
                case UInt8(ascii: ">"):
                    depth -= 1
                    if depth == 0 {
                        return index + 1
                    }
                case UInt8(ascii: ","), UInt8(ascii: "."), UInt8(ascii: "["), UInt8(ascii: "]"), UInt8(ascii: "?"), UInt8(ascii: ":"), UInt8(ascii: " "):
                    break
                default:
                    guard isLabelByte(source[index]) else { return start }
                }
                index += 1
            }
            return start
        }

        /// The first byte from `start` that is not whitespace or a comment, a line break and a line comment skipped only where line breaks are.
        private static func skipping(from start: Int, in source: UnsafeRawBufferPointer, lineBreaks: Bool) -> Int {
            var index = start
            while index < source.count {
                if isSpace(source[index], lineBreaks: lineBreaks) {
                    index += 1
                } else if index + 1 < source.count, source[index] == UInt8(ascii: "/"), source[index + 1] == UInt8(ascii: "*") {
                    index = skippingBlockComment(from: index, in: source)
                } else if lineBreaks, index + 1 < source.count, source[index] == UInt8(ascii: "/"), source[index + 1] == UInt8(ascii: "/") {
                    while index < source.count, source[index] != UInt8(ascii: "\n") {
                        index += 1
                    }
                } else {
                    break
                }
            }
            return index
        }

        /// The byte after the block comment opening at `start`, nested ones included, or the end of `source`.
        private static func skippingBlockComment(from start: Int, in source: UnsafeRawBufferPointer) -> Int {
            var depth = 0
            var index = start
            while index + 1 < source.count {
                if source[index] == UInt8(ascii: "/"), source[index + 1] == UInt8(ascii: "*") {
                    depth += 1
                    index += 2
                } else if source[index] == UInt8(ascii: "*"), source[index + 1] == UInt8(ascii: "/") {
                    depth -= 1
                    index += 2
                    if depth == 0 {
                        return index
                    }
                } else {
                    index += 1
                }
            }
            return source.count
        }

        private static func isSpace(_ byte: UInt8, lineBreaks: Bool) -> Bool {
            byte == UInt8(ascii: " ") || byte == UInt8(ascii: "\t") || (lineBreaks && (byte == UInt8(ascii: "\n") || byte == UInt8(ascii: "\r")))
        }

        private static func isLabelByte(_ byte: UInt8) -> Bool {
            byte == UInt8(ascii: "_") || byte == UInt8(ascii: "`") || byte >= 0x80 || (byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")) || (byte | 0x20 >= UInt8(ascii: "a") && byte | 0x20 <= UInt8(ascii: "z"))
        }
    }
}
