import Foundation
import CryptoKit

public protocol BackupServicing: Sendable {
    func createBackup(
        appID: UUID,
        deviceIdentifier: String,
        trigger: BackupTrigger
    ) async throws -> BackupManifest

    func restoreBackup(
        appID: UUID,
        backupID: UUID,
        deviceIdentifier: String,
        isFreshInstall: Bool
    ) async throws

    func deleteBackup(backupID: UUID) async throws

    func freezeApp(
        appID: UUID,
        deviceIdentifier: String,
        createBackupFirst: Bool
    ) async throws -> BackupManifest?

    func thawApp(
        appID: UUID,
        deviceIdentifier: String,
        restoreBackupID: UUID?
    ) async throws -> ManagedAppRecord

    func swapApps(
        freezeAppID: UUID,
        thawAppID: UUID,
        deviceIdentifier: String,
        restoreBackupIDForThaw: UUID?
    ) async throws -> (frozenBackup: BackupManifest, thawedApp: ManagedAppRecord)
}

public actor BackupAndSwapManager: BackupServicing {
    public let paths: AppleSyncPaths
    public let store: SyncStateStore
    public let coreDevice: any CoreDeviceServicing
    public let signingEngine: any SigningServicing

    public init(
        paths: AppleSyncPaths = AppleSyncPaths(),
        store: SyncStateStore,
        coreDevice: any CoreDeviceServicing,
        signingEngine: any SigningServicing
    ) {
        self.paths = paths
        self.store = store
        self.coreDevice = coreDevice
        self.signingEngine = signingEngine
    }

    // MARK: - 1. Create Verified Container Backup

    public func createBackup(
        appID: UUID,
        deviceIdentifier: String,
        trigger: BackupTrigger
    ) async throws -> BackupManifest {
        try paths.ensureDirectoriesExist()
        guard let app = try await store.app(id: appID) else {
            throw AppleSyncError.appNotFound(appID)
        }

        let installedApps = try await coreDevice.installedApps(deviceIdentifier: deviceIdentifier)
        guard let installedApp = installedApps.first(where: { $0.bundleIdentifier == app.effectiveBundleID }) else {
            throw AppleSyncError.backupVerificationFailed(
                "App '\(app.displayName)' (\(app.effectiveBundleID)) is not installed on device '\(deviceIdentifier)'."
            )
        }

        guard installedApp.containerAccessible else {
            throw AppleSyncError.backupVerificationFailed(
                "Data container for '\(app.displayName)' (\(app.effectiveBundleID)) is not accessible."
            )
        }

        try await quiesceAppProcessIfRunning(
            deviceIdentifier: deviceIdentifier,
            installedApp: installedApp,
            fallbackExecutableName: app.displayName
        )

        let backupID = UUID()
        let finalBackupDir = paths.backupDirectory(for: app.effectiveBundleID, backupID: backupID)
        let bundleBackupsParent = finalBackupDir.deletingLastPathComponent()
        let stagingDir = bundleBackupsParent.appendingPathComponent(".staging_\(backupID.uuidString)", isDirectory: true)
        let stagedContainerDir = stagingDir.appendingPathComponent("Container", isDirectory: true)

        let fm = FileManager.default
        try fm.createDirectory(at: bundleBackupsParent, withIntermediateDirectories: true)
        if fm.fileExists(atPath: stagingDir.path) {
            try? fm.removeItem(at: stagingDir)
        }
        try fm.createDirectory(at: stagedContainerDir, withIntermediateDirectories: true)

        do {
            try await coreDevice.copyFromContainer(
                deviceIdentifier: deviceIdentifier,
                bundleIdentifier: app.effectiveBundleID,
                remoteSourceSubpath: ".",
                localDestinationURL: stagedContainerDir
            )

            Self.normalizeAndSanitizeStagedContainer(at: stagedContainerDir)

            let docsURL = stagedContainerDir.appendingPathComponent("Documents", isDirectory: true)
            let libURL = stagedContainerDir.appendingPathComponent("Library", isDirectory: true)
            guard fm.fileExists(atPath: docsURL.path) || fm.fileExists(atPath: libURL.path) else {
                throw AppleSyncError.backupVerificationFailed(
                    "Pulled container for '\(app.effectiveBundleID)' is missing both Documents/ and Library/ directories."
                )
            }

            let digestResult = try Self.computeDirectoryTreeDigest(at: stagedContainerDir)
            let manifest = BackupManifest(
                backupID: backupID,
                appID: app.id,
                effectiveBundleID: app.effectiveBundleID,
                deviceUDID: app.targetDeviceUDID,
                createdAt: Date(),
                appVersion: app.appVersion,
                trigger: trigger,
                sizeBytes: digestResult.sizeBytes,
                fileCount: digestResult.fileCount,
                sha256Digest: digestResult.sha256Digest,
                archiveRelativePath: "\(app.effectiveBundleID)/\(backupID.uuidString)"
            )

            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let manifestData = try encoder.encode(manifest)

            let manifestURL = stagingDir.appendingPathComponent("manifest.json", isDirectory: false)
            try manifestData.write(to: manifestURL, options: [.atomic])

            let verifiedURL = stagingDir.appendingPathComponent(".verified", isDirectory: false)
            try Data(manifest.sha256Digest.utf8).write(to: verifiedURL, options: [.atomic])

            if fm.fileExists(atPath: finalBackupDir.path) {
                try fm.removeItem(at: finalBackupDir)
            }
            try fm.moveItem(at: stagingDir, to: finalBackupDir)

            try await store.addBackup(manifest, updateAppLastBackup: true)
            try await store.recordEvent(
                appID: app.id,
                kind: "backup.created",
                message: "Created \(trigger.rawValue) backup \(backupID.uuidString) (\(manifest.fileCount) files, \(manifest.sizeBytes) bytes).",
                succeeded: true
            )

            return manifest
        } catch {
            try? fm.removeItem(at: stagingDir)
            throw error
        }
    }

    // MARK: - 2. Restore Verified Container Backup

    public func restoreBackup(
        appID: UUID,
        backupID: UUID,
        deviceIdentifier: String,
        isFreshInstall: Bool
    ) async throws {
        guard var app = try await store.app(id: appID) else {
            throw AppleSyncError.appNotFound(appID)
        }

        let storedManifest = try await store.backup(id: backupID)
        let effectiveBundleID = storedManifest?.effectiveBundleID ?? app.effectiveBundleID
        let backupDir = paths.backupDirectory(for: effectiveBundleID, backupID: backupID)

        let manifest = try Self.verifyBackupOnDisk(at: backupDir, expectedBackupID: backupID)
        let containerDir = backupDir.appendingPathComponent("Container", isDirectory: true)

        let installedApps = try await coreDevice.installedApps(deviceIdentifier: deviceIdentifier)
        let installedApp = installedApps.first(where: { $0.bundleIdentifier == app.effectiveBundleID })
        var didCleanReinstall = false

        if let installedApp, !isFreshInstall {
            // Stage & sign BEFORE uninstalling so a signing failure leaves the device untouched.
            let signed = try await signingEngine.stageAndSignApp(for: app)

            try await quiesceAppProcessIfRunning(
                deviceIdentifier: deviceIdentifier,
                installedApp: installedApp,
                fallbackExecutableName: app.displayName
            )

            // Reinstalling guarantees an empty sandbox container so files created after the backup do not linger.
            try await coreDevice.uninstallApp(
                deviceIdentifier: deviceIdentifier,
                bundleIdentifier: app.effectiveBundleID
            )
            try await coreDevice.installApp(
                deviceIdentifier: deviceIdentifier,
                appBundleURL: URL(fileURLWithPath: signed.stagedAppPath)
            )
            try? FileManager.default.removeItem(atPath: signed.stagedAppPath)

            let now = Date()
            app.effectiveBundleID = signed.effectiveBundleID
            app.state = signed.usedUntouchedEmbeddedProfile ? .activeAdHoc : .active
            app.lastInstalledAt = now
            app.profileExpiresAt = signed.profileExpirationDate
            app.stagedSignedAppPath = nil
            app.stagedProfileExpiresAt = nil
            app.lastSyncAttemptAt = now
            app.lastSyncError = nil
            try await store.upsertApp(app)
            didCleanReinstall = true
        } else if let installedApp {
            try await quiesceAppProcessIfRunning(
                deviceIdentifier: deviceIdentifier,
                installedApp: installedApp,
                fallbackExecutableName: app.displayName
            )
        }

        // CRITICAL VERIFIED DEVICECTL SEMANTICS:
        // 1. NEVER pass `--remove-existing-content true` across multiple subfolder copies because
        //    `devicectl device copy to --remove-existing-content true` can wipe the entire appDataContainer.
        // 2. `devicectl device copy to` copies a local directory *as a subdirectory* inside `--destination`.
        //    Therefore, for each immediate child of `Documents/` and `Library/`:
        //    - If the child is a directory (e.g. `Documents/Sub` or `Library/Preferences`), pass
        //      `remoteDestinationSubpath: "Documents"` (or `"Library"`), which places it at `Documents/Sub`
        //      without `Documents/Documents` nesting.
        //    - If the child is a regular file (e.g. `Documents/data.sqlite`), pass
        //      `remoteDestinationSubpath: "Documents/data.sqlite"`, which writes the file directly.
        let restorePlan = try Self.buildContainerRestorePlan(from: containerDir)
        for item in restorePlan {
            try await coreDevice.copyToContainer(
                deviceIdentifier: deviceIdentifier,
                bundleIdentifier: app.effectiveBundleID,
                localSourceURL: item.localSourceURL,
                remoteDestinationSubpath: item.remoteDestinationSubpath,
                removeExistingContent: false
            )
        }

        try await store.recordEvent(
            appID: app.id,
            kind: "backup.restored",
            message: "Restored backup \(manifest.backupID.uuidString) (isFreshInstall=\(isFreshInstall), cleanReinstall=\(didCleanReinstall)).",
            succeeded: true
        )
    }

    // MARK: - 3. Delete Backup

    public func deleteBackup(backupID: UUID) async throws {
        if let manifest = try await store.backup(id: backupID) {
            let dir = paths.backupDirectory(for: manifest.effectiveBundleID, backupID: backupID)
            if FileManager.default.fileExists(atPath: dir.path) {
                try FileManager.default.removeItem(at: dir)
            }
            try await store.removeBackup(id: backupID)
            try await store.recordEvent(
                appID: manifest.appID,
                kind: "backup.deleted",
                message: "Deleted backup \(backupID.uuidString).",
                succeeded: true
            )
        } else {
            try await store.removeBackup(id: backupID)
        }
    }

    // MARK: - 4. Freeze App (Backup -> Verify -> Uninstall -> Mark Frozen)

    public func freezeApp(
        appID: UUID,
        deviceIdentifier: String,
        createBackupFirst: Bool = true
    ) async throws -> BackupManifest? {
        guard var app = try await store.app(id: appID) else {
            throw AppleSyncError.appNotFound(appID)
        }

        try await ensureDeviceUnlocked(deviceIdentifier: deviceIdentifier, udid: app.targetDeviceUDID)

        var createdManifest: BackupManifest?
        if createBackupFirst {
            let manifest = try await createBackup(
                appID: appID,
                deviceIdentifier: deviceIdentifier,
                trigger: .preFreeze
            )
            let backupDir = paths.backupDirectory(for: app.effectiveBundleID, backupID: manifest.backupID)
            _ = try Self.verifyBackupOnDisk(at: backupDir, expectedBackupID: manifest.backupID)
            createdManifest = manifest
        }

        try await coreDevice.uninstallApp(
            deviceIdentifier: deviceIdentifier,
            bundleIdentifier: app.effectiveBundleID
        )

        if let refreshed = try await store.app(id: appID) {
            app = refreshed
        }
        app.state = .frozen
        app.stagedSignedAppPath = nil
        app.stagedProfileExpiresAt = nil
        if let createdManifest {
            app.lastBackupID = createdManifest.backupID
        }
        app.lastSyncError = nil
        try await store.upsertApp(app)

        try await store.recordEvent(
            appID: app.id,
            kind: "app.frozen",
            message: "Froze '\(app.displayName)' and freed active slot on device \(app.targetDeviceUDID).",
            succeeded: true
        )

        return createdManifest
    }

    // MARK: - 5. Thaw App (Stage & Sign -> Verify Slot & Lock -> Install -> Restore)

    public func thawApp(
        appID: UUID,
        deviceIdentifier: String,
        restoreBackupID: UUID? = nil
    ) async throws -> ManagedAppRecord {
        guard var app = try await store.app(id: appID) else {
            throw AppleSyncError.appNotFound(appID)
        }

        let signed = try await signingEngine.stageAndSignApp(for: app)

        if !signed.usedUntouchedEmbeddedProfile {
            let activeCount = try await store.activeSlotCount(
                forDeviceUDID: app.targetDeviceUDID,
                excludingAppID: app.id
            )
            if activeCount >= 3 {
                throw AppleSyncError.activeSlotLimitReached(
                    deviceUDID: app.targetDeviceUDID,
                    currentActiveCount: activeCount
                )
            }
        }

        let backupToRestore = restoreBackupID ?? app.lastBackupID
        if let backupToRestore {
            let storedManifest = try await store.backup(id: backupToRestore)
            let effectiveBundleID = storedManifest?.effectiveBundleID ?? app.effectiveBundleID
            let backupDir = paths.backupDirectory(for: effectiveBundleID, backupID: backupToRestore)
            _ = try Self.verifyBackupOnDisk(at: backupDir, expectedBackupID: backupToRestore)
        }

        try await ensureDeviceUnlocked(deviceIdentifier: deviceIdentifier, udid: app.targetDeviceUDID)

        try await coreDevice.installApp(
            deviceIdentifier: deviceIdentifier,
            appBundleURL: URL(fileURLWithPath: signed.stagedAppPath)
        )

        if let backupToRestore {
            try await restoreBackup(
                appID: app.id,
                backupID: backupToRestore,
                deviceIdentifier: deviceIdentifier,
                isFreshInstall: true
            )
        }

        let now = Date()
        app.effectiveBundleID = signed.effectiveBundleID
        app.state = signed.usedUntouchedEmbeddedProfile ? .activeAdHoc : .active
        app.lastInstalledAt = now
        app.profileExpiresAt = signed.profileExpirationDate
        app.stagedSignedAppPath = nil
        app.stagedProfileExpiresAt = nil
        app.lastSyncAttemptAt = now
        app.lastSyncError = nil
        try await store.upsertApp(app)

        try await store.recordEvent(
            appID: app.id,
            kind: "app.thawed",
            message: "Thawed and installed '\(app.displayName)' on device \(app.targetDeviceUDID).",
            succeeded: true
        )

        return app
    }

    // MARK: - 6. Two-Phase Atomic Swap (Freeze A <-> Thaw B)

    public func swapApps(
        freezeAppID: UUID,
        thawAppID: UUID,
        deviceIdentifier: String,
        restoreBackupIDForThaw: UUID? = nil
    ) async throws -> (frozenBackup: BackupManifest, thawedApp: ManagedAppRecord) {
        guard freezeAppID != thawAppID else {
            throw AppleSyncError.invalidInput("Cannot swap an app with itself.")
        }
        guard var freezeApp = try await store.app(id: freezeAppID) else {
            throw AppleSyncError.appNotFound(freezeAppID)
        }
        guard var thawApp = try await store.app(id: thawAppID) else {
            throw AppleSyncError.appNotFound(thawAppID)
        }

        // Phase 1: Stage & sign thawApp locally FIRST (and verify its target backup if any)
        // before touching freezeApp on the device.
        let signedThaw = try await signingEngine.stageAndSignApp(for: thawApp)
        let backupToRestore = restoreBackupIDForThaw ?? thawApp.lastBackupID
        if let backupToRestore {
            let storedManifest = try await store.backup(id: backupToRestore)
            let effectiveBundleID = storedManifest?.effectiveBundleID ?? thawApp.effectiveBundleID
            let backupDir = paths.backupDirectory(for: effectiveBundleID, backupID: backupToRestore)
            _ = try Self.verifyBackupOnDisk(at: backupDir, expectedBackupID: backupToRestore)
        }

        // Phase 2: Verify device is unlocked before starting any device operation.
        try await ensureDeviceUnlocked(deviceIdentifier: deviceIdentifier, udid: freezeApp.targetDeviceUDID)

        // Phase 3: Create and verify pre-swap backup of freezeApp. If this fails, abort without uninstalling!
        let frozenBackup = try await createBackup(
            appID: freezeAppID,
            deviceIdentifier: deviceIdentifier,
            trigger: .preSwap
        )
        let frozenBackupDir = paths.backupDirectory(for: freezeApp.effectiveBundleID, backupID: frozenBackup.backupID)
        _ = try Self.verifyBackupOnDisk(at: frozenBackupDir, expectedBackupID: frozenBackup.backupID)

        // Phase 4 (Commit 1): Uninstall freezeApp and immediately persist .frozen state.
        try await coreDevice.uninstallApp(
            deviceIdentifier: deviceIdentifier,
            bundleIdentifier: freezeApp.effectiveBundleID
        )
        if let refreshedFreeze = try await store.app(id: freezeAppID) {
            freezeApp = refreshedFreeze
        }
        freezeApp.state = .frozen
        freezeApp.lastBackupID = frozenBackup.backupID
        freezeApp.stagedSignedAppPath = nil
        freezeApp.stagedProfileExpiresAt = nil
        freezeApp.lastSyncError = nil
        try await store.upsertApp(freezeApp)

        // Phase 5 (Commit 2): Install thawApp, restore its container backup, and persist .active state.
        try await coreDevice.installApp(
            deviceIdentifier: deviceIdentifier,
            appBundleURL: URL(fileURLWithPath: signedThaw.stagedAppPath)
        )

        if let backupToRestore {
            try await restoreBackup(
                appID: thawApp.id,
                backupID: backupToRestore,
                deviceIdentifier: deviceIdentifier,
                isFreshInstall: true
            )
        }

        let now = Date()
        if let refreshedThaw = try await store.app(id: thawAppID) {
            thawApp = refreshedThaw
        }
        thawApp.effectiveBundleID = signedThaw.effectiveBundleID
        thawApp.state = signedThaw.usedUntouchedEmbeddedProfile ? .activeAdHoc : .active
        thawApp.lastInstalledAt = now
        thawApp.profileExpiresAt = signedThaw.profileExpirationDate
        thawApp.stagedSignedAppPath = nil
        thawApp.stagedProfileExpiresAt = nil
        thawApp.lastSyncAttemptAt = now
        thawApp.lastSyncError = nil
        try await store.upsertApp(thawApp)

        try await store.recordEvent(
            appID: thawApp.id,
            kind: "app.swapped",
            message: "Swapped out '\(freezeApp.displayName)' (backup \(frozenBackup.backupID.uuidString)) and activated '\(thawApp.displayName)'.",
            succeeded: true
        )

        return (frozenBackup, thawApp)
    }

    // MARK: - Device Lock & Process Quiescing Helpers

    private func ensureDeviceUnlocked(deviceIdentifier: String, udid: String) async throws {
        let lock = try await coreDevice.lockState(deviceIdentifier: deviceIdentifier)
        if !lock.unlockedSinceBoot || lock.passcodeRequired {
            throw AppleSyncError.deviceLocked(udid: udid)
        }
    }

    private func quiesceAppProcessIfRunning(
        deviceIdentifier: String,
        installedApp: InstalledDeviceApp,
        fallbackExecutableName: String
    ) async throws {
        let processes = (try? await coreDevice.runningProcesses(deviceIdentifier: deviceIdentifier)) ?? []
        let matchingPIDs = Self.matchingProcessIdentifiers(
            in: processes,
            installedApp: installedApp,
            fallbackExecutableName: fallbackExecutableName
        )
        guard !matchingPIDs.isEmpty else { return }

        for pid in matchingPIDs {
            try? await coreDevice.terminateProcess(deviceIdentifier: deviceIdentifier, pid: pid, kill: false)
        }

        try await Task.sleep(nanoseconds: 1_500_000_000)

        let remainingProcesses = (try? await coreDevice.runningProcesses(deviceIdentifier: deviceIdentifier)) ?? []
        let remainingPIDs = Self.matchingProcessIdentifiers(
            in: remainingProcesses,
            installedApp: installedApp,
            fallbackExecutableName: fallbackExecutableName
        )
        for pid in remainingPIDs {
            try? await coreDevice.terminateProcess(deviceIdentifier: deviceIdentifier, pid: pid, kill: true)
        }

        try await Task.sleep(nanoseconds: 500_000_000)
    }

    public static func matchingProcessIdentifiers(
        in processes: [RunningDeviceProcess],
        installedApp: InstalledDeviceApp,
        fallbackExecutableName: String
    ) -> [Int] {
        var bundleFolderToken: String?
        if let rawURL = installedApp.url, !rawURL.isEmpty {
            if let parsed = URL(string: rawURL), !parsed.lastPathComponent.isEmpty {
                bundleFolderToken = "/\(parsed.lastPathComponent)/"
            } else {
                let last = URL(fileURLWithPath: rawURL).lastPathComponent
                if !last.isEmpty {
                    bundleFolderToken = "/\(last)/"
                }
            }
        }

        return processes.compactMap { proc in
            if let token = bundleFolderToken, proc.executable.contains(token) {
                return proc.processIdentifier
            }
            if !installedApp.name.isEmpty && proc.executable.contains("/\(installedApp.name).app/") {
                return proc.processIdentifier
            }
            if !fallbackExecutableName.isEmpty && proc.executable.contains("/\(fallbackExecutableName).app/") {
                return proc.processIdentifier
            }
            return nil
        }
    }

    // MARK: - Deterministic Container Verification & Restore Plan

    public struct ContainerRestoreItem: Sendable, Equatable {
        public let localSourceURL: URL
        public let remoteDestinationSubpath: String

        public init(localSourceURL: URL, remoteDestinationSubpath: String) {
            self.localSourceURL = localSourceURL
            self.remoteDestinationSubpath = remoteDestinationSubpath
        }
    }

    public static func buildContainerRestorePlan(from containerDir: URL) throws -> [ContainerRestoreItem] {
        let fm = FileManager.default
        var items: [ContainerRestoreItem] = []

        for topFolder in ["Documents", "Library"] {
            let topURL = containerDir.appendingPathComponent(topFolder, isDirectory: true)
            guard fm.fileExists(atPath: topURL.path) else { continue }

            let children = try fm.contentsOfDirectory(
                at: topURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: []
            ).sorted { $0.lastPathComponent < $1.lastPathComponent }

            for childURL in children {
                let name = childURL.lastPathComponent
                if name == ".DS_Store" {
                    continue
                }
                if topFolder == "Library" && name == "SplashBoard" {
                    continue
                }

                let values = try childURL.resourceValues(forKeys: [.isDirectoryKey])
                if values.isDirectory == true {
                    items.append(
                        ContainerRestoreItem(
                            localSourceURL: childURL,
                            remoteDestinationSubpath: topFolder
                        )
                    )
                } else {
                    items.append(
                        ContainerRestoreItem(
                            localSourceURL: childURL,
                            remoteDestinationSubpath: "\(topFolder)/\(name)"
                        )
                    )
                }
            }
        }

        return items
    }

    public static func normalizeAndSanitizeStagedContainer(at stagedContainerDir: URL) {
        let fm = FileManager.default

        // If devicectl nested a '.' or 'Container' directory inside stagedContainerDir, flatten it.
        let docsAtRoot = stagedContainerDir.appendingPathComponent("Documents", isDirectory: true)
        let libAtRoot = stagedContainerDir.appendingPathComponent("Library", isDirectory: true)
        if !fm.fileExists(atPath: docsAtRoot.path) && !fm.fileExists(atPath: libAtRoot.path) {
            if let children = try? fm.contentsOfDirectory(at: stagedContainerDir, includingPropertiesForKeys: [.isDirectoryKey]),
               children.count == 1,
               (try? children[0].resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                let innerDir = children[0]
                if let innerItems = try? fm.contentsOfDirectory(at: innerDir, includingPropertiesForKeys: nil) {
                    for item in innerItems {
                        let dest = stagedContainerDir.appendingPathComponent(item.lastPathComponent)
                        try? fm.moveItem(at: item, to: dest)
                    }
                    try? fm.removeItem(at: innerDir)
                }
            }
        }

        let transientRelativePaths = [
            ".com.apple.mobile_container_manager.metadata.plist",
            "tmp",
            "Library/SplashBoard",
            "Library/Caches/com.apple.dyld"
        ]
        for rel in transientRelativePaths {
            let url = stagedContainerDir.appendingPathComponent(rel)
            if fm.fileExists(atPath: url.path) {
                try? fm.removeItem(at: url)
            }
        }
    }

    public static func verifyBackupOnDisk(
        at backupDir: URL,
        expectedBackupID: UUID
    ) throws -> BackupManifest {
        let fm = FileManager.default
        let verifiedURL = backupDir.appendingPathComponent(".verified", isDirectory: false)
        let manifestURL = backupDir.appendingPathComponent("manifest.json", isDirectory: false)
        let containerDir = backupDir.appendingPathComponent("Container", isDirectory: true)

        guard fm.fileExists(atPath: verifiedURL.path),
              fm.fileExists(atPath: manifestURL.path),
              fm.fileExists(atPath: containerDir.path) else {
            throw AppleSyncError.backupVerificationFailed(
                "Backup directory at \(backupDir.path) is incomplete or missing .verified marker."
            )
        }

        let manifestData = try Data(contentsOf: manifestURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(BackupManifest.self, from: manifestData)

        guard manifest.backupID == expectedBackupID else {
            throw AppleSyncError.backupVerificationFailed(
                "Backup ID mismatch in manifest: expected \(expectedBackupID), found \(manifest.backupID)."
            )
        }

        let recomputed = try computeDirectoryTreeDigest(at: containerDir)
        guard recomputed.sha256Digest == manifest.sha256Digest else {
            throw AppleSyncError.backupVerificationFailed(
                "Backup SHA-256 digest mismatch for \(expectedBackupID): expected \(manifest.sha256Digest), got \(recomputed.sha256Digest)."
            )
        }

        return manifest
    }

    public static func computeDirectoryTreeDigest(
        at directoryURL: URL
    ) throws -> (sha256Digest: String, sizeBytes: UInt64, fileCount: Int) {
        let fm = FileManager.default
        let rootURL = directoryURL.resolvingSymlinksInPath().standardizedFileURL
        guard fm.fileExists(atPath: rootURL.path) else {
            throw AppleSyncError.backupVerificationFailed("Directory does not exist at \(rootURL.path)")
        }

        var relativeEntries: [(relativePath: String, fileURL: URL, isSymlink: Bool)] = []
        let rootPrefix = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"

        if let enumerator = fm.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey],
            options: []
        ) {
            while let itemURL = enumerator.nextObject() as? URL {
                if itemURL.lastPathComponent == ".DS_Store" {
                    continue
                }
                let standardized = itemURL.standardizedFileURL
                let fullPath = standardized.path
                guard fullPath.hasPrefix(rootPrefix) else { continue }
                let relPath = String(fullPath.dropFirst(rootPrefix.count))

                let values = try itemURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey])
                if values.isSymbolicLink == true {
                    relativeEntries.append((relPath, itemURL, true))
                } else if values.isRegularFile == true {
                    relativeEntries.append((relPath, itemURL, false))
                }
            }
        }

        relativeEntries.sort { $0.relativePath < $1.relativePath }

        var hasher = SHA256()
        var totalBytes: UInt64 = 0
        var totalFiles = 0

        for entry in relativeEntries {
            totalFiles += 1
            hasher.update(data: Data("PATH:\(entry.relativePath)\n".utf8))
            if entry.isSymlink {
                let dest = (try? fm.destinationOfSymbolicLink(atPath: entry.fileURL.path)) ?? ""
                let destData = Data(dest.utf8)
                totalBytes += UInt64(destData.count)
                hasher.update(data: Data("SYMLINK:\(destData.count)\n".utf8))
                hasher.update(data: destData)
            } else {
                let fileData = try Data(contentsOf: entry.fileURL)
                totalBytes += UInt64(fileData.count)
                hasher.update(data: Data("FILE:\(fileData.count)\n".utf8))
                hasher.update(data: fileData)
            }
        }

        let digestHex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return (digestHex, totalBytes, totalFiles)
    }
}
