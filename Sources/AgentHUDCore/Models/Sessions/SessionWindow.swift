import Foundation

/// How long a session stays listed after its last activity, whatever window tokens are read for. Providers read their
/// logs for the host's `historyHours`, which a host can widen to a month for day totals and usage records; the sessions
/// they report are those active within these days, each with its whole sub-agent tree, and the turns and completions they
/// report are those of these sessions and trees. The Sessions page, the agent cards' sessions and the session records a
/// phone reads list the same days (`ReportView.recentSessions`).
public enum SessionWindow {
    public static let recency: TimeInterval = 7 * 86400

    /// The earliest last activity of a session reported at `now`.
    public static func start(at now: Date) -> Date { now.addingTimeInterval(-recency) }
}
