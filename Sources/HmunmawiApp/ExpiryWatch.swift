import Foundation
import HmunmawiCore
import Security
import SwiftUI

/// Expiry watchdog: everything with a deadline that silently breaks things when missed. Apple certificates and
/// profiles (from App Store Connect), connection logins with an end date (e.g. a Cloudflare token), your domains (public RDAP registry) and their website certificates (read
/// from the site itself), and your Apple Developer membership (typed once; Apple has no API for it).
/// A daily "expiry.status" event per item lets rules warn you (e.g. 30 days ahead).
@MainActor @Observable
final class ExpiryWatch {
    static let shared = ExpiryWatch()

    struct Item: Identifiable, Hashable {
        let kind: String      // Certificate, Profile, Domain, Website certificate, Membership
        let name: String
        let expires: Date?
        let note: String?     // why there's no date (couldn't read it)
        var id: String { kind + "|" + name }
        var days: Int? { expires.map { Int(($0.timeIntervalSinceNow / 86_400).rounded(.down)) } }
    }

    static let domainsKey = "HMWatchDomains"
    static let membershipKey = "HMMembershipRenews"
    private(set) var web: [Item] = []
    private(set) var lastWebCheck: Date?

    var domains: [String] {
        get { UserDefaults.standard.stringArray(forKey: Self.domainsKey) ?? [] }
        set { UserDefaults.standard.set(Array(Set(newValue.map { $0.lowercased() })).sorted(), forKey: Self.domainsKey) }
    }
    var membership: Date? {
        get { UserDefaults.standard.object(forKey: Self.membershipKey) as? Date }
        set { UserDefaults.standard.set(newValue, forKey: Self.membershipKey) }
    }

    func items(_ model: AppModel) -> [Item] {
        let iso = ISO8601DateFormatter()
        var out: [Item] = (model.snapshots("expiry.snapshot").first?.payload[path: "items"]?.array ?? []).compactMap { i in
            guard let name = i[path: "name"]?.string else { return nil }
            return Item(kind: i[path: "kind"]?.string ?? "Certificate", name: name,
                        expires: i[path: "expires"]?.string.flatMap { iso.date(from: $0) ?? (try? Date($0, strategy: .iso8601)) }, note: nil)
        }
        // Connection logins that end on a date (a Cloudflare token with an end date): each add-on's
        // "login.<id>.snapshot". A login without an end date isn't listed.
        for (kind, rows) in model.snapshotCache where kind.hasPrefix("login.") && kind.hasSuffix(".snapshot") {
            guard let p = rows.first?.payload, let name = p[path: "name"]?.string,
                  let exp = p[path: "expires"]?.string, let date = iso.date(from: exp) ?? (try? Date(exp, strategy: .iso8601)) else { continue }
            out.append(Item(kind: "Login", name: name, expires: date, note: nil))
        }
        out += web
        if let m = membership { out.append(Item(kind: "Membership", name: "Apple Developer Program", expires: m, note: nil)) }
        return out.sorted { ($0.expires ?? .distantFuture) < ($1.expires ?? .distantFuture) }
    }

    /// Domains and website certificates, at most every 12 hours. A failure shows on the item, never silently.
    func checkWeb(force: Bool = false) async {
        if !force, let last = lastWebCheck, Date.now.timeIntervalSince(last) < 12 * 3600 { return }
        lastWebCheck = .now
        var found: [Item] = []
        for d in domains.prefix(30) where InputCheck.httpsURL("https://\(d)") != nil {
            let (domain, why) = await Self.rdapExpiry(d)
            found.append(Item(kind: "Domain", name: d, expires: domain, note: why))
            let (cert, why2) = await Self.tlsExpiry(d)
            found.append(Item(kind: "Website certificate", name: d, expires: cert, note: why2))
        }
        web = found
    }

    /// Daily events for rules: one per item with days left.
    func statusEvents(_ model: AppModel) -> [Event] {
        let day = Date.now.formatted(Date.ISO8601FormatStyle(timeZone: .current).year().month().day())   // your day, not UTC's
        let now = Millis(Date.now.timeIntervalSince1970 * 1000)
        return items(model).compactMap { i in
            guard let days = i.days else { return nil }
            return Event(source: "hmunmawi", kind: "expiry.status", app: nil,
                         payload: .object(["kind": .string(i.kind), "name": .string(i.name), "days_left": .number(Double(days))]),
                         occurredAt: now, dedupeKey: "expiry-\(i.id)-\(day)")
        }
    }

