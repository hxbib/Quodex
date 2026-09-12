import Foundation

struct HTTPTransport: Sendable {
    static let shared = HTTPTransport()
    static let maximumResponseBytes = 2 * 1024 * 1024

    private let session: URLSession

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 20
            configuration.timeoutIntervalForResource = 30
            configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            configuration.urlCache = nil
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.httpAdditionalHeaders = ["User-Agent": "Quodex"]
            self.session = URLSession(
                configuration: configuration,
                delegate: NoRedirectDelegate(),
                delegateQueue: nil
            )
        }
    }

    func data(for request: URLRequest, acceptedStatusCodes: Set<Int>? = nil) async throws -> (Data, HTTPURLResponse) {
        try EndpointPolicy.validate(request.url)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw QuodexError.invalidResponse
        }
        if data.count > Self.maximumResponseBytes {
            throw QuodexError.responseTooLarge
        }
        let accepted = acceptedStatusCodes ?? Set(200...299)
        guard accepted.contains(http.statusCode) else {
            throw QuodexError.httpStatus(http.statusCode)
        }
        if !data.isEmpty {
            let contentType = http.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
            guard contentType.contains("application/json") else {
                if AuthenticationResponseClassifier.isUsageSessionChallenge(
                    data,
                    url: request.url
                ) {
                    throw QuodexError.authenticationResponse
                }
                throw QuodexError.invalidResponse
            }
        }
        return (data, http)
    }
}

enum AuthenticationResponseClassifier {
    static func isUsageSessionChallenge(_ data: Data, url: URL?) -> Bool {
        guard url?.host?.lowercased() == "chatgpt.com",
              url?.path == "/backend-api/wham/usage",
              let body = String(data: data, encoding: .utf8)?.lowercased(),
              !body.isEmpty else {
            return false
        }
        let authenticationMarker = [
            "sign in",
            "log in",
            "login",
            "session expired",
            "authentication required",
            "unauthenticated",
            "unauthorized",
            "invalid token",
            "token expired",
        ].contains { body.contains($0) }
        let challengeMarker = body.contains("<html")
            || body.contains("<!doctype")
            || body.contains("\"error\"")
            || body.contains("\"detail\"")
            || body.contains("\"message\"")
        return authenticationMarker && challengeMarker
    }
}

enum EndpointPolicy {
    private static let allowedPaths: [String: Set<String>] = [
        "auth.openai.com": [
            "/api/accounts/deviceauth/usercode",
            "/api/accounts/deviceauth/token",
            "/oauth/token",
        ],
        "chatgpt.com": [
            "/backend-api/wham/usage",
            "/backend-api/wham/rate-limit-reset-credits",
        ],
    ]

    static func validate(_ url: URL?) throws {
        guard let url,
              url.scheme == "https",
              url.user == nil,
              url.password == nil,
              url.port == nil,
              url.query == nil,
              url.fragment == nil,
              let host = url.host?.lowercased(),
              allowedPaths[host]?.contains(url.path) == true else {
            throw QuodexError.server("Quodex refused an unapproved network endpoint.")
        }
    }
}

private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

extension URLRequest {
    static func json(url: URL, method: String = "GET", body: Data? = nil) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }
}
