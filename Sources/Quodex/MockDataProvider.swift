import Foundation

enum MockDataProvider {
    struct Fixture: Decodable {
        var accounts: [FixtureAccount]
    }

    struct FixtureAccount: Decodable {
        var id: String
        var email: String
        var plan: String
        var updatedMinutesAgo: Double
        var resetNotificationsEnabled: Bool
        var bankedResets: Int?
        var lanes: [FixtureLane]
    }

    struct FixtureLane: Decodable {
        var group: String
        var name: String
        var remainingPercent: Double
        var resetIntervalSeconds: TimeInterval?
        var windowSeconds: Int?
    }

    static func load(now: Date = Date()) throws -> [AccountRecord] {
        guard DistributionProfile.isMock,
              let url = Bundle.main.url(forResource: "QuodexMockData", withExtension: "json") else {
            throw QuodexError.invalidAccountStore("mock data is unavailable")
        }
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        return fixture.accounts.map { account in
            let fetchedAt = now.addingTimeInterval(-account.updatedMinutesAgo * 60)
            return AccountRecord(
                id: account.id,
                email: account.email,
                plan: account.plan,
                addedAt: now,
                lastSnapshot: UsageSnapshot(
                    lanes: account.lanes.map { lane in
                        UsageLane(
                            group: lane.group,
                            name: lane.name,
                            usedPercent: 100 - lane.remainingPercent,
                            resetAt: lane.resetIntervalSeconds.map(now.addingTimeInterval),
                            windowSeconds: lane.windowSeconds
                        )
                    },
                    bankedResets: account.bankedResets.map {
                        BankedResets(count: $0, earliestExpiry: nil)
                    },
                    fetchedAt: fetchedAt,
                    bankedResetCountConfirmed: account.bankedResets != nil
                ),
                resetNotificationsEnabled: account.resetNotificationsEnabled,
                lastKnownBankedResetCount: account.bankedResets
            )
        }
    }
}
