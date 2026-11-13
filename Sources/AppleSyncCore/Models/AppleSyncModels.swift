import Foundation
import CryptoKit

public enum AppSource: Codable, Sendable, Equatable {
    case xcodeProject(
        projectOrWorkspacePath: String,
        scheme: String,
        configuration: String,
        pinnedSnapshotCommit: String?
    )
    case externalIPA(
        originalIPAPath: String,
        originalBundleID: String,
        stripExtensions: Bool,
        useOriginalAdHocIfValid: Bool
    )
}

public enum AppLifecycleState: String, Codable, Sendable, Equatable, CaseIterable {
    case active
    case stagedOffline
    case syncUrgent
    case expiredOnDevice
    case frozen
    case activeAdHoc

    public var countsAgainstActiveSlotLimit: Bool {
        switch self {
        case .active, .stagedOffline, .syncUrgent:
            return true
        case .expiredOnDevice, .frozen, .activeAdHoc:
            return false
        }
    }
}

public struct ManagedAppRecord: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    public var displayName: String
    public var originalBundleID: String
    public var effectiveBundleID: String
    public var teamID: String
    public var targetDeviceUDID: String
    public var source: AppSource
    public var state: AppLifecycleState
    public var cachedBaseAppPath: String
    public var stagedSignedAppPath: String?
    public var lastInstalledAt: Date?
    public var profileExpiresAt: Date?
    public var stagedProfileExpiresAt: Date?
    public var lastBackupID: UUID?
    public var lastSyncAttemptAt: Date?
    public var lastSyncError: String?
    public var appVersion: String
    public var buildVersion: String
    public var autoSyncPaused: Bool
    public var stripEmbeddedExtensions: Bool

    public init(
        id: UUID = UUID(),
        displayName: String,
        originalBundleID: String,
        effectiveBundleID: String,
        teamID: String,
        targetDeviceUDID: String,
        source: AppSource,
        state: AppLifecycleState,
        cachedBaseAppPath: String,
        stagedSignedAppPath: String? = nil,
        lastInstalledAt: Date? = nil,
        profileExpiresAt: Date? = nil,
        stagedProfileExpiresAt: Date? = nil,
        lastBackupID: UUID? = nil,
        lastSyncAttemptAt: Date? = nil,
        lastSyncError: String? = nil,
        appVersion: String = "1.0",
        buildVersion: String = "1",
        autoSyncPaused: Bool = false,
        stripEmbeddedExtensions: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.originalBundleID = originalBundleID
        self.effectiveBundleID = effectiveBundleID
        self.teamID = teamID
        self.targetDeviceUDID = targetDeviceUDID
        self.source = source
        self.state = state
        self.cachedBaseAppPath = cachedBaseAppPath
        self.stagedSignedAppPath = stagedSignedAppPath
        self.lastInstalledAt = lastInstalledAt
        self.profileExpiresAt = profileExpiresAt
        self.stagedProfileExpiresAt = stagedProfileExpiresAt
        self.lastBackupID = lastBackupID
        self.lastSyncAttemptAt = lastSyncAttemptAt
        self.lastSyncError = lastSyncError
        self.appVersion = appVersion
        self.buildVersion = buildVersion
        self.autoSyncPaused = autoSyncPaused
        self.stripEmbeddedExtensions = stripEmbeddedExtensions
    }

    private enum CodingKeys: String, CodingKey {
        case id, displayName, originalBundleID, effectiveBundleID, teamID, targetDeviceUDID
        case source, state, cachedBaseAppPath, stagedSignedAppPath
        case lastInstalledAt, profileExpiresAt, stagedProfileExpiresAt
        case lastBackupID, lastSyncAttemptAt, lastSyncError
        case appVersion, buildVersion, autoSyncPaused, stripEmbeddedExtensions
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        displayName = try c.decode(String.self, forKey: .displayName)
        originalBundleID = try c.decode(String.self, forKey: .originalBundleID)
        effectiveBundleID = try c.decode(String.self, forKey: .effectiveBundleID)
        teamID = try c.decode(String.self, forKey: .teamID)
        targetDeviceUDID = try c.decode(String.self, forKey: .targetDeviceUDID)
        source = try c.decode(AppSource.self, forKey: .source)
        state = try c.decode(AppLifecycleState.self, forKey: .state)
        cachedBaseAppPath = try c.decode(String.self, forKey: .cachedBaseAppPath)
        stagedSignedAppPath = try c.decodeIfPresent(String.self, forKey: .stagedSignedAppPath)
        lastInstalledAt = try c.decodeIfPresent(Date.self, forKey: .lastInstalledAt)
        profileExpiresAt = try c.decodeIfPresent(Date.self, forKey: .profileExpiresAt)
        stagedProfileExpiresAt = try c.decodeIfPresent(Date.self, forKey: .stagedProfileExpiresAt)
        lastBackupID = try c.decodeIfPresent(UUID.self, forKey: .lastBackupID)
        lastSyncAttemptAt = try c.decodeIfPresent(Date.self, forKey: .lastSyncAttemptAt)
        lastSyncError = try c.decodeIfPresent(String.self, forKey: .lastSyncError)
        appVersion = try c.decodeIfPresent(String.self, forKey: .appVersion) ?? "1.0"
        buildVersion = try c.decodeIfPresent(String.self, forKey: .buildVersion) ?? "1"
        autoSyncPaused = try c.decodeIfPresent(Bool.self, forKey: .autoSyncPaused) ?? false
        stripEmbeddedExtensions = try c.decodeIfPresent(Bool.self, forKey: .stripEmbeddedExtensions) ?? false
    }

    public var shouldStripNestedExtensions: Bool {
        if case .externalIPA(_, _, let strip, _) = source {
            return strip || stripEmbeddedExtensions
        }
        return stripEmbeddedExtensions
    }

    public func remainingValiditySeconds(at now: Date = Date()) -> TimeInterval? {
        guard let profileExpiresAt else { return nil }
        return profileExpiresAt.timeIntervalSince(now)
    }

    public func daysSinceInstall(at now: Date = Date()) -> Double? {
        guard let lastInstalledAt else { return nil }
        return now.timeIntervalSince(lastInstalledAt) / 86_400.0
    }
}

