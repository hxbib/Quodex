import AppKit
import SwiftUI

enum QuodexLayout {
    static let width: CGFloat = 438
    static let horizontalInset: CGFloat = 14
    static let sectionSpacing: CGFloat = 8
    static let minimumHeight: CGFloat = 220
    static let maximumHeight: CGFloat = 720
}

enum QuodexPopoverSizing {
    static func preferredHeight(
        accounts: [AccountRecord],
        refreshStates: [String: AccountRefreshState],
        isLoading: Bool,
        hasLoadError: Bool,
        loginPresented: Bool
    ) -> CGFloat {
        if loginPresented { return 620 }
        if isLoading || hasLoadError || accounts.isEmpty { return 420 }
        let total = headerHeight
            + poolHeight(accounts: accounts, refreshStates: refreshStates)
            + QuodexLayout.sectionSpacing
            + accountContentHeight(accounts: accounts, refreshStates: refreshStates)
        return min(QuodexLayout.maximumHeight, max(QuodexLayout.minimumHeight, total))
    }

    private static let headerHeight: CGFloat = 60

    private static func poolHeight(
        accounts: [AccountRecord],
        refreshStates: [String: AccountRefreshState]
    ) -> CGFloat {
        let confirmed = accounts.filter { refreshStates[$0.id]?.hasConfirmedSnapshot == true }
        let included = confirmed.isEmpty ? accounts : confirmed
        let laneCount = Set(included.flatMap { $0.lastSnapshot?.reportedLanes.map(\.id) ?? [] }).count
        let unknownResetStatus = confirmed.contains { $0.lastSnapshot?.bankedResets == nil }
        let warningRows = unknownResetStatus ? 1 : 0
        return 48 + CGFloat(max(1, laneCount)) * 22 + CGFloat(warningRows) * 18
    }

    private static func accountContentHeight(
        accounts: [AccountRecord],
        refreshStates: [String: AccountRefreshState]
    ) -> CGFloat {
        let cards = accounts.reduce(CGFloat.zero) { total, account in
            let laneCount = account.lastSnapshot?.reportedLanes.count ?? 0
            let bankedRow = (account.lastSnapshot?.bankedResets?.count ?? 0) > 0 ? 24 : 0
            let resetUnknownRow = refreshStates[account.id]?.hasConfirmedSnapshot == true
                && account.lastSnapshot?.bankedResets == nil ? 20 : 0
            let stateRow: CGFloat
            switch refreshStates[account.id] {
            case .failed, .requiresLogin: stateRow = 34
            default: stateRow = 0
            }
            let usageHeight = laneCount > 0 ? CGFloat(laneCount) * 29 : 28
            return total + 60 + usageHeight + CGFloat(bankedRow + resetUnknownRow) + stateRow
        }
        return cards + CGFloat(max(0, accounts.count - 1)) * QuodexLayout.sectionSpacing
    }
}

struct RootView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Group {
            if model.loginPresented {
                LoginView(model: model)
            } else {
                DashboardView(model: model)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { QuodexBackdrop() }
        .overlay(alignment: .top) {
            if let toast = model.toast {
                ToastView(toast: toast)
                    .allowsHitTesting(false)
                    .padding(.horizontal, QuodexLayout.horizontalInset)
                    .padding(.top, 9)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.24), value: model.toast)
    }
}

private struct DashboardView: View {
    @ObservedObject var model: AppModel
    @State private var accountPendingRemoval: AccountRecord?
    @State private var dragSession: AccountDragSession?
    @State private var accountFrames: [String: CGRect] = [:]
    @State private var controlFrames: [CGRect] = []
    @StateObject private var dragController = AccountDragController()

