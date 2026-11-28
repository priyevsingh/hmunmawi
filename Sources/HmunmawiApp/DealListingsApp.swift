import Foundation
import HmunmawiCore

/// Manages deal directory submissions, pre-flight validation, gated PR/email preparation,
/// and zero-lag background GitHub PR status polling.
@MainActor
@Observable
final class DealListings {
    static let shared = DealListings()

    private let url: URL
    private(set) var book: DealListingsBook
    private let urlCache = DealPreflightValidator.URLCheckCache()
    private let launchedAt = Date.now
    private var lastPollAt: Date?
    private var rateLimitUntil: Date?
    private var isPolling = false

    init(url: URL = URL.hmSupport.appending(path: DealListingsStore.fileName)) {
        self.url = url
        self.book = DealListingsStore.load(url)
    }

    private func persist() {
        book.updatedAt = ISO8601DateFormatter().string(from: .now)
        DealListingsStore.save(book, to: url)
    }

    // MARK: - CRUD

    func upsert(_ submission: DealSubmission) {
        if let idx = book.submissions.firstIndex(where: { $0.id == submission.id }) {
            book.submissions[idx] = submission
        } else {
            book.submissions.insert(submission, at: 0)
        }
        persist()
    }

    func remove(id: String) {
        let before = book.submissions.count
        book.submissions.removeAll { $0.id == id }
        if book.submissions.count != before { persist() }
    }

