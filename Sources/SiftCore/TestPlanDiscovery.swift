//
// Copyright © Agulhas Labs
//

import Foundation

/// Finding the `.xctestplan` files a repository holds, by reading the tree rather than an index of it.
public struct TestPlanDiscovery {
    /// Every `.xctestplan` under `root`, read live, skipping the trees no configuration opts back in.
    ///
    /// The directory skip is ``SiftConfig/isExcludedPathComponent(_:)`` — build output, caches, vendored trees and every hidden tree — which is the rule the file walk applies, so plan discovery and file indexing agree about what is in the repository.
    ///
    /// Two plans of one name in different directories are both answered, ordered by name and then by path, so the answer is the same on every machine.
    ///
    /// A file that does not decode is carried in ``TestPlanSurvey/unreadable`` instead of being left out, because a plan that could not be read has to stay nameable by whoever reports the answer.
    public static func plans(under root: URL) throws -> TestPlanSurvey {
        let rootURL = root.standardizedFileURL
        let rootPath = rootURL.path
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: rootPath, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw TestPlanError.unwalkable(path: rootPath)
        }
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) else {
            throw TestPlanError.unwalkable(path: rootPath)
        }
        var plans: [TestPlanFile] = []
        var unreadable: [TestPlanSurvey.Unreadable] = []
        while let url = enumerator.nextObject() as? URL {
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false {
                if SiftConfig.isExcludedPathComponent(url.lastPathComponent) {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard url.pathExtension == planExtension else { continue }
            let standardized = url.standardizedFileURL.path
            guard standardized.hasPrefix(rootPath + "/") else { continue }
            let relative = String(standardized.dropFirst(rootPath.count + 1))
            do {
                let data = try Data(contentsOf: url)
                try plans.append(TestPlanFile.read(data, name: url.deletingPathExtension().lastPathComponent, path: relative))
            } catch {
                unreadable.append(TestPlanSurvey.Unreadable(path: relative, reason: "\(error)"))
            }
        }
        return TestPlanSurvey(
            plans: plans.sorted { ($0.name, $0.path) < ($1.name, $1.path) },
            unreadable: unreadable.sorted { $0.path < $1.path }
        )
    }

    /// The extension Xcode gives a test plan.
    private static var planExtension: String {
        "xctestplan"
    }
}
