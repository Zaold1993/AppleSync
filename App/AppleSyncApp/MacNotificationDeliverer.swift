import AppleSyncCore
import Foundation
@preconcurrency import UserNotifications

public actor MacNotificationDeliverer: NotificationDelivering {
    private let onDelivered: @Sendable (SyncAlert) async -> Void
    private var authorizationRequested = false

    public init(onDelivered: @escaping @Sendable (SyncAlert) async -> Void = { _ in }) {
        self.onDelivered = onDelivered
    }

    public func requestPermissionsIfRunningInAppBundle() async {
        guard Self.canUseUserNotificationCenter(), !authorizationRequested else { return }
        authorizationRequested = true
        let center = UNUserNotificationCenter.current()
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
    }

    public func deliver(_ alert: SyncAlert) async {
        await onDelivered(alert)

        guard Self.canUseUserNotificationCenter() else {
            await ConsoleNotificationDeliverer().deliver(alert)
            return
        }

        if !authorizationRequested {
            await requestPermissionsIfRunningInAppBundle()
        }

        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.body = alert.body
        content.sound = alert.severity == .critical ? .defaultCritical : .default
        if alert.severity == .critical {
            content.interruptionLevel = .timeSensitive
        }

        let request = UNNotificationRequest(
            identifier: "com.applesync.\(alert.id.uuidString)",
            content: content,
            trigger: nil
        )
        try? await UNUserNotificationCenter.current().add(request)
    }

    private static func canUseUserNotificationCenter() -> Bool {
        Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil
    }
}
