import Foundation
import CryptoKit

public protocol SigningServicing: Sendable {
    func discoverSigningTeams() async throws -> [TeamIdentitySummary]
    func inspectXcodeProject(
        at projectURL: URL,
        preferredScheme: String?,
        configuration: String
    ) async throws -> XcodeProjectInspection
    func inspectIPA(
        at ipaURL: URL,
        targetDeviceUDID: String
    ) async throws -> IPAInspectionReport
    func importBaseArtifact(
        appID: UUID,
        source: AppSource,
        teamID: String
    ) async throws -> (baseAppURL: URL, version: String, buildVersion: String)
    func stageAndSignApp(
        for app: ManagedAppRecord
    ) async throws -> SignedArtifactMetadata
}

public struct DualSourceSigningEngine: SigningServicing, Sendable {
    public let paths: AppleSyncPaths
    public let runner: any CommandRunning
    public let proxyGenerator: ProvisioningProxyGenerator

    public init(
        paths: AppleSyncPaths = AppleSyncPaths(),
        runner: any CommandRunning = SystemProcessRunner(),
        proxyGenerator: ProvisioningProxyGenerator? = nil
    ) {
        self.paths = paths
        self.runner = runner
        self.proxyGenerator = proxyGenerator ?? ProvisioningProxyGenerator(paths: paths, runner: runner)
    }

    // MARK: - 1. Discover Signing Teams

    public func discoverSigningTeams() async throws -> [TeamIdentitySummary] {
        let output = try await runner.run(
            "/usr/bin/security",
            arguments: ["find-identity", "-v", "-p", "codesigning"],
            timeout: 30
        )
        guard output.exitCode == 0 else {
            throw AppleSyncError.commandFailed(
                executable: "/usr/bin/security",
                exitCode: output.exitCode,
                stderr: output.stderrString
            )
        }

        return Self.parseIdentities(from: output.stdoutString)
    }

    public static func parseIdentities(from securityOutput: String) -> [TeamIdentitySummary] {
        var results: [TeamIdentitySummary] = []
        var seenSHA1 = Set<String>()

        for rawLine in securityOutput.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            if line.contains("CSSMERR_") {
                continue
            }

            guard let firstQuote = line.firstIndex(of: "\""),
                  let lastQuote = line.lastIndex(of: "\""),
                  firstQuote < lastQuote else {
                continue
            }

            let prefixPart = line[..<firstQuote]
            let commonName = String(line[line.index(after: firstQuote)..<lastQuote])

            guard commonName.hasPrefix("Apple Development:") || commonName.hasPrefix("iPhone Developer:") else {
                continue
            }

            let tokens = prefixPart.split(whereSeparator: \.isWhitespace)
            guard let sha1Candidate = tokens.first(where: { token in
                token.count == 40 && token.allSatisfy({ $0.isHexDigit })
            }) else {
                continue
            }

            guard let openParen = commonName.lastIndex(of: "("),
                  let closeParen = commonName.lastIndex(of: ")"),
                  openParen < closeParen else {
                continue
            }

            let teamID = String(commonName[commonName.index(after: openParen)..<closeParen])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard teamID.count == 10, teamID.allSatisfy({ $0.isLetter || $0.isNumber }) else {
                continue
            }

            let sha1 = String(sha1Candidate).uppercased()
            if seenSHA1.insert(sha1).inserted {
                results.append(TeamIdentitySummary(teamID: teamID, commonName: commonName, sha1Fingerprint: sha1))
            }
        }