    var body: some View {
        VStack(spacing: 0) {
            header

            if model.isLoadingAccounts {
                loadingState
            } else if let loadError = model.loadError {
                loadErrorState(loadError)
            } else if model.accounts.isEmpty {
                emptyState
            } else {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    VStack(spacing: 8) {
                        PoolSummary(
                            accounts: model.accounts,
                            refreshStates: model.refreshStates,
                            now: context.date
                        )
                        .padding(.horizontal, QuodexLayout.horizontalInset)

                        ScrollView(.vertical) {
                            LazyVStack(spacing: 8) {
                                ForEach(displayedAccounts) { account in
                                    AccountCard(
                                        account: account,
                                        state: model.refreshStates[account.id] ?? .idle,
                                        isRemoving: model.removingAccountIDs.contains(account.id),
                                        now: context.date,
                                        copyEmail: { model.copyEmail(account.email) },
                                        toggleNotifications: {
                                            model.toggleResetNotifications(accountID: account.id)
                                        },
                                        refresh: { model.refresh(accountID: account.id) },
                                        signIn: { model.presentLogin(accountID: account.id) },
                                        remove: { accountPendingRemoval = account }
                                    )
                                    .background {
                                        GeometryReader { geometry in
                                            Color.clear.preference(
                                                key: AccountCardFramePreferenceKey.self,
                                                value: [
                                                    account.id: geometry.frame(
                                                        in: .named("QuodexAccountReorderSpace")
                                                    ),
                                                ]
                                            )
                                        }
                                    }
                                    .opacity(dragSession?.accountID == account.id ? 0 : 1)
                                    .overlay {
                                        if dragSession?.accountID == account.id {
                                            DraggedCardPlaceholder()
                                        }
                                    }
                                }
                            }
                            .padding(.horizontal, QuodexLayout.horizontalInset)
                            .contentShape(Rectangle())
                            .background { AccountScrollProbe(controller: dragController).frame(width: 0, height: 0) }
                            .onPreferenceChange(AccountCardFramePreferenceKey.self) {
                                accountFrames = $0
                            }
                            .onPreferenceChange(AccountControlFramePreferenceKey.self) { controlFrames = $0 }
                        }
                        .scrollIndicators(.automatic)
                        .coordinateSpace(name: "QuodexAccountReorderSpace")
                        .overlay {
                            AccountDragInput(
                                controller: dragController,
                                enabled: !model.isSorting,
                                canBegin: canBeginDragging,
                                begin: beginDragging,
                                moved: updateDragLocation,
                                ended: finishDragging
                            )
                        }
                        .overlay(alignment: .topLeading) {
                            if let session = dragSession,
                               let account = model.accounts.first(where: { $0.id == session.accountID }) {
                                AccountCard(
                                    account: account,
                                    state: model.refreshStates[account.id] ?? .idle,
                                    isRemoving: false,
                                    now: context.date,
                                    copyEmail: {}, toggleNotifications: {}, refresh: {}, signIn: {}, remove: {}
                                )
                                .frame(width: session.size.width, height: session.size.height, alignment: .top)
                                .scaleEffect(1.018)
                                .shadow(color: .black.opacity(0.42), radius: 18, y: 8)
                                .offset(x: session.origin.x, y: session.origin.y)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                            }
                        }
                        .padding(.bottom, QuodexLayout.horizontalInset)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
                .frame(maxHeight: .infinity)
            }
        }
        .onChange(of: model.accounts.map(\.id)) { _, accountIDs in
            guard let session = dragSession else { return }
            if Set(accountIDs) != Set(session.originalOrder) { dragController.cancel() }
        }
        .onDisappear { dragController.cancel() }
        .onChange(of: model.isDragging) { _, dragging in
            if !dragging { dragController.cancel() }
        }
        .alert(
            "Remove account?",
            isPresented: Binding(
                get: { accountPendingRemoval != nil },
                set: { if !$0 { accountPendingRemoval = nil } }
            )
        ) {
            if let account = accountPendingRemoval {
                Button("Remove \(account.email)", role: .destructive) {
                    model.remove(accountID: account.id)
                    accountPendingRemoval = nil
                }
            }
            Button("Cancel", role: .cancel) { accountPendingRemoval = nil }
        } message: {
            Text("This removes the account and its Quodex credentials from this Mac. It does not alter the ChatGPT account or sign it out elsewhere.")
        }
    }

    private var displayedAccounts: [AccountRecord] {
        guard let session = dragSession,
              Set(session.previewOrder) == Set(model.accounts.map(\.id)) else {
            return model.accounts
        }
        let records = Dictionary(uniqueKeysWithValues: model.accounts.map { ($0.id, $0) })
        return session.previewOrder.compactMap { records[$0] }
    }

    private func canBeginDragging(_ point: CGPoint) -> Bool {
        guard !model.isSorting, !controlFrames.contains(where: { $0.contains(point) }) else { return false }
        return accountFrames.contains { id, frame in
            frame.contains(point) && !model.removingAccountIDs.contains(id)
        }
    }

    private func beginDragging(_ point: CGPoint) -> Bool {
        guard canBeginDragging(point),
              let (id, frame) = accountFrames.first(where: { $0.value.contains(point) }) else { return false }
        let order = model.accounts.map(\.id)
        dragSession = AccountDragSession(
            accountID: id, originalOrder: order, size: frame.size,
            grabOffset: CGPoint(x: point.x - frame.minX, y: point.y - frame.minY),
            previewOrder: order, pointer: point
        )
        model.isDragging = true
        return true
    }

    private func updateDragLocation(_ location: CGPoint) {
        guard var session = dragSession else { return }
        let changed = session.update(pointer: location, frames: accountFrames)
        if changed {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            withAnimation(.interactiveSpring(response: 0.23, dampingFraction: 0.86)) { dragSession = session }
        } else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { dragSession = session }
        }
    }

