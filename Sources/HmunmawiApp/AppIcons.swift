import AppKit
import CryptoKit
import HmunmawiCore
import SwiftUI

/// Real App Store icons, sent by the App Store Connect add-on (`icon.snapshot`) and kept on disk,
/// so they show instantly and still show offline.
actor IconCache {
    static let shared = IconCache()
    private var memory: [URL: NSImage] = [:]
    private let folder = URL.hmSupport.appending(path: "Icons", directoryHint: .isDirectory)

    func image(for url: URL) async -> NSImage? {
        if let hit = memory[url] { return hit }
        let name = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        let file = folder.appending(path: "\(name).png")
        if let data = try? Data(contentsOf: file), let image = NSImage(data: data) {
            memory[url] = image
            return image
        }
        guard url.scheme == "https", let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200, let image = NSImage(data: data) else { return nil }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
        memory[url] = image
        return image
    }
}

extension AppModel {
    /// The App Store icon for an app shown under a short name ("My App" matches "My App: Photo Editor").
    func iconURL(for app: String?) -> URL? {
        guard let app = app?.lowercased(), !app.isEmpty else { return nil }
        let icons = snapshots("icon.snapshot")
        let match = icons.first { ($0.app ?? "").lowercased() == app }
            ?? icons.first { let n = ($0.app ?? "").lowercased(); return n.hasPrefix(app) || app.hasPrefix(n) }
        return match?.payload[path: "url"]?.string.flatMap(URL.init(string:))
    }
}

/// An app's real icon in Apple's rounded-square shape; a neutral placeholder until it loads.
/// `badge` adds a small symbol in the corner, such as a bag for a sale.
struct AppIcon: View {
    let app: String?
    var size: CGFloat = 28
    var badge: String?
    var badgeTint: Color = Brand.good
    @State private var image: NSImage?
    @Environment(AppModel.self) private var model: AppModel?

    private var url: URL? { model?.iconURL(for: app) }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
        Group {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high)
            } else {
                // No icon yet (an app that's only parked or new): its first letter, so the row never shows a blank square.
                shape.fill(.quaternary).overlay {
                    Text(String((app ?? "").trimmingCharacters(in: .whitespaces).prefix(1)).uppercased())
                        .font(.system(size: size * 0.5, weight: .semibold, design: .rounded)).foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 0.5))
        .overlay(alignment: .bottomTrailing) {
            if let badge {
                Image(systemName: badge)
                    .font(.system(size: size * 0.28, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: size * 0.5, height: size * 0.5)
                    .background(badgeTint.gradient, in: Circle())
                    .overlay(Circle().strokeBorder(Brand.surface, lineWidth: 1.5))
                    .offset(x: size * 0.14, y: size * 0.14)
            }
        }
        .task(id: url) {
            guard let url else { return }
            image = await IconCache.shared.image(for: url)
        }
        .accessibilityHidden(true)
    }
}

/// A website's own icon (apple-touch-icon, else favicon), fetched once and kept on disk like Safari does.
struct SiteIcon: View {
    let domain: String
    var size: CGFloat = 20
    /// Shown when the site gives no icon (some sites block icon downloads).
    var fallback = "globe"
    var tint: Color = Brand.data
    @State private var image: NSImage?
    @State private var failed = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
        Group {
            if let image { Image(nsImage: image).resizable().interpolation(.high).scaledToFit() }
            else if failed {
                Image(systemName: fallback).font(.system(size: size * 0.55, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: size, height: size).background(tint.gradient)
            } else { shape.fill(.quaternary) }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .task(id: domain) {
            for path in ["apple-touch-icon.png", "favicon.ico"] {
                if let url = URL(string: "https://\(domain)/\(path)"), let found = await IconCache.shared.image(for: url) {
                    image = found; return
                }
            }
            failed = true
        }
        .accessibilityHidden(true)
    }
}
