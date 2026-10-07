//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore

/// The marker in sift's per-user state directory that says the lookups question was answered no, so the next ask defaults to no.
///
/// Written only by an answered question, cleared by a yes or by a flag that adds the lookups, and left alone where nothing was asked.
struct LookupsDeclineRecord {
    /// The state directory holding the marker: `~/.sift`, or what `SIFT_HOME` names.
    let directory: URL

    /// The marker for the state directory `environment` resolves to, or `directory` where a caller names one.
    init(directory: URL?, environment: [String: String]) {
        self.directory = directory ?? SiftPaths.home(environment: environment)
    }

    private var file: URL {
        directory.appendingPathComponent("lookups-declined")
    }

    /// Whether the lookups question was declined before.
    var exists: Bool {
        FileManager.default.fileExists(atPath: file.path)
    }

    /// Remembers a decline; a directory that cannot be written is not an install failure, so the question is simply asked with its usual default next time.
    func write() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? Data().write(to: file)
    }

    /// Forgets a decline.
    func clear() {
        try? FileManager.default.removeItem(at: file)
    }
}
