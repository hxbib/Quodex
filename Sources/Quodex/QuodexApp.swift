import AppKit
import Combine
import SwiftUI
import UserNotifications

private final class QuodexHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@main
struct QuodexApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate, UNUserNotificationCenterDelegate {
    private let model = AppModel()
    private let loginItemController = LoginItemController()
    private let popover = NSPopover()
    private var statusItem: NSStatusItem?
    private var cancellables: Set<AnyCancellable> = []
    private var localMouseMonitor: Any?
    private var localKeyMonitor: Any?
    private var globalMouseMonitor: Any?
    private var workspaceActivationObserver: NSObjectProtocol?
    private var workspaceWakeObserver: NSObjectProtocol?
    private var ignoreDismissalUntil = Date.distantPast

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if DistributionProfile.permitsSystemIntegration {
            UNUserNotificationCenter.current().delegate = self
            model.notificationCenterBecameReady()
            loginItemController.enableByDefaultIfNeeded()
        }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = QuodexMarkImage.menuBar()
            button.imagePosition = .imageOnly
            button.target = self
            button.action = #selector(handleStatusItem(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem = item
        popover.behavior = .applicationDefined
        popover.animates = true
        updatePopoverSize()
        popover.delegate = self
        let contentController = NSViewController()
        contentController.view = QuodexHostingView(rootView: RootView(model: model))
        popover.contentViewController = contentController
        installPopoverDismissalObservers()

        model.objectWillChange
            .debounce(for: .milliseconds(100), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updatePopoverSize()
            }
            .store(in: &cancellables)

        DispatchQueue.main.async { [weak self, weak button = item.button] in
            guard let self, let button else { return }
            self.showPopover(from: button)
        }
    }

    @objc private func handleStatusItem(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp {
            showStatusMenu(from: sender)
            return
        }

        if popover.isShown {
            popover.close()
        } else {
            showPopover(from: sender)
        }
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        guard let button = statusItem?.button else { return false }
        showPopover(from: button)
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        removePopoverDismissalObservers()
        model.prepareForTermination()
    }

    func popoverDidClose(_ notification: Notification) {
        model.popoverClosed()
    }

    func popoverShouldClose(_ popover: NSPopover) -> Bool {
        !model.isPinned
    }

    private func showPopover(from button: NSStatusBarButton) {
        guard !popover.isShown else { return }
        popover.behavior = .applicationDefined
        updatePopoverSize()
        ignoreDismissalUntil = Date().addingTimeInterval(0.2)
        model.popoverOpened()
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        configurePopoverWindow()
        popover.contentViewController?.view.window?.makeKey()
    }

    private func configurePopoverWindow() {
        guard let window = popover.contentViewController?.view.window else { return }
        window.isOpaque = false
        window.backgroundColor = .clear
        window.contentView?.wantsLayer = true
        window.contentView?.layer?.backgroundColor = NSColor.clear.cgColor
    }

    private func showStatusMenu(from button: NSStatusBarButton) {
        if popover.isShown {
            popover.close()
        }
        let menu = NSMenu()
        let loginItem: NSMenuItem
        switch loginItemController.state {
        case .enabled:
            loginItem = NSMenuItem(
                title: "Open at Login",
                action: #selector(toggleOpenAtLogin),
                keyEquivalent: ""
            )
            loginItem.state = .on
        case .disabled:
            loginItem = NSMenuItem(
                title: "Open at Login",
                action: #selector(toggleOpenAtLogin),
                keyEquivalent: ""
            )
            loginItem.state = .off
        case .requiresApproval:
            loginItem = NSMenuItem(
                title: "Open Login Items Settings…",
                action: #selector(openLoginItemsSettings),
                keyEquivalent: ""
            )
            loginItem.state = .mixed
        case .unavailable:
            loginItem = NSMenuItem(title: "Open at Login", action: nil, keyEquivalent: "")
            loginItem.isEnabled = false
        }
        loginItem.target = self
        menu.addItem(loginItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(
            title: "Quit Quodex",
            action: #selector(quitQuodex),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)
        menu.popUp(
            positioning: quitItem,
            at: NSPoint(x: 0, y: button.bounds.height + 2),
            in: button
        )
    }

    @objc private func quitQuodex() {
        NSApp.terminate(nil)
    }

    @objc private func toggleOpenAtLogin() {
        loginItemController.toggle()
    }

    @objc private func openLoginItemsSettings() {
        loginItemController.openSystemSettings()
    }

    private func installPopoverDismissalObservers() {
        let mouseEvents: NSEvent.EventTypeMask = [
            .leftMouseDown,
            .rightMouseDown,
            .otherMouseDown,
        ]

        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: mouseEvents) {
            [weak self] event in
            guard let self else { return event }
            if !self.eventBelongsToPopover(event),
               event.window !== self.statusItem?.button?.window {
                self.closePopoverIfUnpinned()
            }
            return event
        }

        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            guard let self,
                  event.keyCode == 53,
                  self.popover.isShown,
                  self.popover.contentViewController?.view.window?.attachedSheet == nil else {
                return event
            }
            self.popover.close()
            return nil
        }

        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: mouseEvents) {
            [weak self] _ in
            Task { @MainActor in
                self?.closePopoverIfUnpinned()
            }
        }

        workspaceActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let activatedApp = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication
            guard activatedApp?.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
            Task { @MainActor in
                self?.closePopoverIfUnpinned()
            }
        }

        workspaceWakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.model.systemDidWake()
            }
        }
    }

    private func removePopoverDismissalObservers() {
        if let localMouseMonitor {
            NSEvent.removeMonitor(localMouseMonitor)
            self.localMouseMonitor = nil
        }
        if let globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
            self.globalMouseMonitor = nil
        }
        if let localKeyMonitor {
            NSEvent.removeMonitor(localKeyMonitor)
            self.localKeyMonitor = nil
        }
        if let workspaceActivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceActivationObserver)
            self.workspaceActivationObserver = nil
        }
        if let workspaceWakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceWakeObserver)
            self.workspaceWakeObserver = nil
        }
    }

    private func closePopoverIfUnpinned() {
        guard popover.isShown,
              !model.isPinned,
              Date() >= ignoreDismissalUntil else { return }
        popover.close()
    }

    private func eventBelongsToPopover(_ event: NSEvent) -> Bool {
        guard let eventWindow = event.window,
              let popoverWindow = popover.contentViewController?.view.window else {
            return false
        }
        if eventWindow === popoverWindow { return true }
        if eventWindow.sheetParent === popoverWindow { return true }
        if popoverWindow.attachedSheet === eventWindow { return true }

        var parent = eventWindow.parent
        while let current = parent {
            if current === popoverWindow { return true }
            parent = current.parent
        }
        return false
    }

    private func updatePopoverSize() {
        let estimatedHeight = QuodexPopoverSizing.preferredHeight(
            accounts: model.accounts,
            refreshStates: model.refreshStates,
            isLoading: model.isLoadingAccounts,
            hasLoadError: model.loadError != nil,
            loginPresented: model.loginPresented
        )
        let requestedHeight = estimatedHeight
        let screenHeight = (statusItem?.button?.window?.screen ?? NSScreen.main)?.visibleFrame.height
            ?? (QuodexLayout.maximumHeight + 48)
        let screenLimit = max(QuodexLayout.minimumHeight, screenHeight - 48)
        let height = min(QuodexLayout.maximumHeight, screenLimit, max(QuodexLayout.minimumHeight, ceil(requestedHeight)))
        let size = NSSize(width: QuodexLayout.width, height: height)
        guard popover.contentSize != size else { return }
        popover.contentSize = size
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }
}
