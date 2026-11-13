import Testing
import Foundation
@testable import AppleSyncCore

@Suite("Step B Signing & Provisioning Engine Tests")
struct SigningTests {
    @Test("Identity parser filters revoked certs and extracts Team IDs across multiple accounts")
    func parseIdentitiesFiltersRevoked() {
        let output = """
          1) AAA111BBB222CCC333DDD444EEE555FFF6667771 "Apple Development: Personal One (TEAM111AAA)"
          2) BBB111BBB222CCC333DDD444EEE555FFF6667772 "Apple Development: Revoked One (REVOKED99)" (CSSMERR_TP_CERT_REVOKED)
          3) CCC111BBB222CCC333DDD444EEE555FFF6667773 "iPhone Developer: Personal Two (TEAM222BBB)"
          4) DDD111BBB222CCC333DDD444EEE555FFF6667774 "Mac Developer: Ignored Mac Cert (MAC1234567)"
          5) AAA111BBB222CCC333DDD444EEE555FFF6667771 "Apple Development: Personal One (TEAM111AAA)"
        """

        let teams = DualSourceSigningEngine.parseIdentities(from: output)
        #expect(teams.count == 2)
        #expect(teams[0].teamID == "TEAM111AAA")
        #expect(teams[1].teamID == "TEAM222BBB")
    }

    @Test("FairPlay cryptid parser distinguishes encrypted vs clean binaries")
    func parseFairPlayEncrypted() {
        let encryptedOtool = """
        Load command 12
                  cmd LC_ENCRYPTION_INFO_64
              cmdsize 24
             cryptoff 16384
            cryptsize 327680
              cryptid 1
        """
        let cleanOtool = """
        Load command 12
                  cmd LC_ENCRYPTION_INFO_64
              cmdsize 24
             cryptoff 16384
            cryptsize 327680
              cryptid 0
        """
        let simulatorOtool = """
        Load command 0
              cmd LC_SEGMENT_64
          segname __TEXT
        """

        #expect(DualSourceSigningEngine.parseFairPlayEncrypted(fromOtoolOutput: encryptedOtool) == true)
        #expect(DualSourceSigningEngine.parseFairPlayEncrypted(fromOtoolOutput: cleanOtool) == false)
        #expect(DualSourceSigningEngine.parseFairPlayEncrypted(fromOtoolOutput: simulatorOtool) == false)
    }

    @Test("arm64 iOS parser validates physical iOS platform")
    func parseArm64iOS() {
        let validVtool = """
        cmd LC_BUILD_VERSION
        platform IOS
        """
        let validOtool = """
        Mach header
              magic cputype cpusubtype
         0xfeedfacf 16777228          0
        architecture arm64
        """
        let simVtool = """
        cmd LC_BUILD_VERSION
        platform IOSSIMULATOR
        """
        let x86Otool = """
        architecture x86_64
        """

        #expect(DualSourceSigningEngine.parseSupportsArm64iOS(vtoolOutput: validVtool, otoolOutput: validOtool) == true)
        #expect(DualSourceSigningEngine.parseSupportsArm64iOS(vtoolOutput: simVtool, otoolOutput: validOtool) == false)
        #expect(DualSourceSigningEngine.parseSupportsArm64iOS(vtoolOutput: validVtool, otoolOutput: x86Otool) == false)
    }

    @Test("Extension bundle ID remapping keeps parent effective prefix")
    func makeChildExtensionBundleID() {
        let child1 = DualSourceSigningEngine.makeChildExtensionBundleID(
            parentEffectiveBundleID: "com.applesync.team1.deadbeef",
            parentOriginalBundleID: "com.friend.AwesomeApp",
            originalExtensionBundleID: "com.friend.AwesomeApp.WidgetExt",
            fallbackExtensionName: "WidgetExt"
        )
        #expect(child1 == "com.applesync.team1.deadbeef.WidgetExt")

        let child2 = DualSourceSigningEngine.makeChildExtensionBundleID(
            parentEffectiveBundleID: "com.applesync.team1.deadbeef",
            parentOriginalBundleID: "com.friend.Other",
            originalExtensionBundleID: "org.unrelated.Share Ext!",
            fallbackExtensionName: "Fallback"
        )
        #expect(child2.hasPrefix("com.applesync.team1.deadbeef."))
        #expect(!child2.contains(" "))
        #expect(!child2.contains("!"))
    }

