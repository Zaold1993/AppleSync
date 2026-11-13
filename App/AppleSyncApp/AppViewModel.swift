import AppKit
import AppleSyncCore
import Foundation
import Observation
@preconcurrency import ServiceManagement

private final class WeakViewModelBox: @unchecked Sendable {
    weak var target: AppleSyncViewModel?
}

@MainActor
@Observable
public final class AppleSyncViewModel {
    public enum MenuBarStatus: Sendable {
        case idle
        case syncing
        case paused
        case urgent
        case warning
    }

    public private(set) var apps: [ManagedAppRecord] = []
    public private(set) var devices: [DiscoveredDevice] = []
    public private(set) var teams: [TeamIdentitySummary] = []
    public private(set) var backupsByAppID: [UUID: [BackupManifest]] = [:]
    public private(set) var events: [SyncEvent] = []
    public private(set) var recentAlerts: [SyncAlert] = []
    public private(set) var lastCycleReport: SyncCycleReport?

    public var selectedDeviceUDID: String?
    public var selectedAppID: UUID?
    public private(set) var isBusy: Bool = false
    public private(set) var busyMessage: String?
    public var errorMessage: String?
    public private(set) var launchAtLoginEnabled: Bool = false
    public private(set) var isDaemonPaused: Bool = false
    public private(set) var isSchedulerRunning: Bool = false
    public private(set) var activeSingleAppSyncID: UUID?

    public let paths: AppleSyncPaths
    public let coordinator: DeviceOperationCoordinator
    public let notifier: MacNotificationDeliverer

    private var backgroundLoopTask: Task<Void, Never>?
    private var wakeObserverTask: Task<Void, Never>?
    private var currentOperationTask: Task<Bool, Never>?
    private var didStart = false

    public init(paths: AppleSyncPaths = AppleSyncPaths()) {
        self.paths = paths

        let box = WeakViewModelBox()
        let deliverer = MacNotificationDeliverer { alert in
            await MainActor.run {
                box.target?.appendAlert(alert)
            }
        }
        self.notifier = deliverer

        let runner = SystemProcessRunner()
        let coreDevice = DevicectlClient(runner: runner)
        let signing = DualSourceSigningEngine(paths: paths, runner: runner)
        let store = SyncStateStore(paths: paths)
        let backupManager = BackupAndSwapManager(
            paths: paths,
            store: store,
            coreDevice: coreDevice,
            signingEngine: signing
        )
        self.coordinator = DeviceOperationCoordinator(
            paths: paths,
            store: store,
            coreDevice: coreDevice,
            signingEngine: signing,
            backupManager: backupManager,
            notifier: deliverer
        )
        box.target = self
        self.launchAtLoginEnabled = (SMAppService.mainApp.status == .enabled)
    }

    public func startIfNeeded() {
        guard !didStart else { return }
        didStart = true

        Task { [weak self] in
            guard let self else { return }
            await self.notifier.requestPermissionsIfRunningInAppBundle()
            await self.refreshAll()
            if !self.isDaemonPaused {
                self.startBackgroundSchedulers()
                await self.runSyncCycleNow(silent: true, force: false)
            }
        }
    }

