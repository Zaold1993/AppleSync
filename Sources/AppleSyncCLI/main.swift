import AppleSyncCore
import Foundation

@main
struct AppleSyncCLI {
    static func main() async {
        do {
            try await run(arguments: Array(CommandLine.arguments.dropFirst()))
        } catch {
            let message = "Error: \(error.localizedDescription)\n"
            FileHandle.standardError.write(Data(message.utf8))
            exit(1)
        }
    }

    private static func makeCoordinator() -> DeviceOperationCoordinator {
        let paths = AppleSyncPaths()
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
        return DeviceOperationCoordinator(
            paths: paths,
            store: store,
            coreDevice: coreDevice,
            signingEngine: signing,
            backupManager: backupManager,
            notifier: ConsoleNotificationDeliverer()
        )
    }

    private static func run(arguments: [String]) async throws {
        var parser = CLIArgs(arguments)
        let jsonOutput = parser.consumeFlag("--json")

        guard let subcommand = parser.nextPositional() else {
            printUsage()
            return
        }

        if subcommand == "help" || subcommand == "--help" || subcommand == "-h" {
            printUsage()
            return
        }

        let coordinator = makeCoordinator()

        switch subcommand {
        case "teams":
            let teams = try await coordinator.discoverSigningTeams()
            if jsonOutput {
                try printJSON(teams)
            } else if teams.isEmpty {
                print("No valid Apple Development certificates found in Keychain.")
            } else {
                for team in teams {
                    print("\(team.teamID)\t\(team.commonName)\t\(team.sha1Fingerprint)")
                }
            }

        case "devices":
            let devices = try await coordinator.discoverDevices()
            if jsonOutput {
                try printJSON(devices)
            } else if devices.isEmpty {
                print("No paired physical iOS devices found.")
            } else {
                for dev in devices {
                    let conn = dev.connectionState ?? "unknown"
                    let transport = dev.transportType ?? "-"
                    print("\(dev.udid)\t\(dev.marketingName)\t\(transport)\t\(conn)\tid=\(dev.coreDeviceIdentifier)")
                }
            }

        case "inspect-xcode":
            let path = try parser.requirePositional("Missing .xcodeproj or .xcworkspace path")
            let scheme = parser.consumeOption("--scheme")
            let config = parser.consumeOption("--config") ?? "Release"
            let report = try await coordinator.inspectXcodeProject(
                at: URL(fileURLWithPath: path),
                preferredScheme: scheme,
                configuration: config
            )
            if jsonOutput {
                try printJSON(report)
            } else {
                print("Project: \(report.displayName) (\(report.bundleIdentifier))")
                print("Scheme: \(report.selectedScheme) | Configuration: \(report.selectedConfiguration) | Team: \(report.developmentTeam ?? "none")")
                print("Version: \(report.marketingVersion) (\(report.buildVersion))")
                print("Available schemes: \(report.schemes.joined(separator: ", "))")
                print("Available configurations: \(report.configurations.joined(separator: ", "))")
            }

        case "inspect-ipa":
            let path = try parser.requirePositional("Missing .ipa path")
            let udid = parser.consumeOption("--udid") ?? ""
            let report = try await coordinator.inspectIPA(at: URL(fileURLWithPath: path), targetDeviceUDID: udid)
            if jsonOutput {
                try printJSON(report)
            } else {
                print("App: \(report.displayName) (\(report.bundleIdentifier)) v\(report.marketingVersion) (\(report.buildVersion))")
                print("arm64 iOS: \(report.supportsArm64iOS) | FairPlay Encrypted: \(report.isFairPlayEncrypted)")
                print("Untouched Ad-Hoc valid for device: \(report.canInstallUntouchedForTargetDevice)")
                print("Extensions: \(report.nestedExtensions.isEmpty ? "none" : report.nestedExtensions.joined(separator: ", "))")
            }

        case "add-xcode":
            let path = try parser.requirePositional("Missing .xcodeproj or .xcworkspace path")
            let teamID = try parser.requireOption("--team")
            let udid = try parser.requireOption("--udid")
            let scheme = parser.consumeOption("--scheme")
            let config = parser.consumeOption("--config") ?? "Release"
            let stripExtensions = !parser.consumeFlag("--keep-extensions")
            let nameOverride = parser.consumeOption("--name")
            let installNow = !parser.consumeFlag("--frozen")
            let record = try await coordinator.registerXcodeApp(
                projectOrWorkspacePath: path,
                scheme: scheme,
                configuration: config,
                stripExtensions: stripExtensions,
                teamID: teamID,
                targetDeviceUDID: udid,
                displayNameOverride: nameOverride,
                installImmediately: installNow
            )
            if jsonOutput {
                try printJSON(record)
            } else {
                print("Registered Xcode app '\(record.displayName)' id=\(record.id.uuidString) bundle=\(record.effectiveBundleID) state=\(record.state.rawValue)")
            }

        case "add-ipa":
            let path = try parser.requirePositional("Missing .ipa path")
            let teamID = try parser.requireOption("--team")
            let udid = try parser.requireOption("--udid")
            let nameOverride = parser.consumeOption("--name")
            let stripExtensions = !parser.consumeFlag("--keep-extensions")
            let preferAdHoc = !parser.consumeFlag("--no-adhoc-fastpath")
            let installNow = !parser.consumeFlag("--frozen")
            let record = try await coordinator.registerIPAApp(
                ipaPath: path,
                teamID: teamID,
                targetDeviceUDID: udid,
                stripExtensions: stripExtensions,
                preferOriginalAdHocIfValid: preferAdHoc,
                displayNameOverride: nameOverride,
                installImmediately: installNow
            )
            if jsonOutput {
                try printJSON(record)
            } else {
                print("Registered IPA '\(record.displayName)' id=\(record.id.uuidString) bundle=\(record.effectiveBundleID) state=\(record.state.rawValue)")
            }

        case "rebuild-xcode":
            let appID = try parser.requireUUID("Invalid or missing appID")
            let reinstall = !parser.consumeFlag("--no-reinstall")
            let updated = try await coordinator.rebuildXcodeSnapshot(appID: appID, reinstallIfActive: reinstall)
            if jsonOutput {
                try printJSON(updated)
            } else {
                print("Xcode snapshot rebuilt for '\(updated.displayName)' v\(updated.appVersion) (\(updated.buildVersion)) state=\(updated.state.rawValue)")
            }

        case "list":
            let udidFilter = parser.consumeOption("--udid")
            var apps = try await coordinator.listApps()
            if let udidFilter {
                apps = apps.filter { $0.targetDeviceUDID == udidFilter }
            }
            if jsonOutput {
                try printJSON(apps)
            } else if apps.isEmpty {
                print("No managed apps configured.")
            } else {
                for app in apps {
                    let rem = app.remainingValiditySeconds().map { String(format: "%.1fd", $0 / 86_400.0) } ?? "-"
                    let pauseTag = app.autoSyncPaused ? "\t[SYNC PAUSED]" : ""
                    print("\(app.id.uuidString)\t\(app.displayName)\t\(app.state.rawValue)\texp=\(rem)\tteam=\(app.teamID)\t\(app.effectiveBundleID)\(pauseTag)")
                }
            }

        case "slots":
            let udid = try parser.requireOption("--udid")
            let summary = try await coordinator.activeSlotSummary(forDeviceUDID: udid)
            if jsonOutput {
                try printJSON(summary)
            } else {
                print("Device \(summary.deviceUDID): \(summary.activeCount)/\(summary.maxFreeSlots) active free slots (remaining: \(summary.remainingSlots))")
                print("  Active: \(summary.activeApps.map(\.displayName).joined(separator: ", "))")
                print("  Frozen: \(summary.frozenApps.map(\.displayName).joined(separator: ", "))")
                print("  Ad-Hoc exempt: \(summary.adHocApps.map(\.displayName).joined(separator: ", "))")
            }

        case "sync-now":
            let appID = try parser.requireUUID("Missing or invalid appID")
            let synced = try await coordinator.syncAppNow(appID: appID)
            if jsonOutput {
                try printJSON(synced)
            } else {
                print("Synced '\(synced.displayName)' at \(ISO8601DateFormatter().string(from: synced.lastInstalledAt ?? Date()))")
            }

        case "sync-cycle":
            let force = parser.consumeFlag("--force")
            let report = try await coordinator.runBackgroundSyncCycle(force: force)
            if jsonOutput {
                try printJSON(report)
            } else if report.wasStoppedGlobally {
                print("Auto-sync daemon is currently paused. Run 'applesync daemon start' or pass '--force'.")
            } else {
                print("Sync cycle completed: \(report.outcomes.count) app(s) evaluated, \(report.alertsEmitted.count) alert(s) emitted.")
                for outcome in report.outcomes {
                    print("  - \(outcome.displayName): \(outcome.action.rawValue) [\(outcome.previousState.rawValue) -> \(outcome.newState.rawValue)] (\(outcome.message))")
                }
            }

        case "daemon":
            let action = try parser.requirePositional("Missing daemon action: use status | stop | start")
            switch action {
            case "status":
                let paused = try await coordinator.isGlobalAutoSyncPaused()
                if jsonOutput {
                    try printJSON(["autoSyncGlobalPaused": paused])
                } else {
                    print(paused ? "Auto-sync daemon: STOPPED (paused)" : "Auto-sync daemon: ACTIVE")
                }
            case "stop", "pause":
                try await coordinator.setGlobalAutoSyncPaused(true)
                if jsonOutput {
                    try printJSON(["autoSyncGlobalPaused": true])
                } else {
                    print("Auto-sync daemon stopped.")
                }
            case "start", "resume":
                try await coordinator.setGlobalAutoSyncPaused(false)
                if jsonOutput {
                    try printJSON(["autoSyncGlobalPaused": false])
                } else {
                    print("Auto-sync daemon started.")
                }
            default:
                throw AppleSyncError.invalidInput("Invalid daemon action '\(action)'. Use status, stop, or start.")
            }

        case "pause":
            let appID = try parser.requireUUID("Missing or invalid appID")
            let updated = try await coordinator.setAppAutoSyncPaused(appID: appID, paused: true)
            if jsonOutput {
                try printJSON(updated)
            } else {
                print("Auto-sync paused for '\(updated.displayName)'.")
            }

        case "resume":
            let appID = try parser.requireUUID("Missing or invalid appID")
            let updated = try await coordinator.setAppAutoSyncPaused(appID: appID, paused: false)
            if jsonOutput {
                try printJSON(updated)
            } else {
                print("Auto-sync resumed for '\(updated.displayName)'.")
            }

        case "backup":
            let appID = try parser.requireUUID("Missing or invalid appID")
            let manifest = try await coordinator.createManualBackup(appID: appID)
            if jsonOutput {
                try printJSON(manifest)
            } else {
                print("Backup created: \(manifest.backupID.uuidString) (\(manifest.fileCount) files, \(manifest.sizeBytes) bytes)")
            }

        case "backups":
            let appID = try parser.requireUUID("Missing or invalid appID")
            let list = try await coordinator.backups(forAppID: appID)
            if jsonOutput {
                try printJSON(list)
            } else if list.isEmpty {
                print("No backups found for app \(appID.uuidString).")
            } else {
                let iso = ISO8601DateFormatter()
                for b in list {
                    print("\(b.backupID.uuidString)\t\(iso.string(from: b.createdAt))\t\(b.trigger.rawValue)\t\(b.fileCount) files\t\(b.sizeBytes) B")
                }
            }

        case "restore":
            let appID = try parser.requireUUID("Missing or invalid appID")
            let backupID = try parser.requireUUID("Missing or invalid backupID")
            try await coordinator.restoreBackup(appID: appID, backupID: backupID)
            print("Backup \(backupID.uuidString) restored onto app \(appID.uuidString).")

        case "delete-backup":
            let backupID = try parser.requireUUID("Missing or invalid backupID")
            try await coordinator.deleteBackup(backupID: backupID)
            print("Backup \(backupID.uuidString) deleted.")

        case "freeze":
            let appID = try parser.requireUUID("Missing or invalid appID")
            let createBackupFirst = !parser.consumeFlag("--no-backup")
            let manifest = try await coordinator.freezeApp(appID: appID, createBackupFirst: createBackupFirst)
            if jsonOutput {
                try printJSON(manifest)
            } else {
                print("App frozen. Backup created: \(manifest?.backupID.uuidString ?? "none")")
            }

        case "thaw":
            let appID = try parser.requireUUID("Missing or invalid appID")
            let backupIDStr = parser.consumeOption("--backup-id")
            let backupID = try backupIDStr.map { str -> UUID in
                guard let id = UUID(uuidString: str) else {
                    throw AppleSyncError.invalidInput("Invalid backup-id: \(str)")
                }
                return id
            }
            let record = try await coordinator.thawApp(appID: appID, restoreBackupID: backupID)
            if jsonOutput {
                try printJSON(record)
            } else {
                print("App thawed and reinstalled: '\(record.displayName)' (\(record.state.rawValue))")
            }

        case "swap":
            let freezeID = try parser.requireUUID("Missing or invalid freezeAppID")
            let thawID = try parser.requireUUID("Missing or invalid thawAppID")
            let backupIDStr = parser.consumeOption("--backup-id")
            let backupID = try backupIDStr.map { str -> UUID in
                guard let id = UUID(uuidString: str) else {
                    throw AppleSyncError.invalidInput("Invalid backup-id: \(str)")
                }
                return id
            }
            let result = try await coordinator.swapApps(
                freezeAppID: freezeID,
                thawAppID: thawID,
                restoreBackupIDForThaw: backupID
            )
            if jsonOutput {
                try printJSON(["frozenBackup": result.frozenBackup.backupID.uuidString, "thawedApp": result.thawedApp.id.uuidString])
            } else {
                print("Swap completed: frozen backup=\(result.frozenBackup.backupID.uuidString), active='\(result.thawedApp.displayName)'")
            }

        case "remove":
            let appID = try parser.requireUUID("Missing or invalid appID")
            let uninstall = parser.consumeFlag("--uninstall")
            let deleteBackups = parser.consumeFlag("--delete-backups")
            try await coordinator.removeApp(
                appID: appID,
                uninstallFromDevice: uninstall,
                deleteBackups: deleteBackups
            )
            print("App \(appID.uuidString) removed from AppleSync.")

        case "events":
            let limit = parser.consumeOption("--limit").flatMap(Int.init) ?? 50
            let events = try await coordinator.events(limit: limit)
            if jsonOutput {
                try printJSON(events)
            } else {
                let iso = ISO8601DateFormatter()
                for e in events {
                    print("[\(iso.string(from: e.timestamp))] [\(e.succeeded ? "OK" : "ERR")] \(e.kind): \(e.message)")
                }
            }

        default:
            throw AppleSyncError.invalidInput("Unknown command: '\(subcommand)'. Run 'applesync help'.")
        }
    }

