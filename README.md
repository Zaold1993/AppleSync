# AppleSync

**Keep your private iOS apps alive beyond Apple's 7-day Personal Team limit — directly from your own Mac, with Wi-Fi auto-resync, multi-account support, and SHA-256 verified app data freeze/swap.**

AppleSync is a native macOS menu bar app, desktop dashboard, and CLI (`AppleSyncCore` + `applesync`) built on Apple's own toolchain (`xcodebuild`, `codesign`, `security`, and CoreDevice / `devicectl`). It helps indie developers and hobbyists running apps with a **free Apple Developer Personal Team** manage the **7-day signature expiry** and **3-active-app slot limit** without paid stores, third-party servers, or leaving macOS.

---

## Key Features

- **Dual-Source Onboarding (Xcode Projects & Clean IPAs)**:
  - **Xcode Projects / Workspaces**: Works with native Swift/Xcode apps, Flutter (`ios/Runner.xcworkspace`), CocoaPods, React Native, or monorepos. AppleSync discovers the project, builds an **isolated unsigned snapshot**, and never dirties your working git tree.
  - **Clean `.ipa` Files**: Imports unencrypted `.ipa` bundles (for example, test builds shared by a friend), detects whether they already include a valid **1-year Ad-Hoc profile** for your device (exempt from the 3-app free limit!), or re-signs them cleanly with your Personal Team.
- **Automated Days 4–6 Wi-Fi Resync Daemon**:
  - **Days 0–3**: Idle (zero unnecessary churn).
  - **Day 4–5**: Stages a fresh 7-day signed bundle offline on your Mac; whenever your unlocked iPhone is reachable over Wi-Fi (or USB), pushes the update **in-place** so your iOS app data stays intact.
  - **Day 6**: Raises a critical macOS notification (`Urgent: Expires in < 24 Hours`) if your iPhone hasn't completed a Wi-Fi sync yet.
  - **Wake-on-Mac & Pause Controls**: Checks automatically every 15 minutes and on Mac wake. You can **stop the daemon globally** or **pause/resume individual apps** at any time.
- **Break Past the 3-App Limit Safely (SHA-256 Backup, Freeze, Thaw & Atomic Swap)**:
  - Pulls your app's `Documents/` and `Library/` sandbox container over Wi-Fi/USB, verifies every file against a **SHA-256 tree digest** (`.verified` marker + `manifest.json`), and only then uninstalls to free a slot.
  - **2-Phase Atomic Swap** lets you swap an active app into the Mac Vault and restore a frozen app (with its saved data!) back onto your iPhone.
- **Multi-Account Support**: Use multiple free Apple IDs (`Team ID` certificates in your macOS Keychain) and track per-account signatures cleanly.

---

## Requirements

- **Mac**: macOS 15.0 (Sequoia) or newer.
- **Xcode**: Xcode 15.0 or newer installed from the Mac App Store (or Apple Developer Downloads), with the iOS platform SDK installed.
- **iPhone / iPad**: iOS 17.0 or newer (required for CoreDevice / `devicectl`).
- **Apple ID**: One or more standard Apple IDs signed into Xcode as a **Personal Team** (free — no \$99/year membership needed).
- **No external runtime dependencies**: AppleSync uses only built-in macOS/Xcode binaries (`/usr/bin/xcodebuild`, `/usr/bin/xcrun devicectl`, `/usr/bin/codesign`, `/usr/bin/security`, `/usr/bin/plutil`, `unzip`, `lipo`, `otool`, `vtool`). Homebrew and XcodeGen are **not** required.

---

## Setup Guide (Starting From Scratch)

Follow these steps if you have never built or sideloaded an iOS app from Xcode before.

### Step 1: Install Xcode & Command Line Tools

1. Install **Xcode** from the **Mac App Store**.
2. Open Xcode once, accept the license agreement, and make sure the **iOS SDK** finishes downloading when prompted (`Xcode > Settings > Components` or first-launch setup).
3. Open **Terminal** and confirm `xcodebuild` and `devicectl` work:
   ```bash
   xcodebuild -version
   xcrun devicectl --version
   ```
   If `xcode-select` points somewhere else, fix it with:
   ```bash
   sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
   ```

