import AppKit
import Foundation

enum AccountRefreshState: Equatable {
    case idle
    case cached(Date)
    case refreshing
    case current(Date)
    case failed(String)
    case requiresLogin

    var hasConfirmedSnapshot: Bool {
        if case .current = self { return true }
        if case .cached = self { return true }
        return false
    }

    func isFresh(at date: Date) -> Bool {
        guard case let .current(fetchedAt) = self else { return false }
        return date.timeIntervalSince(fetchedAt) < 2 * 60
    }

    var needsLogin: Bool {
        if case .requiresLogin = self { return true }
        return false
    }
}

enum LoginState: Equatable {
    case idle
    case requestingCode
    case waiting(DeviceLogin)
    case complete(String)
    case failed(String)
}

struct QuodexToast: Identifiable, Equatable {
    enum Style: Equatable {
        case success
        case warning
        case info
    }

    let id = UUID()
    let message: String
    let style: Style

    static func == (lhs: QuodexToast, rhs: QuodexToast) -> Bool {
        lhs.id == rhs.id
    }
}

@MainActor
final class AppModel: ObservableObject {
    static let automaticRefreshCooldown: TimeInterval = 30 * 60
    private static let lastAllAccountRefreshAttemptKey = "Quodex.lastAllAccountRefreshAttemptAt"
    private static let lastAllAccountRefreshCompletionKey = "Quodex.lastAllAccountRefreshAt"

    @Published private(set) var accounts: [AccountRecord] = []
    @Published private(set) var isLoadingAccounts = true
    @Published private(set) var loadError: String?
    @Published private(set) var refreshStates: [String: AccountRefreshState] = [:]
    @Published private(set) var removingAccountIDs: Set<String> = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var isSorting = false
    @Published var isDragging = false {
        didSet {
            if !isDragging { drainRefreshQueue() }
        }
    }
    @Published private(set) var lastRefreshCompletedAt: Date?
    @Published private(set) var toast: QuodexToast?
    @Published var loginPresented = false
    @Published private(set) var loginState: LoginState = .idle
    @Published private(set) var loginTargetEmail: String?
    @Published var isPinned = false

    private let store: AccountStore
    private let client: ChatGPTClient
    private let oauth: OAuthDeviceFlow
    private let providedNotificationScheduler: ResetNotificationScheduler?
    private var notificationScheduler: ResetNotificationScheduler {
        providedNotificationScheduler ?? .shared
    }
    private let refreshEnvironment: RefreshEnvironment
    private let defaults: UserDefaults
    private var orderPersistenceTask: Task<Void, Never>?
    private var orderRevision = 0
    private var isTerminating = false
    private var bootstrapID = UUID()
    private var periodicScheduleID = UUID()
    private var updatingLoginAccountIDs: Set<String> = []
    private var accountRefreshTasks: [String: Task<Void, Never>] = [:]
    private var periodicRefreshTask: Task<Void, Never>?
    private var loginTask: Task<Void, Never>?
    private var clipboardCleanupTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?
    private var activeLoginCode: String?
    private var loginTargetAccountID: String?
    private var refreshGenerations: [String: UUID] = [:]
    private var credentialExpirations: [String: Date] = [:]
    private var lastRefreshAttemptAt: Date?
    private var refreshCoordinator = RefreshCoordinator(maximumConcurrency: 4)
    private var notificationCenterIsReady = false

    init(
        store: AccountStore = .shared,
        client: ChatGPTClient = .shared,
        oauth: OAuthDeviceFlow = OAuthDeviceFlow(),
        notificationScheduler: ResetNotificationScheduler? = nil,
        defaults: UserDefaults = .standard,
        refreshEnvironment: RefreshEnvironment? = nil,
        startAutomatically: Bool = true
    ) {
        self.store = store
        self.client = client
        self.oauth = oauth
        self.providedNotificationScheduler = notificationScheduler
        self.refreshEnvironment = refreshEnvironment ?? .live(client: client, store: store)
        self.defaults = defaults
        self.lastRefreshCompletedAt = defaults.object(
            forKey: Self.lastAllAccountRefreshCompletionKey
        ) as? Date
        self.lastRefreshAttemptAt = defaults.object(
            forKey: Self.lastAllAccountRefreshAttemptKey
        ) as? Date ?? self.lastRefreshCompletedAt
        if startAutomatically { Task { await bootstrap() } }
    }