        return results
    }

    // MARK: - 2. Inspect Xcode Project / Workspace

    private static let wellKnownIOSSubdirectories = ["ios", "iosApp", "example/ios", "app/ios"]
    private static let ignoredDiscoveryDirectoryNames: Set<String> = [
        "Pods", "build", ".build", ".dart_tool", "node_modules", ".git",
        "DerivedData", "SourcePackages", ".symlinks", "ephemeral", "Carthage", "vendor"
    ]

    public static func resolveXcodeContainerURL(at url: URL) throws -> URL {
        let fm = FileManager.default
        let standardized = url.standardizedFileURL
        guard fm.fileExists(atPath: standardized.path) else {
            throw AppleSyncError.invalidInput("Xcode project or workspace does not exist at \(standardized.path)")
        }

        let ext = standardized.pathExtension.lowercased()
        if ext == "xcworkspace" {
            return standardized
        }
        if ext == "xcodeproj" {
            return upgradeToSiblingWorkspaceIfNeeded(xcodeprojURL: standardized)
        }

        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: standardized.path, isDirectory: &isDir), isDir.boolValue else {
            throw AppleSyncError.invalidInput(
                "Unsupported path '\(standardized.path)'. Select a .xcodeproj, .xcworkspace, or a folder containing one."
            )
        }

        if let directMatch = firstXcodeContainer(in: standardized) {
            return directMatch
        }

        for relSubdir in wellKnownIOSSubdirectories {
            let candidateDir = standardized.appendingPathComponent(relSubdir, isDirectory: true)
            if fm.fileExists(atPath: candidateDir.path, isDirectory: &isDir), isDir.boolValue,
               let match = firstXcodeContainer(in: candidateDir) {
                return match
            }
        }

        if let deepMatch = findContainerViaBoundedBFS(in: standardized, maxDepth: 3) {
            return deepMatch
        }

        throw AppleSyncError.invalidInput(
            "Nessun file .xcodeproj o .xcworkspace trovato nella cartella '\(standardized.path)'."
        )
    }

    private static func upgradeToSiblingWorkspaceIfNeeded(xcodeprojURL: URL) -> URL {
        let fm = FileManager.default
        let parentDir = xcodeprojURL.deletingLastPathComponent()
        let stem = xcodeprojURL.deletingPathExtension().lastPathComponent
        let exactSiblingWorkspace = parentDir.appendingPathComponent("\(stem).xcworkspace", isDirectory: true)
        if fm.fileExists(atPath: exactSiblingWorkspace.path) {
            return exactSiblingWorkspace.standardizedFileURL
        }

        // Upgrade when CocoaPods is present alongside a differently named .xcworkspace in the same directory.
        let hasPods = fm.fileExists(atPath: parentDir.appendingPathComponent("Pods").path)
            || fm.fileExists(atPath: parentDir.appendingPathComponent("Podfile.lock").path)
        if hasPods {
            let children = (try? fm.contentsOfDirectory(
                at: parentDir,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []
            let workspaces = children
                .filter { $0.pathExtension.lowercased() == "xcworkspace" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            if workspaces.count == 1 {
                return workspaces[0].standardizedFileURL
            }
        }
        return xcodeprojURL
    }

    private static func firstXcodeContainer(in directory: URL) -> URL? {
        let children = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        let sorted = children.sorted { $0.lastPathComponent < $1.lastPathComponent }

        if let workspace = sorted.first(where: { $0.pathExtension.lowercased() == "xcworkspace" }) {
            return workspace.standardizedFileURL
        }
        if let project = sorted.first(where: { $0.pathExtension.lowercased() == "xcodeproj" }) {
            return project.standardizedFileURL
        }
        return nil
    }

    private static func findContainerViaBoundedBFS(in root: URL, maxDepth: Int) -> URL? {
        let fm = FileManager.default
        let skipExtensions: Set<String> = ["app", "framework", "xcassets", "lproj", "bundle", "xcodeproj", "xcworkspace"]
        var queue: [(dir: URL, depth: Int)] = [(root, 0)]
        var index = 0

        while index < queue.count {
            let current = queue[index]
            index += 1

            let children = (try? fm.contentsOfDirectory(
                at: current.dir,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            let sorted = children.sorted { $0.lastPathComponent < $1.lastPathComponent }

            if let workspace = sorted.first(where: { $0.pathExtension.lowercased() == "xcworkspace" }) {
                return workspace.standardizedFileURL
            }
            if let project = sorted.first(where: { $0.pathExtension.lowercased() == "xcodeproj" }) {
                return project.standardizedFileURL
            }

            guard current.depth < maxDepth else { continue }
            for child in sorted {
                let name = child.lastPathComponent
                let ext = child.pathExtension.lowercased()
                if ignoredDiscoveryDirectoryNames.contains(name) || skipExtensions.contains(ext) {
                    continue
                }
                let isDir = (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                if isDir {
                    queue.append((child, current.depth + 1))
                }
            }
        }
        return nil
    }

    public static func parseReferencedProjectPaths(fromWorkspaceContentsXML xml: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"location\s*=\s*"([^"]+)""#) else {
            return []
        }
        let nsRange = NSRange(xml.startIndex..<xml.endIndex, in: xml)
        var results: [String] = []
        for match in regex.matches(in: xml, range: nsRange) {
            guard match.numberOfRanges >= 2,
                  let range = Range(match.range(at: 1), in: xml) else {
                continue
            }
            var raw = String(xml[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            for prefix in ["group:", "container:", "self:"] {
                if raw.hasPrefix(prefix) {
                    raw = String(raw.dropFirst(prefix.count))
                    break
                }
            }
            let lower = raw.lowercased()
            guard lower.hasSuffix(".xcodeproj"),
                  !lower.hasPrefix("pods/"),
                  !lower.contains("/pods/"),
                  lower != "pods.xcodeproj" else {
                continue
            }
            results.append(raw)
        }
        return results
    }

    public static func rankSchemes(
        _ allSchemes: [String],
        containerURL: URL,
        referencedAppSchemes: Set<String> = []
    ) -> [String] {
        let containerStem = containerURL.deletingPathExtension().lastPathComponent
        var seen = Set<String>()
        let unique = allSchemes.filter { seen.insert($0).inserted }

        func priority(for scheme: String) -> Int {
            let lower = scheme.lowercased()
            let isPodAggregate = lower.hasPrefix("pods-")
            let isTest = lower.hasSuffix("tests") || lower.hasSuffix("uitests")
            let isSPMGenerated = lower.hasSuffix("swiftpackage") || lower == "flutter"
            let isResourceBundle = scheme.contains("-") && !referencedAppSchemes.contains(scheme)

            if scheme == containerStem && !isPodAggregate && !isTest && !isSPMGenerated {
                return 0
            }
            if referencedAppSchemes.contains(scheme) && !isTest && !isSPMGenerated && !isPodAggregate {
                return 1
            }
            if !isPodAggregate && !isTest && !isSPMGenerated && !isResourceBundle {
                return 2
            }
            if !isPodAggregate && !isTest && !isSPMGenerated {
                return 3
            }
            return 4
        }

        return unique.enumerated()
            .sorted { lhs, rhs in
                let p1 = priority(for: lhs.element)
                let p2 = priority(for: rhs.element)
                return p1 != p2 ? p1 < p2 : lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    public static func resolveConfiguration(requested: String, available: [String]) -> String {
        guard !available.isEmpty else {
            return requested.isEmpty ? "Release" : requested
        }
        let trimmed = requested.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            if let exact = available.first(where: { $0 == trimmed }) {
                return exact
            }
            if let ciExact = available.first(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
                return ciExact
            }
            if let partial = available.first(where: { $0.localizedCaseInsensitiveContains(trimmed) }) {
                return partial
            }
        }
        if let releaseExact = available.first(where: { $0.caseInsensitiveCompare("Release") == .orderedSame }) {
            return releaseExact
        }
        if let releaseLike = available.first(where: { $0.localizedCaseInsensitiveContains("release") }) {
            return releaseLike
        }
        if let profile = available.first(where: { $0.caseInsensitiveCompare("Profile") == .orderedSame }) {
            return profile
        }
        if let nonDebug = available.first(where: { !$0.localizedCaseInsensitiveContains("debug") }) {
            return nonDebug
        }
        return available[0]
    }

    public static func isApplicationTarget(_ buildSettings: [String: String]) -> Bool {
        let productType = buildSettings["PRODUCT_TYPE"] ?? ""
        let wrapperExt = (buildSettings["WRAPPER_EXTENSION"] ?? "").lowercased()
        guard productType == "com.apple.product-type.application" ||
              (wrapperExt == "app" && !productType.contains("watchapp") && !productType.contains("on-demand-install-capable")) else {
            return false
        }
        let platform = (buildSettings["PLATFORM_NAME"] ?? "").lowercased()
        if !platform.isEmpty && platform != "iphoneos" && platform != "iphonesimulator" {
            return false
        }
        let supported = (buildSettings["SUPPORTED_PLATFORMS"] ?? "").lowercased()
        if !supported.isEmpty && !supported.contains("iphoneos") {
            return false
        }
        return true
    }

    public static func expandBuildSettingVariables(in rawValue: String, settings: [String: String]) -> String? {
        var resolved = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !resolved.isEmpty else { return nil }

        guard let regex = try? NSRegularExpression(pattern: #"\$\(([^)]+)\)|\$\{([^}]+)\}"#) else {
            return resolved
        }

        for _ in 0..<3 {
            let nsRange = NSRange(resolved.startIndex..<resolved.endIndex, in: resolved)
            let matches = regex.matches(in: resolved, range: nsRange)
            if matches.isEmpty { break }

            var replacedAny = false
            var mutable = resolved
            for match in matches.reversed() {
                let keyRange = match.range(at: 1).location != NSNotFound ? match.range(at: 1) : match.range(at: 2)
                guard let fullSwiftRange = Range(match.range, in: mutable),
                      let keySwiftRange = Range(keyRange, in: mutable) else { continue }
                let rawKey = String(mutable[keySwiftRange])
                let parts = rawKey.split(separator: ":", maxSplits: 1)
                let baseKey = String(parts[0])
                if var val = settings[baseKey], !val.isEmpty {
                    if parts.count == 2 {
                        val = applyBuildSettingModifier(String(parts[1]), to: val)
                    }
                    mutable.replaceSubrange(fullSwiftRange, with: val)
                    replacedAny = true
                }
            }
            resolved = mutable
            if !replacedAny { break }
        }

        let trimmed = resolved.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.contains("$(") || trimmed.contains("${") {
            return nil
        }
        return trimmed
    }

    private static func applyBuildSettingModifier(_ modifier: String, to value: String) -> String {
        switch modifier.lowercased() {
        case "lower":
            return value.lowercased()
        case "upper":
            return value.uppercased()
        case "rfc1034identifier":
            let scalars = value.unicodeScalars.map { scalar -> Character in
                if CharacterSet.alphanumerics.contains(scalar) || scalar == "." || scalar == "-" {
                    return Character(scalar)
                }
                return "-"
            }
            return String(scalars)
        case "identifier":
            let scalars = value.unicodeScalars.map { scalar -> Character in
                CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : "_"
            }
            return String(scalars)
        default:
            return value
        }
    }

    public func inspectXcodeProject(
        at projectURL: URL,
        preferredScheme: String? = nil,
        configuration: String = "Release"
    ) async throws -> XcodeProjectInspection {
        let resolvedURL = try Self.resolveXcodeContainerURL(at: projectURL)
        let cleanPath = resolvedURL.path

        let isWorkspace = resolvedURL.pathExtension.lowercased() == "xcworkspace"
        let containerFlag = isWorkspace ? "-workspace" : "-project"

        let listOut = try await runner.run(
            "/usr/bin/xcodebuild",
            arguments: [containerFlag, cleanPath, "-list", "-json"],
            timeout: 60
        )
        guard listOut.exitCode == 0 else {
            throw AppleSyncError.commandFailed(
                executable: "/usr/bin/xcodebuild",
                exitCode: listOut.exitCode,
                stderr: listOut.stderrString
            )
        }

        let listResponse = try JSONDecoder().decode(XcodeListJSON.self, from: listOut.stdoutData)
        let rawSchemes = listResponse.project?.schemes ?? listResponse.workspace?.schemes ?? []
        guard !rawSchemes.isEmpty else {
            throw AppleSyncError.invalidInput("No shared or visible schemes found in \(cleanPath)")
        }

        var referencedAppSchemes = Set<String>()
        var discoveredConfigurations = listResponse.project?.configurations ?? listResponse.workspace?.configurations ?? []
        if isWorkspace {
            let meta = await discoverWorkspaceMetadata(inWorkspaceURL: resolvedURL)
            referencedAppSchemes = meta.schemes
            for cfg in meta.configurations where !discoveredConfigurations.contains(cfg) {
                discoveredConfigurations.append(cfg)
            }
        }
        if discoveredConfigurations.isEmpty {
            discoveredConfigurations = ["Release", "Debug"]
        }

        let selectedConfiguration = Self.resolveConfiguration(requested: configuration, available: discoveredConfigurations)
        let orderedSchemes = Self.rankSchemes(
            rawSchemes,
            containerURL: resolvedURL,
            referencedAppSchemes: referencedAppSchemes
        )

        let selectedScheme: String
        let chosenSettings: [String: String]

        if let preferredScheme, !preferredScheme.isEmpty {
            guard rawSchemes.contains(preferredScheme) else {
                throw AppleSyncError.invalidInput(
                    "Scheme '\(preferredScheme)' not found in \(cleanPath). Available schemes: \(rawSchemes.joined(separator: ", "))"
                )
            }
            let entries = try await fetchBuildSettings(
                containerFlag: containerFlag,
                containerPath: cleanPath,
                scheme: preferredScheme,
                configuration: selectedConfiguration
            )
            guard let appSettings = entries.first(where: { Self.isApplicationTarget($0.buildSettings) })?.buildSettings else {
                throw AppleSyncError.invalidInput(
                    "Lo scheme '\(preferredScheme)' non compila un'app iOS (.app). Seleziona lo scheme principale dell'app."
                )
            }
            selectedScheme = preferredScheme
            chosenSettings = appSettings
        } else {
            var matched: (scheme: String, settings: [String: String])?
            for candidate in orderedSchemes.prefix(12) {
                if let entries = try? await fetchBuildSettings(
                    containerFlag: containerFlag,
                    containerPath: cleanPath,
                    scheme: candidate,
                    configuration: selectedConfiguration
                ),
                   let appSettings = entries.first(where: { Self.isApplicationTarget($0.buildSettings) })?.buildSettings {
                    matched = (candidate, appSettings)
                    break
                }
            }
            guard let resolvedMatch = matched else {
                throw AppleSyncError.invalidInput(
                    "Nessuno scheme iOS eseguibile (.app) trovato in \(cleanPath). Schemi rilevati: \(orderedSchemes.prefix(10).joined(separator: ", "))"
                )
            }
            selectedScheme = resolvedMatch.scheme
            chosenSettings = resolvedMatch.settings
        }

        guard let rawBundleID = nonEmpty(chosenSettings["PRODUCT_BUNDLE_IDENTIFIER"]),
              let bundleID = Self.expandBuildSettingVariables(in: rawBundleID, settings: chosenSettings) else {
            throw AppleSyncError.invalidInput("Unable to resolve PRODUCT_BUNDLE_IDENTIFIER for scheme '\(selectedScheme)'")
        }

        let projectInfoPlist = readProjectInfoPlist(from: chosenSettings, containerURL: resolvedURL)
        let expandedPlistDisplayName = (projectInfoPlist["CFBundleDisplayName"] as? String)
            .flatMap { Self.expandBuildSettingVariables(in: $0, settings: chosenSettings) }
        let expandedPlistBundleName = (projectInfoPlist["CFBundleName"] as? String)
            .flatMap { Self.expandBuildSettingVariables(in: $0, settings: chosenSettings) }
        let expandedPlistShortVersion = (projectInfoPlist["CFBundleShortVersionString"] as? String)
            .flatMap { Self.expandBuildSettingVariables(in: $0, settings: chosenSettings) }
        let expandedPlistBuildVersion = (projectInfoPlist["CFBundleVersion"] as? String)
            .flatMap { Self.expandBuildSettingVariables(in: $0, settings: chosenSettings) }

        let displayName = nonEmpty(chosenSettings["INFOPLIST_KEY_CFBundleDisplayName"])
            .flatMap { Self.expandBuildSettingVariables(in: $0, settings: chosenSettings) }
            ?? expandedPlistDisplayName
            ?? expandedPlistBundleName
            ?? nonEmpty(chosenSettings["PRODUCT_NAME"])
            ?? selectedScheme
        let team = nonEmpty(chosenSettings["DEVELOPMENT_TEAM"])
        let marketingVersion = nonEmpty(chosenSettings["MARKETING_VERSION"])
            .flatMap { Self.expandBuildSettingVariables(in: $0, settings: chosenSettings) }
            ?? expandedPlistShortVersion
            ?? nonEmpty(chosenSettings["FLUTTER_BUILD_NAME"])
            ?? "1.0"
        let buildVersion = nonEmpty(chosenSettings["CURRENT_PROJECT_VERSION"])
            .flatMap { Self.expandBuildSettingVariables(in: $0, settings: chosenSettings) }
            ?? expandedPlistBuildVersion
            ?? nonEmpty(chosenSettings["FLUTTER_BUILD_NUMBER"])
            ?? "1"

        return XcodeProjectInspection(
            projectPath: cleanPath,
            isWorkspace: isWorkspace,
            schemes: orderedSchemes,
            selectedScheme: selectedScheme,
            configurations: discoveredConfigurations,
            selectedConfiguration: selectedConfiguration,
            bundleIdentifier: bundleID,
            displayName: displayName,
            developmentTeam: team,
            marketingVersion: marketingVersion,
            buildVersion: buildVersion
        )
    }

    private func discoverWorkspaceMetadata(inWorkspaceURL workspaceURL: URL) async -> (schemes: Set<String>, configurations: [String]) {
        let contentsURL = workspaceURL.appendingPathComponent("contents.xcworkspacedata", isDirectory: false)
        guard let xml = try? String(contentsOf: contentsURL, encoding: .utf8) else {
            return ([], [])
        }
        let baseDir = workspaceURL.deletingLastPathComponent()
        let relativeProjects = Self.parseReferencedProjectPaths(fromWorkspaceContentsXML: xml)
        var schemes = Set<String>()
        var configurations: [String] = []

        for relPath in relativeProjects {
            let projURL = baseDir.appendingPathComponent(relPath).standardizedFileURL
            guard FileManager.default.fileExists(atPath: projURL.path) else { continue }
            guard let out = try? await runner.run(
                "/usr/bin/xcodebuild",
                arguments: ["-project", projURL.path, "-list", "-json"],
                timeout: 30
            ),
                  out.exitCode == 0,
                  let list = try? JSONDecoder().decode(XcodeListJSON.self, from: out.stdoutData) else {
                continue
            }
            for s in list.project?.schemes ?? [] {
                schemes.insert(s)
            }
            for c in list.project?.configurations ?? [] where !configurations.contains(c) {
                configurations.append(c)
            }
        }
        return (schemes, configurations)
    }

    private func fetchBuildSettings(
        containerFlag: String,
        containerPath: String,
        scheme: String,
        configuration: String
    ) async throws -> [XcodeBuildSettingsEntry] {
        let settingsOut = try await runner.run(
            "/usr/bin/xcodebuild",
            arguments: [
                containerFlag, containerPath,
                "-scheme", scheme,
                "-configuration", configuration,
                "-sdk", "iphoneos",
                "-destination", "generic/platform=iOS",
                "-showBuildSettings",
                "-json"
            ],
            timeout: 120
        )
        guard settingsOut.exitCode == 0 else {
            throw AppleSyncError.commandFailed(
                executable: "/usr/bin/xcodebuild",
                exitCode: settingsOut.exitCode,
                stderr: settingsOut.stderrString
            )
        }
        return try JSONDecoder().decode([XcodeBuildSettingsEntry].self, from: settingsOut.stdoutData)
    }

    private func readProjectInfoPlist(from settings: [String: String], containerURL: URL) -> [String: Any] {
        guard let rawSetting = nonEmpty(settings["INFOPLIST_FILE"]) else {
            return [:]
        }
        let expandedSetting = Self.expandBuildSettingVariables(in: rawSetting, settings: settings) ?? rawSetting
        let infoURL: URL
        if expandedSetting.hasPrefix("/") {
            infoURL = URL(fileURLWithPath: expandedSetting)
        } else {
            let rootPath = nonEmpty(settings["SRCROOT"])
                ?? nonEmpty(settings["PROJECT_DIR"])
                ?? containerURL.deletingLastPathComponent().path
            infoURL = URL(fileURLWithPath: rootPath).appendingPathComponent(expandedSetting)
        }
        return (try? readPlistDictionary(at: infoURL.standardizedFileURL)) ?? [:]
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    // MARK: - 3. Inspect IPA / App Bundle

    public func inspectIPA(
        at ipaURL: URL,
        targetDeviceUDID: String
    ) async throws -> IPAInspectionReport {
        let cleanURL = ipaURL.standardizedFileURL
        let fm = FileManager.default
        guard fm.fileExists(atPath: cleanURL.path) else {
            throw AppleSyncError.invalidInput("IPA or app bundle not found at \(cleanURL.path)")
        }

        if cleanURL.pathExtension.lowercased() == "app" {
            return try await inspectAppBundle(
                at: cleanURL,
                originalSourcePath: cleanURL.path,
                targetDeviceUDID: targetDeviceUDID
            )
        }

        let tempDir = fm.temporaryDirectory.appendingPathComponent("applesync-inspect-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        let unpackOut = try await runner.run(
            "/usr/bin/ditto",
            arguments: ["-x", "-k", cleanURL.path, tempDir.path],
            timeout: 120
        )
        guard unpackOut.exitCode == 0 else {
            throw AppleSyncError.invalidInput("Failed to unpack IPA at \(cleanURL.path): \(unpackOut.stderrString)")
        }

        let appBundleURL = try locateAppBundle(inExtractedIPADirectory: tempDir)
        return try await inspectAppBundle(
            at: appBundleURL,
            originalSourcePath: cleanURL.path,
            targetDeviceUDID: targetDeviceUDID
        )
    }

    public func inspectAppBundle(
        at appBundleURL: URL,
        originalSourcePath: String,
        targetDeviceUDID: String
    ) async throws -> IPAInspectionReport {
        let fm = FileManager.default
        let infoPlistURL = appBundleURL.appendingPathComponent("Info.plist", isDirectory: false)
        guard fm.fileExists(atPath: infoPlistURL.path) else {
            throw AppleSyncError.invalidInput("Missing Info.plist in \(appBundleURL.path)")
        }

        let plistDict = try readPlistDictionary(at: infoPlistURL)
        guard let bundleID = plistDict["CFBundleIdentifier"] as? String, !bundleID.isEmpty else {
            throw AppleSyncError.invalidInput("Missing CFBundleIdentifier in \(infoPlistURL.path)")
        }
        guard let executableName = plistDict["CFBundleExecutable"] as? String, !executableName.isEmpty else {
            throw AppleSyncError.invalidInput("Missing CFBundleExecutable in \(infoPlistURL.path)")
        }

        let displayName = (plistDict["CFBundleDisplayName"] as? String)
            ?? (plistDict["CFBundleName"] as? String)
            ?? appBundleURL.deletingPathExtension().lastPathComponent
        let marketingVersion = (plistDict["CFBundleShortVersionString"] as? String) ?? "1.0"
        let buildVersion = (plistDict["CFBundleVersion"] as? String) ?? "1"

        let executableURL = appBundleURL.appendingPathComponent(executableName, isDirectory: false)
        guard fm.fileExists(atPath: executableURL.path) else {
            throw AppleSyncError.invalidInput("Main executable '\(executableName)' not found in \(appBundleURL.path)")
        }

        let otoolOut = try await runner.run(
            "/usr/bin/otool",
            arguments: ["-l", executableURL.path],
            timeout: 30
        )
        guard otoolOut.exitCode == 0 else {
            throw AppleSyncError.commandFailed(
                executable: "/usr/bin/otool",
                exitCode: otoolOut.exitCode,
                stderr: otoolOut.stderrString
            )
        }
        let isEncrypted = Self.parseFairPlayEncrypted(fromOtoolOutput: otoolOut.stdoutString)

        let vtoolOut = try await runner.run(
            "/usr/bin/vtool",
            arguments: ["-show-build", executableURL.path],
            timeout: 30
        )
        let supportsArm64iOS = Self.parseSupportsArm64iOS(
            vtoolOutput: vtoolOut.stdoutString,
            otoolOutput: otoolOut.stdoutString
        )

        var nestedExtensions: [String] = []
        let plugInsDir = appBundleURL.appendingPathComponent("PlugIns", isDirectory: true)
        if let items = try? fm.contentsOfDirectory(at: plugInsDir, includingPropertiesForKeys: nil) {
            nestedExtensions = items
                .filter { $0.pathExtension.lowercased() == "appex" }
                .map(\.lastPathComponent)
                .sorted()
        }

        var profileExpiration: Date?
        var provisionedUDIDs: [String] = []
        var isNonFreeLongLivedProfile = false

        let embeddedProfileURL = appBundleURL.appendingPathComponent("embedded.mobileprovision", isDirectory: false)
        if fm.fileExists(atPath: embeddedProfileURL.path),
           let decodedProfile = try? await decodeMobileProvision(at: embeddedProfileURL) {
            profileExpiration = decodedProfile.expirationDate
            provisionedUDIDs = decodedProfile.provisionedUDIDs

            let now = Date()
            let remainingSeconds = decodedProfile.expirationDate.timeIntervalSince(now)
            let totalValiditySeconds: TimeInterval
            if let creation = decodedProfile.creationDate {
                totalValiditySeconds = decodedProfile.expirationDate.timeIntervalSince(creation)
            } else {
                totalValiditySeconds = remainingSeconds
            }

            if !decodedProfile.isLocalProvision &&
               remainingSeconds > 7 * 86_400 &&
               totalValiditySeconds > 8 * 86_400 {
                isNonFreeLongLivedProfile = true
            }
        }

        var canInstallUntouched = false
        if !isEncrypted &&
           supportsArm64iOS &&
           isNonFreeLongLivedProfile &&
           !targetDeviceUDID.isEmpty &&
           provisionedUDIDs.contains(targetDeviceUDID) {
            let verifyOut = try await runner.run(
                "/usr/bin/codesign",
                arguments: ["--verify", "--deep", "--strict", appBundleURL.path],
                timeout: 30
            )
            canInstallUntouched = (verifyOut.exitCode == 0)
        }

        return IPAInspectionReport(
            ipaPath: originalSourcePath,
            bundleIdentifier: bundleID,
            displayName: displayName,
            executableName: executableName,
            marketingVersion: marketingVersion,
            buildVersion: buildVersion,
            isFairPlayEncrypted: isEncrypted,
            supportsArm64iOS: supportsArm64iOS,
            nestedExtensions: nestedExtensions,
            embeddedProfileExpiration: profileExpiration,
            embeddedProfileProvisionedUDIDs: provisionedUDIDs,
            canInstallUntouchedForTargetDevice: canInstallUntouched
        )
    }

    public static func parseFairPlayEncrypted(fromOtoolOutput output: String) -> Bool {
        var inEncryptionCommand = false
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("Load command ") {
                inEncryptionCommand = false
                continue
            }
            if trimmed.hasPrefix("cmd LC_ENCRYPTION_INFO") {
                inEncryptionCommand = true
                continue
            }
            if inEncryptionCommand && trimmed.hasPrefix("cryptid") {
                let parts = trimmed.split(whereSeparator: \.isWhitespace)
                if parts.count >= 2, parts[1] != "0" {
                    return true
                }
            }
        }
        return false
    }

    public static func parseSupportsArm64iOS(vtoolOutput: String, otoolOutput: String) -> Bool {
        let lowerVtool = vtoolOutput.lowercased()
        let hasArm64InVtool = lowerVtool.contains("arm64")
        let hasIOSInVtool = lowerVtool.contains("platform ios") || lowerVtool.contains("platform 2")
        if hasArm64InVtool && hasIOSInVtool {
            return true
        }
        let lowerOtool = otoolOutput.lowercased()
        if (hasArm64InVtool || lowerOtool.contains("cputype cpu_type_arm64") || lowerOtool.contains("architecture arm64")) &&
           !lowerVtool.contains("platform iossimulator") &&
           !lowerVtool.contains("platform macos") {
            return true
        }
        return false
    }

    // MARK: - 4. Import Base Artifact

    public func importBaseArtifact(
        appID: UUID,
        source: AppSource,
        teamID: String
    ) async throws -> (baseAppURL: URL, version: String, buildVersion: String) {
        try paths.ensureDirectoriesExist()
        let fm = FileManager.default
        let baseDir = paths.baseAppDirectory(for: appID)
        if fm.fileExists(atPath: baseDir.path) {
            try fm.removeItem(at: baseDir)
        }
        try fm.createDirectory(at: baseDir, withIntermediateDirectories: true)

        switch source {
        case .xcodeProject(let projectOrWorkspacePath, let scheme, let configuration, _):
            let projectURL = URL(fileURLWithPath: projectOrWorkspacePath).standardizedFileURL
            let isWorkspace = projectURL.pathExtension.lowercased() == "xcworkspace"
            let containerFlag = isWorkspace ? "-workspace" : "-project"

            let tempDerivedData = fm.temporaryDirectory.appendingPathComponent(
                "applesync-build-\(UUID().uuidString)",
                isDirectory: true
            )
            try fm.createDirectory(at: tempDerivedData, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: tempDerivedData) }

            // Build an unsigned snapshot first; stageAndSignApp rewrites CFBundleIdentifier to
            // EffectiveBundleID and deep-signs via ProvisioningProxy without touching original App IDs
            // or breaking CocoaPods resource bundles.
            let buildOut = try await runner.run(
                "/usr/bin/xcodebuild",
                arguments: [
                    containerFlag, projectURL.path,
                    "-scheme", scheme,
                    "-configuration", configuration,
                    "-sdk", "iphoneos",
                    "-destination", "generic/platform=iOS",
                    "-derivedDataPath", tempDerivedData.path,
                    "CODE_SIGNING_REQUIRED=NO",
                    "CODE_SIGNING_ALLOWED=NO",
                    "CODE_SIGN_IDENTITY=",
                    "EXPANDED_CODE_SIGN_IDENTITY=",
                    "build"
                ],
                timeout: 600
            )
            guard buildOut.exitCode == 0 else {
                throw AppleSyncError.commandFailed(
                    executable: "/usr/bin/xcodebuild",
                    exitCode: buildOut.exitCode,
                    stderr: buildOut.stderrString.isEmpty ? buildOut.stdoutString : buildOut.stderrString
                )
            }

            let builtAppURL = try locateBuiltApp(inDerivedData: tempDerivedData, configuration: configuration)
            let destAppURL = baseDir.appendingPathComponent(builtAppURL.lastPathComponent, isDirectory: true)
            try copyBundle(from: builtAppURL, to: destAppURL)

            let infoPlist = try readPlistDictionary(at: destAppURL.appendingPathComponent("Info.plist"))
            let version = (infoPlist["CFBundleShortVersionString"] as? String) ?? "1.0"
            let buildVersion = (infoPlist["CFBundleVersion"] as? String) ?? "1"
            return (destAppURL, version, buildVersion)

        case .externalIPA(let originalIPAPath, _, _, _):
            let ipaURL = URL(fileURLWithPath: originalIPAPath).standardizedFileURL
            guard fm.fileExists(atPath: ipaURL.path) else {
                throw AppleSyncError.invalidInput("IPA file does not exist at \(ipaURL.path)")
            }

            let tempExtractDir = fm.temporaryDirectory.appendingPathComponent(
                "applesync-import-\(UUID().uuidString)",
                isDirectory: true
            )
            try fm.createDirectory(at: tempExtractDir, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: tempExtractDir) }

            let sourceAppURL: URL
            if ipaURL.pathExtension.lowercased() == "app" {
                sourceAppURL = ipaURL
            } else {
                let unpackOut = try await runner.run(
                    "/usr/bin/ditto",
                    arguments: ["-x", "-k", ipaURL.path, tempExtractDir.path],
                    timeout: 120
                )
                guard unpackOut.exitCode == 0 else {
                    throw AppleSyncError.invalidInput("Failed to unpack IPA at \(ipaURL.path): \(unpackOut.stderrString)")
                }
                sourceAppURL = try locateAppBundle(inExtractedIPADirectory: tempExtractDir)
            }

            let inspection = try await inspectAppBundle(
                at: sourceAppURL,
                originalSourcePath: ipaURL.path,
                targetDeviceUDID: ""
            )
            if inspection.isFairPlayEncrypted {
                throw AppleSyncError.encryptedIPAUnsupported(ipaURL.path)
            }
            if !inspection.supportsArm64iOS {
                throw AppleSyncError.unsupportedArchitecture("App at \(ipaURL.path) does not support physical arm64 iOS devices.")
            }

            let destAppURL = baseDir.appendingPathComponent(sourceAppURL.lastPathComponent, isDirectory: true)
            try copyBundle(from: sourceAppURL, to: destAppURL)
            return (destAppURL, inspection.marketingVersion, inspection.buildVersion)
        }
    }

    // MARK: - 5. Stage and Sign App

    public func stageAndSignApp(
        for app: ManagedAppRecord
    ) async throws -> SignedArtifactMetadata {
        try paths.ensureDirectoriesExist()
        let fm = FileManager.default
        let baseAppURL = URL(fileURLWithPath: app.cachedBaseAppPath).standardizedFileURL
        guard fm.fileExists(atPath: baseAppURL.path) else {
            throw AppleSyncError.invalidInput("Cached base app bundle missing at \(baseAppURL.path)")
        }

        let stagedDir = paths.stagedAppDirectory(for: app.id)
        if fm.fileExists(atPath: stagedDir.path) {
            try fm.removeItem(at: stagedDir)
        }
        try fm.createDirectory(at: stagedDir, withIntermediateDirectories: true)

        let stagedAppURL = stagedDir.appendingPathComponent(baseAppURL.lastPathComponent, isDirectory: true)
        try copyBundle(from: baseAppURL, to: stagedAppURL)

        if case .externalIPA(_, _, _, let useOriginalAdHocIfValid) = app.source, useOriginalAdHocIfValid {
            let report = try await inspectAppBundle(
                at: stagedAppURL,
                originalSourcePath: baseAppURL.path,
                targetDeviceUDID: app.targetDeviceUDID
            )
            if report.canInstallUntouchedForTargetDevice,
               let profileExpiration = report.embeddedProfileExpiration {
                return SignedArtifactMetadata(
                    stagedAppPath: stagedAppURL.path,
                    effectiveBundleID: report.bundleIdentifier,
                    teamID: app.teamID,
                    profileExpirationDate: profileExpiration,
                    provisionedUDIDs: report.embeddedProfileProvisionedUDIDs,
                    usedUntouchedEmbeddedProfile: true
                )
            }
        }

        _ = try? await runner.run("/usr/bin/xattr", arguments: ["-cr", stagedAppURL.path], timeout: 30)

        let foldersToStrip = app.shouldStripNestedExtensions
            ? ["PlugIns", "Watch", "Extensions", "AppClips"]
            : ["Watch", "AppClips"]
        for folder in foldersToStrip {
            let folderURL = stagedAppURL.appendingPathComponent(folder, isDirectory: true)
            if fm.fileExists(atPath: folderURL.path) {
                try fm.removeItem(at: folderURL)
            }
        }

        let mainInfoPlistURL = stagedAppURL.appendingPathComponent("Info.plist", isDirectory: false)
        try await rewriteBundleIdentifier(in: mainInfoPlistURL, to: app.effectiveBundleID)
        _ = try? await runner.run(
            "/usr/bin/plutil",
            arguments: ["-remove", "UISupportedDevices", mainInfoPlistURL.path],
            timeout: 15
        )

        let mainMinted = try await mintProvisioningProfile(
            bundleID: app.effectiveBundleID,
            teamID: app.teamID,
            targetDeviceUDID: app.targetDeviceUDID
        )

        let tempWorkDir = fm.temporaryDirectory.appendingPathComponent(
            "applesync-sign-\(UUID().uuidString)",
            isDirectory: true
        )
        try fm.createDirectory(at: tempWorkDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempWorkDir) }

        let mainEmbeddedProfileDest = stagedAppURL.appendingPathComponent("embedded.mobileprovision", isDirectory: false)
        if fm.fileExists(atPath: mainEmbeddedProfileDest.path) {
            try fm.removeItem(at: mainEmbeddedProfileDest)
        }
        try mainMinted.rawProfileData.write(to: mainEmbeddedProfileDest, options: .atomic)

        let mainEntitlementsURL = tempWorkDir.appendingPathComponent("main-entitlements.plist", isDirectory: false)
        try mainMinted.entitlementsPlistData.write(to: mainEntitlementsURL, options: .atomic)

        var appexEntitlementsByPath: [String: URL] = [:]
        let plugInsURL = stagedAppURL.appendingPathComponent("PlugIns", isDirectory: true)
        if let plugInItems = try? fm.contentsOfDirectory(at: plugInsURL, includingPropertiesForKeys: nil) {
            let appexBundles = plugInItems
                .filter { $0.pathExtension.lowercased() == "appex" }
                .sorted { $0.path < $1.path }

            for (index, appexURL) in appexBundles.enumerated() {
                let appexInfoPlist = appexURL.appendingPathComponent("Info.plist", isDirectory: false)
                let appexPlistDict = (try? readPlistDictionary(at: appexInfoPlist)) ?? [:]
                let originalAppexBundleID = (appexPlistDict["CFBundleIdentifier"] as? String) ?? ""
                let childBundleID = Self.makeChildExtensionBundleID(
                    parentEffectiveBundleID: app.effectiveBundleID,
                    parentOriginalBundleID: app.originalBundleID,
                    originalExtensionBundleID: originalAppexBundleID,
                    fallbackExtensionName: appexURL.deletingPathExtension().lastPathComponent
                )

                try await rewriteBundleIdentifier(in: appexInfoPlist, to: childBundleID)
                _ = try? await runner.run(
                    "/usr/bin/plutil",
                    arguments: [
                        "-replace",
                        "NSExtension.NSExtensionAttributes.WKAppBundleIdentifier",
                        "-string",
                        app.effectiveBundleID,
                        appexInfoPlist.path
                    ],
                    timeout: 10
                )

                let childMinted = try await mintProvisioningProfile(
                    bundleID: childBundleID,
                    teamID: app.teamID,
                    targetDeviceUDID: app.targetDeviceUDID
                )
                let childProfileDest = appexURL.appendingPathComponent("embedded.mobileprovision", isDirectory: false)
                if fm.fileExists(atPath: childProfileDest.path) {
                    try fm.removeItem(at: childProfileDest)
                }
                try childMinted.rawProfileData.write(to: childProfileDest, options: .atomic)

                let childEntURL = tempWorkDir.appendingPathComponent("appex-\(index)-entitlements.plist", isDirectory: false)
                try childMinted.entitlementsPlistData.write(to: childEntURL, options: .atomic)
                appexEntitlementsByPath[appexURL.standardizedFileURL.path] = childEntURL
            }
        }

        let nestedLibraries = findSignableNestedLibraries(in: stagedAppURL)
        for libURL in nestedLibraries {
            try await codesign(
                targetURL: libURL,
                signingIdentitySHA1: mainMinted.signingIdentitySHA1,
                entitlementsURL: nil
            )
        }

        let sortedAppexPaths = appexEntitlementsByPath.keys.sorted {
            pathDepth($0) > pathDepth($1)
        }
        for appexPath in sortedAppexPaths {
            let entURL = appexEntitlementsByPath[appexPath]
            try await codesign(
                targetURL: URL(fileURLWithPath: appexPath),
                signingIdentitySHA1: mainMinted.signingIdentitySHA1,
                entitlementsURL: entURL
            )
        }

        try await codesign(
            targetURL: stagedAppURL,
            signingIdentitySHA1: mainMinted.signingIdentitySHA1,
            entitlementsURL: mainEntitlementsURL
        )

        let verifyOut = try await runner.run(
            "/usr/bin/codesign",
            arguments: ["--verify", "--deep", "--strict", stagedAppURL.path],
            timeout: 60
        )
        guard verifyOut.exitCode == 0 else {
            throw AppleSyncError.codesignFailed(
                "Signature verification failed for \(stagedAppURL.lastPathComponent): \(verifyOut.stderrString)"
            )
        }

        return SignedArtifactMetadata(
            stagedAppPath: stagedAppURL.path,
            effectiveBundleID: app.effectiveBundleID,
            teamID: app.teamID,
            profileExpirationDate: mainMinted.expirationDate,
            provisionedUDIDs: mainMinted.provisionedUDIDs,
            usedUntouchedEmbeddedProfile: false
        )
    }

    // MARK: - Provisioning Profile Minting & Parsing

    private struct DecodedMobileProvision: Sendable {
        let rawProfileData: Data
        let creationDate: Date?
        let expirationDate: Date
        let provisionedUDIDs: [String]
        let isLocalProvision: Bool
        let entitlementsPlistData: Data
        let certificateSHA1s: [String]
    }

    private struct MintedProfile: Sendable {
        let rawProfileData: Data
        let expirationDate: Date
        let provisionedUDIDs: [String]
        let entitlementsPlistData: Data
        let signingIdentitySHA1: String
    }

    private func mintProvisioningProfile(
        bundleID: String,
        teamID: String,
        targetDeviceUDID: String
    ) async throws -> MintedProfile {
        let proxyProjectURL = try await proxyGenerator.ensureProxyProject()
        let fm = FileManager.default
        let tempDerivedData = fm.temporaryDirectory.appendingPathComponent(
            "applesync-proxy-dd-\(UUID().uuidString)",
            isDirectory: true
        )
        try fm.createDirectory(at: tempDerivedData, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDerivedData) }

        let destinations: [String] = targetDeviceUDID.isEmpty
            ? ["generic/platform=iOS"]
            : ["id=\(targetDeviceUDID)", "generic/platform=iOS"]

        var lastFailureStderr = ""
        var buildSucceeded = false

        for destination in destinations {
            let out = try await runner.run(
                "/usr/bin/xcodebuild",
                arguments: [
                    "-project", proxyProjectURL.path,
                    "-scheme", "ProvisioningProxy",
                    "-configuration", "Debug",
                    "-sdk", "iphoneos",
                    "-destination", destination,
                    "-derivedDataPath", tempDerivedData.path,
                    "-allowProvisioningUpdates",
                    "DEVELOPMENT_TEAM=\(teamID)",
                    "PRODUCT_BUNDLE_IDENTIFIER=\(bundleID)",
                    "CODE_SIGN_STYLE=Automatic",
                    "build"
                ],
                timeout: 180
            )
            if out.exitCode == 0 {
                buildSucceeded = true
                break
            }
            lastFailureStderr = out.stderrString.isEmpty ? out.stdoutString : out.stderrString
        }

        guard buildSucceeded else {
            throw AppleSyncError.provisioningFailed(
                "xcodebuild failed to mint provisioning profile for '\(bundleID)' (team \(teamID)): \(lastFailureStderr)"
            )
        }

        let builtProxyApp = try locateBuiltApp(inDerivedData: tempDerivedData, configuration: "Debug")
        let embeddedProfileURL = builtProxyApp.appendingPathComponent("embedded.mobileprovision", isDirectory: false)
        guard fm.fileExists(atPath: embeddedProfileURL.path) else {
            throw AppleSyncError.provisioningFailed(
                "ProvisioningProxy succeeded but embedded.mobileprovision was missing at \(embeddedProfileURL.path)"
            )
        }

        let decoded = try await decodeMobileProvision(at: embeddedProfileURL)
        if !targetDeviceUDID.isEmpty && !decoded.provisionedUDIDs.contains(targetDeviceUDID) {
            throw AppleSyncError.deviceNotProvisionedInProfile(udid: targetDeviceUDID, teamID: teamID)
        }

        let availableIdentities = try await discoverSigningTeams()
        let teamIdentities = availableIdentities.filter { $0.teamID == teamID }
        guard !teamIdentities.isEmpty else {
            throw AppleSyncError.signingIdentityNotFound(teamID: teamID)
        }

        let matchingIdentity = teamIdentities.first(where: {
            decoded.certificateSHA1s.contains($0.sha1Fingerprint.uppercased())
        }) ?? teamIdentities[0]

        return MintedProfile(
            rawProfileData: decoded.rawProfileData,
            expirationDate: decoded.expirationDate,
            provisionedUDIDs: decoded.provisionedUDIDs,
            entitlementsPlistData: decoded.entitlementsPlistData,
            signingIdentitySHA1: matchingIdentity.sha1Fingerprint
        )
    }

    private func decodeMobileProvision(at profileURL: URL) async throws -> DecodedMobileProvision {
        let rawData = try Data(contentsOf: profileURL)
        let cmsOut = try await runner.run(
            "/usr/bin/security",
            arguments: ["cms", "-D", "-i", profileURL.path],
            timeout: 30
        )
        guard cmsOut.exitCode == 0 else {
            throw AppleSyncError.provisioningFailed(
                "security cms -D failed on \(profileURL.path): \(cmsOut.stderrString)"
            )
        }

        guard let plist = try PropertyListSerialization.propertyList(
            from: cmsOut.stdoutData,
            options: [],
            format: nil
        ) as? [String: Any] else {
            throw AppleSyncError.provisioningFailed("Decoded mobileprovision at \(profileURL.path) is not a dictionary plist")
        }

        guard let expirationDate = plist["ExpirationDate"] as? Date else {
            throw AppleSyncError.provisioningFailed("Decoded mobileprovision at \(profileURL.path) is missing ExpirationDate")
        }

        let creationDate = plist["CreationDate"] as? Date
        let provisionedUDIDs = (plist["ProvisionedDevices"] as? [String]) ?? []
        let isLocalProvision = (plist["LocalProvision"] as? Bool) ?? false
        let entitlementsDict = (plist["Entitlements"] as? [String: Any]) ?? [:]
        let entitlementsData = try PropertyListSerialization.data(
            fromPropertyList: entitlementsDict,
            format: .xml,
            options: 0
        )

        let certDatas = (plist["DeveloperCertificates"] as? [Data]) ?? []
        let certSHA1s = certDatas.map { certData -> String in
            let digest = Insecure.SHA1.hash(data: certData)
            return digest.map { String(format: "%02X", $0) }.joined()
        }

        return DecodedMobileProvision(
            rawProfileData: rawData,
            creationDate: creationDate,
            expirationDate: expirationDate,
            provisionedUDIDs: provisionedUDIDs,
            isLocalProvision: isLocalProvision,
            entitlementsPlistData: entitlementsData,
            certificateSHA1s: certSHA1s
        )
    }

    // MARK: - Codesign & Bundle Helpers

    private func codesign(
        targetURL: URL,
        signingIdentitySHA1: String,
        entitlementsURL: URL?
    ) async throws {
        var args = [
            "--force",
            "--sign", signingIdentitySHA1,
            "--timestamp=none"
        ]
        if let entitlementsURL {
            args.append(contentsOf: [
                "--entitlements", entitlementsURL.path,
                "--generate-entitlement-der"
            ])
        }
        args.append(targetURL.path)

        let out = try await runner.run("/usr/bin/codesign", arguments: args, timeout: 60)
        guard out.exitCode == 0 else {
            throw AppleSyncError.codesignFailed(
                "codesign failed on \(targetURL.lastPathComponent): \(out.stderrString)"
            )
        }
    }

    private func findSignableNestedLibraries(in appBundleURL: URL) -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: appBundleURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var results: [URL] = []
        while let itemURL = enumerator.nextObject() as? URL {
            let ext = itemURL.pathExtension.lowercased()
            if ext == "framework" || ext == "dylib" {
                results.append(itemURL.standardizedFileURL)
            }
        }

        return results.sorted { lhs, rhs in
            let d1 = pathDepth(lhs.path)
            let d2 = pathDepth(rhs.path)
            if d1 != d2 {
                return d1 > d2
            }
            return lhs.path < rhs.path
        }
    }

    private func pathDepth(_ path: String) -> Int {
        path.split(separator: "/").count
    }

    private func rewriteBundleIdentifier(in infoPlistURL: URL, to newBundleID: String) async throws {
        let out = try await runner.run(
            "/usr/bin/plutil",
            arguments: ["-replace", "CFBundleIdentifier", "-string", newBundleID, infoPlistURL.path],
            timeout: 15
        )
        guard out.exitCode == 0 else {
            throw AppleSyncError.invalidInput(
                "Failed to update CFBundleIdentifier in \(infoPlistURL.path): \(out.stderrString)"
            )
        }
    }

    public static func makeChildExtensionBundleID(
        parentEffectiveBundleID: String,
        parentOriginalBundleID: String,
        originalExtensionBundleID: String,
        fallbackExtensionName: String
    ) -> String {
        let prefix = parentOriginalBundleID + "."
        let rawSuffix: String
        if !parentOriginalBundleID.isEmpty, originalExtensionBundleID.hasPrefix(prefix) {
            rawSuffix = String(originalExtensionBundleID.dropFirst(prefix.count))
        } else if let lastDot = originalExtensionBundleID.lastIndex(of: ".") {
            rawSuffix = String(originalExtensionBundleID[originalExtensionBundleID.index(after: lastDot)...])
        } else {
            rawSuffix = fallbackExtensionName
        }

        let sanitized = rawSuffix.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "." || scalar == "-" {
                return Character(scalar)
            }
            return "-"
        }
        let cleanSuffix = String(sanitized).trimmingCharacters(in: CharacterSet(charactersIn: ".-"))
        return "\(parentEffectiveBundleID).\(cleanSuffix.isEmpty ? "ext" : cleanSuffix)"
    }

    private func copyBundle(from sourceURL: URL, to destinationURL: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: destinationURL.path) {
            try fm.removeItem(at: destinationURL)
        }
        try fm.copyItem(at: sourceURL, to: destinationURL)
    }

    private func readPlistDictionary(at plistURL: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: plistURL)
        guard let dict = try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ) as? [String: Any] else {
            throw AppleSyncError.invalidInput("Plist at \(plistURL.path) is not a top-level dictionary")
        }
        return dict
    }

    private func locateAppBundle(inExtractedIPADirectory rootDir: URL) throws -> URL {
        let fm = FileManager.default
        let payloadDir = rootDir.appendingPathComponent("Payload", isDirectory: true)
        let searchDir = fm.fileExists(atPath: payloadDir.path) ? payloadDir : rootDir
        let items = try fm.contentsOfDirectory(at: searchDir, includingPropertiesForKeys: nil)
        guard let appURL = items.first(where: { $0.pathExtension.lowercased() == "app" }) else {
            throw AppleSyncError.invalidInput("No .app bundle found inside Payload directory at \(searchDir.path)")
        }
        return appURL
    }

    private func locateBuiltApp(inDerivedData derivedDataURL: URL, configuration: String) throws -> URL {
        let fm = FileManager.default
        let productsDir = derivedDataURL
            .appendingPathComponent("Build", isDirectory: true)
            .appendingPathComponent("Products", isDirectory: true)
        let preferredDir = productsDir.appendingPathComponent("\(configuration)-iphoneos", isDirectory: true)

        if let items = try? fm.contentsOfDirectory(at: preferredDir, includingPropertiesForKeys: nil),
           let app = items.first(where: { $0.pathExtension.lowercased() == "app" }) {
            return app
        }

        if let productSubdirs = try? fm.contentsOfDirectory(
            at: productsDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            let iOSDirs = productSubdirs
                .filter { $0.lastPathComponent.lowercased().hasSuffix("-iphoneos") }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            for dir in iOSDirs {
                if let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil),
                   let app = items.first(where: { $0.pathExtension.lowercased() == "app" }) {
                    return app
                }
            }
        }

        let excludedSegments = [
            "-iphonesimulator", "-watchos", "-watchsimulator",
            "-appletv", "-macosx", "/Watch/", "/PlugIns/", "/Extensions/"
        ]
        if let enumerator = fm.enumerator(
            at: productsDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            while let candidate = enumerator.nextObject() as? URL {
                let ext = candidate.pathExtension.lowercased()
                let path = candidate.path
                if excludedSegments.contains(where: { path.localizedCaseInsensitiveContains($0) }) {
                    enumerator.skipDescendants()
                    continue
                }
                if ext == "app" {
                    return candidate
                }
                if ext == "appex" || ext == "framework" {
                    enumerator.skipDescendants()
                }
            }
        }

        throw AppleSyncError.provisioningFailed("Unable to locate built .app in DerivedData at \(productsDir.path)")
    }
}

// MARK: - Private Xcode JSON Models

private struct XcodeListJSON: Decodable {
    struct Container: Decodable {
        let schemes: [String]?
        let configurations: [String]?
    }
    let project: Container?
    let workspace: Container?
}

private struct XcodeBuildSettingsEntry: Decodable {
    let buildSettings: [String: String]
}
