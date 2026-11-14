import HmunmawiCore
import SwiftUI

/// Manual Claude / hub AI pause controls (policy file via ai_policy.py).
///
/// Layout: the saved, live status is plain read-only text at the top (never an input). Changing the pause is a
/// separate step: "Change pause…" opens a small form (length, resume time, optional note). Indefinite pauses and
/// clearing a pause both ask for confirmation, because either one changes whether hub AI jobs run.
struct AIPolicyPauseCard: View {
    enum Length: Hashable { case untilTime, indefinitely }

    @State private var policy = AIPolicyService.shared
    @State private var editing = false
    @State private var length: Length = .untilTime
    @State private var pauseUntil = Date.now.addingTimeInterval(3600)
    @State private var note = ""
    @State private var confirmIndefinite = false
    @State private var confirmClear = false
    @State private var message: String?

    private var snap: AIPolicyDisplay.Snapshot {
        AIPolicyDisplay.parse(policy.statusJSON, loadFailed: policy.lastError != nil && policy.statusJSON.isEmpty)
    }

    var body: some View {
        KitCard {
            CardHeader(symbol: "pause.circle.fill", title: "AI job pause", tint: Brand.Category.users,
                       caption: "Shared hub policy on this Mac. The status below is live; nothing changes until you save.")

            statusBlock

            if let err = policy.lastError {
                Text(err).font(.caption).foregroundStyle(Brand.caution)
            }

            if editing { editForm } else { actionRow }

            if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
        }
        .task { await policy.refresh() }
        .confirmationDialog(AIPolicyDisplay.indefiniteConfirmTitle, isPresented: $confirmIndefinite, titleVisibility: .visible) {
            Button("Pause indefinitely", role: .destructive) { Task { await applyPause() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(AIPolicyDisplay.indefiniteConfirmMessage)
        }
        .confirmationDialog("Clear your pause?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear my pause", role: .destructive) { Task { await clearPause() } }
            Button("Keep it", role: .cancel) {}
        } message: {
            Text("Hub AI jobs may start again right away. Provider limits (daily, weekly) still apply.")
        }
    }

    // MARK: Read-only status

    @ViewBuilder private var statusBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            if policy.busy && policy.statusJSON.isEmpty {
                Label("Reading pause policy…", systemImage: "hourglass")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            } else {
                Text(AIPolicyDisplay.headline(snap))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(snap.blocked ? Brand.caution : Brand.Category.users)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(Array(AIPolicyDisplay.restrictionLines(snap).enumerated()), id: \.offset) { _, line in
                    Text(line).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if let foot = AIPolicyDisplay.recheckFootnote(snap) {
                    Text(foot).font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(AIPolicyDisplay.headline(snap))
    }

    // MARK: Actions (collapsed)

    @ViewBuilder private var actionRow: some View {
        HStack(spacing: 8) {
            Button { startEditing() } label: { Label("Change pause…", systemImage: "slider.horizontal.3") }
            Button { Task { await check() } } label: { Label("Check availability", systemImage: "arrow.clockwise") }
            Spacer(minLength: 0)
            if AIPolicyDisplay.hasManualPause(snap) {
                Button(role: .destructive) { confirmClear = true } label: { Label("Clear my pause", systemImage: "play.circle") }
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .padding(.top, 2)
    }

    // MARK: Edit form (expanded)

    @ViewBuilder private var editForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("New pause").font(.subheadline.weight(.semibold))
            Text("A proposal only. The saved pause above stays as it is until you save.")
                .font(.caption).foregroundStyle(.secondary)

            Picker("Length", selection: $length.animation()) {
                Label("Until a date", systemImage: "calendar").tag(Length.untilTime)
                Label("Indefinitely", systemImage: "infinity").tag(Length.indefinitely)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 320)
            .accessibilityLabel("Pause length")

            if length == .untilTime {
                DatePicker("Resume at", selection: $pauseUntil, in: Date.now..., displayedComponents: [.date, .hourAndMinute])
                    .frame(maxWidth: 320, alignment: .leading)
            } else {
                Label(AIPolicyDisplay.indefiniteExplainer, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(Brand.caution)
                    .fixedSize(horizontal: false, vertical: true)
            }

            TextField("Note", text: $note, prompt: Text(AIPolicyDisplay.notePrompt(snap)))
                .textFieldStyle(.roundedBorder)
                .input(.text(300), $note)
                .frame(maxWidth: 420)
                .accessibilityLabel("Pause note (optional)")

            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("Cancel") { editing = false; message = nil }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.bordered)
                if length == .indefinitely {
                    Button { confirmIndefinite = true } label: { Label("Pause indefinitely…", systemImage: "infinity") }
                        .buttonStyle(.borderedProminent)
                        .tint(Brand.caution)
                } else {
                    Button { Task { await applyPause() } } label: { Label("Save pause", systemImage: "pause.fill") }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(pauseUntil <= .now)
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.quaternary))
    }

    // MARK: Behaviour

    private func startEditing() {
        let defaults = AIPolicyDisplay.manualFormDefaults(from: snap)
        length = defaults?.indefinite == true ? .indefinitely : .untilTime
        if let until = defaults?.until, until > .now { pauseUntil = until } else { pauseUntil = .now.addingTimeInterval(3600) }
        note = "" // the saved note is shown read-only above and kept unless you type a new one
        message = nil
        editing = true
    }

    private func applyPause() async {
        let why = AIPolicyDisplay.reasonToSave(typed: note, snap: snap)
        let ok: Bool
        if length == .indefinitely {
            ok = await policy.setIndefinitePause(reason: why)
        } else {
            ok = await policy.setPause(until: pauseUntil, reason: why)
        }
        message = ok ? "Pause saved." : "Couldn't save pause."
        if ok { editing = false }
        await policy.refresh()
    }

    private func clearPause() async {
        let ok = await policy.clearManualPause()
        message = ok ? "Hands-on pause cleared (provider limits still apply)." : "Couldn't clear pause."
        if ok { editing = false }
        await policy.refresh()
    }

    private func check() async {
        let ok = await policy.checkAvailability()
        message = ok ? "Policy allows a Claude job to start (provider may still refuse)." : "Still deferred by policy."
        await policy.refresh()
    }
}