    func popoverOpened() {
        expireKnownCredentials()
        if !isLoadingAccounts {
            refreshAll(force: false)
        }
    }

    func popoverClosed() {
        isDragging = false
    }

    func notificationCenterBecameReady() {
        guard !notificationCenterIsReady else { return }
        notificationCenterIsReady = true
        guard !isLoadingAccounts else { return }
        Task {
            await notificationScheduler.removeOrphanedNotifications(
                validAccountIDs: Set(accounts.map(\.id))
            )
            try? await notificationScheduler.reconcile(accounts: notificationEligibleAccounts)
            await flushPendingNotificationEvents()
        }
    }

    func retryLoadingAccounts() {
        Task { await bootstrap() }
    }

    func refreshAll(force: Bool = true) {
        requestFullRefresh(intent: force ? .manualAll : .automatic)
    }

    func sortBySoonestReset() {
        guard !accounts.isEmpty, !isDragging else { return }
        requestFullRefresh(intent: .sort)
    }

    func systemDidWake() {
        expireKnownCredentials()
        requestFullRefresh(intent: .automatic)
        restartPeriodicRefreshLoop()
    }

    private func requestFullRefresh(intent: RefreshIntent) {
        guard !isTerminating, !isLoadingAccounts, !accounts.isEmpty else { return }
        if DistributionProfile.isMock {
            guard intent != .automatic else { return }
            performMockRefresh(intent: intent)
            return
        }
        expireKnownCredentials()
        if intent == .automatic,
           !RefreshPolicy.shouldAutomaticallyRefresh(
                lastAllAccountRefreshAt: lastRefreshAttemptAt,
                now: refreshEnvironment.now(),
                cooldown: Self.automaticRefreshCooldown
           ) {
            return
        }
        let generations = accounts.filter { isEligible($0.id) }.map {
            ($0.id, generation(for: $0.id))
        }
        let started = refreshCoordinator.requestFull(intent, generations: generations)
        if started { recordFullRefreshAttempt() }
        if intent == .sort {
            isSorting = true
            showToast(
                started ? "Refreshing all accounts before sorting." : "Sorting after the current refresh.",
                style: .info
            )
        } else if intent == .manualAll {
            showToast(
                started ? "Refreshing all \(accounts.count) accounts’ usage limits."
                    : "All accounts are already refreshing.",
                style: .info
            )
        }
        for request in refreshCoordinator.pending where isEligible(request.accountID) {
            refreshStates[request.accountID] = .refreshing
        }
        drainRefreshQueue()
    }

    func refresh(accountID: String) {
        guard !isTerminating, !isLoadingAccounts else { return }
        expireKnownCredentials()
        guard isEligible(accountID),
              let account = accounts.first(where: { $0.id == accountID }) else { return }
        if DistributionProfile.isMock {
            guard let index = accounts.firstIndex(where: { $0.id == accountID }) else { return }
            let now = refreshEnvironment.now()
            accounts[index].lastSnapshot?.fetchedAt = now
            refreshStates[accountID] = .current(now)
            showToast("Refreshing \(account.email) usage limits.", style: .info)
            return
        }
        let queued = refreshCoordinator.requestAccount(accountID, generation: generation(for: accountID))
        let inFlight = refreshCoordinator.active[accountID] != nil
            || refreshCoordinator.pending.contains { $0.accountID == accountID }
        if queued || inFlight { refreshStates[accountID] = .refreshing }
        showToast(
            queued ? "Refreshing \(account.email) usage limits."
                : inFlight ? "\(account.email) is already refreshing."
                    : "\(account.email) was updated in the current refresh.",
            style: .info
        )
        drainRefreshQueue()
    }

