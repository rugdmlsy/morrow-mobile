import SwiftUI
import UIKit

/// Main Chat Tab Root: Telegram Topics-style navigation container.
struct ChatView: View {
    @ObservedObject var model: WorkerViewModel
    @ObservedObject private var chatStore = MobileChatStore.shared

    @State private var navigationPath = NavigationPath()

    init(model: WorkerViewModel) {
        self.model = model
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            ChatProjectsListView(
                model: model,
                navigationPath: $navigationPath
            )
            .navigationDestination(for: ChatProjectItem.self) { project in
                ProjectTopicsListView(
                    model: model,
                    project: project,
                    navigationPath: $navigationPath
                )
            }
            .navigationDestination(for: ChatSessionItem.self) { session in
                ChatDetailView(
                    model: model,
                    session: session,
                    onDeleteSession: {
                        if !navigationPath.isEmpty {
                            navigationPath.removeLast()
                        }
                    }
                )
            }
        }
        .onAppear {
            chatStore.startPolling(server: model.server, token: token)
            Task {
                await chatStore.sync(server: model.server, token: token)
            }
        }
        .onDisappear {
            chatStore.stopPolling()
        }
    }

    private var token: String? {
        if let data = try? KeychainStore.load(),
           let id = try? JSONDecoder().decode(WorkerIdentity.self, from: data) {
            return id.token
        }
        return nil
    }
}

// MARK: - Level 1: Projects List View (Telegram Forum Groups)

struct ChatProjectsListView: View {
    @ObservedObject var model: WorkerViewModel
    @Binding var navigationPath: NavigationPath
    @ObservedObject private var chatStore = MobileChatStore.shared

    @State private var searchText: String = ""
    @State private var isShowingNewProjectAlert: Bool = false
    @State private var newProjectName: String = ""
    @State private var projectToDelete: ChatProjectItem? = nil

    private var token: String? {
        if let data = try? KeychainStore.load(),
           let id = try? JSONDecoder().decode(WorkerIdentity.self, from: data) {
            return id.token
        }
        return nil
    }

    private var filteredProjects: [ChatProjectItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if query.isEmpty {
            return chatStore.projects
        }
        return chatStore.projects.filter { proj in
            proj.name.lowercased().contains(query) ||
            proj.latestSnippet.lowercased().contains(query)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Telegram connectivity header
            telegramStatusBar

            if filteredProjects.isEmpty && !searchText.isEmpty {
                emptySearchResultView
            } else if chatStore.projects.isEmpty {
                emptyProjectsView
            } else {
                List {
                    ForEach(filteredProjects) { project in
                        NavigationLink(value: project) {
                            ProjectRowView(project: project)
                        }
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if project.id != "outside-of-project" && project.id != "default-cli-project" {
                                Button(role: .destructive) {
                                    projectToDelete = project
                                } label: {
                                    Label("删除项目", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .refreshable {
                    await chatStore.sync(server: model.server, token: token)
                }
            }
        }
        .navigationTitle("Project")
        .navigationBarTitleDisplayMode(.large)
        .searchable(text: $searchText, prompt: "搜索项目或对话内容")
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button {
                    newProjectName = ""
                    isShowingNewProjectAlert = true
                } label: {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 16, weight: .semibold))
                }

                Button {
                    let newTopic = chatStore.createSession(
                        title: "新对话",
                        projectId: "outside-of-project",
                        projectName: "Outside of Project"
                    )
                    navigationPath.append(newTopic)
                } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 16, weight: .semibold))
                }
            }
        }
        .alert("新建项目", isPresented: $isShowingNewProjectAlert) {
            TextField("项目名称", text: $newProjectName)
            Button("取消", role: .cancel) {
                newProjectName = ""
            }
            Button("创建") {
                let clean = newProjectName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !clean.isEmpty else { return }
                let newProj = chatStore.createProject(name: clean)
                let newSess = chatStore.createSession(
                    title: "新对话",
                    projectId: newProj.id,
                    projectName: newProj.name
                )
                newProjectName = ""
                navigationPath.append(newProj)
                navigationPath.append(newSess)
            }
        } message: {
            Text("请输入新项目名称，创建后将自动同步至 Mac 端 Antigravity。")
        }
        .alert("删除项目", isPresented: Binding(
            get: { projectToDelete != nil },
            set: { if !$0 { projectToDelete = nil } }
        )) {
            Button("取消", role: .cancel) { projectToDelete = nil }
            Button("删除", role: .destructive) {
                if let p = projectToDelete {
                    chatStore.deleteProject(id: p.id, server: model.server, token: token)
                }
                projectToDelete = nil
            }
        } message: {
            Text("确定要删除此项目及其所有对话吗？此操作不可撤销。")
        }
    }

    private var telegramStatusBar: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(model.connected ? Color.green : Color.orange)
                .frame(width: 8, height: 8)
            Text(model.connected ? "MacBook 已在线 · 随时响应" : "等待连接至中继...")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer()
            Text("\(chatStore.projects.count) 个项目 · \(chatStore.sessions.count) 个对话")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
    }

    private var emptySearchResultView: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "magnifyingglass")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("未找到相关项目")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("没有找到与“\(searchText)”匹配的项目或对话")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
        }
    }

    private var emptyProjectsView: some View {
        VStack(spacing: 16) {
            Spacer()
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.12))
                    .frame(width: 80, height: 80)
                Image(systemName: "folder.badge.gearshape")
                    .font(.system(size: 36))
                    .foregroundStyle(Color.accentColor)
            }
            Text("暂无项目")
                .font(.title3.weight(.semibold))
            Text("Mac 端的 Antigravity 对话将自动按项目同步到此处。您也可以立即创建新对话。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 36)

            HStack(spacing: 12) {
                Button {
                    newProjectName = ""
                    isShowingNewProjectAlert = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "folder.badge.plus")
                        Text("新建项目")
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 11)
                    .background(Color.accentColor)
                    .clipShape(Capsule())
                    .shadow(color: Color.accentColor.opacity(0.3), radius: 6, x: 0, y: 3)
                }

                Button {
                    let newTopic = chatStore.createSession(
                        title: "新对话",
                        projectId: "outside-of-project",
                        projectName: "Outside of Project"
                    )
                    navigationPath.append(newTopic)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "square.and.pencil")
                        Text("新建对话")
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 11)
                    .background(Color.accentColor.opacity(0.12))
                    .clipShape(Capsule())
                }
            }
            .padding(.top, 8)
            Spacer()
        }
    }
}

