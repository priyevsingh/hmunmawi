import AppKit
import HmunmawiCore
import SwiftUI

/// First run for a new user: Welcome → Connect App Store Connect (guide + step-by-step key check) → Permissions
/// (each with its reason, asked once) → More sources (optional). If skipped, a "Get set up" card stays on Today
/// until every step is done. Sample numbers show behind it until real data arrives.
@MainActor enum SetupState {
    static let doneKey = "HMSetupDone"            // the sheet was finished or skipped
    static let sourcesKey = "HMSetupSourcesSeen"
    static let hiddenKey = "HMSetupCardHidden"

    static func ascRow(_ model: AppModel) -> AddOnRow? { model.addOns.first { $0.id == "appstoreconnect" } }
    static func ascConnected(_ model: AppModel) -> Bool { ascRow(model).map { $0.approved && $0.missing.isEmpty } ?? false }
    static func complete(_ model: AppModel, _ permissions: Permissions) -> Bool {
        // Messages is needed only when alerts go by iMessage (permissionsReady checks that; ntfy users must still finish).
        // Opening at login is offered and recommended but never required to finish setup: it is the person's choice
        // (Apple's settings guidance: leave system-level choices to the person, don't make them a gate).
        let permissionsDone = permissionsReady(model, permissions)
        return ascConnected(model) && permissionsDone && UserDefaults.standard.bool(forKey: sourcesKey)
    }

    static func permissionsReady(_ model: AppModel, _ permissions: Permissions) -> Bool {
        let usesIMessage = model.addOns.contains { $0.id == "imessage" && $0.approved }
        return permissions.files == .granted
            && permissions.keychain != .denied
            && (!usesIMessage || permissions.messages == .granted)
    }
}

struct SetupFlow: View {
    let model: AppModel
    let permissions: Permissions
    var start = 0
    let done: () -> Void
    @State private var step = 0
    private let titles = ["Welcome", "App Store Connect", "Permissions", "Menu bar & alerts", "More sources"]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 6) {
                ForEach(0..<titles.count, id: \.self) { i in
                    Capsule().fill(i <= step ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.secondary.opacity(0.25)))
                        .frame(width: i == step ? 28 : 10, height: 6)
                }
                Text("Step \(step + 1) of \(titles.count) · \(titles[step])").font(.callout).foregroundStyle(.secondary).padding(.leading, 6)
            }
            .animation(.smooth, value: step)
            Group {
                switch step {
                case 0: Welcome()
                case 1: ConnectASC(model: model)
                case 2: VStack(alignment: .leading, spacing: 10) {
                    Text("Allow these once").font(.title)
                    Text("Each one says why and whether it's already on. You grant each once; Hmunmawi never pops up a system box in the middle of a job.").foregroundStyle(.secondary)
                    ScrollView { PermissionsList(permissions: permissions) }.frame(maxHeight: 480)
                }
                case 3: StayInTheLoop()
                default: MoreSources()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack {
                Button("Skip for now") { done() }.buttonStyle(.borderless).foregroundStyle(.secondary)
                Spacer()
                if step > 0 { Button("Back") { step -= 1 }.buttonStyle(.pill) }
                Button(step == titles.count - 1 ? "Start" : "Continue") {
                    if step == titles.count - 1 { UserDefaults.standard.set(true, forKey: SetupState.sourcesKey); done() } else { step += 1 }
                }
                .buttonStyle(.pillProminent).keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
        }
        .padding(28)
        .frame(width: 640)
        .onAppear { step = start }
    }
}

private struct Welcome: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 72, height: 72)
            Text("Welcome to Hmunmawi").font(.largeTitle)
            Text("hmoon-MAH-wee · Mizo for \(Text("\u{201C}beautiful place\u{201D}").foregroundStyle(Kit.vibrant(Brand.Category.web)))")
                .font(.title3)
            Text("Your apps, money, reviews and Mac jobs in one calm place, running by itself. Setup takes about 3 minutes. Until your own numbers arrive, you'll see sample ones so nothing looks empty.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The App Store Connect key, step by step, with a check that says exactly what the key can read.
private struct ConnectASC: View {
    let model: AppModel
    @AppStorage("HMSetupKeyPath") private var path = "have"     // have | new

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connect App Store Connect").font(.title)
            Text("Do you already have an App Store Connect API key, for example one your scripts or tools use?")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Picker("Key", selection: $path) {
                Text("I already have one").tag("have")
                Text("Make a new one").tag("new")
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            if path == "have" {
                Label("Paste its Issuer ID and Key ID and choose its .p8 file below. Tip: a key just for Hmunmawi lets you switch it off without touching your other tools.",
                      systemImage: "lightbulb")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Label("Tip: press \u{201C}Find my key\u{201D} next to a field and Hmunmawi looks in your Keychain, your .env files and Downloads for it.", systemImage: "key.viewfinder")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
            VStack(alignment: .leading, spacing: 8) {
                Step(n: 1, text: "Open Users and Access → Integrations → **Team Keys**. First time? Only the Account Holder can turn on API access.") {
                    Link("Open App Store Connect", destination: URL(string: "https://appstoreconnect.apple.com/access/integrations/api")!)
                }
                Step(n: 2, text: "Press **+** and give it any name you'll recognise later (like \u{201C}Hmunmawi\u{201D}). Pick the role **Admin**: the one role that can read everything Hmunmawi uses (sales, payments, reviews, offer codes). Use a *team* key: personal keys can't read sales.")
                Step(n: 3, text: "Copy the **Issuer ID** (above the table) and the **Key ID**, and download the **.p8** file. Apple lets you download it only once.")
                Step(n: 4, text: "Your **vendor number** is at the top left of Payments and Financial Reports.") {
                    Link("Open Payments and Financial Reports", destination: URL(string: "https://appstoreconnect.apple.com/itc/payments_and_financial_reports")!)
                }
            }
            }
            if let row = SetupState.ascRow(model) {
                Form { AddOnSection(row: row, model: model) }.formStyle(.grouped).frame(height: 350).scrollContentBackground(.hidden)
                AccessResults(model: model)
            }
        }
    }

    private struct Step<Extra: View>: View {
        let n: Int
        let text: LocalizedStringKey
        @ViewBuilder var extra: Extra
        init(n: Int, text: LocalizedStringKey, @ViewBuilder extra: () -> Extra = { EmptyView() }) { self.n = n; self.text = text; self.extra = extra() }
        var body: some View {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("\(n)").font(.callout.bold()).foregroundStyle(.white).frame(width: 22, height: 22).background(Circle().fill(Color.accentColor))
                VStack(alignment: .leading, spacing: 4) {
                    Text(text).fixedSize(horizontal: false, vertical: true)
                    extra
                }
            }
        }
    }
}

