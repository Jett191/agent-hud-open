import AgentHUDSupport
import Foundation

/// Devin CLI's account and quota reading. The CLI caches its `GetUserStatus` answer at
/// `~/.cache/devin/cli/user_status.<digest>.bin`: a JSON envelope `{version, identity_digest, fetched_at_secs,
/// payload}` whose payload is the base64 of a protobuf response carrying the plan, its quota windows and their
/// reset times. Field 13 is the subscription: inside it `1.2` names the plan, `14` and `15` are the weekly and
/// daily shares used, `17` and `18` the daily and weekly reset times, and `2.1`/`3.1` bound the billing month.
/// A zero share is absent from the bytes, as proto3 omits defaults; the root's 3, 5 and 7 hold the user's
/// name, their `team$account` slug and their email.
enum DevinQuota {
    /// One decoded message: its fields in order of appearance, grouped by field number.
    private typealias ProtoFields = [Int: [AntigravityProtoReader.Field]]

    static func read() async throws -> ProviderQuota {
        let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache/devin/cli")
        return try quota(in: directory, now: Date())
    }

    /// The quota of the newest cache file that parses, tried newest first. No file means the client never
    /// reported its status; files that do not parse mean the answer's shape changed.
    static func quota(in directory: URL, now: Date) throws -> ProviderQuota {
        let files: [URL] = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        var candidates: [(url: URL, modified: Date)] = []
        for url in files where url.lastPathComponent.hasPrefix("user_status.") && url.lastPathComponent.hasSuffix(".bin") {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            candidates.append((url, modified))
        }
        candidates.sort { lhs, rhs in
            if lhs.modified != rhs.modified { return lhs.modified > rhs.modified }
            return lhs.url.lastPathComponent > rhs.url.lastPathComponent
        }
        guard !candidates.isEmpty else { return ProviderQuota(client: "Devin CLI", signedOut: true) }
        for (url, _) in candidates {
            try Task.checkCancellation()
            if let quota = quota(from: url, now: now) { return quota }
        }
        return ProviderQuota(notice: L10n.text("Devin CLI 缓存额度不可用，请在 CLI 中刷新",
            "Devin CLI cached quota is unavailable; refresh in the CLI"), client: "Devin CLI")
    }

    /// The quota of one envelope's protobuf payload, nil when it holds nothing this reader knows.
    private static func quota(from url: URL, now: Date) -> ProviderQuota? {
        guard let envelope = try? ProviderFiles.json(url),
              let base64 = envelope["payload"].stringValue,
              let payload = Data(base64Encoded: base64) else { return nil }
        let observedAt = envelope["fetched_at_secs"].numberValue
            .flatMap { $0 > 0 && $0 <= 253402300799 ? Date(timeIntervalSince1970: $0) : nil }
            ?? (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? now
        let root = fields([UInt8](payload)[...])
        guard let status = message(root, 13) else { return nil }
        let windows = [
            window(status, percent: 15, reset: 17, id: "devin:daily",
                   label: L10n.text("每日额度", "Daily limit"), period: .day, observedAt: observedAt),
            window(status, percent: 14, reset: 18, id: "devin:weekly",
                   label: L10n.text("每周额度", "Weekly limit"), period: .week, observedAt: observedAt),
        ].compactMap { $0 }
        let plan = message(status, 1).flatMap { string($0, 2) }
        guard plan != nil || !windows.isEmpty else { return nil }
        let email = string(root, 7)
        var quota = ProviderQuota(windows: windows, plan: plan,
            account: .identified(provider: "Devin", user: email, workspace: string(root, 5)),
            label: email ?? string(root, 3), observedAt: observedAt, client: "Devin CLI")
        quota.sourceInfo = L10n.text("额度来自 Devin CLI 缓存；在 CLI 中刷新可更新读数",
            "Quota from Devin CLI cache; refresh in the CLI to update")
        return quota
    }

    /// A daily or weekly row: emitted when either its share or its reset is present, so a full window whose
    /// reset is all the answer carries is still listed. An absent share is proto3's zero — the CLI's own
    /// /usage reads it as 0% used — while a share that is present but over 100 is no percent and stays unknown.
    private static func window(_ status: ProtoFields, percent: Int, reset: Int,
                               id: String, label: String, period: WindowNames.Period,
                               observedAt: Date) -> ProviderQuota.Window? {
        let date = timestamp(status, reset)
        let used = self.percent(status, percent) ?? (status[percent] == nil && date != nil ? 0 : nil)
        guard used != nil || date != nil else { return nil }
        return ProviderQuota.Window(id: id, label: label,
            remaining: used.map(QuotaMath.remaining(usedPercent:)), reset: date,
            duration: period == .day ? 86400 : 7 * 86400, shortLabel: period.shortName, observedAt: observedAt)
    }

    /// The fields of one protobuf message grouped by number; empty when the bytes do not parse as a message.
    private static func fields(_ bytes: ArraySlice<UInt8>) -> ProtoFields {
        var reader = AntigravityProtoReader(bytes: Array(bytes))
        var grouped: ProtoFields = [:]
        while let field = reader.nextField() { grouped[field.number, default: []].append(field) }
        return reader.isMalformed ? [:] : grouped
    }

    private static func message(_ fields: ProtoFields, _ number: Int) -> ProtoFields? {
        (try? fields[number]?.last?.message()).map(Self.fields)
    }

    private static func string(_ fields: ProtoFields, _ number: Int) -> String? {
        fields[number]?.last.flatMap { try? $0.string() }
    }

    /// A percent as the CLI's /usage reports it; a value beyond 100 is some other counter, not an overage.
    private static func percent(_ fields: ProtoFields, _ number: Int) -> Double? {
        fields[number]?.last.flatMap { try? $0.integer() }.flatMap { $0 <= 100 ? Double($0) : nil }
    }

    private static func timestamp(_ fields: ProtoFields, _ number: Int) -> Date? {
        fields[number]?.last.flatMap { try? $0.integer() }
            .flatMap { $0 > 0 && $0 <= 253402300799 ? Date(timeIntervalSince1970: TimeInterval($0)) : nil }
    }
}
