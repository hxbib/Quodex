import Foundation

enum RefreshIntent: Sendable {
    case automatic
    case manualAll
    case sort
}

struct RefreshRequest: Equatable, Sendable {
    let id = UUID()
    let accountID: String
    let generation: UUID
}

struct FullRefreshRun: Sendable {
    var generations: [String: UUID] = [:]
    var successfulGenerations: [String: UUID] = [:]
    var completedGenerations: [String: UUID] = [:]
    var sortAfterCompletion: Bool
    var waitingForIndividuals = false

    var successfulAccountIDs: Set<String> {
        Set(successfulGenerations.keys.filter { successfulGenerations[$0] == generations[$0] })
    }
}

struct RefreshCoordinator: Sendable {
    private(set) var activeFullRun: FullRefreshRun?
    private(set) var active: [String: RefreshRequest] = [:]
    private(set) var pending: [RefreshRequest] = []
    let maximumConcurrency: Int

    init(maximumConcurrency: Int = 4) {
        self.maximumConcurrency = min(4, max(1, maximumConcurrency))
    }

    var hasAnyWork: Bool { activeFullRun != nil || !active.isEmpty || !pending.isEmpty }

    @discardableResult
    mutating func requestFull(_ intent: RefreshIntent, generations: [(String, UUID)]) -> Bool {
        let started = activeFullRun == nil
        if started {
            activeFullRun = FullRefreshRun(
                sortAfterCompletion: intent == .sort,
                waitingForIndividuals: !active.isEmpty
            )
        } else if intent == .sort {
            activeFullRun?.sortAfterCompletion = true
        }
        for (accountID, generation) in generations {
            if activeFullRun?.generations[accountID] == generation { continue }
            if started && !active.isEmpty {
                activeFullRun?.generations[accountID] = generation
                pending.removeAll { $0.accountID == accountID }
                pending.append(RefreshRequest(accountID: accountID, generation: generation))
            } else {
                requestAccount(accountID, generation: generation)
            }
        }
        return started
    }

    @discardableResult
    mutating func requestAccount(_ accountID: String, generation: UUID) -> Bool {
        if activeFullRun?.completedGenerations[accountID] == generation { return false }
        activeFullRun?.generations[accountID] = generation
        if active[accountID]?.generation == generation
            || pending.contains(where: { $0.accountID == accountID && $0.generation == generation }) {
            return false
        }
        pending.removeAll { $0.accountID == accountID }
        activeFullRun?.successfulGenerations[accountID] = nil
        pending.append(RefreshRequest(accountID: accountID, generation: generation))
        return true
    }

    mutating func reserveNext() -> RefreshRequest? {
        if activeFullRun?.waitingForIndividuals == true {
            guard active.isEmpty else { return nil }
            activeFullRun?.waitingForIndividuals = false
        }
        guard active.count < maximumConcurrency,
              let index = pending.firstIndex(where: { active[$0.accountID] == nil }) else { return nil }
        let request = pending.remove(at: index)
        active[request.accountID] = request
        return request
    }

    mutating func finish(_ request: RefreshRequest, succeeded: Bool) {
        guard active[request.accountID] == request else { return }
        active[request.accountID] = nil
        if activeFullRun?.waitingForIndividuals != true,
           activeFullRun?.generations[request.accountID] == request.generation {
            activeFullRun?.completedGenerations[request.accountID] = request.generation
            if succeeded { activeFullRun?.successfulGenerations[request.accountID] = request.generation }
        }
    }

    mutating func invalidate(_ accountID: String) {
        pending.removeAll { $0.accountID == accountID }
        activeFullRun?.generations[accountID] = nil
        activeFullRun?.successfulGenerations[accountID] = nil
        activeFullRun?.completedGenerations[accountID] = nil
    }

    mutating func finishFullIfDrained() -> FullRefreshRun? {
        guard active.isEmpty, pending.isEmpty else { return nil }
        let run = activeFullRun
        activeFullRun = nil
        return run
    }

    mutating func cancelPendingWork() {
        pending.removeAll()
        activeFullRun = nil
    }
}

@MainActor
struct RefreshEnvironment {
    var fetch: (String) async throws -> AccountFetchResult
    var expiration: (String) async throws -> Date?
    var removeCredentials: (String) async throws -> Void
    var updateSnapshot: (String, AccountFetchResult) async throws -> AccountSnapshotUpdate
    var reorder: ([String]) async throws -> Void
    var now: () -> Date = { Date() }
    var sleepUntil: (Date) async throws -> Void = { deadline in
        try await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow)))
    }

    static func live(client: ChatGPTClient, store: AccountStore) -> Self {
        Self(
            fetch: { try await client.fetch(accountID: $0) },
            expiration: { try await client.storedAccessTokenExpiration(accountID: $0) },
            removeCredentials: { try await client.removeCredentials(accountID: $0) },
            updateSnapshot: { accountID, result in
                try await store.updateSnapshot(
                    accountID: accountID,
                    snapshot: result.snapshot,
                    email: result.email,
                    plan: result.plan
                )
            },
            reorder: { _ = try await store.reorder(accountIDs: $0) }
        )
    }
}
