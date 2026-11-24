import HmunmawiCore
import SwiftUI

enum Page: String, CaseIterable, Identifiable {
    case today = "Today"
    case apps = "Apps"
    case log = "Log"
    case automations = "Automations"

    var id: Self { self }

    var symbol: String {
        switch self {
        case .today: "mountain.2.fill"
        case .apps: "app.badge.fill"
        case .log: "tray.full.fill"
        case .automations: "point.3.connected.trianglepath.dotted"
        }
    }

    var shortcut: KeyEquivalent { KeyEquivalent(Character("\(Page.allCases.firstIndex(of: self)! + 1)")) }
}

/// Today is one continuous story; each chapter gathers what used to be a separate dashboard.
enum Chapter: String, CaseIterable, Identifiable {
    case pulse = "Pulse", money = "Money", growth = "Growth"
    var id: Self { self }

    var symbol: String {
        switch self {
        case .pulse: "waveform.path.ecg"
        case .money: "banknote.fill"
        case .growth: "chart.line.uptrend.xyaxis"
        }
    }

    /// Where sections sent by add-ons (their `page` value) appear.
    var sectionKeys: [String] {
        switch self {
        case .pulse: ["overview", "health"]
        case .money: ["revenue"]
        case .growth: ["growth"]
        }
    }
}

struct MainView: View {
    let model: AppModel
    // `open Hmunmawi.app --args -HMPage Revenue` opens a page directly (handy for screenshots).
    @AppStorage("HMPage") private var page: Page = .today
    @State private var detail = DetailPresenter()
    @State private var permissions = Permissions.shared
    @AppStorage("HMSetupStep") private var setupStep = 0
    @AppStorage("HMSetupDone") private var setupDone = false
    @State private var refreshing = false

    var body: some View {
        // Developer design boards, only with the -HMStyleBoard launch option (see StyleBoard / OverviewConcepts).
        if UserDefaults.standard.string(forKey: "HMStyleBoard") == "overview" {
            OverviewConcepts(model: model)
        } else if UserDefaults.standard.bool(forKey: "HMStyleBoard") {
            StyleBoard(model: model)
        } else {
            mainBody
        }
    }

