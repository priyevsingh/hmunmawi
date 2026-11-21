import Foundation
import HmunmawiProtocol

/// Validates multipart worker metadata the app uploads (local only; no Cloudflare calls).
enum WorkerDeployMetadata {
    /// When the hooks worker URL is already saved, deploy must target that account—not the token's first account.
    static func pickHookDeployAccount(list: [[String: Any]], pinned: String?) throws -> String {
        let ids = list.compactMap { $0["id"] as? String }
        if let pinned, ids.contains(pinned) { return pinned }
        // A token scoped to one account (Workers Scripts and KV only, no account read) lists no accounts at all;
        // the account the worker was deployed to is still the right one, and Cloudflare refuses the upload if not.
        if let pinned, ids.isEmpty, pinned.wholeMatch(of: /[0-9a-f]{32}/) != nil { return pinned }
        if let first = ids.first { return first }
        throw WireError("cf", "That token can't see a Cloudflare account. Create it with Account → Workers Scripts: Edit and Workers KV Storage: Edit.")
    }

    static func validateHooksV2(bindings: [[String: Any]], metadata: [String: Any], moduleNames: [String]) -> [String] {
        var issues: [String] = []
        let requiredModules = Set(["worker.mjs", "workerCore.mjs", "ascRelayDO.mjs", "ascKvImport.mjs", "verify.mjs", "x509.mjs", "root.mjs"])
        let missingModules = requiredModules.subtracting(moduleNames)
        if !missingModules.isEmpty { issues.append("missing modules: \(missingModules.sorted().joined(separator: ", "))") }
        if metadata["main_module"] as? String != "worker.mjs" { issues.append("main_module must be worker.mjs") }
        let names = Set(bindings.compactMap { $0["name"] as? String })
        if !names.contains("ASC_RELAY") { issues.append("ASC_RELAY durable object binding required for v2") }
        if !names.contains("OUTBOX") { issues.append("OUTBOX kv binding required") }
        let migrations = metadata["migrations"] as? [[String: Any]] ?? []
        let hasSqlite = migrations.contains { ($0["new_sqlite_classes"] as? [String])?.contains("AscRelayDO") == true }
        if !hasSqlite { issues.append("migrations must include new_sqlite_classes AscRelayDO") }
        if (metadata["migration_tag"] as? String)?.isEmpty != false { issues.append("migration_tag required") }
        return issues
    }
}
