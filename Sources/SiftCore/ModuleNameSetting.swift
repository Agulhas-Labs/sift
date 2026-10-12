//
// Copyright © Agulhas Labs
//

import Foundation

/// The module a target's build settings rename it to, read from `PRODUCT_MODULE_NAME` and `PRODUCT_NAME` in each configuration.
///
/// A target's module is not always its name: `PRODUCT_MODULE_NAME` names it outright, and otherwise Xcode derives it from `PRODUCT_NAME` through the `c99extidentifier` operator (`PRODUCT_NAME: My-App` builds `My_App`, measured with xcodegen 2.46.0 and Xcode 26). Missing either would attribute a file to a module the compiler never builds while counting it as resolved, so `where`'s framework-qualified extension rule, which trusts a fully resolved tree, would read `extension Kit2.Widget` as some framework's type and drop it unmarked.
struct ModuleNameSetting {
    /// The module a target named `target` builds across `configurations`, each one configuration's levels of build settings, highest precedence first.
    ///
    /// The levels are the target's own settings, its xcconfig, the project's settings, the project's xcconfig. A `nil` level is one this tool cannot read, an xcconfig with an `#include` or a settings group, and only matters where no level above it sets the key.
    ///
    /// A configuration that sets neither key builds the default, `target` as the compiler spells it, which is what an override in another configuration is compared against.
    static func outcome(target: String, configurations: [[[String: Any]?]]) -> Outcome {
        let perConfiguration = configurations.map { name(target: target, levels: $0) }
        guard perConfiguration.contains(where: { $0 != .unset }) else { return .unset }
        var names: Set<String> = []
        for outcome in perConfiguration {
            switch outcome {
            case .unset:
                names.insert(C99ExtendedIdentifier.spelling(of: target))
            case let .named(name):
                names.insert(name)
            case .unknown:
                return .unknown
            }
        }
        guard names.count == 1, let name = names.first else { return .unknown }
        return .named(name)
    }

    /// One configuration's module: `PRODUCT_MODULE_NAME` as written, else `PRODUCT_NAME` as the compiler spells it.
    ///
    /// Each key is read from the highest level that sets it, as Xcode resolves it, so an xcconfig's `PRODUCT_MODULE_NAME = $(TARGET_NAME)` beneath a target's own `PRODUCT_NAME` still names the module after the target.
    private static func name(target: String, levels: [[String: Any]?]) -> Outcome {
        let module = lookup("PRODUCT_MODULE_NAME", in: levels)
        let product = lookup("PRODUCT_NAME", in: levels)
        let productName: String? = switch product {
        case .absent: target
        case .unreadable: nil
        case let .value(text): expanded(text, references: ["TARGET_NAME": target])
        }
        switch module {
        case .unreadable:
            return .unknown
        case let .value(text):
            var references = ["TARGET_NAME": target]
            references["PRODUCT_NAME"] = productName
            return expanded(text, references: references).map(Outcome.named) ?? .unknown
        case .absent:
            guard product != .absent else { return .unset }
            return productName.map { .named(C99ExtendedIdentifier.spelling(of: $0)) } ?? .unknown
        }
    }

    /// An xcconfig's plain `KEY = value` lines as one level, or `nil` where it cannot be read or includes another file, which could set anything.
    ///
    /// A quoted value is kept unreadable rather than guessed at: whether the quotes are part of the name is not measured.
    static func xcconfigLevel(at url: URL) -> [String: Any]? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var level: [String: Any] = [:]
        for rawLine in text.components(separatedBy: .newlines) {
            let line = (rawLine.components(separatedBy: "//").first ?? "").trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") {
                return nil
            }
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if value.hasSuffix(";") {
                value = String(value.dropLast()).trimmingCharacters(in: .whitespaces)
            }
            level[key] = value.contains("\"") ? NSNull() : value
        }
        return level
    }

    /// `key`'s value from the highest level that sets it; unreadable where a level this tool cannot read comes first, or the setting is conditional (`KEY[sdk=…]`) or not text.
    private static func lookup(_ key: String, in levels: [[String: Any]?]) -> Lookup {
        for level in levels {
            guard let level else { return .unreadable }
            if level.keys.contains(where: { $0.hasPrefix(key + "[") }) {
                return .unreadable
            }
            if let value = level[key] {
                return string(value).map(Lookup.value) ?? .unreadable
            }
        }
        return .absent
    }

    /// `value` with each `$(NAME)` or `${NAME}` reference to a known setting substituted, or `nil` where any reference is to a setting this tool does not know, or carries an operator other than `c99extidentifier`.
    static func expanded(_ value: String, references: [String: String]) -> String? {
        var result = ""
        var rest = Substring(value)
        while let dollar = rest.firstIndex(of: "$") {
            result += rest[rest.startIndex ..< dollar]
            let opening = rest.index(after: dollar)
            guard opening < rest.endIndex else { return nil }
            let closer: Character
            switch rest[opening] {
            case "(": closer = ")"
            case "{": closer = "}"
            default: return nil
            }
            let bodyStart = rest.index(after: opening)
            guard let closing = rest[bodyStart...].firstIndex(of: closer) else { return nil }
            let parts = rest[bodyStart ..< closing].split(separator: ":", omittingEmptySubsequences: false)
            guard let key = parts.first, let substituted = references[String(key)] else { return nil }
            switch parts.dropFirst().map(String.init) {
            case []:
                result += substituted
            case ["c99extidentifier"]:
                result += C99ExtendedIdentifier.spelling(of: substituted)
            default:
                return nil
            }
            rest = rest[rest.index(after: closing)...]
        }
        result += rest
        return result.isEmpty ? nil : result
    }

    /// A setting's value as text; YAML reads `PRODUCT_NAME: 2048` as a number.
    private static func string(_ value: Any?) -> String? {
        switch value {
        case let text as String:
            text
        case let number as Int:
            String(number)
        default:
            nil
        }
    }
}

extension ModuleNameSetting {
    /// What a target's configurations say about its module name.
    enum Outcome: Equatable {
        /// No configuration renames the module, so the build file's own default applies.
        case unset
        /// Every configuration builds this module.
        case named(String)
        /// A setting renames the module through a reference this tool cannot expand, or configurations disagree, so the name is a guess.
        case unknown
    }

    /// What the levels of a configuration say about one setting.
    private enum Lookup: Equatable {
        case absent
        case unreadable
        case value(String)
    }
}
