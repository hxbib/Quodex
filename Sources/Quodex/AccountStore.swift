import Foundation

struct AccountSnapshotUpdate: Sendable {
    let accounts: [AccountRecord]
    let pendingEvents: [QuotaTransitionEvent]
}

struct AccountRemoval: Sendable {
    let accounts: [AccountRecord]
    let removedAccount: AccountRecord
    let originalIndex: Int
}

actor AccountStore {
    private struct Envelope: Codable {
        var version: Int
        var accounts: [AccountRecord]
    }

    static let shared = AccountStore()
    static let maximumAccounts = 100
    static let maximumStoreBytes = 1 * 1024 * 1024

    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let fileURL: URL
    private var accounts: [AccountRecord] = []

    init(fileURL: URL? = nil) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder

        if let fileURL {
            self.fileURL = fileURL
        } else {
            let support = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first!
            self.fileURL = support
                .appendingPathComponent(DistributionProfile.applicationSupportDirectory, isDirectory: true)
                .appendingPathComponent("accounts.json", isDirectory: false)
        }
    }

    func load() throws -> [AccountRecord] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            accounts = []
            return []
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        if let size = attributes[.size] as? NSNumber,
           size.intValue > Self.maximumStoreBytes {
            throw QuodexError.invalidAccountStore("the file is unexpectedly large")
        }
        let data = try Data(contentsOf: fileURL)
        let envelope = try decoder.decode(Envelope.self, from: data)
        guard envelope.version == 1 else {
            throw QuodexError.invalidAccountStore("unsupported format version \(envelope.version)")
        }
        guard envelope.accounts.count <= Self.maximumAccounts else {
            throw QuodexError.invalidAccountStore(
                "it contains \(envelope.accounts.count) accounts; the supported maximum is \(Self.maximumAccounts)"
            )
        }
        let normalizedIDs = envelope.accounts.map {
            $0.id.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard normalizedIDs.allSatisfy({ !$0.isEmpty }) else {
            throw QuodexError.invalidAccountStore("an account identifier is empty")
        }
        guard Set(normalizedIDs).count == normalizedIDs.count else {
            throw QuodexError.invalidAccountStore("duplicate account identifiers are present")
        }
        var loadedAccounts = envelope.accounts
        var migratedMetadata = false
        for index in loadedAccounts.indices {
            var seenEvents = Set<QuotaTransitionEvent>()
            var queuedEvents = loadedAccounts[index].queuedNotificationEvents.filter { event in
                guard seenEvents.insert(event).inserted else { return false }
                if !loadedAccounts[index].resetNotificationsAreEnabled,
                   case .earlyUsageReset = event.kind {
                    return false
                }
                return true
            }
            if queuedEvents.count > 32 {
                queuedEvents = Array(queuedEvents.suffix(32))
            }
            if queuedEvents != loadedAccounts[index].queuedNotificationEvents {
                loadedAccounts[index].pendingNotificationEvents = queuedEvents.isEmpty ? nil : queuedEvents
                migratedMetadata = true
            }
            guard var snapshot = loadedAccounts[index].lastSnapshot else {
                if loadedAccounts[index].lastKnownBankedResetCount != nil {
                    loadedAccounts[index].lastKnownBankedResetCount = nil
                    migratedMetadata = true
                }
                continue
            }
            if snapshot.bankedResetCountConfirmed != true {
                if loadedAccounts[index].lastKnownBankedResetCount != nil {
                    loadedAccounts[index].lastKnownBankedResetCount = nil
                    migratedMetadata = true
                }
            } else if loadedAccounts[index].lastKnownBankedResetCount == nil,
                      let count = snapshot.bankedResets?.count {
                loadedAccounts[index].lastKnownBankedResetCount = count
                migratedMetadata = true
            }
            let reportedLanes = snapshot.lanes.filter { !$0.isInferred }
            let laneIDs = reportedLanes.map(\.id)
            guard Set(laneIDs).count == laneIDs.count else {
                throw QuodexError.invalidAccountStore(
                    "an account snapshot contains duplicate usage lanes"
                )
            }
            guard reportedLanes.count != snapshot.lanes.count else { continue }
            migratedMetadata = true
            if reportedLanes.isEmpty {
                loadedAccounts[index].lastSnapshot = nil
            } else {
                snapshot.lanes = reportedLanes
                loadedAccounts[index].lastSnapshot = snapshot
            }
        }

        try secureStorePermissions()
        if migratedMetadata {
            try persist(loadedAccounts)
        }
        accounts = loadedAccounts
        return accounts
    }

    func all() -> [AccountRecord] {
        accounts
    }

    @discardableResult
    func upsert(_ incoming: AccountRecord) throws -> (accounts: [AccountRecord], reused: Bool) {
        let incomingID = incoming.id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !incomingID.isEmpty else {
            throw QuodexError.invalidAccountStore("an account identifier is empty")
        }
        var updatedAccounts = accounts
        let reused: Bool
        if let index = updatedAccounts.firstIndex(where: { $0.id == incoming.id }) {
            var updated = incoming
            updated.addedAt = updatedAccounts[index].addedAt
            updated.lastSnapshot = incoming.lastSnapshot ?? updatedAccounts[index].lastSnapshot
            updated.resetNotificationsEnabled = incoming.resetNotificationsEnabled
                ?? updatedAccounts[index].resetNotificationsEnabled
            updated.lastKnownBankedResetCount = incoming.lastKnownBankedResetCount
                ?? updatedAccounts[index].lastKnownBankedResetCount
            updated.pendingNotificationEvents = incoming.pendingNotificationEvents
                ?? updatedAccounts[index].pendingNotificationEvents
            updatedAccounts[index] = updated
            reused = true
        } else {
            guard updatedAccounts.count < Self.maximumAccounts else {
                throw QuodexError.accountLimitReached
            }
            if incoming.displayPlan == "Free" {
                updatedAccounts.append(incoming)
            } else {
                let insertionIndex = updatedAccounts.lastIndex(where: { $0.displayPlan != "Free" })
                    .map { updatedAccounts.index(after: $0) }
                    ?? updatedAccounts.startIndex
                updatedAccounts.insert(incoming, at: insertionIndex)
            }
            reused = false
        }
        try persist(updatedAccounts)
        accounts = updatedAccounts
        return (accounts, reused)
    }

    func updateSnapshot(
        accountID: String,
        snapshot: UsageSnapshot,
        email: String?,
        plan: String?
    ) throws -> AccountSnapshotUpdate {
        var updatedAccounts = accounts
        guard let index = updatedAccounts.firstIndex(where: { $0.id == accountID }) else {
            return AccountSnapshotUpdate(accounts: accounts, pendingEvents: [])
        }
        let previousAccount = updatedAccounts[index]
        updatedAccounts[index].lastSnapshot = snapshot
        if let email, !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            updatedAccounts[index].email = email
        }
        if let plan, !plan.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            updatedAccounts[index].plan = plan
        }
        let newEvents = QuotaTransitionDetector.events(
            account: updatedAccounts[index],
            previous: previousAccount.lastSnapshot,
            current: snapshot
        )
        var pending = previousAccount.queuedNotificationEvents
        for event in newEvents where !pending.contains(event) {
            pending.append(event)
        }
        if pending.count > 32 {
            pending = Array(pending.suffix(32))
        }
        updatedAccounts[index].pendingNotificationEvents = pending.isEmpty ? nil : pending
        if snapshot.bankedResetCountConfirmed == true,
           let count = snapshot.bankedResets?.count {
            updatedAccounts[index].lastKnownBankedResetCount = count
        }
        try persist(updatedAccounts)
        accounts = updatedAccounts
        return AccountSnapshotUpdate(accounts: accounts, pendingEvents: pending)
    }

    func clearPendingNotificationEvents(_ delivered: [QuotaTransitionEvent]) throws -> [AccountRecord] {
        guard !delivered.isEmpty else { return accounts }
        let deliveredSet = Set(delivered)
        var updatedAccounts = accounts
        var changed = false
        for index in updatedAccounts.indices {
            let retained = updatedAccounts[index].queuedNotificationEvents.filter {
                !deliveredSet.contains($0)
            }
            if retained.count != updatedAccounts[index].queuedNotificationEvents.count {
                updatedAccounts[index].pendingNotificationEvents = retained.isEmpty ? nil : retained
                changed = true
            }
        }
        guard changed else { return accounts }
        try persist(updatedAccounts)
        accounts = updatedAccounts
        return accounts
    }

    func removePendingUsageResetEvents(accountID: String) throws -> [AccountRecord] {
        var updatedAccounts = accounts
        guard let index = updatedAccounts.firstIndex(where: { $0.id == accountID }) else {
            return accounts
        }
        let retained = updatedAccounts[index].queuedNotificationEvents.filter { event in
            if case .earlyUsageReset = event.kind { return false }
            return true
        }
        guard retained.count != updatedAccounts[index].queuedNotificationEvents.count else {
            return accounts
        }
        updatedAccounts[index].pendingNotificationEvents = retained.isEmpty ? nil : retained
        try persist(updatedAccounts)
        accounts = updatedAccounts
        return accounts
    }

    func remove(accountID: String) throws -> [AccountRecord] {
        try removeWithRecord(accountID: accountID).accounts
    }

    func removeWithRecord(accountID: String) throws -> AccountRemoval {
        var updatedAccounts = accounts
        guard let index = updatedAccounts.firstIndex(where: { $0.id == accountID }) else {
            throw QuodexError.invalidAccountStore("the account no longer exists")
        }
        let removedAccount = updatedAccounts.remove(at: index)
        try persist(updatedAccounts)
        accounts = updatedAccounts
        return AccountRemoval(
            accounts: accounts,
            removedAccount: removedAccount,
            originalIndex: index
        )
    }

    func restore(_ removal: AccountRemoval) throws -> [AccountRecord] {
        guard !accounts.contains(where: { $0.id == removal.removedAccount.id }) else {
            return accounts
        }
        var updatedAccounts = accounts
        let index = min(max(0, removal.originalIndex), updatedAccounts.count)
        updatedAccounts.insert(removal.removedAccount, at: index)
        try persist(updatedAccounts)
        accounts = updatedAccounts
        return accounts
    }

    func setResetNotifications(accountID: String, enabled: Bool) throws -> [AccountRecord] {
        var updatedAccounts = accounts
        guard let index = updatedAccounts.firstIndex(where: { $0.id == accountID }) else {
            return accounts
        }
        updatedAccounts[index].resetNotificationsEnabled = enabled
        try persist(updatedAccounts)
        accounts = updatedAccounts
        return accounts
    }

    func reorder(accountIDs: [String]) throws -> [AccountRecord] {
        guard accountIDs.count == accounts.count,
              Set(accountIDs).count == accountIDs.count,
              Set(accountIDs) == Set(accounts.map(\.id)) else {
            throw QuodexError.invalidAccountStore("the requested account order is incomplete")
        }
        let records = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) })
        let updatedAccounts = accountIDs.compactMap { records[$0] }
        try persist(updatedAccounts)
        accounts = updatedAccounts
        return accounts
    }

    private func persist(_ updatedAccounts: [AccountRecord]) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
        let data = try encoder.encode(Envelope(version: 1, accounts: updatedAccounts))
        guard data.count <= Self.maximumStoreBytes else {
            throw QuodexError.invalidAccountStore(
                "the updated account metadata would exceed the supported size"
            )
        }
        try data.write(to: fileURL, options: [.atomic])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
    }

    private func secureStorePermissions() throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
    }
}