    private static func printJSON<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        print(String(data: data, encoding: .utf8) ?? "{}")
    }

    private static func printUsage() {
        print("""
        AppleSync CLI — Personal iOS app manager, 7-day auto-resync & Freeze/Swap

        Commands:
          teams                                        List Xcode Apple Development accounts/certificates in Keychain
          devices                                      List paired physical iPhone/iPad devices
          inspect-xcode <path> [--scheme S]            Inspect an Xcode project, workspace, or folder
          inspect-ipa <path> [--udid U]                Inspect an .ipa (FairPlay, arm64, Ad-Hoc)
          add-xcode <path> --team T --udid U [...]     Register an Xcode snapshot [--frozen] [--name N]
          add-ipa <path> --team T --udid U [...]       Register an .ipa [--keep-extensions] [--frozen]
          rebuild-xcode <appID> [--no-reinstall]       Rebuild an Xcode snapshot manually
          list [--udid U]                              List managed apps and expiration status
          slots --udid U                               Show the 3 active free-account slots for a device
          sync-now <appID>                             Re-sign and reinstall immediately over Wi-Fi/USB
          sync-cycle [--force]                         Run the Days 4-6 background sync cycle
          daemon <status|stop|start>                   Check status or pause/resume the auto-sync daemon
          pause <appID>                                Pause auto-sync for a single app
          resume <appID>                               Resume auto-sync for a single app
          backup <appID>                               Create SHA-256 verified backup (Documents & Library)
          backups <appID>                              List saved backups for an app
          restore <appID> <backupID>                   Clean-reinstall and restore a backup onto the device
          delete-backup <backupID>                     Permanently delete a saved backup
          freeze <appID> [--no-backup]                 Backup + Uninstall from device (frees 1 slot)
          thaw <appID> [--backup-id ID]                Re-sign + Reinstall + Restore backup
          swap <freezeID> <thawID> [--backup-id ID]    Two-phase atomic swap within the 3-app limit
          remove <appID> [--uninstall] [--delete-backups]
          events [--limit N]                           Show recent activity log
        Global option: --json
        """)
    }
}

