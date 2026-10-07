//
// Copyright © Agulhas Labs
//

import Foundation

/// What a declaration a macro generated says of where it came from — which macro expanded, and, for an attached macro, the declaration it is attached to — as the Swift runtime's own demangler reads its mangled name.
///
/// A macro's expansion names what it declares with a mangled name (docs/ABI/Mangling.rst in the compiler's repository), and the store hands that name back as the declaration's: `@Test func spans()` generates a function named `$s`, `10GizmoTests`, `5spans`, `4Test`, `fMp_`, and a name the expansion made unique. Reading that by hand misread most real suites, because the mangling spells a word an earlier name already used as a back-reference — in `GizmoTests`, `struct LampTests { @Test func dimLampWorks() }` spells the suite `Lamp` then a letter standing for `Tests`, and the test `dim`, a letter standing for `Lamp`, then `Works` — and a reading backwards from the macro named the test `Works`. The demangler resolves every substitution and prints an expansion in fixed words — `peer macro @Test expansion`, the expansion's number, then `of dimLampWorks in GizmoTests.LampTests` for an attached macro; `freestanding macro expansion`, its number, then `of Preview in …` for a freestanding one — verified empirically on names from a real store. So a name is an expansion's only where the demangler says so, and both names are read from what it prints.
///
/// A USR is read the same way, as `$s` and what follows its `s:`. The name an expansion made unique for its declaration sits inside the USR as an identifier of its own — `@Test`'s function carries one, and so does the `makePreview()` of the registry type a `#Preview` declares — and the demangler prints that identifier as it is spelled, so it is demangled in turn.
///
/// **What it cannot read**: a demangler older than a given macro kind reads no expansion of that kind — the Swift 5.9/5.10 runtime on macOS 14, say, reads no body or preamble macro expansion (`fMb`/`fMq`, added in Swift 6.0). There, nothing of that kind counts as generated: a caller a macro generated is named by the store's mangled name, and a `#Preview`'s copy of a call it wraps is listed beside the call — an extra row, never a real use dropped as a copy, which is what calling a name generated on the strength of its spelling alone risked: a function the user named `fMp_odd` spells a marker too.
struct ExpansionOrigin: Equatable {
    /// The macro's name, as written after its `@` or `#`.
    let macro: String
    /// The base name of the declaration an attached macro is attached to; `nil` for a freestanding macro.
    let attachedTo: String?

    /// The macro as it is written in source: `#Preview` for a freestanding one, `@Test` for an attached one.
    var spelling: String {
        (attachedTo == nil ? "#" : "@") + macro
    }

    /// What the expansion is, in the words a reader looks for: `#Preview expansion`, `@Test expansion of spans`.
    var expansion: String {
        attachedTo.map { "\(spelling) expansion of \($0)" } ?? "\(spelling) expansion"
    }

    /// The origin `mangled` — a declaration's mangled name, or a USR — names, `nil` where the demangler reads no macro's expansion in it.
    init?(mangled: String) {
        guard let origin = Self.origin(in: mangled, depth: 2) else { return nil }
        self = origin
    }

    init(macro: String, attachedTo: String?) {
        self.macro = macro
        self.attachedTo = attachedTo
    }

    /// Whether `mangled` names something a macro's expansion declared: the demangler reads an expansion in it — a unique name's included, since the demangler prints the expansion it was made in.
    static func isGenerated(_ mangled: String) -> Bool {
        ExpansionOrigin(mangled: mangled) != nil
    }
}

private extension ExpansionOrigin {
    /// The words the demangler opens a freestanding macro's expansion with.
    static var freestandingWords: String {
        "freestanding macro expansion #"
    }

    /// The words between an attached macro's kind — `peer`, `accessor`, `member`, … — and its name.
    static var attachedWords: String {
        " macro @"
    }

    /// The expansion `mangled` names, read through an identifier it carries that is itself a mangled name at most `depth` times.
    static func origin(in mangled: String, depth: Int) -> ExpansionOrigin? {
        let symbol = mangled.hasPrefix("s:") ? "$s" + mangled.dropFirst(2) : mangled
        // Only a Swift symbol spelling a macro-expansion operator, or an identifier that is a mangled name, is worth the demangler's time.
        guard symbol.hasPrefix("$s"), symbol.contains("fM") || symbol.dropFirst(2).contains("$s") else { return nil }
        // A declaration's name carries its argument labels after the mangled part — `…fMu_()` — which no symbol does.
        let name = String(symbol.prefix { $0 != "(" })
        // The demangler hands back what it was given when it cannot read it.
        guard let text = demangled(name), text != name else { return nil }
        if let origin = read(text) {
            return origin
        }
        guard depth > 0 else { return nil }
        return embeddedNames(in: text).lazy.compactMap { origin(in: $0, depth: depth - 1) }.first
    }

    /// The expansion the demangler's words name first — the innermost, since it prints a declaration before the context it sits in.
    static func read(_ text: String) -> ExpansionOrigin? {
        let freestanding = text.range(of: freestandingWords)
        let attached = text.range(of: attachedWords)
        if let freestanding, attached.map({ freestanding.lowerBound < $0.lowerBound }) ?? true {
            return name(after: freestanding.upperBound, in: text).map { ExpansionOrigin(macro: $0, attachedTo: nil) }
        }
        guard let attached, let end = text[attached.upperBound...].range(of: " expansion #") else { return nil }
        let macro = text[attached.upperBound ..< end.lowerBound]
        guard !macro.isEmpty, !macro.contains(" "), let declaration = name(after: end.upperBound, in: text) else { return nil }
        return ExpansionOrigin(macro: String(macro), attachedTo: declaration)
    }

    /// The name after an expansion's number and `of` — `dimLampWorks` — up to the space or parenthesis the demangler closes it with, as it closes `Preview(in _5FC…) in module …`.
    static func name(after index: String.Index, in text: String) -> String? {
        let rest = text[index...].drop { $0.isNumber }
        guard rest.hasPrefix(" of ") else { return nil }
        let name = rest.dropFirst(4).prefix { $0 != " " && $0 != "(" }
        return name.isEmpty ? nil : String(name)
    }

    /// Every identifier in the demangler's words that is itself a mangled name: a run of identifier characters from a `$s`.
    static func embeddedNames(in text: String) -> [String] {
        var names: [String] = []
        var rest = text[...]
        while let start = rest.range(of: "$s") {
            let name = rest[start.lowerBound...].prefix { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "$") }
            names.append(String(name))
            rest = rest[name.endIndex...]
        }
        return names
    }

    /// What the Swift runtime's demangler prints for `name`, `nil` for a name that is not a Swift symbol.
    static func demangled(_ name: String) -> String? {
        name.withCString { pointer in
            guard let output = swiftDemangle(pointer, UInt(name.utf8.count), nil, nil, 0) else { return nil }
            defer { free(output) }
            return String(cString: output)
        }
    }
}

/// The demangler the Swift runtime exports, as swift-testing calls it: with no buffer given it returns a string it allocated, which the caller frees, or `nil` for a name that is not a Swift symbol.
@_silgen_name("swift_demangle")
private func swiftDemangle(
    _ mangledName: UnsafePointer<CChar>,
    _ mangledNameLength: UInt,
    _ outputBuffer: UnsafeMutablePointer<CChar>?,
    _ outputBufferSize: UnsafeMutablePointer<UInt>?,
    _ flags: UInt32
) -> UnsafeMutablePointer<CChar>?
