//
// Copyright © Agulhas Labs
//

import Foundation

/// Which Swift toolchain a run used, as the toolchain itself states it.
///
/// A tree key says what the compiler read; it says nothing about the compiler. A toolchain upgrade, an `xcode-select` to another Xcode, or a `PATH` that puts a development snapshot in front all change what an identical tree does, and each of them is common enough on a developer's machine to be the first thing a proved run has to be refused for.
///
/// `swift --version` is resolved through `PATH` rather than at an absolute path, because `PATH` is exactly how a toolchain is substituted; the whole of what it prints is kept, so the target triple travels with the version.
public struct ToolchainIdentity: Sendable, Equatable {
    /// The version banner, with its lines joined, or `nil` when no toolchain would answer.
    public let description: String

    public init(description: String) {
        self.description = description
    }
}

public extension ToolchainIdentity {
    /// How the toolchain on this `PATH` names itself, or `nil` when it could not be asked.
    ///
    /// `nil` is a refusal and never a wildcard: a run whose toolchain cannot be named is not recorded, and a question asked where it cannot be named is answered *not proved*.
    static func current() -> ToolchainIdentity? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["swift", "--version"]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        guard (try? process.run()) != nil else {
            ProcessStreams.abandon(stdout, stderr)
            return nil
        }
        let (data, _) = ProcessStreams.drain(stdout: stdout, stderr: stderr)
        process.waitUntilExit()
        guard process.terminationStatus == 0, let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        let joined = text
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
        return joined.isEmpty ? nil : ToolchainIdentity(description: joined)
    }
}
