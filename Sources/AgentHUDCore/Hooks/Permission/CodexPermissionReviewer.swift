import AgentHUDSupport
import Foundation

/// Who reviews a Codex turn: its user, or Codex's own automatic review.
///
/// Codex asks its permission hook before it has chosen, and the request says only what is asked: its fields carry the
/// tool, its input, the session and the turn, and `permission_mode` is the approval policy, which is the same for
/// both. A request held for the user in a turn that automatic review would have answered holds that review up, so
/// only a turn known to be the user's reaches the HUD. The app learns who reviews a turn as the turn begins, from what
/// it already follows, and looks nothing up for a request it can answer from that:
/// - a Desktop thread it follows carries each turn's settings in its state;
/// - the reader of the session logs meets each turn's context record as the log grows, and remembers it.
/// A turn neither has told of yet is looked up in its log, from the end back: Codex writes the context when the turn
/// begins, so that reads what the turn itself has written and none of the conversation before it.
enum CodexPermissionReviewer {
    static func isUser(payload: JSONValue, reviewers: CodexTurnReviewers = .shared,
                       thread: @Sendable (String) -> JSONValue? = { CodexDesktopStream.shared.thread($0)?.state }) async -> Bool {
        guard let turn = payload["turn_id"].stringValue, !turn.isEmpty else { return false }
        if let session = payload["session_id"].stringValue, let state = thread(session),
           let followed = try? CodexDesktopQuestions.turn(turn, in: state), followed["params"].objectValue != nil {
            return followed["params"]["approvalsReviewer"].stringValue == "user"
        }
        if let remembered = reviewers.reviewer(of: turn) { return remembered == "user" }
        return await Task.detached(priority: .userInitiated) { recorded(payload) == "user" }.value
    }

    /// The reviewer the turn's newest context record in its log names; nil when it names none or cannot be read.
    static func recorded(_ payload: JSONValue) -> String? {
        guard let path = payload["transcript_path"].stringValue, !path.isEmpty,
              let turn = payload["turn_id"].stringValue, !turn.isEmpty else { return nil }
        var reviewer: String?
        try? ProviderFiles.linesFromEnd(URL(fileURLWithPath: path), marker: Data("\"turn_context\"".utf8)) { record in
            guard record["type"].stringValue == "turn_context",
                  record["payload"]["turn_id"].stringValue == turn else { return true }
            // The turn's newest context is the one that counts, a context without a reviewer included.
            reviewer = record["payload"]["approvals_reviewer"].stringValue
            return false
        }
        return reviewer
    }
}

/// The reviewer of each recent Codex turn whose context record the log reader has met, kept while the app runs. A
/// turn that began before the app did, or long ago, is not here, and is looked up in its log.
///
/// The reader can meet a log's records out of order, its newest turns first and then its history page by page, so a
/// record is placed by its own time rather than by when it was read.
final class CodexTurnReviewers: @unchecked Sendable {
    static let shared = CodexTurnReviewers()
    /// Turns are short-lived questions: the newest ones are the ones asked about.
    static let limit = 512
    /// A context record older than this is history read for other ends: a turn that asks for approval began recently.
    static let recent: TimeInterval = 24 * 60 * 60

    private struct Entry {
        let reviewer: String?
        let at: Date
    }

    private let lock = NSLock()
    private var reviewers: [String: Entry] = [:]

    /// A turn's context record as read: the reviewer it names, or that it names none, and the record's own time; a record
    /// with no time counts as written now. A record older than `recent` is passed over, and an older record of a turn
    /// never takes the place of a newer one. Beyond `limit` turns, the one with the oldest record goes.
    func note(turn: String, reviewer: String?, at: Date? = nil, now: Date = Date()) {
        let at = at ?? now
        guard now.timeIntervalSince(at) < Self.recent else { return }
        lock.withLock {
            if let earlier = reviewers[turn], earlier.at > at { return }
            reviewers[turn] = Entry(reviewer: reviewer, at: at)
            guard reviewers.count > Self.limit, let oldest = reviewers.min(by: { $0.value.at < $1.value.at })?.key else { return }
            reviewers.removeValue(forKey: oldest)
        }
    }

    /// The reviewer of a turn whose record was met: nil inside for a record that names none. Nil for a turn not met.
    func reviewer(of turn: String) -> String?? { lock.withLock { reviewers[turn].map(\.reviewer) } }
}
