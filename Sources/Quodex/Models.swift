import Foundation

struct AccountRecord: Codable, Identifiable, Equatable, Sendable {
    let id: String
    var email: String
    var plan: String
    var addedAt: Date
    var lastSnapshot: UsageSnapshot?
    var resetNotificationsEnabled: Bool? = nil
    var lastKnownBankedResetCount: Int? = nil
    var pendingNotificationEvents: [QuotaTransitionEvent]? = nil

    var resetNotificationsAreEnabled: Bool {
        resetNotificationsEnabled == true
    }

    var queuedNotificationEvents: [QuotaTransitionEvent] {
        pendingNotificationEvents ?? []
    }

    var displayPlan: String {
        let normalized = plan.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "": return "ChatGPT"
        case "free": return "Free"
        case "plus": return "Plus"
        case "pro": return "Pro"
        case "team": return "Team"
        case "business": return "Business"
        case "enterprise": return "Enterprise"
        case "edu", "education": return "Education"
        default: return plan.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}

struct OAuthTokens: Codable, Equatable, Sendable {
    var idToken: String
    var accessToken: String
    var refreshToken: String
    var refreshedAt: Date

    init(
        idToken: String,
        accessToken: String,
        refreshToken: String,
        refreshedAt: Date = Date()
    ) {
        self.idToken = idToken
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.refreshedAt = refreshedAt
    }

    enum CodingKeys: String, CodingKey {
        case idToken
        case accessToken
        case refreshToken
        case refreshedAt
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        idToken = try values.decode(String.self, forKey: .idToken)
        accessToken = try values.decode(String.self, forKey: .accessToken)
        refreshToken = try values.decode(String.self, forKey: .refreshToken)
        refreshedAt = try values.decodeIfPresent(Date.self, forKey: .refreshedAt) ?? .distantPast
    }
}

struct UsageSnapshot: Codable, Equatable, Sendable {
    var lanes: [UsageLane]
    var bankedResets: BankedResets?
    var fetchedAt: Date
    var bankedResetCountConfirmed: Bool? = nil

    var reportedLanes: [UsageLane] {
        lanes.filter { !$0.isInferred }
    }
}

struct UsageLane: Codable, Identifiable, Equatable, Sendable {
    var id: String { "\(group)|\(name)" }
    var group: String
    var name: String
    var usedPercent: Double
    var resetAt: Date?
    var windowSeconds: Int?
    var isAssumed: Bool? = nil

    var isInferred: Bool {
        isAssumed == true
    }

    var remainingPercent: Double {
        min(100, max(0, 100 - usedPercent))
    }

    var displayName: String {
        Self.displayName(group: group, name: name)
    }

    static func displayName(group: String, name: String) -> String {
        if group == "Standard" { return name }
        if group == "Reserve", name == "Weekly" { return "Reserve" }
        return "\(group) · \(name)"
    }
}

struct BankedResets: Codable, Equatable, Sendable {
    var count: Int
    var earliestExpiry: Date?
}

enum UsageLaneTone: Equatable {
    case critical
    case reserve
    case standard

    static func resolve(group: String, remainingPercent: Double) -> Self {
        if remainingPercent < 35 { return .critical }
        if group == "Reserve" { return .reserve }
        return .standard
    }
}

enum RefreshPolicy {
    static func shouldAutomaticallyRefresh(
        lastAllAccountRefreshAt: Date?,
        now: Date = Date(),
        cooldown: TimeInterval = 30 * 60
    ) -> Bool {
        guard let lastAllAccountRefreshAt else { return true }
        return now.timeIntervalSince(lastAllAccountRefreshAt) >= cooldown
    }
}

enum PeriodicRefreshPolicy {
    static let interval: TimeInterval = 30 * 60

    static func nextDeadline(lastAttemptAt: Date?, now: Date = Date()) -> Date {
        guard let lastAttemptAt else { return now }
        return max(now, lastAttemptAt.addingTimeInterval(interval))
    }
}

enum AccountOrdering {
    static func moving(
        _ accountIDs: [String],
        draggedID: String,
        over destinationID: String
    ) -> [String]? {
        guard draggedID != destinationID,
              let sourceIndex = accountIDs.firstIndex(of: draggedID),
              let destinationIndex = accountIDs.firstIndex(of: destinationID) else { return nil }
        var reordered = accountIDs
        let moved = reordered.remove(at: sourceIndex)
        let insertionIndex = min(destinationIndex, reordered.count)
        reordered.insert(moved, at: insertionIndex)
        return reordered
    }