// MARK: - Project Row View (Telegram Forum Item)

struct ProjectRowView: View {
    let project: ChatProjectItem

    var body: some View {
        HStack(spacing: 14) {
            // Rounded rectangle Forum Icon
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(projectGradient(for: project.id))
                    .frame(width: 50, height: 50)
                Text(project.icon)
                    .font(.system(size: 24))
            }

            // Middle info
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(project.name)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Color.primary)
                        .lineLimit(1)

                    Spacer()

                    Text(formatRelativeTime(project.latestTime))
                        .font(.system(size: 12))
                        .foregroundStyle(Color.secondary.opacity(0.8))
                }

                HStack(spacing: 4) {
                    Text("\(project.count) 个对话")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.accentColor)

                    if !project.latestSnippet.isEmpty {
                        Text("·")
                            .font(.system(size: 13))
                            .foregroundStyle(.tertiary)
                        Text(project.latestSnippet)
                            .font(.system(size: 13))
                            .foregroundStyle(Color.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func projectGradient(for id: String) -> LinearGradient {
        if id == "outside-of-project" {
            return LinearGradient(
                colors: [Color(red: 0.20, green: 0.65, blue: 0.95), Color(red: 0.10, green: 0.45, blue: 0.85)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        } else if id == "default-cli-project" {
            return LinearGradient(
                colors: [Color(red: 0.35, green: 0.40, blue: 0.50), Color(red: 0.20, green: 0.25, blue: 0.35)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        }
        let colors: [[Color]] = [
            [Color(red: 0.15, green: 0.75, blue: 0.70), Color(red: 0.10, green: 0.55, blue: 0.65)],
            [Color(red: 1.00, green: 0.55, blue: 0.20), Color(red: 0.95, green: 0.35, blue: 0.30)],
            [Color(red: 0.25, green: 0.75, blue: 0.40), Color(red: 0.15, green: 0.60, blue: 0.45)],
            [Color(red: 0.95, green: 0.30, blue: 0.60), Color(red: 0.75, green: 0.15, blue: 0.55)],
        ]
        let hash = abs(id.hashValue)
        let pair = colors[hash % colors.count]
        return LinearGradient(colors: pair, startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

// MARK: - Level 2: Project Topics List View (Telegram Topics Screen)

struct ProjectTopicsListView: View {
    @ObservedObject var model: WorkerViewModel
    let project: ChatProjectItem
    @Binding var navigationPath: NavigationPath

    @ObservedObject private var chatStore = MobileChatStore.shared
    @State private var searchText: String = ""
    @State private var sessionToRename: ChatSessionItem? = nil
    @State private var renameText: String = ""
    @State private var sessionToDelete: ChatSessionItem? = nil

    private var token: String? {
        if let data = try? KeychainStore.load(),
           let id = try? JSONDecoder().decode(WorkerIdentity.self, from: data) {
            return id.token
        }
        return nil
    }

    private var projectSessions: [ChatSessionItem] {
        let baseList = chatStore.sessions.filter { $0.projectId == project.id }

        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if query.isEmpty {
            return baseList
        }
        return baseList.filter { s in
            s.title.lowercased().contains(query) ||
            s.lastMessageSnippet.lowercased().contains(query)
        }
    }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                // Topic count indicator bar
                HStack(spacing: 6) {
                    Text(project.icon)
                        .font(.caption)
                    Text(project.name)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                    Spacer()
                    Text("共 \(projectSessions.count) 个对话")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color(uiColor: .secondarySystemGroupedBackground))

                if projectSessions.isEmpty {
                    emptyTopicsView
                } else {
                    List {
                        ForEach(projectSessions) { session in
                            NavigationLink(value: session) {
                                TopicRowView(
                                    session: session,
                                    isTyping: chatStore.isAgentTyping(for: session.id)
                                )
                            }
                            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    sessionToDelete = session
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                            }
                            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                Button {
                                    withAnimation {
                                        chatStore.togglePin(id: session.id)
                                    }
                                } label: {
                                    Label(
                                        session.isPinned ? "取消置顶" : "置顶",
                                        systemImage: session.isPinned ? "pin.slash.fill" : "pin.fill"
                                    )
                                }
                                .tint(.blue)
                            }
                            .contextMenu {
                                Button {
                                    withAnimation {
                                        chatStore.togglePin(id: session.id)
                                    }
                                } label: {
                                    Label(
                                        session.isPinned ? "取消置顶" : "置顶",
                                        systemImage: session.isPinned ? "pin.slash" : "pin"
                                    )
                                }

                                Button {
                                    renameText = session.title
                                    sessionToRename = session
                                } label: {
                                    Label("重命名", systemImage: "pencil")
                                }

                                Button {
                                    chatStore.clearHistory(sessionId: session.id)
                                } label: {
                                    Label("清空记录", systemImage: "paintbrush")
                                }

                                Divider()

                                Button(role: .destructive) {
                                    sessionToDelete = session
                                } label: {
                                    Label("删除对话", systemImage: "trash")
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                    .refreshable {
                        await chatStore.sync(server: model.server, token: token)
                    }
                }
            }

            // Telegram Floating Action Button (FAB)
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    Button {
                        let newTopic = chatStore.createSession(
                            title: "新对话",
                            projectId: project.id,
                            projectName: project.name
                        )
                        navigationPath.append(newTopic)
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 54, height: 54)
                            .background(Color.accentColor)
                            .clipShape(Circle())
                            .shadow(color: Color.accentColor.opacity(0.35), radius: 8, x: 0, y: 4)
                    }
                    .padding(.trailing, 20)
                    .padding(.bottom, 20)
                }
            }
        }
        .navigationTitle(project.name)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "搜索当前项目对话")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    let newTopic = chatStore.createSession(
                        title: "新对话",
                        projectId: project.id,
                        projectName: project.name
                    )
                    navigationPath.append(newTopic)
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 16, weight: .semibold))
                }
            }
        }
        .alert("重命名对话", isPresented: Binding(
            get: { sessionToRename != nil },
            set: { if !$0 { sessionToRename = nil } }
        )) {
            TextField("对话名称", text: $renameText)
            Button("取消", role: .cancel) { sessionToRename = nil }
            Button("保存") {
                if let s = sessionToRename {
                    chatStore.renameSession(id: s.id, newTitle: renameText)
                }
                sessionToRename = nil
            }
        }
        .alert("删除对话", isPresented: Binding(
            get: { sessionToDelete != nil },
            set: { if !$0 { sessionToDelete = nil } }
        )) {
            Button("取消", role: .cancel) { sessionToDelete = nil }
            Button("删除", role: .destructive) {
                if let s = sessionToDelete {
                    chatStore.deleteSession(id: s.id, server: model.server, token: token)
                }
                sessionToDelete = nil
            }
        } message: {
            Text("确定要删除此对话及其所有聊天记录吗？此操作不可撤销。")
        }
    }

    private var emptyTopicsView: some View {
        VStack(spacing: 16) {
            Spacer()
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.12))
                    .frame(width: 72, height: 72)
                Text(project.icon)
                    .font(.system(size: 32))
            }
            Text("暂无对话")
                .font(.headline)
            Text("在此项目中创建第一个对话，开始与 Mac 协同工作。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 36)

            Button {
                let newTopic = chatStore.createSession(
                    title: "新对话",
                    projectId: project.id,
                    projectName: project.name
                )
                navigationPath.append(newTopic)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus.circle.fill")
                    Text("新建对话")
                }
                .font(.headline)
                .foregroundStyle(.white)
                .padding(.horizontal, 22)
                .padding(.vertical, 10)
                .background(Color.accentColor)
                .clipShape(Capsule())
            }
            .padding(.top, 6)
            Spacer()
        }
    }
}