public enum BackupTrigger: String, Codable, Sendable, Equatable {
    case manual
    case preFreeze
    case preSwap
    case preSync
}

public struct BackupManifest: Codable, Sendable, Identifiable, Equatable {
    public var backupID: UUID
    public var id: UUID { backupID }
    public var appID: UUID
    public var effectiveBundleID: String
    public var deviceUDID: String
    public var createdAt: Date
    public var appVersion: String
    public var trigger: BackupTrigger
    public var sizeBytes: UInt64
    public var fileCount: Int
    public var sha256Digest: String
    public var archiveRelativePath: String

    public init(
        backupID: UUID = UUID(),
        appID: UUID,
        effectiveBundleID: String,
        deviceUDID: String,
        createdAt: Date = Date(),
        appVersion: String,
        trigger: BackupTrigger,
        sizeBytes: UInt64,
        fileCount: Int,
        sha256Digest: String,
        archiveRelativePath: String
    ) {
        self.backupID = backupID
        self.appID = appID
        self.effectiveBundleID = effectiveBundleID
        self.deviceUDID = deviceUDID
        self.createdAt = createdAt
        self.appVersion = appVersion
        self.trigger = trigger
        self.sizeBytes = sizeBytes
        self.fileCount = fileCount
        self.sha256Digest = sha256Digest
        self.archiveRelativePath = archiveRelativePath
    }
}

public struct SyncEvent: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    public var timestamp: Date
    public var appID: UUID?
    public var kind: String
    public var message: String
    public var succeeded: Bool

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        appID: UUID? = nil,
        kind: String,
        message: String,
        succeeded: Bool
    ) {
        self.id = id
        self.timestamp = timestamp
        self.appID = appID
        self.kind = kind
        self.message = message
        self.succeeded = succeeded
    }
}