    private func finishDragging(_ accepted: Bool) {
        guard let session = dragSession else { return }
        if accepted, Set(session.previewOrder) == Set(model.accounts.map(\.id)),
           session.previewOrder != session.originalOrder {
            model.commitAccountOrder(accountIDs: session.previewOrder)
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        }
        withAnimation(.snappy(duration: 0.16)) { dragSession = nil }
        model.isDragging = false
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(.blue.gradient)
                QuodexMark()
                    .stroke(
                        .white,
                        style: StrokeStyle(lineWidth: 3.2, lineCap: .round, lineJoin: .round)
                    )
                    .frame(width: 27, height: 27)
            }
            .frame(width: 32, height: 32)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Quodex")

            VStack(alignment: .leading, spacing: 1) {
                Text("Quodex")
                    .font(.system(size: 16, weight: .semibold))
                Text(accountCountLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            HStack(spacing: 6) {
                QuodexCircularButton(
                    systemName: model.isPinned ? "pin.fill" : "pin",
                    tint: model.isPinned ? .blue : .secondary,
                    isActive: model.isPinned,
                    help: model.isPinned ? "Unpin popover" : "Keep popover open",
                    accessibilityLabel: model.isPinned ? "Unpin Quodex" : "Pin Quodex open"
                ) {
                    model.isPinned.toggle()
                }

                QuodexCircularButton(
                    systemName: "arrow.up.arrow.down",
                    tint: .secondary,
                    help: "Refresh, then sort by soonest reset",
                    accessibilityLabel: "Sort accounts by soonest reset",
                    isLoading: model.isSorting,
                    isDisabled: dragSession != nil || model.accounts.isEmpty
                ) {
                    model.sortBySoonestReset()
                }

                QuodexCircularButton(
                    systemName: "arrow.clockwise",
                    tint: .secondary,
                    help: "Refresh all accounts",
                    accessibilityLabel: "Refresh usage",
                    isLoading: model.isRefreshing,
                    isDisabled: model.accounts.isEmpty
                ) {
                    model.refreshAll()
                }

                QuodexCircularButton(
                    systemName: "plus",
                    tint: .white,
                    isProminent: true,
                    help: "Add account",
                    accessibilityLabel: "Add ChatGPT account",
                    isDisabled: model.accounts.count >= AccountStore.maximumAccounts
                ) {
                    model.presentLogin()
                }
            }
        }
        .padding(.horizontal, QuodexLayout.horizontalInset)
        .padding(.top, 18)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity)
    }

    private var accountCountLabel: String {
        let count = model.accounts.count
        return "\(count) \(count == 1 ? "account" : "accounts")"
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "person.2.badge.plus")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.secondary)
            Text("Track your ChatGPT accounts")
                .font(.title3.weight(.semibold))
            Text("Sign in to see live usage limits and reset information.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 320)
            Button("Add your first account") {
                model.presentLogin()
            }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            Spacer()
            PrivacyFootnote()
        }
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .padding(.bottom, QuodexLayout.horizontalInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var loadingState: some View {
        VStack(spacing: 12) {
            Spacer()
            ProgressView()
                .controlSize(.large)
            Text("Loading accounts…")
                .font(.headline)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func loadErrorState(_ message: String) -> some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 36))
                .foregroundStyle(.orange)
            Text("Couldn’t load accounts")
                .font(.title3.weight(.semibold))
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 320)
            Button("Try again") { model.retryLoadingAccounts() }
                .buttonStyle(.borderedProminent)
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

}

private struct PoolSummary: View {
    let accounts: [AccountRecord]
    let refreshStates: [String: AccountRefreshState]
    let now: Date

    private var lanes: [PooledLane] {
        var values: [String: PooledLane] = [:]
        let included = confirmedCount > 0
            ? accounts.filter { refreshStates[$0.id]?.hasConfirmedSnapshot == true }
            : accounts
        for account in included {
            guard let snapshot = account.lastSnapshot else { continue }
            for lane in snapshot.reportedLanes {
                let key = lane.id
                var pooled = values[key] ?? PooledLane(
                    group: lane.group,
                    name: lane.name,
                    remaining: 0,
                    accountCount: 0,
                    nextReset: nil
                )
                pooled.remaining += lane.remainingPercent
                pooled.accountCount += 1
                if let reset = lane.resetAt,
                   pooled.nextReset == nil || reset < pooled.nextReset! {
                    pooled.nextReset = reset
                }
                values[key] = pooled
            }
        }
        return values.values.sorted { left, right in
            let leftRank = LaneSort.rank(group: left.group, name: left.name)
            let rightRank = LaneSort.rank(group: right.group, name: right.name)
            return leftRank == rightRank
                ? "\(left.group) \(left.name)" < "\(right.group) \(right.name)"
                : leftRank < rightRank
        }
    }

