//
// Copyright © Agulhas Labs
//

import SiftCore
import Testing

/// Covers the version constant both binary faces report.
struct SiftVersionTests {
    @Test
    func currentIsASemanticVersion() {
        let parts = SiftVersion.current.split(separator: ".")

        #expect(parts.count == 3)
        #expect(parts.allSatisfy { UInt($0) != nil })
    }
}
