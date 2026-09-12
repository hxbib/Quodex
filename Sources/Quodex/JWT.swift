import Foundation

struct ChatGPTIdentity: Equatable, Sendable {
    let accountID: String
    let email: String
    let plan: String
}

enum JWT {
    static func identity(from idToken: String) throws -> ChatGPTIdentity {
        let claims = try claims(from: idToken)
        let profile = claims["https://api.openai.com/profile"] as? [String: Any]
        let auth = claims["https://api.openai.com/auth"] as? [String: Any]

        guard let accountID = nonEmpty(auth?["chatgpt_account_id"] as? String) else {
            throw QuodexError.missingAccountIdentity
        }
        let email = nonEmpty(claims["email"] as? String)
            ?? nonEmpty(profile?["email"] as? String)
            ?? "Account \(accountID.suffix(6))"
        let plan = nonEmpty(auth?["chatgpt_plan_type"] as? String) ?? "ChatGPT"
        return ChatGPTIdentity(accountID: accountID, email: email, plan: plan)
    }

    static func expiration(from token: String) -> Date? {
        guard let claims = try? claims(from: token) else { return nil }
        if let value = claims["exp"] as? TimeInterval {
            return Date(timeIntervalSince1970: value)
        }
        if let value = claims["exp"] as? NSNumber {
            return Date(timeIntervalSince1970: value.doubleValue)
        }
        return nil
    }

    private static func claims(from token: String) throws -> [String: Any] {
        let segments = token.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 3, let data = base64URLDecode(String(segments[1])) else {
            throw QuodexError.malformedToken
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw QuodexError.malformedToken
        }
        return object
    }

    private static func base64URLDecode(_ value: String) -> Data? {
        var base64 = value.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder != 0 {
            base64.append(String(repeating: "=", count: 4 - remainder))
        }
        return Data(base64Encoded: base64)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
