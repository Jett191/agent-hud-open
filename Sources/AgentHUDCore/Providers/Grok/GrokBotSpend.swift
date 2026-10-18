import AgentHUDSupport
import Foundation

/// The dashboard's per-bot metered usage. `GetDailySpendByCategory` groups an account's spend rows by the bot that
/// incurred them; each row carries one bot's total for one day. Included-usage plans write no rows, so an account
/// without metered spend answers an empty `dailySpend`, which is data, not a failure.
enum GrokBotSpend {
    private static let spendEndpoint = URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetDailySpendByCategory")!
    private static let meEndpoint = URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetMe")!
    /// Rows grouped under a name that is no bot id are unattributed; the dashboard folds them into this bucket.
    static let unattributed = "other-bots"

    /// The app's own usage-breakdown request: `SpendGroupByCategory.GROK_BOT` scoped to the desktop client and the
    /// sand product, matching the calls Grok Bot's settings page makes for its chart. The reply's shape is verified
    /// against the proto schemas embedded in the app's bundle: `GetDailySpendByCategoryResponse` carries
    /// `daily_spend` (`dailySpend`) rows of `DailySpendByCategory{day, category, spend_cents, total_tokens}`.
    static func dailySpend(auth: CursorClient.Session, since: Date, until: Date,
                           http: ProviderHTTP = ProviderHTTP()) async throws -> ProviderJSON {
        let headers = ["Authorization": "Bearer \(auth.token)", "Connect-Protocol-Version": "1"]
        var body: [String: ProviderJSON] = [
            "periodStartMs": .string(String(RecordCoding.milliseconds(since))),
            "periodEndMs": .string(String(RecordCoding.milliseconds(until))),
            "groupBy": .string("GROK_BOT"), "spendType": .string("ALL"),
            "clientType": .string("grok-bot"), "products": .array([.string("sand")]),
            "includeCreditUsage": .bool(true),
        ]
        if let me = try? await http.json(meEndpoint, headers: headers, body: .object([:]), timeout: 5),
           let user = me["userId"].stringValue ?? me["userId"].countValue.map(String.init) {
            body["userId"] = .string(user)
        }
        return try await http.json(spendEndpoint, headers: headers, body: .object(body), timeout: 12)
    }

    /// Rows join the billing namespace they share: each conversation keeps one `cursor-account` session for the
    /// exact-native-id join. A conversation the request-level events already billed keeps them, since a daily total
    /// would count the same usage a second time and carries no model or input/output split.
    static func merged(_ reply: ProviderJSON, account: String, into billing: ProviderSessions) -> ProviderSessions {
        var totals: [String: [Date: Int]] = [:]
        let billed = Set(billing.sessions.map(\.id))
        for row in reply["dailySpend"].arrayValue ?? [] {
            guard let category = row["category"].stringValue,
                  let day = ProviderDate.milliseconds(row["day"]),
                  let tokens = tokens(row["totalTokens"]), tokens > 0 else { continue }
            let conversation = category == "Other" || category == "unattributed" ? unattributed : category
            guard GrokBotCache.isAgentID(conversation) else { continue }
            let id = "cursor-account:\(account):\(conversation)"
            guard !billed.contains(id) else { continue }
            totals[conversation, default: [:]][day, default: 0] += tokens
        }
        guard !totals.isEmpty else { return billing }
        var result = billing
        for conversation in totals.keys.sorted() {
            let events = totals[conversation, default: [:]].sorted { $0.key > $1.key }.map { day, tokens in
                ProviderEvent(id: "spend-\(conversation)-\(Int(day.timeIntervalSince1970))",
                    model: "grok-bot", timestamp: day, input: tokens, output: 0)
            }
            let subagent = GrokBotUsage.subagentID(conversation)
            result.sessions.append(ProviderSession(id: "cursor-account:\(account):\(conversation)",
                title: subagent.map { L10n.text("Grok Bot 子代理", "Grok Bot subagent") + " · " + $0.prefix(8) }
                    ?? "Cursor · \(conversation.prefix(8))",
                client: subagent == nil ? "Cursor" : "Grok Bot", events: events, accountWide: true))
        }
        return result
    }

    /// int64 fields serialize as strings in Connect JSON but arrive as numbers in fixtures and older replies.
    private static func tokens(_ value: ProviderJSON) -> Int? {
        if let count = value.countValue { return count }
        if let text = value.stringValue, let count = Int64(text), count >= 0 { return Int(exactly: count) }
        return nil
    }
}
