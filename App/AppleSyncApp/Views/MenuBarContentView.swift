import AppKit
import AppleSyncCore
import SwiftUI

struct MenuBarContentView: View {
    @Bindable var viewModel: AppleSyncViewModel
    @Environment(\.openWindow) private var openWindow

    private var targetUDID: String? {
        viewModel.activeTargetUDID
    }

    private var activeApps: [ManagedAppRecord] {
        viewModel.activeApps(forDeviceUDID: targetUDID)
    }

    private var frozenApps: [ManagedAppRecord] {
        viewModel.frozenApps(forDeviceUDID: targetUDID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("AppleSync")
                        .font(.headline)
                    if let dev = viewModel.devices.first(where: { $0.udid == targetUDID }) {
                        Label(
                            "\(dev.marketingName) · \(dev.connectionState ?? "detected")",
                            systemImage: dev.transportType == "wired" ? "cable.connector" : "wifi"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    } else {
                        Text("No iPhone connected right now")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if viewModel.isBusy {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Button {
                            viewModel.cancelCurrentSync()
                        } label: {
                            Image(systemName: "stop.circle.fill")
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.plain)
                        .help("Stop running operation")
                    }
                } else {
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
                        .font(.caption.weight(.medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .tint(viewModel.isDaemonPaused ? .green : .orange)
                }
            }

            if viewModel.isDaemonPaused {
                HStack(spacing: 6) {
                    Image(systemName: "pause.circle.fill")
                        .foregroundStyle(.orange)
                    Text("Auto-sync daemon stopped. Manual Sync and Swap are still available.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            }

            // Active 3-slot gauge
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Personal Team Free Slots")
                        .font(.caption.weight(.medium))
                    Spacer()
                    Text("\(activeApps.count) / 3 used")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(activeApps.count >= 3 ? .orange : .secondary)
                }
                ProgressView(value: Double(min(activeApps.count, 3)), total: 3)
                    .tint(activeApps.count >= 3 ? .orange : .accentColor)
            }

            if !viewModel.recentAlerts.isEmpty, let latest = viewModel.recentAlerts.first {
                VStack(alignment: .leading, spacing: 2) {
                    Text(latest.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(latest.severity == .critical ? .red : .orange)
                    Text(latest.body)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            }

            Divider()

            if activeApps.isEmpty {
                Text("No active apps yet. Open the dashboard to add an Xcode project or clean .ipa file.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(activeApps) { app in
                        HStack(spacing: 8) {
                            Image(systemName: app.state.symbolName)
                                .foregroundStyle(app.state.badgeColor)
                                .font(.subheadline)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(app.displayName)
                                    .font(.subheadline.weight(.medium))
                                    .lineLimit(1)
                                HStack(spacing: 6) {
                                    Text(app.countdownText)
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(app.countdownColor)
                                    Text("· Team \(app.teamID)")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    if app.autoSyncPaused {
                                        Text("· Auto-sync paused")
                                            .font(.caption2.weight(.semibold))
                                            .foregroundStyle(.orange)
                                    }
                                }
                            }
                            Spacer()
                            Button {
                                Task { await viewModel.toggleAppAutoSync(app.id, paused: !app.autoSyncPaused) }
                            } label: {
                                Image(systemName: app.autoSyncPaused ? "play.fill" : "pause.fill")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                            .tint(app.autoSyncPaused ? .green : .orange)
                            .help(app.autoSyncPaused ? "Resume auto-sync for this app" : "Pause auto-sync for this app")

                            Button("Sync") {
                                Task { await viewModel.syncAppNow(app.id) }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                            .disabled(viewModel.isBusy)
                        }
                    }
                }
            }

            if !frozenApps.isEmpty {
                Text("Mac Vault: \(frozenApps.count) frozen app(s) ready to swap")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            HStack {
                Button {
                    openDashboardWindow()
                } label: {
                    Label("Open Dashboard", systemImage: "macwindow")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Button {
                    Task { await viewModel.runSyncCycleNow() }
                } label: {
                    Label("Run Cycle", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(viewModel.isBusy)

                Spacer()

                Button("Quit") {
                    NSApp.terminate(nil)
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Toggle(
                "Launch automatically at login",
                isOn: Binding(
                    get: { viewModel.launchAtLoginEnabled },
                    set: { viewModel.toggleLaunchAtLogin($0) }
                )
            )
            .font(.caption)
        }
        .padding(14)
        .frame(width: 340)
        .onAppear {
            viewModel.startIfNeeded()
        }
        .task {
            await viewModel.refreshAll()
        }
    }

    private func openDashboardWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "dashboard")
    }
}