public struct SyncStoreState: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var apps: [ManagedAppRecord]
    public var backups: [BackupManifest]
    public var events: [SyncEvent]
    public var notifiedThresholds: [String: Date]
    public var autoSyncGlobalPaused: Bool

    public init(
        schemaVersion: Int = 1,
        apps: [ManagedAppRecord] = [],
        backups: [BackupManifest] = [],
        events: [SyncEvent] = [],
        notifiedThresholds: [String: Date] = [:],
        autoSyncGlobalPaused: Bool = false
    ) {
        self.schemaVersion = schemaVersion
        self.apps = apps
        self.backups = backups
        self.events = events
        self.notifiedThresholds = notifiedThresholds
        self.autoSyncGlobalPaused = autoSyncGlobalPaused
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, apps, backups, events, notifiedThresholds, autoSyncGlobalPaused
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        apps = try c.decodeIfPresent([ManagedAppRecord].self, forKey: .apps) ?? []
        backups = try c.decodeIfPresent([BackupManifest].self, forKey: .backups) ?? []
        events = try c.decodeIfPresent([SyncEvent].self, forKey: .events) ?? []
        notifiedThresholds = try c.decodeIfPresent([String: Date].self, forKey: .notifiedThresholds) ?? [:]
        autoSyncGlobalPaused = try c.decodeIfPresent(Bool.self, forKey: .autoSyncGlobalPaused) ?? false
    }
}

public struct TeamIdentitySummary: Codable, Sendable, Equatable, Identifiable {
    public var id: String { sha1Fingerprint }
    public var teamID: String
    public var commonName: String
    public var sha1Fingerprint: String

    public init(teamID: String, commonName: String, sha1Fingerprint: String) {
        self.teamID = teamID
        self.commonName = commonName
        self.sha1Fingerprint = sha1Fingerprint
    }
}

public struct DiscoveredDevice: Codable, Sendable, Equatable, Identifiable {
    public var id: String { coreDeviceIdentifier }
    public var coreDeviceIdentifier: String
    public var udid: String
    public var marketingName: String
    public var platform: String
    public var reality: String
    public var pairingState: String
    public var transportType: String?
    public var connectionState: String?

    public init(
        coreDeviceIdentifier: String,
        udid: String,
        marketingName: String,
        platform: String,
        reality: String,
        pairingState: String,
        transportType: String?,
        connectionState: String?
    ) {
        self.coreDeviceIdentifier = coreDeviceIdentifier
        self.udid = udid
        self.marketingName = marketingName
        self.platform = platform
        self.reality = reality
        self.pairingState = pairingState
        self.transportType = transportType
        self.connectionState = connectionState
    }

    public var isPhysicaliOSDevice: Bool {
        platform.localizedCaseInsensitiveContains("iOS") && reality.lowercased() == "physical"
    }

    public var isPaired: Bool {
        pairingState.lowercased() == "paired"
    }
}

public struct LockStateInfo: Codable, Sendable, Equatable {
    public var deviceIdentifier: String
    public var passcodeRequired: Bool
    public var unlockedSinceBoot: Bool

    public init(deviceIdentifier: String, passcodeRequired: Bool, unlockedSinceBoot: Bool) {
        self.deviceIdentifier = deviceIdentifier
        self.passcodeRequired = passcodeRequired
        self.unlockedSinceBoot = unlockedSinceBoot
    }
}

public struct InstalledDeviceApp: Codable, Sendable, Equatable {
    public var bundleIdentifier: String
    public var name: String
    public var version: String
    public var bundleVersion: String
    public var builtByDeveloper: Bool
    public var containerAccessible: Bool
    public var removable: Bool
    public var url: String?

    public init(
        bundleIdentifier: String,
        name: String,
        version: String,
        bundleVersion: String,
        builtByDeveloper: Bool,
        containerAccessible: Bool,
        removable: Bool,
        url: String?
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.name = name
        self.version = version
        self.bundleVersion = bundleVersion
        self.builtByDeveloper = builtByDeveloper
        self.containerAccessible = containerAccessible
        self.removable = removable
        self.url = url
    }
}

public struct RunningDeviceProcess: Codable, Sendable, Equatable {
    public var processIdentifier: Int
    public var executable: String

    public init(processIdentifier: Int, executable: String) {
        self.processIdentifier = processIdentifier
        self.executable = executable
    }
}

public struct XcodeProjectInspection: Codable, Sendable, Equatable {
    public var projectPath: String
    public var isWorkspace: Bool
    public var schemes: [String]
    public var selectedScheme: String
    public var configurations: [String]
    public var selectedConfiguration: String
    public var bundleIdentifier: String
    public var displayName: String
    public var developmentTeam: String?
    public var marketingVersion: String
    public var buildVersion: String