// MARK: - Topic Row View (Telegram Topic Item with Badge)

struct TopicRowView: View {
    let session: ChatSessionItem
    let isTyping: Bool

    var body: some View {
        HStack(spacing: 12) {
            // Telegram rounded-square topic badge
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(topicGradient(for: session.id))
                    .frame(width: 44, height: 44)

                Text(session.icon.isEmpty ? "💬" : session.icon)
                    .font(.system(size: 22))
            }

            // Content
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(session.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.primary)
                        .lineLimit(1)

                    Spacer()

                    Text(formatRelativeTime(session.lastModifiedAt))
                        .font(.system(size: 12))
                        .foregroundStyle(isTyping ? Color.accentColor : Color.secondary.opacity(0.8))
                }

                HStack(spacing: 6) {
                    if isTyping {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(Color.accentColor)
                                .frame(width: 5, height: 5)
                            Text("Agent 正在思考...")
                                .font(.system(size: 13))
                                .foregroundStyle(Color.accentColor)
                        }
                    } else if !session.lastMessageSnippet.isEmpty {
                        Text(session.lastMessageSnippet)
                            .font(.system(size: 13))
                            .foregroundStyle(Color.secondary)
                            .lineLimit(2)
                    } else {
                        Text("暂无消息")
                            .font(.system(size: 13))
                            .foregroundStyle(.tertiary)
                    }

