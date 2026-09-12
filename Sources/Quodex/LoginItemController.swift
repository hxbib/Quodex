import AppKit
import Foundation
import ServiceManagement

@MainActor
final class LoginItemController {
    enum State: Equatable {
        case enabled
        case disabled
        case requiresApproval
        case unavailable
    }

    private static let preferenceKey = "Quodex.openAtLoginEnabled"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var state: State {
        guard DistributionProfile.permitsSystemIntegration else { return .unavailable }
        switch SMAppService.mainApp.status {
        case .enabled:
            return .enabled
        case .requiresApproval:
            return .requiresApproval
        case .notRegistered, .notFound:
            return .disabled
        @unknown default:
            return .unavailable
        }
    }

    func enableByDefaultIfNeeded() {
        guard DistributionProfile.permitsSystemIntegration else { return }
        if defaults.object(forKey: Self.preferenceKey) == nil {
            defaults.set(true, forKey: Self.preferenceKey)
        }
        guard defaults.bool(forKey: Self.preferenceKey), state == .disabled else { return }
        enable()
    }

    func toggle() {
        switch state {
        case .enabled:
            disable()
        case .requiresApproval:
            SMAppService.openSystemSettingsLoginItems()
        case .disabled:
            enable()
        case .unavailable:
            break
        }
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    private func enable() {
        defaults.set(true, forKey: Self.preferenceKey)
        do {
            try SMAppService.mainApp.register()
        } catch {}
    }

    private func disable() {
        defaults.set(false, forKey: Self.preferenceKey)
        do {
            try SMAppService.mainApp.unregister()
        } catch {}
    }
}