    static func movingToEnd(_ accountIDs: [String], draggedID: String) -> [String]? {
        guard let sourceIndex = accountIDs.firstIndex(of: draggedID),
              sourceIndex != accountIDs.index(before: accountIDs.endIndex) else { return nil }
        var reordered = accountIDs
        reordered.append(reordered.remove(at: sourceIndex))
        return reordered
    }

    static func moving(
        _ accountIDs: [String],
        draggedID: String,
        toInsertionIndex insertionIndex: Int
    ) -> [String]? {
        guard let sourceIndex = accountIDs.firstIndex(of: draggedID) else { return nil }
        var reordered = accountIDs
        let moved = reordered.remove(at: sourceIndex)
        let adjustedIndex = sourceIndex < insertionIndex ? insertionIndex - 1 : insertionIndex
        let destination = min(max(0, adjustedIndex), reordered.count)
        reordered.insert(moved, at: destination)
        return reordered == accountIDs ? nil : reordered
    }
}

enum AccountResetOrdering {
    static func orderedIDs(
        accounts: [AccountRecord],
        availableAccountIDs: Set<String>,
        now: Date = Date()
    ) -> [String] {
        accounts.enumerated().sorted { left, right in
            let leftReset = nextReset(for: left.element, availableAccountIDs: availableAccountIDs, now: now)
            let rightReset = nextReset(for: right.element, availableAccountIDs: availableAccountIDs, now: now)
            switch (leftReset, rightReset) {
            case let (leftDate?, rightDate?):
                if leftDate != rightDate { return leftDate < rightDate }
                return left.offset < right.offset
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                return left.offset < right.offset
            }
        }.map(\.element.id)
    }

    private static func nextReset(
        for account: AccountRecord,
        availableAccountIDs: Set<String>,
        now: Date
    ) -> Date? {
        guard availableAccountIDs.contains(account.id),
              let snapshot = account.lastSnapshot else { return nil }
        return snapshot.reportedLanes.compactMap(\.resetAt).filter { $0 > now }.min()
    }
}

struct UsageAPIResponse: Decodable, Sendable {
    let email: String?
    let planType: String?
    let rateLimit: NativeUsageLimit?
    let additionalRateLimits: [NativeAdditionalRateLimit]
    let rateLimitResetCredits: NativeResetCreditStatus?

    enum CodingKeys: String, CodingKey {
        case email
        case planType = "plan_type"
        case rateLimit = "rate_limit"
        case additionalRateLimits = "additional_rate_limits"
        case rateLimitResetCredits = "rate_limit_reset_credits"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        email = try? values.decodeIfPresent(String.self, forKey: .email)
        planType = try? values.decodeIfPresent(String.self, forKey: .planType)
        rateLimit = try? values.decodeIfPresent(NativeUsageLimit.self, forKey: .rateLimit)
        additionalRateLimits = (try? values.decodeIfPresent(
            LossyArray<NativeAdditionalRateLimit>.self,
            forKey: .additionalRateLimits
        ))?.elements ?? []
        rateLimitResetCredits = try? values.decodeIfPresent(
            NativeResetCreditStatus.self,
            forKey: .rateLimitResetCredits
        )
    }
}

struct NativeUsageLimit: Decodable, Sendable {
    let allowed: Bool?
    let limitReached: Bool?
    let primaryWindow: NativeUsageWindow?
    let secondaryWindow: NativeUsageWindow?

    enum CodingKeys: String, CodingKey {
        case allowed
        case limitReached = "limit_reached"
        case primaryWindow = "primary_window"
        case secondaryWindow = "secondary_window"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        allowed = try? values.decodeIfPresent(Bool.self, forKey: .allowed)
        limitReached = try? values.decodeIfPresent(Bool.self, forKey: .limitReached)
        primaryWindow = try? values.decodeIfPresent(NativeUsageWindow.self, forKey: .primaryWindow)
        secondaryWindow = try? values.decodeIfPresent(NativeUsageWindow.self, forKey: .secondaryWindow)
    }
}

struct NativeUsageWindow: Decodable, Sendable {
    let usedPercent: Double?
    let limitWindowSeconds: Int?
    let resetAt: Int64?