private struct CLIArgs {
    private var tokens: [String]

    init(_ tokens: [String]) {
        self.tokens = tokens
    }

    mutating func consumeFlag(_ flag: String) -> Bool {
        if let idx = tokens.firstIndex(of: flag) {
            tokens.remove(at: idx)
            return true
        }
        return false
    }

    mutating func consumeOption(_ name: String) -> String? {
        guard let idx = tokens.firstIndex(of: name), idx + 1 < tokens.count else {
            return nil
        }
        let value = tokens[idx + 1]
        tokens.remove(at: idx + 1)
        tokens.remove(at: idx)
        return value
    }

    mutating func requireOption(_ name: String) throws -> String {
        guard let value = consumeOption(name) else {
            throw AppleSyncError.invalidInput("Missing required option: \(name)")
        }
        return value
    }

    mutating func nextPositional() -> String? {
        guard !tokens.isEmpty else { return nil }
        return tokens.removeFirst()
    }

    mutating func requirePositional(_ message: String) throws -> String {
        guard let next = nextPositional() else {
            throw AppleSyncError.invalidInput(message)
        }
        return next
    }

    mutating func requireUUID(_ message: String) throws -> UUID {
        let raw = try requirePositional(message)
        guard let uuid = UUID(uuidString: raw) else {
            throw AppleSyncError.invalidInput("\(message): '\(raw)'")
        }
        return uuid
    }
}
