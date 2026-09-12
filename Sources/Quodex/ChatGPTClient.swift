import Foundation
import CryptoKit

struct AccountFetchResult: Sendable {
    let snapshot: UsageSnapshot
    let email: String?
    let plan: String?
}

actor ChatGPTClient {
    static let shared = ChatGPTClient(rejectedTokenDefaults: .standard)

    private let transport: HTTPTransport
    private let vault: KeychainVault
    private let decoder = JSONDecoder()
    private let rejectedTokenDefaults: UserDefaults?
    private let rejectedTokensKey = "Quodex.rejectedAccessTokens.\(DistributionProfile.keychainService)"
    private var rejectedTokenDigests: [String: String]

    init(
        transport: HTTPTransport = .shared,
        vault: KeychainVault = .shared,
        rejectedTokenDefaults: UserDefaults? = nil
    ) {
        self.transport = transport
        self.vault = vault
        self.rejectedTokenDefaults = rejectedTokenDefaults
        self.rejectedTokenDigests = rejectedTokenDefaults?.dictionary(
            forKey: "Quodex.rejectedAccessTokens.\(DistributionProfile.keychainService)"
        ) as? [String: String] ?? [:]
    }

    func fetch(accountID: String) async throws -> AccountFetchResult {
        let usage = try await fetchUsage(accountID: accountID)
        let resetLookup = try await fetchResets(accountID: accountID)
        let snapshot = try LaneNormalizer.snapshot(
            usage: usage,
            resets: resetLookup.response,
            resetLookupFailed: resetLookup.failed
        )
        return AccountFetchResult(snapshot: snapshot, email: usage.email, plan: usage.planType)
    }

    func saveNewLogin(
        _ tokens: OAuthTokens,
        expectedAccountID: String? = nil,
        expectedEmail: String? = nil
    ) async throws -> ChatGPTIdentity {
        let identity = try JWT.identity(from: tokens.idToken)
        if let expectedAccountID, identity.accountID != expectedAccountID {
            let label = expectedEmail ?? "the selected account"
            throw QuodexError.server(
                "This sign-in belongs to \(identity.email), not \(label). No session was changed."
            )
        }
        try await vault.save(tokens.withoutRefreshToken, for: identity.accountID)
        return identity
    }

    func removeCredentials(accountID: String) async throws {
        try await vault.remove(accountID: accountID)
        rejectedTokenDigests[accountID] = nil
        rejectedTokenDefaults?.set(rejectedTokenDigests, forKey: rejectedTokensKey)
    }

    func storedAccessTokenExpiration(accountID: String) async throws -> Date? {
        var current = try await vault.tokens(for: accountID)
        guard rejectedTokenDigests[accountID] != Self.digest(current.accessToken) else {
            throw QuodexError.noStoredCredentials
        }
        if !current.refreshToken.isEmpty {
            current = current.withoutRefreshToken
            try await vault.save(current, for: accountID)
        }
        return JWT.expiration(from: current.accessToken)
    }

    private func fetchUsage(accountID: String) async throws -> UsageAPIResponse {
        let endpoint = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
        let data: Data
        do {
            data = try await authenticatedData(endpoint: endpoint, accountID: accountID)
        } catch let error as QuodexError where error == .invalidResponse {
            throw QuodexError.authenticationResponse
        }
        if AuthenticationResponseClassifier.isUsageSessionChallenge(data, url: endpoint) {
            throw QuodexError.authenticationResponse
        }
        return try decoder.decode(UsageAPIResponse.self, from: data)
    }

    private func fetchResets(accountID: String) async throws -> (response: ResetCreditsResponse?, failed: Bool) {
        do {
            let endpoint = URL(string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits")!
            let data = try await authenticatedData(endpoint: endpoint, accountID: accountID)
            return (try decoder.decode(ResetCreditsResponse.self, from: data), false)
        } catch let error as QuodexError where error.requiresReauthentication {
            throw error
        } catch {
            return (nil, true)
        }
    }

    private func authenticatedData(endpoint: URL, accountID: String) async throws -> Data {
        let tokens = try await validTokens(accountID: accountID)
        do {
            let response = try await request(
                endpoint: endpoint, accountID: accountID, accessToken: tokens.accessToken
            )
            guard response.statusCode != 401 else { throw QuodexError.noStoredCredentials }
            if AuthenticationResponseClassifier.isUsageSessionChallenge(response.data, url: endpoint) {
                throw QuodexError.authenticationResponse
            }
            return response.data
        } catch let error as QuodexError {
            let isUsageChallenge = error == .invalidResponse && endpoint.path == "/backend-api/wham/usage"
            if error.requiresReauthentication || isUsageChallenge {
                rejectedTokenDigests[accountID] = Self.digest(tokens.accessToken)
                rejectedTokenDefaults?.set(rejectedTokenDigests, forKey: rejectedTokensKey)
            }
            throw isUsageChallenge ? QuodexError.authenticationResponse : error
        }
    }

    private func request(
        endpoint: URL,
        accountID: String,
        accessToken: String
    ) async throws -> (data: Data, statusCode: Int) {
        var request = URLRequest.json(url: endpoint)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-ID")
        let (data, response) = try await transport.data(
            for: request,
            acceptedStatusCodes: Set(200...299).union([401])
        )
        return (data, response.statusCode)
    }

    private func validTokens(accountID: String) async throws -> OAuthTokens {
        var current = try await vault.tokens(for: accountID)
        if !current.refreshToken.isEmpty {
            current = current.withoutRefreshToken
            try await vault.save(current, for: accountID)
        }
        if let expiration = JWT.expiration(from: current.accessToken),
           expiration <= Date() {
            throw QuodexError.noStoredCredentials
        }
        guard rejectedTokenDigests[accountID] != Self.digest(current.accessToken) else {
            throw QuodexError.noStoredCredentials
        }
        return current
    }

    private static func digest(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

private extension OAuthTokens {
    var withoutRefreshToken: OAuthTokens {
        OAuthTokens(
            idToken: idToken,
            accessToken: accessToken,
            refreshToken: "",
            refreshedAt: refreshedAt
        )
    }
}