    @Test("ProvisioningProxyGenerator creates valid Xcode proxy project without xcodegen")
    func generateProvisioningProxyPureSwift() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("applesync-proxy-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let paths = AppleSyncPaths(rootURL: tempRoot)
        let generator = ProvisioningProxyGenerator(paths: paths, runner: SystemProcessRunner())
        let projectURL = try await generator.ensureProxyProject()

        #expect(FileManager.default.fileExists(atPath: projectURL.appendingPathComponent("project.pbxproj").path))
        #expect(FileManager.default.fileExists(atPath: paths.provisioningProxyDirectoryURL.appendingPathComponent("Info.plist").path))
        #expect(FileManager.default.fileExists(atPath: paths.provisioningProxyDirectoryURL.appendingPathComponent("Sources/ProxyMain.swift").path))

        // Second call should reuse cached project cleanly.
        let projectURL2 = try await generator.ensureProxyProject()
        #expect(projectURL == projectURL2)

        if FileManager.default.isExecutableFile(atPath: "/usr/bin/xcodebuild") {
            let listOutput = try await SystemProcessRunner().run(
                "/usr/bin/xcodebuild",
                arguments: ["-list", "-json", "-project", projectURL.path],
                timeout: 30
            )
            #expect(listOutput.exitCode == 0)
            #expect(listOutput.stdoutString.contains("ProvisioningProxy"))
        }
    }