    public init(
        projectPath: String,
        isWorkspace: Bool,
        schemes: [String],
        selectedScheme: String,
        configurations: [String] = ["Release", "Debug"],
        selectedConfiguration: String = "Release",
        bundleIdentifier: String,
        displayName: String,
        developmentTeam: String?,
        marketingVersion: String,
        buildVersion: String
    ) {
        self.projectPath = projectPath
        self.isWorkspace = isWorkspace
        self.schemes = schemes
        self.selectedScheme = selectedScheme
        self.configurations = configurations
        self.selectedConfiguration = selectedConfiguration
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
        self.developmentTeam = developmentTeam
        self.marketingVersion = marketingVersion
        self.buildVersion = buildVersion
    }
}

public struct IPAInspectionReport: Codable, Sendable, Equatable {
    public var ipaPath: String
    public var bundleIdentifier: String
    public var displayName: String
    public var executableName: String
    public var marketingVersion: String
    public var buildVersion: String
    public var isFairPlayEncrypted: Bool
    public var supportsArm64iOS: Bool
    public var nestedExtensions: [String]
    public var embeddedProfileExpiration: Date?
    public var embeddedProfileProvisionedUDIDs: [String]
    public var canInstallUntouchedForTargetDevice: Bool

    public init(
        ipaPath: String,
        bundleIdentifier: String,
        displayName: String,
        executableName: String,
        marketingVersion: String,
        buildVersion: String,
        isFairPlayEncrypted: Bool,
        supportsArm64iOS: Bool,
        nestedExtensions: [String],
        embeddedProfileExpiration: Date?,
        embeddedProfileProvisionedUDIDs: [String],
        canInstallUntouchedForTargetDevice: Bool
    ) {
        self.ipaPath = ipaPath
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
        self.executableName = executableName
        self.marketingVersion = marketingVersion
        self.buildVersion = buildVersion
        self.isFairPlayEncrypted = isFairPlayEncrypted
        self.supportsArm64iOS = supportsArm64iOS
        self.nestedExtensions = nestedExtensions
        self.embeddedProfileExpiration = embeddedProfileExpiration
        self.embeddedProfileProvisionedUDIDs = embeddedProfileProvisionedUDIDs
        self.canInstallUntouchedForTargetDevice = canInstallUntouchedForTargetDevice
    }
}

public struct SignedArtifactMetadata: Codable, Sendable, Equatable {
    public var stagedAppPath: String
    public var effectiveBundleID: String
    public var teamID: String
    public var profileExpirationDate: Date
    public var provisionedUDIDs: [String]
    public var usedUntouchedEmbeddedProfile: Bool

    public init(
        stagedAppPath: String,
        effectiveBundleID: String,
        teamID: String,
        profileExpirationDate: Date,
        provisionedUDIDs: [String],
        usedUntouchedEmbeddedProfile: Bool
    ) {
        self.stagedAppPath = stagedAppPath
        self.effectiveBundleID = effectiveBundleID
        self.teamID = teamID
        self.profileExpirationDate = profileExpirationDate
        self.provisionedUDIDs = provisionedUDIDs
        self.usedUntouchedEmbeddedProfile = usedUntouchedEmbeddedProfile
    }
}

public enum EffectiveBundleID {
    public static func make(teamID: String, originalBundleID: String) -> String {
        let cleanTeam = sanitizeSegment(teamID.lowercased(), fallback: "team")
        let slug = sanitizeSegment(originalBundleID.lowercased(), fallback: "app")
        let digest = SHA256.hash(data: Data(originalBundleID.utf8))
        let shortHash = digest.prefix(3).map { String(format: "%02x", $0) }.joined()
        return "com.applesync.\(cleanTeam).\(slug)-\(shortHash)"
    }

    private static func sanitizeSegment(_ raw: String, fallback: String) -> String {
        let mapped = raw.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) {
                return Character(scalar)
            }
            return "-"
        }
        let collapsed = String(mapped)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        let trimmed = String(collapsed.prefix(36))
        return trimmed.isEmpty ? fallback : trimmed
    }
}

public struct AppleSyncPaths: Sendable, Equatable {
    public let rootURL: URL

    public init(rootURL: URL? = nil) {
        if let rootURL {
            self.rootURL = rootURL
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
            self.rootURL = appSupport.appendingPathComponent("AppleSync", isDirectory: true)
        }
    }

