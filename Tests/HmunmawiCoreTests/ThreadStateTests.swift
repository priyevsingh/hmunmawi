import Testing
@testable import HmunmawiCore

@Suite struct ThreadStateTests {
    /// A podcaster: a coverage promise, then thanks that keeps it.
    @Test func podcasterPromiseThenThanks() {
        let first = ThreadState.read("Thanks, Sam! This is exactly the kind of app I'd use in the morning. Downloading now to test it out and consider for possible inclusion in a future listener-apps episode. Thanks for sending it!\n\nBest,\n-Alex")
        #expect(first.state == .promised && first.promise == .coverage)
        let second = ThreadState.read("Thank you! I'm looking forward to checking it out!\n\nBest,\n\n-Alex")
        let after = ThreadState.next(after: .promised, currentPromise: .coverage, reading: second)
        #expect(after.0 == .promised && after.1 == .coverage)
        #expect(ThreadState.checkBack(.promised, promise: .coverage) == 90)
    }

    @Test func clearCases() {
        #expect(ThreadState.read("Thanks for reaching out. Could you send over a press kit and a few screenshots").state == .yourTurn)
        #expect(ThreadState.read("Thanks! When does the update ship?").state == .yourTurn)
        #expect(ThreadState.read("Appreciate it, but this isn't a fit for us right now. Not a fit.").state == .declined)
        #expect(ThreadState.read("I'm not the right person for this, please write to reviews@example.com").state == .referred)
        #expect(ThreadState.read("Great, we'll feature it in next Tuesday's roundup").state == .scheduled)
        #expect(ThreadState.read("Thanks!").state == .thanks)
        #expect(ThreadState.read("Will give it a try this weekend.").promise == .testing)
        #expect(ThreadState.read("Hmm, interesting idea.").state == .unclear)
    }

    @Test func robots() {
        #expect(ThreadState.isRobot("mailer@podcast.example"))
        #expect(ThreadState.isRobot("no-reply@accounts.example.com"))
        #expect(!ThreadState.isRobot("feedback@podcast.example"))
    }
}
