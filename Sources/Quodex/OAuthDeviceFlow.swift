import Foundation

struct DeviceLogin: Equatable, Sendable {
    let verificationURL: URL
    let userCode: String
    fileprivate let deviceAuthID: String
    fileprivate let intervalSeconds: UInt64
}

struct OAuthDeviceFlow: Sendable {
    static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    static let issuer = URL(string: "https://auth.openai.com")!

    private let transport: HTTPTransport
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(transport: HTTPTransport = .shared) {
        self.transport = transport
    }

    func start() async throws -> DeviceLogin {
        let endpoint = Self.issuer.appending(path: "api/accounts/deviceauth/usercode")
        let body = try encoder.encode(UserCodeRequest(clientID: Self.clientID))
        let (data, _) = try await transport.data(for: .json(url: endpoint, method: "POST", body: body))
        let response = try decoder.decode(UserCodeResponse.self, from: data)
        guard !response.deviceAuthID.isEmpty, !response.userCode.isEmpty else {
            throw QuodexError.invalidResponse
        }
        return DeviceLogin(
            verificationURL: Self.issuer.appending(path: "codex/device"),
            userCode: response.userCode,
            deviceAuthID: response.deviceAuthID,
            intervalSeconds: max(1, response.interval)
        )
    }

    func complete(_ login: DeviceLogin) async throws -> OAuthTokens {
        let deadline = Date().addingTimeInterval(15 * 60)
        let endpoint = Self.issuer.appending(path: "api/accounts/deviceauth/token")
        var authorization: AuthorizationCodeResponse?

        while Date() < deadline {
            try Task.checkCancellation()
            let body = try encoder.encode(TokenPollRequest(
                deviceAuthID: login.deviceAuthID,
                userCode: login.userCode
            ))
            var request = URLRequest.json(url: endpoint, method: "POST", body: body)
            request.timeoutInterval = 20
            let (data, response) = try await transport.data(
                for: request,
                acceptedStatusCodes: Set(200...299).union([403, 404])
            )
            if response.statusCode == 200 {
                authorization = try decoder.decode(AuthorizationCodeResponse.self, from: data)
                break
            }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { break }
            try await Task.sleep(
                for: .seconds(min(TimeInterval(login.intervalSeconds), remaining))
            )
        }

        guard let authorization else {
            throw QuodexError.loginTimedOut
        }
        return try await exchange(authorization)
    }

    private func exchange(_ authorization: AuthorizationCodeResponse) async throws -> OAuthTokens {
        let endpoint = Self.issuer.appending(path: "oauth/token")
        let redirectURI = Self.issuer.appending(path: "deviceauth/callback").absoluteString
        let values = [
            "grant_type": "authorization_code",
            "code": authorization.authorizationCode,
            "redirect_uri": redirectURI,
            "client_id": Self.clientID,
            "code_verifier": authorization.codeVerifier,
        ]
        let form = values.sorted { $0.key < $1.key }.map { key, value in
            "\(formEncode(key))=\(formEncode(value))"
        }.joined(separator: "&")

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = Data(form.utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, _) = try await transport.data(for: request)
        return try decoder.decode(TokenExchangeResponse.self, from: data).tokens
    }

    private func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }
}

private struct UserCodeRequest: Encodable {
    let clientID: String
    enum CodingKeys: String, CodingKey { case clientID = "client_id" }
}

private struct UserCodeResponse: Decodable {
    let deviceAuthID: String
    let userCode: String
    let interval: UInt64

    enum CodingKeys: String, CodingKey {
        case deviceAuthID = "device_auth_id"
        case userCode = "user_code"
        case userCodeAlternate = "usercode"
        case interval
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        deviceAuthID = try values.decode(String.self, forKey: .deviceAuthID)
        userCode = try values.decodeIfPresent(String.self, forKey: .userCode)
            ?? values.decode(String.self, forKey: .userCodeAlternate)
        if let text = try? values.decode(String.self, forKey: .interval) {
            interval = UInt64(text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 5
        } else {
            interval = try values.decodeIfPresent(UInt64.self, forKey: .interval) ?? 5
        }
    }
}

private struct TokenPollRequest: Encodable {
    let deviceAuthID: String
    let userCode: String
    enum CodingKeys: String, CodingKey {
        case deviceAuthID = "device_auth_id"
        case userCode = "user_code"
    }
}

private struct AuthorizationCodeResponse: Decodable {
    let authorizationCode: String
    let codeChallenge: String
    let codeVerifier: String
    enum CodingKeys: String, CodingKey {
        case authorizationCode = "authorization_code"
        case codeChallenge = "code_challenge"
        case codeVerifier = "code_verifier"
    }
}

private struct TokenExchangeResponse: Decodable {
    let idToken: String
    let accessToken: String
    let refreshToken: String
    enum CodingKeys: String, CodingKey {
        case idToken = "id_token"
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
    }

    var tokens: OAuthTokens {
        OAuthTokens(idToken: idToken, accessToken: accessToken, refreshToken: refreshToken)
    }
}
