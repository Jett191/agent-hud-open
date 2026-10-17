import AgentHUDSupport
import Foundation

/// WorkBuddy's plan ceilings: the rows the 429s its transcripts logged make, one per model, each shown while the
/// vendor's reset is ahead. The plans behind those models expose no quota endpoint, so a logged reset is the only
/// reading such a row has, unless the app reads the plan itself: a model whose call went through a GLM Coding Plan the
/// app reads from Zhipu shows that reading, and no ceiling row of its own.
///
/// A pass reads only the last week of transcripts, while a monthly ceiling can block a model for a month, so every
/// ceiling still ahead is kept until its reset passes, whether or not its transcript is still read, and across launches
/// in `fileURL`.
struct WorkBuddyCeilings: Sendable {
    /// What a pass can say about the ceiling rows of WorkBuddy's account.
    enum Inventory: Equatable, Sendable {
        /// Transcripts are still being indexed, so the ceilings read so far may not be all of them: nothing is claimed.
        case pending
        /// No ceiling is ahead and none of the rows the app shows is left to retire: there is no account to report.
        case none
        /// Every ceiling row the account has, by its id before the account scopes it; any other retires.
        case complete(Set<String>)
    }

    struct Rows: Sendable {
        var windows: [ProviderQuota.Window] = []
        var inventory: Inventory = .none
    }

    /// The ceilings still ahead, by their row's id before the account scopes it.
    private var held: [String: ProviderLimitHit] = [:]
    private let fileURL: URL?
    /// Where WorkBuddy's model list is read, to tell which GLM Coding Plan a model's calls went through.
    private let home: URL
    private var routes: (modified: Date, plans: [String: String])?

    /// - fileURL: where the ceilings still ahead are kept across launches; nil keeps them in memory.
    init(fileURL: URL? = nil, home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.fileURL = fileURL
        self.home = home
        if let data = fileURL.flatMap({ try? Data(contentsOf: $0) }),
           let saved = try? JSONDecoder().decode([ProviderLimitHit].self, from: data) {
            held = Dictionary(saved.map { ($0.rowID, $0) }, uniquingKeysWith: { $0.observedAt >= $1.observedAt ? $0 : $1 })
        }
    }

    /// This pass's ceiling rows for `account`. `logged` is every ceiling the transcripts this pass read hold; `agents` is
    /// every row the app shows, whose plan rows say which plans the app reads and whose ceiling rows may be left to retire.
    mutating func rows(logged: [ProviderLimitHit], indexing: Bool, agents: [AgentDescriptor], apiReached: Set<String>,
                       account: ProviderAccount, now: Date) -> Rows {
        hold(logged, now: now)
        // The plans whose quota the app reads, as their rows' billing pools say.
        let read = Set(agents.compactMap { $0.billingPool?.id })
        let plans = read.isEmpty || !held.values.contains(where: { $0.route != nil }) ? [:] : planRoutes()
        let shown = held.values.filter { hit in !(hit.route.flatMap { plans[$0] }.map(read.contains) ?? false) }
        // One row per model, its latest ceiling: two models can sit at their ceilings at once, and the model's own name
        // leads its row, since the window's period alone would not tell their rows apart.
        let latest = Dictionary(grouping: shown, by: \.model).values.compactMap { $0.max { $0.observedAt < $1.observedAt } }
        var rows = Rows()
        for hit in latest.sorted(by: { $0.model < $1.model }) {
            let model = WorkBuddySessions.displayName(hit.model, apiReached: hit.route == nil ? apiReached : apiReached.union([hit.model]))
            let duration = Self.durations[hit.window]
            rows.windows.append(.init(id: account.windowID(hit.rowID), label: "\(model) · \(Self.label(hit.window))", remaining: 0,
                                      reset: hit.reset, duration: duration,
                                      shortLabel: "\(model) · \(WindowNames.Period(seconds: duration)?.shortName ?? hit.window)",
                                      observedAt: hit.observedAt))
        }
        // While a ceiling is shown, or one the app still shows is gone, the rows are the account's complete inventory:
        // an expired ceiling's absence from it is what retires its row, instead of the row lingering as a pending reset.
        let retiring = agents.contains { $0.vendor == AdditionalSource.workbuddy.vendor && $0.id.contains("/limit:") }
        rows.inventory = indexing ? .pending : rows.windows.isEmpty && !retiring ? .none : .complete(Set(latest.map(\.rowID)))
        return rows
    }

