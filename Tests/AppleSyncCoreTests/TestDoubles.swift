import Foundation
@testable import AppleSyncCore

actor MockCoreDeviceService: CoreDeviceServicing {
    enum RecordedCall: Sendable, Equatable {
        case listDevices
        case lockState(String)
        case installedApps(String)
        case runningProcesses(String)
        case terminateProcess(String, Int, Bool)
        case installApp(String, String)
        case uninstallApp(String, String)
        case copyFromContainer(String, String, String, String)
        case copyToContainer(String, String, String, String, Bool)
    }

    var devices: [DiscoveredDevice] = []
    var lockStateResult = LockStateInfo(
        deviceIdentifier: "CORE-1",
        passcodeRequired: false,
        unlockedSinceBoot: true
    )
    var installedAppsList: [InstalledDeviceApp] = []
    var runningProcessesList: [RunningDeviceProcess] = []
    var calls: [RecordedCall] = []

    var shouldThrowOnListDevices: Error?
    var shouldThrowOnCopyFromContainer: Error?
    var shouldThrowOnInstallApp: Error?
    var shouldThrowOnUninstallApp: Error?
    var sampleContainerFiles: [String: Data] = [
        "Documents/user.json": Data("{\"score\":42}".utf8),
        "Documents/Notes/entry.txt": Data("hello world".utf8),
        "Library/Preferences/prefs.plist": Data("plist-bytes".utf8),
        "Library/SplashBoard/cache.bin": Data("ignore-me".utf8),
        "tmp/scratch.tmp": Data("ignore-tmp".utf8)
    ]

    func setDevices(_ newDevices: [DiscoveredDevice]) {
        self.devices = newDevices
    }

    func setLockState(_ state: LockStateInfo) {
        self.lockStateResult = state
    }

    func setInstalledApps(_ apps: [InstalledDeviceApp]) {
        self.installedAppsList = apps
    }

    func setRunningProcesses(_ procs: [RunningDeviceProcess]) {
        self.runningProcessesList = procs
    }

    func setErrors(
        listDevices: Error? = nil,
        copyFrom: Error? = nil,
        install: Error? = nil,
        uninstall: Error? = nil
    ) {
        self.shouldThrowOnListDevices = listDevices
        self.shouldThrowOnCopyFromContainer = copyFrom
        self.shouldThrowOnInstallApp = install
        self.shouldThrowOnUninstallApp = uninstall
    }

    func recordedCalls() -> [RecordedCall] {
        calls
    }

    func clearCalls() {
        calls.removeAll()
    }

    func listDevices() async throws -> [DiscoveredDevice] {
        calls.append(.listDevices)
        if let err = shouldThrowOnListDevices { throw err }
        return devices
    }

    func lockState(deviceIdentifier: String) async throws -> LockStateInfo {
        calls.append(.lockState(deviceIdentifier))
        return lockStateResult
    }

    func installedApps(deviceIdentifier: String) async throws -> [InstalledDeviceApp] {
        calls.append(.installedApps(deviceIdentifier))
        return installedAppsList
    }

    func runningProcesses(deviceIdentifier: String) async throws -> [RunningDeviceProcess] {
        calls.append(.runningProcesses(deviceIdentifier))
        return runningProcessesList
    }

    func terminateProcess(deviceIdentifier: String, pid: Int, kill: Bool) async throws {
        calls.append(.terminateProcess(deviceIdentifier, pid, kill))
        runningProcessesList.removeAll { $0.processIdentifier == pid }
    }

    func installApp(deviceIdentifier: String, appBundleURL: URL) async throws {
        calls.append(.installApp(deviceIdentifier, appBundleURL.path))
        if let err = shouldThrowOnInstallApp { throw err }
    }

    func uninstallApp(deviceIdentifier: String, bundleIdentifier: String) async throws {
        calls.append(.uninstallApp(deviceIdentifier, bundleIdentifier))
        if let err = shouldThrowOnUninstallApp { throw err }
        installedAppsList.removeAll { $0.bundleIdentifier == bundleIdentifier }
    }

    func copyFromContainer(
        deviceIdentifier: String,
        bundleIdentifier: String,
        remoteSourceSubpath: String,
        localDestinationURL: URL
    ) async throws {
        calls.append(.copyFromContainer(deviceIdentifier, bundleIdentifier, remoteSourceSubpath, localDestinationURL.path))
        if let err = shouldThrowOnCopyFromContainer { throw err }

        let fm = FileManager.default
        for (relPath, content) in sampleContainerFiles {
            let dest = localDestinationURL.appendingPathComponent(relPath, isDirectory: false)
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: dest)
        }
    }

    func copyToContainer(
        deviceIdentifier: String,
        bundleIdentifier: String,
        localSourceURL: URL,
        remoteDestinationSubpath: String,
        removeExistingContent: Bool
    ) async throws {
        calls.append(.copyToContainer(deviceIdentifier, bundleIdentifier, localSourceURL.path, remoteDestinationSubpath, removeExistingContent))
    }
}