    func presentLogin() {
        guard !DistributionProfile.isMock else {
            showToast("Sign-in is disabled in the reference build.", style: .info)
            return
        }
        loginTargetEmail = nil
        presentLogin(targetAccountID: nil)
    }

    func presentLogin(accountID: String) {
        guard !DistributionProfile.isMock else {
            showToast("Sign-in is disabled in the reference build.", style: .info)
            return
        }
        guard let account = accounts.first(where: { $0.id == accountID }) else { return }
        loginTargetEmail = account.email
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(account.email, forType: .string)
        presentLogin(targetAccountID: accountID)
    }

    private func presentLogin(targetAccountID: String?) {
        loginTargetAccountID = targetAccountID
        loginPresented = true
        loginState = .idle
    }

    func startLogin() {
        loginTask?.cancel()
        loginState = .requestingCode
        let expectedAccountID = loginTargetAccountID
        let expectedEmail = loginTargetEmail
        loginTask = Task { [weak self] in
            guard let self else { return }
            var pendingNewCredentialID: String?
            do {
                let login = try await oauth.start()
                try Task.checkCancellation()
                activeLoginCode = login.userCode
                copyToPasteboard(login.userCode)
                scheduleLoginCodeCleanup(login.userCode)
                loginState = .waiting(login)
                NSWorkspace.shared.open(login.verificationURL)

                let tokens = try await oauth.complete(login)
                try Task.checkCancellation()
                let identity = try await client.saveNewLogin(
                    tokens,
                    expectedAccountID: expectedAccountID,
                    expectedEmail: expectedEmail
                )
                let replacesExisting = accounts.contains { $0.id == identity.accountID }
                if !replacesExisting {
                    pendingNewCredentialID = identity.accountID
                }
                let reused = try await loginSucceeded(
                    account: AccountRecord(
                        id: identity.accountID,
                        email: identity.email,
                        plan: identity.plan,
                        addedAt: refreshEnvironment.now(),
                        lastSnapshot: nil
                    )
                )
                pendingNewCredentialID = nil
                let message = expectedAccountID != nil
                    ? "Session refreshed for \(identity.email)."
                    : reused
                    ? "Existing login refreshed — no duplicate was created."
                    : "\(identity.email) was added."
                clearLoginCodeFromClipboard()
                loginState = .complete(message)
            } catch is CancellationError {
                if let pendingNewCredentialID {
                    try? await client.removeCredentials(accountID: pendingNewCredentialID)
                }
                clearLoginCodeFromClipboard()
                loginState = .idle
            } catch {
                if let pendingNewCredentialID {
                    try? await client.removeCredentials(accountID: pendingNewCredentialID)
                }
                clearLoginCodeFromClipboard()
                loginState = .failed(Self.message(for: error))
            }
        }
    }

    func cancelLogin() {
        loginTask?.cancel()
        loginTask = nil
        clearLoginCodeFromClipboard()
        loginState = .idle
        loginPresented = false
        loginTargetAccountID = nil
        loginTargetEmail = nil
    }

    func finishLogin() {
        loginTask = nil
        loginPresented = false
        loginState = .idle
        loginTargetAccountID = nil
        loginTargetEmail = nil
    }

    func copyLoginCode() {
        guard case let .waiting(login) = loginState else { return }
        copyToPasteboard(login.userCode)
        scheduleLoginCodeCleanup(login.userCode)
    }

    func copyEmail(_ email: String) {
        copyToPasteboard(email)
        showToast("Copied \(email) to clipboard.", style: .success)
    }

    func openLoginPage() {
        guard case let .waiting(login) = loginState else { return }
        NSWorkspace.shared.open(login.verificationURL)
    }

    func prepareForTermination() {
        isTerminating = true
        bootstrapID = UUID()
        cancelRefreshWork()
        periodicRefreshTask?.cancel()
        loginTask?.cancel()
        clipboardCleanupTask?.cancel()
        toastTask?.cancel()
        clearLoginCodeFromClipboard()
    }