    private var resetCount: Int {
        accounts.compactMap { account in
            guard refreshStates[account.id]?.hasConfirmedSnapshot == true else { return nil }
            return account.lastSnapshot?.bankedResets?.count
        }.reduce(0, +)
    }

    private var resetKnownCount: Int {
        accounts.filter { account in
            refreshStates[account.id]?.hasConfirmedSnapshot == true
                && account.lastSnapshot?.bankedResets != nil
        }.count
    }

    private var confirmedCount: Int {
        accounts.filter { refreshStates[$0.id]?.hasConfirmedSnapshot == true }.count
    }

    private var liveCount: Int {
        accounts.filter { refreshStates[$0.id]?.isFresh(at: now) == true }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Pool capacity")
                        .font(.headline)
                    Text(statusLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if resetCount > 0 {
                    Label("\(resetCount) reset\(resetCount == 1 ? "" : "s")", systemImage: "arrow.counterclockwise.circle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.yellow)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(.yellow.opacity(0.12), in: Capsule())
                }
            }

            if confirmedCount > 0, resetKnownCount < confirmedCount {
                Label("Reset status available for \(resetKnownCount) of \(confirmedCount) current accounts", systemImage: "exclamationmark.circle")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if !lanes.isEmpty, lanes.allSatisfy({ $0.remaining <= 0 }) {
                Label("All currently reported capacity is depleted", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
            }

            if lanes.isEmpty {
                Text("Usage will appear after the first live refresh.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(lanes) { lane in
                    HStack(spacing: 8) {
                        Text("\(lane.title) · \(lane.accountCount) acct\(lane.accountCount == 1 ? "" : "s")")
                            .font(.caption.weight(.medium))
                            .lineLimit(1)
                        Spacer()
                        Text("\(Int(lane.remaining.rounded()))%")
                            .font(.caption.monospacedDigit().weight(.semibold))
                            .frame(width: 42, alignment: .trailing)
                            .help("Sum of the displayed per-account percentages remaining")
                        Text(lane.nextReset.map {
                            ResetTime.compact($0, now: now, prefix: "next ")
                        } ?? "")
                        .font(.system(size: 9.5, weight: .regular).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(width: 146, alignment: .trailing)
                        .accessibilityHidden(lane.nextReset == nil)
                    }
                }
            }
        }
        .padding(10)
        .background {
            QuodexCardSurface()
        }
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(.white.opacity(0.12))
        )
    }

    private var statusLabel: String {
        if liveCount == accounts.count, !accounts.isEmpty {
            return accounts.count == 1 ? "Live usage" : "Live across all \(accounts.count) accounts"
        }
        if confirmedCount == accounts.count, !accounts.isEmpty {
            if liveCount > 0 {
                return "\(liveCount) live · \(confirmedCount - liveCount) last updated"
            }
            if let oldest = confirmedDates.min() {
                return "All updated \(UpdateAge.phrase(since: oldest, now: now)) or newer"
            }
        }
        if confirmedCount > 0 {
            let unavailable = accounts.count - confirmedCount
            return "\(liveCount) live · \(confirmedCount - liveCount) last updated · \(unavailable) unavailable"
        }
        if accounts.allSatisfy({ account in
            if case .failed = refreshStates[account.id] { return true }
            if case .requiresLogin = refreshStates[account.id] { return true }
            return false
        }) {
            return "No live accounts · showing last known data"
        }
        return "Refreshing \(accounts.count) \(accounts.count == 1 ? "account" : "accounts")"
    }

    private var confirmedDates: [Date] {
        accounts.compactMap { account in
            switch refreshStates[account.id] {
            case let .cached(fetchedAt), let .current(fetchedAt): fetchedAt
            default: nil
            }
        }
    }
}

private struct QuodexCircularButton: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var isHovering = false

    let systemName: String
    let tint: Color
    var isActive = false
    var isProminent = false
    let help: String
    let accessibilityLabel: String
    var iconSize: CGFloat = 12
    var isLoading = false
    var isDisabled = false
    var fallbackFill: Color? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                surface
                    .frame(width: 28, height: 28)
                    .allowsHitTesting(false)
                Circle()
                    .fill(.white.opacity(isHovering && !isDisabled ? 0.055 : 0))
                    .frame(width: 28, height: 28)
                    .allowsHitTesting(false)
                Group {
                    if isLoading {
                        ProgressView()
                            .controlSize(.mini)
                    } else {
                        Image(systemName: systemName)
                            .font(
                                .system(
                                    size: isProminent ? max(iconSize, 13) : iconSize,
                                    weight: .semibold
                                )
                            )
                            .foregroundStyle(tint)
                    }
                }
                .allowsHitTesting(false)
            }
            .frame(width: 32, height: 32)
            .contentShape(Circle())
        }
        .buttonStyle(QuodexCircularButtonStyle())
        .controlSize(.small)
        .help(help)
        .accessibilityLabel(accessibilityLabel)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.48 : 1)
        .onHover { isHovering = $0 }
        .modifier(AccountControlRegion())
    }

    @ViewBuilder
    private var surface: some View {
        if #available(macOS 26.0, *), !reduceTransparency {
            Color.clear
                .glassEffect(
                    .regular
                        .tint(
                            isProminent
                                ? Color.blue.opacity(contrast == .increased ? 0.80 : 0.72)
                                : tint.opacity(
                                    contrast == .increased
                                        ? isActive ? 0.34 : 0.22
                                        : isActive ? 0.24 : 0.14
                                )
                        )
                        .interactive(),
                    in: Circle()
                )
        } else if reduceTransparency {
            Circle()
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay {
                    Circle().fill(
                        isProminent
                            ? Color.blue.opacity(0.86)
                            : fallbackFill
                                ?? tint.opacity(isActive ? 0.26 : 0.12)
                    )
                }
        } else {
            Circle().fill(
                isProminent
                    ? Color.blue.opacity(0.86)
                    : fallbackFill
                        ?? (isActive
                            ? Color.blue.opacity(contrast == .increased ? 0.26 : 0.18)
                            : Color.primary.opacity(contrast == .increased ? 0.12 : 0.065))
            )
        }
    }

}

