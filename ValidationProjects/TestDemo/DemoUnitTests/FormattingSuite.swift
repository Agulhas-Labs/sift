import Testing

@Suite("Formatting")
struct FormattingSuite {
    @Test func formatsUppercase() {
        #expect("demo".uppercased() == "DEMO")
    }

    @Test func formatsJoinedList() {
        #expect(["a", "b"].joined(separator: ",") == "a,b")
    }

    @Test func aKnownFormattingIssuePasses() {
        withKnownIssue("formatting rounding is tracked separately") {
            #expect(0.1 + 0.2 == 0.3)
        }
    }
}
