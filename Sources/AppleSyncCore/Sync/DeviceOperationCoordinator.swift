import Foundation

public struct ActiveSlotSummary: Codable, Sendable, Equatable {
    public static let defaultMaxFreeSlots: Int = 3

    public var deviceUDID: String
    public var activeCount: Int
    public var maxFreeSlots: Int
    public var remainingSlots: Int
    public var activeApps: [ManagedAppRecord]
    public var frozenApps: [ManagedAppRecord]
    public var adHocApps: [ManagedAppRecord]

    public init(
        deviceUDID: String,
        activeCount: Int,
        maxFreeSlots: Int = ActiveSlotSummary.defaultMaxFreeSlots,
        remainingSlots: Int,
        activeApps: [ManagedAppRecord],
        frozenApps: [ManagedAppRecord],
        adHocApps: [ManagedAppRecord]
    ) {
        self.deviceUDID = deviceUDID
        self.activeCount = activeCount
        self.maxFreeSlots = maxFreeSlots
        self.remainingSlots = remainingSlots
        self.activeApps = activeApps
        self.frozenApps = frozenApps
        self.adHocApps = adHocApps
    }
}

public struct AppSyncOutcome: Codable, Sendable, Equatable {
    public enum Action: String, Codable, Sendable, Equatable {
        case skippedFrozen
        case skippedPaused
        case upToDate
        case stagedOfflineOnly
        case syncedOverDevice
        case skippedDeviceOffline
        case skippedDeviceLocked
        case stagingFailed
        case expiredOnDevice
        case activeAdHocOk
    }

    public var appID: UUID
    public var displayName: String
    public var action: Action
    public var previousState: AppLifecycleState
    public var newState: AppLifecycleState
    public var message: String
    public var alertEmitted: SyncAlert?

    public init(
        appID: UUID,
        displayName: String,
        action: Action,
        previousState: AppLifecycleState,
        newState: AppLifecycleState,
        message: String,
        alertEmitted: SyncAlert? = nil
    ) {
        self.appID = appID
        self.displayName = displayName
        self.action = action
        self.previousState = previousState
        self.newState = newState
        self.message = message
        self.alertEmitted = alertEmitted
    }
}

public struct SyncCycleReport: Codable, Sendable, Equatable {
    public var startedAt: Date
    public var completedAt: Date
    public var reachableDeviceUDIDs: [String]
    public var outcomes: [AppSyncOutcome]
    public var alertsEmitted: [SyncAlert]
    public var wasStoppedGlobally: Bool

    public init(
        startedAt: Date,
        completedAt: Date,
        reachableDeviceUDIDs: [String],
        outcomes: [AppSyncOutcome],
        alertsEmitted: [SyncAlert],
        wasStoppedGlobally: Bool = false
    ) {
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.reachableDeviceUDIDs = reachableDeviceUDIDs
        self.outcomes = outcomes
        self.alertsEmitted = alertsEmitted
        self.wasStoppedGlobally = wasStoppedGlobally
    }
}