    func remove(accountID: String) {
        guard !isTerminating, !isLoadingAccounts,
              accounts.contains(where: { $0.id == accountID }),
              removingAccountIDs.insert(accountID).inserted else { return }
        if DistributionProfile.isMock {
            accounts.removeAll { $0.id == accountID }
            refreshStates[accountID] = nil
            removingAccountIDs.remove(accountID)
            showToast("Account removed from Quodex.", style: .success)
            return
        }
        invalidateRefresh(accountID)
        let drainingTask = accountRefreshTasks[accountID]
        Task {
            defer {
                removingAccountIDs.remove(accountID)
                drainRefreshQueue()
                restartPeriodicRefreshLoop()
            }
            do {
                await drainingTask?.value
                if notificationCenterIsReady {
                    await notificationScheduler.removeAllNotifications(accountID: accountID)
                }
                let removal = try await store.removeWithRecord(accountID: accountID)
                do {
                    try await refreshEnvironment.removeCredentials(accountID)
                } catch {
                    _ = try await store.restore(removal)
                    throw error
                }
                accounts.removeAll { $0.id == accountID }
                refreshStates[accountID] = nil
                credentialExpirations[accountID] = nil
                showToast("Account removed from Quodex.", style: .success)
            } catch {
                restoreCachedState(accountID)
                if notificationCenterIsReady {
                    try? await notificationScheduler.reconcile(accounts: notificationEligibleAccounts)
                    await flushPendingNotificationEvents()
                }
                showToast(Self.message(for: error), style: .warning, duration: 5)
            }
        }
    }

    @discardableResult
    func loginSucceeded(account: AccountRecord) async throws -> Bool {
        guard !isTerminating, !isLoadingAccounts, !removingAccountIDs.contains(account.id),
              updatingLoginAccountIDs.insert(account.id).inserted else {
            throw CancellationError()
        }
        defer {
            updatingLoginAccountIDs.remove(account.id)
            drainRefreshQueue()
            restartPeriodicRefreshLoop()
        }
        invalidateRefresh(account.id)
        let loginGeneration = generation(for: account.id)
        let expiration = try? await refreshEnvironment.expiration(account.id)
        guard !isTerminating, !removingAccountIDs.contains(account.id),
              refreshGenerations[account.id] == loginGeneration else { throw CancellationError() }
        let result = try await store.upsert(account)
        guard !isTerminating, !removingAccountIDs.contains(account.id),
              refreshGenerations[account.id] == loginGeneration else { throw CancellationError() }
        if let index = accounts.firstIndex(where: { $0.id == account.id }) {
            accounts[index].email = account.email
            accounts[index].plan = account.plan
        } else if let added = result.accounts.first(where: { $0.id == account.id }) {
            let insertion = added.displayPlan == "Free" ? accounts.count
                : accounts.lastIndex(where: { $0.displayPlan != "Free" }).map { $0 + 1 } ?? 0
            accounts.insert(added, at: insertion)
        }
        credentialExpirations[account.id] = expiration
        refreshStates[account.id] = .idle
        if let expiration, expiration <= refreshEnvironment.now() {
            refreshStates[account.id] = .requiresLogin
        } else {
            refreshCoordinator.requestAccount(account.id, generation: loginGeneration)
            refreshStates[account.id] = .refreshing
        }
        return result.reused
    }

