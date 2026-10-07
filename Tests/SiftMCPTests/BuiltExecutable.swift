//
// Copyright © Agulhas Labs
//

import Foundation

/// The `sift` executable a subprocess test launches: the one this run's own build produced.
///
/// A subprocess test is a claim about the code under test, so the binary it runs has to be that code's. The build writes the executable beside the test bundle, in one products directory, wherever `--scratch-path` puts it, so the bundle's own location is the only reliable handle on it: a fixed `.build/debug` under the package names whichever build last wrote there, and under another scratch path that is an older binary answering for newer code.
struct BuiltExecutable {
    /// Where this run's `sift` is expected: in the products directory holding the running test bundle.
    static var expected: URL {
        let bundle = Bundle(for: Anchor.self).bundleURL
        let products = bundle.pathExtension == "xctest" ? bundle.deletingLastPathComponent() : bundle
        return products.appendingPathComponent("sift")
    }

    /// This run's `sift`, or `nil` where the build put none beside the test bundle — never another build's.
    static var sift: URL? {
        FileManager.default.isExecutableFile(atPath: expected.path) ? expected : nil
    }
}

private extension BuiltExecutable {
    /// A class declared in the test bundle, so `Bundle(for:)` names that bundle rather than the process that loaded it.
    final class Anchor {}
}
