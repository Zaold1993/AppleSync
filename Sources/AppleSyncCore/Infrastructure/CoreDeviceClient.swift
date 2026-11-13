import Foundation

public protocol CoreDeviceServicing: Sendable {
    func listDevices() async throws -> [DiscoveredDevice]
    func lockState(deviceIdentifier: String) async throws -> LockStateInfo
    func installedApps(deviceIdentifier: String) async throws -> [InstalledDeviceApp]
    func runningProcesses(deviceIdentifier: String) async throws -> [RunningDeviceProcess]
    func terminateProcess(deviceIdentifier: String, pid: Int, kill: Bool) async throws
    func installApp(deviceIdentifier: String, appBundleURL: URL) async throws
    func uninstallApp(deviceIdentifier: String, bundleIdentifier: String) async throws
    func copyFromContainer(
        deviceIdentifier: String,
        bundleIdentifier: String,
        remoteSourceSubpath: String,
        localDestinationURL: URL
    ) async throws
    func copyToContainer(
        deviceIdentifier: String,
        bundleIdentifier: String,
        localSourceURL: URL,
        remoteDestinationSubpath: String,
        removeExistingContent: Bool
    ) async throws
}

public actor DevicectlClient: CoreDeviceServicing {
    private let runner: CommandRunning
    private let xcrunPath: String

    public init(
        runner: CommandRunning = SystemProcessRunner(),
        xcrunPath: String = "/usr/bin/xcrun"
    ) {
        self.runner = runner
        self.xcrunPath = xcrunPath
    }

    public func listDevices() async throws -> [DiscoveredDevice] {
        let data = try await runDevicectl(["list", "devices"], timeout: 15)
        let envelope = try JSONDecoder().decode(DevicectlEnvelope<ListDevicesResult>.self, from: data)
        return envelope.result.devices.map { raw in
            let udid = raw.properties?.hardware?.udid
                ?? raw.hardwareProperties?.udid
                ?? raw.identifier
            let marketingName = raw.properties?.hardware?.marketingName
                ?? raw.properties?.state?.name
                ?? raw.deviceProperties?.name
                ?? raw.hardwareProperties?.marketingName
                ?? "iOS Device"
            let platform = raw.properties?.hardware?.platform
                ?? raw.hardwareProperties?.platform
                ?? "iOS"
            let reality = raw.properties?.hardware?.reality
                ?? raw.hardwareProperties?.reality
                ?? "physical"
            let pairingState = raw.properties?.connection?.pairingState
                ?? raw.connectionProperties?.pairingState
                ?? "unknown"
            let transportType = raw.properties?.connection?.transportType
                ?? raw.connectionProperties?.transportType
            let connectionState = raw.properties?.connection?.state
                ?? raw.connectionProperties?.tunnelState

            return DiscoveredDevice(
                coreDeviceIdentifier: raw.identifier,
                udid: udid,
                marketingName: marketingName,
                platform: platform,
                reality: reality,
                pairingState: pairingState,
                transportType: transportType,
                connectionState: connectionState
            )
        }
    }

    public func lockState(deviceIdentifier: String) async throws -> LockStateInfo {
        let data = try await runDevicectl(
            ["device", "info", "lockState", "--device", deviceIdentifier],
            timeout: 15
        )
        let envelope = try JSONDecoder().decode(DevicectlEnvelope<LockStateResult>.self, from: data)
        return LockStateInfo(
            deviceIdentifier: envelope.result.deviceIdentifier ?? deviceIdentifier,
            passcodeRequired: envelope.result.passcodeRequired ?? false,
            unlockedSinceBoot: envelope.result.unlockedSinceBoot ?? true
        )
    }

    public func installedApps(deviceIdentifier: String) async throws -> [InstalledDeviceApp] {
        let data = try await runDevicectl(
            ["device", "info", "apps", "--device", deviceIdentifier],
            timeout: 25
        )
        let envelope = try JSONDecoder().decode(DevicectlEnvelope<InstalledAppsResult>.self, from: data)
        return envelope.result.apps.map { app in
            InstalledDeviceApp(
                bundleIdentifier: app.bundleIdentifier,
                name: app.name ?? app.bundleIdentifier,
                version: app.version ?? "1.0",
                bundleVersion: app.bundleVersion ?? "1",
                builtByDeveloper: app.builtByDeveloper ?? false,
                containerAccessible: app.containerAccessible ?? false,
                removable: app.removable ?? true,
                url: app.url
            )
        }
    }

    public func runningProcesses(deviceIdentifier: String) async throws -> [RunningDeviceProcess] {
        let data = try await runDevicectl(
            ["device", "info", "processes", "--device", deviceIdentifier],
            timeout: 20
        )
        let envelope = try JSONDecoder().decode(DevicectlEnvelope<RunningProcessesResult>.self, from: data)
        return envelope.result.runningProcesses.map {
            RunningDeviceProcess(processIdentifier: $0.processIdentifier, executable: $0.executable)
        }
    }

    public func terminateProcess(deviceIdentifier: String, pid: Int, kill: Bool = false) async throws {
        var args = ["device", "process", "terminate", "--device", deviceIdentifier, "--pid", String(pid)]
        if kill {
            args.append("--kill")
        }
        _ = try await runDevicectl(args, timeout: 15)
    }

    public func installApp(deviceIdentifier: String, appBundleURL: URL) async throws {
        _ = try await runDevicectl(
            ["device", "install", "app", "--device", deviceIdentifier, appBundleURL.path],
            timeout: 180
        )
    }

    public func uninstallApp(deviceIdentifier: String, bundleIdentifier: String) async throws {
        _ = try await runDevicectl(
            ["device", "uninstall", "app", "--device", deviceIdentifier, bundleIdentifier],
            timeout: 60
        )
    }

    public func copyFromContainer(
        deviceIdentifier: String,
        bundleIdentifier: String,
        remoteSourceSubpath: String,
        localDestinationURL: URL
    ) async throws {
        _ = try await runDevicectl(
            [
                "device", "copy", "from",
                "--device", deviceIdentifier,
                "--domain-type", "appDataContainer",
                "--domain-identifier", bundleIdentifier,
                "--source", remoteSourceSubpath,
                "--destination", localDestinationURL.path
            ],
            timeout: 180
        )
    }

    public func copyToContainer(
        deviceIdentifier: String,
        bundleIdentifier: String,
        localSourceURL: URL,
        remoteDestinationSubpath: String,
        removeExistingContent: Bool = true
    ) async throws {
        _ = try await runDevicectl(
            [
                "device", "copy", "to",
                "--device", deviceIdentifier,
                "--domain-type", "appDataContainer",
                "--domain-identifier", bundleIdentifier,
                "--source", localSourceURL.path,
                "--destination", remoteDestinationSubpath,
                "--remove-existing-content", removeExistingContent ? "true" : "false"
            ],
            timeout: 180
        )
    }

    private func runDevicectl(_ subcommandArgs: [String], timeout: TimeInterval) async throws -> Data {
        let args = [
            "devicectl",
            "--quiet",
            "--omit-deprecated-fields-in-json",
            "--timeout", String(Int(timeout)),
            "--json-output", "-"
        ] + subcommandArgs

        let output = try await runner.run(xcrunPath, arguments: args, timeout: timeout + 5)
        guard output.exitCode == 0 else {
            let detail = output.stderrString.isEmpty ? output.stdoutString : output.stderrString
            throw AppleSyncError.commandFailed(
                executable: "xcrun devicectl \(subcommandArgs.joined(separator: " "))",
                exitCode: output.exitCode,
                stderr: detail
            )
        }
        return output.stdoutData
    }
}

