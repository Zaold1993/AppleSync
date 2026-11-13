import Testing
import Foundation
@testable import AppleSyncCore

private final class MutableTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var currentDate: Date

    init(_ initial: Date) { self.currentDate = initial }

    func set(_ next: Date) {
        lock.withLock { currentDate = next }
    }

    func advance(days: Double) {
        lock.withLock { currentDate = currentDate.addingTimeInterval(days * 86_400) }
    }

    func now() -> Date {
        lock.withLock { currentDate }
    }
}

@Suite("Step D Coordinator & State Machine Tests")
struct CoordinatorTests {
    private func makeCoordinatorEnv(initialDate: Date = Date(timeIntervalSince1970: 1_760_000_000)) -> (
        tempRoot: URL,
        paths: AppleSyncPaths,
        store: SyncStateStore,
        coreDevice: MockCoreDeviceService,
        signing: MockSigningService,
        backupManager: BackupAndSwapManager,
        notifier: RecordingNotificationDeliverer,
        clock: MutableTestClock,
        coordinator: DeviceOperationCoordinator
    ) {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("applesync-coord-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        let paths = AppleSyncPaths(rootURL: tempRoot)
        let store = SyncStateStore(paths: paths)
        let clock = MutableTestClock(initialDate)
        let nowProvider: @Sendable () -> Date = { clock.now() }

        let coreDevice = MockCoreDeviceService()
        let signing = MockSigningService(paths: paths, clock: nowProvider)
        let backupManager = BackupAndSwapManager(
            paths: paths,
            store: store,
            coreDevice: coreDevice,
            signingEngine: signing
        )
        let notifier = RecordingNotificationDeliverer()
        let coordinator = DeviceOperationCoordinator(
            paths: paths,
            store: store,
            coreDevice: coreDevice,
            signingEngine: signing,
            backupManager: backupManager,
            notifier: notifier,
            clock: nowProvider
        )
        return (tempRoot, paths, store, coreDevice, signing, backupManager, notifier, clock, coordinator)
    }

    private func onlineUnlockedDevice(udid: String = "UDID-IPHONE-1", connected: Bool = true) -> DiscoveredDevice {
        DiscoveredDevice(
            coreDeviceIdentifier: "CORE-\(udid)",
            udid: udid,
            marketingName: "Test iPhone",
            platform: "iOS",
            reality: "physical",
            pairingState: "paired",
            transportType: "localNetwork",
            connectionState: connected ? "connected" : "disconnected"
        )
    }

    @Test("Multi-account 3-slot limit, frozen registration, and Ad-Hoc fast-path slot exemption")
    func multiAccountSlotsAndAdHocExemption() async throws {
        let env = makeCoordinatorEnv()
        defer { try? FileManager.default.removeItem(at: env.tempRoot) }

        await env.coreDevice.setDevices([onlineUnlockedDevice()])
        await env.coreDevice.setLockState(LockStateInfo(deviceIdentifier: "CORE-UDID-IPHONE-1", passcodeRequired: false, unlockedSinceBoot: true))

        let r1 = try await env.coordinator.registerXcodeApp(
            projectOrWorkspacePath: "/tmp/App1.xcodeproj",
            scheme: "App1",
            teamID: "TEAM_ACCOUNT_A",
            targetDeviceUDID: "UDID-IPHONE-1"
        )
        let r2 = try await env.coordinator.registerIPAApp(
            ipaPath: "/tmp/App2.ipa",
            teamID: "TEAM_ACCOUNT_B",
            targetDeviceUDID: "UDID-IPHONE-1"
        )
        let r3 = try await env.coordinator.registerIPAApp(
            ipaPath: "/tmp/App3.ipa",
            teamID: "TEAM_ACCOUNT_A",
            targetDeviceUDID: "UDID-IPHONE-1"
        )
        #expect(r1.teamID == "TEAM_ACCOUNT_A")
        #expect(r2.teamID == "TEAM_ACCOUNT_B")
        #expect(r3.state == .active)

        let summary = try await env.coordinator.activeSlotSummary(forDeviceUDID: "UDID-IPHONE-1")
        #expect(summary.activeCount == 3)
        #expect(summary.remainingSlots == 0)

        // 4th active free app hits 3-slot device limit
        await #expect(throws: AppleSyncError.self) {
            _ = try await env.coordinator.registerIPAApp(
                ipaPath: "/tmp/App4.ipa",
                teamID: "TEAM_ACCOUNT_B",
                targetDeviceUDID: "UDID-IPHONE-1",
                installImmediately: true
            )
        }

        // 4th app registered as Frozen skips slot limit cleanly
        let r4Frozen = try await env.coordinator.registerIPAApp(
            ipaPath: "/tmp/App4.ipa",
            teamID: "TEAM_ACCOUNT_B",
            targetDeviceUDID: "UDID-IPHONE-1",
            installImmediately: false
        )
        #expect(r4Frozen.state == .frozen)

        // Friend's Ad-Hoc UDID-provisioned IPA uses fast-path and does NOT count against 3-slot limit!
        await env.signing.setInspectResults(ipa: IPAInspectionReport(
            ipaPath: "/tmp/FriendAdHoc.ipa",
            bundleIdentifier: "com.friend.AdHocBeta",
            displayName: "AdHocBeta",
            executableName: "AdHocBeta",
            marketingVersion: "1.0",
            buildVersion: "10",
            isFairPlayEncrypted: false,
            supportsArm64iOS: true,
            nestedExtensions: [],
            embeddedProfileExpiration: env.clock.now().addingTimeInterval(250 * 86_400),
            embeddedProfileProvisionedUDIDs: ["UDID-IPHONE-1"],
            canInstallUntouchedForTargetDevice: true
        ))
        let r5AdHoc = try await env.coordinator.registerIPAApp(
            ipaPath: "/tmp/FriendAdHoc.ipa",
            teamID: "TEAM_ACCOUNT_A",
            targetDeviceUDID: "UDID-IPHONE-1",
            preferOriginalAdHocIfValid: true,
            installImmediately: true
        )
        #expect(r5AdHoc.state == .activeAdHoc)
        #expect(r5AdHoc.effectiveBundleID == "com.friend.AdHocBeta")

        let summaryAfterAdHoc = try await env.coordinator.activeSlotSummary(forDeviceUDID: "UDID-IPHONE-1")
        #expect(summaryAfterAdHoc.activeCount == 3)
        #expect(summaryAfterAdHoc.adHocApps.count == 1)
        #expect(summaryAfterAdHoc.frozenApps.count == 1)
    }

