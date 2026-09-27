import Foundation

/// What can go wrong asking Anthropic for an account's figures.
public enum UsageAPIError: LocalizedError, Equatable {
    case noCredentials
    case signInAgain
    case signInRefused
    case noFigures
    case refused(Int)
    case malformedAnswer
    case unreachable(String)

    public var errorDescription: String? {
        switch self {
        case .noCredentials:
            return "No saved tokens to ask with."
        case .signInAgain:
            return "The saved sign-in has expired. Switch to this account and sign in again."
        case .signInRefused:
            // Said differently because the remedy is different: this is the
            // account already signed in, so "switch to it and sign in" is advice
            // that cannot be followed.
            return """
                   Anthropic refused this sign-in. Claude Code renews it itself, so try again \
                   in a moment; if it keeps happening, sign in again.
                   """
        case .noFigures:
            return "Anthropic reported no limits for this account."
        case .refused(let status):
            return "Anthropic refused the request (HTTP \(status))."
        case .malformedAnswer:
            return "Anthropic answered with something this cannot read."
        case .unreachable(let reason):
            return "Could not reach Anthropic: \(reason)"
        }
    }
}

/// The two requests a reading needs: the figures themselves, and a renewed token
/// when the saved one has run out.
///
/// A protocol because the test suite has no business making either request, and
/// because the failure paths worth testing — an expired sign-in, a refusal
/// halfway through a renewal — are otherwise unreachable.
public protocol UsageEndpoint: Sendable {

    /// The raw body of the usage endpoint, which is the same object Claude Code
    /// files under `utilization` when it writes the answer to disk.
    func usage(accessToken: String) async throws -> Data

    /// Spends the refresh token and returns the credentials that replace it.
    func renew(_ credentials: Credentials, now: Date) async throws -> Credentials
}

/// Anthropic's own usage endpoint, reached with the account's own token.
///
/// The only network code in Janus, and it talks to one host. These are the
/// requests Claude Code makes for `/usage`, made the same way and with the same
/// credentials; the difference is that Janus can make them for an account that is
/// not the one signed in, which is the only way a parked account's figures can
/// ever be anything but frozen.
public struct AnthropicUsage: UsageEndpoint {

    public static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    public static let tokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!

    /// Claude Code's public OAuth client identifier. Not a secret: it travels in
    /// the browser during every sign-in.
    public static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"

    /// The header that tells the API these are OAuth credentials rather than an
    /// API key.
    static let betaHeader = "oauth-2025-04-20"

    private let session: URLSession

    public init(timeout: TimeInterval = 15) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.httpShouldSetCookies = false
        // Nothing here is worth re-serving from a cache: a figure a minute old
        // read as a figure from now is the bug this whole feature exists to fix.
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
    }

    public func usage(accessToken: String) async throws -> Data {
        var request = URLRequest(url: Self.usageURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.betaHeader, forHTTPHeaderField: "anthropic-beta")

        let (data, status) = try await send(request)
        switch status {
        case 200: return data
        case 401, 403: throw UsageAPIError.signInAgain
        default: throw UsageAPIError.refused(status)
        }
    }

    public func renew(_ credentials: Credentials, now: Date) async throws -> Credentials {
        guard let refreshToken = credentials.refreshToken else { throw UsageAPIError.signInAgain }

        var request = URLRequest(url: Self.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": Self.clientID
        ])

        let (data, status) = try await send(request)
        // A refusal here is the end of the road rather than something to retry:
        // the refresh token is the last credential there is.
        guard status == 200 else {
            throw status == 400 || status == 401 ? UsageAPIError.signInAgain
                                                 : UsageAPIError.refused(status)
        }

        guard let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = body["access_token"] as? String,
              let renewed = credentials.renewed(accessToken: accessToken,
                                                refreshToken: body["refresh_token"] as? String,
                                                expiresIn: body["expires_in"] as? TimeInterval,
                                                now: now)
        else { throw UsageAPIError.malformedAnswer }

        return renewed
    }

    /// Foundation's network messages are already whole sentences ending in a full
    /// stop, so they are quoted as they are rather than punctuated again.
    static func phrase(_ error: Error) -> String {
        let text = (error as NSError).localizedDescription
        return text.hasSuffix(".") ? text : text + "."
    }

    private func send(_ request: URLRequest) async throws -> (Data, Int) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw UsageAPIError.malformedAnswer }
            return (data, http.statusCode)
        } catch let error as UsageAPIError {
            throw error
        } catch {
            throw UsageAPIError.unreachable(Self.phrase(error))
        }
    }
}