private struct QuodexCircularButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.93 : 1)
            .brightness(configuration.isPressed ? -0.08 : 0)
            .animation(.easeOut(duration: 0.09), value: configuration.isPressed)
    }
}

private struct DraggedCardPlaceholder: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(.blue.opacity(0.055))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(.blue.opacity(0.42), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            }
            .padding(1)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

private struct AccountCardFramePreferenceKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}

private struct AccountControlFramePreferenceKey: PreferenceKey {
    static let defaultValue: [CGRect] = []
    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) {
        value.append(contentsOf: nextValue())
    }
}

private struct AccountControlRegion: ViewModifier {
    func body(content: Content) -> some View {
        content.background {
            GeometryReader { geometry in
                Color.clear.preference(
                    key: AccountControlFramePreferenceKey.self,
                    value: [geometry.frame(in: .named("QuodexAccountReorderSpace"))]
                )
            }
        }
    }
}

private struct AccountCard: View {
    let account: AccountRecord
    let state: AccountRefreshState
    let isRemoving: Bool
    let now: Date
    let copyEmail: () -> Void
    let toggleNotifications: () -> Void
    let refresh: () -> Void
    let signIn: () -> Void
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Circle()
                    .fill(avatarGradient)
                    .frame(width: 30, height: 30)
                    .overlay {
                        Text(initials)
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white)
                    }

                VStack(alignment: .leading, spacing: 3) {
                    Button {
                        copyEmail()
                    } label: {
                        Text(account.email)
                            .font(.system(size: 13, weight: .semibold))
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .buttonStyle(.plain)
                    .help("Copy email")
                    .modifier(AccountControlRegion())
                    .accessibilityLabel("Copy \(account.email)")
                    HStack(spacing: 5) {
                        Text(account.displayPlan)
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.secondary.opacity(0.12), in: Capsule())
                        freshness
                    }
                }

                Spacer(minLength: 4)

                if state.hasConfirmedSnapshot,
                   let count = account.lastSnapshot?.bankedResets?.count,
                   count > 0 {
                    Label("\(count) reset\(count == 1 ? "" : "s")", systemImage: "arrow.counterclockwise.circle.fill")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.yellow)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 5)
                        .background(.yellow.opacity(0.15), in: Capsule())
                        .help("\(count) banked usage reset\(count == 1 ? "" : "s")")
                }

                HStack(spacing: 4) {
                    QuodexCircularButton(
                        systemName: account.resetNotificationsAreEnabled ? "bell.fill" : "bell",
                        tint: account.resetNotificationsAreEnabled ? .blue : .secondary,
                        isActive: account.resetNotificationsAreEnabled,
                        help: account.resetNotificationsAreEnabled
                            ? "Turn off reset alerts for \(account.email)"
                            : "Notify when limits reset for \(account.email)",
                        accessibilityLabel: account.resetNotificationsAreEnabled
                            ? "Turn off reset alerts for \(account.email)"
                            : "Turn on reset alerts for \(account.email)",
                        iconSize: 11,
                        isDisabled: isRemoving || state.needsLogin,
                        fallbackFill: account.resetNotificationsAreEnabled
                            ? Color.blue.opacity(0.16)
                            : Color.primary.opacity(0.055),
                        action: toggleNotifications
                    )

                    QuodexCircularButton(
                        systemName: "arrow.clockwise",
                        tint: .secondary,
                        help: "Refresh \(account.email)",
                        accessibilityLabel: "Refresh \(account.email)",
                        iconSize: 11,
                        isLoading: state == .refreshing,
                        isDisabled: isRemoving || state.needsLogin,
                        fallbackFill: Color.primary.opacity(0.055),
                        action: refresh
                    )

                    QuodexCircularButton(
                        systemName: "trash",
                        tint: .red,
                        help: "Remove \(account.email)",
                        accessibilityLabel: "Remove \(account.email)",
                        iconSize: 11,
                        isDisabled: isRemoving,
                        fallbackFill: Color.red.opacity(0.085),
                        action: remove
                    )
                }

                if isRemoving {
                    ProgressView()
                        .controlSize(.mini)
                        .accessibilityLabel("Removing \(account.email)")
                }
            }

            if let snapshot = account.lastSnapshot, !snapshot.reportedLanes.isEmpty {
                ForEach(snapshot.reportedLanes.sorted(by: LaneSort.lessThan)) { lane in
                    UsageLaneRow(lane: lane, now: now)
                }
                if state.hasConfirmedSnapshot, let resets = snapshot.bankedResets, resets.count > 0 {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.counterclockwise.circle.fill")
                            .foregroundStyle(.yellow)
                        Text("\(resets.count) banked reset\(resets.count == 1 ? "" : "s") available")
                            .font(.caption.weight(.medium))
                        Spacer()
                        if let expiry = resets.earliestExpiry {
                            Text("expires \(RelativeTime.short(from: expiry, now: now))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else if state.hasConfirmedSnapshot, snapshot.bankedResets == nil {
                    Label("Banked reset status unavailable", systemImage: "exclamationmark.circle")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else {
                HStack(spacing: 8) {
                    if case .refreshing = state { ProgressView().controlSize(.small) }
                    Text(emptyUsageLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            if case let .failed(message) = state {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Button("Retry") { refresh() }
                        .modifier(AccountControlRegion())
                        .font(.caption2.weight(.semibold))
                        .buttonStyle(.borderless)
                }
            }


            if case .requiresLogin = state {
                HStack(alignment: .center, spacing: 8) {
                    Label("Login required", systemImage: "person.crop.circle.badge.exclamationmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                    Spacer()
                    Button("Sign in") { signIn() }
                        .modifier(AccountControlRegion())
                        .font(.caption.weight(.semibold))
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
                .accessibilityElement(children: .contain)
            }
        }
        .padding(10)
        .background {
            QuodexCardSurface()
        }
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.white.opacity(0.095), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var freshness: some View {
        switch state {
        case .idle:
            Text("Saved")
                .font(.caption2)
                .foregroundStyle(.secondary)
        case let .cached(fetchedAt):
            Text("Last updated \(UpdateAge.phrase(since: fetchedAt, now: now))")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
        case .refreshing:
            Text("Syncing…")
                .font(.caption2)
                .foregroundStyle(.blue)
        case let .current(fetchedAt):
            Text(
                now.timeIntervalSince(fetchedAt) < 2 * 60
                    ? "Live"
                    : "Last updated \(UpdateAge.phrase(since: fetchedAt, now: now))"
            )
                .font(.caption2.weight(.semibold))
                .foregroundStyle(now.timeIntervalSince(fetchedAt) < 2 * 60 ? .green : .secondary)
        case .failed:
            Text(
                account.lastSnapshot.map {
                    "Last updated \(UpdateAge.phrase(since: $0.fetchedAt, now: now))"
                } ?? "Update failed"
            )
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.orange)
        case .requiresLogin:
            Text("Login required")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.orange)
        }
    }

    private var initials: String {
        let prefix = account.email.split(separator: "@").first.map(String.init) ?? account.email
        let parts = prefix.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        if parts.count > 1 {
            return parts.prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
        }
        return String(prefix.prefix(2)).uppercased()
    }

    private var avatarGradient: LinearGradient {
        let hue = Double(abs(account.id.hashValue % 360)) / 360
        return LinearGradient(
            colors: [Color(hue: hue, saturation: 0.72, brightness: 0.85), Color(hue: hue + 0.08, saturation: 0.8, brightness: 0.62)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var emptyUsageLabel: String {
        if case .failed = state { return "No current usage snapshot" }
        if case .requiresLogin = state { return "Login required to load usage" }
        return "Loading live usage…"
    }
}

private struct UsageLaneRow: View {
    let lane: UsageLane
    let now: Date

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Text(laneTitle)
                    .font(.caption.weight(.medium))
                Spacer()
                Text("\(Int(lane.remainingPercent.rounded()))% left")
                    .font(.caption.monospacedDigit().weight(.semibold))
                if let reset = lane.resetAt {
                    Text(ResetTime.compact(reset, now: now))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .frame(minWidth: 126, alignment: .trailing)
                } else {
                    Text("No reset time")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.secondary.opacity(0.15))
                    Capsule()
                        .fill(progressColor.gradient)
                        .frame(width: geometry.size.width * lane.remainingPercent / 100)
                }
            }
            .frame(height: 4)
            .accessibilityHidden(true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(laneTitle) limit")
        .accessibilityValue(accessibilityValue)
    }

    private var laneTitle: String {
        lane.displayName
    }

    private var progressColor: Color {
        switch UsageLaneTone.resolve(
            group: lane.group,
            remainingPercent: lane.remainingPercent
        ) {
        case .critical:
            Color(red: 0.70, green: 0.04, blue: 0.08)
        case .reserve:
            Color(red: 0.98, green: 0.72, blue: 0.04)
        case .standard:
            .blue
        }
    }

    private var accessibilityValue: String {
        let remaining = "\(Int(lane.remainingPercent.rounded())) percent remaining"
        if let reset = lane.resetAt {
            return "\(remaining), resets \(ResetTime.accessible(reset, now: now))"
        }
        return "\(remaining), reset time unavailable"
    }
}

private struct LoginView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    model.cancelLogin()
                } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Back to accounts")
                Spacer()
                Text(model.loginTargetEmail == nil ? "Add ChatGPT account" : "Sign in again")
                    .font(.headline)
                Spacer()
                Color.clear.frame(width: 16, height: 16)
            }
            .padding(14)

            Divider()

            VStack(spacing: 18) {
                Spacer()
                loginContent
                Spacer()
            }
            .padding(28)

            PrivacyFootnote()
                .padding(.horizontal, QuodexLayout.horizontalInset)
                .padding(.top, 8)
                .padding(.bottom, QuodexLayout.horizontalInset)
        }
    }

    @ViewBuilder
    private var loginContent: some View {
        switch model.loginState {
        case .idle:
            Image(systemName: "person.crop.circle.badge.plus")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.blue)
            Text(model.loginTargetEmail == nil ? "Sign in with a one-time code" : "Refresh this session")
                .font(.title3.weight(.semibold))
            if let email = model.loginTargetEmail {
                Text(email)
                    .font(.callout.weight(.semibold))
                    .textSelection(.enabled)
            }
            Text(loginInstructions)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Start sign-in") { model.startLogin() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

        case .requestingCode:
            ProgressView()
                .controlSize(.large)
            Text("Requesting a secure sign-in code…")
                .font(.headline)

        case let .waiting(login):
            Image(systemName: "checkmark.shield")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(.blue)
            Text("Enter this code")
                .font(.headline)
            Text(login.userCode)
                .font(.system(size: 30, weight: .bold, design: .monospaced))
                .textSelection(.enabled)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            HStack {
                Button("Copy code") { model.copyLoginCode() }
                Button("Open login page") { model.openLoginPage() }
                    .buttonStyle(.borderedProminent)
            }
            Text("Waiting for OpenAI to confirm sign-in…")
                .font(.caption)
                .foregroundStyle(.secondary)

        case let .complete(message):
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)
            Text("Account ready")
                .font(.title3.weight(.semibold))
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Done") { model.finishLogin() }
                .buttonStyle(.borderedProminent)

        case let .failed(message):
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.orange)
            Text("Sign-in did not finish")
                .font(.title3.weight(.semibold))
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            HStack {
                Button("Cancel") { model.cancelLogin() }
                Button("Try again") { model.startLogin() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private var loginInstructions: String {
        if let email = model.loginTargetEmail {
            return "A secure OpenAI page will open. Sign in as \(email), then enter the code shown here. A different account will be rejected without changing any session."
        }
        return "A secure OpenAI page will open in your browser. Sign in to the account you want to track, then enter the code shown here."
    }
}

private struct PrivacyFootnote: View {
    var body: some View {
        Text("Quodex stores this account’s tokens locally in your Mac’s Keychain. It does not read or modify the official ChatGPT or Codex apps.")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct QuodexBackdrop: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        if #available(macOS 26.0, *), !reduceTransparency {
            LinearGradient(
                colors: [
                    Color.black.opacity(nativeTintOpacity + 0.05),
                    Color.black.opacity(nativeTintOpacity),
                    Color.black.opacity(nativeTintOpacity + 0.03)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        } else {
            ZStack {
                if reduceTransparency {
                    Color(nsColor: .windowBackgroundColor)
                } else {
                    QuodexMaterialSurface()
                }
                LinearGradient(
                    colors: [
                        Color.black.opacity(tintOpacity + 0.035),
                        Color.black.opacity(tintOpacity * 0.82),
                        Color.black.opacity(tintOpacity + 0.015)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        }
    }

    private var nativeTintOpacity: Double {
        contrast == .increased ? 0.16 : 0.07
    }

    private var tintOpacity: Double {
        if reduceTransparency { return 0.72 }
        if contrast == .increased { return 0.30 }
        return 0.18
    }
}

private struct QuodexCardSurface: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        if #available(macOS 26.0, *), !reduceTransparency {
            Color.clear
                .glassEffect(
                    .regular.tint(
                        .black.opacity(contrast == .increased ? 0.11 : 0.065)
                    ),
                    in: shape
                )
        } else {
            Group {
                if reduceTransparency {
                    shape.fill(Color(nsColor: .controlBackgroundColor))
                } else {
                    Color.clear.background(.thinMaterial, in: shape)
                }
            }
                .overlay(
                    shape.fill(
                        .black.opacity(
                            reduceTransparency
                                ? 0.14
                                : contrast == .increased ? 0.09 : 0.055
                        )
                    )
                )
        }
    }
}

private struct ToastView: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let toast: QuodexToast

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: toastSymbol)
                .foregroundStyle(toastColor)
            Text(toast.message)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .background {
            let shape = RoundedRectangle(cornerRadius: 11, style: .continuous)
            if reduceTransparency {
                shape.fill(Color(nsColor: .controlBackgroundColor))
            } else {
                Color.clear.background(.thickMaterial, in: shape)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.28), radius: 12, y: 5)
    }

    private var toastSymbol: String {
        switch toast.style {
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .info: "arrow.clockwise.circle.fill"
        }
    }

    private var toastColor: Color {
        switch toast.style {
        case .success: .green
        case .warning: .orange
        case .info: .blue
        }
    }
}

