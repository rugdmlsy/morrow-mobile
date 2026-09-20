import Foundation
import SwiftUI
import Combine

/// A chat project grouping item representing a project container / forum (Telegram style).
struct ChatProjectItem: Identifiable, Codable, Equatable, Hashable {
    let id: String
    var name: String
    var icon: String
    var count: Int
    var latestSnippet: String
    var latestTime: Date

    init(
        id: String,
        name: String,
        icon: String = "💬",
        count: Int = 0,
        latestSnippet: String = "",
        latestTime: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.icon = icon
        self.count = count
        self.latestSnippet = latestSnippet
        self.latestTime = latestTime
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: ChatProjectItem, rhs: ChatProjectItem) -> Bool {
        lhs.id == rhs.id &&
        lhs.name == rhs.name &&
        lhs.icon == rhs.icon &&
        lhs.count == rhs.count &&
        lhs.latestSnippet == rhs.latestSnippet
    }
}

/// A chat session item representing an independent conversation thread / topic (Telegram style).
struct ChatSessionItem: Identifiable, Codable, Equatable, Hashable {
    let id: String
    var title: String
    var projectId: String
    var projectName: String
    var icon: String
    var createdAt: Date
    var lastModifiedAt: Date
    var lastMessageSnippet: String
    var isPinned: Bool
    var msgCount: Int

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case projectId = "project_id"
        case projectName = "project_name"
        case icon
        case createdAt = "created_at"
        case lastModifiedAt = "last_modified_at"
        case lastMessageSnippet = "last_message_snippet"
        case isPinned = "is_pinned"
        case msgCount = "msg_count"
    }

    init(
        id: String = "sess_\(UUID().uuidString.prefix(8).lowercased())",
        title: String = "新对话",
        projectId: String = "outside-of-project",
        projectName: String = "Outside of Project",
        icon: String = "💬",
        createdAt: Date = Date(),
        lastModifiedAt: Date = Date(),
        lastMessageSnippet: String = "",
        isPinned: Bool = false,
        msgCount: Int = 0
    ) {
        self.id = id
        self.title = title
        self.projectId = projectId
        self.projectName = projectName
        self.icon = icon
        self.createdAt = createdAt
        self.lastModifiedAt = lastModifiedAt
        self.lastMessageSnippet = lastMessageSnippet
        self.isPinned = isPinned
        self.msgCount = msgCount
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "新对话"
        projectId = try c.decodeIfPresent(String.self, forKey: .projectId) ?? "outside-of-project"
        projectName = try c.decodeIfPresent(String.self, forKey: .projectName) ?? "Outside of Project"
        icon = try c.decodeIfPresent(String.self, forKey: .icon) ?? "💬"
        isPinned = try c.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        msgCount = try c.decodeIfPresent(Int.self, forKey: .msgCount) ?? 0
        lastMessageSnippet = try c.decodeIfPresent(String.self, forKey: .lastMessageSnippet) ?? ""

        if let epoch = try? c.decode(Double.self, forKey: .createdAt) {
            createdAt = Date(timeIntervalSince1970: epoch)
        } else {
            createdAt = Date()
        }

        if let epoch = try? c.decode(Double.self, forKey: .lastModifiedAt) {
            lastModifiedAt = Date(timeIntervalSince1970: epoch)
        } else {
            lastModifiedAt = Date()
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(projectId, forKey: .projectId)
        try c.encode(projectName, forKey: .projectName)
        try c.encode(icon, forKey: .icon)
        try c.encode(isPinned, forKey: .isPinned)
        try c.encode(msgCount, forKey: .msgCount)
        try c.encode(lastMessageSnippet, forKey: .lastMessageSnippet)
        try c.encode(createdAt.timeIntervalSince1970, forKey: .createdAt)
        try c.encode(lastModifiedAt.timeIntervalSince1970, forKey: .lastModifiedAt)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: ChatSessionItem, rhs: ChatSessionItem) -> Bool {
        lhs.id == rhs.id &&
        lhs.title == rhs.title &&
        lhs.projectId == rhs.projectId &&
        lhs.projectName == rhs.projectName &&
        lhs.lastModifiedAt == rhs.lastModifiedAt &&
        lhs.lastMessageSnippet == rhs.lastMessageSnippet &&
        lhs.isPinned == rhs.isPinned &&
        lhs.msgCount == rhs.msgCount
    }
}

/// A chat message exchanged in AMARP (Asynchronous Mobile-Agent Relay Protocol).
struct ChatMessageItem: Identifiable, Codable, Equatable {
    let id: String
    let sessionId: String
    let seq: Int
    let replyTo: String?
    let sender: String        // "user" or "agent"
    let type: String          // "text", "thought", "tool_call", "tool_result", "status"
    var status: String        // "pending", "running", "completed", "failed"
    let content: String
    let toolName: String?
    let toolOutput: String?
    let createdAt: Date
    var tokens: Int?
    var duration: Double?

