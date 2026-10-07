//
// Copyright © Agulhas Labs
//

import SwiftSyntax

/// A file's syntax tree and the converter that reads locations against it, kept together so a shape lookup never rebuilds either.
struct BuildTimingParsedTree {
    let tree: SourceFileSyntax
    let converter: SourceLocationConverter
}