private struct PooledLane: Identifiable {
    var id: String { "\(group)|\(name)" }
    var group: String
    var name: String
    var remaining: Double
    var accountCount: Int
    var nextReset: Date?
    var title: String { UsageLane.displayName(group: group, name: name) }
}

private enum LaneSort {
    static func rank(group: String, name: String) -> Int {
        if group == "Standard" && name == "5-hour" { return 0 }
        if group == "Standard" && name == "Weekly" { return 1 }
        if group.localizedCaseInsensitiveContains("reserve") { return 2 }
        if name == "Free Monthly" { return 3 }
        return 10
    }

    static func lessThan(_ left: UsageLane, _ right: UsageLane) -> Bool {
        let leftRank = rank(group: left.group, name: left.name)
        let rightRank = rank(group: right.group, name: right.name)
        return leftRank == rightRank
            ? "\(left.group) \(left.name)" < "\(right.group) \(right.name)"
            : leftRank < rightRank
    }
}

private enum RelativeTime {
    static func short(from date: Date, now: Date) -> String {
        let interval = date.timeIntervalSince(now)
        if abs(interval) < 60 { return interval >= 0 ? "now" : "just now" }
        if interval > 0, interval < 24 * 60 * 60 {
            let hours = Int(interval) / 3600
            let minutes = (Int(interval) % 3600) / 60
            if hours > 0 { return "in \(hours)h \(minutes)m" }
            return "in \(max(1, minutes))m"
        }
        if interval < 0, abs(interval) < 24 * 60 * 60 {
            let minutes = max(1, Int(abs(interval)) / 60)
            return minutes < 60 ? "\(minutes)m ago" : "\(minutes / 60)h ago"
        }
        return date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }
}

