import AppKit
import HmunmawiCore
import SwiftUI

/// The INR that actually reached your bank for each of Apple's payouts (read from App Store Connect or typed by you;
/// kept in backups), and the
/// accountant export built from Apple's finance reports.
@MainActor @Observable
final class PayoutBook {
    static let shared = PayoutBook()
    private let url = URL.hmSupport.appending(path: "payouts.json")
    private(set) var bank: [String: Double] = [:]          // fiscal month name -> INR received
    private var rateCache: [String: [String: Double]] = [:] // day -> INR per unit
    init() { if let d = try? Data(contentsOf: url), let b = try? JSONDecoder().decode([String: Double].self, from: d) { bank = b } }

    func setBank(_ month: String, _ inr: Double?) {
        bank[month] = inr.flatMap { $0 > 0 && $0 < 1e12 ? $0 : nil }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(bank).write(to: url, options: .atomic)
    }

    static let autoKey = "HMPayoutsAutoFill"
    static let lastAutoKey = "HMPayoutsLastAutoFill"

    /// Fills paid months from App Store Connect's Payments page through your signed-in Safari (Apple's API doesn't
    /// give the paid amount). Read only; months you typed yourself are kept. `openTab`: may open the page if no App
    /// Store Connect tab is open (only when you press the button; the automatic check never opens tabs).
    func fillFromAppStoreConnect(openTab: Bool) async -> String {
        if let note = Permissions.shared.deferIfNeeded([.safari]) { return note }
        let js = BankPayments.script()
        let script = """
        tell application "Safari"
            set t to missing value
            repeat with w in windows
                repeat with x in tabs of w
                    if URL of x contains "appstoreconnect.apple.com" then set t to x
                end repeat
            end repeat
            if t is missing value then
                if \(openTab ? "true" : "false") is false then return "ERR notab"
                if (count of windows) is 0 then make new document
                set t to make new tab at end of tabs of window 1 with properties {URL:"https://appstoreconnect.apple.com/itc/payments_and_financial_reports"}
                delay 8
            end if
            return do JavaScript "\(js)" in t
        end tell
        """
        let text: String? = await Task.detached {
            let p = Process(), out = Pipe(), input = Pipe()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-"]
            p.standardInput = input; p.standardOutput = out; p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return nil }
            try? input.fileHandleForWriting.write(contentsOf: Data(script.utf8)); try? input.fileHandleForWriting.close()
            let killer = Task.detached { try? await Task.sleep(for: .seconds(120)); if p.isRunning { p.terminate() } }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit(); killer.cancel()
            return p.terminationStatus == 0 ? String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) : nil
        }.value
        guard let text else { return "Couldn't read Safari. Check Settings → Permissions → Safari." }
        if text == "ERR notab" { return "No App Store Connect tab open in Safari." }
        if text.hasPrefix("ERR") { return "Sign in to App Store Connect in Safari first, then try again." }
        let paid = BankPayments.parse(text).filter { $0.currency == "INR" }
        var added = 0
        for p in paid where bank[p.month] == nil { setBank(p.month, p.amount); added += 1 }
        UserDefaults.standard.set(Date.now.timeIntervalSince1970, forKey: Self.lastAutoKey)
        if paid.isEmpty { return "No paid months in INR found on App Store Connect." }
        return added == 0 ? "Up to date: all \(paid.count) paid months are already filled." : "Filled \(added) paid month\(added == 1 ? "" : "s") from App Store Connect."
    }

    /// Automatic check (Settings switch, off by default): once a day, and only when an App Store Connect tab is
    /// already open and signed in. Never opens a tab or asks for anything.
    func autoFillIfDue() async {
        guard UserDefaults.standard.bool(forKey: Self.autoKey) else { return }
        let last = UserDefaults.standard.double(forKey: Self.lastAutoKey)
        guard Date.now.timeIntervalSince1970 - last > 86_400 else { return }
        _ = await fillFromAppStoreConnect(openTab: false)
    }

    /// INR per unit of every currency the ECB publishes, on `day` (the nearest earlier working day when it's a
    /// weekend or holiday). Read from frankfurter.app, the same free source the app's other rates use.
    func inrPer(_ day: String) async -> [String: Double]? {
        if let hit = rateCache[day] { return hit }
        guard let u = URL(string: "https://api.frankfurter.dev/v1/\(day)?from=INR"),
              let (d, r) = try? await URLSession.shared.data(from: u), (r as? HTTPURLResponse)?.statusCode == 200,
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let rates = j["rates"] as? [String: Double] else { return nil }
        let inr = rates.filter { $0.value > 0 }.mapValues { 1 / $0 }
        rateCache[day] = inr
        return inr
    }

    /// The CSV for every finance month Hmunmawi has (Apple's reports are kept for good).
    func csv(_ model: AppModel, now: Date = .now) async -> String {
        let months = PayoutCSV.months(await model.financeMonths(days: 3650))
        var rates: [String: [String: Double]] = [:]
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        for day in Set(months.map { f.string(from: PayoutCSV.rateDay(for: $0, now: now)) }) { rates[day] = await inrPer(day) }
        return PayoutCSV.build(months, bank: bank, inrPer: rates, now: now)
    }
}

