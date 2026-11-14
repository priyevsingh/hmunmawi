import AppKit
import HmunmawiCore
import SwiftUI

/// Settings → Backups: what's kept, one-click restore, and fetching everything again from the sources.
struct BackupsForm: View {
    let model: AppModel
    @State private var backups = Backups.shared
    @State private var confirm: Backups.Entry?
    @State private var working = false
    @State private var code: String?
    @State private var cloudCode = ""
    @State private var cloudNote: String?
    @State private var refetched = false
    /// Set once the recovery code was copied or confirmed saved; until then the iCloud section asks for it.
    @AppStorage("HMRecoveryCodeSaved") private var codeSaved = false

    var body: some View {
        Form {
            Section {
                ForEach(backups.entries.prefix(12)) { e in
                    LabeledContent {
                        Button("Restore") { confirm = e }.disabled(working || model.liveStore == nil)
                    } label: {
                        Label {
                            Text(e.date.formatted(.dateTime.day().month(.abbreviated).hour().minute()))
                            Text("\(e.kind.rawValue) · \(ByteCountFormatter.string(fromByteCount: e.bytes, countStyle: .file))\(e.verified ? " · checked" : " · failed its check")")
                        } icon: {
                            Image(systemName: e.kind == .state ? "person.crop.circle.badge.checkmark" : "cylinder.split.1x2")
                        }
                    }
                }
                if backups.entries.isEmpty { Text("The first backup is made a minute after launch.").foregroundStyle(.secondary) }
                HStack {
                    if let r = backups.lastResult { Text(r).font(.callout).foregroundStyle(.secondary) }
                    Spacer()
                    Button("Back up now") { run { if let s = model.liveStore { await backups.backUpNow(store: s) } } }
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([backups.folder]) }
                }
            } header: { Text("On this Mac") } footer: {
                Text("Daily. \u{201C}Your data\u{201D} holds what no source can give back (sales, reviews, daily figures, the activity log, your rules, projects, codes and settings; never keys), kept 30 days plus one a month for a year. Restoring saves your current state first, then restarts the app.")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            Section {
                if !codeSaved, !backups.iCloudCopies().isEmpty {
                    LabeledContent {
                        Button("I've saved it") { codeSaved = true }
                    } label: {
                        Label("Save your recovery code", systemImage: "key.fill").foregroundStyle(Brand.caution)
                        Text("The key stays on this Mac, so after a disk loss or on a new Mac the iCloud copies open only with this code. Show it below, copy it into your password manager.")
                    }
                }
                LabeledContent("Encrypted copy") { Text(backups.iCloudStatus ?? (backups.iCloudCopies().isEmpty ? "None yet" : "\(backups.iCloudCopies().count) in iCloud Drive")).foregroundStyle(.secondary) }
                LabeledContent("Recovery code") {
                    if let code {
                        HStack {
                            Text(code).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                            Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(code, forType: .string); codeSaved = true }
                        }
                    } else {
                        Button("Show") { Task { code = await backups.recoveryCode() ?? "The Keychain didn't answer; try again" } }
                    }
                }
                if let newest = backups.iCloudCopies().first {
                    LabeledContent {
                        HStack {
                            SecureField("", text: $cloudCode, prompt: Text("Recovery code (other Mac only)")).labelsHidden().input(.secret, $cloudCode).frame(width: 240)
                            Button("Bring back") {
                                Task {
                                    do { try await backups.bringBack(newest, recoveryCode: cloudCode); cloudNote = "Added to the list above: choose Restore." }
                                    catch { cloudNote = "Couldn't bring back the backup: \(plainError(error))" }
                                }
                            }
                        }
                    } label: {
                        Text("Newest iCloud copy")
                        Text(cloudNote ?? newest.deletingPathExtension().lastPathComponent)
                    }
                }
            } header: { Text("iCloud Drive") } footer: {
                Text("Each day's backup is also saved encrypted in iCloud Drive \u{203A} Hmunmawi Backups. Keep the recovery code in your password manager: on a new Mac it unlocks those copies.")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            Section {
                LabeledContent {
                    Button(refetched ? "Fetching…" : "Fetch everything again") {
                        refetched = true
                        run { await model.fetchEverythingAgain() }
                    }.disabled(working || model.liveStore == nil)
                } label: {
                    Text("Fetch from your sources")
                    Text("Reads App Store Connect, analytics, search and the rest again, including up to 70 days of sales. Nothing is sent or changed; duplicates are skipped.")
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { backups.reload() }
        .confirmationDialog("Restore this backup?", isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }), presenting: confirm) { e in
            Button("Save current state and restore") { run { if let s = model.liveStore { await backups.restore(e, store: s) } } }
            Button("Cancel", role: .cancel) {}
        } message: { e in
            Text(e.kind == .state
                 ? "Your data from \(e.date.formatted(.dateTime.day().month().hour().minute())) comes back, then everything else is fetched again from your sources. Your current state is saved first, so this can be undone."
                 : "The whole database from \(e.date.formatted(.dateTime.day().month().hour().minute())) comes back. Your current state is saved first, so this can be undone.")
        }
    }

    private func run(_ work: @escaping () async -> Void) {
        working = true
        Task { await work(); working = false; refetched = false }
    }
}
