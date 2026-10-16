import SwiftUI
import AgentHUDCore

/// The hover panel's sessions section: which sessions it lists, and each one's row with the way back to its agent, its
/// questions and its usage.
extension HoverPanelView {
    /// What is waiting, running and recently ended: the sessions with work in flight first — those waiting for the
    /// user ahead of those still running — then those last active in the past day, up to the layout's limit, five by
    /// default, of the agents and states it lists. The remaining count includes every other session the filter keeps in
    /// that summary, and a filter that keeps none says so in one line under the header. The statistics window's range
    /// never applies here — that range belongs to the session card, which answers a different question. The header
    /// opens the session list; each row's title returns to its agent, or opens its session page where the client names
    /// no destination, and its token count opens usage. Its gaps follow the layout's spacing, and its divider the
    /// layout's separators. On the panel's picture for an agent a row is named by its place in the list, with no title
    /// and no project.
    func sessionLine(_ filter: PanelSessionFilter, hasAbove: Bool, spacing: PanelSpacingMetrics, divider: Color) -> some View {
        let rows = Self.sessionRows(store, vendor: focusVendor, filter: filter)
        let shown = rows.shown, status = Self.sessionStatus(rows)
        return VStack(alignment: .leading, spacing: spacing.sessionRows) {
            Button { openSessions() } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(L10n.text("会话", "Sessions"))
                        .font(.ui(13, .semibold)).foregroundStyle(theme.text)
                    Spacer()
                    // Without a status the line keeps its room, so the header is as tall either way.
                    Text(status ?? L10n.text("最近结束", "Recently ended"))
                        .font(.tabular(12)).foregroundStyle(theme.secondary)
                        .opacity(status == nil ? 0 : 1)
                        .accessibilityHidden(status == nil)
                }
                .contentShape(Rectangle())
            }
            .help(L10n.text("查看会话列表", "Show sessions"))
            .accessibilityIdentifier("island-sessions")
            if shown.isEmpty {
                Text(Self.emptySessionsLine(rows))
                    .foregroundStyle(theme.secondary)
            } else {
                ForEach(Array(shown.enumerated()), id: \.element.id) { index, session in
                    sessionRow(session, position: index + 1)
                }
                if rows.more > 0 {
                    Button { openSessions() } label: {
                        Text(L10n.text("还有 \(rows.more) 个", "+\(rows.more) more"))
                            .foregroundStyle(theme.secondary)
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .font(.ui(12))
        .padding(.top, hasAbove ? spacing.divided : 0)
        .topDivider(hasAbove ? divider : .clear)
    }

    /// One session's row. Masked, its title, its project and its questions give way to its place in the list, and
    /// nothing written from them is left: no help, no label, no question card.
    private func sessionRow(_ session: LiveSession, position: Int) -> some View {
        let masked = masksIdentity
        let name = masked ? IdentityMask.session(at: position) : session.task
        let asks = Self.questionRequests(for: session, waiting: waitingRequests)
        let expanded = answeringSessionID == session.id && !asks.isEmpty && !masked
        let failed = failedListedSessionID == session.id
        let tokens = "\(TokenFormat.short(session.tokensIn + session.tokensOut)) tok"
        let dot = Self.sessionDot(session, store: store)
        let destination: String = session.navigationTarget != nil
            ? L10n.text("返回会话", "Return to session") : L10n.text("查看会话详情", "Show session details")
        let help: String = masked ? "" : session.task + "\n" + destination
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Button { open(session) } label: {
                    HStack(spacing: 8) {
                        sessionMark(session, dot: dot)
                        Text(masked ? name : Self.sessionTitle(session))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .help(help)
                .accessibilityLabel(L10n.text("打开会话：", "Open session: ") + name)
                .accessibilityHint(session.navigationTarget != nil
                                   ? L10n.text("在 agent 中打开", "Open in the agent")
                                   : L10n.text("打开此会话的详情页", "Open this session's detail page"))
                .accessibilityIdentifier("island-session-return-\(session.id)")

                if !asks.isEmpty {
                    questionBadge(asks, session: session, name: name, expanded: expanded)
                }

                Button { openSessions(session.id) } label: {
                    Text(tokens)
                        .fixedSize()
                        .contentShape(Rectangle())
                }
                .help(L10n.text("查看此会话的用量", "View this session's token usage"))
                .accessibilityLabel(L10n.text("查看会话用量：", "View token usage: ") + name)
                .accessibilityValue(tokens)
                .accessibilityIdentifier("island-session-usage-\(session.id)")
            }
            .foregroundStyle(theme.secondary)
            if failed {
                Text(session.navigationTarget != nil
                     ? L10n.text("返回失败，点击标题重试", "Couldn't return. Click the title to retry.")
                     : L10n.text("无法返回此会话", "Session return unavailable"))
                    .font(.ui(11))
                    .foregroundStyle(theme.status(.warning))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 14)
            }
            if expanded {
                questionAnswer(asks, session: session)
            }
        }
    }

    /// Back to the agent where its client names a destination; where none exists, the session's own page, so a row
    /// always leads to that conversation rather than nowhere.
    private func open(_ session: LiveSession) {
        if session.navigationTarget != nil { onOpenListedSession(session.id) } else { openSessions(session.id) }
    }

    /// The agent's mark with the session's state on its corner: its own colour while it runs, the warning colour
    /// while it waits for the user, grey once it ends. A source without a bundled mark falls back to the dot alone.
    private func sessionMark(_ session: LiveSession, dot: SessionDot) -> some View {
        let color = dotColor(dot, session: session)
        guard let vendor = store.sessionSource(session).agentVendor, !vendor.isEmpty else {
            return AnyView(Circle().fill(color).frame(width: 6, height: 6))
        }
        return AnyView(
            ZStack(alignment: .bottomTrailing) {
                AgentLogo(vendor: vendor, size: 14)
                Circle().fill(color)
                    .frame(width: 6, height: 6)
                    .overlay(Circle().stroke(theme.windowBackground, lineWidth: 1.5))
                    .offset(x: 2, y: 2)
            }
            .frame(width: 14, height: 14)
            .opacity(dot == .ended ? 0.7 : 1)
        )
    }

    /// How many questions this session waits on, and where answering them opens. `name` is how the row names the
    /// session.
    private func questionBadge(_ asks: [PermissionRequest], session: LiveSession, name: String, expanded: Bool) -> some View {
        Button {
            onAnswerSession(expanded ? nil : session.id)
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "questionmark.bubble.fill")
                    .font(.system(size: 9, weight: .semibold))
                if asks.count > 1 {
                    Text("\(asks.count)").font(.tabular(9, .semibold))
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Capsule().fill(theme.status(.warning).opacity(0.16)))
            .foregroundStyle(theme.status(.warning))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(L10n.text("有 \(asks.count) 个提问待回答，点击在此展开",
                        "\(asks.count) questions waiting for an answer — click to answer here"))
        .accessibilityLabel(L10n.text("待回答的提问：", "Questions waiting: ") + name)
        .accessibilityValue(L10n.text("\(asks.count) 个", "\(asks.count)"))
        .accessibilityIdentifier("island-session-question-\(session.id)")
        .accessibilityAddTraits(expanded ? [.isSelected] : [])
    }

    /// The questions themselves, answered right here the way the island's own card answers them, beside the way
    /// back to the agent for answering them there instead.
    private func questionAnswer(_ asks: [PermissionRequest], session: LiveSession) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(asks) { request in
                PermissionQuestionCard(request: request) { decision in
                    if case .answer = decision { onAnswerSession(nil) }
                    PermissionRequests.shared.resolve(request.id, decision)
                }
            }
            HStack(spacing: 6) {
                Button {
                    onAnswerSession(nil)
                    open(session)
                } label: {
                    HStack(spacing: 4) {
                        Text(session.navigationTarget != nil
                             ? L10n.text("在 Agent 中回答", "Answer in the agent")
                             : L10n.text("查看会话", "View session"))
                        Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold))
                    }
                }
                Spacer(minLength: 8)
                Button { onAnswerSession(nil) } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.up").font(.system(size: 8, weight: .bold))
                        Text(L10n.text("收起", "Hide"))
                    }
                }
            }
            .font(.ui(11, .medium))
            .foregroundStyle(theme.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(theme.text.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.cardBorder))
        .padding(.leading, 14)
        .accessibilityIdentifier("island-session-question-card-\(session.id)")
    }

    /// The statistics window on its Sessions page: the list, or one session's page.
    private func openSessions(_ id: String? = nil) {
        store.focusedSessionID = id
        store.statsTab = .sessions
        onOpenStats()
    }

    /// The island's summary: local work in flight and sessions last active in the past day, with waiting before
    /// running, newest created first, then the most recently ended, of the agents and states `filter` keeps and as
    /// many as it allows (`ReportView.panelSessions(_:vendor:)`). The full session list holds any hidden rows.
    /// `vendor` keeps only the sessions of the agents drawn with that vendor's mark, and the filter applies among them.
    static func sessionRows(_ store: UsageStore, vendor: String? = nil,
                            filter: PanelSessionFilter = PanelSessionFilter()) -> PanelSessionRows {
        store.view.panelSessions(filter, vendor: vendor)
    }

    /// What the header says beside its name: how many of the listed sessions are in flight, or that those listed have
    /// ended; nil where the layout's filter keeps none of the sessions there are, which the line under the header says,
    /// so the header claims no state of sessions it leaves out.
    static func sessionStatus(_ rows: PanelSessionRows) -> String? {
        guard !rows.noneMatch else { return nil }
        return rows.running.isEmpty ? L10n.text("最近结束", "Recently ended")
            : L10n.text("\(rows.running.count) 个运行中", "\(rows.running.count) running")
    }

    /// What the section says without rows: that the layout's filter keeps none of the sessions there are, or that there
    /// are none yet.
    static func emptySessionsLine(_ rows: PanelSessionRows) -> String {
        rows.noneMatch ? L10n.text("没有符合条件的会话", "No sessions match") : L10n.text("还没有会话", "No sessions yet")
    }

    /// The vendor's newest session, among those of the past week drawn with its mark, that its client names a
    /// destination for: where the vendor's logo and name in the quota list lead. Nil when none does.
    static func latestDestination(_ store: UsageStore, vendor: String) -> String? {
        let mark = AgentArtwork.markKey(vendor)
        return store.view.recentSessions.first {
            !$0.session.accountWide && $0.session.navigationTarget != nil
                && ($0.source.agentVendor ?? $0.source.vendor).map(AgentArtwork.markKey) == mark
        }?.id
    }

    /// The questions this session is waiting on: only a question put to this exact session reaches its row.
    static func questionRequests(for session: LiveSession, waiting: [PermissionRequest]) -> [PermissionRequest] {
        waiting.filter { $0.sessionID == session.id && $0.isQuestion }
    }

    /// A running session wears its agent's colour, one blocked on the user the warning colour, and an ended one grey.
    static func sessionDot(_ session: LiveSession, store: UsageStore) -> SessionDot {
        SessionDot(store.view.phase(of: session))
    }

    private func dotColor(_ dot: SessionDot, session: LiveSession) -> Color {
        switch dot {
        case .waiting: return theme.status(.warning)
        case .running: return AgentPalette.swiftUIColor(index: store.consumerPaletteIndex(session.agentId))
        case .ended: return theme.dotEnded
        }
    }

    static func sessionTitle(_ session: LiveSession) -> String {
        guard let terminal = session.terminal, !terminal.isEmpty else { return session.task }
        return "\(shortTask(session.task)) · \(terminal)"
    }

    /// "fix auth bug in middleware" → "fix auth bug"
    static func shortTask(_ task: String) -> String {
        let words = task.split(separator: " ")
        if words.count > 3 { return words.prefix(3).joined(separator: " ") }
        return String(task.prefix(14))
    }
}