    @Test("Days 0-7 lifecycle: Day 4 offline staging (no Xcode compile), Day 5 Wi-Fi push, Day 6 urgent alert dedup, Day 7 expiry notice")
    func backgroundSyncTimelineAndDeduplication() async throws {
        let env = makeCoordinatorEnv()
        defer { try? FileManager.default.removeItem(at: env.tempRoot) }

        await env.coreDevice.setDevices([onlineUnlockedDevice(connected: true)])
        await env.coreDevice.setLockState(LockStateInfo(deviceIdentifier: "CORE-UDID-IPHONE-1", passcodeRequired: false, unlockedSinceBoot: true))

        let app = try await env.coordinator.registerXcodeApp(
            projectOrWorkspacePath: "/tmp/MyProject.xcodeproj",
            scheme: "MyProject",
            teamID: "TEAM123AAA",
            targetDeviceUDID: "UDID-IPHONE-1"
        )
        let countsAfterInstall = await env.signing.counts()
        #expect(countsAfterInstall == (1, 1))

        // Day 2: still within Days 0-3 window
        env.clock.advance(days: 2)
        let day2 = try await env.coordinator.runBackgroundSyncCycle()
        #expect(day2.outcomes.first?.action == .upToDate)
        #expect(await env.signing.counts() == (1, 1))

        // Day 4: iPhone is offline/disconnected -> stages freshly signed bundle offline on Mac WITHOUT touching Xcode project source
        await env.coreDevice.setDevices([onlineUnlockedDevice(connected: false)])
        env.clock.advance(days: 2) // Day 4 total
        let day4 = try await env.coordinator.runBackgroundSyncCycle()
        #expect(day4.outcomes.first?.action == .stagedOfflineOnly)
        #expect(day4.outcomes.first?.newState == .stagedOffline)
        #expect(await env.signing.counts() == (1, 2)) // No extra import/compile!
        #expect(try await env.coordinator.app(id: app.id)?.stagedSignedAppPath != nil)

        // Day 5: iPhone comes back on Wi-Fi, unlocks -> pushes already-staged bundle without re-staging!
        await env.coreDevice.setDevices([onlineUnlockedDevice(connected: true)])
        env.clock.advance(days: 1) // Day 5 total
        let day5 = try await env.coordinator.runBackgroundSyncCycle()
        #expect(day5.outcomes.first?.action == .syncedOverDevice)
        #expect(day5.outcomes.first?.newState == .active)
        #expect(await env.signing.counts() == (1, 2)) // Reused staged bundle directly!
        #expect(try await env.coordinator.app(id: app.id)?.stagedSignedAppPath == nil)

        // Advance +5.2 days from Day 5 sync (0.8 days / ~19h left before Day 4-minted profile expires on Day 11) -> triggers Urgent < 24h
        await env.coreDevice.setDevices([])
        await env.signing.setStageError(AppleSyncError.provisioningFailed("Apple ID session expired"))
        env.clock.advance(days: 5.2)

        let day6First = try await env.coordinator.runBackgroundSyncCycle()
        #expect(day6First.outcomes.first?.newState == .syncUrgent)
        let alertsAfterFirstDay6 = await env.notifier.alerts()
        // At least auth + day6 urgent (let's verify dedup on second Day 6 pass)
        let countAfterFirstDay6 = alertsAfterFirstDay6.count
        #expect(countAfterFirstDay6 >= 1)

        // Second poll 15 minutes later on Day 6 must NOT duplicate Day 6 / Auth notifications
        env.clock.advance(days: 0.01)
        let day6Second = try await env.coordinator.runBackgroundSyncCycle()
        #expect(day6Second.alertsEmitted.isEmpty)
        #expect(await env.notifier.alerts().count == countAfterFirstDay6)

        // Day 7+: expired on device -> transitions to .expiredOnDevice and emits .expiryWarning once
        env.clock.advance(days: 1.0)
        let day7 = try await env.coordinator.runBackgroundSyncCycle()
        #expect(day7.outcomes.first?.action == .expiredOnDevice)
        #expect(day7.outcomes.first?.newState == .expiredOnDevice)
        let allAlerts = await env.notifier.alerts()
        #expect(allAlerts.contains { $0.category == .expiryWarning && $0.severity == .critical })
    }

