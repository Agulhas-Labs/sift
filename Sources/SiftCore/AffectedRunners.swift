//
// Copyright © Agulhas Labs
//

/// Which runners' commands an answer prints: the one the repository builds with where the index store says which, both where it does not.
struct AffectedRunners: Equatable {
    var swiftPM = true
    var xcodebuild = true

    /// Both runners, as the answer prints them with no store or one of unknown origin.
    static let both = AffectedRunners()

    /// The runners for a store found as `provenance`: SwiftPM's own `.build` is a `swift test` repository, a DerivedData or `buildServer.json` store an `xcodebuild` one, and anything else (a configured store, an in-tree build, no store) says nothing, so both.
    ///
    /// A `.build` inside a nested package (a non-empty `package`) is not the repository's own: its `swift test` runs that package's targets only, so a root test target is reached by `xcodebuild` and both print.
    init(provenance: DiscoveredStore.Provenance? = nil, package: String = "") {
        switch provenance {
        case .swiftPMBuild: xcodebuild = !package.isEmpty
        case .derivedData, .buildServerJSON: swiftPM = false
        case .config, .inTree, nil: break
        }
    }

    /// The clause the heading carries where one runner was left out, so the omission is said once; empty where both print.
    func headingClause(provenance: DiscoveredStore.Provenance?, package: String) -> String {
        guard self != .both, let provenance else { return "" }
        let label = DiscoveredStore.label(provenance: provenance, package: package)
        return " — \(swiftPM ? "swift test" : "xcodebuild") commands only (the index store is \(label))"
    }
}