### Step 2: Create Your Free Apple Developer "Personal Team" Profile

You do **not** need to pay \$99/year. A free Apple ID creates a valid 7-day Personal Team signing identity in seconds:

1. Open **Xcode** and go to **Xcode > Settings…** (or `⌘ ,`) > **Accounts**.
2. Click the **`+`** button at the bottom-left and choose **Apple ID**.
3. Sign in with your Apple ID. (You can repeat this to add multiple free Apple IDs!)
4. Select your account in the list, click **Manage Certificates…**, click **`+`** at the bottom-left, and choose **Apple Development**.
5. Verify in **Terminal** that macOS sees your signing identity:
   ```bash
   security find-identity -v -p codesigning
   ```
   You should see a line like:
   `1) ABC123... "Apple Development: your@email.com (TEAMID1234)"`

### Step 3: Prepare Your iPhone (One-Time USB Pairing + Developer Mode)

Apple only lets Xcode/AppleSync deploy to your iPhone over Wi-Fi after a **one-time USB cable trust & pairing**:

1. Plug your iPhone into your Mac via USB cable and unlock your iPhone.
2. When prompted on the iPhone, tap **Trust** and enter your passcode.
3. Enable **Developer Mode** on your iPhone:
   - Go to **Settings > Privacy & Security > Developer Mode** -> turn it **On** -> restart the iPhone when prompted and confirm **Turn On** after reboot.
   - *(Note: On iOS, the "Developer Mode" toggle appears only after Xcode detects the connected phone at least once. If you don't see it yet, open **Xcode > Window > Devices and Simulators**, select your iPhone, and wait ~10 seconds.)*
4. Enable **Wi-Fi Syncing** in **Xcode > Window > Devices and Simulators** (select your iPhone -> check **Connect via network**), or in Finder under your iPhone (`Show this iPhone when on Wi-Fi`).
5. Also **open Finder / Xcode Devices & Simulators once** while the Personal Team is selected on a test build (AppleSync uses a lightweight internal `ProvisioningProxy` via `xcodebuild -allowProvisioningUpdates` to register your iPhone's UDID automatically once paired, so your device must be connected via USB on the very first provisioning profile mint for a new Team ID!).
6. Verify your iPhone appears in CoreDevice:
   ```bash
   xcrun devicectl list devices
   ```
   Disconnect the USB cable — as long as your Mac and iPhone share the same Wi-Fi network and your iPhone is **unlocked** during installation, CoreDevice will reach it wirelessly.

### Step 4: Build & Install AppleSync

Because AppleSync is an open-source app signed with a local ad-hoc signature (`CODE_SIGN_IDENTITY: "-"` instead of a paid \$99/year Apple Developer ID Notarization certificate), macOS Gatekeeper flags pre-built `.zip` downloads from the browser. You have **two easy options**:

#### Option A: Build Locally With Xcode (Recommended — Zero Gatekeeper Prompts)

Since **Xcode is already required** to run AppleSync anyway, building from source takes seconds and creates a local app bundle that macOS trusts immediately with zero Gatekeeper warnings:

1. **Via Terminal (one command)**:
   ```bash
   git clone https://github.com/Zaold1993/AppleSync.git
   cd AppleSync
   chmod +x scripts/build-app.sh
   ./scripts/build-app.sh --install
   open /Applications/AppleSync.app
   ```
2. **Or directly inside Xcode GUI**:
   - Open `App/AppleSync.xcodeproj` in Xcode, select the **AppleSync** scheme (`My Mac`), and click **Run (`⌘ R`)** (or **Product > Archive** to export to `/Applications`).

#### Option B: Pre-Built Release Archive (`AppleSync-macOS.zip`)

If you downloaded `AppleSync-macOS.zip` directly from **GitHub Releases**:

1. Unzip the archive and drag `AppleSync.app` into `/Applications/`.
2. Double-click `AppleSync.app` once (macOS will display an "unidentified developer / malware check" block — click **Done** / **OK**).
3. Authorize the app in **System Settings > Privacy & Security**, scroll down to the Security section, and click **Open Anyway** next to `AppleSync` (or clear the browser quarantine flag in Terminal with `xattr -dr com.apple.quarantine /Applications/AppleSync.app`).

### Step 5: Important First-Run Keychain Prompt ("Always Allow")

The **very first time** AppleSync signs an app with `/usr/bin/codesign`, macOS will display a system dialog:

> *"codesign wants to access key '...' in your keychain."*

Click **Always Allow** and enter your Mac login password.  
If you only click "Allow", future background refreshes during Days 4–6 will hang waiting for a manual password prompt when you aren't looking!

---

## How to Use AppleSync

AppleSync runs as a **menu bar icon** (top-right of your screen) and includes a full **Dashboard** window.

### 1. Add an Xcode Project
1. Click **Xcode Project** in the Dashboard toolbar.
2. Select a `.xcodeproj`, `.xcworkspace`, or even the enclosing project folder (e.g., the root folder of a Flutter or React Native repo — AppleSync searches cleanly for the workspace/project while ignoring `Pods`, `DerivedData`, `node_modules`, `.git`, etc.).
3. Click **Inspect**, verify the detected app target, scheme, and configuration (`Release` recommended), choose your **Xcode Account / Certificate** and target **iPhone**, and click **Import & Sign**.

### 2. Add a Clean `.ipa`
1. Click **Import IPA**.
2. Choose an unencrypted `.ipa` file (not an App Store FairPlay `.ipa` — those have `cryptid=1` and cannot be re-signed).
3. AppleSync inspects architecture (`arm64` iOS), extensions (`PlugIns/`, `Watch/`), and any embedded `.mobileprovision`:
   - **Ad-Hoc 1-Year Pass-Through**: If a friend gave you an `.ipa` already provisioned for your iPhone's UDID under a paid team, AppleSync can install it untouched (`activeAdHoc`), **exempt from your 3-app free slot limit**!
   - **Personal Team Re-Sign**: Otherwise, AppleSync rewrites the Bundle ID into a deterministic private namespace (`com.applesync.<team>.<slug>-<hash>`), optionally strips nested extensions/Watch bundles (recommended for Free accounts because Apple Free profiles don't allow multiple App Extension App IDs or shared App Groups), mints a fresh 7-day profile, signs everything nested-first, and installs it.

### 3. Monitor & Manage Syncs
- **Daemon Controls**: Use **Stop Daemon** / **Start Daemon** in the menu bar or dashboard to halt all background activity globally, or use **Pause Auto-Sync** / **Resume Auto-Sync** for individual apps.
- **Cancel Anytime**: Click **Stop** on the bottom banner (or stop icon in the menu bar) to cancel an in-flight build/install immediately.
- **Launch at Login**: Toggle **Launch automatically at login** in the menu bar popover (requires `AppleSync.app` to reside in `/Applications/`, and may ask for approval in **System Settings > General > Login Items**).

### 4. Backup, Freeze, Thaw & Atomic Swap
- **Backup Now**: Saves `Documents/` and `Library/` from the iPhone app container to `~/Library/Application Support/AppleSync/Backups/` with a full **SHA-256 directory digest**.
- **Clean Restore**: Verifies the backup SHA-256 on disk, stages and signs a fresh `.app` bundle *first* (aborting safely without touching your device if signing fails), then uninstalls, reinstalls cleanly, and restores `Documents/` and `Library/` so stale files created after the snapshot do not linger.
- **Freeze App**: Creates a verified backup -> verifies SHA-256 on disk -> uninstalls from iPhone -> moves the app to **Frozen Vault**, freeing one of your 3 free slots.
- **Thaw / Swap**: Re-signs the frozen app with a fresh 7-day profile, installs it, and restores your backed-up `Documents/` and `Library/` data in-place. **Swap** executes Freeze A + Thaw B safely: it compiles/signs B *and* verifies A's backup on disk before uninstalling A.

---

## Command-Line Interface (`applesync`)

AppleSync also ships a headless Swift CLI target (`applesync`) sharing the exact same `AppleSyncCore` engine and file lock:

```bash
swift run applesync help
swift run applesync teams --json
swift run applesync devices --json
swift run applesync sync-cycle
swift run applesync daemon pause
```

*(Data and lock files are stored under `~/Library/Application Support/AppleSync/`.)*

---

## Running Tests & Verification

```bash
# Run unit & integration test suite (Swift Testing)
swift test

# Build the macOS app with Xcode
./scripts/build-app.sh
```

---

## Architecture Overview

```text
AppleSync/
├── Package.swift                       # Swift 6.0 library (AppleSyncCore) + CLI (applesync) + tests
├── Sources/
│   ├── AppleSyncCore/
│   │   ├── Models/AppleSyncModels.swift
│   │   ├── Infrastructure/
│   │   │   ├── ProcessRunner.swift     # Async Process runner + CrossProcessFileLock (flock)
│   │   │   └── CoreDeviceClient.swift  # xcrun devicectl JSON wrapper
│   │   ├── Signing/
│   │   │   ├── ProvisioningProxyGenerator.swift # Pure-Swift Xcode proxy project generator
│   │   │   └── DualSourceSigningEngine.swift    # Project/IPA inspection, minting & codesign
│   │   ├── Backup/BackupAndSwapManager.swift    # SHA-256 backup/restore, freeze/thaw & swap
│   │   ├── Storage/SyncStateStore.swift         # Atomic JSON state store
│   │   └── Sync/DeviceOperationCoordinator.swift# Days 4-6 state machine & deduplicated alerts
│   └── AppleSyncCLI/main.swift
├── App/
│   ├── project.yml                     # XcodeGen source spec (optional; project.pbxproj checked in)
│   ├── AppleSync.xcodeproj/            # Ready-to-build macOS Xcode project
│   └── AppleSyncApp/                   # SwiftUI MenuBarExtra + NavigationSplitView dashboard
├── Tests/AppleSyncCoreTests/           # Signing, backup/swap, coordinator & foundation tests
└── scripts/build-app.sh                # One-command Release .app & .zip builder
```

---

## Known Limitations & Apple Constraints

1. **Free Apple Account Entitlement Limits**: Free Personal Team profiles do **not** support Push Notifications, iCloud/CloudKit, App Groups, Network Extensions, Associated Domains, or paid-only capabilities. Enabling *"Strip nested extensions"* resolves most Widget/Share/Watch extension provisioning errors cleanly for personal use.
2. **Effective Bundle ID Rewrite**: Because your Personal Team cannot register another developer's Bundle ID (nor a globally claimed one), re-signed apps use `com.applesync.<team>.<slug>-<hash>`. That means AppleSync installs a clean personal copy alongside (rather than overwriting) existing App Store apps.
3. **iPhone Must Be Unlocked During Installation**: Apple's CoreDevice refuses app installs and container file transfers while iOS is locked. AppleSync detects this (`lockState`), pauses safely, and reminds you once per cycle on Day 5–6+.
4. **App Store Encrypted IPAs (`cryptid=1`)**: FairPlay-encrypted App Store `.ipa` files cannot be re-signed by `codesign` and are rejected during inspection.
5. **iOS Keychain Data Cannot Be Exported**: CoreDevice backups archive your app's `Documents/` and `Library/` sandbox folders, but Apple does not expose iOS Keychain entries (for example, OAuth tokens saved in Keychain rather than `UserDefaults`/files) across uninstalls.
6. **Gatekeeper Notice on Pre-Built Downloads**: Without a paid \$99/year Apple Developer ID Notarization certificate, downloading `.zip` builds triggers macOS Gatekeeper once until authorized in **System Settings > Privacy & Security > Open Anyway** (building locally with Xcode avoids this completely).

---

## Disclaimer

AppleSync is intended strictly for managing your own development builds and legitimately shared private/test `.ipa` archives on devices you own, using Apple's standard Xcode Personal Team workflow. You are responsible for respecting Apple's Xcode and Developer Program terms and third-party software licenses.

## License

MIT — see [LICENSE](LICENSE).
