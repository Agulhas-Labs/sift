//
// Copyright © Agulhas Labs
//

/// Every declaration kind the index records.
public enum SymbolKind: String, Sendable, CaseIterable {
    case structKind = "struct"
    case classKind = "class"
    case actor
    case enumKind = "enum"
    case protocolKind = "protocol"
    case extensionKind = "extension"
    case typealiasKind = "typealias"
    case associatedType = "associatedtype"
    case function = "func"
    case initializer = "init"
    case subscriptKind = "subscript"
    case variable = "var"
    case enumCase = "case"
    case operatorKind = "operator"
    case precedenceGroup = "precedencegroup"
    case macro
}

public extension SymbolKind {
    /// `true` for kinds that can contain member declarations.
    var isContainer: Bool {
        switch self {
        case .structKind, .classKind, .actor, .enumKind, .protocolKind, .extensionKind: true
        default: false
        }
    }

    /// `true` for the nominal type kinds a digest can target directly.
    var isTypeDeclaration: Bool {
        switch self {
        case .structKind, .classKind, .actor, .enumKind, .protocolKind: true
        default: false
        }
    }

    /// `true` for a property or a subscript: used by being read and written through its accessors, never by being called, so what stands for its callers is its reads and writes.
    var isReadAndWritten: Bool {
        switch self {
        case .variable, .subscriptKind: true
        default: false
        }
    }

    /// `true` for a property, a subscript or an enum case: what stands for its callers is its uses.
    ///
    /// A property or subscript is read and written through its accessors; an enum case is named — `.fast`, `case .fast:` — and called only where a payload is built.
    var isUsedRatherThanCalled: Bool {
        switch self {
        case .variable, .subscriptKind, .enumCase: true
        default: false
        }
    }
}
