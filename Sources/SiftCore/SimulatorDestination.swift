//
// Copyright © Agulhas Labs
//

import Foundation

/// The simulator an `xcodebuild` invocation ran its tests on, read from argv and then resolved against `simctl`'s own listing.
///
/// Argv is the only thing that says which device a run used, and it says it three ways: outright, by name, or not at all. The three are kept apart rather than collapsed into an optional udid because they lead to different answers — a device named outright needs no listing, a device named by name needs one and may not be settled by it, and a destination that names no device at all is a run this tool cannot follow and must say so about.
public enum SimulatorDestination: Equatable, Sendable {
    /// `-destination "id=<udid>"` — the device is named outright, so nothing has to be resolved.
    case identified(udid: String)
    /// `-destination "platform=iOS Simulator,name=<name>[,OS=<version>]"` — a name to look up in the listing.
    case named(name: String, osVersion: String?)
    /// A simulator platform whose destination names no device of its own, such as `generic/platform=iOS Simulator`.
    case unnamed
}

public extension SimulatorDestination {
    /// Every simulator `arguments` executed a test bundle on, in the order argv names them — empty when this invocation leaves no simulator torn down.
    ///
    /// **The action is read with the table `RunVerdict.Contract` reads it with**, through the population the run would file under, so a `test` standing where some option's value goes is not an action and an action argv leaves in doubt is not one either. That is the same rule ``RunCommandKind/population(of:)`` already states for a different purpose — which runs a test failure may be counted against — and it is the same set of actions for the same reason: `test` and `test-without-building` are the two that execute a test bundle, and executing a test bundle is what starts the session whose teardown switches the preference off.
    ///
    /// **Every destination, not the first.** An invocation may carry several, and each one's session tears its own device down: answering for one of them would leave the others off while the answer read as a clean run. Duplicates are dropped, since a device named twice is torn down once and owes one line, not two.
    ///
    /// **No `-destination` at all is not the same as no simulator.** Xcode resolves a default destination for the scheme itself, and that default is often a simulator — one whose session tears down exactly as a named one does, and that `log`, when given, is the only place it shows: `xcodebuild`'s own verbose build settings echo `export PLATFORM_NAME\=iphonesimulator` (or the watchOS/tvOS spelling) for the destination it picked. A command line with a `-destination` value already answers the question without reading `log` at all; `log` is consulted only when argv named none, and only a simulator platform is read out of it — there is no device to name, so a match answers `.unnamed`, the same reading a `generic/platform=…Simulator` destination gets.
    static func simulatorsOfTestRun(_ arguments: [String], log: String? = nil) -> [SimulatorDestination] {
        let key = RunCommandKind.logKey(of: arguments)
        guard RunCommandKind.population(of: key) == "\(RunCommandKind.xcodebuild.toolKey) test" else {
            return []
        }
        let named = destinations(of: arguments)
        var simulators: [SimulatorDestination] = []
        for destination in named {
            if let simulator = simulator(in: destination), !simulators.contains(simulator) {
                simulators.append(simulator)
            }
        }
        if named.isEmpty, let log, resolvedASimulator(in: log) {
            simulators.append(.unnamed)
        }
        return simulators
    }

    /// The `simctl` argument vector that lists every available device as JSON.
    static var listArguments: [String] {
        ["simctl", "list", "devices", "available", "-j"]
    }

    /// The udid `name` resolves to in `simctl`'s listing, or `nil` when the listing does not settle it.
    ///
    /// **A booted device wins, and only when exactly one is booted.** A test run goes to a booted device where there is one, and a name such as a stock device model is carried by devices on several runtimes at once — so the booted one is the run's device and the rest are candidates that were never touched. Two booted devices of one name, several available ones, or none at all leave the question unanswered, and an unanswered question is answered with `nil` rather than with whichever came first: writing a preference into the wrong device is a change to a device this run never used.
    ///
    /// `OS` narrows by the runtime the device sits under, compared component by component so `OS=26` accepts `26.0`. `OS=latest` narrows nothing, which is what it means.
    static func device(named name: String, osVersion: String?, inListing json: Data) -> String? {
        guard let listing = try? JSONDecoder().decode(Listing.self, from: json) else {
            return nil
        }
        let candidates = listing.devices
            .filter { runtime, _ in accepts(runtime: runtime, osVersion: osVersion) }
            .flatMap(\.value)
            .filter { $0.name == name }
        let booted = candidates.filter { $0.state == "Booted" }
        if booted.count == 1 {
            return booted[0].udid
        }
        guard booted.isEmpty, candidates.count == 1 else {
            return nil
        }
        return candidates[0].udid
    }
}

private extension SimulatorDestination.Listing {
    struct Device: Decodable {
        let udid: String
        let name: String
        let state: String?
    }
}

private extension SimulatorDestination {
    /// What `simctl list devices available -j` prints, down to the three fields this reads.
    struct Listing: Decodable {
        let devices: [String: [Device]]
    }

    /// Every `-destination` value on the command line, in the order they were written.
    static func destinations(of arguments: [String]) -> [String] {
        var values: [String] = []
        var expectingValue = false
        for argument in arguments.dropFirst() {
            if expectingValue {
                values.append(argument)
                expectingValue = false
                continue
            }
            expectingValue = argument == "-destination"
        }
        return values
    }

