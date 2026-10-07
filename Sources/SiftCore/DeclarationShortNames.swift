//
// Copyright © Agulhas Labs
//

/// How a `where` answer names a declaration once its `declarations` list has named it in full: by the shortest tail of its qualified name no other declaration listed ends with.
///
/// The list prints each declaration's module-qualified name and signature once. A block further down that stands for some of them says which in as few words as stay unambiguous — `init(of:)` where only one declaration listed has that name, `A.run()` and `B.run()` where two types each declare one, and the qualified name itself only where nothing shorter tells them apart.
struct DeclarationShortNames {
    private var short: [Int64: String] = [:]
    private var all: Set<Int64> = []

    /// The short names of `declarations`, each told apart from every other by `qualifiedName`.
    init(_ declarations: [SymbolRow], qualifiedName: (SymbolRow) throws -> String) rethrows {
        let named = try declarations.map { try (id: $0.id, qualified: qualifiedName($0)) }
        let distinct = Set(named.map(\.qualified))
        for (id, qualified) in named {
            all.insert(id)
            let parts = Self.components(of: qualified)
            let tails = parts.indices.reversed().map { parts[$0...].joined(separator: ".") }
            short[id] = tails.first { tail in
                !distinct.contains { $0 != qualified && ($0 == tail || $0.hasSuffix("." + tail)) }
            } ?? qualified
        }
    }

    /// The short name of `row`, or its own name for a declaration the list does not carry.
    func name(of row: SymbolRow) -> String {
        short[row.id] ?? row.name
    }

    /// What a block standing for `rows` is said to be for: `both` or `all N declarations` where it stands for every one listed, their short names otherwise, and `nil` where the answer lists that one declaration alone.
    func owners(_ rows: [SymbolRow]) -> String? {
        let ids = Set(rows.map(\.id))
        if ids == all {
            switch all.count {
            case 1: return nil
            case 2: return "both"
            default: return "all \(all.count) declarations"
            }
        }
        return rows.map(name(of:)).sorted().joined(separator: ", ")
    }

    /// A qualified name's dotted components, the last keeping its argument labels whole.
    private static func components(of qualified: String) -> [String] {
        let labels = qualified.firstIndex(of: "(") ?? qualified.endIndex
        var parts = qualified[..<labels].split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        if let last = parts.popLast() {
            parts.append(last + qualified[labels...])
        }
        return parts
    }
}
