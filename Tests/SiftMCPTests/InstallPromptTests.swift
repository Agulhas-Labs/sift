//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore
import Testing

/// How `sift install` reads each `[Y/n]` answer, and which agents a run of answers accepts, with every question it asked.
struct InstallPromptTests {
    static let answers: [(String?, InstallPrompt.Answer)] = [
        ("", .accept), ("\n", .accept), ("y", .accept), ("Y", .accept), ("yes", .accept), ("YES", .accept), (" Yes \n", .accept),
        ("n", .decline), ("N", .decline), ("no", .decline), ("No", .decline), (" NO ", .decline),
        (nil, .ended),
        ("maybe", .unclear), ("yep", .unclear), ("nope", .unclear), ("q", .unclear),
    ]

    @Test(arguments: answers)
    func eachAnswerReads(_ line: String?, _ expected: InstallPrompt.Answer) {
        #expect(InstallPrompt.answer(line) == expected)
    }

    @Test
    func eachAgentIsAskedOnceAndAnEmptyAnswerIsYes() {
        let script = Script(["", "n", "y"])

        #expect(script.prompt.choose(InstallAgent.allCases) == [.claude, .codex])
        #expect(script.asked == InstallAgent.allCases.map(InstallPrompt.question))
        #expect(script.asked.first == "Install sift into Claude Code? [Y/n] ")
    }

    @Test
    func anUnclearAnswerIsAskedAgainOnce() {
        let script = Script(["maybe", "y"])

        #expect(script.prompt.choose([.cursor]) == [.cursor])
        #expect(script.asked == [InstallPrompt.question(.cursor), "Please answer y or n. Install sift into Cursor? [Y/n] "])
    }

    @Test
    func twoUnclearAnswersAreNoAndTheNextAgentIsStillAsked() {
        let script = Script(["maybe", "what", "y"])

        #expect(script.prompt.choose([.claude, .codex]) == [.codex])
        #expect(script.asked == [InstallPrompt.question(.claude), InstallPrompt.retry(.claude), InstallPrompt.question(.codex)])
    }

    @Test
    func theEndOfInputDeclinesTheRestUnasked() {
        let script = Script(["y"])

        #expect(script.prompt.choose(InstallAgent.allCases) == [.claude])
        #expect(script.asked == [InstallPrompt.question(.claude), InstallPrompt.question(.cursor)])
    }

    @Test
    func theEndOfInputOnTheSecondAskIsNoAndStops() {
        let script = Script(["maybe"])

        #expect(script.prompt.choose([.claude, .codex]).isEmpty)
        #expect(script.asked == [InstallPrompt.question(.claude), InstallPrompt.retry(.claude)])
    }
}

extension InstallPromptTests {
    /// Stands in for the person at the terminal: gives the scripted answers in turn, the end of input once they run out, and keeps every question.
    private final class Script: @unchecked Sendable {
        private let lock = NSLock()
        private var answers: [String?]
        private var askedQuestions: [String] = []

        init(_ answers: [String?]) {
            self.answers = answers
        }

        var asked: [String] {
            lock.withLock { askedQuestions }
        }

        var prompt: InstallPrompt {
            InstallPrompt { question in
                self.lock.withLock {
                    self.askedQuestions.append(question)
                    return self.answers.isEmpty ? nil : self.answers.removeFirst()
                }
            }
        }
    }
}
