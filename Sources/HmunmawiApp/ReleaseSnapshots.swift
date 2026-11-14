import AppKit
import HmunmawiCore
import SwiftUI

/// Screenshots for release notes and review, taken by the app itself so nothing on screen is touched: a test
/// profile only (`HMUNMAWI_PROFILE`, never the real app), when `HMUNMAWI_SNAPSHOT_DIR` is set. Writes each open
/// window, the menu bar panel, and (with `HMUNMAWI_SNAPSHOT_SHARE`, a JSON file of a project's `name`, `search`
/// and `sections`) its share card in two looks. Works even when the window sits in Stage Manager's strip.
@MainActor enum ReleaseSnapshots {
    static func scheduleIfAsked(model: AppModel) {
        let env = ProcessInfo.processInfo.environment
        guard TestProfile.name != nil, let dir = env["HMUNMAWI_SNAPSHOT_DIR"], !dir.isEmpty else { return }
        let delay = Double(env["HMUNMAWI_SNAPSHOT_DELAY"] ?? "") ?? 12
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            let dest = URL(fileURLWithPath: dir)
            if env["HMUNMAWI_SNAPSHOT_OPEN"] == "permissions" {
                await permissionsPane(into: dest)
            }
            await take(into: dest, model: model, sharePath: env["HMUNMAWI_SNAPSHOT_SHARE"])
        }
    }

    static var tag: String { NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? "dark" : "light" }

    static func take(into dir: URL, model: AppModel, sharePath: String?) async {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for w in NSApp.windows where w.isVisible && w.contentView != nil && w.frame.width > 300 {
            let name = (w.title.isEmpty ? "window" : w.title).replacingOccurrences(of: " ", with: "-").lowercased()
            write(view: w.contentView!.superview ?? w.contentView!, to: dir.appending(path: "\(name)-\(tag).png"))
        }
        // The menu bar panel, hosted off screen at its natural size.
        let host = NSHostingView(rootView: MenuBarPanel(model: model).frame(width: 360))
        host.appearance = NSApp.effectiveAppearance
        let size = host.fittingSize
        // On screen but invisible (SwiftUI only draws text into a window the window server shows), for a moment.
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: size.width, height: size.height),
                           styleMask: [.borderless], backing: .buffered, defer: false)
        win.alphaValue = 0
        win.ignoresMouseEvents = true
        win.appearance = NSApp.effectiveAppearance
        win.backgroundColor = .windowBackgroundColor
        win.contentView = host
        win.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .seconds(2))
        write(view: host, to: dir.appending(path: "menubar-panel-\(tag).png"))
        win.orderOut(nil)
        // The menu bar icon itself, for each dot.
        for dot in [HealthTruth.Dot.good, .attention, .broken, .idle] {
            if let tiff = MenuBarIcon.image(dot).tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: dir.appending(path: "menubar-icon-\(dot.rawValue)-\(tag).png"))
            }
        }
        if let sharePath { shareCards(from: URL(fileURLWithPath: sharePath), into: dir) }
        // The search health card and its detail (a chosen search_health.json), rendered off screen like the panel.
        SearchHealthStore.shared.reload()
        if SearchHealthStore.shared.report != nil {
            await offscreen(AnyView(SearchHealthCard(project: nil).frame(width: 760).padding(20)), to: dir.appending(path: "search-health-card-\(tag).png"))
            await offscreen(AnyView(SearchHealthDetail(project: nil).buttonStyle(.pill).frame(width: 760, height: 1500)), to: dir.appending(path: "search-health-detail-\(tag).png"))
        }
        FileHandle.standardError.write(Data("snapshots: written to \(dir.path)\n".utf8))
    }

    static func shareCards(from url: URL, into dir: URL) {
        guard let data = try? Data(contentsOf: url), let json = try? JSONDecoder().decode(JSONValue.self, from: data) else { return }
        let name = json[path: "name"]?.string ?? "My website"
        let metrics = ProjectShare.metrics(search: json[path: "search"], sections: json[path: "sections"]?.array ?? [])
        guard let hero = ProjectShare.hero(metrics, choice: "auto") else { return }
        for look in [CardLook.hills, .light] {
            var o = CardOptions(); o.look = look; o.shape = .square
            let r = ImageRenderer(content: ProjectShareCard(name: name, metrics: metrics, hero: hero, options: o))
            r.scale = 1
            if let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                let file = name.replacingOccurrences(of: " ", with: "-").lowercased()
                try? png.write(to: dir.appending(path: "share-\(file)-\(look.rawValue.replacingOccurrences(of: " ", with: "-").lowercased()).png"))
            }
        }
        try? ProjectShare.caption(name: name, metrics: metrics).write(to: dir.appending(path: "share-caption.txt"), atomically: true, encoding: .utf8)
    }

    static func offscreen(_ view: AnyView, to url: URL) async {
        let host = NSHostingView(rootView: view)
        host.appearance = NSApp.effectiveAppearance
        let size = host.fittingSize
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: size.width, height: size.height),
                           styleMask: [.borderless], backing: .buffered, defer: false)
        win.alphaValue = 0
        win.ignoresMouseEvents = true
        win.appearance = NSApp.effectiveAppearance
        win.backgroundColor = .windowBackgroundColor
        win.contentView = host
        win.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .seconds(2))
        write(view: host, to: url)
        win.orderOut(nil)
    }

    /// Settings → Permissions, hosted off screen at a readable size so a test copy can snapshot it without clicking.
    static func permissionsPane(into dir: URL) async {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        await Permissions.shared.refresh()
        UserDefaults.standard.set("permissions", forKey: "HMSettingsTab")
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        let host = NSHostingView(rootView:
            PermissionsList(permissions: Permissions.shared)
                .frame(width: 760)
                .padding(24)
                .background(Color(nsColor: .windowBackgroundColor))
        )
        host.appearance = NSApp.effectiveAppearance
        host.layoutSubtreeIfNeeded()
        var size = host.fittingSize
        if size.width < 760 { size.width = 760 }
        if size.height < 400 { size.height = 900 }
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: size.width, height: min(size.height, 1400)),
                           styleMask: [.titled, .closable], backing: .buffered, defer: false)
        win.title = "Mac permissions"
        win.alphaValue = 0
        win.ignoresMouseEvents = true
        win.appearance = NSApp.effectiveAppearance
        win.backgroundColor = .windowBackgroundColor
        win.contentView = host
        host.frame = NSRect(origin: .zero, size: NSSize(width: size.width, height: max(size.height, host.fittingSize.height)))
        win.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .seconds(2))
        write(view: host, to: dir.appending(path: "permissions-screen-\(tag).png"))
        win.orderOut(nil)
    }

    static func write(view: NSView, to url: URL) {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
