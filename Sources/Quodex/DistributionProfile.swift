import Foundation

enum DistributionProfile {
    static let publicBundleIdentifier = "com.quodex.Quodex"
    static let mockBundleIdentifier = "com.quodex.QuodexMock"

    static var bundleIdentifier: String {
        Bundle.main.bundleIdentifier ?? publicBundleIdentifier
    }

    static var isMock: Bool {
        bundleIdentifier == mockBundleIdentifier
    }

    static var keychainService: String {
        bundleIdentifier == mockBundleIdentifier
            ? "com.quodex.QuodexMock.oauth-tokens"
            : "com.quodex.Quodex.oauth-tokens"
    }

    static var applicationSupportDirectory: String {
        "Quodex"
    }

    static var permitsSystemIntegration: Bool {
        !isMock
    }
}
