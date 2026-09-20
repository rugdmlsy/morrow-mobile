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
    var isAutoDetected: Bool
    var sourceSessionId: String?
    var sourceSessionTitle: String?
    var triggerSnippet: String?

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

    var formattedStartTime: String {
        let formatter = DateFormatter()
        let calendar = Calendar.current
        if calendar.isDateInToday(startDate) {
            formatter.dateFormat = "今日 HH:mm:ss"
        } else {
            formatter.dateFormat = "M月d日 HH:mm"
        }
        return formatter.string(from: startDate)
    }
}

@MainActor
final class QuotaResetStore: ObservableObject {
    static let shared = QuotaResetStore()
    private static let key = "mobile.quota.reminders.v1"

    @Published private(set) var reminders: [QuotaReminder] = []
    @Published private(set) var notificationAuthorized: Bool = false
    @Published private(set) var lastScanTime: Date? = nil
    @Published private(set) var scannedSessionsCount: Int = 0

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

    // MARK: - Auto-Detection from Conversation Records (对话记录自动读取)

    func scanAndSyncFromChatStore() {
        let chatStore = MobileChatStore.shared
        scanAndSyncFromConversations(
            messagesBySession: chatStore.messagesBySession,
            sessions: chatStore.sessions,
            currentAccount: chatStore.currentAccount
        )
    }

    func scanAndSyncFromConversations(
        messagesBySession: [String: [ChatMessageItem]],
        sessions: [ChatSessionItem],
        currentAccount: String
    ) {
        lastScanTime = Date()
        scannedSessionsCount = sessions.count

        var sessionTitles: [String: String] = [:]
        for s in sessions {
            sessionTitles[s.id] = s.title
        }

        var detectedList: [QuotaReminder] = []

        for (sessionId, messages) in messagesBySession {
            let sessionTitle = sessionTitles[sessionId] ?? "对话 \(sessionId.prefix(6))"

            for message in messages {
                // Inspect agent or error messages
                guard message.sender != "user" else { continue }

                if let reminder = parseQuotaFromMessage(
                    content: message.content,
                    createdAt: message.createdAt,
                    account: currentAccount,
                    sessionId: sessionId,
                    sessionTitle: sessionTitle
                ) {
                    detectedList.append(reminder)
                }
            }
        }

        // Keep the latest detected record for each quota type (5h and 1w)
        for type in [QuotaType.fiveHours, QuotaType.oneWeek] {
            let matching = detectedList.filter { $0.type == type }.sorted { $0.targetDate > $1.targetDate }
            guard let latest = matching.first else { continue }

            if latest.isActive {
                let existingIdx = reminders.firstIndex(where: {
                    $0.account.lowercased() == latest.account.lowercased() &&
                    $0.type == latest.type &&
                    $0.isActive
                })

                if let existingIdx {
                    // Update if from newer message or different target
                    if abs(reminders[existingIdx].targetDate.timeIntervalSince(latest.targetDate)) > 60 {
                        reminders[existingIdx] = latest
                        save()
                        Task { await postScheduledNotification(for: latest) }
                    }
                } else {
                    reminders.insert(latest, at: 0)
                    save()
                    Task { await postScheduledNotification(for: latest) }
                }
            } else {
                // Expired: record in history if not present
                if !reminders.contains(where: { $0.id == latest.id }) {
                    var finished = latest
                    finished.notified = true
                    reminders.append(finished)
                    save()
                }
            }
        }

        checkExpiredNotifications()
        objectWillChange.send()
    }

    private func parseQuotaFromMessage(
        content: String,
        createdAt: Date,
        account: String,
        sessionId: String,
        sessionTitle: String
    ) -> QuotaReminder? {
        let lower = content.lowercased()

        let keywords = [
            "429",
            "quota",
            "rate limit",
            "rate-limit",
            "rate_limit",
            "resource_exhausted",
            "resourceexhausted",
            "usage limit",
            "usage cap",
            "too many requests",
            "out of messages",
            "额度已用尽",
            "额度耗尽",
            "配额耗尽",
            "频率超限",
            "频率限制",
            "额度受限",
            "配额已用完",
            "达到上限",
            "达到额度上限"
        ]

        guard keywords.contains(where: { lower.contains($0) }) else {
            return nil
        }

        // Determine if weekly quota
        let isWeekly = lower.contains("week") ||
                       lower.contains("weekly") ||
                       lower.contains("7 day") ||
                       lower.contains("周配额") ||
                       lower.contains("周额度") ||
                       lower.contains("周上限") ||
                       lower.contains("1周") ||
                       lower.contains("1w")

        let type: QuotaType = isWeekly ? .oneWeek : .fiveHours
        var duration: TimeInterval = type.defaultDuration // 5h (18000s) or 7d (604800s)

        // Try extracting explicit cooldown hours if present (e.g. "resets in 4 hours", "3.5小时后重置")
        if let hMatch = extractRegex(pattern: #"(?:resets?\s+(?:in|after)|重置时间(?:为|还有)?|请等待)\s*(\d+(?:\.\d+)?)\s*(?:hours?|h|hrs?|小时)"#, in: content),
           let h = Double(hMatch) {
            duration = h * 3600
        } else if let mMatch = extractRegex(pattern: #"(?:resets?\s+(?:in|after)|重置时间(?:为|还有)?|请等待)\s*(\d+(?:\.\d+)?)\s*(?:minutes?|m|mins?|分钟)"#, in: content),
                  let m = Double(mMatch) {
            duration = m * 60
        }

        let targetDate = createdAt.addingTimeInterval(duration)
        let snippet = String(content.prefix(100)).replacingOccurrences(of: "\n", with: " ")
        let cleanAccount = account.isEmpty ? "antigravity-0" : account

        return QuotaReminder(
            id: "auto-\(cleanAccount)-\(type.rawValue)-\(Int(createdAt.timeIntervalSince1970))",
            account: cleanAccount,
            type: type,
            startDate: createdAt,
            targetDate: targetDate,
            note: "自动读取自《\(sessionTitle)》",
            notified: targetDate <= Date(),
            isAutoDetected: true,
            sourceSessionId: sessionId,
            sourceSessionTitle: sessionTitle,
            triggerSnippet: snippet
        )
    }

    private func extractRegex(pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[range])
    }

    // MARK: - Notifications & Management

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
        note: String? = nil,
        isAutoDetected: Bool = false
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
            notified: false,
            isAutoDetected: isAutoDetected,
            sourceSessionId: nil,
            sourceSessionTitle: nil,
            triggerSnippet: nil
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
        scanAndSyncFromChatStore()
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
