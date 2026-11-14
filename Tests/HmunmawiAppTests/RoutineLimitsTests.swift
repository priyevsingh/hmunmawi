import Testing
@testable import HmunmawiApp

@Suite struct RoutineLimitsTests {
    @Test func savedNumbersCantCrashOrUncap() {
        #expect(Routines.finite("inf") == nil && Routines.finite("nan") == nil && Routines.finite("3") == 3)
        var r = MyRoutine(); r.params = ["cap": "inf"]
        #expect(Routines.cap(r, 2) == 2)                       // an endless cap falls back, never unlimited
        r.params = ["cap": "1e308"]
        #expect(Routines.cap(r, 2) == 1000)
    }
}

@Suite struct AgentPauseArgsTests {
    @Test func accountNamesAreChecked() {
        #expect(AgentBridge.aiAccount(nil) == "team" && AgentBridge.aiAccount("team_2") == "team_2")
        #expect(AgentBridge.aiAccount("../etc") == nil && AgentBridge.aiAccount(String(repeating: "a", count: 40)) == nil)
    }
}