/// What the key can read, from the add-on's step-by-step check, each with the exact fix.
struct AccessResults: View {
    let model: AppModel

    var body: some View {
        if let p = model.snapshots("asc.access").first?.payload {
            let apps = Int(safe: p[path: "apps"]?.number ?? 0)
            VStack(alignment: .leading, spacing: 6) {
                line("Key works", ok: true)
                line("\(apps) app\(apps == 1 ? "" : "s") found", ok: apps > 0, fix: "No apps: is this the right team?")
                item(p, "reviews", "Reviews", fix: "Needs the Customer Support, App Manager or Admin role")
                item(p, "offer_codes", "In-app purchases and offer codes", fix: "Needs the App Manager or Admin role")
                item(p, "sales", "Daily sales", fix: "Needs the Sales, Finance or Admin role")
                item(p, "finance", "Payments", fix: "Needs the Finance or Admin role")
            }
            .font(.callout)
        }
    }

    @ViewBuilder private func item(_ p: JSONValue, _ key: String, _ title: String, fix: String) -> some View {
        switch p[path: key]?.string {
        case "ok": line(title, ok: true)
        case "no_vendor": line(title, ok: false, fix: "Add your vendor number above")
        case "role": line(title, ok: false, fix: fix)
        case nil: EmptyView()
        default: line(title, ok: false, fix: "Couldn't check right now; try again")
        }
    }

    private func line(_ text: String, ok: Bool, fix: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill").foregroundStyle(ok ? Brand.good : Brand.bad)
            Text(text)
            if !ok, let fix { Text(fix).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
    }
}

/// Offers the menu bar icon and Mac notifications (both on by default; notifications start quietly).
private struct StayInTheLoop: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Keep an eye on things without the window").font(.title)
            Text("Close the window any time: Hmunmawi keeps watching in the background. The menu bar icon shows how everything is, and Mac notifications tell you about sales, refunds, bad reviews and anything broken.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Form { MenuBarBasics(); NotificationChoices() }.formStyle(.grouped).frame(height: 380).scrollContentBackground(.hidden)
        }
    }
}

private struct MoreSources: View {
    @Environment(\.openWindow) private var openWindow
    private let sources: [(String, String, String)] = [
        ("chart.line.uptrend.xyaxis", "PostHog", "Who uses your apps each day"),
        ("ant.fill", "Sentry", "Crashes and hangs, with the culprit"),
        ("magnifyingglass", "Search Console and Bing", "How people find your website"),
        ("play.rectangle.fill", "YouTube and X", "Your channel; X with Grok Bot or your Safari login"),
        ("message.fill", "iMessage or ntfy", "Alerts on your phone when it matters"),
        ("calendar.badge.clock", "Your Mac's jobs", "Scheduled scripts on this Mac, if you have any"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add more when you like").font(.title)
            Text("All optional. Each one adds a piece of the story; connect any of them now or later in Settings.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(sources, id: \.1) { s in
                    HStack(spacing: 10) {
                        Image(systemName: s.0).foregroundStyle(Color.accentColor).frame(width: 24)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(s.1).font(.body)
                            Text(s.2).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.06)))
                }
            }
            Button("Open Connections") {
                UserDefaults.standard.set("connections", forKey: "HMSettingsTab")
                openWindow(id: "settings")
            }
            .buttonStyle(.pill)
        }
    }
}

/// On Today until setup is complete (or you hide it): the setup steps as a checklist, each reopening its step.
struct SetupChecklist: View {
    let model: AppModel
    let permissions: Permissions
    let open: (Int) -> Void
    @AppStorage(SetupState.hiddenKey) private var hidden = false
    @AppStorage(SetupState.sourcesKey) private var sourcesSeen = false

    var body: some View {
        if !hidden && !SetupState.complete(model, permissions) {
            let items: [(String, Bool, Int)] = [
                ("Connect App Store Connect", SetupState.ascConnected(model), 1),
                ("Allow permissions", SetupState.permissionsReady(model, permissions), 2),
                ("Look at more sources (optional)", sourcesSeen, 4),
            ]
            let done = items.filter(\.1).count
            KitCard {
                HStack {
                    CardHeader(symbol: "checklist", title: "Get set up", tint: Brand.Category.web, caption: "\(done) of \(items.count) done")
                    Button { hidden = true } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).help("Hide this card")
                }
                ForEach(items, id: \.0) { item in
                    HStack {
                        Image(systemName: item.1 ? "checkmark.circle.fill" : "circle").foregroundStyle(item.1 ? Brand.good : .secondary)
                        Text(item.0).foregroundStyle(item.1 ? .secondary : .primary)
                        Spacer()
                        if !item.1 { Button("Start") { open(item.2) } }
                    }
                }
            }
            .task { await permissions.refresh() }
        }
    }
}
