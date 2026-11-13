import Foundation

public struct ProvisioningProxyGenerator: Sendable {
    private static let templateVersion = "v2"
    private static let versionMarkerFileName = ".proxy_template_version"

    public let paths: AppleSyncPaths
    public let runner: any CommandRunning
    public let xcodegenExecutablePath: String

    public init(
        paths: AppleSyncPaths = AppleSyncPaths(),
        runner: any CommandRunning = SystemProcessRunner(),
        xcodegenExecutablePath: String = ""
    ) {
        self.paths = paths
        self.runner = runner
        self.xcodegenExecutablePath = xcodegenExecutablePath
    }

    /// Ensures `ProvisioningProxy.xcodeproj` exists on disk using pure Swift generation
    /// (no external XcodeGen or Homebrew installation required).
    @discardableResult
    public func ensureProxyProject() async throws -> URL {
        try paths.ensureDirectoriesExist()
        let proxyDir = paths.provisioningProxyDirectoryURL
        let xcodeprojURL = proxyDir.appendingPathComponent("ProvisioningProxy.xcodeproj", isDirectory: true)
        let pbxprojURL = xcodeprojURL.appendingPathComponent("project.pbxproj", isDirectory: false)
        let versionMarkerURL = proxyDir.appendingPathComponent(Self.versionMarkerFileName, isDirectory: false)

        let fm = FileManager.default
        if fm.fileExists(atPath: pbxprojURL.path),
           let existingVersion = try? String(contentsOf: versionMarkerURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           existingVersion == Self.templateVersion {
            return xcodeprojURL
        }

        let sourcesDir = proxyDir.appendingPathComponent("Sources", isDirectory: true)
        try fm.createDirectory(at: sourcesDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: xcodeprojURL, withIntermediateDirectories: true)

        let infoPlistURL = proxyDir.appendingPathComponent("Info.plist", isDirectory: false)
        let mainSwiftURL = sourcesDir.appendingPathComponent("ProxyMain.swift", isDirectory: false)

        try Self.infoPlistContents.write(to: infoPlistURL, atomically: true, encoding: .utf8)
        try Self.proxyMainSwiftContents.write(to: mainSwiftURL, atomically: true, encoding: .utf8)
        try Self.pbxprojContents.write(to: pbxprojURL, atomically: true, encoding: .utf8)
        try Self.templateVersion.write(to: versionMarkerURL, atomically: true, encoding: .utf8)

        return xcodeprojURL
    }

    private static let pbxprojContents = """
    // !$*UTF8*$!
    {
    \tarchiveVersion = 1;
    \tclasses = {
    \t};
    \tobjectVersion = 56;
    \tobjects = {

    /* Begin PBXBuildFile section */
    \t\t3AACABBAED192B8E95DC65F6 /* ProxyMain.swift in Sources */ = {isa = PBXBuildFile; fileRef = BC373270D5A4F274AE32FA90 /* ProxyMain.swift */; };
    /* End PBXBuildFile section */

    /* Begin PBXFileReference section */
    \t\t90487E480B6FB57970DB57F2 /* ProvisioningProxy.app */ = {isa = PBXFileReference; includeInIndex = 0; lastKnownFileType = wrapper.application; path = ProvisioningProxy.app; sourceTree = BUILT_PRODUCTS_DIR; };
    \t\tBC373270D5A4F274AE32FA90 /* ProxyMain.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = ProxyMain.swift; sourceTree = "<group>"; };
    /* End PBXFileReference section */

    /* Begin PBXGroup section */
    \t\t30420A80CE84A63BE6B94936 = {
    \t\t\tisa = PBXGroup;
    \t\t\tchildren = (
    \t\t\t\tB7BC4BB42B4AAA0D50755196 /* Sources */,
    \t\t\t\t34DF7539960960D029427E68 /* Products */,
    \t\t\t);
    \t\t\tsourceTree = "<group>";
    \t\t};
    \t\t34DF7539960960D029427E68 /* Products */ = {
    \t\t\tisa = PBXGroup;
    \t\t\tchildren = (
    \t\t\t\t90487E480B6FB57970DB57F2 /* ProvisioningProxy.app */,
    \t\t\t);
    \t\t\tname = Products;
    \t\t\tsourceTree = "<group>";
    \t\t};
    \t\tB7BC4BB42B4AAA0D50755196 /* Sources */ = {
    \t\t\tisa = PBXGroup;
    \t\t\tchildren = (
    \t\t\t\tBC373270D5A4F274AE32FA90 /* ProxyMain.swift */,
    \t\t\t);
    \t\t\tpath = Sources;
    \t\t\tsourceTree = "<group>";
    \t\t};
    /* End PBXGroup section */

    /* Begin PBXNativeTarget section */
    \t\t2BE93314313FD79F620C0168 /* ProvisioningProxy */ = {
    \t\t\tisa = PBXNativeTarget;
    \t\t\tbuildConfigurationList = 7359501A2D5214099517B78D /* Build configuration list for PBXNativeTarget "ProvisioningProxy" */;
    \t\t\tbuildPhases = (
    \t\t\t\t6A5709EEE7C2025BAE5E0CEB /* Sources */,
    \t\t\t);
    \t\t\tbuildRules = (
    \t\t\t);
    \t\t\tdependencies = (
    \t\t\t);
    \t\t\tname = ProvisioningProxy;
    \t\t\tproductName = ProvisioningProxy;
    \t\t\tproductReference = 90487E480B6FB57970DB57F2 /* ProvisioningProxy.app */;
    \t\t\tproductType = "com.apple.product-type.application";
    \t\t};
    /* End PBXNativeTarget section */

    /* Begin PBXProject section */
    \t\t650B03714C855B4A6EDFDEBB /* Project object */ = {
    \t\t\tisa = PBXProject;
    \t\t\tattributes = {
    \t\t\t\tBuildIndependentTargetsInParallel = YES;
    \t\t\t\tLastUpgradeCheck = 1500;
    \t\t\t\tTargetAttributes = {
    \t\t\t\t\t2BE93314313FD79F620C0168 = {
    \t\t\t\t\t\tProvisioningStyle = Automatic;
    \t\t\t\t\t};
    \t\t\t\t};
    \t\t\t};
    \t\t\tbuildConfigurationList = B42EF83068C46396F3C7BAB8 /* Build configuration list for PBXProject "ProvisioningProxy" */;
    \t\t\tdevelopmentRegion = en;
    \t\t\thasScannedForEncodings = 0;
    \t\t\tknownRegions = (
    \t\t\t\tBase,
    \t\t\t\ten,
    \t\t\t);
    \t\t\tmainGroup = 30420A80CE84A63BE6B94936;
    \t\t\tproductRefGroup = 34DF7539960960D029427E68 /* Products */;
    \t\t\tprojectDirPath = "";
    \t\t\tprojectRoot = "";
    \t\t\ttargets = (
    \t\t\t\t2BE93314313FD79F620C0168 /* ProvisioningProxy */,
    \t\t\t);
    \t\t};
    /* End PBXProject section */

    /* Begin PBXSourcesBuildPhase section */
    \t\t6A5709EEE7C2025BAE5E0CEB /* Sources */ = {
    \t\t\tisa = PBXSourcesBuildPhase;
    \t\t\tbuildActionMask = 2147483647;
    \t\t\tfiles = (
    \t\t\t\t3AACABBAED192B8E95DC65F6 /* ProxyMain.swift in Sources */,
    \t\t\t);
    \t\t\trunOnlyForDeploymentPostprocessing = 0;
    \t\t};
    /* End PBXSourcesBuildPhase section */

    /* Begin XCBuildConfiguration section */
    \t\t78863AB4AA32B6DD2254CE01 /* Release */ = {
    \t\t\tisa = XCBuildConfiguration;
    \t\t\tbuildSettings = {
    \t\t\t\tASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;
    \t\t\t\tCODE_SIGN_IDENTITY = "iPhone Developer";
    \t\t\t\tCODE_SIGN_STYLE = Automatic;
    \t\t\t\tGENERATE_INFOPLIST_FILE = NO;
    \t\t\t\tINFOPLIST_FILE = Info.plist;
    \t\t\t\tIPHONEOS_DEPLOYMENT_TARGET = 17.0;
    \t\t\t\tLD_RUNPATH_SEARCH_PATHS = (
    \t\t\t\t\t"$(inherited)",
    \t\t\t\t\t"@executable_path/Frameworks",
    \t\t\t\t);
    \t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = com.applesync.proxy;
    \t\t\t\tPRODUCT_NAME = ProvisioningProxy;
    \t\t\t\tSDKROOT = iphoneos;
    \t\t\t\tSUPPORTED_PLATFORMS = iphoneos;
    \t\t\t\tSUPPORTS_MACCATALYST = NO;
    \t\t\t\tSUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD = NO;
    \t\t\t\tSWIFT_VERSION = 5.0;
    \t\t\t\tTARGETED_DEVICE_FAMILY = "1,2";
    \t\t\t};
    \t\t\tname = Release;
    \t\t};
    \t\t840EF660C7DD2142EAA060D8 /* Release */ = {
    \t\t\tisa = XCBuildConfiguration;
    \t\t\tbuildSettings = {
    \t\t\t\tALWAYS_SEARCH_USER_PATHS = NO;
    \t\t\t\tCLANG_ANALYZER_NONNULL = YES;
    \t\t\t\tCLANG_ANALYZER_NUMBER_OBJECT_CONVERSION = YES_AGGRESSIVE;
    \t\t\t\tCLANG_CXX_LANGUAGE_STANDARD = "gnu++14";
    \t\t\t\tCLANG_CXX_LIBRARY = "libc++";
    \t\t\t\tCLANG_ENABLE_MODULES = YES;
    \t\t\t\tCLANG_ENABLE_OBJC_ARC = YES;
    \t\t\t\tCLANG_ENABLE_OBJC_WEAK = YES;
    \t\t\t\tENABLE_NS_ASSERTIONS = NO;
    \t\t\t\tENABLE_STRICT_OBJC_MSGSEND = YES;
    \t\t\t\tGCC_C_LANGUAGE_STANDARD = gnu11;
    \t\t\t\tGCC_NO_COMMON_BLOCKS = YES;
    \t\t\t\tIPHONEOS_DEPLOYMENT_TARGET = 17.0;
    \t\t\t\tPRODUCT_NAME = "$(TARGET_NAME)";
    \t\t\t\tSDKROOT = iphoneos;
    \t\t\t\tSWIFT_COMPILATION_MODE = wholemodule;
    \t\t\t\tSWIFT_OPTIMIZATION_LEVEL = "-O";
    \t\t\t\tSWIFT_VERSION = 5.0;
    \t\t\t};
    \t\t\tname = Release;
    \t\t};
    \t\t9F48D144F5D9922178A266D3 /* Debug */ = {
    \t\t\tisa = XCBuildConfiguration;
    \t\t\tbuildSettings = {
    \t\t\t\tASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;
    \t\t\t\tCODE_SIGN_IDENTITY = "iPhone Developer";
    \t\t\t\tCODE_SIGN_STYLE = Automatic;
    \t\t\t\tGENERATE_INFOPLIST_FILE = NO;
    \t\t\t\tINFOPLIST_FILE = Info.plist;
    \t\t\t\tIPHONEOS_DEPLOYMENT_TARGET = 17.0;
    \t\t\t\tLD_RUNPATH_SEARCH_PATHS = (
    \t\t\t\t\t"$(inherited)",
    \t\t\t\t\t"@executable_path/Frameworks",
    \t\t\t\t);
    \t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = com.applesync.proxy;
    \t\t\t\tPRODUCT_NAME = ProvisioningProxy;
    \t\t\t\tSDKROOT = iphoneos;
    \t\t\t\tSUPPORTED_PLATFORMS = iphoneos;
    \t\t\t\tSUPPORTS_MACCATALYST = NO;
    \t\t\t\tSUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD = NO;
    \t\t\t\tSWIFT_VERSION = 5.0;
    \t\t\t\tTARGETED_DEVICE_FAMILY = "1,2";
    \t\t\t};
    \t\t\tname = Debug;
    \t\t};
    \t\tBF222B4F72EF4251A04C6BC5 /* Debug */ = {
    \t\t\tisa = XCBuildConfiguration;
    \t\t\tbuildSettings = {
    \t\t\t\tALWAYS_SEARCH_USER_PATHS = NO;
    \t\t\t\tCLANG_ANALYZER_NONNULL = YES;
    \t\t\t\tCLANG_ANALYZER_NUMBER_OBJECT_CONVERSION = YES_AGGRESSIVE;
    \t\t\t\tCLANG_CXX_LANGUAGE_STANDARD = "gnu++14";
    \t\t\t\tCLANG_CXX_LIBRARY = "libc++";
    \t\t\t\tCLANG_ENABLE_MODULES = YES;
    \t\t\t\tCLANG_ENABLE_OBJC_ARC = YES;
    \t\t\t\tCLANG_ENABLE_OBJC_WEAK = YES;
    \t\t\t\tENABLE_STRICT_OBJC_MSGSEND = YES;
    \t\t\t\tENABLE_TESTABILITY = YES;
    \t\t\t\tGCC_C_LANGUAGE_STANDARD = gnu11;
    \t\t\t\tGCC_NO_COMMON_BLOCKS = YES;
    \t\t\t\tGCC_OPTIMIZATION_LEVEL = 0;
    \t\t\t\tGCC_PREPROCESSOR_DEFINITIONS = (
    \t\t\t\t\t"$(inherited)",
    \t\t\t\t\t"DEBUG=1",
    \t\t\t\t);
    \t\t\t\tIPHONEOS_DEPLOYMENT_TARGET = 17.0;
    \t\t\t\tONLY_ACTIVE_ARCH = YES;
    \t\t\t\tPRODUCT_NAME = "$(TARGET_NAME)";
    \t\t\t\tSDKROOT = iphoneos;
    \t\t\t\tSWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG;
    \t\t\t\tSWIFT_OPTIMIZATION_LEVEL = "-Onone";
    \t\t\t\tSWIFT_VERSION = 5.0;
    \t\t\t};
    \t\t\tname = Debug;
    \t\t};
    /* End XCBuildConfiguration section */

    /* Begin XCConfigurationList section */
    \t\t7359501A2D5214099517B78D /* Build configuration list for PBXNativeTarget "ProvisioningProxy" */ = {
    \t\t\tisa = XCConfigurationList;
    \t\t\tbuildConfigurations = (
    \t\t\t\t9F48D144F5D9922178A266D3 /* Debug */,
    \t\t\t\t78863AB4AA32B6DD2254CE01 /* Release */,
    \t\t\t);
    \t\t\tdefaultConfigurationIsVisible = 0;
    \t\t\tdefaultConfigurationName = Debug;
    \t\t};
    \t\tB42EF83068C46396F3C7BAB8 /* Build configuration list for PBXProject "ProvisioningProxy" */ = {
    \t\t\tisa = XCConfigurationList;
    \t\t\tbuildConfigurations = (
    \t\t\t\tBF222B4F72EF4251A04C6BC5 /* Debug */,
    \t\t\t\t840EF660C7DD2142EAA060D8 /* Release */,
    \t\t\t);
    \t\t\tdefaultConfigurationIsVisible = 0;
    \t\t\tdefaultConfigurationName = Debug;
    \t\t};
    /* End XCConfigurationList section */

    \t};
    \trootObject = 650B03714C855B4A6EDFDEBB /* Project object */;
    }
    """

    private static let infoPlistContents = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
        <key>CFBundleDevelopmentRegion</key>
        <string>en</string>
        <key>CFBundleExecutable</key>
        <string>$(EXECUTABLE_NAME)</string>
        <key>CFBundleIdentifier</key>
        <string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
        <key>CFBundleInfoDictionaryVersion</key>
        <string>6.0</string>
        <key>CFBundleName</key>
        <string>$(PRODUCT_NAME)</string>
        <key>CFBundlePackageType</key>
        <string>APPL</string>
        <key>CFBundleShortVersionString</key>
        <string>1.0</string>
        <key>CFBundleVersion</key>
        <string>1</string>
        <key>LSRequiresIPhoneOS</key>
        <true/>
        <key>UIApplicationSceneManifest</key>
        <dict>
            <key>UIApplicationSupportsMultipleScenes</key>
            <false/>
        </dict>
    </dict>
    </plist>
    """

    private static let proxyMainSwiftContents = """
    import SwiftUI

    @main
    struct ProxyApp: App {
        var body: some Scene {
            WindowGroup {
                Text("AppleSync Provisioning Proxy")
            }
        }
    }
    """
}
