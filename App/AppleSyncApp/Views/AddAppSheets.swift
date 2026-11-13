import AppKit
import AppleSyncCore
import SwiftUI

struct AddXcodeAppSheet: View {
    @Bindable var viewModel: AppleSyncViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var projectPath = ""
    @State private var inspection: XcodeProjectInspection?
    @State private var availableSchemes: [String] = []
    @State private var availableConfigurations: [String] = ["Release", "Debug"]
    @State private var inspectionError: String?
    @State private var isInspecting = false

    @State private var selectedScheme = ""
    @State private var configuration = "Release"
    @State private var lastInspectedPath = ""
    @State private var lastInspectedScheme = ""
    @State private var lastInspectedConfiguration = "Release"
    @State private var lastDetectedDisplayName = ""

    @State private var selectedTeamID = ""
    @State private var selectedDeviceUDID = ""
    @State private var customDisplayName = ""
    @State private var stripExtensions = true
    @State private var installImmediately = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add Xcode Project")
                .font(.title2.bold())

            Text("AppleSync builds an isolated snapshot of your project for background syncing (uncommitted local edits are never modified by automatic syncs).")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    TextField("Path to .xcodeproj, .xcworkspace, or project folder", text: $projectPath)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit {
                            triggerProjectInspection()
                        }
                    Button("Inspect") {
                        triggerProjectInspection()
                    }
                    .disabled(projectPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isInspecting)
                    Button("Choose…") {
                        chooseXcodeProject()
                    }
                }

                if !lastInspectedPath.isEmpty {
                    Text("Detected container: \(lastInspectedPath)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            if isInspecting {
                ProgressView("Inspecting Xcode schemes and Bundle ID…")
            } else if let inspectionError {
                Label(inspectionError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            if inspection != nil || !availableSchemes.isEmpty {
                Form {
                    if let inspection {
                        LabeledContent("Original Bundle ID", value: inspection.bundleIdentifier)
                        LabeledContent("Version", value: "\(inspection.marketingVersion) (\(inspection.buildVersion))")
                    }

                    Picker("Scheme", selection: $selectedScheme) {
                        ForEach(availableSchemes, id: \.self) { scheme in
                            Text(scheme).tag(scheme)
                        }
                    }
                    .onChange(of: selectedScheme) { _, newScheme in
                        guard !isInspecting,
                              !lastInspectedPath.isEmpty,
                              !newScheme.isEmpty,
                              newScheme != lastInspectedScheme else {
                            return
                        }
                        Task {
                            await inspectSelectedProject(
                                URL(fileURLWithPath: lastInspectedPath),
                                preferredScheme: newScheme
                            )
                        }
                    }

                    Picker("Configuration", selection: $configuration) {
                        ForEach(availableConfigurations, id: \.self) { cfg in
                            Text(cfg).tag(cfg)
                        }
                    }
                    .onChange(of: configuration) { _, newConfig in
                        guard !isInspecting,
                              !lastInspectedPath.isEmpty,
                              newConfig != lastInspectedConfiguration else {
                            return
                        }
                        Task {
                            await inspectSelectedProject(
                                URL(fileURLWithPath: lastInspectedPath),
                                preferredScheme: selectedScheme.isEmpty ? nil : selectedScheme
                            )
                        }
                    }

                    TextField("Display Name (optional)", text: $customDisplayName)
                }
                .formStyle(.grouped)
                .frame(maxHeight: 220)
            }

            GroupBox("Destination & Multi-Account Signing") {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Xcode Account / Certificate", selection: $selectedTeamID) {
                        ForEach(viewModel.teams) { team in
                            Text("\(team.commonName) (\(team.teamID))").tag(team.teamID)
                        }
                    }

                    Picker("Target iOS Device", selection: $selectedDeviceUDID) {
                        ForEach(viewModel.devices) { device in
                            Text("\(device.marketingName) (\(device.udid))").tag(device.udid)
                        }
                    }

                    Toggle("Strip nested extensions (Widgets/Watch) when required for Free profile limits", isOn: $stripExtensions)

                    Toggle("Save directly to Frozen Vault (skip immediate install)", isOn: Binding(
                        get: { !installImmediately },
                        set: { installImmediately = !$0 }
                    ))
                }
                .padding(6)
            }

            if viewModel.teams.isEmpty || viewModel.devices.isEmpty {
                Text("Note: make sure at least one Xcode signing certificate in Keychain and one paired iPhone are available.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            SheetActionStatusBanner(viewModel: viewModel)

            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Import & Sign") {
                    Task {
                        let ok = await viewModel.registerXcodeApp(
                            projectPath: lastInspectedPath.isEmpty ? projectPath : lastInspectedPath,
                            scheme: selectedScheme.isEmpty ? nil : selectedScheme,
                            configuration: configuration,
                            stripExtensions: stripExtensions,
                            teamID: selectedTeamID,
                            deviceUDID: selectedDeviceUDID,
                            displayNameOverride: customDisplayName.isEmpty ? nil : customDisplayName,
                            installImmediately: installImmediately
                        )
                        if ok { dismiss() }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(inspection == nil || isInspecting || selectedTeamID.isEmpty || selectedDeviceUDID.isEmpty || viewModel.isBusy)
            }
        }
        .padding(20)
        .frame(width: 580)
        .onAppear {
            viewModel.errorMessage = nil
            if selectedTeamID.isEmpty {
                selectedTeamID = viewModel.teams.first?.teamID ?? ""
            }
            if selectedDeviceUDID.isEmpty {
                selectedDeviceUDID = viewModel.activeTargetUDID ?? viewModel.devices.first?.udid ?? ""
            }
        }
    }

    private func triggerProjectInspection() {
        let trimmed = projectPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let expanded = (trimmed as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)
        projectPath = url.path
        Task { await inspectSelectedProject(url, preferredScheme: nil) }
    }

    private func chooseXcodeProject() {
        let panel = NSOpenPanel()
        panel.message = "Select an .xcodeproj, .xcworkspace, or project folder"
        panel.prompt = "Select"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false

        let filter = OpenPanelExtensionFilter(allowedExtensions: ["xcodeproj", "xcworkspace"])
        panel.delegate = filter
        withExtendedLifetime(filter) {
            if panel.runModal() == .OK, let url = panel.url {
                projectPath = url.path
                Task { await inspectSelectedProject(url, preferredScheme: nil) }
            }
        }
    }

    private func inspectSelectedProject(_ url: URL, preferredScheme: String?) async {
        isInspecting = true
        inspectionError = nil
        viewModel.errorMessage = nil
        defer { isInspecting = false }

        do {
            let report = try await viewModel.coordinator.inspectXcodeProject(
                at: url,
                preferredScheme: preferredScheme,
                configuration: configuration
            )
            availableSchemes = report.schemes
            availableConfigurations = report.configurations.isEmpty ? ["Release", "Debug"] : report.configurations
            lastInspectedPath = report.projectPath
            lastInspectedScheme = report.selectedScheme
            lastInspectedConfiguration = report.selectedConfiguration
            projectPath = report.projectPath
            selectedScheme = report.selectedScheme
            configuration = report.selectedConfiguration
            inspection = report

            if preferredScheme == nil || customDisplayName.isEmpty || customDisplayName == lastDetectedDisplayName {
                customDisplayName = report.displayName
            }
            lastDetectedDisplayName = report.displayName

            if let detectedTeam = report.developmentTeam,
               viewModel.teams.contains(where: { $0.teamID == detectedTeam }) {
                selectedTeamID = detectedTeam
            }
        } catch {
            inspection = nil
            if preferredScheme == nil {
                availableSchemes = []
                availableConfigurations = ["Release", "Debug"]
                lastInspectedPath = ""
                lastInspectedScheme = ""
            } else {
                lastInspectedScheme = preferredScheme ?? ""
                lastInspectedConfiguration = configuration
            }
            inspectionError = error.localizedDescription
        }
    }
}

