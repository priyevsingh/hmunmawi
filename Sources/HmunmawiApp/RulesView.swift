import HmunmawiCore
import SwiftUI

/// Rules in plain sentences ("When a refund arrives → text me"), as a native form: each rule has its mode
/// and a switch; ready-made rules are one click; New Rule… builds one from menus, no codes.
struct RulesEditor: View {
    let model: AppModel
    @State private var building = false

    var body: some View {
        let rules = model.config.rules
        Form {
            AgentsSection()
            Section {
                if rules.isEmpty { Text("No rules yet. Hmunmawi is twiddling its thumbs, awaiting orders").foregroundStyle(.secondary) }
                ForEach(rules) { rule in
                    RuleRow(rule: rule, stat: model.ruleStats[rule.id]) { updated in
                        Task { await model.setRules(rules.map { $0.id == updated.id ? updated : $0 }) }
                    } onDelete: {
                        Task { await model.setRules(rules.filter { $0.id != rule.id }) }
                    }
                }
            } header: {
                HStack {
                    Text("Your Rules")
                    Spacer()
                    Button("New Rule") { building = true }
                }
            } footer: {
                Text("When something happens, Hmunmawi tells you or acts for you. \u{201C}Try out\u{201D} records what it would do and sends nothing.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(RuleTemplates.groups, id: \.title) { group in
                Section(group.title) {
                    ForEach(group.rules) { template in
                        let added = rules.contains { $0.id == template.id }
                        LabeledContent {
                            Button(added ? "Added" : "Add") { Task { await model.setRules(rules + [template]) } }
                                .disabled(added)
                        } label: {
                            Label(RuleText.sentence(template), systemImage: RuleText.symbol(template.when))
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $building) {
            RuleBuilder(apps: apps) { rule in Task { await model.setRules(rules + [rule]) } }
        }
    }

    private var apps: [String] { model.snapshots("app.snapshot").compactMap(\.app) }
}

private struct RuleRow: View {
    let rule: Rule
    let stat: RuleStat?
    let onChange: (Rule) -> Void
    let onDelete: () -> Void

    var body: some View {
        LabeledContent {
            HStack(spacing: 10) {
                Picker("Mode", selection: Binding(get: { RuleText.mode(rule) }, set: { m in
                    var r = rule
                    r.dryRun = m == "Try out"
                    if m != "Try out" { r.approval = m == "Autopilot" ? .auto : .ask }
                    onChange(r)
                })) {
                    Text("Autopilot").tag("Autopilot")
                    Text("Hands-on").tag("Hands-on")
                    Text("Try out").tag("Try out")
                }
                .labelsHidden().fixedSize()
                Toggle("On", isOn: Binding(get: { rule.enabled }, set: { var r = rule; r.enabled = $0; onChange(r) }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
        } label: {
            Label {
                Text(RuleText.sentence(rule))
                Text(stat.map { "Fired \($0.count)× · last \(Ago.text(millis: $0.last))" } ?? "Hasn\u{2019}t fired yet")
            } icon: { Image(systemName: RuleText.symbol(rule.when)) }
        }
        .contextMenu { Button("Remove Rule", role: .destructive, action: onDelete) }
    }
}

/// The sentence builder: every part is picked from a menu, no codes to type.
private struct RuleBuilder: View {
    let apps: [String]
    let onSave: (Rule) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var when = RuleText.triggers[0].kind
    @State private var app = ""
    @State private var channel = "imessage"
    @State private var mode = "try"   // new rules start in Try out: they show what they would do until you switch them on
    @State private var stars: Set<Int> = [1, 2]
    @State private var countries = ""
    @State private var mentions = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New rule").font(.title2.weight(.bold))
            Form {
                Picker("When", selection: $when) {
                    ForEach(RuleText.triggers, id: \.kind) { Label($0.name, systemImage: RuleText.symbol($0.kind)).tag($0.kind) }
                }
                if when == "review.new" {
                    LabeledContent("Stars") {
                        HStack(spacing: 4) {
                            ForEach(1...5, id: \.self) { n in
                                Button {
                                    if stars.contains(n) { if stars.count > 1 { stars.remove(n) } } else { stars.insert(n) }
                                } label: {
                                    Text("\(n)★").font(.callout.weight(.semibold)).monospacedDigit()
                                        .padding(.horizontal, 8).padding(.vertical, 4)
                                        .background(Capsule().fill(stars.contains(n) ? Color.yellow.opacity(0.35) : Color.secondary.opacity(0.1)))
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("\(n) star reviews")
                                .accessibilityAddTraits(stars.contains(n) ? .isSelected : [])
                            }
                        }
                    }
                    TextField("Countries", text: $countries, prompt: Text("All, or e.g. IND, USA"))
                        .input(.list, $countries).accessibilityLabel("Only reviews from these countries")
                    TextField("Mentions", text: $mentions, prompt: Text("Any words, or e.g. crash"))
                        .input(.text(80), $mentions).accessibilityLabel("Only reviews that mention this")
                }
                Picker("For", selection: $app) {
                    Text("Any app").tag("")
                    ForEach(apps, id: \.self) { Text($0).tag($0) }
                }
                Picker("Then", selection: $channel) {
                    Label("Text me on iMessage", systemImage: "message.fill").tag("imessage")
                    Label("Send a push (ntfy)", systemImage: "bell.badge.fill").tag("ntfy")
                }
                Picker("How", selection: $mode) {
                    Text("Do it automatically").tag("auto")
                    Text("Ask me first").tag("ask")
                    Text("Try out (send nothing)").tag("try")
                }
            }
            .formStyle(.grouped)
            let rule = draft
            Label(RuleText.sentence(rule), systemImage: "text.quote").font(.callout).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.pill).keyboardShortcut(.cancelAction)
                Button("Add rule") { onSave(rule); dismiss() }.buttonStyle(.pillProminent).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520)
    }

    private var conditions: [Condition] {
        var list: [Condition] = app.isEmpty ? [] : [Condition(field: "app", op: .eq, value: .string(app))]
        guard when == "review.new" else { return list }
        if stars.count < 5 { list.append(Condition(field: "rating", op: .oneOf, value: .array(stars.sorted().map { .number(Double($0)) }))) }
        let codes = countries.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).uppercased() }.filter { !$0.isEmpty }
        if !codes.isEmpty { list.append(Condition(field: "territory", op: .oneOf, value: .array(codes.map(JSONValue.string)))) }
        let words = mentions.trimmingCharacters(in: .whitespaces)
        if !words.isEmpty { list.append(Condition(field: "body", op: .contains, value: .string(words))) }
        return list
    }

    private var draft: Rule {
        Rule(id: "custom-\(UUID().uuidString.prefix(8))", name: nil, when: when,
             conditions: conditions,
             actions: [RuleAction(action: "notify", resource: channel)], priority: 3, cooldownSeconds: 0,
             approval: mode == "ask" ? .ask : .auto, dryRun: mode == "try", enabled: true)
    }
}

/// Plain words for rules: triggers, conditions, actions and modes.
enum RuleText {
    struct Trigger { let kind: String; let name: String }

    static let triggers: [Trigger] = [
        .init(kind: "revenue.purchase", name: "A new subscriber"), .init(kind: "revenue.renewal", name: "A renewal"),
        .init(kind: "revenue.refund", name: "A refund"), .init(kind: "revenue.cancelled", name: "A cancellation"),
        .init(kind: "revenue.billing_issue", name: "A billing problem"), .init(kind: "review.new", name: "A new review"),
        .init(kind: "story.win", name: "A win in today's story"), .init(kind: "story.worry", name: "A worry in today's story"),
        .init(kind: "story.digest", name: "The morning story"), .init(kind: "story.weekly", name: "The weekly digest"), .init(kind: "job.failed", name: "A Mac job fails"),
        .init(kind: "job.finished", name: "A Mac job finishes"),
        .init(kind: "job.attention", name: "A script says something needs a look"),
        .init(kind: "site.down", name: "The website goes down"), .init(kind: "disk.low", name: "Disk space runs low"),
        .init(kind: "offercodes.status", name: "Offer codes check (daily)"),
        .init(kind: "testflight.feedback", name: "A TestFlight tester sends feedback"),
        .init(kind: "expiry.status", name: "Expiry check (daily)"),
        .init(kind: "usage.status", name: "AI & subscription usage check"),
        .init(kind: "ci.build", name: "An Xcode Cloud build finishes"),
    ]

    static func name(_ kind: String) -> String { triggers.first { $0.kind == kind }?.name ?? kind }

    static func sentence(_ rule: Rule) -> String {
        let n = name(rule.when)
        // Lowercase the first letter only for ordinary words ("A refund" -> "a refund"), never for "AI" or "X".
        let keepCase = n.count > 1 && n.dropFirst().first?.isUppercase == true
        var when = "When " + (keepCase ? n : n.prefix(1).lowercased() + n.dropFirst())
        for c in rule.conditions {
            switch (c.field, c.op) {
            case ("app", .eq): when += " for \(c.value.string ?? "")"
            case ("rating", .lte): when += " rated \(Int(safe: c.value.number ?? 0)) stars or less"
            case ("family", .contains): when += " about \(c.value.string ?? "")"
            case ("rating", .oneOf):
                let n = c.value.array?.compactMap { $0.number.map { Int(safe: $0) } } ?? []
                when += " rated " + (n.count == 1 ? "\(n[0])" : n.dropLast().map(String.init).joined(separator: ", ") + " or \(n.last ?? 0)") + (n == [1] ? " star" : " stars")
            case ("territory", .oneOf): when += " from " + (c.value.array?.compactMap(\.string).joined(separator: ", ") ?? "")
            case ("body", .contains): when += " mentioning “\(c.value.string ?? "")”"
            case ("status", .oneOf): when += " and it failed"
            case ("used_percent", .gte): when += " finds a plan at \(Int(safe: c.value.number ?? 0))% or more"
            case ("days_left", .lte): when += " finds something expiring within \(Int(safe: c.value.number ?? 0)) days"
            case ("left", .lte): when += " finds \(Int(safe: c.value.number ?? 0)) codes or fewer left"
            case ("days_to_expiry", .lte): when += " finds a code expiring within \(Int(safe: c.value.number ?? 0)) days"
            default: when += " (\(c.field) \(c.op.rawValue) \(c.value.string ?? c.value.number.map { "\($0)" } ?? ""))"
            }
        }
        let does = rule.actions.map { a in
            a.action == "notify" ? (a.resource == "ntfy" ? "send me a push" : "text me on iMessage") : a.action.replacingOccurrences(of: ".", with: " ")
        }.joined(separator: " and ")
        return "\(when) → \(does)"
    }

    static func mode(_ rule: Rule) -> String {
        rule.dryRun ? "Try out" : rule.approval == .auto ? "Autopilot" : rule.approval == .ask ? "Hands-on" : "Never"
    }

    static func symbol(_ kind: String) -> String {
        switch kind {
        case "revenue.purchase": "bag.fill"
        case "revenue.renewal": "arrow.triangle.2.circlepath"
        case "revenue.refund", "revenue.cancelled": "arrow.uturn.backward"
        case "revenue.billing_issue": "creditcard.trianglebadge.exclamationmark"
        case "review.new": "star.fill"
        case "story.win": "sparkles"
        case "story.worry": "exclamationmark.triangle.fill"
        case "story.digest": "sunrise.fill"
        case "job.failed", "job.finished": "gearshape.2.fill"
        case "job.attention": "exclamationmark.bubble.fill"
        case "site.down": "globe"
        case "disk.low": "internaldrive.fill"
        case "offercodes.status": "ticket.fill"
        case "testflight.feedback": "airplane.departure"
        case "ci.build": "hammer.fill"
        case "expiry.status": "hourglass"
        case "usage.status": "gauge.with.dots.needle.67percent"
        default: "bolt.fill"
        }
    }

    static func tint(_ kind: String) -> Color {
        if kind.hasPrefix("revenue.") { return ["revenue.refund", "revenue.cancelled", "revenue.billing_issue"].contains(kind) ? Brand.bad : Brand.Category.money }
        if kind == "review.new" { return Brand.Category.users }
        if kind.hasPrefix("story.") { return kind == "story.worry" ? Brand.caution : Brand.Category.web }
        return Brand.Category.social
    }
}

/// The ready-made rules, in four groups.
enum RuleTemplates {
    struct Group { let title: String; let symbol: String; let tint: Color; let rules: [Rule] }

    static func notify(_ id: String, _ when: String, _ channel: String, _ conditions: [Condition] = [], cooldown: Int = 0) -> Rule {
        Rule(id: id, when: when, conditions: conditions, actions: [RuleAction(action: "notify", resource: channel)],
             priority: 3, cooldownSeconds: cooldown, approval: .auto, dryRun: true, enabled: true)   // added in Try out
    }

    static let groups: [Group] = [
        Group(title: "Money moments", symbol: "banknote.fill", tint: Brand.Category.money, rules: [
            notify("tpl-new-subscriber", "revenue.purchase", "imessage"),
            notify("refund-alert", "revenue.refund", "imessage"),
            notify("tpl-billing", "revenue.billing_issue", "imessage"),
        ]),
        // Worries the insight engine finds in the trends (each at most once a day).
        Group(title: "Trends", symbol: "chart.line.downtrend.xyaxis", tint: Brand.Category.money, rules: [
            notify("tpl-downloads-worry", "story.worry", "imessage", [Condition(field: "family", op: .contains, value: .string("downloads"))], cooldown: 86_400),
            notify("tpl-earnings-worry", "story.worry", "imessage", [Condition(field: "family", op: .contains, value: .string("proceeds"))], cooldown: 86_400),
        ]),
        Group(title: "Reputation", symbol: "star.fill", tint: Brand.Category.users, rules: [
            notify("low-review-alert", "review.new", "ntfy", [Condition(field: "rating", op: .lte, value: .number(2))]),
            notify("tpl-rating-floor", "story.worry", "imessage", [Condition(field: "family", op: .contains, value: .string("rating"))], cooldown: 86_400),
        ]),
        Group(title: "Stability", symbol: "checkmark.shield.fill", tint: Brand.Category.users, rules: [
            notify("tpl-crash-worry", "story.worry", "imessage", [Condition(field: "family", op: .contains, value: .string("crash"))], cooldown: 86_400),
            notify("tpl-job-failed", "job.failed", "ntfy", cooldown: 3_600),
            // A script's "needs a look": once a day at most, so a state that lasts doesn't repeat.
            notify("tpl-job-attention", "job.attention", "imessage", cooldown: 86_400),
            notify("tpl-job-finished", "job.finished", "imessage"),
            notify("tpl-site-down", "site.down", "imessage", cooldown: 3_600),
        ]),
        Group(title: "AI & subscriptions", symbol: "gauge.with.dots.needle.67percent", tint: Brand.Category.users, rules: [
            notify("tpl-usage-hot", "usage.status", "imessage", [Condition(field: "used_percent", op: .gte, value: .number(80))], cooldown: 86_400),
        ]),
        Group(title: "Offer codes", symbol: "ticket.fill", tint: Brand.Category.money, rules: [
            notify("tpl-codes-low", "offercodes.status", "imessage", [Condition(field: "left", op: .lte, value: .number(20))], cooldown: 3 * 86_400),
            notify("tpl-code-expiry", "offercodes.status", "imessage", [Condition(field: "days_to_expiry", op: .lte, value: .number(14))], cooldown: 7 * 86_400),
        ]),
        Group(title: "Releases", symbol: "airplane.departure", tint: Brand.Category.users, rules: [
            notify("tpl-testflight", "testflight.feedback", "imessage", cooldown: 600),
            notify("tpl-expiry", "expiry.status", "imessage", [Condition(field: "days_left", op: .lte, value: .number(30))], cooldown: 7 * 86_400),
            notify("tpl-ci-failed", "ci.build", "ntfy", [Condition(field: "status", op: .oneOf, value: .array([.string("FAILED"), .string("ERRORED")]))], cooldown: 600),
        ]),
        Group(title: "Story digest", symbol: "sunrise.fill", tint: Brand.Category.web, rules: [
            notify("tpl-morning-story", "story.digest", "imessage"),
            notify("tpl-weekly-digest", "story.weekly", "imessage"),
        ]),
    ]
}