                    Spacer()

                    if session.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.secondary.opacity(0.6))
                    }

                    // Telegram style blue pill badge for message count
                    let count = session.msgCount > 0 ? session.msgCount : MobileChatStore.shared.messages(for: session.id).count
                    if count > 0 {
                        Text("\(count)")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Color.accentColor)
                            .clipShape(Capsule())
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func topicGradient(for id: String) -> LinearGradient {
        let colors: [[Color]] = [
            [Color(red: 0.15, green: 0.50, blue: 0.90), Color(red: 0.10, green: 0.35, blue: 0.80)],
            [Color(red: 0.45, green: 0.30, blue: 0.85), Color(red: 0.60, green: 0.20, blue: 0.80)],
            [Color(red: 0.12, green: 0.70, blue: 0.65), Color(red: 0.08, green: 0.50, blue: 0.55)],
            [Color(red: 0.95, green: 0.50, blue: 0.15), Color(red: 0.90, green: 0.30, blue: 0.25)],
            [Color(red: 0.20, green: 0.70, blue: 0.35), Color(red: 0.12, green: 0.55, blue: 0.40)],
        ]
        let hash = abs(id.hashValue)
        let pair = colors[hash % colors.count]
        return LinearGradient(colors: pair, startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

// MARK: - Time Formatter Helper

func formatRelativeTime(_ date: Date) -> String {
    let calendar = Calendar.current
    if calendar.isDateInToday(date) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    } else if calendar.isDateInYesterday(date) {
        return "昨天"
    } else {
        let formatter = DateFormatter()
        formatter.dateFormat = "M/d"
        return formatter.string(from: date)
    }
}

// MARK: - Chat Detail View (Telegram / QQ Styled Chat Panel)

struct ChatDetailView: View {
    @ObservedObject var model: WorkerViewModel
    let session: ChatSessionItem
    var onDeleteSession: (() -> Void)? = nil

    @ObservedObject private var chatStore = MobileChatStore.shared

    @State private var inputText: String = ""
    @State private var isShowingClearAlert: Bool = false
    @State private var isShowingDeleteAlert: Bool = false
    @State private var isShowingRenameAlert: Bool = false
    @State private var renameText: String = ""
    @FocusState private var isInputFocused: Bool

    // Quick prompt shortcuts
    private let quickPrompts = [
        "📊 检查机器与 Git 状态",
        "🧪 运行所有单元测试",
        "🔍 查看最近系统日志",
        "💡 总结今天完成的工作",
    ]

    private var token: String? {
        if let data = try? KeychainStore.load(),
           let id = try? JSONDecoder().decode(WorkerIdentity.self, from: data) {
            return id.token
        }
        return nil
    }

    private var currentSession: ChatSessionItem {
        chatStore.session(for: session.id) ?? session
    }

    private var sessionMessages: [ChatMessageItem] {
        chatStore.messages(for: session.id)
    }

    private var isAgentTyping: Bool {
        chatStore.isAgentTyping(for: session.id)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Messages list
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        if sessionMessages.isEmpty {
                            emptyStateView
                                .padding(.top, 40)
                        } else {
                            ForEach(sessionMessages) { message in
                                MessageBubbleView(message: message, onRetry: {
                                    Task {
                                        await chatStore.retryMessage(
                                            id: message.id,
                                            sessionId: session.id,
                                            server: model.server,
                                            token: token
                                        )
                                    }
                                })
                                .id(message.id)
                            }
                        }

                        // Typing / Thinking Indicator
                        if isAgentTyping {
                            HStack(spacing: 8) {
                                AgentAvatarView()
                                TypingDotsIndicatorView()
                                Spacer()
                            }
                            .padding(.horizontal, 16)
                            .id("typing_indicator")
                        }
                    }
                    .padding(.vertical, 14)
                }
                .background(Color(uiColor: .systemGroupedBackground))
                .onTapGesture {
                    isInputFocused = false
                }
                .onChange(of: sessionMessages.count) { _ in
                    withAnimation(.easeOut(duration: 0.25)) {
                        if let lastId = sessionMessages.last?.id {
                            proxy.scrollTo(lastId, anchor: .bottom)
                        }
                    }
                }
                .onChange(of: isAgentTyping) { typing in
                    if typing {
                        withAnimation(.easeOut(duration: 0.25)) {
                            proxy.scrollTo("typing_indicator", anchor: .bottom)
                        }
                    }
                }
            }

            // Error banner if any
            if let error = chatStore.errorMessage {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Dismiss") { chatStore.errorMessage = nil }
                        .font(.caption2)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(Color(uiColor: .secondarySystemBackground))
            }

            // Bottom Input Bar
            bottomInputBar
        }
        .navigationTitle(currentSession.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 2) {
                    Text(currentSession.title)
                        .font(.system(size: 16, weight: .semibold))
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        Circle()
                            .fill(isAgentTyping ? Color.accentColor : (model.connected ? Color.green : Color.orange))
                            .frame(width: 6, height: 6)
                        Text(isAgentTyping ? "正在思考..." : (model.connected ? "MacBook 已在线" : "等待连接"))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button {
                        renameText = currentSession.title
                        isShowingRenameAlert = true
                    } label: {
                        Label("重命名会话", systemImage: "pencil")
                    }

                    Button {
                        withAnimation {
                            chatStore.togglePin(id: session.id)
                        }
                    } label: {
                        Label(
                            currentSession.isPinned ? "取消置顶" : "置顶会话",
                            systemImage: currentSession.isPinned ? "pin.slash" : "pin"
                        )
                    }

                    Button(role: .destructive) {
                        isShowingClearAlert = true
                    } label: {
                        Label("清空聊天记录", systemImage: "paintbrush")
                    }

                    Divider()

                    Button(role: .destructive) {
                        isShowingDeleteAlert = true
                    } label: {
                        Label("删除此会话", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.body)
                }
            }
        }
        .alert("重命名会话", isPresented: $isShowingRenameAlert) {
            TextField("会话名称", text: $renameText)
            Button("取消", role: .cancel) {}
            Button("保存") {
                chatStore.renameSession(id: session.id, newTitle: renameText)
            }
        }
        .alert("清空会话记录", isPresented: $isShowingClearAlert) {
            Button("取消", role: .cancel) {}
            Button("清空", role: .destructive) {
                chatStore.clearHistory(sessionId: session.id)
            }
        } message: {
            Text("此操作将清空该会话在手机上的所有聊天记录。")
        }
        .alert("删除此会话", isPresented: $isShowingDeleteAlert) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) {
                chatStore.deleteSession(id: session.id)
                onDeleteSession?()
            }
        } message: {
            Text("确定要删除此会话吗？其聊天记录将被永久移除。")
        }
        .onAppear {
            chatStore.selectedSessionId = session.id
        }
    }

    // Empty state
    private var emptyStateView: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.12))
                    .frame(width: 72, height: 72)
                Image(systemName: "sparkles")
                    .font(.system(size: 32, weight: .medium))
                    .foregroundStyle(Color.accentColor)
            }
            Text(currentSession.title)
                .font(.headline)
            Text("发送消息开始与本地 Agent 对话，首条消息可自动重命名此会话。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            // Quick suggestion chips
            VStack(alignment: .leading, spacing: 8) {
                Text("快捷示例：")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                ForEach(quickPrompts, id: \.self) { prompt in
                    Button {
                        inputText = prompt
                        isInputFocused = true
                    } label: {
                        HStack {
                            Text(prompt)
                                .font(.footnote)
                            Spacer()
                            Image(systemName: "arrow.up.right")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Color(uiColor: .secondarySystemGroupedBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)
        }
    }

    // Telegram/QQ-style bottom floating input dock
    private var bottomInputBar: some View {
        VStack(spacing: 8) {
            if !quickPrompts.isEmpty && inputText.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(quickPrompts, id: \.self) { chip in
                            Button {
                                inputText = chip
                                isInputFocused = true
                            } label: {
                                Text(chip)
                                    .font(.caption)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(Color(uiColor: .tertiarySystemFill))
                                    .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }

            HStack(alignment: .bottom, spacing: 10) {
                TextField("给 Agent 发送指令...", text: $inputText, axis: .vertical)
                    .lineLimit(1...5)
                    .focused($isInputFocused)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color(uiColor: .tertiarySystemFill))
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

                Button {
                    let text = inputText
                    inputText = ""
                    Task {
                        await chatStore.sendMessage(
                            content: text,
                            sessionId: session.id,
                            server: model.server,
                            token: token
                        )
                    }
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(
                            inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                ? Color.secondary.opacity(0.4)
                                : Color.accentColor
                        )
                }
                .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(
            Color(uiColor: .secondarySystemGroupedBackground)
                .ignoresSafeArea(edges: .bottom)
        )
    }
}

// MARK: - Message Bubble Component (TG & QQ Inspired)

struct MessageBubbleView: View {
    let message: ChatMessageItem
    var onRetry: (() -> Void)? = nil

    var isUser: Bool {
        message.sender == "user"
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if isUser {
                Spacer(minLength: 44)
            } else {
                AgentAvatarView()
            }

            VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
                // Tool invocation / Thought badge if applicable
                if let toolName = message.toolName {
                    HStack(spacing: 4) {
                        Image(systemName: "terminal.fill")
                            .font(.caption2)
                        Text(toolName)
                            .font(.system(.caption2, design: .monospaced))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.black.opacity(0.12))
                    .clipShape(Capsule())
                }

                // Bubble Content
                VStack(alignment: .leading, spacing: 6) {
                    MarkdownMessageView(content: message.content, isUser: isUser)

                    // Optional tool output
                    if let output = message.toolOutput, !output.isEmpty {
                        Text(output)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(Color.green)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.black.opacity(0.85))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(bubbleBackground)
                .clipShape(BubbleShape(isUser: isUser))
                .shadow(color: Color.black.opacity(0.04), radius: 2, x: 0, y: 1)

                // Timestamp and Delivery Status
                HStack(spacing: 4) {
                    Text(timeString(from: message.createdAt))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)

                    if isUser {
                        statusIcon
                    }
                }
                .padding(.horizontal, 4)
            }

            if !isUser {
                Spacer(minLength: 44)
            }
        }
        .padding(.horizontal, 12)
    }

    @ViewBuilder
    private var bubbleBackground: some View {
        if isUser {
            LinearGradient(
                colors: [
                    Color(red: 0.12, green: 0.58, blue: 0.95),
                    Color(red: 0.05, green: 0.48, blue: 0.90)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        } else {
            Color(uiColor: .secondarySystemGroupedBackground)
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch message.status {
        case "pending":
            Image(systemName: "clock")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        case "completed":
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 10))
                .foregroundStyle(.green)
        case "failed":
            if let onRetry {
                Button {
                    onRetry()
                } label: {
                    HStack(spacing: 2) {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.system(size: 10))
                        Text("重试")
                            .font(.system(size: 9, weight: .medium))
                    }
                    .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
            } else {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
            }
        default:
            EmptyView()
        }
    }

    private func timeString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}

// Telegram & QQ style rounded bubble with slight corner tail
struct BubbleShape: Shape {
    let isUser: Bool

    func path(in rect: CGRect) -> Path {
        let corner: CGFloat = 16
        let tailCorner: CGFloat = 4

        return Path { path in
            if isUser {
                path.addRoundedRect(
                    in: rect,
                    cornerRadii: RectangleCornerRadii(
                        topLeading: corner,
                        bottomLeading: corner,
                        bottomTrailing: tailCorner,
                        topTrailing: corner
                    )
                )
            } else {
                path.addRoundedRect(
                    in: rect,
                    cornerRadii: RectangleCornerRadii(
                        topLeading: tailCorner,
                        bottomLeading: corner,
                        bottomTrailing: corner,
                        topTrailing: corner
                    )
                )
            }
        }
    }
}

// Avatar for Agent
struct AgentAvatarView: View {
    var body: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [Color.indigo, Color.purple],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 32, height: 32)
            Image(systemName: "cpu.fill")
                .font(.system(size: 15))
                .foregroundStyle(.white)
        }
    }
}