private enum UpdateAge {
    static func phrase(since date: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return "just now" }
        if seconds < 60 * 60 { return "\(seconds / 60) min ago" }
        if seconds < 24 * 60 * 60 {
            let hours = seconds / (60 * 60)
            return "\(hours) hr\(hours == 1 ? "" : "s") ago"
        }
        let days = seconds / (24 * 60 * 60)
        return "\(days) day\(days == 1 ? "" : "s") ago"
    }
}

private enum ResetTime {
    static func compact(_ date: Date, now: Date, prefix: String = "") -> String {
        "\(prefix)\(countdown(date, now: now)) · \(clock(date, now: now))"
    }

    static func accessible(_ date: Date, now: Date) -> String {
        "\(countdown(date, now: now)), at \(date.formatted(.dateTime.weekday(.wide).month().day().hour().minute()))"
    }

    private static func countdown(_ date: Date, now: Date) -> String {
        let seconds = max(0, Int(date.timeIntervalSince(now)))
        if seconds < 60 { return "now" }
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60
        if days > 0 { return "in \(days)d \(hours)h" }
        if hours > 0 { return "in \(hours)h \(minutes)m" }
        return "in \(max(1, minutes))m"
    }

    private static func clock(_ date: Date, now: Date) -> String {
        if Calendar.current.isDate(date, inSameDayAs: now) {
            return date.formatted(.dateTime.hour().minute())
        }
        return date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }
}
