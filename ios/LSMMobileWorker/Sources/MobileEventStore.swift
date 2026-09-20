import Combine
import Foundation
import UserNotifications

struct MobileControllerEvent: Identifiable, Codable, Equatable {
    let id: String
    let type: String
    let title: String
    let body: String
    let createdAt: Date
}

@MainActor
final class MobileEventStore: ObservableObject {
    static let shared = MobileEventStore()
    private static let key = "mobile.controller.events.v1"
    private static let retentionInterval: TimeInterval = 24 * 60 * 60
    private let maxItems = 100

    @Published private(set) var items: [MobileControllerEvent] = []

    private init() {
        // Clean up legacy LSM event notifications from system notification center
        UNUserNotificationCenter.current().getPendingNotificationRequests { requests in
            let legacyIds = requests.map(\.identifier).filter { $0.hasPrefix("lsm-event-") }
            if !legacyIds.isEmpty {
                UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: legacyIds)
            }
        }
    }

    func process(_ rows: [[String: Any]]) async -> [String] {
        var ack: [String] = []
        for row in rows {
            guard let id = row["id"] as? String, !id.isEmpty else { continue }
            ack.append(id)

            let type = (row["type"] as? String) ?? "event"

            // Route mobile inbox deliveries directly to MobileInboxStore
            if type == "mobile_delivery", let data = row["data"] as? [String: Any] {
                _ = try? MobileInboxStore.shared.receive(data, id: id)
            }

            // LSM job completion notifications (job_completed) and controller events
            // have been disabled per user requirement. No local notifications are posted.
        }
        return ack
    }

    func clear() {
        items = []
    }

    @discardableResult
    func pruneExpired(now: Date = Date()) -> Int {
        return 0
    }
}