    enum CodingKeys: String, CodingKey {
        case id
        case sessionId = "session_id"
        case seq
        case replyTo = "reply_to"
        case sender
        case type
        case status
        case content
        case toolInfo = "tool_info"
        case createdAt = "created_at"
        case tokens
        case tokenCount = "token_count"
        case duration
        case elapsedSeconds = "elapsed_seconds"
    }

    init(
        id: String = "msg_\(UUID().uuidString.prefix(12).lowercased())",
        sessionId: String = "default",
        seq: Int = 0,
        replyTo: String? = nil,
        sender: String = "user",
        type: String = "text",
        status: String = "completed",
        content: String = "",
        toolName: String? = nil,
        toolOutput: String? = nil,
        createdAt: Date = Date(),
        tokens: Int? = nil,
        duration: Double? = nil
    ) {
        self.id = id
        self.sessionId = sessionId
        self.seq = seq
        self.replyTo = replyTo
        self.sender = sender
        self.type = type
        self.status = status
        self.content = content
        self.toolName = toolName
        self.toolOutput = toolOutput
        self.createdAt = createdAt
        self.tokens = tokens
        self.duration = duration
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        sessionId = try container.decodeIfPresent(String.self, forKey: .sessionId) ?? "default"
        seq = try container.decodeIfPresent(Int.self, forKey: .seq) ?? 0
        replyTo = try container.decodeIfPresent(String.self, forKey: .replyTo)
        sender = try container.decodeIfPresent(String.self, forKey: .sender) ?? "user"
        type = try container.decodeIfPresent(String.self, forKey: .type) ?? "text"
        status = try container.decodeIfPresent(String.self, forKey: .status) ?? "completed"
        content = try container.decodeIfPresent(String.self, forKey: .content) ?? ""

        if let epoch = try? container.decode(Double.self, forKey: .createdAt) {
            createdAt = Date(timeIntervalSince1970: epoch)
        } else if let dateStr = try? container.decode(String.self, forKey: .createdAt) {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            createdAt = formatter.date(from: dateStr) ?? ISO8601DateFormatter().date(from: dateStr) ?? Date()
        } else {
            createdAt = Date()
        }

        if let info = try? container.decode([String: String].self, forKey: .toolInfo) {
            toolName = info["name"]
            toolOutput = info["output"]
        } else {
            toolName = nil
            toolOutput = nil
        }

        tokens = (try? container.decodeIfPresent(Int.self, forKey: .tokens))
            ?? (try? container.decodeIfPresent(Int.self, forKey: .tokenCount))
        duration = (try? container.decodeIfPresent(Double.self, forKey: .duration))
            ?? (try? container.decodeIfPresent(Double.self, forKey: .elapsedSeconds))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encode(seq, forKey: .seq)
        try container.encodeIfPresent(replyTo, forKey: .replyTo)
        try container.encode(sender, forKey: .sender)
        try container.encode(type, forKey: .type)
        try container.encode(status, forKey: .status)
        try container.encode(content, forKey: .content)
        try container.encode(createdAt.timeIntervalSince1970, forKey: .createdAt)
        try container.encodeIfPresent(tokens, forKey: .tokens)
        try container.encodeIfPresent(duration, forKey: .duration)
        if let name = toolName {
            var info: [String: String] = ["name": name]
            if let output = toolOutput { info["output"] = output }
            try container.encode(info, forKey: .toolInfo)
        }
    }

    var displayDuration: Double? {
        if let duration = duration, duration > 0 {
            return duration
        }
        return nil
    }
}

@MainActor
final class MobileChatStore: ObservableObject {
    static let shared = MobileChatStore()

    @Published var projects: [ChatProjectItem] = []
    @Published var sessions: [ChatSessionItem] = []
    @Published var selectedSessionId: String = "default"
    @Published var messagesBySession: [String: [ChatMessageItem]] = [:]
    @Published var typingBySession: [String: Bool] = [:]
    @Published var errorMessage: String? = nil

    // Backward-compatibility properties
    var messages: [ChatMessageItem] {
        messagesBySession[selectedSessionId] ?? []
    }
    var currentSessionId: String {
        get { selectedSessionId }
        set { selectedSessionId = newValue }
    }
    var isAgentTyping: Bool {
        typingBySession[selectedSessionId] ?? false
    }

    @Published var currentAccount: String = "antigravity-0"

    private let baseChatDir: URL
    private var currentAccountKey: String = "default"
    private var chatDir: URL {
        baseChatDir.appendingPathComponent(currentAccountKey, isDirectory: true)
    }
    private var sessionsURL: URL {
        chatDir.appendingPathComponent("sessions.json")
    }
    private var projectsURL: URL {
        chatDir.appendingPathComponent("projects.json")
    }
    private let legacyFileURL: URL
    private var syncTimer: AnyCancellable?