    /// Whether `log` shows `xcodebuild` resolved its own default destination to a simulator platform.
    ///
    /// The verbose build settings `xcodebuild` echoes for the action it ran carry `export PLATFORM_NAME\=<platform>` once per build — `iphonesimulator`, `watchsimulator`, `appletvsimulator` or `xrsimulator` for a simulator, `iphoneos` and its siblings for a device, `macosx` for the host. That line is read literally rather than with a pattern, since it is exactly what a verbose `xcodebuild` writes and nothing here needs to parse the rest of the block.
    static func resolvedASimulator(in log: String) -> Bool {
        ["iphonesimulator", "watchsimulator", "appletvsimulator", "xrsimulator"].contains {
            log.contains("PLATFORM_NAME\\=\($0)")
        }
    }

    /// The simulator one `-destination` value names, or `nil` when it names something else.
    ///
    /// **A platform this reader can see decides it before the identifier does.** `platform=macOS` and `platform=iOS,id=…` both name a device no `simctl` write can reach, so a `platform` that is not a simulator's ends the reading whatever else the value carries.
    ///
    /// **A bare `id=…` is the canonical spelling for a physical device too**, so on its own it is read as a simulator only when the identifier is shaped like a CoreSimulator udid — see ``isSimulatorIdentifier(_:)``. With a simulator `platform` beside it the platform has already decided, and the identifier is taken as written.
    static func simulator(in destination: String) -> SimulatorDestination? {
        let fields = fields(of: destination)
        let platform = fields["platform"]
        if let platform, !isSimulator(platform) {
            return nil
        }
        if let udid = fields["id"], !udid.isEmpty {
            guard platform != nil || isSimulatorIdentifier(udid) else {
                return nil
            }
            return .identified(udid: udid)
        }
        guard platform != nil else {
            return nil
        }
        guard let name = fields["name"], !name.isEmpty else {
            return .unnamed
        }
        let version = fields["OS"].flatMap { $0.caseInsensitiveCompare("latest") == .orderedSame ? nil : $0 }
        return .named(name: name, osVersion: version)
    }

    /// The `key=value` pairs one destination value carries, with `generic/` — which qualifies the whole destination, not the key — taken off.
    static func fields(of destination: String) -> [String: String] {
        var fields: [String: String] = [:]
        for field in destination.split(separator: ",") {
            let parts = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else {
                continue
            }
            var key = parts[0].trimmingCharacters(in: .whitespaces)
            if key.hasPrefix("generic/") {
                key = String(key.dropFirst("generic/".count))
            }
            fields[key] = parts[1].trimmingCharacters(in: .whitespaces)
        }
        return fields
    }

    /// Whether a `platform` field names a simulator — every one of them is spelled as the platform followed by the word.
    static func isSimulator(_ platform: String) -> Bool {
        platform.lowercased().hasSuffix("simulator")
    }

    /// Whether a runtime holds the devices an `OS=` value asks for — every runtime, when it asks for nothing.
    static func accepts(runtime: String, osVersion: String?) -> Bool {
        guard let osVersion else {
            return true
        }
        guard let version = runtimeVersion(of: runtime) else {
            return false
        }
        return matches(osVersion, version)
    }

    /// The runtime version a `simctl` runtime identifier carries, or `nil` when the identifier is not shaped like one.
    ///
    /// The identifier is the platform and version joined by dashes (`…SimRuntime.iOS-26-0`), so the version is what follows the first dash of its last component, with the dashes read back as the dots they stand for.
    static func runtimeVersion(of runtime: String) -> String? {
        guard let identifier = runtime.split(separator: ".").last, let dash = identifier.firstIndex(of: "-") else {
            return nil
        }
        return identifier[identifier.index(after: dash)...].replacingOccurrences(of: "-", with: ".")
    }
}

/// The two readings of a `simctl` spelling that other simulator work in this module asks for as well — a runtime version and the shape of a udid.
extension SimulatorDestination {
    /// Whether an `OS=` value names `version`, component by component, so a version written short accepts the longer spelling of itself.
    static func matches(_ asked: String, _ version: String) -> Bool {
        let wanted = asked.split(separator: ".")
        let found = version.split(separator: ".")
        guard wanted.count <= found.count else {
            return false
        }
        return zip(wanted, found).allSatisfy { $0 == $1 }
    }

    /// Whether an identifier standing alone in a destination is a simulator's.
    ///
    /// **The shape is the whole of the evidence, and it is enough.** `-destination "id=<udid>"` is how a physical device is named as well, and a `simctl` write aimed at one of those goes to no device at all — so the identifier has to say which it is. Every CoreSimulator udid is a UUID (`8-4-4-4-12` hex), and no physical device's is: an iPhone's is `8-16` hex with a dash (`00008120-000A4D3A0A88401E`) or, on older hardware, 40 hex with none. **A Mac's identifier is the one this cannot tell apart.** An Intel Mac's destination id is a UUID too, so a bare `id=<its id>` with no `platform=` beside it reads as a simulator. The cost is bounded and stated rather than prevented: one `simctl` spawn that answers "Invalid device", and an `unreached` note under a macOS run, which qualifies nothing. `platform=macOS` beside the id, which is how `xcodebuild -showdestinations` spells it, ends the reading before the identifier is looked at.
    static func isSimulatorIdentifier(_ identifier: String) -> Bool {
        let groups = identifier.split(separator: "-", omittingEmptySubsequences: false)
        guard groups.map(\.count) == [8, 4, 4, 4, 12] else {
            return false
        }
        return groups.allSatisfy { $0.allSatisfy(\.isHexDigit) }
    }
}