public actor DeviceOperationCoordinator {
    public static let maxActiveFreeSlots: Int = 3
    public static let offlineStageThresholdSeconds: TimeInterval = 4 * 86_400
    public static let urgentAlertThresholdSeconds: TimeInterval = 6 * 86_400
    public static let urgentRemainingThresholdSeconds: TimeInterval = 24 * 3600
    public static let expiryFallbackSeconds: TimeInterval = 7 * 86_400
    public static let adHocWarningRemainingSeconds: TimeInterval = 14 * 86_400
    private static let thresholdRetentionSeconds: TimeInterval = 30 * 86_400

    public let paths: AppleSyncPaths
    public let store: SyncStateStore
    public let coreDevice: any CoreDeviceServicing
    public let signingEngine: any SigningServicing
    public let backupManager: any BackupServicing
    public let notifier: any NotificationDelivering
    public let clock: @Sendable () -> Date

    private let fileLock: CrossProcessFileLock

    public init(
        paths: AppleSyncPaths = AppleSyncPaths(),
        store: SyncStateStore,
        coreDevice: any CoreDeviceServicing,
        signingEngine: any SigningServicing,
        backupManager: any BackupServicing,
        notifier: any NotificationDelivering = NoOpNotificationDeliverer(),
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.paths = paths
        self.store = store
        self.coreDevice = coreDevice
        self.signingEngine = signingEngine
        self.backupManager = backupManager
        self.notifier = notifier
        self.clock = clock
        self.fileLock = CrossProcessFileLock(lockFileURL: paths.lockFileURL)
    }

    // MARK: - Read-Only Queries (No Device Lock)

    public func discoverSigningTeams() async throws -> [TeamIdentitySummary] {
        try await signingEngine.discoverSigningTeams()
    }

    public func discoverDevices() async throws -> [DiscoveredDevice] {
        try await coreDevice.listDevices()
    }

    public func inspectXcodeProject(
        at projectURL: URL,
        preferredScheme: String? = nil,
        configuration: String = "Debug"
    ) async throws -> XcodeProjectInspection {
        try await signingEngine.inspectXcodeProject(
            at: projectURL,
            preferredScheme: preferredScheme,
            configuration: configuration
        )
    }

    public func inspectIPA(
        at ipaURL: URL,
        targetDeviceUDID: String
    ) async throws -> IPAInspectionReport {
        try await signingEngine.inspectIPA(at: ipaURL, targetDeviceUDID: targetDeviceUDID)
    }

    public func listApps() async throws -> [ManagedAppRecord] {
        try await store.allApps()
    }

    public func app(id: UUID) async throws -> ManagedAppRecord? {
        try await store.app(id: id)
    }

    public func backups(forAppID appID: UUID) async throws -> [BackupManifest] {
        try await store.backups(forAppID: appID)
    }

    public func events(limit: Int? = nil) async throws -> [SyncEvent] {
        try await store.events(limit: limit)
    }

    public func isGlobalAutoSyncPaused() async throws -> Bool {
        try await store.isGlobalAutoSyncPaused()
    }

    public func setGlobalAutoSyncPaused(_ paused: Bool) async throws {
        try paths.ensureDirectoriesExist()
        try await store.setGlobalAutoSyncPaused(paused)
        try await store.recordEvent(
            appID: nil,
            kind: paused ? "daemon_stopped" : "daemon_started",
            message: paused
                ? "Automatic background sync daemon stopped/paused by user."
                : "Automatic background sync daemon started/resumed by user.",
            succeeded: true,
            at: clock()
        )
    }

    public func setAppAutoSyncPaused(appID: UUID, paused: Bool) async throws -> ManagedAppRecord {
        try paths.ensureDirectoriesExist()
        let updated = try await store.setAppAutoSyncPaused(appID: appID, paused: paused)
        try await store.recordEvent(
            appID: appID,
            kind: paused ? "app_autosync_paused" : "app_autosync_resumed",
            message: paused
                ? "Automatic sync paused for '\(updated.displayName)'."
                : "Automatic sync resumed for '\(updated.displayName)'.",
            succeeded: true,
            at: clock()
        )
        return updated
    }

    public func activeSlotSummary(forDeviceUDID deviceUDID: String) async throws -> ActiveSlotSummary {
        let deviceApps = try await store.apps(forDeviceUDID: deviceUDID)
        let activeApps = deviceApps.filter { $0.state.countsAgainstActiveSlotLimit }
        let frozenApps = deviceApps.filter { $0.state == .frozen }
        let adHocApps = deviceApps.filter { $0.state == .activeAdHoc }
        let activeCount = activeApps.count
        let remaining = max(0, Self.maxActiveFreeSlots - activeCount)
        return ActiveSlotSummary(
            deviceUDID: deviceUDID,
            activeCount: activeCount,
            maxFreeSlots: Self.maxActiveFreeSlots,
            remainingSlots: remaining,
            activeApps: activeApps,
            frozenApps: frozenApps,
            adHocApps: adHocApps
        )
    }

    // MARK: - Serialized Device & State Mutations

    public func registerXcodeApp(
        projectOrWorkspacePath: String,
        scheme: String? = nil,
        configuration: String = "Release",
        stripExtensions: Bool = true,
        teamID: String,
        targetDeviceUDID: String,
        displayNameOverride: String? = nil,
        installImmediately: Bool = true
    ) async throws -> ManagedAppRecord {
        try paths.ensureDirectoriesExist()
        return try await fileLock.withLock {
            let projectURL = URL(fileURLWithPath: projectOrWorkspacePath)
            let inspection = try await self.signingEngine.inspectXcodeProject(
                at: projectURL,
                preferredScheme: scheme,
                configuration: configuration
            )

            if installImmediately {
                let activeCount = try await self.store.activeSlotCount(forDeviceUDID: targetDeviceUDID)
                if activeCount >= Self.maxActiveFreeSlots {
                    throw AppleSyncError.activeSlotLimitReached(
                        deviceUDID: targetDeviceUDID,
                        currentActiveCount: activeCount
                    )
                }
                _ = try await self.requireUnlockedDevice(forUDID: targetDeviceUDID)
            }

            let appID = UUID()
            let effectiveBundleID = EffectiveBundleID.make(
                teamID: teamID,
                originalBundleID: inspection.bundleIdentifier
            )
            let resolvedURL = URL(fileURLWithPath: inspection.projectPath)
            let pinnedCommit = Self.resolveGitHeadCommit(near: resolvedURL)
            let source = AppSource.xcodeProject(
                projectOrWorkspacePath: inspection.projectPath,
                scheme: inspection.selectedScheme,
                configuration: inspection.selectedConfiguration,
                pinnedSnapshotCommit: pinnedCommit
            )

            do {
                let imported = try await self.signingEngine.importBaseArtifact(
                    appID: appID,
                    source: source,
                    teamID: teamID
                )
                let cleanDisplayName = Self.resolvedDisplayName(
                    override: displayNameOverride,
                    fallback: inspection.displayName
                )

                var record = ManagedAppRecord(
                    id: appID,
                    displayName: cleanDisplayName,
                    originalBundleID: inspection.bundleIdentifier,
                    effectiveBundleID: effectiveBundleID,
                    teamID: teamID,
                    targetDeviceUDID: targetDeviceUDID,
                    source: source,
                    state: installImmediately ? .active : .frozen,
                    cachedBaseAppPath: imported.baseAppURL.path,
                    appVersion: imported.version,
                    buildVersion: imported.buildVersion,
                    stripEmbeddedExtensions: stripExtensions
                )

                let now = self.clock()
                if installImmediately {
                    let signed = try await self.signingEngine.stageAndSignApp(for: record)
                    let device = try await self.requireUnlockedDevice(forUDID: targetDeviceUDID)
                    try await self.coreDevice.installApp(
                        deviceIdentifier: device.coreDeviceIdentifier,
                        appBundleURL: URL(fileURLWithPath: signed.stagedAppPath)
                    )
                    record.state = .active
                    record.effectiveBundleID = signed.effectiveBundleID
                    record.lastInstalledAt = now
                    record.profileExpiresAt = signed.profileExpirationDate
                    record.stagedSignedAppPath = nil
                    record.stagedProfileExpiresAt = nil
                    record.lastSyncAttemptAt = now
                    record.lastSyncError = nil
                    try? FileManager.default.removeItem(atPath: signed.stagedAppPath)
                }

                try await self.store.upsertApp(record)
                try await self.store.recordEvent(
                    appID: appID,
                    kind: "register_xcode",
                    message: "Registered Xcode app '\(record.displayName)' (\(record.effectiveBundleID)) in state \(record.state.rawValue).",
                    succeeded: true,
                    at: now
                )
                return record
            } catch {
                try? FileManager.default.removeItem(at: self.paths.artifactDirectory(for: appID))
                throw error
            }
        }
    }

    public func registerIPAApp(
        ipaPath: String,
        teamID: String,
        targetDeviceUDID: String,
        stripExtensions: Bool = true,
        preferOriginalAdHocIfValid: Bool = true,
        displayNameOverride: String? = nil,
        installImmediately: Bool = true
    ) async throws -> ManagedAppRecord {
        try paths.ensureDirectoriesExist()
        return try await fileLock.withLock {
            let ipaURL = URL(fileURLWithPath: ipaPath)
            let inspection = try await self.signingEngine.inspectIPA(
                at: ipaURL,
                targetDeviceUDID: targetDeviceUDID
            )

            if inspection.isFairPlayEncrypted {
                throw AppleSyncError.encryptedIPAUnsupported(ipaURL.path)
            }
            if !inspection.supportsArm64iOS {
                throw AppleSyncError.unsupportedArchitecture(ipaURL.path)
            }

            let isAdHoc = preferOriginalAdHocIfValid && inspection.canInstallUntouchedForTargetDevice

            if installImmediately {
                if !isAdHoc {
                    let activeCount = try await self.store.activeSlotCount(forDeviceUDID: targetDeviceUDID)
                    if activeCount >= Self.maxActiveFreeSlots {
                        throw AppleSyncError.activeSlotLimitReached(
                            deviceUDID: targetDeviceUDID,
                            currentActiveCount: activeCount
                        )
                    }
                }
                _ = try await self.requireUnlockedDevice(forUDID: targetDeviceUDID)
            }

            let appID = UUID()
            let effectiveBundleID = isAdHoc
                ? inspection.bundleIdentifier
                : EffectiveBundleID.make(teamID: teamID, originalBundleID: inspection.bundleIdentifier)

            let source = AppSource.externalIPA(
                originalIPAPath: ipaURL.path,
                originalBundleID: inspection.bundleIdentifier,
                stripExtensions: stripExtensions,
                useOriginalAdHocIfValid: preferOriginalAdHocIfValid
            )

            do {
                let imported = try await self.signingEngine.importBaseArtifact(
                    appID: appID,
                    source: source,
                    teamID: teamID
                )
                let cleanDisplayName = Self.resolvedDisplayName(
                    override: displayNameOverride,
                    fallback: inspection.displayName
                )

                var record = ManagedAppRecord(
                    id: appID,
                    displayName: cleanDisplayName,
                    originalBundleID: inspection.bundleIdentifier,
                    effectiveBundleID: effectiveBundleID,
                    teamID: teamID,
                    targetDeviceUDID: targetDeviceUDID,
                    source: source,
                    state: installImmediately ? (isAdHoc ? .activeAdHoc : .active) : .frozen,
                    cachedBaseAppPath: imported.baseAppURL.path,
                    appVersion: imported.version,
                    buildVersion: imported.buildVersion
                )

                let now = self.clock()
                if installImmediately {
                    let signed = try await self.signingEngine.stageAndSignApp(for: record)
                    let device = try await self.requireUnlockedDevice(forUDID: targetDeviceUDID)
                    try await self.coreDevice.installApp(
                        deviceIdentifier: device.coreDeviceIdentifier,
                        appBundleURL: URL(fileURLWithPath: signed.stagedAppPath)
                    )
                    record.state = signed.usedUntouchedEmbeddedProfile ? .activeAdHoc : .active
                    record.effectiveBundleID = signed.effectiveBundleID
                    record.lastInstalledAt = now
                    record.profileExpiresAt = signed.profileExpirationDate
                    record.stagedSignedAppPath = nil
                    record.stagedProfileExpiresAt = nil
                    record.lastSyncAttemptAt = now
                    record.lastSyncError = nil
                    try? FileManager.default.removeItem(atPath: signed.stagedAppPath)
                }

                try await self.store.upsertApp(record)
                try await self.store.recordEvent(
                    appID: appID,
                    kind: "register_ipa",
                    message: "Registered IPA app '\(record.displayName)' (\(record.effectiveBundleID)) in state \(record.state.rawValue).",
                    succeeded: true,
                    at: now
                )
                return record
            } catch {
                try? FileManager.default.removeItem(at: self.paths.artifactDirectory(for: appID))
                throw error
            }
        }
    }

    public func rebuildXcodeSnapshot(
        appID: UUID,
        reinstallIfActive: Bool = true
    ) async throws -> ManagedAppRecord {
        try paths.ensureDirectoriesExist()
        return try await fileLock.withLock {
            guard var app = try await self.store.app(id: appID) else {
                throw AppleSyncError.appNotFound(appID)
            }

            guard case let .xcodeProject(projectOrWorkspacePath, scheme, configuration, _) = app.source else {
                throw AppleSyncError.invalidInput(
                    "App '\(app.displayName)' is not backed by an Xcode project source."
                )
            }

            let projectURL = URL(fileURLWithPath: projectOrWorkspacePath)
            let newCommit = Self.resolveGitHeadCommit(near: projectURL)
            let updatedSource = AppSource.xcodeProject(
                projectOrWorkspacePath: projectOrWorkspacePath,
                scheme: scheme,
                configuration: configuration,
                pinnedSnapshotCommit: newCommit
            )

            let imported = try await self.signingEngine.importBaseArtifact(
                appID: app.id,
                source: updatedSource,
                teamID: app.teamID
            )

            app.source = updatedSource
            app.cachedBaseAppPath = imported.baseAppURL.path
            app.appVersion = imported.version
            app.buildVersion = imported.buildVersion
            app.stagedSignedAppPath = nil
            app.stagedProfileExpiresAt = nil

            let now = self.clock()
            if reinstallIfActive && app.state != .frozen {
                let activeCount = try await self.store.activeSlotCount(
                    forDeviceUDID: app.targetDeviceUDID,
                    excludingAppID: app.id
                )
                if activeCount >= Self.maxActiveFreeSlots {
                    throw AppleSyncError.activeSlotLimitReached(
                        deviceUDID: app.targetDeviceUDID,
                        currentActiveCount: activeCount
                    )
                }

                let signed = try await self.signingEngine.stageAndSignApp(for: app)
                let device = try await self.requireUnlockedDevice(forUDID: app.targetDeviceUDID)
                try await self.coreDevice.installApp(
                    deviceIdentifier: device.coreDeviceIdentifier,
                    appBundleURL: URL(fileURLWithPath: signed.stagedAppPath)
                )
                app.state = .active
                app.lastInstalledAt = now
                app.profileExpiresAt = signed.profileExpirationDate
                app.stagedSignedAppPath = nil
                app.stagedProfileExpiresAt = nil
                app.lastSyncAttemptAt = now
                app.lastSyncError = nil
                try? FileManager.default.removeItem(atPath: signed.stagedAppPath)
            }

            try await self.store.upsertApp(app)
            try await self.store.recordEvent(
                appID: app.id,
                kind: "rebuild_xcode_snapshot",
                message: "Rebuilt frozen base snapshot for '\(app.displayName)' (v\(app.appVersion) build \(app.buildVersion)).",
                succeeded: true,
                at: now
            )
            return app
        }
    }

    public func syncAppNow(appID: UUID) async throws -> ManagedAppRecord {
        try paths.ensureDirectoriesExist()
        return try await fileLock.withLock {
            guard var app = try await self.store.app(id: appID) else {
                throw AppleSyncError.appNotFound(appID)
            }

            if app.state == .frozen {
                throw AppleSyncError.invalidInput(
                    "Cannot sync frozen app '\(app.displayName)'. Thaw or swap it first."
                )
            }

            if app.state != .activeAdHoc {
                let activeCount = try await self.store.activeSlotCount(
                    forDeviceUDID: app.targetDeviceUDID,
                    excludingAppID: app.id
                )
                if activeCount >= Self.maxActiveFreeSlots {
                    throw AppleSyncError.activeSlotLimitReached(
                        deviceUDID: app.targetDeviceUDID,
                        currentActiveCount: activeCount
                    )
                }
            }

            let device = try await self.requireUnlockedDevice(forUDID: app.targetDeviceUDID)
            let signed = try await self.signingEngine.stageAndSignApp(for: app)
            try await self.coreDevice.installApp(
                deviceIdentifier: device.coreDeviceIdentifier,
                appBundleURL: URL(fileURLWithPath: signed.stagedAppPath)
            )

            let now = self.clock()
            app.state = signed.usedUntouchedEmbeddedProfile ? .activeAdHoc : .active
            app.lastInstalledAt = now
            app.profileExpiresAt = signed.profileExpirationDate
            app.stagedSignedAppPath = nil
            app.stagedProfileExpiresAt = nil
            app.lastSyncAttemptAt = now
            app.lastSyncError = nil
            try? FileManager.default.removeItem(atPath: signed.stagedAppPath)

            try await self.store.upsertApp(app)
            try await self.store.recordEvent(
                appID: app.id,
                kind: "sync_now",
                message: "Manually re-synced '\(app.displayName)' to device \(app.targetDeviceUDID).",
                succeeded: true,
                at: now
            )
            return app
        }
    }

    public func removeApp(
        appID: UUID,
        uninstallFromDevice: Bool = false,
        deleteBackups: Bool = false
    ) async throws {
        try paths.ensureDirectoriesExist()
        try await fileLock.withLock {
            guard let app = try await self.store.app(id: appID) else {
                throw AppleSyncError.appNotFound(appID)
            }

            if uninstallFromDevice && app.state != .frozen {
                let device = try await self.resolveConnectedDevice(forUDID: app.targetDeviceUDID)
                try await self.coreDevice.uninstallApp(
                    deviceIdentifier: device.coreDeviceIdentifier,
                    bundleIdentifier: app.effectiveBundleID
                )
            }

            if deleteBackups {
                let manifests = try await self.store.backups(forAppID: appID)
                for manifest in manifests {
                    try await self.backupManager.deleteBackup(backupID: manifest.backupID)
                }
                let appBackupsDir = self.paths.backupsDirectoryURL.appendingPathComponent(
                    app.effectiveBundleID,
                    isDirectory: true
                )
                try? FileManager.default.removeItem(at: appBackupsDir)
            }

            try? FileManager.default.removeItem(at: self.paths.artifactDirectory(for: appID))
            try await self.store.removeApp(id: appID)
            try await self.store.recordEvent(
                appID: appID,
                kind: "remove_app",
                message: "Removed managed app '\(app.displayName)' (uninstallFromDevice=\(uninstallFromDevice), deleteBackups=\(deleteBackups)).",
                succeeded: true,
                at: self.clock()
            )
        }
    }

    public func createManualBackup(appID: UUID) async throws -> BackupManifest {
        try paths.ensureDirectoriesExist()
        return try await fileLock.withLock {
            guard let app = try await self.store.app(id: appID) else {
                throw AppleSyncError.appNotFound(appID)
            }
            let device = try await self.requireUnlockedDevice(forUDID: app.targetDeviceUDID)
            return try await self.backupManager.createBackup(
                appID: appID,
                deviceIdentifier: device.coreDeviceIdentifier,
                trigger: .manual
            )
        }
    }

    public func restoreBackup(appID: UUID, backupID: UUID) async throws {
        try paths.ensureDirectoriesExist()
        try await fileLock.withLock {
            guard let app = try await self.store.app(id: appID) else {
                throw AppleSyncError.appNotFound(appID)
            }
            let device = try await self.requireUnlockedDevice(forUDID: app.targetDeviceUDID)
            try await self.backupManager.restoreBackup(
                appID: appID,
                backupID: backupID,
                deviceIdentifier: device.coreDeviceIdentifier,
                isFreshInstall: false
            )
        }
    }

    public func deleteBackup(backupID: UUID) async throws {
        try paths.ensureDirectoriesExist()
        try await fileLock.withLock {
            try await self.backupManager.deleteBackup(backupID: backupID)
        }
    }

    public func freezeApp(appID: UUID, createBackupFirst: Bool = true) async throws -> BackupManifest? {
        try paths.ensureDirectoriesExist()
        return try await fileLock.withLock {
            guard let app = try await self.store.app(id: appID) else {
                throw AppleSyncError.appNotFound(appID)
            }
            let device = try await self.requireUnlockedDevice(forUDID: app.targetDeviceUDID)
            return try await self.backupManager.freezeApp(
                appID: appID,
                deviceIdentifier: device.coreDeviceIdentifier,
                createBackupFirst: createBackupFirst
            )
        }
    }

    public func thawApp(appID: UUID, restoreBackupID: UUID? = nil) async throws -> ManagedAppRecord {
        try paths.ensureDirectoriesExist()
        return try await fileLock.withLock {
            guard let app = try await self.store.app(id: appID) else {
                throw AppleSyncError.appNotFound(appID)
            }
            let device = try await self.requireUnlockedDevice(forUDID: app.targetDeviceUDID)
            var thawed = try await self.backupManager.thawApp(
                appID: appID,
                deviceIdentifier: device.coreDeviceIdentifier,
                restoreBackupID: restoreBackupID
            )
            let now = self.clock()
            if let installedAt = thawed.lastInstalledAt, abs(installedAt.timeIntervalSince(now)) > 5 {
                thawed.lastInstalledAt = now
                try await self.store.upsertApp(thawed)
            }
            return thawed
        }
    }

    public func swapApps(
        freezeAppID: UUID,
        thawAppID: UUID,
        restoreBackupIDForThaw: UUID? = nil
    ) async throws -> (frozenBackup: BackupManifest, thawedApp: ManagedAppRecord) {
        try paths.ensureDirectoriesExist()
        return try await fileLock.withLock {
            guard (try await self.store.app(id: freezeAppID)) != nil else {
                throw AppleSyncError.appNotFound(freezeAppID)
            }
            guard let thawApp = try await self.store.app(id: thawAppID) else {
                throw AppleSyncError.appNotFound(thawAppID)
            }
            let device = try await self.requireUnlockedDevice(forUDID: thawApp.targetDeviceUDID)
            var result = try await self.backupManager.swapApps(
                freezeAppID: freezeAppID,
                thawAppID: thawAppID,
                deviceIdentifier: device.coreDeviceIdentifier,
                restoreBackupIDForThaw: restoreBackupIDForThaw
            )
            let now = self.clock()
            if let installedAt = result.thawedApp.lastInstalledAt, abs(installedAt.timeIntervalSince(now)) > 5 {
                result.thawedApp.lastInstalledAt = now
                try await self.store.upsertApp(result.thawedApp)
            }
            return result
        }
    }

    // MARK: - Background Sync State Machine (Day 4 Stage -> Wi-Fi Push -> Day 6/7 Alerts)

    public func runBackgroundSyncCycle(force: Bool = false) async throws -> SyncCycleReport {
        try paths.ensureDirectoriesExist()
        return try await fileLock.withLock {
            let startedAt = self.clock()
            if !force, try await self.store.isGlobalAutoSyncPaused() {
                return SyncCycleReport(
                    startedAt: startedAt,
                    completedAt: self.clock(),
                    reachableDeviceUDIDs: [],
                    outcomes: [],
                    alertsEmitted: [],
                    wasStoppedGlobally: true
                )
            }

            try Task.checkCancellation()
            let discoveredDevices: [DiscoveredDevice]
            do {
                discoveredDevices = try await self.coreDevice.listDevices()
            } catch {
                discoveredDevices = []
                try? await self.store.recordEvent(
                    appID: nil,
                    kind: "device_discovery_failed",
                    message: "CoreDevice device discovery failed during sync cycle: \(error.localizedDescription)",
                    succeeded: false,
                    at: startedAt
                )
            }
            let reachableDevices = discoveredDevices.filter { Self.isDeviceReachable($0) }
            let reachableUDIDs = reachableDevices.map(\.udid)

            let apps = try await self.store.allApps()
            var outcomes: [AppSyncOutcome] = []
            var alertsEmitted: [SyncAlert] = []

            for var app in apps {
                try Task.checkCancellation()
                let previousState = app.state
                let now = self.clock()

                if app.state == .frozen {
                    outcomes.append(
                        AppSyncOutcome(
                            appID: app.id,
                            displayName: app.displayName,
                            action: .skippedFrozen,
                            previousState: previousState,
                            newState: .frozen,
                            message: "App is frozen in Mac Vault; skipping background sync."
                        )
                    )
                    continue
                }

                if app.autoSyncPaused {
                    outcomes.append(
                        AppSyncOutcome(
                            appID: app.id,
                            displayName: app.displayName,
                            action: .skippedPaused,
                            previousState: previousState,
                            newState: previousState,
                            message: "Auto-sync paused for this app by user."
                        )
                    )
                    continue
                }

                if app.state == .activeAdHoc {
                    var emittedAlert: SyncAlert? = nil
                    if let exp = app.profileExpiresAt,
                       exp.timeIntervalSince(now) <= Self.adHocWarningRemainingSeconds {
                        let daysLeft = max(0, Int((exp.timeIntervalSince(now) / 86_400.0).rounded(.down)))
                        let key = "\(app.id.uuidString):\(SyncAlert.Category.expiryWarning.rawValue):adhoc:\(Int(exp.timeIntervalSince1970))"
                        emittedAlert = try await self.emitDeduplicatedAlertIfNeeded(
                            appID: app.id,
                            category: .expiryWarning,
                            severity: exp.timeIntervalSince(now) <= 0 ? .critical : .warning,
                            title: "\(app.displayName) Ad-Hoc Profile Expiring Soon",
                            body: "The embedded Ad-Hoc provisioning profile for '\(app.displayName)' expires in ~\(daysLeft) day(s).",
                            thresholdKey: key,
                            now: now
                        )
                        if let emittedAlert {
                            alertsEmitted.append(emittedAlert)
                        }
                    }
                    outcomes.append(
                        AppSyncOutcome(
                            appID: app.id,
                            displayName: app.displayName,
                            action: .activeAdHocOk,
                            previousState: previousState,
                            newState: .activeAdHoc,
                            message: "Ad-Hoc app is active.",
                            alertEmitted: emittedAlert
                        )
                    )
                    continue
                }

                let elapsed: TimeInterval
                if let lastInstalledAt = app.lastInstalledAt {
                    elapsed = max(0, now.timeIntervalSince(lastInstalledAt))
                } else {
                    elapsed = Self.offlineStageThresholdSeconds
                }
                let remaining = app.profileExpiresAt?.timeIntervalSince(now)

                let needsRenewal = (app.state != .active)
                    || (elapsed >= Self.offlineStageThresholdSeconds)
                    || (remaining != nil && remaining! <= (Self.expiryFallbackSeconds - Self.offlineStageThresholdSeconds))

                let isDay6Urgent = (elapsed >= Self.urgentAlertThresholdSeconds)
                    || (remaining != nil && remaining! <= Self.urgentRemainingThresholdSeconds)

                let isExpired = (elapsed >= Self.expiryFallbackSeconds)
                    || (remaining != nil && remaining! <= 0)

                if !needsRenewal {
                    outcomes.append(
                        AppSyncOutcome(
                            appID: app.id,
                            displayName: app.displayName,
                            action: .upToDate,
                            previousState: previousState,
                            newState: app.state,
                            message: "App is within Days 0-3 window; no renewal needed."
                        )
                    )
                    continue
                }

                // Phase A: Day 4+ Offline Stage on Mac
                let hadValidStagedBundleBefore = Self.hasValidStagedArtifact(for: app, at: now)
                var freshlyStagedThisCycle = false
                var stagingFailedError: Error? = nil
                var emittedAlert: SyncAlert? = nil

                if !hadValidStagedBundleBefore {
                    do {
                        let signed = try await self.signingEngine.stageAndSignApp(for: app)
                        app.stagedSignedAppPath = signed.stagedAppPath
                        app.stagedProfileExpiresAt = signed.profileExpirationDate
                        app.lastSyncError = nil
                        if app.state == .active {
                            app.state = .stagedOffline
                        }
                        freshlyStagedThisCycle = true
                        try await self.store.recordEvent(
                            appID: app.id,
                            kind: "stage_offline",
                            message: "Staged fresh 7-day signed bundle for '\(app.displayName)' on Mac.",
                            succeeded: true,
                            at: now
                        )
                    } catch {
                        stagingFailedError = error
                        app.lastSyncAttemptAt = now
                        app.lastSyncError = error.localizedDescription
                        try await self.store.recordEvent(
                            appID: app.id,
                            kind: "stage_offline_failed",
                            message: "Offline staging failed for '\(app.displayName)': \(error.localizedDescription)",
                            succeeded: false,
                            at: now
                        )
                        if Self.isAuthOrProvisioningError(error) {
                            let cycleStamp = Int(app.lastInstalledAt?.timeIntervalSince1970 ?? 0)
                            let key = "\(app.id.uuidString):\(SyncAlert.Category.xcodeAuthRequired.rawValue):\(cycleStamp)"
                            if let authAlert = try await self.emitDeduplicatedAlertIfNeeded(
                                appID: app.id,
                                category: .xcodeAuthRequired,
                                severity: .warning,
                                title: "Xcode Account Sign-In Required for \(app.displayName)",
                                body: "AppleSync could not renew the provisioning profile for '\(app.displayName)' (\(error.localizedDescription)). Open Xcode > Settings > Accounts to re-authenticate.",
                                thresholdKey: key,
                                now: now
                            ) {
                                emittedAlert = authAlert
                                alertsEmitted.append(authAlert)
                            }
                        }
                    }
                }

                // Phase B: Opportunistic Wi-Fi / USB Push
                var deviceWasLocked = false
                let matchingDevice = reachableDevices.first(where: {
                    $0.udid.caseInsensitiveCompare(app.targetDeviceUDID) == .orderedSame ||
                    $0.coreDeviceIdentifier.caseInsensitiveCompare(app.targetDeviceUDID) == .orderedSame
                })

                if let stagedPath = app.stagedSignedAppPath,
                   FileManager.default.fileExists(atPath: stagedPath),
                   let device = matchingDevice {
                    let lockInfo = try? await self.coreDevice.lockState(deviceIdentifier: device.coreDeviceIdentifier)
                    let isUnlocked = (lockInfo?.unlockedSinceBoot == true) && (lockInfo?.passcodeRequired == false)

                    if isUnlocked {
                        let activeCount = try await self.store.activeSlotCount(
                            forDeviceUDID: app.targetDeviceUDID,
                            excludingAppID: app.id
                        )
                        if activeCount < Self.maxActiveFreeSlots {
                            do {
                                try await self.coreDevice.installApp(
                                    deviceIdentifier: device.coreDeviceIdentifier,
                                    appBundleURL: URL(fileURLWithPath: stagedPath)
                                )
                                let refreshedExp = app.stagedProfileExpiresAt ?? now.addingTimeInterval(Self.expiryFallbackSeconds)
                                app.state = .active
                                app.lastInstalledAt = now
                                app.profileExpiresAt = refreshedExp
                                app.stagedSignedAppPath = nil
                                app.stagedProfileExpiresAt = nil
                                app.lastSyncAttemptAt = now
                                app.lastSyncError = nil
                                try? FileManager.default.removeItem(atPath: stagedPath)

                                try await self.store.upsertApp(app)
                                try await self.store.recordEvent(
                                    appID: app.id,
                                    kind: "background_sync_installed",
                                    message: "Automatically re-synced '\(app.displayName)' to device \(app.targetDeviceUDID).",
                                    succeeded: true,
                                    at: now
                                )
                                outcomes.append(
                                    AppSyncOutcome(
                                        appID: app.id,
                                        displayName: app.displayName,
                                        action: .syncedOverDevice,
                                        previousState: previousState,
                                        newState: .active,
                                        message: "Successfully re-synced '\(app.displayName)' to unlocked device.",
                                        alertEmitted: emittedAlert
                                    )
                                )
                                continue
                            } catch {
                                app.lastSyncAttemptAt = now
                                app.lastSyncError = error.localizedDescription
                                try await self.store.recordEvent(
                                    appID: app.id,
                                    kind: "background_sync_install_failed",
                                    message: "Install failed for '\(app.displayName)': \(error.localizedDescription)",
                                    succeeded: false,
                                    at: now
                                )
                            }
                        } else {
                            app.lastSyncAttemptAt = now
                            app.lastSyncError = "Active free-account slot limit (3) reached on device."
                        }
                    } else {
                        deviceWasLocked = true
                        app.lastSyncAttemptAt = now
                        app.lastSyncError = "Device reachable on Wi-Fi but locked."
                        if elapsed >= (Self.offlineStageThresholdSeconds + 86_400) || isDay6Urgent {
                            let cycleStamp = Int(app.lastInstalledAt?.timeIntervalSince1970 ?? 0)
                            let key = "\(app.id.uuidString):\(SyncAlert.Category.deviceLockedWaiting.rawValue):\(cycleStamp)"
                            if let lockAlert = try await self.emitDeduplicatedAlertIfNeeded(
                                appID: app.id,
                                category: .deviceLockedWaiting,
                                severity: .warning,
                                title: "Unlock iPhone to Finish Syncing \(app.displayName)",
                                body: "'\(app.displayName)' is re-signed and ready on your Mac, and your iPhone is reachable on Wi-Fi, but iOS blocks installation while locked. Unlock your iPhone briefly.",
                                thresholdKey: key,
                                now: now
                            ) {
                                emittedAlert = lockAlert
                                alertsEmitted.append(lockAlert)
                            }
                        }
                    }
                }

                // Phase C: Urgent / Expired State & Deduplicated Alert
                let hasStagedNow = app.stagedSignedAppPath != nil
                if isExpired {
                    app.state = .expiredOnDevice
                } else if isDay6Urgent {
                    app.state = .syncUrgent
                } else if hasStagedNow {
                    app.state = .stagedOffline
                }

                let cycleStamp = Int(app.lastInstalledAt?.timeIntervalSince1970 ?? 0)
                if isExpired {
                    let key = "\(app.id.uuidString):\(SyncAlert.Category.expiryWarning.rawValue):\(cycleStamp)"
                    if let expAlert = try await self.emitDeduplicatedAlertIfNeeded(
                        appID: app.id,
                        category: .expiryWarning,
                        severity: .critical,
                        title: "\(app.displayName) 7-Day Signature Expired",
                        body: "The 7-day Personal Team signature for '\(app.displayName)' has expired on your iPhone. Your app data on the iPhone is completely safe and untouched—unlock your iPhone on Wi-Fi or connect via USB to refresh the signature in-place.",
                        thresholdKey: key,
                        now: now
                    ) {
                        emittedAlert = expAlert
                        alertsEmitted.append(expAlert)
                    }
                } else if isDay6Urgent {
                    let key = "\(app.id.uuidString):\(SyncAlert.Category.syncUrgentDay6.rawValue):\(cycleStamp)"
                    let readinessNote = hasStagedNow
                        ? "A fresh signed build is staged on your Mac—unlock your iPhone on the same Wi-Fi network (or connect via USB) now."
                        : "Offline signing also needs attention (\(app.lastSyncError ?? "check Xcode account"))—open AppleSync and connect your iPhone."
                    if let urgentAlert = try await self.emitDeduplicatedAlertIfNeeded(
                        appID: app.id,
                        category: .syncUrgentDay6,
                        severity: .critical,
                        title: "Urgent: \(app.displayName) Expires in < 24 Hours",
                        body: "'\(app.displayName)' has reached Day 6 without completing a Wi-Fi re-sync. \(readinessNote)",
                        thresholdKey: key,
                        now: now
                    ) {
                        emittedAlert = urgentAlert
                        alertsEmitted.append(urgentAlert)
                    }
                }

                try await self.store.upsertApp(app)

                let action: AppSyncOutcome.Action
                let outcomeMessage: String
                if isExpired {
                    action = .expiredOnDevice
                    outcomeMessage = "7-day signature expired on device; app data remains intact awaiting in-place re-install."
                } else if stagingFailedError != nil && !hasStagedNow {
                    action = .stagingFailed
                    outcomeMessage = "Offline staging failed: \(app.lastSyncError ?? "unknown error")"
                } else if deviceWasLocked {
                    action = .skippedDeviceLocked
                    outcomeMessage = "Staged bundle ready, but target device is currently locked."
                } else if freshlyStagedThisCycle && matchingDevice == nil {
                    action = .stagedOfflineOnly
                    outcomeMessage = "Staged fresh 7-day bundle on Mac; awaiting device on Wi-Fi/USB."
                } else {
                    action = .skippedDeviceOffline
                    outcomeMessage = "Staged bundle ready; target device is offline."
                }

                outcomes.append(
                    AppSyncOutcome(
                        appID: app.id,
                        displayName: app.displayName,
                        action: action,
                        previousState: previousState,
                        newState: app.state,
                        message: outcomeMessage,
                        alertEmitted: emittedAlert
                    )
                )
            }

            let completedAt = self.clock()
            return SyncCycleReport(
                startedAt: startedAt,
                completedAt: completedAt,
                reachableDeviceUDIDs: reachableUDIDs,
                outcomes: outcomes,
                alertsEmitted: alertsEmitted
            )
        }
    }

    // MARK: - Internal Helpers

    private func resolveConnectedDevice(forUDID targetUDID: String) async throws -> DiscoveredDevice {
        let devices = try await coreDevice.listDevices()
        guard let matched = devices.first(where: {
            Self.isDeviceReachable($0) &&
            ($0.udid.caseInsensitiveCompare(targetUDID) == .orderedSame ||
             $0.coreDeviceIdentifier.caseInsensitiveCompare(targetUDID) == .orderedSame)
        }) else {
            throw AppleSyncError.deviceNotFound(udid: targetUDID)
        }
        return matched
    }

    private func requireUnlockedDevice(forUDID targetUDID: String) async throws -> DiscoveredDevice {
        let device = try await resolveConnectedDevice(forUDID: targetUDID)
        let lock = try await coreDevice.lockState(deviceIdentifier: device.coreDeviceIdentifier)
        guard lock.unlockedSinceBoot && !lock.passcodeRequired else {
            throw AppleSyncError.deviceLocked(udid: targetUDID)
        }
        return device
    }

    private func emitDeduplicatedAlertIfNeeded(
        appID: UUID?,
        category: SyncAlert.Category,
        severity: SyncAlert.Severity,
        title: String,
        body: String,
        thresholdKey: String,
        now: Date
    ) async throws -> SyncAlert? {
        let shouldDeliver = try await store.update { state -> Bool in
            let cutoff = now.addingTimeInterval(-Self.thresholdRetentionSeconds)
            state.notifiedThresholds = state.notifiedThresholds.filter { _, timestamp in
                timestamp >= cutoff
            }
            if state.notifiedThresholds[thresholdKey] != nil {
                return false
            }
            state.notifiedThresholds[thresholdKey] = now
            return true
        }

        guard shouldDeliver else { return nil }

        let alert = SyncAlert(
            appID: appID,
            category: category,
            severity: severity,
            title: title,
            body: body,
            thresholdKey: thresholdKey,
            createdAt: now
        )
        await notifier.deliver(alert)
        return alert
    }

    private static func isDeviceReachable(_ device: DiscoveredDevice) -> Bool {
        guard device.isPhysicaliOSDevice && device.isPaired else { return false }
        if let state = device.connectionState?.lowercased() {
            if state == "disconnected" || state == "unavailable" || state == "unpaired" {
                return false
            }
        }
        return true
    }

    private static func hasValidStagedArtifact(for app: ManagedAppRecord, at now: Date) -> Bool {
        guard let stagedPath = app.stagedSignedAppPath,
              FileManager.default.fileExists(atPath: stagedPath),
              let stagedExp = app.stagedProfileExpiresAt else {
            return false
        }
        let baseline = (app.lastInstalledAt ?? now).addingTimeInterval(offlineStageThresholdSeconds)
        return stagedExp > baseline && stagedExp > now.addingTimeInterval(offlineStageThresholdSeconds)
    }

    private static func isAuthOrProvisioningError(_ error: Error) -> Bool {
        guard let syncError = error as? AppleSyncError else { return false }
        switch syncError {
        case .signingIdentityNotFound, .provisioningFailed, .deviceNotProvisionedInProfile:
            return true
        default:
            return false
        }
    }

    private static func resolvedDisplayName(override: String?, fallback: String) -> String {
        if let trimmed = override?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty {
            return trimmed
        }
        return fallback
    }

    private static func resolveGitHeadCommit(near projectURL: URL) -> String? {
        let workingDir = projectURL.deletingLastPathComponent().path
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", workingDir, "rev-parse", "HEAD"]
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let commit = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (commit?.isEmpty == false) ? commit : nil
        } catch {
            return nil
        }
    }
}
