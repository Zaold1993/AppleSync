import Testing
import Foundation
@testable import AppleSyncCore

@Suite("Step C State Store & Backup/Swap Tests")
struct BackupAndSwapTests {
    private func makeTestEnvironment() throws -> (
        tempRoot: URL,
        paths: AppleSyncPaths,
        store: SyncStateStore,
        coreDevice: MockCoreDeviceService,
        signing: MockSigningService,
        backupManager: BackupAndSwapManager
    ) {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("applesync-backup-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        let paths = AppleSyncPaths(rootURL: tempRoot)
        let store = SyncStateStore(paths: paths, maxEventsCount: 25)
        let coreDevice = MockCoreDeviceService()
        let signing = MockSigningService(paths: paths)
        let backupManager = BackupAndSwapManager(
            paths: paths,
            store: store,
            coreDevice: coreDevice,
            signingEngine: signing
        )
        return (tempRoot, paths, store, coreDevice, signing, backupManager)
    }

    private func makeSampleApp(
        id: UUID = UUID(),
        name: String = "AppA",
        bundleID: String = "com.applesync.team.appa",
        state: AppLifecycleState = .active,
        udid: String = "UDID-1",
        paths: AppleSyncPaths
    ) throws -> ManagedAppRecord {
        let baseAppURL = paths.baseAppDirectory(for: id).appendingPathComponent("\(name).app", isDirectory: true)
        try FileManager.default.createDirectory(at: baseAppURL, withIntermediateDirectories: true)
        try Data("base".utf8).write(to: baseAppURL.appendingPathComponent("Info.plist"))
        return ManagedAppRecord(
            id: id,
            displayName: name,
            originalBundleID: "com.orig.\(name)",
            effectiveBundleID: bundleID,
            teamID: "TEAM123AAA",
            targetDeviceUDID: udid,
            source: .externalIPA(
                originalIPAPath: "/tmp/\(name).ipa",
                originalBundleID: "com.orig.\(name)",
                stripExtensions: true,
                useOriginalAdHocIfValid: false
            ),
            state: state,
            cachedBaseAppPath: baseAppURL.path,
            lastInstalledAt: Date(),
            profileExpiresAt: Date().addingTimeInterval(7 * 86_400)
        )
    }

    @Test("SyncStateStore enforces active slot counts, atomic persistence, and backup lastBackupID fallback")
    func stateStoreSlotsAndBackups() async throws {
        let env = try makeTestEnvironment()
        defer { try? FileManager.default.removeItem(at: env.tempRoot) }

        let a1 = try makeSampleApp(name: "A1", bundleID: "com.applesync.a1", state: .active, paths: env.paths)
        let a2 = try makeSampleApp(name: "A2", bundleID: "com.applesync.a2", state: .stagedOffline, paths: env.paths)
        let a3 = try makeSampleApp(name: "A3", bundleID: "com.applesync.a3", state: .syncUrgent, paths: env.paths)
        let a4Frozen = try makeSampleApp(name: "A4", bundleID: "com.applesync.a4", state: .frozen, paths: env.paths)
        let a5AdHoc = try makeSampleApp(name: "A5", bundleID: "com.applesync.a5", state: .activeAdHoc, paths: env.paths)

        for app in [a1, a2, a3, a4Frozen, a5AdHoc] {
            try await env.store.upsertApp(app)
        }

        let countAll = try await env.store.activeSlotCount(forDeviceUDID: "UDID-1")
        #expect(countAll == 3)
        let countExcludingA1 = try await env.store.activeSlotCount(forDeviceUDID: "UDID-1", excludingAppID: a1.id)
        #expect(countExcludingA1 == 2)

        let b1 = BackupManifest(
            backupID: UUID(),
            appID: a1.id,
            effectiveBundleID: a1.effectiveBundleID,
            deviceUDID: "UDID-1",
            createdAt: Date().addingTimeInterval(-3600),
            appVersion: "1.0",
            trigger: .manual,
            sizeBytes: 100,
            fileCount: 2,
            sha256Digest: "d1",
            archiveRelativePath: "p1"
        )
        let b2 = BackupManifest(
            backupID: UUID(),
            appID: a1.id,
            effectiveBundleID: a1.effectiveBundleID,
            deviceUDID: "UDID-1",
            createdAt: Date(),
            appVersion: "1.0",
            trigger: .preFreeze,
            sizeBytes: 120,
            fileCount: 3,
            sha256Digest: "d2",
            archiveRelativePath: "p2"
        )
        try await env.store.addBackup(b1)
        try await env.store.addBackup(b2)
        #expect(try await env.store.app(id: a1.id)?.lastBackupID == b2.backupID)

        try await env.store.removeBackup(id: b2.backupID)
        #expect(try await env.store.app(id: a1.id)?.lastBackupID == b1.backupID)
    }

    @Test("Backup creation quiesces app, strips transient folders, and passes SHA-256 disk verification")
    func createAndVerifyBackup() async throws {
        let env = try makeTestEnvironment()
        defer { try? FileManager.default.removeItem(at: env.tempRoot) }

        let app = try makeSampleApp(name: "Notes", bundleID: "com.applesync.team.notes", paths: env.paths)
        try await env.store.upsertApp(app)
        await env.coreDevice.setInstalledApps([
            InstalledDeviceApp(
                bundleIdentifier: app.effectiveBundleID,
                name: "Notes",
                version: "1.0",
                bundleVersion: "1",
                builtByDeveloper: true,
                containerAccessible: true,
                removable: true,
                url: "file:///private/var/containers/Bundle/Application/UUID/Notes.app/"
            )
        ])
        await env.coreDevice.setRunningProcesses([
            RunningDeviceProcess(processIdentifier: 777, executable: "/private/var/containers/Bundle/Application/UUID/Notes.app/Notes")
        ])

        let manifest = try await env.backupManager.createBackup(
            appID: app.id,
            deviceIdentifier: "CORE-1",
            trigger: .manual
        )
        #expect(manifest.fileCount == 3)
        #expect(manifest.sha256Digest.count == 64)

        let calls = await env.coreDevice.recordedCalls()
        #expect(calls.contains(.terminateProcess("CORE-1", 777, false)))

        let backupDir = env.paths.backupDirectory(for: app.effectiveBundleID, backupID: manifest.backupID)
        #expect(FileManager.default.fileExists(atPath: backupDir.appendingPathComponent(".verified").path))
        #expect(!FileManager.default.fileExists(atPath: backupDir.appendingPathComponent("Container/Library/SplashBoard").path))
        #expect(!FileManager.default.fileExists(atPath: backupDir.appendingPathComponent("Container/tmp").path))

        let verified = try BackupAndSwapManager.verifyBackupOnDisk(at: backupDir, expectedBackupID: manifest.backupID)
        #expect(verified.backupID == manifest.backupID)
    }

    @Test("Zero Data Loss: freezeApp aborts WITHOUT uninstalling if backup creation fails")
    func freezeAbortsOnBackupFailure() async throws {
        let env = try makeTestEnvironment()
        defer { try? FileManager.default.removeItem(at: env.tempRoot) }

        let app = try makeSampleApp(name: "Critical", bundleID: "com.applesync.team.critical", paths: env.paths)
        try await env.store.upsertApp(app)
        await env.coreDevice.setInstalledApps([
            InstalledDeviceApp(
                bundleIdentifier: app.effectiveBundleID,
                name: "Critical",
                version: "1.0",
                bundleVersion: "1",
                builtByDeveloper: true,
                containerAccessible: true,
                removable: true,
                url: nil
            )
        ])
        await env.coreDevice.setErrors(copyFrom: AppleSyncError.backupVerificationFailed("Wi-Fi dropped"))

        await #expect(throws: Error.self) {
            _ = try await env.backupManager.freezeApp(appID: app.id, deviceIdentifier: "CORE-1", createBackupFirst: true)
        }

        let calls = await env.coreDevice.recordedCalls()
        let didUninstall = calls.contains {
            if case .uninstallApp = $0 { return true }
            return false
        }
        #expect(didUninstall == false)
        #expect(try await env.store.app(id: app.id)?.state == .active)
    }

