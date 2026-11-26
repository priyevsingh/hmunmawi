import CryptoKit
import Foundation
import Testing
@testable import HmunmawiApp
@testable import HmunmawiCore

@MainActor
@Suite struct SmartAutopilotTests {
    private func policy() -> (AgentPolicy, UserDefaults, SymmetricKey) {
        let d = UserDefaults(suiteName: "hm-smart-\(UUID().uuidString)")!
        let p = AgentPolicy(defaults: d)
        let key = SymmetricKey(size: .bits256)
        p.signCurrent(key)
        return (p, d, key)
    }

    @Test func smartAutopilotIsHMACSignedAndRespectsOverrides() {
        let (p, d, key) = policy()
        p.setSmartAutopilot(true)
        #expect(AgentPolicy(defaults: d).verify(key))
        #expect(p.allowsSmart(command: "routine-run", args: [:], need: .routines, agent: "My Bot"))
        #expect(p.allowsSmart(command: "subscribers-add", args: [:], need: .routines, agent: "My Bot"))
        #expect(p.allowsSmart(command: "shield-fix", args: ["item": "build"], need: .releases, agent: "My Bot"))
        #expect(p.allowsSmart(command: "shield-fix", args: ["item": "promo"], need: .releases, agent: "My Bot"))
        #expect(p.allowsSmart(command: "set", args: ["key": "project"], need: nil, agent: "My Bot"))

        // Critical or non-smart commands are refused by allowsSmart
        #expect(!p.allowsSmart(command: "shield-fix", args: ["item": "submit"], need: .releases, agent: "My Bot"))
        #expect(!p.allowsSmart(command: "deploy-redeploy", args: [:], need: .releases, agent: "My Bot"))
        #expect(!p.allowsSmart(command: "outreach-send", args: [:], need: .messages, agent: "My Bot"))
        #expect(!p.allowsSmart(command: "release-notify-draft", args: [:], need: .messages, agent: "My Bot"))
        #expect(!p.allowsSmart(command: "review-reply", args: [:], need: .releases, agent: "My Bot"))
        #expect(!p.allowsSmart(command: "set-key", args: [:], need: .connections, agent: "My Bot"))
        #expect(!p.allowsSmart(command: "remove-connection", args: [:], need: .deletes, agent: "My Bot"))
        #expect(!p.allowsSmart(command: "publish", args: [:], need: .connections, agent: "My Bot"))

        // Unverified caller & per-agent "ask" override always block
        #expect(!p.allowsSmart(command: "routine-run", args: [:], need: .routines, agent: "Bot" + AgentPolicy.unverifiedSuffix))
        p.setRule(agent: "Strict Bot", .routines, "ask")
        #expect(!p.allowsSmart(command: "routine-run", args: [:], need: .routines, agent: "Strict Bot"))

        // Tampering with UserDefaults breaks signature
        d.set(false, forKey: "HMAgentSmartAutopilot")
        let tampered = AgentPolicy(defaults: d)
        #expect(!tampered.verify(key))
    }

    @Test func alwaysAskGatesAllCriticalCommands() {
        for cmd in ["deploy-redeploy", "python-repair", "outreach-send", "release-notify-draft", "review-reply", "set-key",
                    "publish", "remove-connection", "routine-remove", "change-remove", "plan-remove"] {
            #expect(AgentBridge.isAlwaysAsk(command: cmd, args: [:]), "\(cmd) must be alwaysAsk")
        }
        #expect(AgentBridge.isAlwaysAsk(command: "shield-fix", args: ["item": "submit"]))
        #expect(AgentBridge.isAlwaysAsk(command: "shield-fix", args: ["item": " Submit "]))
        #expect(!AgentBridge.isAlwaysAsk(command: "shield-fix", args: ["item": "build"]))
        #expect(!AgentBridge.isAlwaysAsk(command: "routine-run", args: [:]))
    }

