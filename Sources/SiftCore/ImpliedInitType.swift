//
// Copyright © Agulhas Labs
//

import SwiftSyntax

/// The type a declaration states for an implied initializer call, with the path it is written under and the annotation node that states it, which is `nil` where `Self` stands for the enclosing type.
struct ImpliedInitType {
    let name: String
    let qualifier: String?
    let annotation: TypeSyntax?
}