    /// Adds the ceilings the transcripts logged that are still ahead, a later 429 of a model's window replacing an
    /// earlier one, and forgets those whose reset has passed.
    private mutating func hold(_ logged: [ProviderLimitHit], now: Date) {
        var kept = held.filter { $0.value.reset > now }
        for hit in logged where hit.reset > now && kept[hit.rowID].map({ $0.observedAt < hit.observedAt }) ?? true {
            kept[hit.rowID] = hit
        }
        guard kept != held else { return }
        held = kept
        guard let fileURL else { return }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
            try encoder.encode(kept.values.sorted { $0.rowID < $1.rowID }).write(to: fileURL, options: .atomic)
        } catch { NSLog("[AgentHUD] WorkBuddy ceiling cache write failed: %@", error.localizedDescription) }
    }

    /// The GLM Coding Plan each of WorkBuddy's model entries routes to, read again only when its model list changes.
    private mutating func planRoutes() -> [String: String] {
        let file = home.appendingPathComponent(".workbuddy/models.json")
        guard let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else { return [:] }
        if let routes, routes.modified == modified { return routes.plans }
        let plans = OpenAgentCredentials.workBuddyPlanRoutes(home: home)
        routes = (modified, plans)
        return plans
    }

    // MARK: Reading a 429

    /// One 429 ceiling a line logged, nil for anything else: only an incomplete answer that carries a 429 error reports
    /// one. The message names the window in the vendor's words and the reset as a wall-clock time in the vendor's own
    /// zone, Beijing time, whatever zone this Mac runs in. `call` is the session's latest successful call, the one the
    /// 429 interrupted, since the failed call itself records no model; a 429 before any success names nothing.
    static func hit(_ json: ProviderJSON, date: Date?, after call: (model: String, route: String?)?) -> ProviderLimitHit? {
        guard let date, let call, json["status"].stringValue == "incomplete",
              errorStatus(json["providerData"]["error"]) == 429,
              let message = TencentBuddySessions.nonEmpty(json["providerData"]["error"]["message"]),
              let window = ProviderLimitHit.windows.first(where: { message.contains(phrases[$0]!) }),
              let reset = resetDate(message) else { return nil }
        return ProviderLimitHit(model: call.model, route: call.route, window: window, reset: reset, observedAt: date)
    }

    /// How the vendor's words name each window its 429s report. A window whose words are missing is never matched.
    static let phrases: [String: String] = ["5h": "5 小时", "day": "每日", "week": "每周", "month": "每月"]

    private static func errorStatus(_ error: ProviderJSON) -> Int? {
        error["status"].numberValue.flatMap { $0 == $0.rounded() ? Int(exactly: $0) : nil }
            ?? error["status"].stringValue.flatMap(Int.init)
    }

    /// The reset time in the vendor's message, a wall-clock time in the vendor's own zone (`2026-10-14 01:06:03 重置`).
    private static func resetDate(_ message: String) -> Date? {
        guard let range = message.range(of: #"(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}) 重置"#, options: .regularExpression) else { return nil }
        return DateParsing.serverWallClock(String(message[range].dropLast(3)))
    }

    // MARK: Naming a row

    /// Each window's length, which the message itself does not carry. The month's is a guess at a calendar month, not a
    /// vendor's number: a monthly ceiling's row simply retires at its reset time, and only the pace of a forecast reads it.
    static let durations: [String: TimeInterval] = ["5h": 5 * 3600, "day": 86400, "week": 7 * 86400, "month": 30 * 86400]

    /// How a row names its window, in the vendor's own words where the transcripts quote them (`5 小时的使用上限`), else
    /// in the words the other plans' clients read. Its short name is the window's period (`WindowNames.Period`).
    static func label(_ window: String) -> String {
        switch window {
        case "5h": "5-hour usage limit"
        case "day": "Daily usage limit"
        case "week": "Weekly usage limit"
        default: "Monthly usage limit"
        }
    }
}

extension ProviderLimitHit {
    /// The id of the ceiling's row before the account scopes it: one row per model and window.
    var rowID: String { "limit:\(model):\(window)" }
}
