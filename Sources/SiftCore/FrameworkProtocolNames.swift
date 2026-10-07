//
// Copyright © Agulhas Labs
//

/// The type names a standard library or framework protocol, written in a type's inheritance clause, hands to the type's scope: its associated types, those of the protocols it refines included; and those a framework type an extension extends holds itself.
///
/// A name written bare inside a conforming type is looked up in that type's members before the module's, so `Element()` inside a `Sequence` may be the inferred element type rather than a tree type of the name, and inside `extension Array` the generic parameter. Both lists are closed: a type on neither may hand on any name, so only an entry here can ever let a site go as another type's, and one is added only with every name it supplies.
struct FrameworkProtocolNames {
    /// Whether `protocol`, a supertype or an extended type the tree does not declare, may hand `name` to the scope of a type inheriting it or of an extension of it.
    static func mayName(_ name: String, from protocol: String) -> Bool {
        guard !inert.contains(`protocol`) else { return false }
        guard let supplied = supplying[`protocol`] else { return true }
        return supplied.contains(name)
    }

    /// Whether `supertype`, written in an inheritance clause and not declared by the tree, may hand `name` to the inheriting type's scope, where a raw-literal type is an enum's raw type, which supplies only `RawRepresentable`'s names.
    static func mayName(_ name: String, inheriting supertype: String) -> Bool {
        mayName(name, from: rawLiteralTypes.contains(supertype) ? "RawRepresentable" : supertype)
    }

    /// Protocols that hand no type name to a conforming type's scope, a suppressed conformance as `DeclaredTypeName` reads it (`~Copyable`) included.
    private static let inert: Set<String> = [
        "~Copyable", "~Escapable", "AnyObject", "BitwiseCopyable", "Codable", "Comparable", "CaseIterable", "CustomDebugStringConvertible",
        "CustomStringConvertible", "Decodable", "Encodable", "Equatable", "Error", "Hashable", "Sendable",
    ]

    /// The standard types an enum may write as its raw type, which no class or protocol can inherit, so in an inheritance clause each is a raw type.
    private static let rawLiteralTypes: Set<String> = [
        "CGFloat", "Character", "Double", "Float", "Float16", "Int", "Int128", "Int16", "Int32", "Int64", "Int8", "String", "UInt", "UInt128",
        "UInt16", "UInt32", "UInt64", "UInt8",
    ]

    private static let collection: Set<String> = ["Element", "Index", "Indices", "Iterator", "SubSequence"]
    private static let stringLiteral: Set<String> = ["ExtendedGraphemeClusterLiteralType", "StringLiteralType", "UnicodeScalarLiteralType"]

    /// Each protocol or framework type known by every type name it supplies.
    private static let supplying: [String: Set<String>] = [
        // Standard library types, with the names the protocols they conform to supply, Foundation's `Regions` for byte arrays included.
        "Array": collection.union(["ArrayLiteralElement", "Regions"]),
        // Standard library.
        "AsyncIteratorProtocol": ["Element", "Failure"],
        "AsyncSequence": ["AsyncIterator", "Element", "Failure"],
        "BidirectionalCollection": collection,
        "Collection": collection,
        "ExpressibleByArrayLiteral": ["ArrayLiteralElement"],
        "ExpressibleByBooleanLiteral": ["BooleanLiteralType"],
        "ExpressibleByDictionaryLiteral": ["Key", "Value"],
        "ExpressibleByExtendedGraphemeClusterLiteral": ["ExtendedGraphemeClusterLiteralType", "UnicodeScalarLiteralType"],
        "ExpressibleByFloatLiteral": ["FloatLiteralType"],
        "ExpressibleByIntegerLiteral": ["IntegerLiteralType"],
        "ExpressibleByStringInterpolation": stringLiteral.union(["StringInterpolation"]),
        "ExpressibleByStringLiteral": stringLiteral,
        "ExpressibleByUnicodeScalarLiteral": ["UnicodeScalarLiteralType"],
        "Identifiable": ["ID"],
        "IteratorProtocol": ["Element"],
        "MutableCollection": collection,
        "OptionSet": ["ArrayLiteralElement", "Element", "RawValue"],
        "RandomAccessCollection": collection,
        "RangeReplaceableCollection": collection,
        "RawRepresentable": ["RawValue"],
        "Sequence": ["Element", "Iterator"],
        "SetAlgebra": ["ArrayLiteralElement", "Element"],
        "Strideable": ["Stride"],
        // SwiftUI and Combine.
        "ObservableObject": ["ObjectWillChangePublisher"],
        "Scene": ["Body"],
        "View": ["Body"],
        "ViewModifier": ["Body", "Content"],
    ]
}
