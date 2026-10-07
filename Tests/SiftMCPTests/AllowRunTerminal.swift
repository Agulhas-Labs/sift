//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI

/// Stands in for the person at the terminal, keeping every question asked and giving one answer to each.
final class AllowRunTerminal: @unchecked Sendable {
    private let lock = NSLock()
    private var askedQuestions: [String] = []
    private let answer: String?

    init(answer: String?) {
        self.answer = answer
    }

    var asked: [String] {
        lock.withLock { askedQuestions }
    }

    func prompt(interactive: Bool) -> AllowRunPrompt {
        AllowRunPrompt(isInteractive: interactive) { question in
            self.lock.withLock { self.askedQuestions.append(question) }
            return self.answer
        }
    }
}
