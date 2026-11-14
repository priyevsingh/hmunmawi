import Foundation
import HmunmawiCore

/// "Add my app to the Wall of Apps": looks the app up on the App Store, then opens a pull request on the project
/// that adds it to docs/wall-of-apps.json, through your own GitHub CLI login (`gh`): fork if needed, a branch, the
/// file change, the pull request. Nothing is sent without your confirm (or `confirm=1` from an agent); a dry run
/// only says what it would do. Hmunmawi never holds a GitHub token.
enum WallSubmit {
    static var gh: String? {
        ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func lookup(_ raw: String) async -> Result<WallOfApps.Entry, Failure> {
        guard let id = WallOfApps.appID(raw), let u = WallOfApps.lookupURL(id) else { return .failure(.init("Enter the app's App Store ID (digits) or its App Store link.")) }
        guard let (d, r) = try? await URLSession.shared.data(from: u), (r as? HTTPURLResponse)?.statusCode == 200 else {
            return .failure(.init("Couldn't reach the App Store. Try again in a moment."))
        }
        guard let e = WallOfApps.entry(fromLookup: d) else { return .failure(.init("No public App Store app with that ID.")) }
        return .success(e)
    }

    struct Failure: Error { let text: String; init(_ t: String) { text = t } }

    /// Opens the pull request (or with `dryRun`, only describes it). Returns the plan or the PR address.
    static func submit(_ e: WallOfApps.Entry, dryRun: Bool) async -> Result<String, Failure> {
        guard let gh else { return .failure(.init("Needs the GitHub CLI (brew install gh, then gh auth login).")) }
        let repo = WallOfApps.repo, path = WallOfApps.path
        guard case .ok(let login) = await run(gh, ["api", "user", "-q", ".login"]), !login.isEmpty else {
            return .failure(.init("Sign in to GitHub first: run gh auth login in Terminal."))
        }
        let target = login.lowercased() == repo.split(separator: "/")[0].lowercased() ? repo : "\(login)/hmunmawi"
        let branch = "wall-" + (e.link.firstMatch(of: /id(\d+)/).map { String($0.1) } ?? String(Int(Date.now.timeIntervalSince1970)))
        let plan = "\(target == repo ? "" : "Fork \(repo) as \(target), then ")create branch \(branch), add “\(e.app)” to \(path), and open a pull request on \(repo) as @\(login)."
        if dryRun { return .success(plan) }
        if target != repo {
            _ = await run(gh, ["api", "-X", "POST", "repos/\(repo)/forks"])
            for _ in 0..<10 { if case .ok = await run(gh, ["api", "repos/\(target)", "-q", ".full_name"]) { break }; try? await Task.sleep(for: .seconds(3)) }
        }
        guard case .ok(let base) = await run(gh, ["api", "repos/\(repo)/git/ref/heads/main", "-q", ".object.sha"]) else {
            return .failure(.init("Couldn't read the project on GitHub."))
        }
        _ = await run(gh, ["api", "-X", "POST", "repos/\(target)/git/refs", "-f", "ref=refs/heads/\(branch)", "-f", "sha=\(base)"])
        var wall: [WallOfApps.Entry] = []
        if case .ok(let b64) = await run(gh, ["api", "repos/\(repo)/contents/\(path)", "-q", ".content"]),
           let d = Data(base64Encoded: b64.replacingOccurrences(of: "\n", with: "")) {
            wall = (try? JSONDecoder().decode([WallOfApps.Entry].self, from: d)) ?? []
        }
        let body = WallOfApps.encode(WallOfApps.merged(wall, adding: e)).base64EncodedString()
        var args = ["api", "-X", "PUT", "repos/\(target)/contents/\(path)", "-f", "message=Wall of Apps: add \(e.app)",
                    "-f", "content=\(body)", "-f", "branch=\(branch)"]
        if case .ok(let sha) = await run(gh, ["api", "repos/\(target)/contents/\(path)?ref=\(branch)", "-q", ".sha"]), !sha.isEmpty { args += ["-f", "sha=\(sha)"] }
        guard case .ok = await run(gh, args) else { return .failure(.init("Couldn't write the change on GitHub.")) }
        let pr = await run(gh, ["api", "-X", "POST", "repos/\(repo)/pulls", "-f", "title=Wall of Apps: add \(e.app)",
                                "-f", "head=\(login):\(branch)", "-f", "base=main",
                                "-f", "body=Adds \(e.app) (\(e.link)) to the Wall of Apps.", "-q", ".html_url"])
        if case .ok(let url) = pr { return .success(url) }
        return .failure(.init("The change is on branch \(branch) of \(target), but the pull request couldn't be opened."))
    }

    enum Out { case ok(String), fail(String) }
    static func run(_ exe: String, _ args: [String]) async -> Out {
        await Task.detached {
            let p = Process(), out = Pipe()
            p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
            p.standardOutput = out; p.standardError = out; p.standardInput = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return .fail("couldn't start") }
            let d = out.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
            let t = String(decoding: d, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return p.terminationStatus == 0 ? .ok(t) : .fail(t)
        }.value
    }
}
