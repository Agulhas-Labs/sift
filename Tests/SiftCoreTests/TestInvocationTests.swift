//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers the exact `xcodebuild` command lines one `sift test` run makes, and everything it refuses to make one from.
///
/// Nothing here launches anything: every case is argv in, argv out, or bytes in and one fact out.
struct TestInvocationTests {
    private func makeRun(passThrough: [String] = [], only: [String] = [], skip: [String] = []) throws -> TestInvocation {
        try TestInvocation(
            scheme: "TestDemo",
            deviceType: "iPhone 17",
            osVersion: "27.0",
            plan: "Default",
            only: only,
            skip: skip,
            container: .project("TestDemo.xcodeproj"),
            passThrough: passThrough
        )
    }

    // MARK: - The command lines

    @Test
    func theBuildNamesTheSchemeThePlanAndTheDestination() throws {
        let arguments = try makeRun(passThrough: ["-configuration", "Debug"])
            .buildForTestingArguments(resultBundle: URL(fileURLWithPath: "/scratch/build.xcresult"))

        #expect(arguments == [
            "xcodebuild", "build-for-testing",
            "-project", "TestDemo.xcodeproj",
            "-scheme", "TestDemo",
            "-testPlan", "Default",
            "-destination", "platform=iOS Simulator,name=iPhone 17,OS=27.0",
            "-resultBundlePath", "/scratch/build.xcresult",
            "-configuration", "Debug",
        ])
    }

    @Test
    func aWorkspaceStandsWhereTheProjectWould() throws {
        let run = try TestInvocation(scheme: "TestDemo", deviceType: "iPhone 17", osVersion: "27.0", container: .workspace("Demo.xcworkspace"))

        #expect(run.buildForTestingArguments(resultBundle: URL(fileURLWithPath: "/scratch/build.xcresult")) == [
            "xcodebuild", "build-for-testing",
            "-workspace", "Demo.xcworkspace",
            "-scheme", "TestDemo",
            "-destination", "platform=iOS Simulator,name=iPhone 17,OS=27.0",
            "-resultBundlePath", "/scratch/build.xcresult",
        ])
    }

    @Test
    func theEnumerationTakesNoPassThrough() throws {
        let run = try makeRun(passThrough: ["-configuration", "Debug"], only: ["DemoUnitTests"], skip: ["DemoUITests/ItemListUITests"])

        let arguments = run.enumerationArguments(
            xctestrun: URL(fileURLWithPath: "/build/Products/TestDemo_Default_iphonesimulator27.0-arm64.xctestrun"),
            outputPath: URL(fileURLWithPath: "/scratch/enumeration.json"),
            resultBundle: URL(fileURLWithPath: "/scratch/enumeration.xcresult")
        )

        #expect(arguments == [
            "xcodebuild", "test-without-building",
            "-xctestrun", "/build/Products/TestDemo_Default_iphonesimulator27.0-arm64.xctestrun",
            "-destination", "platform=iOS Simulator,name=iPhone 17,OS=27.0",
            "-enumerate-tests",
            "-test-enumeration-style", "flat",
            "-test-enumeration-format", "json",
            "-test-enumeration-output-path", "/scratch/enumeration.json",
            "-resultBundlePath", "/scratch/enumeration.xcresult",
            "-only-testing:DemoUnitTests",
            "-skip-testing:DemoUITests/ItemListUITests",
        ])
    }

    /// A read of where the products went is asked in the terms the build was made in, or `-derivedDataPath` sends it to look in a directory that build never wrote to.
    @Test
    func theBuildSettingsReadCarriesThePassThroughThatDecidedWhereTheBuildWent() throws {
        let arguments = try makeRun(passThrough: ["-derivedDataPath", "build/derived"]).buildSettingsArguments

        #expect(arguments == [
            "xcodebuild", "-showBuildSettings", "-json",
            "-project", "TestDemo.xcodeproj",
            "-scheme", "TestDemo",
            "-destination", "platform=iOS Simulator,name=iPhone 17,OS=27.0",
            "-derivedDataPath", "build/derived",
        ])
    }

    @Test
    func aShardNamesItsDeviceItsTestsAndItsBundle() throws {
        let run = try makeRun(passThrough: ["-configuration", "Debug"], skip: ["DemoUITests"])
        let first = try #require(TestIdentifier(enumerated: "DemoUnitTests/CalculatorTests/testAddition()"))
        let second = try #require(TestIdentifier(enumerated: "DemoUnitTests/MathSuite/addsTwoNumbers()"))

        let arguments = run.shardArguments(
            xctestrun: URL(fileURLWithPath: "/build/Products/TestDemo_Default_iphonesimulator27.0-arm64.xctestrun"),
            deviceUDID: "9C3F0A11-0000-4000-8000-000000000001",
            tests: [first, second],
            resultBundle: URL(fileURLWithPath: "/scratch/shard-1.xcresult")
        )

        #expect(arguments == [
            "xcodebuild", "test-without-building",
            "-xctestrun", "/build/Products/TestDemo_Default_iphonesimulator27.0-arm64.xctestrun",
            "-destination", "platform=iOS Simulator,id=9C3F0A11-0000-4000-8000-000000000001",
            "-parallel-testing-enabled", "NO",
            "-collect-test-diagnostics", "never",
            "-only-testing:DemoUnitTests/CalculatorTests/testAddition()",
            "-only-testing:DemoUnitTests/MathSuite/addsTwoNumbers()",
            "-resultBundlePath", "/scratch/shard-1.xcresult",
            "-configuration", "Debug",
        ])
        // A shard's list is explicit, so there is nothing left for an exclusion to subtract.
        #expect(!arguments.contains { $0.hasPrefix("-skip-testing") })
    }

    // MARK: - What the pass-through refuses

    @Test
    func aRefusedWordAsAnotherOptionsValueStands() throws {
        // `-configuration test` names a configuration. The bare word four places later names the action.
        #expect(throws: Never.self) {
            try makeRun(passThrough: ["-configuration", "test"])
        }
        #expect(throws: Never.self) {
            try makeRun(passThrough: ["-derivedDataPath", "build"])
        }

        let error = try #require(throws: TestInvocationError.self) {
            try makeRun(passThrough: ["test"])
        }
        #expect(error.description.contains("supplies the action itself"))
    }

    /// `-clonedSourcePackagesDirPath` takes a value, so the word behind it is that path, never the action `refuse` would otherwise misread it as — the pass-through still owes a refusal for `-destination` itself, but never for `build`.
    @Test
    func aClonedSourcePackagesDirPathValueIsNotRefusedAsAnAction() throws {
        let error = try #require(throws: TestInvocationError.self) {
            try makeRun(passThrough: ["-clonedSourcePackagesDirPath", "build", "-destination", "x"])
        }
        guard case .destination = error else {
            Issue.record("expected a destination refusal, got \(error)")
            return
        }
    }

    /// An option this table has never heard of does not get to swallow the word behind it — the direction that would let a refused flag ride through unread.
    ///
    /// `-someFlagThisTableHasNeverHeardOf` is not `-derivedDataPath`: nothing here says it takes a value, so `-destination` behind it is still checked and still refused.
    @Test
    func aRefusedWordBehindAnUnknownFlagIsStillRefused() throws {
        let error = try #require(throws: TestInvocationError.self) {
            try makeRun(passThrough: ["-someFlagThisTableHasNeverHeardOf", "-destination"])
        }

        #expect(error.description.contains("-destination"))
    }

    /// The pass-through can carry an unknown valueless flag ahead of a refused one — `xcodebuild`'s own `-disable-concurrent-destination-testing` is real and takes no value, but this table does not have to know that to still catch `-resultBundlePath` standing behind it.
    @Test
    func aRefusedFlagBehindAnUnknownValuelessFlagIsRefused() throws {
        let error = try #require(throws: TestInvocationError.self) {
            try makeRun(passThrough: ["-disable-concurrent-destination-testing", "-resultBundlePath", "x"])
        }

        #expect(error.description.contains("-resultBundlePath"))
    }

    @Test
    func everyWordAShortFlagAlreadyNamesIsRefused() throws {
        let refused = [
            ["build-for-testing"],
            ["test-without-building"],
            ["clean"],
            ["archive"],
            ["analyze"],
            ["-destination", "platform=iOS Simulator,name=iPhone 17"],
            ["-only-testing:DemoUnitTests"],
            ["-skip-testing:DemoUnitTests"],
            ["-testPlan", "Excluding"],
            ["-scheme", "Other"],
            ["-project", "Other.xcodeproj"],
            ["-workspace", "Other.xcworkspace"],
            ["-xctestrun", "Other.xctestrun"],
            ["-resultBundlePath", "/tmp/other.xcresult"],
            ["-parallel-testing-enabled", "YES"],
            ["-parallel-testing-enabled", "NO"],
            ["-collect-test-diagnostics", "always"],
            ["-enumerate-tests"],
        ]

        for passThrough in refused {
            let error = try #require(throws: TestInvocationError.self) {
                try makeRun(passThrough: passThrough)
            }
            // Each refusal names the word it turned away, so a reader can see which one it was.
            #expect(error.description.contains(passThrough[0]))
        }
    }

    @Test
    func eachRefusalSaysWhichFlagAlreadyCoversTheWord() throws {
        let parallel = try #require(throws: TestInvocationError.self) {
            try makeRun(passThrough: ["-parallel-testing-enabled", "YES"])
        }
        let diagnostics = try #require(throws: TestInvocationError.self) {
            try makeRun(passThrough: ["-collect-test-diagnostics", "always"])
        }
        let plan = try #require(throws: TestInvocationError.self) {
            try makeRun(passThrough: ["-testPlan", "Excluding"])
        }

        #expect(parallel.description.contains("-parallel-testing-enabled NO"))
        #expect(diagnostics.description.contains("-collect-test-diagnostics never"))
        #expect(plan.description.contains("--plan already names the test plan"))
    }

    @Test
    func aSelectorThatNamesNoSetOfTestsIsRefused() throws {
        #expect(throws: Never.self) {
            try makeRun(only: ["DemoUnitTests", "DemoUnitTests/CalculatorTests", "DemoUnitTests/CalculatorTests/testAddition()"])
        }
        // A target may carry spaces, and `-only-testing:` was measured to want them as they are (17 Sep 2026, `Demo Spaced Tests`).
        #expect(throws: Never.self) {
            try makeRun(only: ["Demo Spaced Tests", "Demo Spaced Tests/SpacedTests/testCountsUp()"])
        }

        let error = try #require(throws: TestInvocationError.self) {
            try makeRun(only: ["DemoUnitTests/CalculatorTests/testAddition()/extra"])
        }
        #expect(error.description.contains("--only"))

        #expect(throws: TestInvocationError.self) {
            try makeRun(skip: [" DemoUnitTests"])
        }
        #expect(throws: TestInvocationError.self) {
            try makeRun(skip: [""])
        }
        #expect(throws: TestInvocationError.self) {
            try makeRun(skip: ["-only-testing:DemoUnitTests"])
        }
    }

    // MARK: - Reading what the build wrote

    @Test
    func thePlansOwnFileIsChosenBySegmentNotPrefix() throws {
        let names = [
            "TestDemo_Default_iphonesimulator27.0-arm64.xctestrun",
            "TestDemo_DefaultFast_iphonesimulator27.0-arm64.xctestrun",
            "TestDemo_Excluding_iphonesimulator27.0-arm64.xctestrun",
            "TestDemo_Retrying_iphonesimulator27.0-undefined_arch.xctestrun",
        ]

        let chosen = try TestInvocation.xctestrunName(among: names, plan: "Default")
        let longer = try TestInvocation.xctestrunName(among: names, plan: "DefaultFast")
        let retrying = try TestInvocation.xctestrunName(among: names, plan: "Retrying")

        #expect(chosen == "TestDemo_Default_iphonesimulator27.0-arm64.xctestrun")
        #expect(longer == "TestDemo_DefaultFast_iphonesimulator27.0-arm64.xctestrun")
        #expect(retrying == "TestDemo_Retrying_iphonesimulator27.0-undefined_arch.xctestrun")
    }

    @Test
    func noFileForThePlanNamesWhatWasThere() throws {
        let names = ["TestDemo_Excluding_iphonesimulator27.0-arm64.xctestrun", "TestDemo.app"]

        let error = try #require(throws: TestInvocationError.self) {
            try TestInvocation.xctestrunName(among: names, plan: "Default")
        }

        #expect(error.description.contains("TestDemo_Excluding_iphonesimulator27.0-arm64.xctestrun"))
        #expect(!error.description.contains("TestDemo.app"))
    }

    @Test
    func twoFilesForOnePlanNamesBoth() throws {
        let names = [
            "TestDemo_Default_iphonesimulator27.0-arm64.xctestrun",
            "TestDemo_Default_iphonesimulator26.0-arm64.xctestrun",
        ]

        let error = try #require(throws: TestInvocationError.self) {
            try TestInvocation.xctestrunName(among: names, plan: "Default")
        }

        #expect(error.description.contains("iphonesimulator26.0"))
        #expect(error.description.contains("iphonesimulator27.0"))
    }

    @Test
    func buildDirectoryIsWhereTheProductsSit() throws {
        let json = """
        [{"target":"Demo","buildSettings":{"BUILD_DIR":"/derived/Build/Products","SDKROOT":"iphonesimulator"}},
        {"target":"DemoUnitTests","buildSettings":{"BUILD_DIR":"/derived/Build/Products"}}]
        """

        let directory = try TestInvocation.buildDirectory(inBuildSettings: Data(json.utf8))

        #expect(directory == "/derived/Build/Products")
    }

    @Test
    func buildSettingsWithNoBuildDirectoryAreRefused() throws {
        let error = try #require(throws: TestInvocationError.self) {
            try TestInvocation.buildDirectory(inBuildSettings: Data(#"[{"buildSettings":{"SDKROOT":"iphonesimulator"}}]"#.utf8))
        }

        #expect(error.description.contains("named no BUILD_DIR"))

        #expect(throws: TestInvocationError.self) {
            try TestInvocation.buildDirectory(inBuildSettings: Data("** BUILD FAILED **".utf8))
        }
    }

    @Test
    func twoBuildDirectoriesAreRefused() throws {
        let json = """
        [{"buildSettings":{"BUILD_DIR":"/one/Build/Products"}},{"buildSettings":{"BUILD_DIR":"/two/Build/Products"}}]
        """

        let error = try #require(throws: TestInvocationError.self) {
            try TestInvocation.buildDirectory(inBuildSettings: Data(json.utf8))
        }

        #expect(error.description.contains("/one/Build/Products"))
        #expect(error.description.contains("/two/Build/Products"))
    }

    @Test
    func anAbsolutePathReplacesTheDirectoryRatherThanJoiningIt() {
        let directory = URL(fileURLWithPath: "/scratch/run-1")

        #expect(TestInvocation.absoluteURL("/tmp/shard-1.xcresult", relativeTo: directory).path == "/tmp/shard-1.xcresult")
        #expect(TestInvocation.absoluteURL("shard-1.xcresult", relativeTo: directory).path == "/scratch/run-1/shard-1.xcresult")
    }
}
