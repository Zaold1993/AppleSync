import AppleSyncCore
import SwiftUI

extension AppLifecycleState {
    var displayTitle: String {
        switch self {
        case .active: return "Active"
        case .stagedOffline: return "Staged Offline (D4-5)"
        case .syncUrgent: return "Urgent (Day 6)"
        case .expiredOnDevice: return "Expired on iPhone"
        case .frozen: return "Frozen (Vault)"
        case .activeAdHoc: return "Ad-Hoc (Exempt)"
        }
    }

    var badgeColor: Color {
        switch self {
        case .active: return .green
        case .stagedOffline: return .blue
        case .syncUrgent: return .orange
        case .expiredOnDevice: return .red
        case .frozen: return .secondary
        case .activeAdHoc: return .purple
        }
    }

    var symbolName: String {
        switch self {
        case .active: return "checkmark.seal.fill"
        case .stagedOffline: return "tray.and.arrow.down.fill"
        case .syncUrgent: return "exclamationmark.triangle.fill"
        case .expiredOnDevice: return "xmark.octagon.fill"
        case .frozen: return "snowflake"
        case .activeAdHoc: return "person.2.badge.key.fill"
        }
    }
}

extension ManagedAppRecord {
    var countdownText: String {
        if state == .frozen { return "In Mac Vault" }
        guard let seconds = remainingValiditySeconds() else {
            return state == .activeAdHoc ? "Ad-Hoc" : "Not installed"
        }
        if seconds <= 0 { return "Expired" }
        let totalHours = Int(seconds / 3600)
        let days = totalHours / 24
        let hours = totalHours % 24
        if days > 0 {
            return "\(days)d \(hours)h"
        }
        return "\(max(1, hours))h left"
    }

    var countdownColor: Color {
        if state == .frozen { return .secondary }
        guard let seconds = remainingValiditySeconds() else { return .secondary }
        if seconds <= 0 { return .red }
        if seconds <= 24 * 3600 { return .orange }
        if seconds <= 3 * 86_400 { return .blue }
        return .green
    }

    var sourceLabel: String {
        switch source {
        case .xcodeProject(_, let scheme, let configuration, _):
            return "Xcode (\(scheme) · \(configuration))"
        case .externalIPA:
            return state == .activeAdHoc ? "Ad-Hoc IPA (1 Year)" : "Re-Signed IPA"
        }
    }
}

enum AppleSyncFormatting {
    static func bytesString(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
