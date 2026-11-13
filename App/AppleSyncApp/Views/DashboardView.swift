import AppleSyncCore
import SwiftUI

struct DashboardView: View {
    @Bindable var viewModel: AppleSyncViewModel

    @State private var activeSheet: ActiveSheet?
    @State private var sidebarTab: SidebarSection = .apps
    @State private var freezeConfirmationApp: ManagedAppRecord?
    @State private var removeConfirmationApp: ManagedAppRecord?
    @State private var restoreConfirmation: (appID: UUID, backup: BackupManifest)?
    @State private var deleteBackupConfirmation: BackupManifest?

    private enum SidebarSection: String, CaseIterable, Identifiable {
        case apps = "Apps & Slots"
        case infrastructure = "Devices & Accounts"
        case events = "Activity Log"

        var id: String { rawValue }
    }

    private enum ActiveSheet: Identifiable {
        case addXcode
        case addIPA
        case swap(deviceUDID: String)

        var id: String {
            switch self {
            case .addXcode: return "xcode"
            case .addIPA: return "ipa"
            case .swap(let udid): return "swap-\(udid)"
            }
        }
    }

    private var setupChecklistSummary: String {
        var missing: [String] = []
        if viewModel.teams.isEmpty {
            missing.append("sign in under Xcode > Settings > Accounts to create a Personal Team certificate")
        }
        if viewModel.devices.isEmpty {
            missing.append("connect your iPhone via USB once and tap 'Trust This Computer'")
        }
        return missing.joined(separator: " · ")
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $sidebarTab) {
                Section("AppleSync") {
                    Label("App & Backup Manager", systemImage: "square.grid.2x2")
                        .tag(SidebarSection.apps)
                    Label("Devices & Accounts", systemImage: "iphone.and.arrow.forward")
                        .tag(SidebarSection.infrastructure)
                    Label("Activity Log", systemImage: "list.bullet.rectangle")
                        .tag(SidebarSection.events)
                }

                if sidebarTab == .apps {
                    Section("Free Slots (\(viewModel.activeApps(forDeviceUDID: viewModel.activeTargetUDID).count)/3)") {
                        ForEach(viewModel.activeApps(forDeviceUDID: viewModel.activeTargetUDID)) { app in
                            AppRowButton(app: app, isSelected: viewModel.selectedAppID == app.id) {
                                viewModel.selectedAppID = app.id
                            }
                        }
                    }

                    let adHoc = viewModel.adHocApps(forDeviceUDID: viewModel.activeTargetUDID)
                    if !adHoc.isEmpty {
                        Section("Ad-Hoc (Exempt from 3-Slot Limit)") {
                            ForEach(adHoc) { app in
                                AppRowButton(app: app, isSelected: viewModel.selectedAppID == app.id) {
                                    viewModel.selectedAppID = app.id
                                }
                            }
                        }
                    }

                    let frozen = viewModel.frozenApps(forDeviceUDID: viewModel.activeTargetUDID)
                    if !frozen.isEmpty {
                        Section("Frozen Vault (\(frozen.count))") {
                            ForEach(frozen) { app in
                                AppRowButton(app: app, isSelected: viewModel.selectedAppID == app.id) {
                                    viewModel.selectedAppID = app.id
                                }
                            }
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 250, ideal: 280)
        } detail: {
            VStack(spacing: 0) {
                if viewModel.isDaemonPaused {
                    HStack(spacing: 10) {
                        Image(systemName: "pause.circle.fill")
                            .foregroundStyle(.orange)
                        Text("Auto-sync daemon stopped: no background syncs will run (Sync Now, Backup, Freeze, and Swap still work manually).")
                            .font(.caption)
                        Spacer()
                        Button("Start Daemon") {
                            Task { await viewModel.startSyncDaemon() }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.orange.opacity(0.14))
                }

                if viewModel.teams.isEmpty || viewModel.devices.isEmpty {
                    HStack(spacing: 10) {
                        Image(systemName: "checklist")
                            .foregroundStyle(.blue)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Initial setup incomplete")
                                .font(.caption.weight(.semibold))
                            Text(setupChecklistSummary)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Setup Guide") {
                            sidebarTab = .infrastructure
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.blue.opacity(0.10))
                }

                Group {
                    switch sidebarTab {
                    case .apps:
                        if let app = viewModel.selectedApp {
                            AppDetailPane(
                                app: app,
                                backups: viewModel.backupsByAppID[app.id] ?? [],
                                isBusy: viewModel.isBusy,
                                onSyncNow: { Task { await viewModel.syncAppNow(app.id) } },
                                onToggleAutoSyncPaused: { paused in
                                    Task { await viewModel.toggleAppAutoSync(app.id, paused: paused) }
                                },
                                onRebuildXcode: { Task { await viewModel.rebuildXcodeSnapshot(app.id) } },
                                onCreateBackup: { Task { await viewModel.createBackup(app.id) } },
                                onFreeze: { freezeConfirmationApp = app },
                                onThaw: { backupID in Task { await viewModel.thawApp(app.id, backupID: backupID) } },
                                onSwap: { activeSheet = .swap(deviceUDID: app.targetDeviceUDID) },
                                onRemove: { removeConfirmationApp = app },
                                onRestoreBackup: { backup in restoreConfirmation = (app.id, backup) },
                                onDeleteBackup: { backup in deleteBackupConfirmation = backup }
                            )
                        } else {
                            ContentUnavailableView(
                                "No App Selected",
                                systemImage: "app.badge.checkmark",
                                description: Text("Add an Xcode project or a clean .ipa file from the toolbar.")
                            )
                        }

                    case .infrastructure:
                        InfrastructurePane(viewModel: viewModel)

                    case .events:
                        EventsLogPane(events: viewModel.events, alerts: viewModel.recentAlerts)
                    }
                }
            }
            .overlay(alignment: .bottom) {
                if let busyMessage = viewModel.busyMessage {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text(busyMessage).font(.caption)
                        Button {
                            viewModel.cancelCurrentSync()
                        } label: {
                            Label("Stop", systemImage: "stop.fill")
                                .font(.caption.weight(.semibold))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .tint(.red)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .shadow(radius: 6)
                    .padding(16)
                }
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if !viewModel.devices.isEmpty {
                    Picker("iPhone", selection: $viewModel.selectedDeviceUDID) {
                        ForEach(viewModel.devices) { dev in
                            Text(dev.marketingName).tag(Optional(dev.udid))
                        }
                    }
                    .frame(width: 170)
                }

                Button {
                    activeSheet = .addXcode
                } label: {
                    Label("Xcode Project", systemImage: "hammer")
                }

                Button {
                    activeSheet = .addIPA
                } label: {
                    Label("Import IPA", systemImage: "shippingbox")
                }

                if let udid = viewModel.activeTargetUDID,
                   !viewModel.activeApps(forDeviceUDID: udid).isEmpty,
                   !viewModel.frozenApps(forDeviceUDID: udid).isEmpty {
                    Button {
                        activeSheet = .swap(deviceUDID: udid)
                    } label: {
                        Label("Swap", systemImage: "arrow.left.arrow.right")
                    }
                }

                Button {
                    Task {
                        if viewModel.isDaemonPaused {
                            await viewModel.startSyncDaemon()
                        } else {
                            await viewModel.stopSyncDaemon()
                        }
                    }
                } label: {
                    Label(
                        viewModel.isDaemonPaused ? "Start Daemon" : "Stop Daemon",
                        systemImage: viewModel.isDaemonPaused ? "play.circle.fill" : "stop.circle"
                    )
                }
                .tint(viewModel.isDaemonPaused ? .green : .orange)

                Button {
                    Task { await viewModel.runSyncCycleNow() }
                } label: {
                    Label("Run Cycle", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(viewModel.isBusy)

                Button {
                    Task { await viewModel.refreshAll() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .addXcode:
                AddXcodeAppSheet(viewModel: viewModel)
            case .addIPA:
                AddIPAAppSheet(viewModel: viewModel)
            case .swap(let udid):
                SwapAppsSheet(viewModel: viewModel, deviceUDID: udid)
            }
        }
        .alert("Operation Failed", isPresented: Binding(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )) {
            Button("OK") { viewModel.errorMessage = nil }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
        .confirmationDialog(
            "Freeze '\(freezeConfirmationApp?.displayName ?? "")'?",
            isPresented: Binding(
                get: { freezeConfirmationApp != nil },
                set: { if !$0 { freezeConfirmationApp = nil } }
            )
        ) {
            Button("Backup + Freeze App", role: .destructive) {
                if let app = freezeConfirmationApp {
                    Task { await viewModel.freezeApp(app.id) }
                }
                freezeConfirmationApp = nil
            }
            Button("Cancel", role: .cancel) { freezeConfirmationApp = nil }
        } message: {
            Text("AppleSync will create and verify a SHA-256 backup (Documents & Library) first, and will uninstall the app only if the backup succeeds.\n\nNote: credentials stored in the iOS Keychain cannot be exported by CoreDevice.")
        }
        .confirmationDialog(
            "Restore this backup?",
            isPresented: Binding(
                get: { restoreConfirmation != nil },
                set: { if !$0 { restoreConfirmation = nil } }
            )
        ) {
            Button("Verify SHA-256 & Clean Restore") {
                if let item = restoreConfirmation {
                    Task { await viewModel.restoreBackup(appID: item.appID, backupID: item.backup.backupID) }
                }
                restoreConfirmation = nil
            }
            Button("Cancel", role: .cancel) { restoreConfirmation = nil }
        } message: {
            Text("AppleSync verifies the backup SHA-256, cleanly reinstalls the app to remove newer container files, and restores Documents & Library (ensure your iPhone is unlocked on the same Wi-Fi).")
        }
        .confirmationDialog(
            "Permanently delete backup?",
            isPresented: Binding(
                get: { deleteBackupConfirmation != nil },
                set: { if !$0 { deleteBackupConfirmation = nil } }
            )
        ) {
            Button("Delete Backup", role: .destructive) {
                if let b = deleteBackupConfirmation {
                    Task { await viewModel.deleteBackup(b.backupID) }
                }
                deleteBackupConfirmation = nil
            }
            Button("Cancel", role: .cancel) { deleteBackupConfirmation = nil }
        } message: {
            Text("This deletes the archived app data stored on your Mac for this snapshot.")
        }
        .confirmationDialog(
            "Remove '\(removeConfirmationApp?.displayName ?? "")' from AppleSync?",
            isPresented: Binding(
                get: { removeConfirmationApp != nil },
                set: { if !$0 { removeConfirmationApp = nil } }
            )
        ) {
            Button("Remove from list only (keep backups)") {
                if let app = removeConfirmationApp {
                    Task { await viewModel.removeApp(app.id, uninstall: false, deleteBackups: false) }
                }
                removeConfirmationApp = nil
            }
            Button("Remove + Delete its Backups", role: .destructive) {
                if let app = removeConfirmationApp {
                    Task { await viewModel.removeApp(app.id, uninstall: false, deleteBackups: true) }
                }
                removeConfirmationApp = nil
            }
            Button("Cancel", role: .cancel) { removeConfirmationApp = nil }
        } message: {
            Text("Choose whether to keep saved backup archives on your Mac or delete everything.")
        }
        .frame(minWidth: 880, minHeight: 560)
        .onAppear {
            viewModel.startIfNeeded()
        }
    }
}

private struct AppRowButton: View {
    let app: ManagedAppRecord
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: app.state.symbolName)
                    .foregroundStyle(app.state.badgeColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(app.displayName)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    Text("\(app.countdownText) · \(app.teamID)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if app.autoSyncPaused {
                    Image(systemName: "pause.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .help("Auto-sync paused for this app")
                }
            }
            .padding(.vertical, 3)
            .padding(.horizontal, 4)
            .background(isSelected ? Color.accentColor.opacity(0.16) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }
}

private struct AppDetailPane: View {
    let app: ManagedAppRecord
    let backups: [BackupManifest]
    let isBusy: Bool
    let onSyncNow: () -> Void
    let onToggleAutoSyncPaused: (Bool) -> Void
    let onRebuildXcode: () -> Void
    let onCreateBackup: () -> Void
    let onFreeze: () -> Void
    let onThaw: (UUID?) -> Void
    let onSwap: () -> Void
    let onRemove: () -> Void
    let onRestoreBackup: (BackupManifest) -> Void
    let onDeleteBackup: (BackupManifest) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                // Header card
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Text(app.displayName)
                                .font(.largeTitle.bold())
                            Text(app.state.displayTitle)
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(app.state.badgeColor.opacity(0.16), in: Capsule())
                                .foregroundStyle(app.state.badgeColor)
                            if app.autoSyncPaused && app.state != .frozen {
                                Text("Auto-Sync Paused")
                                    .font(.caption.weight(.semibold))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(.orange.opacity(0.16), in: Capsule())
                                    .foregroundStyle(.orange)
                            }
                        }
                        Text("\(app.sourceLabel) · v\(app.appVersion) (\(app.buildVersion))")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 4) {
                        Text(app.countdownText)
                            .font(.title3.bold().monospacedDigit())
                            .foregroundStyle(app.countdownColor)
                        if let exp = app.profileExpiresAt {
                            Text("Expires: \(exp.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                // Actions
                HStack(spacing: 10) {
                    if app.state == .frozen {
                        Button("Thaw & Reinstall", action: { onThaw(backups.first?.backupID) })
                            .buttonStyle(.borderedProminent)
                            .disabled(isBusy)
                    } else {
                        Button("Sync Now", action: onSyncNow)
                            .buttonStyle(.borderedProminent)
                            .disabled(isBusy)

                        Button {
                            onToggleAutoSyncPaused(!app.autoSyncPaused)
                        } label: {
                            Label(
                                app.autoSyncPaused ? "Resume Auto-Sync" : "Pause Auto-Sync",
                                systemImage: app.autoSyncPaused ? "play.fill" : "pause.fill"
                            )
                        }
                        .buttonStyle(.bordered)
                        .tint(app.autoSyncPaused ? .green : .orange)

                        if case .xcodeProject = app.source {
                            Button("Rebuild Xcode Snapshot", action: onRebuildXcode)
                                .buttonStyle(.bordered)
                                .disabled(isBusy)
                        }

                        Button("Backup Now", action: onCreateBackup)
                            .buttonStyle(.bordered)
                            .disabled(isBusy)

                        Button("Freeze App", action: onFreeze)
                            .buttonStyle(.bordered)
                            .disabled(isBusy)
                    }

                    Button("Swap", action: onSwap)
                        .buttonStyle(.bordered)
                        .disabled(isBusy)

                    Spacer()

                    Button("Remove…", role: .destructive, action: onRemove)
                        .buttonStyle(.bordered)
                        .disabled(isBusy)
                }

                if let err = app.lastSyncError {
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                }

                if let stagedPath = app.stagedSignedAppPath {
                    Label("Re-signed build staged offline on your Mac (\(URL(fileURLWithPath: stagedPath).lastPathComponent)). It will install automatically when your unlocked iPhone is on the same Wi-Fi.", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.blue)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                }

                GroupBox("Signing & Source Details") {
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                        GridRow {
                            Text("Team / Xcode Account").foregroundStyle(.secondary)
                            Text(app.teamID).font(.body.monospaced())
                        }
                        GridRow {
                            Text("Original Bundle ID").foregroundStyle(.secondary)
                            Text(app.originalBundleID).font(.body.monospaced())
                        }
                        GridRow {
                            Text("Effective Bundle ID").foregroundStyle(.secondary)
                            Text(app.effectiveBundleID).font(.body.monospaced())
                        }
                        GridRow {
                            Text("Target UDID").foregroundStyle(.secondary)
                            Text(app.targetDeviceUDID).font(.body.monospaced())
                        }
                        if case .xcodeProject(let path, _, _, let commit) = app.source {
                            GridRow {
                                Text("Xcode Project").foregroundStyle(.secondary)
                                Text(path).lineLimit(1).truncationMode(.middle)
                            }
                            if let commit {
                                GridRow {
                                    Text("Snapshot Commit").foregroundStyle(.secondary)
                                    Text(String(commit.prefix(12))).font(.body.monospaced())
                                }
                            }
                        }
                    }
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("Sandbox Backups (Documents & Library · SHA-256)") {
                    if backups.isEmpty {
                        Text("No backups for this app yet. Click 'Backup Now' or 'Freeze App' to archive app data.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(10)
                    } else {
                        VStack(spacing: 8) {
                            ForEach(backups) { backup in
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("\(backup.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(backup.trigger.rawValue)")
                                            .font(.subheadline.weight(.medium))
                                        Text("\(backup.fileCount) files · \(AppleSyncFormatting.bytesString(backup.sizeBytes)) · SHA-256 \(String(backup.sha256Digest.prefix(12)))…")
                                            .font(.caption2.monospaced())
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if app.state == .frozen {
                                        Button("Thaw with this") {
                                            onThaw(backup.backupID)
                                        }
                                        .buttonStyle(.borderedProminent)
                                        .controlSize(.small)
                                        .disabled(isBusy)
                                    } else {
                                        Button("Restore") {
                                            onRestoreBackup(backup)
                                        }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)
                                        .disabled(isBusy)
                                    }
                                    Button("Delete", role: .destructive) {
                                        onDeleteBackup(backup)
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                    .disabled(isBusy)
                                }
                                .padding(8)
                                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                            }
                        }
                        .padding(4)
                    }
                }
            }
            .padding(22)
        }
    }
}

private struct InfrastructurePane: View {
    @Bindable var viewModel: AppleSyncViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("iOS Devices & Xcode Accounts")
                    .font(.title2.bold())

                GroupBox("Paired Physical Devices (CoreDevice / devicectl)") {
                    if viewModel.devices.isEmpty {
                        Text("No devices detected. Connect your iPhone via USB once with Xcode and enable Wi-Fi syncing (Connect via network).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(8)
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(viewModel.devices) { dev in
                                HStack {
                                    Image(systemName: dev.transportType == "wired" ? "cable.connector" : "wifi")
                                    VStack(alignment: .leading) {
                                        Text(dev.marketingName).font(.headline)
                                        Text("UDID: \(dev.udid) · State: \(dev.connectionState ?? "n/a")")
                                            .font(.caption.monospaced())
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    let activeCount = viewModel.activeApps(forDeviceUDID: dev.udid).count
                                    Text("\(activeCount)/3 slots")
                                        .font(.caption.bold())
                                }
                                .padding(6)
                            }
                        }
                    }
                }

                GroupBox("Multi-Account Apple Development Certificates in Keychain") {
                    if viewModel.teams.isEmpty {
                        Text("No valid Apple Development certificates found. Sign in under Xcode > Settings > Accounts with one or more Apple IDs.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(8)
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(viewModel.teams) { team in
                                HStack {
                                    Image(systemName: "person.crop.circle.badge.checkmark")
                                        .foregroundStyle(.green)
                                    VStack(alignment: .leading) {
                                        Text(team.commonName).font(.subheadline.weight(.medium))
                                        Text("Team ID: \(team.teamID) · SHA-1: \(String(team.sha1Fingerprint.prefix(12)))…")
                                            .font(.caption.monospaced())
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .padding(6)
                            }
                        }
                    }
                }

                GroupBox("macOS Keychain Note (Silent Background Sync)") {
                    Text("On the first automatic signing run, macOS may ask 'codesign wants to access key...': always click 'Always Allow' so background syncs on Days 4-6 succeed without modal prompts.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(6)
                }
            }
            .padding(22)
        }
    }
}

private struct EventsLogPane: View {
    let events: [SyncEvent]
    let alerts: [SyncAlert]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Notifications & Activity Log")
                    .font(.title2.bold())

                if !alerts.isEmpty {
                    GroupBox("Recent Notifications") {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(alerts) { alert in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("[\(alert.severity.rawValue.uppercased())] \(alert.title)")
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(alert.severity == .critical ? .red : .orange)
                                    Text(alert.body)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(6)
                            }
                        }
                    }
                }

                GroupBox("System Events") {
                    if events.isEmpty {
                        Text("No events recorded yet.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(8)
                    } else {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(events) { event in
                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: event.succeeded ? "checkmark.circle.fill" : "xmark.circle.fill")
                                        .foregroundStyle(event.succeeded ? .green : .red)
                                        .font(.caption)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text("\(event.kind) · \(event.timestamp.formatted(date: .abbreviated, time: .shortened))")
                                            .font(.caption.monospaced())
                                            .foregroundStyle(.secondary)
                                        Text(event.message)
                                            .font(.caption)
                                    }
                                }
                                .padding(.vertical, 3)
                            }
                        }
                    }
                }
            }
            .padding(22)
        }
    }
}
