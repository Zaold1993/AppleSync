import Foundation
import Darwin

public actor SyncStateStore {
    public let paths: AppleSyncPaths
    public let maxEventsCount: Int

    private var stateLockURL: URL {
        paths.rootURL.appendingPathComponent("state.lock", isDirectory: false)
    }

    public init(paths: AppleSyncPaths = AppleSyncPaths(), maxEventsCount: Int = 500) {
        self.paths = paths
        self.maxEventsCount = max(10, maxEventsCount)
    }

    // MARK: - Core Atomic Read / Write

    public func load() throws -> SyncStoreState {
        try paths.ensureDirectoriesExist()
        return try withStateFileLock {
            try readStateUnlocked()
        }
    }

    @discardableResult
    public func update<R: Sendable>(
        _ transform: @Sendable (inout SyncStoreState) throws -> R
    ) throws -> R {
        try paths.ensureDirectoriesExist()
        return try withStateFileLock {
            var state = try readStateUnlocked()
            let result = try transform(&state)
            trimEventsIfNeeded(&state)
            try writeStateUnlocked(state)
            return result
        }
    }

    // MARK: - App Queries & Mutations

    public func allApps() throws -> [ManagedAppRecord] {
        try load().apps
    }

    public func app(id: UUID) throws -> ManagedAppRecord? {
        try load().apps.first(where: { $0.id == id })
    }

    public func apps(forDeviceUDID deviceUDID: String) throws -> [ManagedAppRecord] {
        try load().apps.filter { $0.targetDeviceUDID == deviceUDID }
    }

    public func activeSlotCount(
        forDeviceUDID deviceUDID: String,
        excludingAppID: UUID? = nil
    ) throws -> Int {
        let currentApps = try load().apps
        return currentApps.filter { app in
            guard app.targetDeviceUDID == deviceUDID else { return false }
            if let excludingAppID, app.id == excludingAppID {
                return false
            }
            return app.state.countsAgainstActiveSlotLimit
        }.count
    }

    public func upsertApp(_ record: ManagedAppRecord) throws {
        try update { state in
            if let idx = state.apps.firstIndex(where: { $0.id == record.id }) {
                state.apps[idx] = record
            } else {
                state.apps.append(record)
            }
        }
    }

    public func removeApp(id: UUID) throws {
        try update { state in
            state.apps.removeAll { $0.id == id }
        }
    }

    public func isGlobalAutoSyncPaused() throws -> Bool {
        try load().autoSyncGlobalPaused
    }

    public func setGlobalAutoSyncPaused(_ paused: Bool) throws {
        try update { state in
            state.autoSyncGlobalPaused = paused
        }
    }

    public func setAppAutoSyncPaused(appID: UUID, paused: Bool) throws -> ManagedAppRecord {
        try update { state in
            guard let idx = state.apps.firstIndex(where: { $0.id == appID }) else {
                throw AppleSyncError.appNotFound(appID)
            }
            state.apps[idx].autoSyncPaused = paused
            return state.apps[idx]
        }
    }

    // MARK: - Backup Queries & Mutations

    public func backups(forAppID appID: UUID) throws -> [BackupManifest] {
        try load().backups
            .filter { $0.appID == appID }
            .sorted { $0.createdAt > $1.createdAt }
    }

    public func backup(id: UUID) throws -> BackupManifest? {
        try load().backups.first(where: { $0.backupID == id })
    }

    public func addBackup(_ manifest: BackupManifest, updateAppLastBackup: Bool = true) throws {
        try update { state in
            if let idx = state.backups.firstIndex(where: { $0.backupID == manifest.backupID }) {
                state.backups[idx] = manifest
            } else {
                state.backups.append(manifest)
            }

            if updateAppLastBackup,
               let appIdx = state.apps.firstIndex(where: { $0.id == manifest.appID }) {
                state.apps[appIdx].lastBackupID = manifest.backupID
            }
        }
    }

    public func removeBackup(id: UUID) throws {
        try update { state in
            state.backups.removeAll { $0.backupID == id }
            for idx in state.apps.indices where state.apps[idx].lastBackupID == id {
                let appID = state.apps[idx].id
                let fallback = state.backups
                    .filter { $0.appID == appID }
                    .sorted { $0.createdAt > $1.createdAt }
                    .first?.backupID
                state.apps[idx].lastBackupID = fallback
            }
        }
    }

    // MARK: - Events & Thresholds

    public func recordEvent(
        appID: UUID? = nil,
        kind: String,
        message: String,
        succeeded: Bool,
        at timestamp: Date = Date()
    ) throws {
        let event = SyncEvent(
            timestamp: timestamp,
            appID: appID,
            kind: kind,
            message: message,
            succeeded: succeeded
        )
        try update { state in
            state.events.append(event)
        }
    }

    public func events(limit: Int? = nil) throws -> [SyncEvent] {
        let sorted = try load().events.sorted { $0.timestamp > $1.timestamp }
        if let limit, limit > 0 {
            return Array(sorted.prefix(limit))
        }
        return sorted
    }

    // MARK: - Private Unlocked File IO & Dedicated State Lock

    private func readStateUnlocked() throws -> SyncStoreState {
        let fm = FileManager.default
        let url = paths.stateFileURL
        guard fm.fileExists(atPath: url.path) else {
            return SyncStoreState()
        }

        let data = try Data(contentsOf: url)
        if data.isEmpty {
            return SyncStoreState()
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(SyncStoreState.self, from: data)
    }

    private func writeStateUnlocked(_ state: SyncStoreState) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(state)
        try data.write(to: paths.stateFileURL, options: [.atomic])
    }

    private func trimEventsIfNeeded(_ state: inout SyncStoreState) {
        if state.events.count > maxEventsCount {
            let overflow = state.events.count - maxEventsCount
            state.events.removeFirst(overflow)
        }
    }

    /// Acquires an exclusive POSIX flock on `state.lock` (distinct from `sync.lock`)
    /// so callers holding the outer daemon/device lock never deadlock when mutating state.
    private func withStateFileLock<R>(_ body: () throws -> R) throws -> R {
        let fd = open(stateLockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else {
            throw AppleSyncError.invalidInput("Unable to open state lock file at \(stateLockURL.path)")
        }
        defer {
            _ = flock(fd, LOCK_UN)
            _ = close(fd)
        }

        if flock(fd, LOCK_EX) != 0 {
            throw AppleSyncError.invalidInput("Unable to acquire exclusive flock on \(stateLockURL.path)")
        }

        return try body()
    }
}
