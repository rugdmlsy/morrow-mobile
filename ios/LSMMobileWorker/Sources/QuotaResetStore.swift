import Combine
import Foundation
import UserNotifications

enum QuotaType: String, Codable, CaseIterable {
    case fiveHours = "5h"
    case oneWeek = "1w"
    case custom = "custom"

    var title: String {
        switch self {
        case .fiveHours: return "5小时短期额度"
        case .oneWeek: return "1周长期总额度"
        case .custom: return "自定义额度"
        }
    }

    var shortTag: String {
        switch self {
        case .fiveHours: return "5h"
        case .oneWeek: return "1 week"
        case .custom: return "自定义"
        }
    }

    var defaultDuration: TimeInterval {
        switch self {
        case .fiveHours: return 5 * 3600
        case .oneWeek: return 7 * 24 * 3600
        case .custom: return 3600
        }
    }

    var icon: String {
        switch self {
        case .fiveHours: return "bolt.hourglass.bottomhalf.fill"
        case .oneWeek: return "calendar.badge.clock"
        case .custom: return "timer"
        }
    }
}

struct QuotaReminder: Identifiable, Codable, Equatable {
    let id: String
    let account: String
    let type: QuotaType
    let startDate: Date
    let targetDate: Date
    var note: String?
    var notified: Bool

    var isActive: Bool {
        Date() < targetDate
    }

    var totalDuration: TimeInterval {
        max(1.0, targetDate.timeIntervalSince(startDate))
    }

    var timeRemaining: TimeInterval {
        max(0.0, targetDate.timeIntervalSince(Date()))
    }

    var progress: Double {
        let elapsed = Date().timeIntervalSince(startDate)
        return min(1.0, max(0.0, elapsed / totalDuration))
    }

    var formattedRemaining: String {
        let remaining = timeRemaining
        if remaining <= 0 {
            return "已重置"
        }
        let totalSeconds = Int(remaining)
        let days = totalSeconds / 86400
        let hours = (totalSeconds % 86400) / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60

        if days > 0 {
            return "\(days)天 \(hours)小时 \(minutes)分"
        } else if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%02d:%02d", minutes, seconds)
        }
    }

    var formattedTargetTime: String {
        let formatter = DateFormatter()
        let calendar = Calendar.current
        if calendar.isDateInToday(targetDate) {
            formatter.dateFormat = "今日 HH:mm:ss"
        } else if calendar.isDateInTomorrow(targetDate) {
            formatter.dateFormat = "明日 HH:mm:ss"
        } else {
            formatter.dateFormat = "M月d日 HH:mm"
        }
        return formatter.string(from: targetDate)
    }
}

@MainActor
final class QuotaResetStore: ObservableObject {
    static let shared = QuotaResetStore()
    private static let key = "mobile.quota.reminders.v1"

    @Published private(set) var reminders: [QuotaReminder] = []
    @Published private(set) var notificationAuthorized: Bool = false

    private var timer: Timer?

    private init() {
        load()
        checkNotificationStatus()
        startPeriodicTimer()
    }

    deinit {
        timer?.invalidate()
    }

    var activeReminders: [QuotaReminder] {
        reminders.filter { $0.isActive }.sorted { $0.targetDate < $1.targetDate }
    }

    var completedReminders: [QuotaReminder] {
        reminders.filter { !$0.isActive }.sorted { $0.targetDate > $1.targetDate }
    }

    func checkNotificationStatus() {
        Task {
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            await MainActor.run {
                self.notificationAuthorized = (settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional)
            }
        }
    }

    func requestNotificationPermission() async -> Bool {
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])
            await MainActor.run {
                self.notificationAuthorized = granted
            }
            return granted
        } catch {
            return false
        }
    }

    @discardableResult
    func scheduleReminder(
        account: String,
        type: QuotaType,
        customDuration: TimeInterval? = nil,
        note: String? = nil
    ) async -> QuotaReminder {
        let duration = customDuration ?? type.defaultDuration
        let start = Date()
        let target = start.addingTimeInterval(duration)
        let id = UUID().uuidString

        let cleanAccount = account.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedAccount = cleanAccount.isEmpty ? "antigravity-0" : cleanAccount

        // Remove any existing active reminder of the same type for the same account
        reminders.removeAll { $0.account.lowercased() == resolvedAccount.lowercased() && $0.type == type && $0.isActive }

        let reminder = QuotaReminder(
            id: id,
            account: resolvedAccount,
            type: type,
            startDate: start,
            targetDate: target,
            note: note,
            notified: false
        )

        reminders.insert(reminder, at: 0)
        save()

        await postScheduledNotification(for: reminder)
        checkNotificationStatus()
        return reminder
    }

    func cancelReminder(id: String) {
        if let idx = reminders.firstIndex(where: { $0.id == id }) {
            let reminder = reminders[idx]
            reminders.remove(at: idx)
            save()

            let identifier = "quota-reset-\(reminder.id)"
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [identifier])
        }
    }

    func clearHistory() {
        reminders.removeAll { !$0.isActive }
        save()
    }

    func triggerTestNotification() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        if settings.authorizationStatus != .authorized && settings.authorizationStatus != .provisional {
            _ = await requestNotificationPermission()
        }

        let content = UNMutableNotificationContent()
        content.title = "🎉 额度已恢复 (测试)"
        content.body = "测试通知成功！额度重置提醒通道已准备就绪，到期时将准时提醒。"
        content.sound = .default

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 2.0, repeats: false)
        let request = UNNotificationRequest(identifier: "quota-test-\(UUID().uuidString)", content: content, trigger: trigger)
        try? await center.add(request)
    }

    func refreshState() {
        checkExpiredNotifications()
        objectWillChange.send()
    }

    private func startPeriodicTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                if self.reminders.contains(where: { $0.isActive }) {
                    self.objectWillChange.send()
                }
            }
        }
    }

    private func postScheduledNotification(for reminder: QuotaReminder) async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        if settings.authorizationStatus != .authorized && settings.authorizationStatus != .provisional {
            _ = try? await center.requestAuthorization(options: [.alert, .badge, .sound])
        }

        let content = UNMutableNotificationContent()
        content.title = "🎉 额度已重置 (\(reminder.type.shortTag))"
        content.body = "Agent [\(reminder.account)] 的 \(reminder.type.title) 已经重置完毕，现在可以继续向 Agent 发送任务了！"
        content.sound = .default
        if #available(iOS 15.0, *) {
            content.interruptionLevel = .timeSensitive
        }

        let duration = max(1.0, reminder.targetDate.timeIntervalSince(Date()))
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: duration, repeats: false)
        let request = UNNotificationRequest(
            identifier: "quota-reset-\(reminder.id)",
            content: content,
            trigger: trigger
        )
        try? await center.add(request)
    }

    private func checkExpiredNotifications() {
        var changed = false
        for i in 0..<reminders.count {
            if !reminders[i].isActive && !reminders[i].notified {
                reminders[i].notified = true
                changed = true
            }
        }
        if changed {
            save()
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.key),
              let decoded = try? JSONDecoder().decode([QuotaReminder].self, from: data) else {
            return
        }
        // Retain active reminders and up to 30 history items
        let active = decoded.filter { $0.isActive }
        let history = decoded.filter { !$0.isActive }.prefix(30)
        reminders = active + history
    }

    private func save() {
        if let data = try? JSONEncoder().encode(reminders) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}