    @Test("Restore rejects SHA-256 tampered backup BEFORE calling devicectl copyTo")
    func restoreRejectsTamperedBackup() async throws {
        let env = try makeTestEnvironment()
        defer { try? FileManager.default.removeItem(at: env.tempRoot) }

        let app = try makeSampleApp(name: "Secure", bundleID: "com.applesync.team.secure", paths: env.paths)
        try await env.store.upsertApp(app)
        await env.coreDevice.setInstalledApps([
            InstalledDeviceApp(
                bundleIdentifier: app.effectiveBundleID,
                name: "Secure",
                version: "1.0",
                bundleVersion: "1",
                builtByDeveloper: true,
                containerAccessible: true,
                removable: true,
                url: nil
            )
        ])

        let manifest = try await env.backupManager.createBackup(appID: app.id, deviceIdentifier: "CORE-1", trigger: .manual)
        let backupDir = env.paths.backupDirectory(for: app.effectiveBundleID, backupID: manifest.backupID)
        let targetFile = backupDir.appendingPathComponent("Container/Documents/user.json")
        try Data("{\"score\":999}".utf8).write(to: targetFile)

        await env.coreDevice.clearCalls()
        await #expect(throws: AppleSyncError.self) {
            try await env.backupManager.restoreBackup(
                appID: app.id,
                backupID: manifest.backupID,
                deviceIdentifier: "CORE-1",
                isFreshInstall: false
            )
        }