/// Payday card > Export for accountant: each payout with a box for what reached the bank, then Save CSV.
struct PayoutsSheet: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var book = PayoutBook.shared
    @State private var months: [PayoutCSV.Month] = []
    @State private var texts: [String: String] = [:]
    @State private var note: String?
    @State private var estimates: [String: Double] = [:]   // month -> INR estimate (ECB rate on the payment date)
    @State private var filling = false
    @AppStorage(PayoutBook.autoKey) private var auto = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Export for accountant").font(.title2.bold())
            Text("Apple's finance reports by fiscal month. Paid amounts come from App Store Connect's Payments page (the amount Apple sent to your bank); type one yourself to override it. Months without one use an estimate (European Central Bank rate on the payment date). Your bank statement is the final figure for tax.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Button(filling ? "Reading…" : "Fill paid months from App Store Connect") {
                    Task {
                        filling = true
                        note = await book.fillFromAppStoreConnect(openTab: true)
                        for m in months { if let b = book.bank[m.name] { texts[m.name] = String(format: "%.2f", b) } }
                        filling = false
                    }
                }
                .disabled(filling)
                Toggle("Keep them filled (daily, when App Store Connect is open in Safari)", isOn: $auto)
            }
            if months.isEmpty {
                Text("No finance reports yet: Apple publishes each month's about a week after it ends.").foregroundStyle(.secondary)
            }
            // One aligned column of boxes, each month's estimate beside it.
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
                ForEach(months, id: \.name) { m in
                    GridRow {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(Self.title(m.name))
                            Text("\(m.start.formatted(.dateTime.day().month(.abbreviated))) – \(m.end.formatted(.dateTime.day().month(.abbreviated).year())) · paid ≈ \(m.paid.formatted(.dateTime.day().month(.abbreviated)))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Text(estimates[m.name].map { "≈ " + Money.text($0, "INR", decimals: 0) } ?? "…")
                            .monospacedDigit().foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                        TextField("INR received", text: Binding(get: { texts[m.name] ?? "" }, set: { v in
                            // Digits and separators only, at most 15 characters.
                            let clean = String(v.filter { ("0"..."9").contains($0) || $0 == "," || $0 == "." }.prefix(15))
                            texts[m.name] = clean
                            book.setBank(m.name, clean.isEmpty ? nil : Money.number(clean))
                        })).multilineTextAlignment(.trailing).frame(width: 150)
                    }
                }
            }
            HStack {
                if let note { Text(note).font(.callout).foregroundStyle(.secondary) }
                Spacer()
                Button("Close") { dismiss() }.buttonStyle(.pill).keyboardShortcut(.cancelAction)
                Button("Save CSV") { Task { await save() } }.buttonStyle(.pillProminent).keyboardShortcut(.defaultAction).disabled(months.isEmpty)
            }
        }
        .padding(24).frame(minWidth: 560)
        .task {
            months = PayoutCSV.months(await model.financeMonths(days: 3650))
            for m in months { if let b = book.bank[m.name] { texts[m.name] = String(format: "%.2f", b) } }
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
            for m in months {
                guard let r = await book.inrPer(f.string(from: PayoutCSV.rateDay(for: m, now: .now))) else { continue }
                estimates[m.name] = m.totals.reduce(0) { $0 + $1.value * ($1.key == "INR" ? 1 : r[$1.key] ?? 0) }
            }
        }
    }

    static func title(_ name: String) -> String {
        let p = name.split(separator: "-").compactMap { Int($0) }
        guard p.count == 2, let d = Calendar.current.date(from: DateComponents(year: p[0], month: p[1], day: 15)) else { return name }
        return d.formatted(.dateTime.month(.wide).year())
    }

    private func save() async {
        let csv = await book.csv(model)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Apple payouts \(Date.now.localDay).csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try csv.write(to: url, atomically: true, encoding: .utf8); note = "Saved \(url.lastPathComponent)" }
        catch { note = "Couldn't save: \(error.localizedDescription)" }
    }
}
