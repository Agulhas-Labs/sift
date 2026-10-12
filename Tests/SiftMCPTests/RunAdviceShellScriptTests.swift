//
// Copyright © Agulhas Labs
//

@testable import SiftMCP
import Testing

/// A gate split across a quoted shell script is still a split gate.
///
/// The quoted script is one token on the outer line, so the second half is only found by reading inside it; nothing inside is rewritten.
struct RunAdviceShellScriptTests {
    /// The build half beside a quoted second half is read as the unwrapped line is.
    @Test
    func aTestLegInsideAShellScriptMakesTheBuildLegAGateLeg() {
        let plain = "xcodebuild build-for-testing -scheme GK && xcodebuild test-without-building -scheme GK"
        for shell in ["bash", "sh", "zsh"] {
            let quoted = "xcodebuild build-for-testing -scheme GK && \(shell) -c 'xcodebuild test-without-building -scheme GK'"
            #expect(RunAdvice.suggestion(for: quoted) == nil)
            #expect(RunAdvice.silencedAsAGateLeg(quoted))
            #expect(RunAdvice.silencedAsAGateLeg(quoted) == RunAdvice.silencedAsAGateLeg(plain))
        }
    }

    /// A script that holds no test leg leaves the build leg a lone build.
    @Test
    func aShellScriptWithoutATestLegLeavesTheLoneBuildWrapped() {
        let line = "xcodebuild build-for-testing -scheme GK && bash -c 'echo hi'"

        #expect(RunAdvice.suggestion(for: line) != nil)
    }

    /// A clustered flag or a wrapper before the shell does not hide the script.
    @Test
    func aClusteredFlagOrAWrapperStillExposesTheTestLeg() {
        let build = "xcodebuild build-for-testing -scheme GK && "
        let test = "'xcodebuild test-without-building -scheme GK'"
        for shell in ["bash -lc", "bash -ec", "zsh -euxc", "env CI=1 bash -c", "nohup sh -c", "exec bash -l -c"] {
            let line = build + shell + " " + test
            #expect(RunAdvice.suggestion(for: line) == nil, "\(line)")
            #expect(RunAdvice.silencedAsAGateLeg(line), "\(line)")
        }
    }

    /// A clustered flag with no test leg in the script is still a lone build.
    @Test
    func aClusteredFlagScriptWithoutATestLegLeavesTheLoneBuildWrapped() {
        let line = "xcodebuild build-for-testing -scheme GK && bash -lc 'echo hi'"

        #expect(RunAdvice.suggestion(for: line) != nil)
    }

    /// A bare double dash after the flag ends the options, and the next word is still the script.
    @Test
    func aDoubleDashAfterTheCommandFlagStillExposesTheTestLeg() {
        let build = "xcodebuild build-for-testing -scheme GK && "
        let test = "'xcodebuild test-without-building -scheme GK'"
        for shell in ["sh -c --", "bash -c --", "zsh -c --", "bash -lc --"] {
            let line = build + shell + " " + test
            #expect(RunAdvice.suggestion(for: line) == nil, "\(line)")
            #expect(RunAdvice.silencedAsAGateLeg(line), "\(line)")
        }
    }

    /// A lone dash after the flag ends the options as a double dash does, and the next word is still the script.
    @Test
    func aLoneDashAfterTheCommandFlagStillExposesTheTestLeg() {
        let build = "xcodebuild build-for-testing -scheme GK && "
        let test = "'xcodebuild test-without-building -scheme GK'"
        for shell in ["sh -c -", "bash -c -", "zsh -c -", "bash -lc -"] {
            let line = build + shell + " " + test
            #expect(RunAdvice.suggestion(for: line) == nil, "\(line)")
            #expect(RunAdvice.silencedAsAGateLeg(line), "\(line)")
        }
    }

    /// A word after a leading double dash is the shell's script file, not a flag, so it is no script text.
    @Test
    func aDoubleDashBeforeTheFlagMakesTheFlagAFileName() {
        let build = "xcodebuild build-for-testing -scheme GK && "
        let test = "'xcodebuild test-without-building -scheme GK'"
        for shell in ["sh -- -c", "bash -- -c", "zsh -- -c"] {
            let line = build + shell + " " + test
            #expect(RunAdvice.suggestion(for: line) != nil, "\(line)")
            #expect(!RunAdvice.silencedAsAGateLeg(line), "\(line)")
        }
    }

    /// A word after a double dash with no command flag is a script file, never script text.
    @Test
    func aDoubleDashThenAWordWithoutTheCommandFlagIsAScriptFile() {
        let line = "xcodebuild build-for-testing -scheme GK && sh -- 'xcodebuild test-without-building -scheme GK'"

        #expect(RunAdvice.suggestion(for: line) != nil)
        #expect(!RunAdvice.silencedAsAGateLeg(line))
    }
}
