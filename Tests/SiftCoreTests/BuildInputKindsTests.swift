//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Which changed paths count as something a build reads, so a green run of one tree stands for another only when nothing but the rest differs.
struct BuildInputKindsTests {
    @Test(arguments: [
        "Sources/App/A.swift", "Sources/C/include/a.h", "Sources/C/a.hpp", "Sources/C/a.m", "Sources/C/a.mm",
        "Sources/C/a.c", "Sources/C/a.cc", "Sources/C/a.cpp", "Sources/App/Shader.metal", "Sources/C/module.modulemap",
    ])
    func eachSourceKindIsAnInput(path: String) {
        #expect(TreeKey.isBuildInput(path))
    }

    @Test(arguments: [
        "Package.swift", "Package@swift-5.9.swift", "Package.resolved", "Config/Base.xcconfig",
        "App.xcodeproj/project.pbxproj", "App.xcodeproj/xcshareddata/xcschemes/App.xcscheme",
        "App.xcworkspace/contents.xcworkspacedata", "project.yml", "project.yaml",
    ])
    func eachManifestAndBuildSettingIsAnInput(path: String) {
        #expect(TreeKey.isBuildInput(path))
    }

    @Test(arguments: [
        "App/Info.plist", "App/App.entitlements", "App/Assets.xcassets/Icon.appiconset/icon.png", "App/Assets.xcassets/Contents.json",
        "App/en.lproj/Localizable.strings", "App/Localizable.stringsdict", "App/Localizable.xcstrings",
        "App/Main.storyboard", "App/View.xib", "App/Model.xcdatamodeld/Model.xcdatamodel/contents",
        "App/Model.xcdatamodeld/.xccurrentversion", "App/Intents.intentdefinition",
    ])
    func eachCompiledResourceIsAnInput(path: String) {
        #expect(TreeKey.isBuildInput(path))
    }

    @Test(arguments: [
        "README.md", "Docs/Design.md", "notes.txt", ".gitignore", ".github/workflows/x.yml", "art/logo.png",
        "Package.swift.orig", "swift", "Scripts/build.sh", "Makefile",
    ])
    func everythingElseIsNot(path: String) {
        #expect(!TreeKey.isBuildInput(path))
    }
}
