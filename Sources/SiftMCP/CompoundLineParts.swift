//
// Copyright © Agulhas Labs
//

import Foundation

/// What a compound line has gathered so far: its calls, where its literals fall among them, and what answering them stands on.
struct CompoundLineParts {
    var calls: [InPlaceCall] = []
    var windowed: [Bool] = []
    /// The file each call reads, spelled out, or `nil` for a call that reads no file whole.
    var files: [String?] = []
    var literals: [Int: String] = [:]
    var lookups = 0
    /// How many lookups ask more than a document's outline.
    var asking = 0
    /// The directory every lookup resolves against, once the first has been added.
    var directory: String??
    /// Whether any lookup's success had to be proven.
    var proves = false
    /// The statements each call's answer stands for, in the order of ``calls``.
    var statements: [[String]] = []
    /// The fallbacks behind a `cd` or a literal, which never run, waiting for the call whose answer stands for them.
    var unattached: [String] = []

    /// Adds `found`, resolved against `directory`, and says whether it could be: a second directory, a file read whole twice, or whole beside a window of it, cannot — nor a window of a file windowed before with a literal printed since, which the one digest both windows share would move to after it.
    mutating func add(_ found: (call: InPlaceCall, isWindow: Bool), from directory: String?, answering unit: [String]) -> Bool {
        if let earlier = self.directory, earlier != directory {
            return false
        }
        self.directory = .some(directory)
        lookups += 1
        if found.call.shape != .outline {
            asking += 1
        }
        let file = found.call.readPath.map { InPlaceShape.resolve($0, against: directory) ?? $0 }
        if let file, let earlier = files.firstIndex(of: file) {
            guard found.isWindow, windowed[earlier], !literals.keys.contains(where: { $0 > earlier }) else { return false }
            // Every window's lines ride on the one digest, or none do where any window's cannot be read.
            if case let .fileDigest(path, known) = calls[earlier], case let .fileDigest(_, more) = found.call {
                calls[earlier] = .fileDigest(path: path, windows: known.isEmpty || more.isEmpty ? [] : known + more)
            }
            statements[earlier] += unattached + unit
            unattached = []
            return true
        }
        calls.append(found.call)
        windowed.append(found.isWindow)
        files.append(file)
        statements.append(unattached + unit)
        unattached = []
        return true
    }

    /// The match gathered, or `nil` where fewer than two lookups ask anything.
    var match: InPlaceShape.Match? {
        guard asking >= 2, let directory else { return nil }
        var statements = statements
        statements[statements.count - 1] += unattached
        return InPlaceShape.Match(
            calls: calls,
            directory: directory,
            isWholeCommand: true,
            windowed: windowed,
            lookups: lookups,
            fallbackFollows: proves,
            literals: literals,
            statements: statements
        )
    }
}
