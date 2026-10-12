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
    /// The repo-relative directory of the SwiftPM package whose `.build` holds the store, empty for the repository's own package and for every store that is no SwiftPM build; what a build command printed for the store passes as `--package-path`, since SwiftPM run from the root finds no manifest there.
    var package = ""
}

extension DiscoveredStore {
    /// The wrapped SwiftPM build a reader is told to run for a package in `package` (empty for the root's): `--package-path` names a nested one, and `--build-tests` is added where a test target is wanted.
    static func swiftPMBuildCommand(package: String, buildTests: Bool) -> String {
        "sift run -- swift build" + (package.isEmpty ? "" : " --package-path \(package)") + (buildTests ? " --build-tests" : "")
    }

    /// The `swift test` a reader is told to run for a package in `package` (empty for the root's): `--package-path` names a nested one, as the build command does.
    static func swiftPMTestCommand(package: String) -> String {
        "swift test" + (package.isEmpty ? "" : " --package-path \(package)")
    }

    /// How `status` names where the store was found: the provenance, qualified by the package directory for a nested package's `.build` so it does not read as the root's.
    var label: String {
        Self.label(provenance: provenance, package: package)
    }

    /// The label for a store known only by its provenance and package, as an open store carries them.
    static func label(provenance: Provenance, package: String) -> String {
        provenance == .swiftPMBuild && !package.isEmpty ? package + "/" + provenance.name : provenance.name
    }

    /// Whether a store built in `package` answers for the repo-relative `path`: a nested package's store only for a file inside that package, any other store for the whole tree.
    ///
    /// A nested package's build describes that package alone, so a file outside it is read from another store or from syntax, never from a unit that build wrote for a path ending the same way.
    static func answers(package: String, forFile path: String) -> Bool {
        package.isEmpty || path.hasPrefix(package + "/")
    }
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