    enum CodingKeys: String, CodingKey {
        case usedPercent = "used_percent"
        case limitWindowSeconds = "limit_window_seconds"
        case resetAt = "reset_at"
    }


    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        usedPercent = try? values.decodeIfPresent(Double.self, forKey: .usedPercent)
        limitWindowSeconds = try? values.decodeIfPresent(Int.self, forKey: .limitWindowSeconds)
        resetAt = try? values.decodeIfPresent(Int64.self, forKey: .resetAt)
    }
}

struct NativeAdditionalRateLimit: Decodable, Sendable {
    let limitName: String?
    let rateLimit: NativeUsageLimit?

    enum CodingKeys: String, CodingKey {
        case limitName = "limit_name"
        case rateLimit = "rate_limit"
    }


    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        limitName = try? values.decodeIfPresent(String.self, forKey: .limitName)
        rateLimit = try? values.decodeIfPresent(NativeUsageLimit.self, forKey: .rateLimit)
    }
}

struct NativeResetCreditStatus: Decodable, Sendable {
    let availableCount: Int?
    let applicableAvailableCount: Int?

    enum CodingKeys: String, CodingKey {
        case availableCount = "available_count"
        case applicableAvailableCount = "applicable_available_count"
    }


    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        availableCount = try? values.decodeIfPresent(Int.self, forKey: .availableCount)
        applicableAvailableCount = try? values.decodeIfPresent(Int.self, forKey: .applicableAvailableCount)
    }
}

struct ResetCreditsResponse: Decodable, Sendable {
    let availableCount: Int?
    let applicableAvailableCount: Int?
    let credits: [ResetCredit]

    enum CodingKeys: String, CodingKey {
        case availableCount = "available_count"
        case applicableAvailableCount = "applicable_available_count"
        case credits
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        availableCount = try? values.decodeIfPresent(Int.self, forKey: .availableCount)
        applicableAvailableCount = try? values.decodeIfPresent(Int.self, forKey: .applicableAvailableCount)
        credits = (try? values.decodeIfPresent(LossyArray<ResetCredit>.self, forKey: .credits))?.elements ?? []
    }
}

struct ResetCredit: Decodable, Sendable {
    let status: String?
    let expiresAt: String?

    enum CodingKeys: String, CodingKey {
        case status
        case expiresAt = "expires_at"
    }
}

private struct LossyArray<Element: Decodable & Sendable>: Decodable, Sendable {
    let elements: [Element]

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var decoded: [Element] = []
        while !container.isAtEnd {
            if let element = try? container.decode(Element.self) {
                decoded.append(element)
            } else {
                _ = try? container.decode(DiscardedValue.self)
            }
        }
        elements = decoded
    }
}

private struct DiscardedValue: Decodable, Sendable {
    init(from decoder: Decoder) throws {}
}

enum LaneNormalizer {
    static func snapshot(
        usage: UsageAPIResponse,
        resets: ResetCreditsResponse?,
        resetLookupFailed: Bool = false,
        fetchedAt: Date = Date()
    ) throws -> UsageSnapshot {
        var lanes: [UsageLane] = []
        append(limit: usage.rateLimit, group: "Standard", to: &lanes)

        for additional in usage.additionalRateLimits {
            guard let name = additional.limitName?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty else { continue }
            let group = humanize(name)
            append(limit: additional.rateLimit, group: group, to: &lanes)
        }

        guard !lanes.isEmpty else {
            throw QuodexError.unsupportedUsageSchema
        }
        let laneIDs = lanes.map(\.id)
        guard Set(laneIDs).count == laneIDs.count else {
            throw QuodexError.unsupportedUsageSchema
        }

        let embeddedRaw = usage.rateLimitResetCredits?.applicableAvailableCount
            ?? usage.rateLimitResetCredits?.availableCount
        let dedicatedRaw = resets?.applicableAvailableCount ?? resets?.availableCount
        let embeddedCount = embeddedRaw.flatMap { $0 >= 0 ? $0 : nil }
        let dedicatedCount = dedicatedRaw.flatMap { $0 >= 0 ? $0 : nil }
        let count: Int? = (embeddedRaw.map { $0 < 0 } ?? false)
            || (dedicatedRaw.map { $0 < 0 } ?? false)
            ? nil
            : resetLookupFailed
            ? embeddedCount.flatMap { $0 > 0 ? $0 : nil }
            : (dedicatedCount ?? embeddedCount)
        let earliestExpiry = resets?.credits.compactMap { credit -> Date? in
            if let status = credit.status, !status.isEmpty, status != "available" {
                return nil
            }
            guard let value = credit.expiresAt else { return nil }
            return ISO8601DateFormatter().date(from: value)
        }.min()

        let banked = count.map { BankedResets(count: $0, earliestExpiry: earliestExpiry) }
        let countIsConfirmed = !resetLookupFailed && dedicatedCount != nil
        return UsageSnapshot(
            lanes: lanes,
            bankedResets: banked,
            fetchedAt: fetchedAt,
            bankedResetCountConfirmed: banked == nil ? nil : countIsConfirmed
        )
    }

