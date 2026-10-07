//
// Copyright © Agulhas Labs
//

import Foundation

/// Why the test bundles or the result bundle a coverage reading needs could not be read.
public struct CoverageObjectsRefusal: Error, Equatable {
    public let reason: String

    public init(reason: String) {
        self.reason = reason
    }
}