    @Test("Ad-Hoc fast path detects untouched 1-year UDID-provisioned app vs re-sign requirement")
    func adHocFastPathDetection() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("applesync-adhoc-test-\(UUID().uuidString)", isDirectory: true)
        let appURL = tempRoot.appendingPathComponent("FriendApp.app", isDirectory: true)
        try FileManager.default.createDirectory(at: appURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let infoPlist: [String: Any] = [
            "CFBundleIdentifier": "com.friend.BetaApp",
            "CFBundleExecutable": "FriendApp",
            "CFBundleDisplayName": "Friend Beta",
            "CFBundleShortVersionString": "2.1",
            "CFBundleVersion": "42"
        ]
        let plistData = try PropertyListSerialization.data(fromPropertyList: infoPlist, format: .xml, options: 0)
        try plistData.write(to: appURL.appendingPathComponent("Info.plist"))
        try Data("#!/bin/sh\n".utf8).write(to: appURL.appendingPathComponent("FriendApp"))
        try Data("stub-profile".utf8).write(to: appURL.appendingPathComponent("embedded.mobileprovision"))

        let plugInsDir = appURL.appendingPathComponent("PlugIns/Widget.appex", isDirectory: true)
        try FileManager.default.createDirectory(at: plugInsDir, withIntermediateDirectories: true)

        let iso = ISO8601DateFormatter()
        let created = iso.string(from: Date().addingTimeInterval(-86_400))
        let expiresIn200Days = iso.string(from: Date().addingTimeInterval(200 * 86_400))

        let cleanCMSPlist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>CreationDate</key>
            <date>\(created)</date>
            <key>ExpirationDate</key>
            <date>\(expiresIn200Days)</date>
            <key>ProvisionedDevices</key>
            <array>
                <string>00000000-MATCHING-UDID</string>
            </array>
            <key>TeamIdentifier</key>
            <array>
                <string>FRIENDTEAM</string>
            </array>
            <key>Entitlements</key>
            <dict>
                <key>application-identifier</key>
                <string>FRIENDTEAM.com.friend.BetaApp</string>
            </dict>
        </dict>
        </plist>
        """

        let mockRunner = MockCommandRunner { exec, args, _, _, _ in
            if exec == "/usr/bin/otool" {
                return ProcessOutput(exitCode: 0, stdoutData: Data("architecture arm64\ncryptid 0\n".utf8), stderrData: Data())
            }
            if exec == "/usr/bin/vtool" {
                return ProcessOutput(exitCode: 0, stdoutData: Data("platform IOS\n".utf8), stderrData: Data())
            }
            if exec == "/usr/bin/security" && args.contains("cms") {
                return ProcessOutput(exitCode: 0, stdoutData: Data(cleanCMSPlist.utf8), stderrData: Data())
            }
            if exec == "/usr/bin/codesign" && args.contains("--verify") {
                return ProcessOutput(exitCode: 0, stdoutData: Data(), stderrData: Data())
            }
            return ProcessOutput(exitCode: 0, stdoutData: Data(), stderrData: Data())
        }

        let paths = AppleSyncPaths(rootURL: tempRoot.appendingPathComponent("State"))
        let engine = DualSourceSigningEngine(paths: paths, runner: mockRunner)

        // Matching UDID qualifies for Ad-Hoc fast path
        let matchingReport = try await engine.inspectAppBundle(
            at: appURL,
            originalSourcePath: "/tmp/FriendApp.ipa",
            targetDeviceUDID: "00000000-MATCHING-UDID"
        )
        #expect(matchingReport.canInstallUntouchedForTargetDevice == true)
        #expect(!matchingReport.isFairPlayEncrypted)
        #expect(matchingReport.supportsArm64iOS)
        #expect(matchingReport.nestedExtensions == ["Widget.appex"])

        // Different UDID falls back to re-sign
        let otherDeviceReport = try await engine.inspectAppBundle(
            at: appURL,
            originalSourcePath: "/tmp/FriendApp.ipa",
            targetDeviceUDID: "00000000-OTHER-UDID"
        )
        #expect(otherDeviceReport.canInstallUntouchedForTargetDevice == false)

        // Staging Ad-Hoc fast-path reuses embedded profile without modifying bundle
        let adHocRecord = ManagedAppRecord(
            displayName: "Friend Beta",
            originalBundleID: "com.friend.BetaApp",
            effectiveBundleID: "com.friend.BetaApp",
            teamID: "USERTEAM1",
            targetDeviceUDID: "00000000-MATCHING-UDID",
            source: .externalIPA(
                originalIPAPath: "/tmp/FriendApp.ipa",
                originalBundleID: "com.friend.BetaApp",
                stripExtensions: true,
                useOriginalAdHocIfValid: true
            ),
            state: .activeAdHoc,
            cachedBaseAppPath: appURL.path
        )
        let signed = try await engine.stageAndSignApp(for: adHocRecord)
        #expect(signed.usedUntouchedEmbeddedProfile == true)
        #expect(signed.effectiveBundleID == "com.friend.BetaApp")
    }

    @Test("resolveXcodeContainerURL accepts .xcodeproj, .xcworkspace, enclosing folder, or ios/ subfolder")
    func resolveXcodeContainerFromFolderOrBundle() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("applesync-resolve-test-\(UUID().uuidString)", isDirectory: true)
        let folderOnlyProj = tempRoot.appendingPathComponent("ProjOnly", isDirectory: true)
        let folderWithBoth = tempRoot.appendingPathComponent("WithWorkspace", isDirectory: true)
        let flutterRoot = tempRoot.appendingPathComponent("FlutterRoot", isDirectory: true)
        let emptyFolder = tempRoot.appendingPathComponent("Empty", isDirectory: true)

        try FileManager.default.createDirectory(at: folderOnlyProj.appendingPathComponent("Demo.xcodeproj"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folderWithBoth.appendingPathComponent("Demo.xcodeproj"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folderWithBoth.appendingPathComponent("Demo.xcworkspace"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: flutterRoot.appendingPathComponent("ios/Runner.xcodeproj"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: flutterRoot.appendingPathComponent("ios/Runner.xcworkspace"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: emptyFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let directProj = folderOnlyProj.appendingPathComponent("Demo.xcodeproj")
        #expect(try DualSourceSigningEngine.resolveXcodeContainerURL(at: directProj) == directProj.standardizedFileURL)
        #expect(try DualSourceSigningEngine.resolveXcodeContainerURL(at: folderOnlyProj) == directProj.standardizedFileURL)

        let workspace = folderWithBoth.appendingPathComponent("Demo.xcworkspace")
        #expect(try DualSourceSigningEngine.resolveXcodeContainerURL(at: folderWithBoth) == workspace.standardizedFileURL)

        let flutterWorkspace = flutterRoot.appendingPathComponent("ios/Runner.xcworkspace")
        #expect(try DualSourceSigningEngine.resolveXcodeContainerURL(at: flutterRoot) == flutterWorkspace.standardizedFileURL)

        #expect(throws: AppleSyncError.self) {
            _ = try DualSourceSigningEngine.resolveXcodeContainerURL(at: emptyFolder)
        }
    }

    @Test("inspectXcodeProject selects Runner over alphabetical CocoaPods schemes and resolves Flutter Info.plist metadata")
    func inspectCocoaPodsWorkspaceSelectsAppScheme() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("applesync-workspace-test-\(UUID().uuidString)", isDirectory: true)
        let iosDir = tempRoot.appendingPathComponent("ios", isDirectory: true)
        let workspaceDir = iosDir.appendingPathComponent("Runner.xcworkspace", isDirectory: true)
        let runnerProjDir = iosDir.appendingPathComponent("Runner.xcodeproj", isDirectory: true)
        let runnerAppDir = iosDir.appendingPathComponent("Runner", isDirectory: true)

        try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: runnerProjDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: runnerAppDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let workspaceXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Workspace version="1.0">
           <FileRef location="group:Runner.xcodeproj"></FileRef>
           <FileRef location="group:Pods/Pods.xcodeproj"></FileRef>
        </Workspace>
        """
        try workspaceXML.write(to: workspaceDir.appendingPathComponent("contents.xcworkspacedata"), atomically: true, encoding: .utf8)

        let runnerPlist: [String: Any] = [
            "CFBundleDisplayName": "Sample Flutter App",
            "CFBundleName": "sample_flutter_app",
            "CFBundleShortVersionString": "$(FLUTTER_BUILD_NAME)",
            "CFBundleVersion": "$(FLUTTER_BUILD_NUMBER)"
        ]
        let plistData = try PropertyListSerialization.data(fromPropertyList: runnerPlist, format: .xml, options: 0)
        try plistData.write(to: runnerAppDir.appendingPathComponent("Info.plist"))

        let workspaceListJSON = """
        {
          "workspace": {
            "name": "Runner",
            "schemes": [
              "camera_avfoundation",
              "camera_avfoundation-camera_avfoundation_privacy",
              "FlutterGeneratedPluginSwiftPackage",
              "Pods-Runner",
              "Runner",
              "RunnerTests"
            ]
          }
        }
        """
        let projectListJSON = """
        {
          "project": {
            "name": "Runner",
            "schemes": ["FlutterGeneratedPluginSwiftPackage", "Runner"]
          }
        }
        """
        let runnerSettingsJSON = """
        [
          {
            "action": "build",
            "buildSettings": {
              "PRODUCT_TYPE": "com.apple.product-type.application",
              "WRAPPER_EXTENSION": "app",
              "PRODUCT_BUNDLE_IDENTIFIER": "com.example.sampleFlutterApp",
              "INFOPLIST_KEY_CFBundleDisplayName": "",
              "PRODUCT_NAME": "Runner",
              "INFOPLIST_FILE": "Runner/Info.plist",
              "SRCROOT": "\(iosDir.path)",
              "FLUTTER_BUILD_NAME": "1.1.9",
              "FLUTTER_BUILD_NUMBER": "11",
              "CURRENT_PROJECT_VERSION": "11",
              "DEVELOPMENT_TEAM": "TEAM567890"
            },
            "target": "Runner"
          }
        ]
        """
        let podSettingsJSON = """
        [
          {
            "action": "build",
            "buildSettings": {
              "PRODUCT_TYPE": "com.apple.product-type.framework",
              "WRAPPER_EXTENSION": "framework",
              "PRODUCT_BUNDLE_IDENTIFIER": "org.cocoapods.camera-avfoundation",
              "PRODUCT_NAME": "camera_avfoundation",
              "MARKETING_VERSION": "1.0",
              "CURRENT_PROJECT_VERSION": "1"
            },
            "target": "camera_avfoundation"
          }
        ]
        """

        let mockRunner = MockCommandRunner { exec, args, _, _, _ in
            if exec == "/usr/bin/xcodebuild" && args.contains("-list") {
                if args.contains("-project") {
                    return ProcessOutput(exitCode: 0, stdoutData: Data(projectListJSON.utf8), stderrData: Data())
                }
                return ProcessOutput(exitCode: 0, stdoutData: Data(workspaceListJSON.utf8), stderrData: Data())
            }
            if exec == "/usr/bin/xcodebuild" && args.contains("-showBuildSettings") {
                if let idx = args.firstIndex(of: "-scheme"), idx + 1 < args.count, args[idx + 1] == "Runner" {
                    return ProcessOutput(exitCode: 0, stdoutData: Data(runnerSettingsJSON.utf8), stderrData: Data())
                }
                return ProcessOutput(exitCode: 0, stdoutData: Data(podSettingsJSON.utf8), stderrData: Data())
            }
            return ProcessOutput(exitCode: 0, stdoutData: Data(), stderrData: Data())
        }

        let paths = AppleSyncPaths(rootURL: tempRoot.appendingPathComponent("State"))
        let engine = DualSourceSigningEngine(paths: paths, runner: mockRunner)

        // Passing the Flutter root resolves ios/Runner.xcworkspace and picks Runner over camera_avfoundation.
        let report = try await engine.inspectXcodeProject(at: tempRoot, preferredScheme: nil, configuration: "Release")
        #expect(report.projectPath == workspaceDir.standardizedFileURL.path)
        #expect(report.selectedScheme == "Runner")
        #expect(report.schemes.first == "Runner")
        #expect(report.bundleIdentifier == "com.example.sampleFlutterApp")
        #expect(report.displayName == "Sample Flutter App")
        #expect(report.marketingVersion == "1.1.9")
        #expect(report.buildVersion == "11")
        #expect(report.developmentTeam == "TEAM567890")

        // Explicitly picking a non-app CocoaPods framework scheme throws a clear validation error.
        await #expect(throws: AppleSyncError.self) {
            _ = try await engine.inspectXcodeProject(at: workspaceDir, preferredScheme: "camera_avfoundation", configuration: "Release")
        }
    }

    @Test("importBaseArtifact compiles Xcode snapshot unsigned so re-signing uses EffectiveBundleID")
    func importBaseArtifactCompilesUnsigned() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("applesync-unsigned-build-test-\(UUID().uuidString)", isDirectory: true)
        let fakeDerivedProduct = tempRoot.appendingPathComponent("FakeBuilt.app", isDirectory: true)
        try FileManager.default.createDirectory(at: fakeDerivedProduct, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let infoPlist: [String: Any] = [
            "CFBundleShortVersionString": "1.1.9",
            "CFBundleVersion": "11"
        ]
        let plistData = try PropertyListSerialization.data(fromPropertyList: infoPlist, format: .xml, options: 0)
        try plistData.write(to: fakeDerivedProduct.appendingPathComponent("Info.plist"))

        actor ArgRecorder {
            var capturedArgs: [String] = []
            func set(_ args: [String]) { capturedArgs = args }
        }
        let recorder = ArgRecorder()

        let mockRunner = MockCommandRunner { exec, args, _, _, _ in
            if exec == "/usr/bin/xcodebuild",
               args.contains("build"),
               let ddIdx = args.firstIndex(of: "-derivedDataPath"),
               ddIdx + 1 < args.count {
                await recorder.set(args)
                let builtAppDir = URL(fileURLWithPath: args[ddIdx + 1])
                    .appendingPathComponent("Build/Products/Release-iphoneos/Runner.app", isDirectory: true)
                try FileManager.default.createDirectory(at: builtAppDir, withIntermediateDirectories: true)
                try FileManager.default.copyItem(
                    at: fakeDerivedProduct.appendingPathComponent("Info.plist"),
                    to: builtAppDir.appendingPathComponent("Info.plist")
                )
                return ProcessOutput(exitCode: 0, stdoutData: Data(), stderrData: Data())
            }
            return ProcessOutput(exitCode: 0, stdoutData: Data(), stderrData: Data())
        }

        let paths = AppleSyncPaths(rootURL: tempRoot.appendingPathComponent("State"))
        let engine = DualSourceSigningEngine(paths: paths, runner: mockRunner)
        let source = AppSource.xcodeProject(
            projectOrWorkspacePath: tempRoot.appendingPathComponent("ios/Runner.xcworkspace").path,
            scheme: "Runner",
            configuration: "Release",
            pinnedSnapshotCommit: nil
        )
        let imported = try await engine.importBaseArtifact(appID: UUID(), source: source, teamID: "TEAM123AAA")
        let args = await recorder.capturedArgs

        #expect(args.contains("CODE_SIGNING_ALLOWED=NO"))
        #expect(args.contains("CODE_SIGNING_REQUIRED=NO"))
        #expect(!args.contains("-allowProvisioningUpdates"))
        #expect(imported.version == "1.1.9")
        #expect(imported.buildVersion == "11")
    }

    @Test("Sibling .xcworkspace upgrade and monorepo bounded discovery ignore Pods and node_modules")
    func siblingWorkspaceAndMonorepoDiscovery() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("applesync-monorepo-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        // Direct .xcodeproj selection upgrades to sibling .xcworkspace (ignoring internal project.xcworkspace)
        let cocoaDir = tempRoot.appendingPathComponent("CocoaApp/ios", isDirectory: true)
        let proj = cocoaDir.appendingPathComponent("Runner.xcodeproj", isDirectory: true)
        let internalWorkspace = proj.appendingPathComponent("project.xcworkspace", isDirectory: true)
        let siblingWorkspace = cocoaDir.appendingPathComponent("Runner.xcworkspace", isDirectory: true)
        try FileManager.default.createDirectory(at: internalWorkspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: siblingWorkspace, withIntermediateDirectories: true)

        #expect(try DualSourceSigningEngine.resolveXcodeContainerURL(at: proj) == siblingWorkspace.standardizedFileURL)

        // Monorepo depth-3 lookup skips ignored directories like Pods and node_modules
        let monoRoot = tempRoot.appendingPathComponent("Monorepo", isDirectory: true)
        try FileManager.default.createDirectory(at: monoRoot.appendingPathComponent("node_modules/fake/ios/Fake.xcodeproj"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: monoRoot.appendingPathComponent("Pods/FakePod.xcodeproj"), withIntermediateDirectories: true)
        let realAppProj = monoRoot.appendingPathComponent("apps/mobile/Demo.xcodeproj", isDirectory: true)
        try FileManager.default.createDirectory(at: realAppProj, withIntermediateDirectories: true)

        #expect(try DualSourceSigningEngine.resolveXcodeContainerURL(at: monoRoot) == realAppProj.standardizedFileURL)
    }

    @Test("isApplicationTarget, expandBuildSettingVariables modifiers, and custom configurations")
    func multiplatformFilterAndCustomConfigs() {
        let watchSettings: [String: String] = [
            "PRODUCT_TYPE": "com.apple.product-type.application.watchapp2",
            "WRAPPER_EXTENSION": "app",
            "PLATFORM_NAME": "watchos",
            "SUPPORTED_PLATFORMS": "watchos watchsimulator"
        ]
        let macSettings: [String: String] = [
            "PRODUCT_TYPE": "com.apple.product-type.application",
            "WRAPPER_EXTENSION": "app",
            "PLATFORM_NAME": "macosx",
            "SUPPORTED_PLATFORMS": "macosx"
        ]
        let iosSettings: [String: String] = [
            "PRODUCT_TYPE": "com.apple.product-type.application",
            "WRAPPER_EXTENSION": "app",
            "PLATFORM_NAME": "iphoneos",
            "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator",
            "PRODUCT_NAME": "Sample App!"
        ]

        #expect(DualSourceSigningEngine.isApplicationTarget(watchSettings) == false)
        #expect(DualSourceSigningEngine.isApplicationTarget(macSettings) == false)
        #expect(DualSourceSigningEngine.isApplicationTarget(iosSettings) == true)

        let expandedBundle = DualSourceSigningEngine.expandBuildSettingVariables(
            in: "com.acme.$(PRODUCT_NAME:rfc1034identifier)",
            settings: iosSettings
        )
        #expect(expandedBundle == "com.acme.Sample-App-")

        #expect(DualSourceSigningEngine.resolveConfiguration(requested: "Release", available: ["Debug", "Production"]) == "Production")
        #expect(DualSourceSigningEngine.resolveConfiguration(requested: "Release", available: ["Debug", "Staging-Release"]) == "Staging-Release")
        #expect(DualSourceSigningEngine.resolveConfiguration(requested: "Staging", available: ["Debug", "Staging", "Release"]) == "Staging")
    }

    @Test("locateBuiltApp ignores watchOS/nested Watch apps and picks *-iphoneos for custom flavor configurations")
    func locateBuiltAppPrefersIOSCustomConfig() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("applesync-locate-built-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let mockRunner = MockCommandRunner { exec, args, _, _, _ in
            if exec == "/usr/bin/xcodebuild",
               args.contains("build"),
               let ddIdx = args.firstIndex(of: "-derivedDataPath"),
               ddIdx + 1 < args.count {
                let products = URL(fileURLWithPath: args[ddIdx + 1]).appendingPathComponent("Build/Products", isDirectory: true)
                let watchApp = products.appendingPathComponent("Release-watchos/Companion.app", isDirectory: true)
                let iosApp = products.appendingPathComponent("CustomProd-iphoneos/MainApp.app", isDirectory: true)
                let nestedWatch = iosApp.appendingPathComponent("Watch/EmbeddedWatch.app", isDirectory: true)
                try FileManager.default.createDirectory(at: watchApp, withIntermediateDirectories: true)
                try FileManager.default.createDirectory(at: nestedWatch, withIntermediateDirectories: true)

                let watchPlist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleShortVersionString": "9.9", "CFBundleVersion": "99"], format: .xml, options: 0)
                try watchPlist.write(to: watchApp.appendingPathComponent("Info.plist"))
                try watchPlist.write(to: nestedWatch.appendingPathComponent("Info.plist"))

                let iosPlist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleShortVersionString": "2.4.0", "CFBundleVersion": "24"], format: .xml, options: 0)
                try iosPlist.write(to: iosApp.appendingPathComponent("Info.plist"))

                return ProcessOutput(exitCode: 0, stdoutData: Data(), stderrData: Data())
            }
            return ProcessOutput(exitCode: 0, stdoutData: Data(), stderrData: Data())
        }

        let paths = AppleSyncPaths(rootURL: tempRoot.appendingPathComponent("State"))
        let engine = DualSourceSigningEngine(paths: paths, runner: mockRunner)
        let source = AppSource.xcodeProject(
            projectOrWorkspacePath: tempRoot.appendingPathComponent("Demo.xcodeproj").path,
            scheme: "Demo",
            configuration: "Production",
            pinnedSnapshotCommit: nil
        )
        let imported = try await engine.importBaseArtifact(appID: UUID(), source: source, teamID: "TEAM123AAA")
        #expect(imported.baseAppURL.lastPathComponent == "MainApp.app")
        #expect(imported.version == "2.4.0")
        #expect(imported.buildVersion == "24")
    }

    @Test("ManagedAppRecord stripEmbeddedExtensions defaults false on legacy JSON and stageAndSignApp strips PlugIns/Watch for xcodeProject")
    func stripExtensionsWorksForXcodeProjectAndLegacyJSON() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("applesync-strip-xcode-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let baseApp = tempRoot.appendingPathComponent("Base/MainApp.app", isDirectory: true)
        try FileManager.default.createDirectory(at: baseApp.appendingPathComponent("PlugIns/Widget.appex"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: baseApp.appendingPathComponent("Watch/WatchApp.app"), withIntermediateDirectories: true)
        try Data().write(to: baseApp.appendingPathComponent("MainApp"))
        let appPlist = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleIdentifier": "com.example.demo", "CFBundleExecutable": "MainApp"],
            format: .xml,
            options: 0
        )
        try appPlist.write(to: baseApp.appendingPathComponent("Info.plist"))

        let futureExpires = ISO8601DateFormatter().string(from: Date().addingTimeInterval(7 * 86_400))
        let cmsPlist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>ExpirationDate</key>
            <date>\(futureExpires)</date>
            <key>ProvisionedDevices</key>
            <array><string>UDID123</string></array>
            <key>Entitlements</key>
            <dict><key>application-identifier</key><string>TEAM123AAA.com.applesync.demo</string></dict>
        </dict>
        </plist>
        """

        let paths = AppleSyncPaths(rootURL: tempRoot.appendingPathComponent("State"))
        let mockRunner = MockCommandRunner { exec, args, _, _, _ in
            if exec == "/usr/bin/xcodebuild",
               args.contains("-derivedDataPath"),
               let ddIdx = args.firstIndex(of: "-derivedDataPath"),
               ddIdx + 1 < args.count {
                let proxyApp = URL(fileURLWithPath: args[ddIdx + 1])
                    .appendingPathComponent("Build/Products/Debug-iphoneos/ProvisioningProxy.app", isDirectory: true)
                try FileManager.default.createDirectory(at: proxyApp, withIntermediateDirectories: true)
                try Data("stub-profile".utf8).write(to: proxyApp.appendingPathComponent("embedded.mobileprovision"))
                return ProcessOutput(exitCode: 0, stdoutData: Data(), stderrData: Data())
            }
            if exec == "/usr/bin/security", args.contains("cms") {
                return ProcessOutput(exitCode: 0, stdoutData: Data(cmsPlist.utf8), stderrData: Data())
            }
            if exec == "/usr/bin/security", args.contains("find-identity") {
                let idOut = "  1) AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA \"Apple Development: Test (TEAM123AAA)\"\n"
                return ProcessOutput(exitCode: 0, stdoutData: Data(idOut.utf8), stderrData: Data())
            }
            return ProcessOutput(exitCode: 0, stdoutData: Data(), stderrData: Data())
        }

        let engine = DualSourceSigningEngine(paths: paths, runner: mockRunner)
        let record = ManagedAppRecord(
            displayName: "MainApp",
            originalBundleID: "com.example.demo",
            effectiveBundleID: "com.example.demo.applesync.team123aaa",
            teamID: "TEAM123AAA",
            targetDeviceUDID: "UDID123",
            source: .xcodeProject(
                projectOrWorkspacePath: "/tmp/Demo.xcodeproj",
                scheme: "Demo",
                configuration: "Release",
                pinnedSnapshotCommit: nil
            ),
            state: .active,
            cachedBaseAppPath: baseApp.path,
            stripEmbeddedExtensions: true
        )

        // Legacy JSON missing stripEmbeddedExtensions decodes safely as false
        let encoded = try JSONEncoder().encode(record)
        var jsonObj = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        jsonObj.removeValue(forKey: "stripEmbeddedExtensions")
        let legacyData = try JSONSerialization.data(withJSONObject: jsonObj)
        let legacyDecoded = try JSONDecoder().decode(ManagedAppRecord.self, from: legacyData)
        #expect(legacyDecoded.stripEmbeddedExtensions == false)

        let signed = try await engine.stageAndSignApp(for: record)
        let stagedURL = URL(fileURLWithPath: signed.stagedAppPath)
        #expect(!FileManager.default.fileExists(atPath: stagedURL.appendingPathComponent("PlugIns").path))
        #expect(!FileManager.default.fileExists(atPath: stagedURL.appendingPathComponent("Watch").path))
    }
}