    /// The public registry (RDAP) date a domain expires. Free, no key.
    nonisolated static func rdapExpiry(_ domain: String) async -> (Date?, String?) {
        guard domain.wholeMatch(of: /[A-Za-z0-9]([A-Za-z0-9.-]{0,251}[A-Za-z0-9])?/) != nil,
              let url = URL(string: "https://rdap.org/domain/\(domain)") else { return (nil, "Not a domain") }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let events = root["events"] as? [[String: Any]],
                  let exp = events.first(where: { ($0["eventAction"] as? String) == "expiration" })?["eventDate"] as? String,
                  let date = try? Date(exp, strategy: .iso8601) else {
                return (nil, "The registry doesn't publish this domain's expiry date")
            }
            return (date, nil)
        } catch {
            return (nil, "Couldn't reach the domain registry: \(error.localizedDescription)")
        }
    }

    /// The website certificate's "not after" date, read from a real HTTPS connection.
    nonisolated static func tlsExpiry(_ domain: String) async -> (Date?, String?) {
        guard let url = URL(string: "https://\(domain)") else { return (nil, "Not a domain") }
        let catcher = CertCatcher()
        let session = URLSession(configuration: .ephemeral, delegate: catcher, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "HEAD"
        _ = try? await session.data(for: request)
        if let date = catcher.notAfter { return (date, nil) }
        return (nil, "Couldn't read the website's certificate")
    }

    private final class CertCatcher: NSObject, URLSessionDelegate, @unchecked Sendable {
        var notAfter: Date?
        func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async
            -> (URLSession.AuthChallengeDisposition, URLCredential?) {
            if let trust = challenge.protectionSpace.serverTrust,
               let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first,
               let values = SecCertificateCopyValues(leaf, [kSecOIDX509V1ValidityNotAfter] as CFArray, nil) as? [CFString: Any],
               let entry = values[kSecOIDX509V1ValidityNotAfter] as? [CFString: Any],
               let seconds = (entry[kSecPropertyKeyValue] as? NSNumber)?.doubleValue {
                notAfter = Date(timeIntervalSinceReferenceDate: seconds)
            }
            return (.performDefaultHandling, nil)
        }
    }
}

/// On Automations: what expires soonest first, colour by how soon, with a place to add domains and the
/// membership date.
struct ExpiryCard: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var watch = ExpiryWatch.shared
    @State private var adding = ""
    @State private var editing = false
    @State private var showAll = false
    @State private var confirmClear = false

    var body: some View {
        let items = watch.items(model)
        let soon = items.filter { ($0.days ?? 9999) <= 60 || $0.note != nil }
        KitCard {
            HStack {
                CardHeader(symbol: "hourglass", title: "Expiry watchdog", tint: Brand.caution,
                           caption: soon.isEmpty ? Quips.pick(["Nothing expiring soon. Calendar's yawning.", "All good for 60 days. Go build something."])
                               : "\(soon.count) need\(soon.count == 1 ? "s" : "") a look")
                Button { editing.toggle() } label: { Image(systemName: "slider.horizontal.3") }.buttonStyle(.borderless).help("Domains and membership date")
            }
            ForEach(showAll ? items : Array(soon.prefix(8))) { i in
                HStack(spacing: 10) {
                    let d = i.days
                    Circle().fill(d.map { $0 < 0 ? Brand.bad : $0 <= 14 ? Brand.bad : $0 <= 60 ? Brand.caution : Brand.good } ?? Color.secondary)
                        .frame(width: 8, height: 8)
                    Text(i.name).fixedSize(horizontal: false, vertical: true)
                    Text(i.kind).font(.callout).foregroundStyle(.secondary)
                    if i.kind == "Login", (i.days ?? 99) <= 30 {
                        Button("Reconnect") { UserDefaults.standard.set("connections", forKey: "HMSettingsTab"); openWindow(id: "settings") }
                            .buttonStyle(.pill).help("Make a new token and paste it in Settings → Connections")
                    }
                    Spacer()
                    if let note = i.note { Text(note).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                    else if let d { Text(d < 0 ? "expired \(-d) \(-d == 1 ? "day" : "days") ago" : d == 0 ? "expires today" : "in \(d) \(d == 1 ? "day" : "days") · \(i.expires!.formatted(date: .abbreviated, time: .omitted))")
                        .font(.callout.monospacedDigit()).foregroundStyle(d <= 14 ? Brand.bad : .secondary).liveNumber(d) }
                }
            }
            if items.count > soon.count {
                Button(showAll ? "Show only the urgent ones" : "Show all \(items.count)") { withAnimation { showAll.toggle() } }.buttonStyle(.pill)
            }
            if editing {
                Divider()
                HStack {
                    TextField("Add a domain, e.g. example.com", text: $adding).input(.identifier, $adding)
                    Button("Add") { watch.domains += [adding]; adding = ""; Task { await watch.checkWeb(force: true) } }
                        .buttonStyle(.pill).disabled(InputCheck.httpsURL("https://\(adding)") == nil || !adding.contains("."))
                }
                if !watch.domains.isEmpty {
                    Text("Watching: " + watch.domains.joined(separator: ", ")).font(.callout).foregroundStyle(.secondary)
                    Button("Remove all domains", role: .destructive) { confirmClear = true }.buttonStyle(.pill)
                        .confirmationDialog("Stop watching every domain?", isPresented: $confirmClear) {
                            Button("Remove all", role: .destructive) { watch.domains = []; Task { await watch.checkWeb(force: true) } }
                            Button("Cancel", role: .cancel) {}
                        } message: { Text("Their expiry dates won't be checked any more. You can add them again.") }
                }
                DatePicker("Apple Developer membership renews", selection: Binding(get: { watch.membership ?? .now.addingTimeInterval(365 * 86_400) },
                                                                                    set: { watch.membership = $0 }), displayedComponents: .date)
                Text("Apple doesn't share this date through its API; find it in your developer account under Membership.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .task { await watch.checkWeb() }
    }
}