// MARK: - Devicectl v651.32 JSON DTOs

private struct DevicectlEnvelope<ResultType: Decodable>: Decodable {
    let result: ResultType
}

private struct ListDevicesResult: Decodable {
    let devices: [RawDevice]
}

private struct RawDevice: Decodable {
    let identifier: String
    let properties: RawDevicePropertiesContainer?
    let hardwareProperties: RawHardwareProperties?
    let deviceProperties: RawStateProperties?
    let connectionProperties: RawConnectionProperties?
}

private struct RawDevicePropertiesContainer: Decodable {
    let hardware: RawHardwareProperties?
    let state: RawStateProperties?
    let connection: RawConnectionProperties?
}

private struct RawHardwareProperties: Decodable {
    let udid: String?
    let platform: String?
    let reality: String?
    let marketingName: String?
}

private struct RawStateProperties: Decodable {
    let name: String?
}

private struct RawConnectionProperties: Decodable {
    let pairingState: String?
    let transportType: String?
    let state: String?
    let tunnelState: String?
}

private struct LockStateResult: Decodable {
    let deviceIdentifier: String?
    let passcodeRequired: Bool?
    let unlockedSinceBoot: Bool?
}

private struct InstalledAppsResult: Decodable {
    let apps: [RawInstalledApp]
}

private struct RawInstalledApp: Decodable {
    let bundleIdentifier: String
    let bundleVersion: String?
    let builtByDeveloper: Bool?
    let containerAccessible: Bool?
    let name: String?
    let removable: Bool?
    let url: String?
    let version: String?
}

private struct RunningProcessesResult: Decodable {
    let runningProcesses: [RawRunningProcess]
}

private struct RawRunningProcess: Decodable {
    let executable: String
    let processIdentifier: Int
}