        let calls = await env.coreDevice.recordedCalls()
        let didCopyTo = calls.contains {
            if case .copyToContainer = $0 { return true }
            return false
        }
        #expect(didCopyTo == false)
    }

    @Test("Restore plan never sets removeExistingContent=true and avoids Documents/Documents nesting")
    func restorePlanAvoidsDestructiveOverwriteAndNesting() async throws {
        let env = try makeTestEnvironment()
        defer { try? FileManager.default.removeItem(at: env.tempRoot) }

        let app = try makeSampleApp(name: "Planner", bundleID: "com.applesync.team.planner", paths: env.paths)
        try await env.store.upsertApp(app)
        await env.coreDevice.setInstalledApps([
            InstalledDeviceApp(
                bundleIdentifier: app.effectiveBundleID,
                name: "Planner",
                version: "1.0",
                bundleVersion: "1",
                builtByDeveloper: true,
                containerAccessible: true,
                removable: true,
                url: nil
            )
        ])

        let manifest = try await env.backupManager.createBackup(appID: app.id, deviceIdentifier: "CORE-1", trigger: .manual)
        await env.coreDevice.clearCalls()
        try await env.backupManager.restoreBackup(
            appID: app.id,
            backupID: manifest.backupID,
            deviceIdentifier: "CORE-1",
            isFreshInstall: true
        )

        let copyToCalls = await env.coreDevice.recordedCalls().compactMap { call -> (String, String, Bool)? in
            if case .copyToContainer(_, _, let localSrc, let remoteDest, let wipe) = call {
                return (URL(fileURLWithPath: localSrc).lastPathComponent, remoteDest, wipe)
            }
            return nil
        }

        #expect(copyToCalls.count == 3)
        // Directories map to their parent topFolder ("Documents" or "Library"), files map to explicit file subpath.
        #expect(copyToCalls.contains { $0.0 == "Notes" && $0.1 == "Documents" && $0.2 == false })
        #expect(copyToCalls.contains { $0.0 == "user.json" && $0.1 == "Documents/user.json" && $0.2 == false })
        #expect(copyToCalls.contains { $0.0 == "Preferences" && $0.1 == "Library" && $0.2 == false })
        #expect(copyToCalls.allSatisfy { $0.2 == false })
    }

    @Test("Two-phase swap persists Commit 1 frozen state if Phase 5 install fails, and deleteBackup removes disk archive")
    func swapCommitAndDeleteBackup() async throws {
        let env = try makeTestEnvironment()
        defer { try? FileManager.default.removeItem(at: env.tempRoot) }

        let appA = try makeSampleApp(name: "AppA", bundleID: "com.applesync.team.appa", state: .active, paths: env.paths)
        let appB = try makeSampleApp(name: "AppB", bundleID: "com.applesync.team.appb", state: .frozen, paths: env.paths)
        try await env.store.upsertApp(appA)
        try await env.store.upsertApp(appB)

        await env.coreDevice.setInstalledApps([
            InstalledDeviceApp(
                bundleIdentifier: appA.effectiveBundleID,
                name: "AppA",
                version: "1.0",
                bundleVersion: "1",
                builtByDeveloper: true,
                containerAccessible: true,
                removable: true,
                url: nil
            )
        ])
        await env.coreDevice.setErrors(install: AppleSyncError.deviceLocked(udid: "UDID-1"))

        await #expect(throws: AppleSyncError.self) {
            _ = try await env.backupManager.swapApps(
                freezeAppID: appA.id,
                thawAppID: appB.id,
                deviceIdentifier: "CORE-1",
                restoreBackupIDForThaw: nil
            )
        }

        let frozenA = try await env.store.app(id: appA.id)
        let stillFrozenB = try await env.store.app(id: appB.id)
        #expect(frozenA?.state == .frozen)
        let backupID = try #require(frozenA?.lastBackupID)
        #expect(stillFrozenB?.state == .frozen)

        let backupDir = env.paths.backupDirectory(for: appA.effectiveBundleID, backupID: backupID)
        #expect(FileManager.default.fileExists(atPath: backupDir.path))

        try await env.backupManager.deleteBackup(backupID: backupID)
        #expect(!FileManager.default.fileExists(atPath: backupDir.path))
        #expect(try await env.store.app(id: appA.id)?.lastBackupID == nil)
        #expect(try await env.store.backup(id: backupID) == nil)
    }

    @Test("Clean restore on installed app stages first, uninstalls stale container, reinstalls, and aborts safely if signing fails")
    func cleanRestoreReinstallsContainerSafely() async throws {
        let env = try makeTestEnvironment()
        defer { try? FileManager.default.removeItem(at: env.tempRoot) }

        let app = try makeSampleApp(name: "CleanRestore", bundleID: "com.applesync.team.clean", paths: env.paths)
        try await env.store.upsertApp(app)
        await env.coreDevice.setInstalledApps([
            InstalledDeviceApp(
                bundleIdentifier: app.effectiveBundleID,
                name: "CleanRestore",
                version: "1.0",
                bundleVersion: "1",
                builtByDeveloper: true,
                containerAccessible: true,
                removable: true,
                url: nil
            )
        ])

        let manifest = try await env.backupManager.createBackup(appID: app.id, deviceIdentifier: "CORE-1", trigger: .manual)

        // 1) If staging fails, device must NEVER be uninstalled or written to.
        await env.signing.setStageError(AppleSyncError.provisioningFailed("Offline"))
        await env.coreDevice.clearCalls()
        await #expect(throws: AppleSyncError.self) {
            try await env.backupManager.restoreBackup(
                appID: app.id,
                backupID: manifest.backupID,
                deviceIdentifier: "CORE-1",
                isFreshInstall: false
            )
        }
        let failedCalls = await env.coreDevice.recordedCalls()
        #expect(!failedCalls.contains { if case .uninstallApp = $0 { return true }; return false })
        #expect(!failedCalls.contains { if case .copyToContainer = $0 { return true }; return false })

        // 2) Once staging succeeds, clean restore uninstalls, reinstalls, and copies container cleanly.
        await env.signing.setStageError(nil)
        await env.coreDevice.clearCalls()
        try await env.backupManager.restoreBackup(
            appID: app.id,
            backupID: manifest.backupID,
            deviceIdentifier: "CORE-1",
            isFreshInstall: false
        )

        let calls = await env.coreDevice.recordedCalls()
        let uninstallIdx = calls.firstIndex { if case .uninstallApp("CORE-1", app.effectiveBundleID) = $0 { return true }; return false }
        let installIdx = calls.firstIndex { if case .installApp("CORE-1", _) = $0 { return true }; return false }
        let firstCopyIdx = calls.firstIndex { if case .copyToContainer = $0 { return true }; return false }
        #expect(uninstallIdx != nil)
        #expect(installIdx != nil)
        #expect(firstCopyIdx != nil)
        if let u = uninstallIdx, let i = installIdx, let c = firstCopyIdx {
            #expect(u < i && i < c)
        }
    }
}