    @Test func approveAllNonCriticalSkipsEveryAlwaysAskJob() {
        func job(_ kind: String, payload: JSONValue) -> Job {
            Job(id: 1, kind: kind, resource: "agent", priority: 3, state: .waitingApproval, attempts: 0, maxAttempts: 1, runAfter: 0, payload: payload)
        }
        #expect(AppModel.isCriticalWaiting(job("outreach.send", payload: .object([:]))))
        #expect(AppModel.isCriticalWaiting(job("release.notify", payload: .object([:]))))
        #expect(AppModel.isCriticalWaiting(job("review.reply", payload: .object([:]))))
        #expect(AppModel.isCriticalWaiting(job("asc.fix", payload: .object(["fix": .string("submit")]))))
        #expect(AppModel.isCriticalWaiting(job("agent.request", payload: .object(["command": .string("set-key")]))))
        #expect(AppModel.isCriticalWaiting(job("agent.request", payload: .object(["command": .string("release-notify-draft")]))))
        #expect(AppModel.isCriticalWaiting(job("agent.request", payload: .object(["command": .string("deploy-redeploy")]))))
        #expect(AppModel.isCriticalWaiting(job("agent.request", payload: .object(["command": .string("python-repair")]))))
        #expect(AppModel.isCriticalWaiting(job("agent.request", payload: .object(["command": .string("publish")]))))
        #expect(AppModel.isCriticalWaiting(job("agent.request", payload: .object(["command": .string("remove-connection")]))))
        #expect(AppModel.isCriticalWaiting(job("agent.request", payload: .object(["command": .string("shield-fix"), "args": .object(["item": .string("submit")])]))))

        #expect(!AppModel.isCriticalWaiting(job("agent.request", payload: .object(["command": .string("routine-run")]))))
        #expect(!AppModel.isCriticalWaiting(job("agent.request", payload: .object(["command": .string("shield-fix"), "args": .object(["item": .string("build")])]))))
        #expect(!AppModel.isCriticalWaiting(job("notify", payload: .object([:]))))
    }

    @Test func shieldChecklistClassifiesReversibleAndManualItems() {
        let report: JSONValue = .object([
            "app_name": .string("Pulse Diary"),
            "version": .string("2.0"),
            "version_id": .string("v2"),
            "live_version_id": .string("v1"),
            "state": .string("PREPARE_FOR_SUBMISSION"),
            "items": .array([
                .object(["id": .string("build"), "ok": .bool(false), "level": .string("block"), "title": .string("Build")]),
                .object(["id": .string("promo"), "ok": .bool(false), "level": .string("warn"), "title": .string("Promo")]),
                .object(["id": .string("privacy"), "ok": .bool(false), "level": .string("manual"), "title": .string("App Privacy")]),
                .object(["id": .string("description"), "ok": .bool(true), "level": .string("block"), "title": .string("Description")]),
            ]),
        ])
        let c = ShieldChecklist.build(report: report, fixedIDs: [])
        #expect(c.reversibleIDs == ["build", "promo"])
        #expect(c.manualTitles == ["App Privacy"])
        #expect(!c.canSubmit)
    }

    @Test func ruleNudgesAndPlaybookBriefs() {
        let dryRule = Rule(id: "r1", when: "revenue.refund", actions: [RuleAction(action: "notify", resource: "imessage")],
                           approval: .auto, dryRun: true, enabled: true)
        #expect(!RuleText.shouldNudgeToAutopilot(dryRule, stat: nil))
        #expect(RuleText.shouldNudgeToAutopilot(dryRule, stat: RuleStat(count: 2, last: 1_794_000_000_000)))

        let askNotify = Rule(id: "low-review-alert", when: "review.new", actions: [RuleAction(action: "notify", resource: "ntfy")],
                             approval: .ask, dryRun: false, enabled: true)
        #expect(RuleText.shouldNudgeToAutopilot(askNotify, stat: nil))

        let autoNotify = Rule(id: "r3", when: "review.new", actions: [RuleAction(action: "notify", resource: "ntfy")],
                              approval: .auto, dryRun: false, enabled: true)
        #expect(!RuleText.shouldNudgeToAutopilot(autoNotify, stat: nil))

        let s = Suggestion(id: "page|example.com|/guide", kind: .pageTitle, app: "example.com",
                           title: "/guide: seen 500 times at position 4.2, clicked 3",
                           why: "Below site CTR", action: "Rewrite its title and description.",
                           score: 0.5, metric: 3, higherIsBetter: true)
        let brief = Playbook.taskBrief(for: s)
        #expect(brief.contains("example.com") && brief.contains("Rewrite its title") && brief.contains("lint-text"))

        let rp = ReviewDrafter.prompt(app: "Pulse Diary", rating: 2, title: "Crashes", body: "Fails on launch")
        #expect(rp.contains("<<<") && rp.contains("city, state, or country"))
    }
}