    public var stateFileURL: URL {
        rootURL.appendingPathComponent("state.json", isDirectory: false)
    }

    public var lockFileURL: URL {
        rootURL.appendingPathComponent("sync.lock", isDirectory: false)
    }

    public var provisioningProxyDirectoryURL: URL {
        rootURL.appendingPathComponent("ProvisioningProxy", isDirectory: true)
    }

    public var artifactsDirectoryURL: URL {
        rootURL.appendingPathComponent("Artifacts", isDirectory: true)
    }

    public var backupsDirectoryURL: URL {
        rootURL.appendingPathComponent("Backups", isDirectory: true)
    }

    public var logsDirectoryURL: URL {
        rootURL.appendingPathComponent("Logs", isDirectory: true)
    }

    public func artifactDirectory(for appID: UUID) -> URL {
        artifactsDirectoryURL.appendingPathComponent(appID.uuidString, isDirectory: true)
    }

    public func baseAppDirectory(for appID: UUID) -> URL {
        artifactDirectory(for: appID).appendingPathComponent("base", isDirectory: true)
    }

    public func stagedAppDirectory(for appID: UUID) -> URL {
        artifactDirectory(for: appID).appendingPathComponent("staged", isDirectory: true)
    }

    public func backupDirectory(for effectiveBundleID: String, backupID: UUID) -> URL {
        backupsDirectoryURL
            .appendingPathComponent(effectiveBundleID, isDirectory: true)
            .appendingPathComponent(backupID.uuidString, isDirectory: true)
    }

    public func ensureDirectoriesExist() throws {
        let fm = FileManager.default
        for dir in [
            rootURL,
            provisioningProxyDirectoryURL,
            artifactsDirectoryURL,
            backupsDirectoryURL,
            logsDirectoryURL
        ] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}

public enum AppleSyncError: LocalizedError, Sendable, Equatable {
    case invalidInput(String)
    case encryptedIPAUnsupported(String)
    case unsupportedArchitecture(String)
    case signingIdentityNotFound(teamID: String)
    case provisioningFailed(String)
    case deviceNotProvisionedInProfile(udid: String, teamID: String)
    case codesignFailed(String)
    case deviceNotFound(udid: String)
    case deviceLocked(udid: String)
    case activeSlotLimitReached(deviceUDID: String, currentActiveCount: Int)
    case backupVerificationFailed(String)
    case appNotFound(UUID)
    case commandFailed(executable: String, exitCode: Int32, stderr: String)

    public var errorDescription: String? {
        switch self {
        case .invalidInput(let msg):
            return msg
        case .encryptedIPAUnsupported(let path):
            return "IPA at '\(path)' contains a FairPlay-encrypted binary (cryptid=1) from the App Store and cannot be re-signed."
        case .unsupportedArchitecture(let detail):
            return "Binary does not support physical arm64 iOS devices: \(detail)"
        case .signingIdentityNotFound(let teamID):
            return "No valid (non-revoked) Apple Development certificate found in Keychain for Team ID '\(teamID)'."
        case .provisioningFailed(let detail):
            return "Failed to generate or decode provisioning profile: \(detail)"
        case .deviceNotProvisionedInProfile(let udid, let teamID):
            return "Provisioning profile for team '\(teamID)' does not include device UDID '\(udid)'. Connect your iPhone via USB once and let Xcode register the device."
        case .codesignFailed(let detail):
            return "Code signing failed: \(detail)"
        case .deviceNotFound(let udid):
            return "Target iOS device '\(udid)' is not currently visible to CoreDevice."
        case .deviceLocked(let udid):
            return "Device '\(udid)' has not been unlocked since boot or requires passcode unlock."
        case .activeSlotLimitReached(let deviceUDID, let count):
            return "Device '\(deviceUDID)' already has \(count) active free-account apps (limit is 3). Freeze or swap an existing app first."
        case .backupVerificationFailed(let reason):
            return "Container backup verification failed (aborting destructive operation): \(reason)"
        case .appNotFound(let id):
            return "Managed app '\(id.uuidString)' was not found in state store."
        case .commandFailed(let executable, let code, let stderr):
            return "Command '\(executable)' failed with exit code \(code): \(stderr)"
        }
    }
}