// Animated 3-dots typing indicator (TG style)
struct TypingDotsIndicatorView: View {
    @State private var phase: CGFloat = 0

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3) { index in
                Circle()
                    .fill(Color.secondary.opacity(0.6))
                    .frame(width: 7, height: 7)
                    .offset(y: sin(phase + Double(index) * 1.0) * 4)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(Capsule())
        .onAppear {
            withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
                phase = .pi
            }
        }
    }
}

// MARK: - Markdown Rendering Engine

enum MarkdownBlock: Identifiable {
    case codeBlock(id: String, language: String?, code: String)
    case heading(id: String, level: Int, text: String)
    case quote(id: String, text: String, alertType: String?)
    case list(id: String, items: [(bullet: String, text: String)])
    case divider(id: String)
    case paragraph(id: String, text: String)

    var id: String {
        switch self {
        case .codeBlock(let id, _, _): return id
        case .heading(let id, _, _): return id
        case .quote(let id, _, _): return id
        case .list(let id, _): return id
        case .divider(let id): return id
        case .paragraph(let id, _): return id
        }
    }
}

struct MarkdownMessageView: View {
    let content: String
    let isUser: Bool

    private var blocks: [MarkdownBlock] {
        parseMarkdownBlocks(content)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(blocks) { block in
                renderBlock(block)
            }
        }
    }

    @ViewBuilder
    private func renderBlock(_ block: MarkdownBlock) -> some View {
        switch block {
        case .codeBlock(_, let language, let code):
            CodeBlockCardView(language: language, code: code, isUser: isUser)
        case .heading(_, let level, let text):
            Text(LocalizedStringKey(text))
                .font(headingFont(level: level))
                .fontWeight(.bold)
                .foregroundStyle(isUser ? Color.white : Color.primary)
                .textSelection(.enabled)
                .padding(.top, level <= 2 ? 4 : 2)
        case .quote(_, let text, let alertType):
            AlertCalloutView(text: text, alertType: alertType, isUser: isUser)
        case .list(_, let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(0..<items.count, id: \.self) { idx in
                    HStack(alignment: .top, spacing: 6) {
                        Text(items[idx].bullet)
                            .font(.system(size: 14, weight: .bold, design: .monospaced))
                            .foregroundStyle(isUser ? Color.white.opacity(0.8) : Color.accentColor)
                            .frame(minWidth: 16, alignment: .leading)
                        Text(LocalizedStringKey(items[idx].text))
                            .font(.body)
                            .foregroundStyle(isUser ? Color.white : Color.primary)
                            .textSelection(.enabled)
                    }
                }
            }
            .padding(.vertical, 2)
        case .divider(_):
            Divider()
                .overlay(isUser ? Color.white.opacity(0.3) : Color.secondary.opacity(0.3))
                .padding(.vertical, 2)
        case .paragraph(_, let text):
            Text(LocalizedStringKey(text))
                .font(.body)
                .foregroundStyle(isUser ? Color.white : Color.primary)
                .textSelection(.enabled)
        }
    }

    private func headingFont(level: Int) -> Font {
        switch level {
        case 1: return .title2
        case 2: return .title3
        case 3: return .headline
        default: return .subheadline
        }
    }
}