    func markSubmitted(id: String, liveURL: String?) {
        guard let idx = book.submissions.firstIndex(where: { $0.id == id }) else { return }
        if let liveURL, !liveURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            book.submissions[idx].liveListingURL = liveURL.trimmingCharacters(in: .whitespacesAndNewlines)
            book.submissions[idx].status = .listed
        } else {
            book.submissions[idx].status = .submitted
        }
        book.submissions[idx].lastCheckedAt = DealPreflightValidator.todayISO()
        persist()
    }

    func setLiveURL(id: String, urlString: String) {
        guard let idx = book.submissions.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        book.submissions[idx].liveListingURL = trimmed.isEmpty ? nil : trimmed
        if !trimmed.isEmpty {
            book.submissions[idx].status = .listed
        }
        persist()
    }

    func liveListedSubmissions(appName: String? = nil) -> [DealSubmission] {
        book.submissions.filter { sub in
            guard sub.status.isLiveListed || (sub.liveListingURL?.isEmpty == false) else { return false }
            if let appName, !appName.isEmpty {
                return sub.appName.caseInsensitiveCompare(appName) == .orderedSame
            }
            return true
        }
    }

    // MARK: - Pre-Flight

    func runPreflight(for sub: DealSubmission) async -> DealPreflightResult {
        guard let dir = book.directory(id: sub.directoryID) else {
            return DealPreflightResult(errors: ["Unknown directory: \(sub.directoryID)"])
        }
        var result = DealPreflightValidator.validateSync(sub, directory: dir, existingBook: book, wording: Wording.rules)
        let prodCheck = await urlCache.checkURL(sub.productURL)
        if !prodCheck.0, let note = prodCheck.1 {
            result.errors.append(note)
        }
        if let redeem = sub.redeemURL, !redeem.isEmpty {
            let rCheck = await urlCache.checkURL(redeem)
            if !rCheck.0, let note = rCheck.1 {
                result.warnings.append(note)
            }
        }
        if dir.requiresIcon, let icon = sub.iconURL, !icon.isEmpty {
            let iconCheck = await urlCache.checkURL(icon, requireImageMinPixels: dir.minIconPixels)
            if !iconCheck.0, let note = iconCheck.1 {
                result.errors.append(note)
            }
        }
        return result
    }

    // MARK: - Gated PR & Email Preparation

    func preparePRJob(submissionID: String, model: AppModel) async -> (ok: Bool, note: String, jobID: Int64?) {
        guard let sub = book.submissions.first(where: { $0.id == submissionID }),
              let dir = book.directory(id: sub.directoryID),
              let repo = dir.repo, !repo.isEmpty else {
            return (false, "Submission or GitHub directory repo is missing.", nil)
        }
        guard let liveStore = model.liveStore else {
            return (false, "Live store is unavailable.", nil)
        }
        let preflight = await runPreflight(for: sub)
        guard preflight.ok else {
            return (false, preflight.errors.joined(separator: " "), nil)
        }

        let preview: String
        let targetPath: String
        let slug = DealFormatters.slug(for: sub.appName)
        let year = String(sub.startDate.prefix(4))
        if dir.kind == .githubJSONPR {
            targetPath = "\(year)/\(slug).json"
            preview = DealFormatters.indieGoodiesJSON(for: sub)
        } else {
            targetPath = "README.md"
            preview = DealFormatters.markdownTableRow(for: sub, directory: dir)
        }

        let payload: JSONValue = .object([
            "submission_id": .string(sub.id),
            "directory_id": .string(dir.id),
            "directory_name": .string(dir.name),
            "repo": .string(repo),
            "target_path": .string(targetPath),
            "target_section": .string(dir.targetSection ?? ""),
            "app": .string(sub.appName),
            "preview": .string(String(preview.prefix(4000))),
            "offer_code": .string(sub.offerCode ?? ""),
            "end_date": .string(sub.endDate),
        ])
        guard let jobID = try? await liveStore.enqueue(
            kind: "deal.pr",
            resource: "github",
            priority: 3,
            maxAttempts: 1,
            payload: payload,
            needsApproval: true
        ) else {
            return (false, "Couldn't queue deal PR for approval.", nil)
        }
        if let idx = book.submissions.firstIndex(where: { $0.id == sub.id }) {
            book.submissions[idx].status = .waitingApproval
            persist()
        }
        await model.refresh()
        return (true, "Queued \(sub.appName) → \(dir.name) PR in Log → Needs your OK.", jobID)
    }

    func executeApprovedPRJob(_ job: Job, model: AppModel) async -> (ok: Bool, note: String, prURL: String?) {
        guard case .object(let p) = job.payload,
              let subID = p["submission_id"]?.string,
              let sub = book.submissions.first(where: { $0.id == subID }),
              let dir = book.directory(id: sub.directoryID),
              let repo = dir.repo else {
            return (false, "Deal PR job is missing submission or directory details.", nil)
        }

        let slug = DealFormatters.slug(for: sub.appName)
        let branch = "add-\(slug)-deal"
        let workRoot = model.supportDirectory.appending(path: "DealWork", directoryHint: .isDirectory)
        let workDir = workRoot.appending(path: "\(slug)-\(UUID().uuidString.prefix(6))", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: workDir) }

        do {
            try FileManager.default.createDirectory(at: workRoot, withIntermediateDirectories: true)
            let forkRes = try await runShell(
                "/usr/bin/env",
                args: ["gh", "repo", "fork", repo, "--clone", "--", workDir.path],
                cwd: workRoot,
                extraArgs: ["--depth", "1", "--single-branch"]
            )
            if forkRes.code != 0 && !FileManager.default.fileExists(atPath: workDir.appending(path: ".git").path) {
                return (false, "Couldn't fork/clone \(repo): \(forkRes.output.prefix(240))", nil)
            }

            _ = try await runShell("/usr/bin/git", args: ["checkout", "-B", branch], cwd: workDir)

            let fileRelPath: String
            if dir.kind == .githubJSONPR {
                let year = String(sub.startDate.prefix(4))
                fileRelPath = "\(year)/\(slug).json"
                let fileURL = workDir.appending(path: fileRelPath)
                try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                let content = DealFormatters.indieGoodiesJSON(for: sub)
                try content.write(to: fileURL, atomically: true, encoding: .utf8)
            } else {
                fileRelPath = "README.md"
                let readmeURL = workDir.appending(path: "README.md")
                let existing = try String(contentsOf: readmeURL, encoding: .utf8)
                let row = DealFormatters.markdownTableRow(for: sub, directory: dir)
                guard let heading = dir.targetSection,
                      let updated = DealFormatters.appendRowToMarkdownSection(existing, row: row, heading: heading) else {
                    return (false, "Couldn't find target section \(dir.targetSection ?? "") in \(repo)/README.md.", nil)
                }
                try updated.write(to: readmeURL, atomically: true, encoding: .utf8)
            }

            let addRes = try await runShell("/usr/bin/git", args: ["add", fileRelPath], cwd: workDir)
            guard addRes.code == 0 else { return (false, "git add failed: \(addRes.output)", nil) }

            let commitMsg = "Add \(sub.appName) deal"
            let commitRes = try await runShell("/usr/bin/git", args: ["commit", "-s", "-m", commitMsg], cwd: workDir)
            guard commitRes.code == 0 else { return (false, "git commit failed: \(commitRes.output)", nil) }

            let pushRes = try await runShell("/usr/bin/git", args: ["push", "-u", "origin", branch, "--force-with-lease"], cwd: workDir)
            guard pushRes.code == 0 else { return (false, "git push failed: \(pushRes.output)", nil) }

            let prBody = "Added **\(sub.appName)** (\(sub.dealSummary), valid \(sub.startDate) – \(sub.endDate)) · \(sub.productURL)"
            let prRes = try await runShell(
                "/usr/bin/env",
                args: ["gh", "pr", "create", "--repo", repo, "--title", "Add \(sub.appName) (\(sub.dealSummary))", "--body", prBody],
                cwd: workDir
            )
            guard prRes.code == 0 else { return (false, "gh pr create failed: \(prRes.output)", nil) }

            let prURL = prRes.output.components(separatedBy: .whitespacesAndNewlines).first(where: { $0.contains("https://github.com/") && $0.contains("/pull/") })
            let prNumber = prURL.flatMap { URL(string: $0)?.lastPathComponent }.flatMap(Int.init)

            if let idx = book.submissions.firstIndex(where: { $0.id == sub.id }) {
                book.submissions[idx].status = .prOpen
                book.submissions[idx].prURL = prURL
                book.submissions[idx].prNumber = prNumber
                book.submissions[idx].branchName = branch
                book.submissions[idx].lastCheckedAt = DealPreflightValidator.todayISO()
                book.submissions[idx].lastNote = "Opened PR" + (prNumber.map { " #\($0)" } ?? "")
                persist()
            }
            return (true, prURL.map { "Opened PR: \($0)" } ?? "Opened PR on \(repo).", prURL)
        } catch {
            return (false, "PR failed: \(error.localizedDescription)", nil)
        }
    }

    func prepareEmailJob(submissionID: String, to: String, subject: String, body: String, model: AppModel) async -> (ok: Bool, note: String, jobID: Int64?) {
        guard let sub = book.submissions.first(where: { $0.id == submissionID }),
              let dir = book.directory(id: sub.directoryID),
              let liveStore = model.liveStore else {
            return (false, "Submission or live store unavailable.", nil)
        }
        guard SMTPConfig.isSingleEmail(to) else {
            return (false, "Enter a valid single recipient email address.", nil)
        }
        if let problem = Wording.rules.problem(subject) ?? Wording.rules.problem(body) {
            return (false, "Blocked by Words I never use: \(problem)", nil)
        }
        let payload: JSONValue = .object([
            "submission_id": .string(sub.id),
            "directory_id": .string(dir.id),
            "directory_name": .string(dir.name),
            "app": .string(sub.appName),
            "to": .string(to.trimmingCharacters(in: .whitespacesAndNewlines)),
            "subject": .string(String(subject.prefix(300))),
            "body": .string(String(body.prefix(10_000))),
        ])
        guard let jobID = try? await liveStore.enqueue(
            kind: "deal.email",
            resource: "mail",
            priority: 3,
            maxAttempts: 1,
            payload: payload,
            needsApproval: true
        ) else {
            return (false, "Couldn't queue deal pitch email.", nil)
        }
        if let idx = book.submissions.firstIndex(where: { $0.id == sub.id }) {
            book.submissions[idx].status = .waitingApproval
            persist()
        }
        await model.refresh()
        return (true, "Queued \(sub.appName) pitch for \(dir.name) in Log → Needs your OK.", jobID)
    }

    func executeApprovedEmailJob(_ job: Job) async -> (ok: Bool, note: String) {
        guard case .object(let p) = job.payload,
              let to = p["to"]?.string,
              let subject = p["subject"]?.string,
              let body = p["body"]?.string else {
            return (false, "Deal pitch job is missing email fields.")
        }
        let res = await MailSender.send(to: to, subject: subject, body: body)
        if res.ok, let subID = p["submission_id"]?.string,
           let idx = book.submissions.firstIndex(where: { $0.id == subID }) {
            book.submissions[idx].status = .submitted
            book.submissions[idx].lastCheckedAt = DealPreflightValidator.todayISO()
            book.submissions[idx].lastNote = "Sent via \(res.via)"
            persist()
        }
        return (res.ok, res.note)
    }

    // MARK: - Zero-Lag Background PR Watcher (URLSession + ETag)

    /// Polls open GitHub PRs on a calm 4-hour cadence after a 60s launch defer.
    /// Does zero work when no PRs are open and never blocks @MainActor.
    func pollOpenPRsIfDue(force: Bool = false) async {
        let openIndices = book.submissions.indices.filter {
            book.submissions[$0].status == .prOpen || book.submissions[$0].status == .needsFix
        }
        guard !openIndices.isEmpty else { return }
        if !force {
            if Date.now.timeIntervalSince(launchedAt) < 60 { return }
            if let until = rateLimitUntil, Date.now < until { return }
            if let last = lastPollAt, Date.now.timeIntervalSince(last) < 4 * 3600 { return }
        }
        guard !isPolling else { return }
        isPolling = true
        defer { isPolling = false; lastPollAt = .now }

        let token = await Task.detached(priority: .utility) { Self.ghAuthToken() }.value
        var changed = false

        for idx in openIndices {
            let sub = book.submissions[idx]
            guard let dir = book.directory(id: sub.directoryID),
                  let repo = dir.repo,
                  let prNum = sub.prNumber else { continue }
            guard let apiURL = URL(string: "https://api.github.com/repos/\(repo)/pulls/\(prNum)") else { continue }

            let outcome = await Self.fetchPRState(url: apiURL, etag: sub.prETag, token: token)
            switch outcome {
            case .notModified:
                continue
            case .rateLimited(let retryAfter):
                rateLimitUntil = Date.now.addingTimeInterval(max(900, retryAfter))
                return
            case .failed:
                continue
            case .updated(let state, let merged, let commentsCount, let newETag):
                var item = book.submissions[idx]
                item.prETag = newETag
                item.lastCheckedAt = DealPreflightValidator.todayISO()
                if merged {
                    item.status = .listed
                    item.liveListingURL = DealFormatters.resolveLiveListingURL(for: item, directory: dir)
                    item.lastNote = "PR #\(prNum) merged"
                } else if state == "closed" {
                    let commentText = await Self.fetchLatestComment(repo: repo, prNumber: prNum, token: token)
                    if let resolved = DealFormatters.resolveLiveListingURL(for: item, directory: dir, mergeComment: commentText),
                       commentText?.localizedCaseInsensitiveContains("merged") == true {
                        item.status = .listed
                        item.liveListingURL = resolved
                        item.lastNote = "Listed via follow-up merge"
                    } else {
                        item.status = .needsFix
                        item.lastNote = commentText.map { String($0.prefix(160)) } ?? "PR #\(prNum) closed"
                    }
                } else if commentsCount > 0 {
                    let commentText = await Self.fetchLatestComment(repo: repo, prNumber: prNum, token: token)
                    if let commentText, !commentText.isEmpty {
                        item.status = .needsFix
                        item.lastNote = String(commentText.prefix(160))
                    }
                }
                if item != book.submissions[idx] {
                    book.submissions[idx] = item
                    changed = true
                }
            }
        }

        if changed { persist() }
    }

    private enum PRFetchOutcome {
        case notModified
        case rateLimited(TimeInterval)
        case failed
        case updated(state: String, merged: Bool, comments: Int, etag: String?)
    }

    private nonisolated static func fetchPRState(url: URL, etag: String?, token: String?) async -> PRFetchOutcome {
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        if let etag, !etag.isEmpty { req.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        if let token, !token.isEmpty { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else { return .failed }
            if http.statusCode == 304 { return .notModified }
            if http.statusCode == 403 || http.statusCode == 429 {
                let retry = TimeInterval(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 1800
                return .rateLimited(retry)
            }
            guard http.statusCode == 200,
                  let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .failed
            }
            let state = (obj["state"] as? String ?? "open").lowercased()
            let merged = obj["merged"] as? Bool ?? false
            let comments = (obj["comments"] as? Int ?? 0) + (obj["review_comments"] as? Int ?? 0)
            let newETag = http.value(forHTTPHeaderField: "ETag")
            return .updated(state: state, merged: merged, comments: comments, etag: newETag)
        } catch {
            return .failed
        }
    }

    private nonisolated static func fetchLatestComment(repo: String, prNumber: Int, token: String?) async -> String? {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/issues/\(prNumber)/comments?per_page=5") else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        if let token, !token.isEmpty { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return nil
        }
        return arr.last?["body"] as? String
    }

    private nonisolated static func ghAuthToken() -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["gh", "auth", "token"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return out?.isEmpty == false ? out : nil
    }

    private func runShell(_ exe: String, args: [String], cwd: URL, extraArgs: [String] = []) async throws -> (code: Int32, output: String) {
        try await Task.detached(priority: .userInitiated) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: exe)
            p.arguments = args + extraArgs
            p.currentDirectoryURL = cwd
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            try p.run()
            p.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
        }.value
    }
}