    private func startBackgroundSchedulers() {
        stopBackgroundSchedulers()
        isSchedulerRunning = true

        backgroundLoopTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15 * 60))
                guard !Task.isCancelled, let self else { break }
                if !self.isDaemonPaused {
                    await self.runSyncCycleNow(silent: true, force: false)
                }
            }
        }

        wakeObserverTask = Task { [weak self] in
            let wakeStream = NSWorkspace.shared.notificationCenter.notifications(named: NSWorkspace.didWakeNotification)
            for await _ in wakeStream {
                guard !Task.isCancelled, let self else { break }
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled, !self.isDaemonPaused else { continue }
                await self.runSyncCycleNow(silent: true, force: false)
            }
        }
    }

    private func stopBackgroundSchedulers() {
        backgroundLoopTask?.cancel()
        backgroundLoopTask = nil
        wakeObserverTask?.cancel()
        wakeObserverTask = nil
        isSchedulerRunning = false
    }

    private func appendAlert(_ alert: SyncAlert) {
        recentAlerts.insert(alert, at: 0)
        if recentAlerts.count > 25 {
            recentAlerts.removeLast(recentAlerts.count - 25)
        }
    }

    // MARK: - Computed Properties

    public var menuBarStatus: MenuBarStatus {
        if isBusy { return .syncing }
        if isDaemonPaused { return .paused }
        if apps.contains(where: { $0.state == .syncUrgent || $0.state == .expiredOnDevice }) {
            return .urgent
        }
        if apps.contains(where: { $0.state == .stagedOffline || $0.lastSyncError != nil }) {
            return .warning
        }
        return .idle
    }

    public var activeTargetUDID: String? {
        selectedDeviceUDID ?? devices.first?.udid ?? apps.first?.targetDeviceUDID
    }

    public func activeApps(forDeviceUDID udid: String?) -> [ManagedAppRecord] {
        apps.filter { app in
            (udid == nil || app.targetDeviceUDID == udid) && app.state.countsAgainstActiveSlotLimit
        }
    }

    public func frozenApps(forDeviceUDID udid: String?) -> [ManagedAppRecord] {
        apps.filter { app in
            (udid == nil || app.targetDeviceUDID == udid) && app.state == .frozen
        }
    }

    public func adHocApps(forDeviceUDID udid: String?) -> [ManagedAppRecord] {
        apps.filter { app in
            (udid == nil || app.targetDeviceUDID == udid) && app.state == .activeAdHoc
        }
    }

    public var selectedApp: ManagedAppRecord? {
        guard let selectedAppID else { return apps.first }
        return apps.first(where: { $0.id == selectedAppID }) ?? apps.first
    }

    // MARK: - Data Loading

    public func refreshAll() async {
        do {
            async let loadedApps = coordinator.listApps()
            async let loadedDevices = try? await coordinator.discoverDevices()
            async let loadedTeams = try? await coordinator.discoverSigningTeams()
            async let loadedEvents = try? await coordinator.events(limit: 80)
            async let loadedPaused = try? await coordinator.isGlobalAutoSyncPaused()

            let appsResult = try await loadedApps
            let devicesResult = (await loadedDevices) ?? []
            let teamsResult = (await loadedTeams) ?? []
            let eventsResult = (await loadedEvents) ?? []
            let pausedResult = (await loadedPaused) ?? false

            self.apps = appsResult
            self.devices = devicesResult
            self.teams = teamsResult
            self.events = eventsResult
            self.isDaemonPaused = pausedResult
            if pausedResult && isSchedulerRunning {
                stopBackgroundSchedulers()
            } else if !pausedResult && didStart && !isSchedulerRunning {
                startBackgroundSchedulers()
            }

            if self.selectedDeviceUDID == nil {
                self.selectedDeviceUDID = devicesResult.first?.udid ?? appsResult.first?.targetDeviceUDID
            }
            if self.selectedAppID == nil || !appsResult.contains(where: { $0.id == self.selectedAppID }) {
                self.selectedAppID = appsResult.first?.id
            }

            var backupsMap: [UUID: [BackupManifest]] = [:]
            for app in appsResult {
                backupsMap[app.id] = (try? await coordinator.backups(forAppID: app.id)) ?? []
            }
            self.backupsByAppID = backupsMap
        } catch {
            self.errorMessage = error.localizedDescription
        }
    }

    // MARK: - Daemon & Per-App Sync Stop / Resume Controls

    public func stopSyncDaemon() async {
        cancelCurrentSync()
        stopBackgroundSchedulers()
        do {
            try await coordinator.setGlobalAutoSyncPaused(true)
            self.isDaemonPaused = true
            await refreshAll()
        } catch {
            self.errorMessage = error.localizedDescription
        }
    }

    public func startSyncDaemon() async {
        do {
            try await coordinator.setGlobalAutoSyncPaused(false)
            self.isDaemonPaused = false
            startBackgroundSchedulers()
            await refreshAll()
        } catch {
            self.errorMessage = error.localizedDescription
        }
    }

    public func cancelCurrentSync() {
        currentOperationTask?.cancel()
    }

    public func toggleAppAutoSync(_ appID: UUID, paused: Bool) async {
        if paused && activeSingleAppSyncID == appID {
            cancelCurrentSync()
        }
        do {
            _ = try await coordinator.setAppAutoSyncPaused(appID: appID, paused: paused)
            await refreshAll()
        } catch {
            self.errorMessage = error.localizedDescription
        }
    }

    // MARK: - Coordinator Actions

    public func runSyncCycleNow(silent: Bool = false, force: Bool = true) async {
        _ = await performBoolOperation("Checking Days 4-6 Wi-Fi sync...", silent: silent) {
            let report = try await self.coordinator.runBackgroundSyncCycle(force: force)
            self.lastCycleReport = report
        }
    }

    public func syncAppNow(_ appID: UUID) async {
        await performOperation("Re-signing and syncing to device...", appID: appID) {
            _ = try await self.coordinator.syncAppNow(appID: appID)
        }
    }

    public func rebuildXcodeSnapshot(_ appID: UUID) async {
        await performOperation("Rebuilding Xcode snapshot and reinstalling...") {
            _ = try await self.coordinator.rebuildXcodeSnapshot(appID: appID, reinstallIfActive: true)
        }
    }

    public func createBackup(_ appID: UUID) async {
        await performOperation("Creating SHA-256 verified backup (Documents & Library)...") {
            _ = try await self.coordinator.createManualBackup(appID: appID)
        }
    }

    public func restoreBackup(appID: UUID, backupID: UUID) async {
        await performOperation("Verifying SHA-256 integrity, cleanly reinstalling, and restoring data...") {
            try await self.coordinator.restoreBackup(appID: appID, backupID: backupID)
        }
    }

    public func deleteBackup(_ backupID: UUID) async {
        await performOperation("Deleting backup...") {
            try await self.coordinator.deleteBackup(backupID: backupID)
        }
    }

    public func freezeApp(_ appID: UUID) async {
        await performOperation("Backing up, verifying SHA-256, and freezing app...") {
            _ = try await self.coordinator.freezeApp(appID: appID, createBackupFirst: true)
        }
    }

    public func thawApp(_ appID: UUID, backupID: UUID?) async {
        await performOperation("Thawing: re-signing, reinstalling, and restoring data...") {
            _ = try await self.coordinator.thawApp(appID: appID, restoreBackupID: backupID)
        }
    }

    public func swapApps(freezeID: UUID, thawID: UUID, restoreBackupID: UUID?) async {
        await performOperation("Two-phase swap (Backup A -> Freeze A -> Install & Restore B)...") {
            _ = try await self.coordinator.swapApps(
                freezeAppID: freezeID,
                thawAppID: thawID,
                restoreBackupIDForThaw: restoreBackupID
            )
        }
    }

    public func removeApp(_ appID: UUID, uninstall: Bool, deleteBackups: Bool) async {
        await performOperation("Removing app from AppleSync...") {
            try await self.coordinator.removeApp(
                appID: appID,
                uninstallFromDevice: uninstall,
                deleteBackups: deleteBackups
            )
        }
    }

    public func registerXcodeApp(
        projectPath: String,
        scheme: String?,
        configuration: String,
        stripExtensions: Bool = true,
        teamID: String,
        deviceUDID: String,
        displayNameOverride: String?,
        installImmediately: Bool
    ) async -> Bool {
        await performBoolOperation("Building Xcode snapshot, signing, and installing...") {
            let record = try await self.coordinator.registerXcodeApp(
                projectOrWorkspacePath: projectPath,
                scheme: scheme,
                configuration: configuration,
                stripExtensions: stripExtensions,
                teamID: teamID,
                targetDeviceUDID: deviceUDID,
                displayNameOverride: displayNameOverride,
                installImmediately: installImmediately
            )
            self.selectedAppID = record.id
        }
    }

    public func registerIPAApp(
        ipaPath: String,
        teamID: String,
        deviceUDID: String,
        stripExtensions: Bool,
        preferOriginalAdHocIfValid: Bool,
        displayNameOverride: String?,
        installImmediately: Bool
    ) async -> Bool {
        await performBoolOperation("Inspecting IPA, signing with Xcode account, and installing...") {
            let record = try await self.coordinator.registerIPAApp(
                ipaPath: ipaPath,
                teamID: teamID,
                targetDeviceUDID: deviceUDID,
                stripExtensions: stripExtensions,
                preferOriginalAdHocIfValid: preferOriginalAdHocIfValid,
                displayNameOverride: displayNameOverride,
                installImmediately: installImmediately
            )
            self.selectedAppID = record.id
        }
    }

    public func toggleLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            let status = SMAppService.mainApp.status
            self.launchAtLoginEnabled = (status == .enabled)
            if enabled && status == .requiresApproval {
                self.errorMessage = "Approve AppleSync under System Settings > General > Login Items to finish enabling Launch at Login."
            }
        } catch {
            self.errorMessage = "Unable to update Launch at Login (make sure AppleSync.app is in /Applications): \(error.localizedDescription)"
            self.launchAtLoginEnabled = (SMAppService.mainApp.status == .enabled)
        }
    }

    private func performOperation(_ label: String, appID: UUID? = nil, _ work: @escaping () async throws -> Void) async {
        _ = await performBoolOperation(label, appID: appID, work)
    }

    private func performBoolOperation(
        _ label: String,
        appID: UUID? = nil,
        silent: Bool = false,
        _ work: @escaping () async throws -> Void
    ) async -> Bool {
        guard !isBusy else {
            if !silent {
                self.errorMessage = "Another operation is already in progress. Please wait or click Stop."
            }
            return false
        }
        isBusy = true
        busyMessage = label
        activeSingleAppSyncID = appID
        defer {
            isBusy = false
            busyMessage = nil
            activeSingleAppSyncID = nil
            currentOperationTask = nil
        }

        let task = Task<Bool, Never> { @MainActor in
            do {
                try await work()
                await self.refreshAll()
                return true
            } catch is CancellationError {
                await self.refreshAll()
                return false
            } catch {
                if !silent {
                    self.errorMessage = error.localizedDescription
                }
                await self.refreshAll()
                return false
            }
        }
        currentOperationTask = task
        return await task.value
    }
}
