//
// Copyright © Agulhas Labs
//

/// The facts of the platform this binary was built for that decide a platform `#if` condition, which are the facts of the `swift test` it reads beside it.
///
/// Built for a platform not spelt here, every condition is undecided.
struct HostPlatform {
    /// What the host makes of `function(argument)` in an `#if` condition: active or inactive where the host decides it, undecided otherwise.
    static func decides(_ function: String, _ argument: String) -> HostCompilation.State {
        let decided: Bool? = switch function {
        case "os": os(argument)
        case "arch": arch(argument)
        case "canImport": canImport(argument)
        case "targetEnvironment": argument == "simulator" && isMacOS ? false : nil
        default: nil
        }
        return decided.map { $0 ? .active : .inactive } ?? .undecided
    }
}

private extension HostPlatform {
    static var isMacOS: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }

    static var hostArchitecture: String? {
        #if arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "x86_64"
        #else
        nil
        #endif
    }

    static var knownSystems: Set<String> {
        ["macOS", "OSX", "iOS", "tvOS", "watchOS", "Linux", "Windows", "Android"]
    }

    static var knownArchitectures: Set<String> {
        ["arm64", "x86_64", "i386", "arm", "arm64_32", "wasm32", "powerpc64", "powerpc64le", "s390x"]
    }

    /// Modules every macOS toolchain running `swift test` can import.
    static var alwaysImportable: Set<String> {
        ["Darwin", "Foundation", "XCTest", "Testing", "Dispatch"]
    }

    /// Modules that exist only on another platform, so macOS never imports them.
    static var neverImportable: Set<String> {
        ["UIKit", "Glibc", "Musl", "Bionic", "ucrt"]
    }

    static func os(_ name: String) -> Bool? {
        guard isMacOS, knownSystems.contains(name) else { return nil }
        return name == "macOS" || name == "OSX"
    }

    static func arch(_ name: String) -> Bool? {
        guard let host = hostArchitecture, knownArchitectures.contains(name) else { return nil }
        return name == host
    }

    static func canImport(_ module: String) -> Bool? {
        guard isMacOS else { return nil }
        if alwaysImportable.contains(module) {
            return true
        }
        return neverImportable.contains(module) ? false : nil
    }
}
