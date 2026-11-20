import Foundation
import UserNotifications
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

@Suite struct NotificationSwitchTests {
    @Test func onByDefaultAndFollowsTheSwitch() {
        let defaults = UserDefaults(suiteName: "NotificationSwitchTests.\(UUID().uuidString)")!
        #expect(DownloadNotifications.enabled(defaults))
        defaults.set(false, forKey: DownloadNotifications.enabledKey)
        #expect(!DownloadNotifications.enabled(defaults))
    }
    @Test func onlyAllowedStatusesCountAsOn() {
        #expect(DownloadNotifications.allowed(.authorized))
        #expect(!DownloadNotifications.allowed(.denied))
        #expect(!DownloadNotifications.allowed(.notDetermined))
        #expect(!DownloadNotifications.allowed(nil))
    }
}

@Suite struct PollingTests {
    @Test func pollsQuicklyOnlyWhileDownloadingOrFailing() {
        #expect(LibraryStore.pollInterval(active: true, failing: false) == 2)
        #expect(LibraryStore.pollInterval(active: false, failing: true) == 2.5)
        #expect(LibraryStore.pollInterval(active: false, failing: false) == 15)
    }
}

@Suite struct LibraryPathTests {
    @Test func privateTmpMatchesShortenedPath() throws {
        let folder = URL(fileURLWithPath: "/private/tmp/match-downloader-path-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        // The engine reports the resolved /private path; the app's own URL may be the shortened /tmp form.
        #expect(BackendConfiguration.sameFolder(folder.path, folder.standardizedFileURL))
        #expect(BackendConfiguration.sameFolder(folder.path, URL(fileURLWithPath: "/tmp/" + folder.lastPathComponent)))
        #expect(!BackendConfiguration.sameFolder(folder.path, folder.appendingPathComponent("other")))
    }
}