    @Test("Day 5 reachable locked iPhone delays push and emits deviceLockedWaiting prompt once")
    func lockedDevicePromptOnWiFi() async throws {
        let env = makeCoordinatorEnv()
        defer { try? FileManager.default.removeItem(at: env.tempRoot) }

        await env.coreDevice.setDevices([onlineUnlockedDevice(connected: true)])
        await env.coreDevice.setLockState(LockStateInfo(deviceIdentifier: "CORE-UDID-IPHONE-1", passcodeRequired: false, unlockedSinceBoot: true))

        _ = try await env.coordinator.registerIPAApp(
            ipaPath: "/tmp/LockedTest.ipa",
            teamID: "TEAM123AAA",
            targetDeviceUDID: "UDID-IPHONE-1"
        )

        // Lock device and advance to Day 5.1
        await env.coreDevice.setLockState(LockStateInfo(deviceIdentifier: "CORE-UDID-IPHONE-1", passcodeRequired: true, unlockedSinceBoot: true))
        env.clock.advance(days: 5.1)

        let cycle1 = try await env.coordinator.runBackgroundSyncCycle()
        #expect(cycle1.outcomes.first?.action == .skippedDeviceLocked)
        #expect(cycle1.outcomes.first?.newState == .stagedOffline)
        #expect(cycle1.alertsEmitted.contains { $0.category == .deviceLockedWaiting })

        // Subsequent poll while still locked does not spam notification
        let cycle2 = try await env.coordinator.runBackgroundSyncCycle()
        #expect(cycle2.alertsEmitted.isEmpty)
    }

    @Test("Manual rebuildXcodeSnapshot refreshes compiled binary while preserving effectiveBundleID and lastBackupID")
    func rebuildXcodeSnapshotPreservesIdentityAndBackup() async throws {
        let env = makeCoordinatorEnv()
        defer { try? FileManager.default.removeItem(at: env.tempRoot) }

        await env.coreDevice.setDevices([onlineUnlockedDevice(connected: true)])
        await env.coreDevice.setLockState(LockStateInfo(deviceIdentifier: "CORE-UDID-IPHONE-1", passcodeRequired: false, unlockedSinceBoot: true))

        let app = try await env.coordinator.registerXcodeApp(
            projectOrWorkspacePath: "/tmp/SnapApp.xcodeproj",
            scheme: "SnapApp",
            teamID: "TEAM123AAA",
            targetDeviceUDID: "UDID-IPHONE-1"
        )
        await env.coreDevice.setInstalledApps([
            InstalledDeviceApp(
                bundleIdentifier: app.effectiveBundleID,
                name: "SnapApp",
                version: "1.0",
                bundleVersion: "1",
                builtByDeveloper: true,
                containerAccessible: true,
                removable: true,
                url: nil
            )
        ])
        let backup = try await env.coordinator.createManualBackup(appID: app.id)

        env.clock.advance(days: 1)
        let rebuilt = try await env.coordinator.rebuildXcodeSnapshot(appID: app.id, reinstallIfActive: true)
        #expect(rebuilt.id == app.id)
        #expect(rebuilt.effectiveBundleID == app.effectiveBundleID)
        #expect(rebuilt.lastBackupID == backup.backupID)
        #expect(await env.signing.counts() == (2, 2))
    }