    func toggleResetNotifications(accountID: String) {
        guard let account = accounts.first(where: { $0.id == accountID }) else { return }
        if DistributionProfile.isMock,
           let index = accounts.firstIndex(where: { $0.id == accountID }) {
            accounts[index].resetNotificationsEnabled = !accounts[index].resetNotificationsAreEnabled
            return
        }
        guard refreshStates[accountID]?.needsLogin != true else {
            showToast("Sign in again before enabling reset alerts.", style: .warning)
            return
        }
        Task {
            do {
                if account.resetNotificationsAreEnabled {
                    _ = try await store.setResetNotifications(accountID: accountID, enabled: false)
                    _ = try await store.removePendingUsageResetEvents(accountID: accountID)
                    if let index = accounts.firstIndex(where: { $0.id == accountID }) {
                        accounts[index].resetNotificationsEnabled = false
                        accounts[index].pendingNotificationEvents = accounts[index].queuedNotificationEvents.filter {
                            if case .earlyUsageReset = $0.kind { return false }
                            return true
                        }
                    }
                    await notificationScheduler.removeNotifications(accountID: accountID)
                    showToast("Reset alerts turned off for \(account.email).", style: .success)
                    return
                }

                guard try await notificationScheduler.requestPermission() else {
                    showToast(
                        "Notifications are off. Enable Quodex in System Settings → Notifications.",
                        style: .warning,
                        duration: 6
                    )
                    return
                }
                guard accounts.contains(where: { $0.id == accountID }) else { return }
                _ = try await store.setResetNotifications(accountID: accountID, enabled: true)
                if let index = accounts.firstIndex(where: { $0.id == accountID }) {
                    accounts[index].resetNotificationsEnabled = true
                }
                try await notificationScheduler.reconcile(accounts: notificationEligibleAccounts)
                showToast("Reset alerts turned on for \(account.email).", style: .success)
            } catch {
                showToast(Self.message(for: error), style: .warning, duration: 5)
            }
        }
    }

