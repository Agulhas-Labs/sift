//
// Copyright © Agulhas Labs
//

import Foundation

/// Which test bundles `llvm-cov` reads for a run: the ones the package declares, never whatever else sits in the products directory.
public struct CoverageObjects: Sendable {
    private init() {}
}

public extension CoverageObjects {
    /// The bundle file names to read, in the manifest's order, or a refusal where the manifest cannot say or a declared bundle is absent.
    ///
    /// `llvm-cov` keeps the first object's copy of each function's line map, so a stale bundle of a renamed or removed test target, left beside the fresh ones, would supply old line positions against a fresh profile; a bundle is chosen by being declared, never by its age, since one that was not relinked is still valid.
    static func select(declared: [String]?, present: [String]) throws -> [String] {
        guard let declared, !declared.isEmpty else {
            throw CoverageObjectsRefusal(reason: "the package's test targets could not be read from Package.swift, so no test bundle can be told from a stale one")
        }
        let files = declared.map { "\($0).xctest" }
        let missing = files.filter { !present.contains($0) }
        guard missing.isEmpty else {
            throw CoverageObjectsRefusal(reason: "the package declares \(missing.joined(separator: ", ")), which this run left no test bundle for")
        }
        return files
    }
}

public extension RunTestBundles {
    /// The test targets the package in `directory` declares for a run of `arguments`, or `nil` where the manifest cannot name them for this run.
    static func declaredNames(forRunOf arguments: [String], in directory: URL) -> [String]? {
        guard !arguments.contains(where: { $0 == "--package-path" || $0.hasPrefix("--package-path=") }) else {
            return nil
        }
        let manifest = SwiftPMManifest.parse(fileAt: directory.appendingPathComponent("Package.swift"))
        return manifest.conditionalTestTargets || manifest.testTargets.isEmpty ? nil : manifest.testTargets
    }
}
