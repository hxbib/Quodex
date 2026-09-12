import CryptoKit
import Foundation
import OSLog
import UserNotifications

struct ResetNotificationPlanEntry: Equatable, Sendable {
    let identifier: String
    let accountID: String
    let email: String
    let laneName: String
    let resetAt: Date
}

struct QuotaTransitionEvent: Codable, Hashable, Sendable {
    enum Kind: Codable, Hashable, Sendable {
        case bankedResets(increase: Int, total: Int)
        case earlyUsageReset(laneName: String)
    }

    let accountID: String
    let email: String
    let observedAt: Date
    var scheduledResetAt: Date? = nil
    let kind: Kind
}

enum QuotaTransitionDetector {
    static func events(
        account: AccountRecord,
        previous: UsageSnapshot?,
        current: UsageSnapshot
    ) -> [QuotaTransitionEvent] {
        var events: [QuotaTransitionEvent] = []

        let confirmedPreviousCount = previous?.bankedResetCountConfirmed == true
            ? previous?.bankedResets?.count
            : nil
        let previousBankedCount = account.lastKnownBankedResetCount
            ?? confirmedPreviousCount
        if let previousBankedCount,
           current.bankedResetCountConfirmed == true,
           let currentBankedCount = current.bankedResets?.count,
           currentBankedCount > 0,
           currentBankedCount > previousBankedCount {
            events.append(QuotaTransitionEvent(
                accountID: account.id,
                email: account.email,
                observedAt: current.fetchedAt,
                scheduledResetAt: nil,
                kind: .bankedResets(
                    increase: currentBankedCount - previousBankedCount,
                    total: currentBankedCount
                )
            ))
        }

        guard account.resetNotificationsAreEnabled, let previous else { return events }
        var previousByID: [String: UsageLane] = [:]
        for lane in previous.reportedLanes {
            previousByID[lane.id] = lane
        }
        for lane in current.reportedLanes where lane.remainingPercent == 100 {
            guard let oldLane = previousByID[lane.id],
                  oldLane.remainingPercent < 100 else { continue }
            events.append(QuotaTransitionEvent(
                accountID: account.id,
                email: account.email,
                observedAt: current.fetchedAt,
                scheduledResetAt: oldLane.resetAt,
                kind: .earlyUsageReset(laneName: lane.displayName)
            ))
        }
        return events
    }
}

enum ResetNotificationPlan {
    static let identifierPrefix = "quodex.reset."

    static func entries(accounts: [AccountRecord], now: Date = Date()) -> [ResetNotificationPlanEntry] {
        var entriesByIdentifier: [String: ResetNotificationPlanEntry] = [:]
        for account in accounts where account.resetNotificationsAreEnabled {
            guard let snapshot = account.lastSnapshot else { continue }
            for lane in snapshot.lanes where !lane.isInferred && lane.remainingPercent < 100 {
                guard let resetAt = lane.resetAt,
                      resetAt.timeIntervalSince(now) > 5 else { continue }
                let laneName = lane.displayName
                let identifier = identifier(
                    accountID: account.id,
                    laneName: laneName,
                    resetAt: resetAt
                )
                entriesByIdentifier[identifier] = ResetNotificationPlanEntry(
                    identifier: identifier,
                    accountID: account.id,
                    email: account.email,
                    laneName: laneName,
                    resetAt: resetAt
                )
            }
        }
        return entriesByIdentifier.values.sorted {
            if $0.resetAt == $1.resetAt { return $0.identifier < $1.identifier }
            return $0.resetAt < $1.resetAt
        }
    }

    static func accountIdentifierPrefix(accountID: String) -> String {
        identifierPrefix + digest(accountID) + "."
    }

    static func laneIdentifierPrefix(accountID: String, laneName: String) -> String {
        accountIdentifierPrefix(accountID: accountID) + digest(laneName) + "."
    }

    static func identifier(
        accountID: String,
        laneName: String,
        resetAt: Date
    ) -> String {
        let resetPart = Int64(resetAt.timeIntervalSince1970.rounded())
        return laneIdentifierPrefix(accountID: accountID, laneName: laneName)
            + String(resetPart)
    }

    static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .prefix(10)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

@MainActor
final class ResetNotificationScheduler {
    static let shared = ResetNotificationScheduler()

