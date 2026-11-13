import Foundation

public struct SyncAlert: Codable, Sendable, Equatable, Identifiable {
    public enum Category: String, Codable, Sendable, Equatable, CaseIterable {
        case syncUrgentDay6
        case deviceLockedWaiting
        case xcodeAuthRequired
        case expiryWarning
        case syncSucceeded
        case activeSlotsFull
    }

    public enum Severity: String, Codable, Sendable, Equatable, CaseIterable {
        case info
        case warning
        case critical
    }

    public var id: UUID
    public var appID: UUID?
    public var category: Category
    public var severity: Severity
    public var title: String
    public var body: String
    public var thresholdKey: String
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        appID: UUID? = nil,
        category: Category,
        severity: Severity,
        title: String,
        body: String,
        thresholdKey: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.appID = appID
        self.category = category
        self.severity = severity
        self.title = title
        self.body = body
        self.thresholdKey = thresholdKey
        self.createdAt = createdAt
    }
}

public protocol NotificationDelivering: Sendable {
    func deliver(_ alert: SyncAlert) async
}

public struct NoOpNotificationDeliverer: NotificationDelivering, Sendable {
    public init() {}

    public func deliver(_ alert: SyncAlert) async {}
}

public struct ConsoleNotificationDeliverer: NotificationDelivering, Sendable {
    public init() {}

    public func deliver(_ alert: SyncAlert) async {
        let line = "[AppleSync][\(alert.severity.rawValue.uppercased())][\(alert.category.rawValue)] \(alert.title): \(alert.body)\n"
        if let data = line.data(using: .utf8) {
            try? FileHandle.standardError.write(contentsOf: data)
        }
    }
}

public actor RecordingNotificationDeliverer: NotificationDelivering {
    private var recorded: [SyncAlert] = []

    public init() {}

    public func deliver(_ alert: SyncAlert) async {
        recorded.append(alert)
    }

    public func alerts() -> [SyncAlert] {
        recorded
    }

    public func clear() {
        recorded.removeAll()
    }
}