struct CodeBlockCardView: View {
    let language: String?
    let code: String
    let isUser: Bool
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language?.uppercased() ?? "CODE")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.secondary)

                Spacer()

                Button {
                    UIPasteboard.general.string = code
                    withAnimation(.easeInOut(duration: 0.2)) {
                        copied = true
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        withAnimation {
                            copied = false
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 11))
                        Text(copied ? "已复制" : "复制")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(copied ? Color.green : Color.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.white.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.black.opacity(0.25))

            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(Color(white: 0.92))
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
        .background(Color(red: 0.12, green: 0.13, blue: 0.16))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
        .padding(.vertical, 3)
    }
}

struct AlertCalloutView: View {
    let text: String
    let alertType: String?
    let isUser: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 2)
                .fill(accentColor)
                .frame(width: 3)

            VStack(alignment: .leading, spacing: 4) {
                if let type = alertType {
                    HStack(spacing: 4) {
                        Image(systemName: iconName)
                            .font(.caption2.bold())
                        Text(type.uppercased())
                            .font(.caption2.bold())
                    }
                    .foregroundStyle(accentColor)
                }
                Text(LocalizedStringKey(text))
                    .font(.subheadline)
                    .foregroundStyle(isUser ? Color.white.opacity(0.9) : Color.primary)
                    .textSelection(.enabled)
            }
        }
        .padding(8)
        .background(accentColor.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .padding(.vertical, 2)
    }

    private var accentColor: Color {
        switch alertType?.uppercased() {
        case "NOTE": return .blue
        case "TIP": return .green
        case "IMPORTANT": return .purple
        case "WARNING": return .orange
        case "CAUTION": return .red
        default: return .secondary
        }
    }

    private var iconName: String {
        switch alertType?.uppercased() {
        case "NOTE": return "info.circle.fill"
        case "TIP": return "lightbulb.fill"
        case "IMPORTANT": return "exclamationmark.circle.fill"
        case "WARNING": return "exclamationmark.triangle.fill"
        case "CAUTION": return "shield.fill"
        default: return "quote.opening"
        }
    }
}

