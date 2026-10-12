//
// Copyright © Agulhas Labs
//

/// The extensions a type digest draws on for one declaration: the ones `where` lists under it, less those written through a path that is not the declaration's own.
///
/// They are ``ExtensionPaths/listed(under:named:in:)``'s, so a specialised header (`extension Box<String>`) is in and the header count and rows match `where`'s extensions block for the same query. One ``ExtensionPlacement`` places as another type's is left out, so a bare `extension Scratch` in a module declaring its own `Scratch` never lands under another module's; one it cannot place is kept and marked.
///
/// The one place it departs from `where` is an extension the code cannot place written through a qualifier that is neither the declaration's own path nor its module (`extension URLSession.Configuration` beside a local `Loader.Configuration`): `where` lists it, unplaced, while here it stays the external type's, which is what ``DigestMissAnswer`` answers a target naming it with.
struct DigestOwnedExtensions {
    /// The marker `where` appends to an extension it cannot place, for the type named `name`.
    static func mark(named name: String) -> String {
        " — may extend another module's \(name)"
    }

    /// The extensions of `primary`, in `where`'s order, each with whether it may extend another module's type of the name instead.
    static func of(_ primary: SymbolRow, renderer: DigestRenderer) throws -> [(row: SymbolRow, mayExtendAnother: Bool)] {
        try ExtensionPaths.listed(under: [primary], named: primary.name, in: renderer.store).filter { try renderer.owns(extension: $0.row, primary: primary) }
    }
}