    @Test("Per-app auto-sync pause and global daemon stop persist across restarts and skip background cycles")
    func perAppPauseAndGlobalDaemonStop() async throws {
        let env = makeCoordinatorEnv()
        defer { try? FileManager.default.removeItem(at: env.tempRoot) }

        await env.coreDevice.setDevices([onlineUnlockedDevice(connected: true)])
        await env.coreDevice.setLockState(LockStateInfo(deviceIdentifier: "CORE-UDID-IPHONE-1", passcodeRequired: false, unlockedSinceBoot: true))

        let pausedApp = try await env.coordinator.registerIPAApp(
            ipaPath: "/tmp/AppPaused.ipa",
            teamID: "TEAM123AAA",
            targetDeviceUDID: "UDID-IPHONE-1",
            displayNameOverride: "PausedApp"
        )
        let activeApp = try await env.coordinator.registerIPAApp(
            ipaPath: "/tmp/AppActive.ipa",
            teamID: "TEAM123AAA",
            targetDeviceUDID: "UDID-IPHONE-1",
            displayNameOverride: "ActiveApp"
        )

        // Pause only AppPaused
        let updatedPaused = try await env.coordinator.setAppAutoSyncPaused(appID: pausedApp.id, paused: true)
        #expect(updatedPaused.autoSyncPaused == true)

        // Advance to Day 4.5 with device offline
        await env.coreDevice.setDevices([onlineUnlockedDevice(connected: false)])
        env.clock.advance(days: 4.5)
        let countsBefore = await env.signing.counts()
        let partialReport = try await env.coordinator.runBackgroundSyncCycle()

        let pausedOutcome = partialReport.outcomes.first { $0.appID == pausedApp.id }
        let activeOutcome = partialReport.outcomes.first { $0.appID == activeApp.id }
        #expect(pausedOutcome?.action == .skippedPaused)
        #expect(activeOutcome?.action == .stagedOfflineOnly)
        // Only activeApp should trigger offline stage (+1 stage call, NOT +2)
        let countsAfter = await env.signing.counts()
        #expect(countsAfter.stages == countsBefore.stages + 1)

        // Now stop the global sync daemon and verify fresh store reload persists stopped state
        try await env.coordinator.setGlobalAutoSyncPaused(true)
        let reloadedStore = SyncStateStore(paths: env.paths)
        let reloadedCoordinator = DeviceOperationCoordinator(
            paths: env.paths,
            store: reloadedStore,
            coreDevice: env.coreDevice,
            signingEngine: env.signing,
            backupManager: env.backupManager,
            notifier: env.notifier,
            clock: { env.clock.now() }
        )
        #expect(try await reloadedCoordinator.isGlobalAutoSyncPaused() == true)

        await env.coreDevice.clearCalls()
        env.clock.advance(days: 2.0) // Day 6.5
        let stoppedReport = try await reloadedCoordinator.runBackgroundSyncCycle()
        #expect(stoppedReport.wasStoppedGlobally == true)
        #expect(stoppedReport.outcomes.isEmpty)
        #expect(await env.coreDevice.recordedCalls().isEmpty)
        #expect(await env.notifier.alerts().isEmpty)

        // Resume pausedApp + global daemon and verify cycle resumes cleanly
        _ = try await reloadedCoordinator.setAppAutoSyncPaused(appID: pausedApp.id, paused: false)
        try await reloadedCoordinator.setGlobalAutoSyncPaused(false)
        let resumedReport = try await reloadedCoordinator.runBackgroundSyncCycle()
        #expect(resumedReport.wasStoppedGlobally == false)
        let pausedAfterResume = resumedReport.outcomes.first { $0.appID == pausedApp.id }
        #expect(pausedAfterResume != nil)
        #expect(pausedAfterResume?.action != .skippedPaused)
    }

    @Test("Backwards-compatible JSON decoding defaults missing pause flags to false")
    func backwardsCompatibleJSONDecoding() throws {
        let legacyJSON = """
        {
          "schemaVersion": 1,
          "apps": [
            {
              "id": "11111111-1111-1111-1111-111111111111",
              "displayName": "Legacy",
              "originalBundleID": "com.test.legacy",
              "effectiveBundleID": "com.applesync.team.abc",
              "teamID": "TEAM1",
              "targetDeviceUDID": "UDID-1",
              "source": {
                "externalIPA": {
                  "originalIPAPath": "/tmp/a.ipa",
                  "originalBundleID": "com.test.legacy",
                  "stripExtensions": true,
                  "useOriginalAdHocIfValid": false
                }
              },
              "state": "active",
              "cachedBaseAppPath": "/tmp/App.app"
            }
          ],
          "backups": [],
          "events": [],
          "notifiedThresholds": {}
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let state = try decoder.decode(SyncStoreState.self, from: Data(legacyJSON.utf8))
        #expect(state.autoSyncGlobalPaused == false)
        #expect(state.apps.count == 1)
        #expect(state.apps[0].autoSyncPaused == false)
    }
}
