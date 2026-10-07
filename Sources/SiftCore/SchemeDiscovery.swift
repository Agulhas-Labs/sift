//
// Copyright © Agulhas Labs
//

import Foundation

/// Finding the `.xcscheme` files a repository holds, by reading the tree rather than an index of it.
public struct SchemeDiscovery {
    /// Every scheme under `root` that sits where Xcode reads one from, live, skipping the trees no configuration opts back in.
    ///
    /// The directory skip is ``SiftConfig/isExcludedPathComponent(_:)``, the same rule plan discovery and the file walk apply, so all three agree about what is in the repository.
    ///
    /// **Both shared and per-user schemes are read, and each says which it is.** A per-user scheme under `xcuserdata` is not shared — most repositories, this one included, do not even commit one — so a target only such a scheme runs is a target run on one machine; the answer names the scheme and says it is per-user rather than folding it in with the shared ones or pretending it is not there.
    ///
    /// A file at this extension anywhere but those two directories is left out rather than carried as unreadable: it is not a scheme Xcode runs, so it is not a scheme this answer has anything to say about.
    public static func schemes(under root: URL) throws -> SchemeSurvey {
        let rootURL = root.standardizedFileURL
        let rootPath = rootURL.path
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: rootPath, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw SchemeError.unwalkable(path: rootPath)
        }
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) else {
            throw SchemeError.unwalkable(path: rootPath)
        }
        var schemes: [SchemeFile] = []
        var unreadable: [SchemeSurvey.Unreadable] = []
        while let url = enumerator.nextObject() as? URL {
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false {
                if SiftConfig.isExcludedPathComponent(url.lastPathComponent) {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard url.pathExtension == schemeExtension else { continue }
            let standardized = url.standardizedFileURL.path
            guard standardized.hasPrefix(rootPath + "/") else { continue }
            let relative = String(standardized.dropFirst(rootPath.count + 1))
            guard let location = SchemeFile.location(ofRepoRelativePath: relative) else { continue }
            do {
                let data = try Data(contentsOf: url)
                try schemes.append(
                    SchemeFile.read(data, name: url.deletingPathExtension().lastPathComponent, path: relative, location: location)
                )
            } catch {
                unreadable.append(SchemeSurvey.Unreadable(path: relative, reason: "\(error)"))
            }
        }
        return SchemeSurvey(
            schemes: schemes.sorted { ($0.name, $0.path) < ($1.name, $1.path) },
            unreadable: unreadable.sorted { $0.path < $1.path }
        )
    }

    /// The extension Xcode gives a scheme.
    private static var schemeExtension: String {
        "xcscheme"
    }
}
