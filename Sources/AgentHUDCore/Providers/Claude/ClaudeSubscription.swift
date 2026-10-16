import Foundation

/// The account profile supplies the plan, its specific tier and the account; the engine's own plan is the fallback.
enum ClaudeSubscription {
    /// `CLAUDE_CONFIG_DIR`, when it is set.
    static func configDirectory(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        ClientHome.variable("CLAUDE_CONFIG_DIR", in: environment).map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// Claude Code's configuration directory: `CLAUDE_CONFIG_DIR`, else `~/.claude`. The account profile and the hooks
    /// written into its settings both follow it.
    static func directory(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                          environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        configDirectory(environment) ?? home.appendingPathComponent(".claude", isDirectory: true)
    }

    /// Inside a configured directory, beside the default one.
    static var accountProfileURL: URL {
        (configDirectory() ?? FileManager.default.homeDirectoryForCurrentUser).appendingPathComponent(".claude.json")
    }

    /// `ClientHome.key` of the Claude Code configuration directory this app reads.
    static var home: String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return ClientHome.key(directory(home: home), defaultDirectory: home.appendingPathComponent(".claude", isDirectory: true))
    }

    /// The engine reports the plan stored with the login at sign-in, which stays behind after an upgrade or downgrade
    /// until the next `/login`; Claude Code rewrites the profile's organization on every start. The engine still decides
    /// whether there is a subscription at all: an API-key or third-party login can leave an old profile behind.
    static func plan(type: String?, profileData: Data?) -> String? {
        guard let type else { return nil }
        let account = profileData.flatMap(decode)
        let plan = account?.organizationType.flatMap { organizationPlans[$0] } ?? type
        guard plan == "max", let account, account.organizationType == "claude_max" else { return plan }
        switch account.userRateLimitTier ?? account.organizationRateLimitTier {
        case "default_claude_max_5x": return "max_5x"
        case "default_claude_max_20x": return "max_20x"
        default: return plan
        }
    }

    /// Claude Code's own names for the organization types it knows.
    private static let organizationPlans = ["claude_max": "max", "claude_pro": "pro", "claude_team": "team",
                                            "claude_enterprise": "enterprise"]

    /// Claude Code itself treats the account and organization UUID pair as the login identity.
    static func identity(profileData: Data?) -> Identity? {
        guard let account = profileData.flatMap(decode),
              let provider = ProviderAccount.identified(provider: "Claude", user: account.accountUuid, workspace: account.organizationUuid)
        else { return nil }
        return Identity(account: provider, email: account.emailAddress)
    }

    struct Identity: Hashable, Sendable {
        let account: ProviderAccount
        let email: String?
    }

    private static func decode(_ data: Data) -> Profile.Account? {
        (try? JSONDecoder().decode(Profile.self, from: data))?.oauthAccount
    }

    private struct Profile: Decodable {
        let oauthAccount: Account?

        struct Account: Decodable {
            let organizationType: String?
            let organizationRateLimitTier: String?
            let userRateLimitTier: String?
            let accountUuid: String?
            let organizationUuid: String?
            let emailAddress: String?
        }
    }
}