    private static func append(limit: NativeUsageLimit?, group: String, to lanes: inout [UsageLane]) {
        guard let limit else { return }
        if let primary = limit.primaryWindow, isValid(primary.usedPercent) {
            lanes.append(lane(from: primary, group: group))
        }
        if let secondary = limit.secondaryWindow, isValid(secondary.usedPercent) {
            lanes.append(lane(from: secondary, group: group))
        }
    }

    private static func isValid(_ usedPercent: Double?) -> Bool {
        guard let usedPercent else { return false }
        return usedPercent.isFinite && (0...100).contains(usedPercent)
    }

    private static func lane(from window: NativeUsageWindow, group: String) -> UsageLane {
        UsageLane(
            group: group,
            name: label(for: window.limitWindowSeconds),
            usedPercent: window.usedPercent ?? 0,
            resetAt: window.resetAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
            windowSeconds: window.limitWindowSeconds
        )
    }

    static func label(for seconds: Int?) -> String {
        guard let seconds, seconds > 0 else { return "Usage" }
        if seconds == 5 * 60 * 60 { return "5-hour" }
        if seconds == 7 * 24 * 60 * 60 { return "Weekly" }
        if seconds == 30 * 24 * 60 * 60 { return "Free Monthly" }
        if seconds % (7 * 24 * 60 * 60) == 0 {
            let weeks = seconds / (7 * 24 * 60 * 60)
            return weeks == 1 ? "Weekly" : "\(weeks)-week"
        }
        if seconds % (24 * 60 * 60) == 0 {
            let days = seconds / (24 * 60 * 60)
            return days == 1 ? "Daily" : "\(days)-day"
        }
        if seconds % (60 * 60) == 0 {
            return "\(seconds / (60 * 60))-hour"
        }
        return "\(max(1, seconds / 60))-minute"
    }

    static func humanize(_ raw: String) -> String {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
        if normalized == "gpt-reserve" {
            return "Reserve"
        }
        return raw.replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .map { $0.lowercased() == "gpt" ? "GPT" : $0.capitalized }
            .joined(separator: " ")
    }

}

enum QuodexError: LocalizedError, Equatable {
    case invalidResponse
    case authenticationResponse
    case httpStatus(Int)
    case responseTooLarge
    case malformedToken
    case missingAccountIdentity
    case unsupportedUsageSchema
    case noStoredCredentials
    case accountLimitReached
    case loginTimedOut
    case loginCancelled
    case invalidAccountStore(String)
    case server(String)

    var requiresReauthentication: Bool {
        switch self {
        case .noStoredCredentials, .authenticationResponse, .httpStatus(401), .httpStatus(403):
            true
        default:
            false
        }
    }

    var errorDescription: String? {
        switch self {
        case .invalidResponse: "The service returned an invalid response."
        case .authenticationResponse:
            "This session is no longer valid. Sign in again; Quodex never retries expired tokens."
        case let .httpStatus(status):
            if status == 429 {
                "OpenAI temporarily rate-limited this usage check. Try again later."
            } else {
                "The service returned HTTP \(status)."
            }
        case .responseTooLarge: "The service response was unexpectedly large."
        case .malformedToken: "The sign-in token could not be read."
        case .missingAccountIdentity: "The sign-in did not include a ChatGPT account identifier."
        case .unsupportedUsageSchema: "The current usage format is not recognized."
        case .noStoredCredentials: "This session expired or was rejected. Sign in again; Quodex never retries expired tokens."
        case .accountLimitReached: "Quodex supports up to 100 accounts."
        case .loginTimedOut: "Sign-in expired after 15 minutes."
        case .loginCancelled: "Sign-in was cancelled."
        case let .invalidAccountStore(message): "The local account store is invalid: \(message)"
        case let .server(message): message
        }
    }
}