struct AddIPAAppSheet: View {
    @Bindable var viewModel: AppleSyncViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var ipaPath = ""
    @State private var report: IPAInspectionReport?
    @State private var inspectionError: String?
    @State private var isInspecting = false

    @State private var selectedTeamID = ""
    @State private var selectedDeviceUDID = ""
    @State private var customDisplayName = ""
    @State private var stripExtensions = true
    @State private var preferAdHocFastPath = true
    @State private var installImmediately = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Import Clean IPA")
                .font(.title2.bold())

            Text("Supports decrypted .ipa bundles (cryptid == 0, arm64) built by you or shared pre-TestFlight. If already Ad-Hoc signed for your iPhone UDID, AppleSync can skip re-signing and stay exempt from the 3 free slots.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                TextField("Path to .ipa or .app bundle", text: $ipaPath)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        triggerIPAInspection()
                    }
                Button("Inspect") {
                    triggerIPAInspection()
                }
                .disabled(ipaPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isInspecting)
                Button("Choose IPA…") {
                    chooseIPA()
                }
            }

            if isInspecting {
                ProgressView("Checking FairPlay encryption, arm64 binary, and Ad-Hoc profile…")
            } else if let inspectionError {
                Label(inspectionError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if let report {
                GroupBox("IPA Inspection") {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(report.displayName).font(.headline)
                            Spacer()
                            Text("v\(report.marketingVersion) (\(report.buildVersion))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text("Original Bundle ID: \(report.bundleIdentifier)")
                            .font(.caption.monospaced())

                        if report.isFairPlayEncrypted {
                            Label("BLOCKED: FairPlay-encrypted App Store IPA. Requires a clean unencrypted build.", systemImage: "lock.slash.fill")
                                .font(.caption)
                                .foregroundStyle(.red)
                        } else if !report.supportsArm64iOS {
                            Label("BLOCKED: No physical arm64 iOS binary found.", systemImage: "cpu")
                                .font(.caption)
                                .foregroundStyle(.red)
                        } else if report.canInstallUntouchedForTargetDevice {
                            Label("Ad-Hoc Fast-Path (1 year): valid embedded profile for your iPhone UDID. Does not use a free slot!", systemImage: "bolt.shield.fill")
                                .font(.caption)
                                .foregroundStyle(.purple)
                        } else {
                            Label("Clean & compatible (arm64). Will be re-signed under an isolated deterministic Bundle ID.", systemImage: "checkmark.seal.fill")
                                .font(.caption)
                                .foregroundStyle(.green)
                        }

                        if !report.nestedExtensions.isEmpty {
                            Text("Extensions found: \(report.nestedExtensions.joined(separator: ", "))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(6)
                }
            }

            GroupBox("Signing & Device Options") {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Xcode Account / Certificate", selection: $selectedTeamID) {
                        ForEach(viewModel.teams) { team in
                            Text("\(team.commonName) (\(team.teamID))").tag(team.teamID)
                        }
                    }

                    Picker("Target iOS Device", selection: $selectedDeviceUDID) {
                        ForEach(viewModel.devices) { device in
                            Text("\(device.marketingName) (\(device.udid))").tag(device.udid)
                        }
                    }
                    .onChange(of: selectedDeviceUDID) { _, _ in
                        if !ipaPath.isEmpty {
                            Task { await inspectSelectedIPA(URL(fileURLWithPath: ipaPath)) }
                        }
                    }

                    TextField("Display Name (optional)", text: $customDisplayName)
                    Toggle("Use untouched Ad-Hoc fast-path when my UDID is provisioned", isOn: $preferAdHocFastPath)
                    Toggle("Strip nested extensions (Widgets/Watch) when required for Free profile limits", isOn: $stripExtensions)
                    Toggle("Save to Frozen Vault without installing right now", isOn: Binding(
                        get: { !installImmediately },
                        set: { installImmediately = !$0 }
                    ))
                }
                .padding(6)
            }

            SheetActionStatusBanner(viewModel: viewModel)

            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                let blocked = (report?.isFairPlayEncrypted ?? true) || !(report?.supportsArm64iOS ?? false)
                Button("Import & Sign") {
                    Task {
                        let ok = await viewModel.registerIPAApp(
                            ipaPath: ipaPath,
                            teamID: selectedTeamID,
                            deviceUDID: selectedDeviceUDID,
                            stripExtensions: stripExtensions,
                            preferOriginalAdHocIfValid: preferAdHocFastPath,
                            displayNameOverride: customDisplayName.isEmpty ? nil : customDisplayName,
                            installImmediately: installImmediately
                        )
                        if ok { dismiss() }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(report == nil || blocked || selectedTeamID.isEmpty || selectedDeviceUDID.isEmpty || viewModel.isBusy)
            }
        }
        .padding(20)
        .frame(width: 580)
        .onAppear {
            viewModel.errorMessage = nil
            if selectedTeamID.isEmpty {
                selectedTeamID = viewModel.teams.first?.teamID ?? ""
            }
            if selectedDeviceUDID.isEmpty {
                selectedDeviceUDID = viewModel.activeTargetUDID ?? viewModel.devices.first?.udid ?? ""
            }
        }
    }

    private func triggerIPAInspection() {
        let trimmed = ipaPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let expanded = (trimmed as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)
        ipaPath = url.path
        Task { await inspectSelectedIPA(url) }
    }

    private func chooseIPA() {
        let panel = NSOpenPanel()
        panel.message = "Select an .ipa file (or .app bundle)"
        panel.prompt = "Select"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false

        let filter = OpenPanelExtensionFilter(allowedExtensions: ["ipa", "app"])
        panel.delegate = filter
        withExtendedLifetime(filter) {
            if panel.runModal() == .OK, let url = panel.url {
                ipaPath = url.path
                Task { await inspectSelectedIPA(url) }
            }
        }
    }

    private func inspectSelectedIPA(_ url: URL) async {
        isInspecting = true
        inspectionError = nil
        defer { isInspecting = false }

        do {
            let res = try await viewModel.coordinator.inspectIPA(at: url, targetDeviceUDID: selectedDeviceUDID)
            report = res
            customDisplayName = res.displayName
        } catch {
            report = nil
            inspectionError = error.localizedDescription
        }
    }
}

struct SwapAppsSheet: View {
    @Bindable var viewModel: AppleSyncViewModel
    @Environment(\.dismiss) private var dismiss

    let deviceUDID: String
    @State private var selectedFreezeID: UUID?
    @State private var selectedThawID: UUID?
    @State private var selectedBackupID: UUID?

    private var activeApps: [ManagedAppRecord] {
        viewModel.activeApps(forDeviceUDID: deviceUDID)
    }

    private var frozenApps: [ManagedAppRecord] {
        viewModel.frozenApps(forDeviceUDID: deviceUDID)
    }

    private var thawBackups: [BackupManifest] {
        guard let selectedThawID else { return [] }
        return viewModel.backupsByAppID[selectedThawID] ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Swap Apps (Freeze ↔ Thaw)")
                .font(.title2.bold())

            Text("1. Creates a SHA-256 backup (Documents/Library) of the active app.\n2. Freezes (uninstalls) it only after verifying the backup on disk.\n3. Re-signs, reinstalls, and restores data for the selected frozen app.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Label("Note: CoreDevice backs up the sandbox (Documents & Library), but CANNOT export iOS Keychain items (stored login tokens).", systemImage: "key.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .padding(10)
                .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))

            Form {
                Picker("Active App to Freeze", selection: $selectedFreezeID) {
                    ForEach(activeApps) { app in
                        Text("\(app.displayName) (\(app.countdownText))").tag(Optional(app.id))
                    }
                }

                Picker("Frozen App to Thaw", selection: $selectedThawID) {
                    ForEach(frozenApps) { app in
                        Text(app.displayName).tag(Optional(app.id))
                    }
                }
                .onChange(of: selectedThawID) { _, newID in
                    if let newID {
                        selectedBackupID = (viewModel.backupsByAppID[newID] ?? []).first?.backupID
                    }
                }

                if !thawBackups.isEmpty {
                    Picker("Backup to Restore", selection: $selectedBackupID) {
                        Text("No restore (clean install)").tag(Optional<UUID>.none)
                        ForEach(thawBackups) { backup in
                            Text("\(backup.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(AppleSyncFormatting.bytesString(backup.sizeBytes))").tag(Optional(backup.backupID))
                        }
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Run Swap") {
                    guard let f = selectedFreezeID, let t = selectedThawID else { return }
                    Task {
                        await viewModel.swapApps(freezeID: f, thawID: t, restoreBackupID: selectedBackupID)
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedFreezeID == nil || selectedThawID == nil || viewModel.isBusy)
            }
        }
        .padding(20)
        .frame(width: 540)
        .onAppear {
            selectedFreezeID = activeApps.first?.id
            selectedThawID = frozenApps.first?.id
            if let t = selectedThawID {
                selectedBackupID = (viewModel.backupsByAppID[t] ?? []).first?.backupID
            }
        }
    }
}

@MainActor
private struct SheetActionStatusBanner: View {
    let viewModel: AppleSyncViewModel

    var body: some View {
        if viewModel.isBusy {
            ProgressView(viewModel.busyMessage ?? "Operation in progress…")
        } else if let error = viewModel.errorMessage, !error.isEmpty {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .textSelection(.enabled)
        }
    }
}

@MainActor
private final class OpenPanelExtensionFilter: NSObject, NSOpenSavePanelDelegate {
    private let allowedExtensions: Set<String>

    init(allowedExtensions: Set<String>) {
        self.allowedExtensions = Set(allowedExtensions.map { $0.lowercased() })
    }

    func panel(_ sender: Any, shouldEnable url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if allowedExtensions.contains(ext) {
            return true
        }
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            // Enable regular folders so user can navigate or select a project folder,
            // while still greying out unrelated bundles like .app inside Xcode picker unless allowed.
            let isPackage = (try? url.resourceValues(forKeys: [.isPackageKey]).isPackage) ?? false
            return !isPackage
        }
        return false
    }
}