    private static func accountKey(for accountName: String?, token: String?) -> String {
        let name = (accountName ?? "").filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        if !name.isEmpty {
            return name.lowercased()
        }
        guard let token, !token.isEmpty else { return "default" }
        let clean = token.filter { $0.isLetter || $0.isNumber }
        if clean.isEmpty { return "default" }
        return "acc_\(clean.prefix(16).lowercased())"
    }

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        self.baseChatDir = docs.appendingPathComponent("LSM/Chat", isDirectory: true)
        try? FileManager.default.createDirectory(at: baseChatDir, withIntermediateDirectories: true)
        self.legacyFileURL = baseChatDir.appendingPathComponent("chat_history.json")

        if let data = try? KeychainStore.load(),
           let id = try? JSONDecoder().decode(WorkerIdentity.self, from: data) {
            let clean = (id.name.isEmpty || id.name == "morrow-iphone" || id.name == "default") ? "antigravity-0" : id.name
            self.currentAccount = clean
            self.currentAccountKey = Self.accountKey(for: clean, token: id.token)
        } else {
            self.currentAccount = "antigravity-0"
            self.currentAccountKey = "antigravity-0"
        }
        try? FileManager.default.createDirectory(at: chatDir, withIntermediateDirectories: true)
        migrateLegacyChatFilesIfNeeded()

