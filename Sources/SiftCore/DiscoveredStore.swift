//
// Copyright © Agulhas Labs
//

import Foundation

/// A located index store and how it was found.
struct DiscoveredStore {
    let path: URL
    let provenance: Provenance
    /// The store's newest unit, where discovery already had to read it to choose between several stores (DerivedData), so a caller needing it again does not walk every unit a second time; `nil` where discovery never looked.
    var newestUnit: Date?
}

extension DiscoveredStore {
    enum Provenance: Equatable {
        case config
        case buildServerJSON
        case swiftPMBuild
        case derivedData
        /// An `xcodebuild -derivedDataPath` build inside an ignored directory of the tree, carrying that build directory's repo-relative path.
        case inTree(String)

        /// How an answer names where the store came from.
        var name: String {
            switch self {
            case .config: "config"
            case .buildServerJSON: "buildServer.json"
            case .swiftPMBuild: ".build"
            case .derivedData: "DerivedData"
            case let .inTree(directory): directory
            }
        }
    }
}