actor MockSigningService: SigningServicing {
    var paths: AppleSyncPaths
    var teams: [TeamIdentitySummary] = [
        TeamIdentitySummary(teamID: "TEAM123AAA", commonName: "Apple Development: Test User (TEAM123AAA)", sha1Fingerprint: "SHA1")
    ]
    var stageCallCount = 0
    var importCallCount = 0
    var stageError: Error?
    var clock: @Sendable () -> Date
    var inspectXcodeResult: XcodeProjectInspection?
    var inspectIPAResult: IPAInspectionReport?

    init(paths: AppleSyncPaths, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.paths = paths
        self.clock = clock
    }

    func setStageError(_ err: Error?) {
        self.stageError = err
    }

    func setInspectResults(xcode: XcodeProjectInspection? = nil, ipa: IPAInspectionReport? = nil) {
        self.inspectXcodeResult = xcode
        self.inspectIPAResult = ipa
    }

    func counts() -> (imports: Int, stages: Int) {
        (importCallCount, stageCallCount)
    }

    func discoverSigningTeams() async throws -> [TeamIdentitySummary] {
        teams
    }

    func inspectXcodeProject(
        at projectURL: URL,
        preferredScheme: String?,
        configuration: String
    ) async throws -> XcodeProjectInspection {
        if let inspectXcodeResult { return inspectXcodeResult }
        return XcodeProjectInspection(
            projectPath: projectURL.path,
            isWorkspace: false,
            schemes: ["DemoApp"],
            selectedScheme: preferredScheme ?? "DemoApp",
            configurations: ["Release", "Debug"],
            selectedConfiguration: configuration,
            bundleIdentifier: "com.test.DemoApp",
            displayName: "DemoApp",
            developmentTeam: "TEAM123AAA",
            marketingVersion: "1.0",
            buildVersion: "1"
        )
    }

    func inspectIPA(at ipaURL: URL, targetDeviceUDID: String) async throws -> IPAInspectionReport {
        if let inspectIPAResult { return inspectIPAResult }
        return IPAInspectionReport(
            ipaPath: ipaURL.path,
            bundleIdentifier: "com.friend.SampleIPA",
            displayName: "SampleIPA",
            executableName: "SampleIPA",
            marketingVersion: "1.2",
            buildVersion: "5",
            isFairPlayEncrypted: false,
            supportsArm64iOS: true,
            nestedExtensions: [],
            embeddedProfileExpiration: nil,
            embeddedProfileProvisionedUDIDs: [],
            canInstallUntouchedForTargetDevice: false
        )
    }

    func importBaseArtifact(
        appID: UUID,
        source: AppSource,
        teamID: String
    ) async throws -> (baseAppURL: URL, version: String, buildVersion: String) {
        importCallCount += 1
        let baseAppURL = paths.baseAppDirectory(for: appID).appendingPathComponent("App.app", isDirectory: true)
        try FileManager.default.createDirectory(at: baseAppURL, withIntermediateDirectories: true)
        try Data("stub".utf8).write(to: baseAppURL.appendingPathComponent("Info.plist"))
        return (baseAppURL, "1.0", "1")
    }

    func stageAndSignApp(for app: ManagedAppRecord) async throws -> SignedArtifactMetadata {
        stageCallCount += 1
        if let stageError { throw stageError }
        let stagedAppURL = paths.stagedAppDirectory(for: app.id).appendingPathComponent("App.app", isDirectory: true)
        try FileManager.default.createDirectory(at: stagedAppURL, withIntermediateDirectories: true)
        try Data("signed".utf8).write(to: stagedAppURL.appendingPathComponent("Info.plist"))

        let now = clock()
        let isAdHoc = app.state == .activeAdHoc
        let exp = now.addingTimeInterval(isAdHoc ? 300 * 86_400 : 7 * 86_400)
        return SignedArtifactMetadata(
            stagedAppPath: stagedAppURL.path,
            effectiveBundleID: app.effectiveBundleID,
            teamID: app.teamID,
            profileExpirationDate: exp,
            provisionedUDIDs: [app.targetDeviceUDID],
            usedUntouchedEmbeddedProfile: isAdHoc
        )
    }
}