    func previewMoveAccount(_ draggedID: String, over destinationID: String) {
        guard let order = AccountOrdering.moving(
            accounts.map(\.id),
            draggedID: draggedID,
            over: destinationID
        ) else { return }
        let byID = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) })
        accounts = order.compactMap { byID[$0] }
    }

    func previewMoveAccountToEnd(_ draggedID: String) {
        guard let order = AccountOrdering.movingToEnd(accounts.map(\.id), draggedID: draggedID) else {
            return
        }
        let byID = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) })
        accounts = order.compactMap { byID[$0] }
    }

    func previewAccountOrder(_ accountIDs: [String]) {
        guard accountIDs.count == accounts.count,
              Set(accountIDs) == Set(accounts.map(\.id)) else { return }
        let byID = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) })
        accounts = accountIDs.compactMap { byID[$0] }
    }

    func commitAccountOrder(accountIDs: [String]) {
        guard accountIDs.count == accounts.count,
              Set(accountIDs).count == accountIDs.count,
              Set(accountIDs) == Set(accounts.map(\.id)) else { return }
        previewAccountOrder(accountIDs)
        persistAccountOrder(accountIDs)
    }

    private func persistAccountOrder(_ accountIDs: [String], successMessage: String? = nil) {
        orderRevision += 1
        let revision = orderRevision
        if DistributionProfile.isMock {
            if let successMessage { showToast(successMessage, style: .success) }
            return
        }
        let previous = orderPersistenceTask
        orderPersistenceTask = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            do {
                let storedIDs = await store.all().map(\.id)
                let storedSet = Set(storedIDs)
                let requestedSet = Set(accountIDs)
                let order = accountIDs.filter { storedSet.contains($0) }
                    + storedIDs.filter { !requestedSet.contains($0) }
                try await refreshEnvironment.reorder(order)
                if orderRevision == revision, let successMessage {
                    showToast(successMessage, style: .success)
                }
            } catch {
                if orderRevision == revision {
                    let stored = await store.all().map(\.id)
                    let current = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) })
                    let storedSet = Set(stored)
                    accounts = stored.compactMap { current[$0] }
                        + accounts.filter { !storedSet.contains($0.id) }
                    showToast(Self.message(for: error), style: .warning, duration: 5)
                }
            }
        }
    }

    func bootstrap() async {
        guard !isTerminating else { return }
        let runID = UUID()
        bootstrapID = runID
        cancelRefreshWork()
        isLoadingAccounts = true
        loadError = nil
        isSorting = false
        if DistributionProfile.isMock {
            do {
                accounts = try MockDataProvider.load()
                refreshStates = Dictionary(uniqueKeysWithValues: accounts.map { account in
                    let fetchedAt = account.lastSnapshot?.fetchedAt ?? Date()
                    let state: AccountRefreshState = Date().timeIntervalSince(fetchedAt) < 2 * 60
                        ? .current(fetchedAt)
                        : .cached(fetchedAt)
                    return (account.id, state)
                })
            } catch {
                loadError = Self.message(for: error)
            }
            isLoadingAccounts = false
            return
        }
        do {
            let drainingTasks = Array(accountRefreshTasks.values)
            for task in drainingTasks { await task.value }
            guard bootstrapID == runID, !isTerminating else { return }
            let loaded = try await store.load()
            guard bootstrapID == runID, !isTerminating else { return }
            accounts = loaded
            refreshStates = Dictionary(uniqueKeysWithValues: accounts.map { account in
                (
                    account.id,
                    account.lastSnapshot.map { .cached($0.fetchedAt) } ?? .idle
                )
            })
            for account in accounts where refreshGenerations[account.id] == nil {
                refreshGenerations[account.id] = UUID()
            }
            await loadCredentialExpirations()
            guard bootstrapID == runID, !isTerminating else { return }
            if notificationCenterIsReady {
                await notificationScheduler.removeOrphanedNotifications(
                    validAccountIDs: Set(accounts.map(\.id))
                )
                try? await notificationScheduler.reconcile(accounts: notificationEligibleAccounts)
                await flushPendingNotificationEvents()
            }
            restartPeriodicRefreshLoop()
        } catch {
            loadError = Self.message(for: error)
        }
        guard bootstrapID == runID, !isTerminating else { return }
        isLoadingAccounts = false
        drainRefreshQueue()
        if !accounts.isEmpty { requestFullRefresh(intent: .automatic) }
        restartPeriodicRefreshLoop()
    }

    private func generation(for accountID: String) -> UUID {
        if let generation = refreshGenerations[accountID] { return generation }
        let generation = UUID()
        refreshGenerations[accountID] = generation
        return generation
    }

    private func isEligible(_ accountID: String) -> Bool {
        !removingAccountIDs.contains(accountID)
            && !updatingLoginAccountIDs.contains(accountID)
            && refreshStates[accountID]?.needsLogin != true
            && accounts.contains { $0.id == accountID }
    }

    private func isCurrent(_ request: RefreshRequest) -> Bool {
        !isTerminating && !Task.isCancelled && isEligible(request.accountID)
            && refreshGenerations[request.accountID] == request.generation
    }

    private func restoreCachedState(_ accountID: String) {
        guard let account = accounts.first(where: { $0.id == accountID }),
              refreshStates[accountID]?.needsLogin != true else { return }
        refreshStates[accountID] = account.lastSnapshot.map { .cached($0.fetchedAt) } ?? .idle
    }

    private func invalidateRefresh(_ accountID: String) {
        refreshGenerations[accountID] = UUID()
        refreshCoordinator.invalidate(accountID)
        accountRefreshTasks[accountID]?.cancel()
        restoreCachedState(accountID)
    }

    private func cancelRefreshWork() {
        for accountID in refreshGenerations.keys { invalidateRefresh(accountID) }
        refreshCoordinator.cancelPendingWork()
        isSorting = false
        isRefreshing = refreshCoordinator.hasAnyWork
    }

    private func recordFullRefreshAttempt() {
        let attempt = refreshEnvironment.now()
        lastRefreshAttemptAt = attempt
        defaults.set(attempt, forKey: Self.lastAllAccountRefreshAttemptKey)
        restartPeriodicRefreshLoop()
    }

    private func drainRefreshQueue() {
        guard !isTerminating, !isLoadingAccounts else { return }
        while let request = refreshCoordinator.reserveNext() {
            guard isEligible(request.accountID),
                  refreshGenerations[request.accountID] == request.generation else {
                refreshCoordinator.finish(request, succeeded: false)
                continue
            }
            refreshStates[request.accountID] = .refreshing
            accountRefreshTasks[request.accountID] = Task { [weak self] in
                guard let self else { return }
                let succeeded = await refreshOne(request)
                accountRefreshTasks[request.accountID] = nil
                refreshCoordinator.finish(request, succeeded: succeeded)
                drainRefreshQueue()
            }
        }
        isRefreshing = refreshCoordinator.hasAnyWork
        guard removingAccountIDs.isEmpty, updatingLoginAccountIDs.isEmpty,
              !(isDragging && refreshCoordinator.activeFullRun?.sortAfterCompletion == true),
              let run = refreshCoordinator.finishFullIfDrained() else { return }
        lastRefreshCompletedAt = refreshEnvironment.now()
        defaults.set(lastRefreshCompletedAt, forKey: Self.lastAllAccountRefreshCompletionKey)
        if run.sortAfterCompletion {
            applySoonestResetSort(availableAccountIDs: run.successfulAccountIDs)
        }
        isRefreshing = refreshCoordinator.hasAnyWork
        isSorting = false
        restartPeriodicRefreshLoop()
        if notificationCenterIsReady {
            Task { try? await notificationScheduler.reconcile(accounts: notificationEligibleAccounts) }
        }
    }

    private func refreshOne(_ request: RefreshRequest) async -> Bool {
        let accountID = request.accountID
        guard isCurrent(request) else { return false }
        do {
            let result = try await refreshEnvironment.fetch(accountID)
            guard isCurrent(request) else { return false }
            let update = try await refreshEnvironment.updateSnapshot(accountID, result)
            guard isCurrent(request),
                  let index = accounts.firstIndex(where: { $0.id == accountID }),
                  let updated = update.accounts.first(where: { $0.id == accountID }) else { return false }
            accounts[index].lastSnapshot = updated.lastSnapshot
            accounts[index].email = updated.email
            accounts[index].plan = updated.plan
            accounts[index].lastKnownBankedResetCount = updated.lastKnownBankedResetCount
            accounts[index].pendingNotificationEvents = updated.pendingNotificationEvents
            refreshStates[accountID] = .current(result.snapshot.fetchedAt)
            if notificationCenterIsReady {
                await flushPendingNotificationEvents()
                if refreshCoordinator.activeFullRun == nil {
                    try? await notificationScheduler.reconcile(accounts: notificationEligibleAccounts)
                }
            }
            return isCurrent(request)
        } catch {
            guard isCurrent(request) else { return false }
            if let quotaError = error as? QuodexError, quotaError.requiresReauthentication {
                refreshStates[accountID] = .requiresLogin
                credentialExpirations[accountID] = nil
                if notificationCenterIsReady {
                    await notificationScheduler.removeNotifications(accountID: accountID)
                }
            } else if error is CancellationError {
                restoreCachedState(accountID)
            } else {
                refreshStates[accountID] = .failed(Self.message(for: error))
            }
            return false
        }
    }

    private static func message(for error: Error) -> String {
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription {
            return description
        }
        return error.localizedDescription
    }

    private var notificationEligibleAccounts: [AccountRecord] {
        accounts.filter { refreshStates[$0.id]?.needsLogin != true }
    }

    private func flushPendingNotificationEvents() async {
        let pending = accounts.flatMap(\.queuedNotificationEvents)
        guard !pending.isEmpty,
              let completed = try? await notificationScheduler.deliver(pending),
              !completed.isEmpty else { return }
        if (try? await store.clearPendingNotificationEvents(completed)) != nil {
            let delivered = Set(completed)
            for index in accounts.indices {
                let retained = accounts[index].queuedNotificationEvents.filter { !delivered.contains($0) }
                accounts[index].pendingNotificationEvents = retained.isEmpty ? nil : retained
            }
        }
    }

    private func restartPeriodicRefreshLoop() {
        periodicRefreshTask?.cancel()
        periodicRefreshTask = nil
        periodicScheduleID = UUID()
        guard !isTerminating, !isLoadingAccounts, !accounts.isEmpty,
              refreshCoordinator.activeFullRun == nil else { return }
        let scheduleID = periodicScheduleID
        let deadline = PeriodicRefreshPolicy.nextDeadline(
            lastAttemptAt: lastRefreshAttemptAt,
            now: refreshEnvironment.now()
        )
        let sleepUntil = refreshEnvironment.sleepUntil
        periodicRefreshTask = Task { [weak self] in
            do { try await sleepUntil(deadline) } catch { return }
            guard let self, !Task.isCancelled, periodicScheduleID == scheduleID else { return }
            periodicRefreshTask = nil
            expireKnownCredentials()
            requestFullRefresh(intent: .automatic)
            if refreshCoordinator.activeFullRun == nil { restartPeriodicRefreshLoop() }
        }
    }

    private func applySoonestResetSort(availableAccountIDs: Set<String>) {
        let orderedIDs = AccountResetOrdering.orderedIDs(
            accounts: accounts,
            availableAccountIDs: availableAccountIDs,
            now: refreshEnvironment.now()
        )
        let changed = orderedIDs != accounts.map(\.id)
        if changed {
            previewAccountOrder(orderedIDs)
            persistAccountOrder(orderedIDs, successMessage: "Sorted by soonest reset.")
        } else {
            showToast("Already sorted by soonest reset.", style: .success)
        }
    }

    private func performMockRefresh(intent: RefreshIntent) {
        let now = refreshEnvironment.now()
        for index in accounts.indices {
            accounts[index].lastSnapshot?.fetchedAt = now
            refreshStates[accounts[index].id] = .current(now)
        }
        lastRefreshAttemptAt = now
        lastRefreshCompletedAt = now
        if intent == .sort {
            let available = Set(accounts.map(\.id))
            let orderedIDs = AccountResetOrdering.orderedIDs(
                accounts: accounts,
                availableAccountIDs: available,
                now: now
            )
            let changed = orderedIDs != accounts.map(\.id)
            let records = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) })
            accounts = orderedIDs.compactMap { records[$0] }
            showToast(
                changed ? "Sorted by soonest reset." : "Already sorted by soonest reset.",
                style: .success
            )
        } else if intent == .manualAll {
            showToast("Refreshing all \(accounts.count) accounts’ usage limits.", style: .info)
        }
        isSorting = false
    }

    private func loadCredentialExpirations() async {
        credentialExpirations.removeAll(keepingCapacity: true)
        for account in accounts {
            do {
                if let expiration = try await refreshEnvironment.expiration(account.id) {
                    credentialExpirations[account.id] = expiration
                    if expiration <= refreshEnvironment.now() {
                        refreshStates[account.id] = .requiresLogin
                    }
                }
            } catch let error as QuodexError where error == .noStoredCredentials {
                refreshStates[account.id] = .requiresLogin
            } catch {
            }
        }
    }

    private func expireKnownCredentials() {
        let now = refreshEnvironment.now()
        let expired = credentialExpirations.compactMap { accountID, expiration in
            expiration <= now ? accountID : nil
        }
        guard !expired.isEmpty else { return }
        for accountID in expired {
            invalidateRefresh(accountID)
            credentialExpirations[accountID] = nil
            refreshStates[accountID] = .requiresLogin
            if notificationCenterIsReady {
                Task { await notificationScheduler.removeNotifications(accountID: accountID) }
            }
        }
    }

    private func copyToPasteboard(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    private func showToast(
        _ message: String,
        style: QuodexToast.Style,
        duration: TimeInterval = 3
    ) {
        toastTask?.cancel()
        let next = QuodexToast(message: message, style: style)
        toast = next
        toastTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(duration))
            } catch {
                return
            }
            guard let self, self.toast?.id == next.id else { return }
            self.toast = nil
            self.toastTask = nil
        }
    }

    private func clearLoginCodeFromClipboard() {
        clipboardCleanupTask?.cancel()
        clipboardCleanupTask = nil
        defer { activeLoginCode = nil }
        guard let activeLoginCode,
              NSPasteboard.general.string(forType: .string) == activeLoginCode else { return }
        NSPasteboard.general.clearContents()
    }

    private func scheduleLoginCodeCleanup(_ code: String) {
        clipboardCleanupTask?.cancel()
        clipboardCleanupTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(15 * 60))
            } catch {
                return
            }
            guard let self, self.activeLoginCode == code else { return }
            if NSPasteboard.general.string(forType: .string) == code {
                NSPasteboard.general.clearContents()
            }
            self.activeLoginCode = nil
            self.clipboardCleanupTask = nil
        }
    }
}
