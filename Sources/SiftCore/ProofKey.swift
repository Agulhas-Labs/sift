//
// Copyright © Agulhas Labs
//

import Foundation

/// The command a proof is filed and looked up under: argv with the options that only say *where* SwiftPM builds taken out.
///
/// `--scratch-path`, `--build-path` and `--cache-path` (in both `--opt value` and `--opt=value` spellings) change where the products and caches live and nothing about which tests run on which tree, so a green `swift test --scratch-path X` proves `swift test`. Every other option still distinguishes the key: a filter, `--skip`, a configuration or `-Xswiftc` changes what was tested, and a filtered run never proves an unfiltered one. Only `swift test` and `swift build` are normalised; any other command keys on its argv as spelled.
public struct ProofKey {
    private init() {}

    private static let locationOptions: Set<String> = ["--scratch-path", "--build-path", "--cache-path"]

    public static func command(of arguments: [String]) -> String {
        guard arguments.count >= 2, arguments[0] == "swift", arguments[1] == "test" || arguments[1] == "build" else {
            return arguments.joined(separator: " ")
        }
        var kept: [String] = []
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if locationOptions.contains(argument) {
                index += 2
                continue
            }
            if let equals = argument.firstIndex(of: "="), locationOptions.contains(String(argument[..<equals])) {
                index += 1
                continue
            }
            kept.append(argument)
            index += 1
        }
        return kept.joined(separator: " ")
    }
}
