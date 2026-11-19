import Foundation
import Testing
@testable import MatchDownloader

@Suite struct SettingsTests {
    @Test func parallelIsOnlyPassedWhenSetInRange() {
        let defaults = UserDefaults(suiteName: "SettingsTests.\(UUID().uuidString)")!
        #expect(EngineSettings.parallel(defaults) == nil)
        defaults.set(3, forKey: EngineSettings.parallelKey)
        #expect(EngineSettings.parallel(defaults) == 3)
        defaults.set(9, forKey: EngineSettings.parallelKey)
        #expect(EngineSettings.parallel(defaults) == nil)
    }
    @Test func catalogueRefreshesOnceADay() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(CatalogueRefresh.isStale(0, now: now))
        #expect(!CatalogueRefresh.isStale(now.timeIntervalSince1970 - 3600, now: now))
        #expect(CatalogueRefresh.isStale(now.timeIntervalSince1970 - 25 * 3600, now: now))
    }
}