        loadLocalHistory()
    }

    private func migrateLegacyChatFilesIfNeeded() {
        let legacySessions = baseChatDir.appendingPathComponent("sessions.json")
        let legacyProjects = baseChatDir.appendingPathComponent("projects.json")
        if FileManager.default.fileExists(atPath: legacySessions.path) && !FileManager.default.fileExists(atPath: sessionsURL.path) {
            try? FileManager.default.copyItem(at: legacySessions, to: sessionsURL)
            if FileManager.default.fileExists(atPath: legacyProjects.path) {
                try? FileManager.default.copyItem(at: legacyProjects, to: projectsURL)
            }
            if let files = try? FileManager.default.contentsOfDirectory(at: baseChatDir, includingPropertiesForKeys: nil) {
                for file in files where file.lastPathComponent.hasPrefix("messages_") {
                    let dest = chatDir.appendingPathComponent(file.lastPathComponent)
                    if !FileManager.default.fileExists(atPath: dest.path) {
                        try? FileManager.default.copyItem(at: file, to: dest)
                    }
                }
            }
        }

        // Migrate from acc_lsmcpwkugvviwrhx for antigravity-1 if it exists
        let altAccDir = baseChatDir.appendingPathComponent("acc_lsmcpwkugvviwrhx")
        if currentAccountKey == "antigravity-1" && !FileManager.default.fileExists(atPath: sessionsURL.path) && FileManager.default.fileExists(atPath: altAccDir.appendingPathComponent("sessions.json").path) {
            try? FileManager.default.copyItem(at: altAccDir.appendingPathComponent("sessions.json"), to: sessionsURL)
            if FileManager.default.fileExists(atPath: altAccDir.appendingPathComponent("projects.json").path) {
                try? FileManager.default.copyItem(at: altAccDir.appendingPathComponent("projects.json"), to: projectsURL)
            }
            if let files = try? FileManager.default.contentsOfDirectory(at: altAccDir, includingPropertiesForKeys: nil) {
                for file in files where file.lastPathComponent.hasPrefix("messages_") {
                    let dest = chatDir.appendingPathComponent(file.lastPathComponent)
                    if !FileManager.default.fileExists(atPath: dest.path) {
                        try? FileManager.default.copyItem(at: file, to: dest)
                    }
                }
            }
        }
    }

    func switchAccount(server: String, token: String?, account: String? = nil) {
        // 1. Flush existing state to old URLs synchronously before switching
        let oldProjects = projects
        let oldProjectsURL = projectsURL
        if !oldProjects.isEmpty, let data = try? JSONEncoder().encode(oldProjects) {
            try? data.write(to: oldProjectsURL, options: .atomic)
        }
        let oldSessions = sessions
        let oldSessionsURL = sessionsURL
        if !oldSessions.isEmpty, let data = try? JSONEncoder().encode(oldSessions) {
            try? data.write(to: oldSessionsURL, options: .atomic)
        }

        let acctName = account ?? (currentAccount.isEmpty ? "antigravity-0" : currentAccount)
        let cleanAcct = (acctName == "morrow-iphone" || acctName.isEmpty || acctName == "default") ? "antigravity-0" : acctName
        self.currentAccount = cleanAcct
        self.currentAccountKey = Self.accountKey(for: cleanAcct, token: token)
        try? FileManager.default.createDirectory(at: chatDir, withIntermediateDirectories: true)
        migrateLegacyChatFilesIfNeeded()

        self.projects = []
        self.sessions = []
        self.messagesBySession = [:]
        self.typingBySession = [:]
        self.selectedSessionId = "default"

        loadLocalHistory()

        startPolling(server: server, token: token)
        Task {
            await sync(server: server, token: token)
        }
    }

    // MARK: - Query Helpers

    func messages(for sessionId: String) -> [ChatMessageItem] {
        messagesBySession[sessionId] ?? []
    }

    func isAgentTyping(for sessionId: String) -> Bool {
        typingBySession[sessionId] ?? false
    }

    func session(for id: String) -> ChatSessionItem? {
        sessions.first(where: { $0.id == id })
    }

    // MARK: - Session Management (Telegram Style)

    @discardableResult
    func createSession(
        title: String? = nil,
        projectId: String = "outside-of-project",
        projectName: String = "Outside of Project"
    ) -> ChatSessionItem {
        let uniqueId = "sess_\(UUID().uuidString.prefix(8).lowercased())"
        let icon: String
        if projectId == "outside-of-project" {
            icon = "📁"
        } else if projectId == "default-cli-project" {
            icon = "⌨️"
        } else {
            icon = "🛠️"
        }
        let newSession = ChatSessionItem(
            id: uniqueId,
            title: title ?? "新对话",
            projectId: projectId,
            projectName: projectName,
            icon: icon,
            createdAt: Date(),
            lastModifiedAt: Date(),
            lastMessageSnippet: "",
            isPinned: false,
            msgCount: 0
        )
        sessions.insert(newSession, at: 0)
        messagesBySession[uniqueId] = []
        selectedSessionId = uniqueId
        sortSessions()
        saveSessions()
        saveMessages(for: uniqueId)
        updateLocalProjectCounts()
        return newSession
    }

    func createProject(name: String, icon: String = "📁") -> ChatProjectItem {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = "proj_\(UUID().uuidString.prefix(8).lowercased())"
        let proj = ChatProjectItem(id: id, name: clean.isEmpty ? "新项目" : clean, icon: icon, count: 0)
        if !projects.contains(where: { $0.id == id }) {
            projects.insert(proj, at: 0)
            saveProjects()
        }
        return proj
    }

    func deleteProject(id: String, server: String? = nil, token: String? = nil) {
        let toDelete = sessions.filter { $0.projectId == id }
        for s in toDelete {
            deleteSession(id: s.id, server: server, token: token)
        }
        projects.removeAll(where: { $0.id == id })
        saveProjects()
        updateLocalProjectCounts()
    }

    func deleteSession(id: String, server: String? = nil, token: String? = nil) {
        sessions.removeAll(where: { $0.id == id })
        messagesBySession.removeValue(forKey: id)
        typingBySession.removeValue(forKey: id)
        try? FileManager.default.removeItem(at: sessionMessagesURL(for: id))

        if sessions.isEmpty {
            let fallback = ChatSessionItem(id: "default", title: "默认对话", projectId: "outside-of-project", projectName: "Outside of Project")
            sessions = [fallback]
            messagesBySession[fallback.id] = []
            saveMessages(for: fallback.id)
        }

        if selectedSessionId == id {
            selectedSessionId = sessions.first?.id ?? "default"
        }
        sortSessions()
        saveSessions()
        updateLocalProjectCounts()

        if let srv = server {
            Task {
                _ = try? await post(server: srv, path: "/api/chat/delete-conversation", payload: ["id": id, "account": currentAccount], token: token)
            }
        }
    }

    func renameSession(id: String, newTitle: String) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let idx = sessions.firstIndex(where: { $0.id == id }) {
            sessions[idx].title = trimmed
            saveSessions()
        }
    }

    func togglePin(id: String) {
        if let idx = sessions.firstIndex(where: { $0.id == id }) {
            sessions[idx].isPinned.toggle()
            sortSessions()
            saveSessions()
        }
    }

    func clearHistory(sessionId: String) {
        messagesBySession[sessionId] = []
        if let idx = sessions.firstIndex(where: { $0.id == sessionId }) {
            sessions[idx].lastMessageSnippet = ""
            sessions[idx].lastModifiedAt = Date()
        }
        try? FileManager.default.removeItem(at: sessionMessagesURL(for: sessionId))
        saveSessions()
    }

    func clearHistory() {
        clearHistory(sessionId: selectedSessionId)
    }

    private func sortSessions() {
        sessions.sort { lhs, rhs in
            if lhs.isPinned != rhs.isPinned {
                return lhs.isPinned && !rhs.isPinned
            }
            return lhs.lastModifiedAt > rhs.lastModifiedAt
        }
    }

    // MARK: - Polling & Network

    func startPolling(server: String, token: String?) {
        syncTimer?.cancel()
        // Responsive timer (2.5s) polling outbox for agent replies without UI jitter
        syncTimer = Timer.publish(every: 2.5, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                Task {
                    await self?.syncOutbox(server: server, token: token)
                }
            }
    }

    func stopPolling() {
        syncTimer?.cancel()
        syncTimer = nil
    }

    func sendMessage(content: String, sessionId: String? = nil, server: String, token: String?) async {
        let targetSessionId = sessionId ?? selectedSessionId
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let userMsg = ChatMessageItem(
            sessionId: targetSessionId,
            sender: "user",
            type: "text",
            status: "pending",
            content: trimmed
        )

        var list = messagesBySession[targetSessionId] ?? []
        list.append(userMsg)
        messagesBySession[targetSessionId] = list
        saveMessages(for: targetSessionId)

        typingBySession[targetSessionId] = true
        errorMessage = nil

        // Auto-title session if still named "新会话"
        if let sIdx = sessions.firstIndex(where: { $0.id == targetSessionId }) {
            if sessions[sIdx].title == "新会话" || sessions[sIdx].title.isEmpty {
                let clean = trimmed.replacingOccurrences(of: "\n", with: " ")
                sessions[sIdx].title = String(clean.prefix(20)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            sessions[sIdx].lastMessageSnippet = "我: \(trimmed)"
            sessions[sIdx].lastModifiedAt = Date()
            sortSessions()
            saveSessions()
        }

        let currentSession = sessions.first(where: { $0.id == targetSessionId })
        let payload: [String: Any] = [
            "id": userMsg.id,
            "account": currentAccount,
            "session_id": targetSessionId,
            "project_id": currentSession?.projectId ?? "outside-of-project",
            "project_name": currentSession?.projectName ?? "Outside of Project",
            "sender": "user",
            "type": "text",
            "status": "completed",
            "content": trimmed,
            "created_at": Date().timeIntervalSince1970,
        ]

        do {
            _ = try await post(server: server, path: "/api/chat/send", payload: payload, token: token)
            if var currentList = messagesBySession[targetSessionId],
               let idx = currentList.firstIndex(where: { $0.id == userMsg.id }) {
                currentList[idx].status = "completed"
                messagesBySession[targetSessionId] = currentList
                saveMessages(for: targetSessionId)
            }
            // Trigger immediate outbox sync for response
            await syncOutbox(server: server, token: token)
        } catch {
            errorMessage = "发送失败: \(error.localizedDescription)"
            if var currentList = messagesBySession[targetSessionId],
               let idx = currentList.firstIndex(where: { $0.id == userMsg.id }) {
                currentList[idx].status = "failed"
                messagesBySession[targetSessionId] = currentList
                saveMessages(for: targetSessionId)
            }
            typingBySession[targetSessionId] = false
        }
    }

    func sync(server: String, token: String?) async {
        await fetchProjectConversations(server: server, token: token)
        await syncOutbox(server: server, token: token)
    }

    func syncOutbox(server: String, token: String?) async {
        do {
            let data = try await post(server: server, path: "/api/chat/sync-outbox", payload: ["account": currentAccount], token: token)
            guard let rawMessages = data["messages"] as? [[String: Any]], !rawMessages.isEmpty else {
                return
            }

            var incomingIds: [String] = []
            var changedSessionIds: Set<String> = []

            for raw in rawMessages {
                if let jsonData = try? JSONSerialization.data(withJSONObject: raw),
                   let item = try? JSONDecoder().decode(ChatMessageItem.self, from: jsonData) {
                    incomingIds.append(item.id)
                    let sid = item.sessionId.isEmpty ? "default" : item.sessionId

                    // Ignore status notifications from becoming chat message bubbles; update typing indicator only
                    if item.type == "status" {
                        if item.status == "running" {
                            typingBySession[sid] = true
                        } else if item.status == "completed" || item.status == "failed" {
                            typingBySession[sid] = false
                        }
                        continue
                    }

                    var list = messagesBySession[sid] ?? []
                    if !list.contains(where: { $0.id == item.id }) {
                        var resolvedItem = item
                        if resolvedItem.duration == nil {
                            // Find corresponding user message to calculate elapsed duration
                            if let repId = resolvedItem.replyTo, let userMsg = list.first(where: { $0.id == repId }) {
                                let dur = resolvedItem.createdAt.timeIntervalSince(userMsg.createdAt)
                                if dur > 0 && dur < 3600 {
                                    resolvedItem.duration = dur
                                }
                            } else if let lastUser = list.last(where: { $0.sender == "user" }) {
                                let dur = resolvedItem.createdAt.timeIntervalSince(lastUser.createdAt)
                                if dur > 0 && dur < 3600 {
                                    resolvedItem.duration = dur
                                }
                            }
                        }

                        list.append(resolvedItem)
                        list.sort(by: { $0.createdAt < $1.createdAt })
                        messagesBySession[sid] = list
                        changedSessionIds.insert(sid)
                        typingBySession[sid] = false

                        // Update or auto-create session in session list
                        let snippet = item.content.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                        if let sIdx = sessions.firstIndex(where: { $0.id == sid }) {
                            sessions[sIdx].lastMessageSnippet = snippet
                            sessions[sIdx].lastModifiedAt = item.createdAt
                        } else {
                            let newSess = ChatSessionItem(
                                id: sid,
                                title: "对话 \(sid.prefix(6))",
                                projectId: "outside-of-project",
                                projectName: "Outside of Project",
                                createdAt: item.createdAt,
                                lastModifiedAt: item.createdAt,
                                lastMessageSnippet: snippet,
                                isPinned: false
                            )
                            sessions.append(newSess)
                        }
                    }
                }
            }

            if !changedSessionIds.isEmpty {
                for sid in changedSessionIds {
                    saveMessages(for: sid)
                }
                sortSessions()
                saveSessions()

                // Automatically scan conversation records for quota limits
                QuotaResetStore.shared.scanAndSyncFromConversations(
                    messagesBySession: self.messagesBySession,
                    sessions: self.sessions,
                    currentAccount: self.currentAccount
                )
            }

            // Immediately ACK to purge copies on VPS!
            if !incomingIds.isEmpty {
                _ = try? await post(server: server, path: "/api/chat/ack-outbox", payload: ["ids": incomingIds], token: token)
            }
        } catch {
            // Background sync error is non-fatal
        }
    }

    func fetchProjectConversations(server: String, token: String?) async {
        do {
            let data = try await post(server: server, path: "/api/chat/conversations", payload: ["account": currentAccount], token: token)

            // 0. Update Native Quotas if returned by relay
            if let rawQuotas = data["quotas"] as? [String: Any], !rawQuotas.isEmpty {
                QuotaResetStore.shared.updateFromRawQuotas(rawQuotas)
            }

            // 1. Parse projects
            if let rawProjects = data["projects"] as? [[String: Any]] {
                var loadedProjects: [ChatProjectItem] = []
                for p in rawProjects {
                    let id = p["id"] as? String ?? ""
                    let name = p["name"] as? String ?? ""
                    let icon = p["icon"] as? String ?? "💬"
                    let count = p["count"] as? Int ?? 0
                    if !id.isEmpty {
                        loadedProjects.append(ChatProjectItem(id: id, name: name, icon: icon, count: count))
                    }
                }
                if self.projects != loadedProjects {
                    self.projects = loadedProjects
                    saveProjects()
                }
            }

            // 2. Parse conversations
            if let rawConvs = data["conversations"] as? [[String: Any]] {
                var hasChanges = false
                for c in rawConvs {
                    guard let cid = c["id"] as? String, !cid.isEmpty else { continue }
                    let projId = c["project_id"] as? String ?? "outside-of-project"
                    let projName = c["project_name"] as? String ?? "Outside of Project"
                    let title = c["title"] as? String ?? "新对话"
                    let snippet = c["snippet"] as? String ?? ""
                    let msgCount = c["msg_count"] as? Int ?? 0
                    let lastEpoch = c["last_modified_at"] as? Double ?? Date().timeIntervalSince1970
                    let lastMod = Date(timeIntervalSince1970: lastEpoch)

                    // Parse messages if provided
                    if let rawMsgs = c["messages"] as? [[String: Any]], !rawMsgs.isEmpty {
                        var parsedMsgs: [ChatMessageItem] = []
                        var lastUserCreatedAt: Date? = nil
                        for m in rawMsgs {
                            let mid = m["id"] as? String ?? UUID().uuidString
                            let role = m["role"] as? String ?? "agent"
                            let content = m["content"] as? String ?? ""
                            var createdAt = Date()
                            if let ts = m["created_at"] as? Double {
                                createdAt = Date(timeIntervalSince1970: ts)
                            } else if let s = m["created_at"] as? String {
                                let f = ISO8601DateFormatter()
                                createdAt = f.date(from: s) ?? Date()
                            }
                            let isUserMsg = (role == "user")
                            var duration = m["duration"] as? Double
                            var tokens = m["tokens"] as? Int ?? m["token_count"] as? Int

                            if isUserMsg {
                                lastUserCreatedAt = createdAt
                            } else {
                                if duration == nil, let userTime = lastUserCreatedAt {
                                    let dur = createdAt.timeIntervalSince(userTime)
                                    if dur > 0 && dur < 3600 {
                                        duration = dur
                                    }
                                }
                            }

                            parsedMsgs.append(ChatMessageItem(
                                id: mid,
                                sessionId: cid,
                                sender: isUserMsg ? "user" : "agent",
                                type: "text",
                                status: "completed",
                                content: content,
                                createdAt: createdAt,
                                tokens: tokens,
                                duration: duration
                            ))
                        }
                        if !parsedMsgs.isEmpty && messagesBySession[cid] != parsedMsgs {
                            messagesBySession[cid] = parsedMsgs
                            saveMessages(for: cid)
                            hasChanges = true
                        }
                    }

                    let icon: String
                    if projId == "outside-of-project" {
                        icon = "📁"
                    } else if projId == "default-cli-project" {
                        icon = "⌨️"
                    } else {
                        icon = "🛠️"
                    }

                    if let idx = sessions.firstIndex(where: { $0.id == cid }) {
                        let curr = sessions[idx]
                        if curr.title != title ||
                           curr.projectId != projId ||
                           curr.projectName != projName ||
                           curr.icon != icon ||
                           (!snippet.isEmpty && curr.lastMessageSnippet != snippet) ||
                           abs(curr.lastModifiedAt.timeIntervalSince(lastMod)) > 1 ||
                           curr.msgCount != msgCount {
                            sessions[idx].title = title
                            sessions[idx].projectId = projId
                            sessions[idx].projectName = projName
                            sessions[idx].icon = icon
                            if !snippet.isEmpty {
                                sessions[idx].lastMessageSnippet = snippet
                            }
                            sessions[idx].lastModifiedAt = lastMod
                            sessions[idx].msgCount = msgCount
                            hasChanges = true
                        }
                    } else {
                        let newTopic = ChatSessionItem(
                            id: cid,
                            title: title,
                            projectId: projId,
                            projectName: projName,
                            icon: icon,
                            createdAt: lastMod,
                            lastModifiedAt: lastMod,
                            lastMessageSnippet: snippet,
                            isPinned: false,
                            msgCount: msgCount
                        )
                        sessions.append(newTopic)
                        hasChanges = true
                    }
                }

                // Prune any server-originating sessions deleted from server
                let serverIds = Set(rawConvs.compactMap { $0["id"] as? String })
                let beforeCount = sessions.count
                sessions.removeAll { s in
                    if serverIds.contains(s.id) {
                        return false
                    }
                    // If it was a server conversation (UUID) that disappeared from server -> remove
                    if s.id.contains("-") && s.id.count >= 32 {
                        try? FileManager.default.removeItem(at: self.sessionMessagesURL(for: s.id))
                        self.messagesBySession.removeValue(forKey: s.id)
                        return true
                    }
                    // If it is an old temporary local session older than 10 mins -> clean up
                    if Date().timeIntervalSince(s.createdAt) > 600 {
                        try? FileManager.default.removeItem(at: self.sessionMessagesURL(for: s.id))
                        self.messagesBySession.removeValue(forKey: s.id)
                        return true
                    }
                    return false
                }
                if sessions.count != beforeCount {
                    hasChanges = true
                }

                if hasChanges {
                    sortSessions()
                    saveSessions()
                    updateLocalProjectCounts()
                }

                // Automatically scan conversation records for quota limits
                QuotaResetStore.shared.scanAndSyncFromConversations(
                    messagesBySession: self.messagesBySession,
                    sessions: self.sessions,
                    currentAccount: self.currentAccount
                )
            }
        } catch {
            // Background fetch error is non-fatal
        }
    }

    func updateLocalProjectCounts() {
        var counts: [String: (name: String, icon: String, count: Int, snippet: String, time: Date)] = [:]
        for s in sessions {
            let pid = (s.projectId.isEmpty || s.projectId == "default") ? "outside-of-project" : s.projectId
            let defaultName = (pid == "outside-of-project") ? "Outside of Project" : "新项目"
            let pName = s.projectName.isEmpty ? defaultName : s.projectName
            if var existing = counts[pid] {
                existing.count += 1
                if s.lastModifiedAt > existing.time {
                    existing.time = s.lastModifiedAt
                    existing.snippet = s.lastMessageSnippet
                }
                counts[pid] = existing
            } else {
                counts[pid] = (pName, s.icon, 1, s.lastMessageSnippet, s.lastModifiedAt)
            }
        }
        var list: [ChatProjectItem] = []
        var seenPids: Set<String> = []
        for p in self.projects {
            guard p.id != "all" else { continue }
            seenPids.insert(p.id)
            if let info = counts[p.id] {
                list.append(ChatProjectItem(id: p.id, name: info.name, icon: info.icon, count: info.count, latestSnippet: info.snippet, latestTime: info.time))
            } else {
                var zeroP = p
                zeroP.count = 0
                zeroP.latestSnippet = ""
                list.append(zeroP)
            }
        }
        for (pid, info) in counts {
            if !seenPids.contains(pid) && pid != "all" {
                list.append(ChatProjectItem(id: pid, name: info.name, icon: info.icon, count: info.count, latestSnippet: info.snippet, latestTime: info.time))
            }
        }
        if self.projects != list {
            self.projects = list
            saveProjects()
        }
    }

    func retryMessage(id: String, sessionId: String? = nil, server: String, token: String?) async {
        let sid = sessionId ?? selectedSessionId
        guard var list = messagesBySession[sid],
              let item = list.first(where: { $0.id == id && $0.status == "failed" }) else { return }

        if let idx = list.firstIndex(where: { $0.id == id }) {
            list[idx].status = "pending"
            messagesBySession[sid] = list
            saveMessages(for: sid)
        }
        errorMessage = nil
        typingBySession[sid] = true

        let payload: [String: Any] = [
            "id": item.id,
            "account": currentAccount,
            "session_id": item.sessionId,
            "sender": "user",
            "type": item.type,
            "status": "completed",
            "content": item.content,
            "created_at": item.createdAt.timeIntervalSince1970,
        ]

        do {
            _ = try await post(server: server, path: "/api/chat/send", payload: payload, token: token)
            if var currentList = messagesBySession[sid],
               let idx = currentList.firstIndex(where: { $0.id == id }) {
                currentList[idx].status = "completed"
                messagesBySession[sid] = currentList
                saveMessages(for: sid)
            }
            await sync(server: server, token: token)
        } catch {
            errorMessage = "发送失败: \(error.localizedDescription)"
            if var currentList = messagesBySession[sid],
               let idx = currentList.firstIndex(where: { $0.id == id }) {
                currentList[idx].status = "failed"
                messagesBySession[sid] = currentList
                saveMessages(for: sid)
            }
            typingBySession[sid] = false
        }
    }

    // MARK: - Persistence & Migration

    private func sessionMessagesURL(for sessionId: String) -> URL {
        let safeName = sessionId.replacingOccurrences(of: "/", with: "_")
        return chatDir.appendingPathComponent("messages_\(safeName).json")
    }

    func saveProjects() {
        let list = projects
        let url = projectsURL
        DispatchQueue.global(qos: .background).async {
            if let data = try? JSONEncoder().encode(list) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    private func saveSessions() {
        let list = sessions
        let url = sessionsURL
        DispatchQueue.global(qos: .background).async {
            if let data = try? JSONEncoder().encode(list) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    private func saveMessages(for sessionId: String) {
        let list = messagesBySession[sessionId] ?? []
        let url = sessionMessagesURL(for: sessionId)
        DispatchQueue.global(qos: .background).async {
            if let data = try? JSONEncoder().encode(list) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    private func loadLocalHistory() {
        // 1. Check if projects.json exists
        if let pData = try? Data(contentsOf: projectsURL),
           let pList = try? JSONDecoder().decode([ChatProjectItem].self, from: pData),
           !pList.isEmpty {
            self.projects = pList
        }

        // 2. Check if modern sessions.json exists
        if let data = try? Data(contentsOf: sessionsURL),
            var list = try? JSONDecoder().decode([ChatSessionItem].self, from: data),
            !list.isEmpty {
            for i in list.indices {
                let sid = list[i].id
                let url = sessionMessagesURL(for: sid)
                if let mData = try? Data(contentsOf: url),
                   let msgs = try? JSONDecoder().decode([ChatMessageItem].self, from: mData) {
                    let cleaned = msgs.filter { $0.type != "status" && !$0.content.hasPrefix("Agent started processing") }
                    messagesBySession[sid] = cleaned
                    if cleaned.count != msgs.count {
                        saveMessages(for: sid)
                    }
                    if list[i].lastMessageSnippet.contains("Agent started processing") {
                        let lastValid = cleaned.last
                        let snip = (lastValid?.content ?? "").replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                        list[i].lastMessageSnippet = lastValid != nil ? "\(lastValid!.sender == "user" ? "我" : "Agent"): \(snip)" : ""
                    }
                } else {
                    messagesBySession[sid] = []
                }
            }
            self.sessions = list
            self.selectedSessionId = sessions.first?.id ?? "default"
            sortSessions()
            saveSessions()
            if self.projects.isEmpty {
                updateLocalProjectCounts()
            }
            QuotaResetStore.shared.scanAndSyncFromConversations(
                messagesBySession: self.messagesBySession,
                sessions: self.sessions,
                currentAccount: self.currentAccount
            )
            return
        }

        // 2. Migration: Check if legacy chat_history.json exists
        if let data = try? Data(contentsOf: legacyFileURL),
           let legacyMessages = try? JSONDecoder().decode([ChatMessageItem].self, from: data),
           !legacyMessages.isEmpty {
            let last = legacyMessages.last
            let lastSnippet = (last?.content ?? "").replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            let defaultSession = ChatSessionItem(
                id: "default",
                title: "默认会话",
                createdAt: legacyMessages.first?.createdAt ?? Date(),
                lastModifiedAt: last?.createdAt ?? Date(),
                lastMessageSnippet: last != nil ? "\(last!.sender == "user" ? "我" : "Agent"): \(lastSnippet)" : "",
                isPinned: true
            )
            self.sessions = [defaultSession]
            self.selectedSessionId = "default"
            self.messagesBySession["default"] = legacyMessages
            saveSessions()
            saveMessages(for: "default")
            return
        }

        // 3. Brand new setup: create starter session
        let initialSession = ChatSessionItem(id: "default", title: "默认会话")
        self.sessions = [initialSession]
        self.selectedSessionId = "default"
        self.messagesBySession["default"] = []
        saveSessions()
        saveMessages(for: "default")
    }

    // MARK: - HTTP Helper

    private func post(
        server: String,
        path: String,
        payload: [String: Any],
        token: String?
    ) async throws -> [String: Any] {
        var base = server.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }

        guard let url = URL(string: base + path) else {
            throw URLError(.badURL)
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("LSM-MobileWorker/0.4.5 (iOS)", forHTTPHeaderField: "User-Agent")
        if let token, !token.isEmpty {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        if !(200..<300).contains(http.statusCode) {
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let err = json["detail"] as? String ?? json["error"] as? String {
                throw NSError(domain: "LSMError", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: err])
            }
            throw URLError(.badServerResponse)
        }

        let obj = try JSONSerialization.jsonObject(with: data)
        guard let dict = obj as? [String: Any], dict["ok"] as? Bool == true else {
            let msg = (obj as? [String: Any])?["error"] as? String ?? "未知错误"
            throw NSError(domain: "LSMError", code: 400, userInfo: [NSLocalizedDescriptionKey: msg])
        }

        return (dict["data"] as? [String: Any]) ?? [:]
    }
}