    private var mainBody: some View {
        HStack(alignment: .top, spacing: 0) {
            Group {
                switch page {
                case .today: FrontPage(model: model)
                case .apps: AppsPager(model: model)
                case .automations: AutomationsPage(model: model)
                case .log:
                    ScrollView {
                        VStack(alignment: .leading, spacing: 24) {
                            InboxPage(model: model)
                            // Apple's status, developer news and your repo belong to apps (or to everything), not to a website.
                            if ProjectStore.shared.selected.map({ $0.kind == .apps }) ?? true { WorldCard(model: model) }
                            CustomSections(model: model, page: "inbox")
                            let steps = ProjectStore.shared.scopedAudit(model.audit)
                            if !steps.isEmpty { ActivityPage(entries: steps) }
                        }
                        .readableWidth()
                    }
                    .scrollEdgeEffectStyle(.soft, for: .top)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            // One button look across every page and the sheets they open: a button that doesn't pick its own
            // style is a pill (toolbar buttons sit outside this, so they keep the system look).
            .buttonStyle(.pill)
            // An open story takes the stage: everything behind it settles back and blurs and dims. The blur is a layer that
            // exists only while a story is open (blur and colour filters on the page itself, even at zero, put every frame
            // of every scroll through an extra off-screen pass: measured with Instruments, Nov 2026).
            .scaleEffect(detail.expanded ? 0.96 : 1)
            .animation(.smooth(duration: 0.45), value: detail.expanded)
            // (The dimming behind an open card is drawn by ZoomedDetail itself. A live blur of the whole window used to be added
            // here too: it was computed on the CPU for every frame of the card's animation, measured with Instruments, Nov 2026.)
            .animation(.smooth(duration: 0.45), value: detail.expanded)
            // A page switch is instant, like a tab in any Apple app: the page is replaced, not cross-faded (a cross-fade keeps two
            // whole pages alive and compositing for a third of a second; measured with Instruments, Nov 2026).
            .id(page)
        }
        // Startup problems, connections waiting for your OK, or a slow launch step: said plainly at the top.
        // Above the page, never over it (it used to cover the greeting line).
        .safeAreaInset(edge: .top, spacing: 0) { VStack(spacing: 0) { StartupBanners(model: model); HiddenIconHint() } }
        .overlay { ZoomedDetail(presenter: detail).buttonStyle(.pill) }
        // After the zoomed card so a live or replayed payment moment is visible even when a story is open
        // (Purchases lives inside Open Money; a moment under that card would be hidden).
        .overlay { SaleMoment(event: model.flash, token: model.flashToken, replay: model.flashReplays) }
        .environment(detail)
        .environment(model)
        .onChange(of: page) { _, _ in detail.closeAll() }

        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in LastSeen.markLeft() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in LastSeen.markLeft() }
        // The Mac going to sleep or locking also ends a look, whichever app is in front.
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.screensDidSleepNotification)) { _ in LastSeen.markLeft() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.sessionDidResignActiveNotification)) { _ in LastSeen.markLeft() }
        // Quiet for a few minutes with the app in front counts as having left (the clock starts when you stopped).
        .task {
            LastSeen.recoverFromUnexpectedEnd()
            while !Task.isCancelled {
                let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
                LastSeen.tick(idle: idle, appActive: NSApp.isActive)
                try? await Task.sleep(for: .seconds(30))
            }
        }
        // Back on screen after running in the background: catch up at once instead of waiting for the next tick.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in Task { await model.refresh() } }
        .navigationTitle(page == .today ? "Hmunmawi" : page.rawValue)
        .navigationSubtitle(Date.now.formatted(.dateTime.weekday(.wide).day().month(.wide)))
        .toolbar {
            // Three spaces in one Liquid Glass switch; the story itself carries the rest.
            ToolbarItem(placement: .principal) {
                Picker("Space", selection: $page) {
                    ForEach(Page.allCases) { p in
                        Text(p == .log && model.waiting.count > 0 ? "Log (\(model.waiting.count))" : p.rawValue).tag(p)
                    }
                }
                .pickerStyle(.segmented)
                .frame(minWidth: 320, idealWidth: 380)
                .background {
                    // ⌘1-⌘4 switch spaces (shortcuts only: one way to each page, no extra menu).
                    ForEach(Page.allCases) { p in
                        Button("") { page = p }.keyboardShortcut(p.shortcut, modifiers: .command).hidden()
                    }
                }
            }
            ToolbarItem(placement: .navigation) { ProjectSwitcher(detail: detail) }
            ToolbarItem {
                // On Overview the ticker already shows new moments; elsewhere the pill announces them briefly.
                StatusPill(status: model.status, truth: model.truth, flash: page == .today ? nil : model.flash)
                    .environment(model)
            }
            ToolbarItem {
                // Today's story zooms open from here: the day in one line, then Win / Worry / Next.
                Button {
                    let rect = NSApp.keyWindow.map { CGRect(x: $0.frame.width - 300, y: 20, width: 120, height: 30) } ?? .zero
                    detail.closeAll()   // the toolbar always starts a fresh story, never stacked on an open card
                    detail.show(view: AnyView(TodaysStoryCard(model: model).environment(model).environment(detail)), from: rect)
                } label: {
                    Label("Today's story", systemImage: "text.book.closed.fill")
                }
                .help("Today's story")
            }
            ToolbarItem {
                Button {
                    Task {
                        refreshing = true
                        await model.refresh()
                        refreshing = false
                    }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                        .symbolEffect(.rotate, isActive: refreshing)
                }
                .keyboardShortcut("r", modifiers: .command)   // ⌘R on the same button, no second route
                .help("Refresh now (⌘R)")
            }
            ToolbarItem { PanelButton() }
            ToolbarItem {
                OpenSettingsButton { Label("Settings", systemImage: "gearshape") }
            }
        }
        .task { ScrollGate.install(); await model.load() }
        .sheet(isPresented: Binding(get: { !setupDone }, set: { setupDone = !$0 })) {
            SetupFlow(model: model, permissions: permissions, start: setupStep) { setupDone = true; setupStep = 0 }
        }
    }
}

/// One notice at a time across the top of the window: a failed start (with Retry), approved connections that
/// changed and need your OK again (instead of silently showing sample data), or a slow launch step.
private struct StartupBanners: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if let problem = model.startError {
            banner(symbol: "exclamationmark.triangle.fill", tint: Brand.bad, text: problem) {
                Button("Retry") { Task { await model.retryStart() } }.buttonStyle(.pillProminent)
            }
        } else if model.lowDisk {
            banner(symbol: "externaldrive.badge.exclamationmark", tint: Brand.bad,
                   text: "Your disk is almost full (under 1 GB free). New data may not be saved until you free some space.") { EmptyView() }
        } else if !model.changedAddOns.isEmpty {
            let names = model.changedAddOns
            let who = names.count == 1 ? "\(names[0]) was" : "\(names.count) connections were"
            banner(symbol: "checkmark.shield", tint: Brand.caution,
                   text: "\(who) updated and \(names.count == 1 ? "needs" : "need") your OK again. Your data is safe; \(names.count == 1 ? "its" : "their") numbers pause until then.") {
                Button("Review") {
                    UserDefaults.standard.set("connections", forKey: "HMSettingsTab")
                    openWindow(id: "settings")
                }.buttonStyle(.pillProminent)
            }
        } else if let note = model.busyNote {
            Label { Text(note) } icon: { ProgressView().controlSize(.small) }
                .font(.callout.weight(.medium)).padding(.horizontal, 14).padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule()).padding(.top, 10)
        }
    }

    private func banner<A: View>(symbol: String, tint: Color, text: String, @ViewBuilder action: () -> A) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
            action()
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .padding(.top, 10).padding(.horizontal, 40)
    }
}