func parseMarkdownBlocks(_ raw: String) -> [MarkdownBlock] {
    let lines = raw.components(separatedBy: "\n")
    var blocks: [MarkdownBlock] = []
    var i = 0
    var blockIndex = 0

    while i < lines.count {
        let line = lines[i]
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        // 1. Code block fence
        if trimmed.hasPrefix("```") {
            let lang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
            var codeLines: [String] = []
            i += 1
            while i < lines.count {
                if lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    i += 1
                    break
                }
                codeLines.append(lines[i])
                i += 1
            }
            let code = codeLines.joined(separator: "\n")
            blocks.append(.codeBlock(id: "block_\(blockIndex)", language: lang.isEmpty ? nil : lang, code: code))
            blockIndex += 1
            continue
        }

        // 2. Horizontal divider
        if trimmed == "---" || trimmed == "***" || trimmed == "___" {
            blocks.append(.divider(id: "block_\(blockIndex)"))
            blockIndex += 1
            i += 1
            continue
        }

        // 3. Headings (# , ## , ### )
        if trimmed.hasPrefix("#") {
            let hashes = trimmed.prefix(while: { $0 == "#" })
            let level = hashes.count
            if level <= 6 {
                let rest = trimmed.dropFirst(level).trimmingCharacters(in: .whitespaces)
                blocks.append(.heading(id: "block_\(blockIndex)", level: level, text: rest))
                blockIndex += 1
                i += 1
                continue
            }
        }

        // 4. Blockquote / GitHub Alert (> )
        if trimmed.hasPrefix(">") {
            var quoteLines: [String] = []
            while i < lines.count && lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                let qLine = String(lines[i].trimmingCharacters(in: .whitespaces).dropFirst()).trimmingCharacters(in: .whitespaces)
                quoteLines.append(qLine)
                i += 1
            }
            var alertType: String? = nil
            var cleanText = quoteLines.joined(separator: "\n")
            if let first = quoteLines.first, first.hasPrefix("[!") && first.contains("]") {
                if let endBracket = first.firstIndex(of: "]") {
                    let type = String(first[first.index(after: first.index(after: first.startIndex))..<endBracket])
                    alertType = type
                    let remainingFirst = String(first[first.index(after: endBracket)...]).trimmingCharacters(in: .whitespaces)
                    var newLines = quoteLines
                    if remainingFirst.isEmpty {
                        newLines.removeFirst()
                    } else {
                        newLines[0] = remainingFirst
                    }
                    cleanText = newLines.joined(separator: "\n")
                }
            }
            blocks.append(.quote(id: "block_\(blockIndex)", text: cleanText, alertType: alertType))
            blockIndex += 1
            continue
        }

        // 5. Lists (- , * , 1. )
        if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || (trimmed.first?.isNumber == true && trimmed.contains(". ")) {
            var listItems: [(bullet: String, text: String)] = []
            while i < lines.count {
                let curr = lines[i].trimmingCharacters(in: .whitespaces)
                if curr.hasPrefix("- ") || curr.hasPrefix("* ") {
                    let itemText = String(curr.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                    listItems.append(("•", itemText))
                    i += 1
                } else if let dotRange = curr.range(of: ". ") {
                    let prefixNum = String(curr[..<dotRange.lowerBound])
                    if Int(prefixNum) != nil {
                        let itemText = String(curr[dotRange.upperBound...]).trimmingCharacters(in: .whitespaces)
                        listItems.append(("\(prefixNum).", itemText))
                        i += 1
                    } else {
                        break
                    }
                } else {
                    break
                }
            }
            blocks.append(.list(id: "block_\(blockIndex)", items: listItems))
            blockIndex += 1
            continue
        }

        // 6. Regular paragraph (accumulate consecutive non-empty non-special lines)
        if trimmed.isEmpty {
            i += 1
            continue
        }

        var paraLines: [String] = []
        while i < lines.count {
            let nextTrimmed = lines[i].trimmingCharacters(in: .whitespaces)
            if nextTrimmed.isEmpty ||
               nextTrimmed.hasPrefix("```") ||
               nextTrimmed.hasPrefix("#") ||
               nextTrimmed.hasPrefix(">") ||
               nextTrimmed == "---" ||
               nextTrimmed == "***" ||
               nextTrimmed.hasPrefix("- ") ||
               nextTrimmed.hasPrefix("* ") {
                break
            }
            paraLines.append(lines[i])
            i += 1
        }
        if !paraLines.isEmpty {
            let pText = paraLines.joined(separator: "\n")
            blocks.append(.paragraph(id: "block_\(blockIndex)", text: pText))
            blockIndex += 1
        }
    }

    return blocks
}