    private let center: UNUserNotificationCenter
    private let logger = Logger(
        subsystem: DistributionProfile.bundleIdentifier,
        category: "reset-notifications"
    )
    private var accountEpochs: [String: Int] = [:]
    private var usageResetEpochs: [String: Int] = [:]

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    func requestPermission() async throws -> Bool {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional:
            return true
        case .notDetermined:
            return try await center.requestAuthorization(options: [.alert, .sound])
        case .denied:
            return false
        @unknown default:
            return false
        }
    }

    func reconcile(accounts: [AccountRecord], now: Date = Date()) async throws {
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional else {
            logger.notice("Reset notification reconciliation skipped because authorization is unavailable")
            return
        }

        let desired = ResetNotificationPlan.entries(accounts: accounts, now: now)
        let desiredIDs = Set(desired.map(\.identifier))
        let pending = await center.pendingNotificationRequests()
        let existingIDs = Set(pending.map(\.identifier).filter {
            $0.hasPrefix(ResetNotificationPlan.identifierPrefix)
        })

        let stale = existingIDs.subtracting(desiredIDs)
        if !stale.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: Array(stale))
        }

        for entry in desired where !existingIDs.contains(entry.identifier) {
            let content = UNMutableNotificationContent()
            content.title = "Usage reset"
            content.body = "\(entry.laneName) is available again for \(entry.email)."
            content.sound = .default

            let interval = max(1, entry.resetAt.timeIntervalSinceNow)
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
            do {
                try await center.add(UNNotificationRequest(
                    identifier: entry.identifier,
                    content: content,
                    trigger: trigger
                ))
            } catch {
                logger.error("Failed to schedule a reset notification: \(String(describing: error), privacy: .public)")
                throw error
            }
        }
        logger.info("Reconciled \(desired.count, privacy: .public) reset notification timers")
    }

    func deliver(_ events: [QuotaTransitionEvent]) async throws -> [QuotaTransitionEvent] {
        guard !events.isEmpty else { return [] }
        let capturedAccountEpochs = Dictionary(uniqueKeysWithValues: Set(events.map(\.accountID)).map {
            ($0, accountEpochs[$0, default: 0])
        })
        let capturedUsageEpochs = Dictionary(uniqueKeysWithValues: Set(events.map(\.accountID)).map {
            ($0, usageResetEpochs[$0, default: 0])
        })
        let settings = await center.notificationSettings()
        let authorizationGranted: Bool
        switch settings.authorizationStatus {
        case .authorized, .provisional:
            authorizationGranted = true
        case .notDetermined where events.contains(where: {
            if case .bankedResets = $0.kind { return true }
            return false
        }):
            authorizationGranted = try await center.requestAuthorization(options: [.alert, .sound])
        default:
            authorizationGranted = false
        }
        guard authorizationGranted else { return [] }

        let pending = await center.pendingNotificationRequests()
        let deliveredNotifications = await center.deliveredNotifications()
        var pendingIDs = Set(pending.map(\.identifier))
        var deliveredIDs = Set(deliveredNotifications.map(\.request.identifier))
        var completed: [QuotaTransitionEvent] = []

        for event in events {
            guard accountEpochs[event.accountID, default: 0]
                    == (capturedAccountEpochs[event.accountID] ?? 0) else { continue }
            if case .earlyUsageReset = event.kind,
               usageResetEpochs[event.accountID, default: 0]
                != (capturedUsageEpochs[event.accountID] ?? 0) {
                continue
            }
            let content = UNMutableNotificationContent()
            let eventKind: String
            switch event.kind {
            case let .bankedResets(increase, total):
                eventKind = "banked.\(total)"
                content.title = increase == 1 ? "New banked reset" : "New banked resets"
                let increaseLabel = increase == 1 ? "1 new banked reset" : "\(increase) new banked resets"
                let totalLabel = total == 1 ? "1 available" : "\(total) available"
                content.body = "\(increaseLabel) detected for \(event.email) (\(totalLabel))."
            case let .earlyUsageReset(laneName):
                eventKind = "observed.\(ResetNotificationPlan.digest(laneName))"
                content.title = "Usage reset detected"
                content.body = "\(laneName) is available again for \(event.email)."
            }
            content.sound = .default
            let timestamp = Int64(event.observedAt.timeIntervalSince1970.rounded())
            let identifier = "quodex.event.\(ResetNotificationPlan.digest(event.accountID)).\(eventKind).\(timestamp)"
            if case let .earlyUsageReset(laneName) = event.kind,
               let scheduledResetAt = event.scheduledResetAt {
                let scheduledIdentifier = ResetNotificationPlan.identifier(
                    accountID: event.accountID,
                    laneName: laneName,
                    resetAt: scheduledResetAt
                )
                if deliveredIDs.contains(scheduledIdentifier) {
                    completed.append(event)
                    continue
                }
                if pendingIDs.remove(scheduledIdentifier) != nil {
                    center.removePendingNotificationRequests(withIdentifiers: [scheduledIdentifier])
                    let deliveredAfterRemoval = await center.deliveredNotifications()
                    deliveredIDs.formUnion(deliveredAfterRemoval.map(\.request.identifier))
                    if deliveredIDs.contains(scheduledIdentifier) {
                        completed.append(event)
                        continue
                    }
                }
            }
            if pendingIDs.contains(identifier) || deliveredIDs.contains(identifier) {
                completed.append(event)
                continue
            }
            try await center.add(UNNotificationRequest(
                identifier: identifier,
                content: content,
                trigger: nil
            ))
            guard accountEpochs[event.accountID, default: 0]
                    == (capturedAccountEpochs[event.accountID] ?? 0) else {
                center.removePendingNotificationRequests(withIdentifiers: [identifier])
                center.removeDeliveredNotifications(withIdentifiers: [identifier])
                continue
            }
            pendingIDs.insert(identifier)
            completed.append(event)
        }
        logger.info("Accepted \(completed.count, privacy: .public) of \(events.count, privacy: .public) quota transition notifications")
        return completed
    }

    func removeOrphanedNotifications(validAccountIDs: Set<String>) async {
        let validDigests = Set(validAccountIDs.map(ResetNotificationPlan.digest))
        let prefixes = [ResetNotificationPlan.identifierPrefix, "quodex.event."]
        func isOrphaned(_ identifier: String) -> Bool {
            for prefix in prefixes where identifier.hasPrefix(prefix) {
                let suffix = identifier.dropFirst(prefix.count)
                guard let digest = suffix.split(separator: ".", maxSplits: 1).first else {
                    return true
                }
                return !validDigests.contains(String(digest))
            }
            return false
        }

        let pending = await center.pendingNotificationRequests()
        let pendingIDs = pending.map(\.identifier).filter(isOrphaned)
        if !pendingIDs.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: pendingIDs)
        }
        let delivered = await center.deliveredNotifications()
        let deliveredIDs = delivered.map(\.request.identifier).filter(isOrphaned)
        if !deliveredIDs.isEmpty {
            center.removeDeliveredNotifications(withIdentifiers: deliveredIDs)
        }
    }

    func removeNotifications(accountID: String) async {
        usageResetEpochs[accountID, default: 0] += 1
        let prefix = ResetNotificationPlan.accountIdentifierPrefix(accountID: accountID)
        let pending = await center.pendingNotificationRequests()
        let pendingIDs = pending.map(\.identifier).filter { $0.hasPrefix(prefix) }
        if !pendingIDs.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: pendingIDs)
        }
        let delivered = await center.deliveredNotifications()
        let deliveredIDs = delivered.map(\.request.identifier).filter { $0.hasPrefix(prefix) }
        if !deliveredIDs.isEmpty {
            center.removeDeliveredNotifications(withIdentifiers: deliveredIDs)
        }
    }

    func removeAllNotifications(accountID: String) async {
        accountEpochs[accountID, default: 0] += 1
        await removeNotifications(accountID: accountID)
        let eventPrefix = "quodex.event.\(ResetNotificationPlan.digest(accountID))."
        let pending = await center.pendingNotificationRequests()
        let pendingIDs = pending.map(\.identifier).filter { $0.hasPrefix(eventPrefix) }
        if !pendingIDs.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: pendingIDs)
        }
        let delivered = await center.deliveredNotifications()
        let deliveredIDs = delivered.map(\.request.identifier).filter { $0.hasPrefix(eventPrefix) }
        if !deliveredIDs.isEmpty {
            center.removeDeliveredNotifications(withIdentifiers: deliveredIDs)
        }
    }

}
