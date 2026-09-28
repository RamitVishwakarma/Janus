import Foundation

/// What can go wrong asking OpenAI for a Codex account's figures.
public enum CodexAPIError: LocalizedError, Equatable {
    case noCredentials
    case apiKeyAccount
    case signInAgain
    case signInRefused
    case noFigures
    case refused(Int)
    case malformedAnswer
    case unreachable(String)

    public var errorDescription: String? {
        switch self {
        case .noCredentials:
            return "No saved sign-in to ask with."
        case .apiKeyAccount:
            return "Signed in with an API key, which has no plan limits to show."
        case .signInAgain:
            return "The saved sign-in has expired. Switch to this account and sign in to Codex again."
        case .signInRefused:
            // The account already signed in: Codex renews its own tokens, and
            // "switch to it" is advice that cannot be followed.
            return """
                   OpenAI refused this sign-in. Codex renews it itself the next time it \
                   runs; if it keeps happening, sign in again.
                   """
        case .noFigures:
            return "OpenAI reported no limits for this account."
        case .refused(403):
            // Not a token problem. ChatGPT's edge turns requests away on its own
            // judgement now and then, and renewing a sign-in over it would spend
            // a refresh token for nothing.
            return "OpenAI turned the request away (HTTP 403). Try again in a moment."
        case .refused(let status):
            return "OpenAI refused the request (HTTP \(status))."
        case .malformedAnswer:
            return "OpenAI answered with something this cannot read."
        case .unreachable(let reason):
            return "Could not reach OpenAI: \(reason)"
        }
    }
}

/// The two requests a Codex reading needs: the figures, and renewed tokens when
/// the saved ones have run out. A protocol for the same reason `UsageEndpoint` is.
public protocol CodexUsageEndpoint: Sendable {

    /// The raw body of ChatGPT's usage endpoint, the one Codex's `/status` reads.
    func usage(accessToken: String, accountID: String?) async throws -> Data

    /// Spends the refresh token and returns the sign-in that replaces it.
    func renew(_ auth: CodexAuth, now: Date) async throws -> CodexAuth
}

/// ChatGPT's usage endpoint and OpenAI's token endpoint, reached with the
/// account's own tokens: the same two requests Codex makes for itself, made for an
/// account that need not be the one signed in.
public struct OpenAIUsage: CodexUsageEndpoint {

    public static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    public static let tokenURL = URL(string: "https://auth.openai.com/oauth/token")!

    /// Codex's public OAuth client identifier. Not a secret: it travels in the
    /// browser during every sign-in.
    public static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"

    /// chatgpt.com sits behind a bot filter that challenges anything which does
    /// not look like a browser, and a challenge comes back as a 403 page rather
    /// than figures. codex-switcher found a plain browser identity to be what
    /// gets through reliably, and this follows it.
    static let userAgent = """
        Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 \
        (KHTML, like Gecko) Chrome/136.0.0.0 Safari/537.36
        """

    private let session: URLSession

    public init(timeout: TimeInterval = 15) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
    }

    public func usage(accessToken: String, accountID: String?) async throws -> Data {
        var request = URLRequest(url: Self.usageURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        if let accountID { request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id") }

        let (data, status) = try await send(request)
        switch status {
        case 200: return data
        // Only a 401 says the token is the problem. A 403 is the bot filter, and
        // treating it as an expired sign-in would renew one that was fine.
        case 401: throw CodexAPIError.signInAgain
        default: throw CodexAPIError.refused(status)
        }
    }

    public func renew(_ auth: CodexAuth, now: Date) async throws -> CodexAuth {
        guard let refreshToken = auth.refreshToken else { throw CodexAPIError.signInAgain }

        var request = URLRequest(url: Self.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(Self.form([
            ("grant_type", "refresh_token"),
            ("refresh_token", refreshToken),
            ("client_id", Self.clientID)
        ]).utf8)

        let (data, status) = try await send(request)
        guard status == 200 else {
            throw status == 400 || status == 401 ? CodexAPIError.signInAgain
                                                 : CodexAPIError.refused(status)
        }

        guard let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = body["access_token"] as? String,
              let renewed = auth.renewed(idToken: body["id_token"] as? String,
                                         accessToken: accessToken,
                                         refreshToken: body["refresh_token"] as? String,
                                         now: now)
        else { throw CodexAPIError.malformedAnswer }

        return renewed
    }

    /// `application/x-www-form-urlencoded`, escaping everything but the handful of
    /// characters that never need it. A refresh token is opaque, and one `+` read
    /// back as a space would be a token that no longer exists.
    static func form(_ fields: [(String, String)]) -> String {
        var unreserved = CharacterSet.alphanumerics
        unreserved.insert(charactersIn: "-._~")
        return fields.map { key, value in
            let escaped = value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
            return "\(key)=\(escaped)"
        }.joined(separator: "&")
    }

    private func send(_ request: URLRequest) async throws -> (Data, Int) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw CodexAPIError.malformedAnswer }
            return (data, http.statusCode)
        } catch let error as CodexAPIError {
            throw error
        } catch {
            throw CodexAPIError.unreachable(AnthropicUsage.phrase(error))
        }
    }
}

extension Usage {

    /// Builds a reading from the body of ChatGPT's usage endpoint.
    ///
    /// The answer carries two windows, `primary_window` and `secondary_window`,
    /// which are normally the five-hour limit and the weekly one. They are placed
    /// by their stated length rather than by which key they arrived under,
    /// because a plan with only a weekly limit gets it as the primary window, and
    /// drawing that as a five-hour bar would be a lie about when it resets.
    public init(codex body: [String: Any], measuredAt: Date) {
        self.init(measuredAt: measuredAt)

        let limits = body["rate_limit"] as? [String: Any]
        let slots: [(value: Any?, weeklyUnlessSaid: Bool)] = [
            (limits?["primary_window"], false),
            (limits?["secondary_window"], true)
        ]

        for slot in slots {
            guard let object = slot.value as? [String: Any],
                  let window = Usage.codexWindow(object, measuredAt: measuredAt)
            else { continue }

            let length = (object["limit_window_seconds"] as? NSNumber)?.doubleValue
            let weekly = length.map { $0 >= 24 * 60 * 60 } ?? slot.weeklyUnlessSaid

            if weekly {
                if sevenDay == nil { sevenDay = window }
            } else if fiveHour == nil {
                fiveHour = window
            }
        }
    }

    private static func codexWindow(_ object: [String: Any], measuredAt: Date) -> Window? {
        guard let percent = percent(object["used_percent"]) else { return nil }

        var resetsAt: Date?
        if let seconds = object["reset_at"] as? NSNumber {
            resetsAt = Date(timeIntervalSince1970: seconds.doubleValue)
        } else if let after = object["reset_after_seconds"] as? NSNumber {
            resetsAt = measuredAt.addingTimeInterval(after.doubleValue)
        }
        return Window(percentUsed: percent, resetsAt: resetsAt)
    }
}
