import SwiftUI
import UserNotifications

struct QuotaResetView: View {
    @ObservedObject var model: WorkerViewModel
    @ObservedObject private var store = QuotaResetStore.shared
    @ObservedObject private var chatStore = MobileChatStore.shared

    @State private var selectedAccount: String = "antigravity-0"
    @State private var showCustomSheet: Bool = false
    @State private var showToast: Bool = false
    @State private var toastMessage: String = ""

    var body: some View {
        List {
            // 1. Notification Permission Notice
            if !store.notificationAuthorized {
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: "bell.badge.slash.fill")
                            .font(.title2)
                            .foregroundStyle(Color.orange)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("未开启系统通知权限")
                                .font(.system(size: 15, weight: .semibold))
                            Text("开启后，额度到期重置时即使锁屏也会准时收到本地推送。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("开启") {
                            Task {
                                _ = await store.requestNotificationPermission()
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .font(.caption.weight(.medium))
                    }
                    .padding(.vertical, 4)
                }
            }

            // 2. Account Selector
            Section {
                HStack {
                    Image(systemName: "person.crop.circle.fill")
                        .font(.title3)
                        .foregroundStyle(Color.accentColor)
                    Text("目标 Agent 账号")
                        .font(.system(size: 15, weight: .medium))
                    Spacer()
                    Picker("账号", selection: $selectedAccount) {
                        ForEach(availableAccounts, id: \.self) { acct in
                            Text(acct).tag(acct)
                        }
                    }
                    .pickerStyle(.menu)
                }
            } header: {
                Text("监控账号")
            } footer: {
                Text("由 Mac 桥接器直接对接本地 Antigravity 核心引擎，自动上报权威原生配额。")
            }

            // 3. Native Real-Time Quota & Reset Timers (原生精确配额与重置时间)
            Section {
                if let nativeQuota = currentNativeQuota {
                    nativeQuotaOverviewCard(nativeQuota)
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                        .listRowBackground(Color.clear)

                    // Models Grid/List (Gemini & GPT/Claude)
                    ForEach(nativeQuota.displayModels) { modelQuota in
                        nativeModelQuotaRow(modelQuota)
                    }

                    // Notification toggle
                    Toggle(isOn: $store.enableNativeNotifications) {
                        Label("额度恢复时自动发送系统推送", systemImage: "bell.badge.fill")
                            .font(.system(size: 14, weight: .medium))
                    }
                    .tint(.blue)
                    .padding(.vertical, 2)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "gauge.with.needle")
                            .font(.system(size: 32))
                            .foregroundStyle(.secondary)
                        Text("尚未获取到 \(selectedAccount) 的原生配额")
                            .font(.system(size: 15, weight: .semibold))
                        Text("请确保 Mac 本地 Antigravity 正在运行，且桥接器正常连接。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button {
                            refreshNativeQuota()
                        } label: {
                            if store.isFetchingNativeQuota {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Label("立即拉取原生配额", systemImage: "arrow.clockwise")
                                    .font(.system(size: 14, weight: .medium))
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .listRowBackground(Color.clear)
                }
            } header: {
                HStack {
                    Label("Antigravity 原生配额与恢复时间", systemImage: "speedometer")
                    Spacer()
                    Button {
                        refreshNativeQuota()
                    } label: {
                        HStack(spacing: 4) {
                            if store.isFetchingNativeQuota {
                                ProgressView()
                                    .controlSize(.mini)
                            } else {
                                Image(systemName: "arrow.clockwise")
                            }
                            Text("刷新")
                        }
                        .font(.caption2)
                    }
                }
            } footer: {
                if let nativeQuota = currentNativeQuota {
                    Text("最近同步：\(formattedUpdateTime(nativeQuota.updatedAt)) · 准确度 100%（官方 RPC 实时数据）")
                }
            }

            // 4. Conversation-detected Status & Active Timers (会话报错备用感应)
            if !currentAccountActiveReminders.isEmpty || store.activeReminders.contains(where: { $0.account == selectedAccount }) {
                Section {
                    ForEach(currentAccountActiveReminders) { reminder in
                        activeReminderCard(reminder)
                            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                            .listRowBackground(Color.clear)
                    }
                } header: {
                    HStack {
                        Text("会话 429 报错冷却倒计时")
                        Spacer()
                        Text("\(currentAccountActiveReminders.count) 个活跃")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // 5. Manual / Fallback Presets (备用手动快捷设定)
            Section {
                VStack(spacing: 12) {
                    quotaActionCard(
                        type: .fiveHours,
                        tagText: "5h 备用设定",
                        description: "适用于突发高频请求受限，准时在 5 小时后提醒。",
                        color: Color.blue,
                        systemImage: "bolt.hourglass.bottomhalf.fill"
                    ) {
                        schedule(type: .fiveHours)
                    }

                    quotaActionCard(
                        type: .oneWeek,
                        tagText: "1 week 备用设定",
                        description: "适用于整周累计配额耗尽，准时在 7 天后提醒。",
                        color: Color.purple,
                        systemImage: "calendar.badge.clock"
                    ) {
                        schedule(type: .oneWeek)
                    }

                    Button {
                        showCustomSheet = true
                    } label: {
                        HStack {
                            Image(systemName: "slider.horizontal.3")
                                .font(.system(size: 14, weight: .semibold))
                            Text("自定义时长（+1h、+2h、+3h、+24h 或自选）...")
                                .font(.system(size: 13, weight: .medium))
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 6)
                        .foregroundStyle(Color.secondary)
                    }
                }
                .padding(.vertical, 4)
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                .listRowBackground(Color.clear)
            } header: {
                Text("手动备用设定（可选）")
            } footer: {
                Text("平时原生配额会自动更新；此区域仅供手动快速设定或测试。")
            }

            // 6. History / Completed Section
            if !store.completedReminders.isEmpty {
                Section {
                    ForEach(store.completedReminders.filter { $0.account.lowercased() == selectedAccount.lowercased() }) { reminder in
                        HStack(spacing: 10) {
                            Image(systemName: "clock.arrow.circlepath")
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(reminder.account) · \(reminder.type.title)")
                                    .font(.system(size: 14, weight: .medium))
                                Text("重置于: \(reminder.formattedTargetTime)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("已重置")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.green)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color.green.opacity(0.12), in: Capsule())
                        }
                        .padding(.vertical, 2)
                    }
                } header: {
                    HStack {
                        Text("历史重置记录")
                        Spacer()
                        Button("清空") {
                            store.clearHistory()
                        }
                        .font(.caption)
                    }
                }
            }
        }
        .navigationTitle("额度重置提醒")
        .refreshable {
            await store.fetchNativeQuota(server: model.server, token: model.activeIdentity?.token, account: selectedAccount)
            store.scanAndSyncFromChatStore()
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        refreshNativeQuota()
                    } label: {
                        Label("立即同步原生额度", systemImage: "speedometer")
                    }

                    Button {
                        rescanConversations()
                    } label: {
                        Label("扫描对话记录", systemImage: "sparkles")
                    }

                    Button {
                        simulateQuotaError()
                    } label: {
                        Label("模拟收到 429 报错测试", systemImage: "bolt.badge.clock")
                    }

                    Button {
                        Task {
                            await store.triggerTestNotification()
                            showBanner("已发送测试通知，请留意 2 秒后的系统推送！")
                        }
                    } label: {
                        Label("发送测试推送", systemImage: "bell.badge")
                    }

                    Button {
                        Task {
                            _ = await store.requestNotificationPermission()
                        }
                    } label: {
                        Label("检查通知权限", systemImage: "gearshape")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 16, weight: .semibold))
                }
            }
        }
        .onAppear {
            if let curr = model.activeIdentity?.name, !curr.isEmpty {
                selectedAccount = curr
            }
            store.checkNotificationStatus()
            store.scanAndSyncFromChatStore()
            refreshNativeQuota()
        }
        .onChange(of: selectedAccount) { _ in
            refreshNativeQuota()
        }
        .sheet(isPresented: $showCustomSheet) {
            CustomDurationSheet(account: selectedAccount) { duration, note in
                Task {
                    await store.scheduleReminder(
                        account: selectedAccount,
                        type: .custom,
                        customDuration: duration,
                        note: note
                    )
                    showBanner("已为 \(selectedAccount) 启动自定义额度重置提醒！")
                }
            }
        }
        .overlay(alignment: .top) {
            if showToast {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(toastMessage)
                        .font(.system(size: 14, weight: .medium))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial, in: Capsule())
                .shadow(color: Color.black.opacity(0.12), radius: 8, y: 4)
                .padding(.top, 12)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }

    // MARK: - Native Quota UI Components (原生配额组件)

    private var currentNativeQuota: NativeAccountQuota? {
        store.nativeQuotas[selectedAccount] ?? store.nativeQuotas[selectedAccount.lowercased()]
    }

    @ViewBuilder
    private func nativeQuotaOverviewCard(_ quota: NativeAccountQuota) -> some View {
        let isExhausted = quota.isExhausted
        let isWarning = quota.isWarning
        let themeColor: Color = isExhausted ? .red : (isWarning ? .orange : .green)

        VStack(alignment: .leading, spacing: 12) {
            // Account Info & Tier
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "person.crop.circle.badge.checkmark")
                    .font(.system(size: 24))
                    .foregroundStyle(themeColor)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(quota.email ?? quota.name ?? quota.account)
                            .font(.system(size: 15, weight: .bold))
                            .lineLimit(1)

                        if let tier = quota.tier, !tier.isEmpty {
                            Text(tier)
                                .font(.system(size: 10, weight: .bold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.blue.opacity(0.15), in: Capsule())
                                .foregroundStyle(Color.blue)
                        }
                    }

                    Text("官方原生鉴权账号 · \(quota.account)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                // Health Badge
                Text(isExhausted ? "配额耗尽" : (isWarning ? "配额偏低" : "状态正常"))
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(themeColor.opacity(0.15), in: Capsule())
                    .foregroundStyle(themeColor)
            }

            Divider()

            // Lowest model or Earliest Reset
            if isExhausted, let lowest = quota.lowestModel, let resetTime = lowest.resetTime {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("受限模型恢复倒计时")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(lowest.formattedCountdown)
                            .font(.system(size: 26, weight: .heavy, design: .monospaced))
                            .foregroundStyle(.red)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("官方精确重置点")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(lowest.formattedResetTime)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.primary)
                    }
                }

                HStack(spacing: 4) {
                    Image(systemName: "bell.badge.fill")
                        .foregroundStyle(.blue)
                        .font(.caption2)
                    Text("到期重置时，iOS 将准时弹出系统通知。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("主模型可用配额")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        let lowestFraction = quota.lowestModel?.remainingPercentFormatted ?? "100.0%"
                        Text(lowestFraction)
                            .font(.system(size: 24, weight: .bold, design: .rounded))
                            .foregroundStyle(themeColor)
                    }
                    Spacer()
                    if let earliest = quota.earliestResetModel, earliest.timeRemaining > 0 {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("预计滚动恢复")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(earliest.formattedResetTime)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .padding(14)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(themeColor.opacity(0.3), lineWidth: 1.5)
        )
        .shadow(color: Color.black.opacity(0.04), radius: 6, y: 2)
    }

    @ViewBuilder
    private func nativeModelQuotaRow(_ model: NativeModelQuota) -> some View {
        let isEx = model.isExhausted
        let isWarn = model.isWarning
        let rowColor: Color = isEx ? .red : (isWarn ? .orange : .green)
        let isGemini = model.isGemini
        let iconName = model.groupIcon
        let iconColor: Color = isGemini ? .blue : .purple

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: iconName)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(iconColor)
                    .frame(width: 28, height: 28)
                    .background(iconColor.opacity(0.12), in: Circle())

                VStack(alignment: .leading, spacing: 1) {
                    Text(model.label)
                        .font(.system(size: 15, weight: .bold))
                        .lineLimit(1)
                    if let desc = model.description, !desc.isEmpty {
                        Text(desc)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 1) {
                    Text(model.remainingPercentFormatted)
                        .font(.system(size: 15, weight: .bold, design: .monospaced))
                        .foregroundStyle(rowColor)
                    Text(isEx ? "额度用尽" : (isWarn ? "偏低" : "充裕"))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(rowColor)
                }
            }

            ProgressView(value: model.remainingFraction)
                .tint(rowColor)
                .scaleEffect(x: 1, y: 1.3, anchor: .center)
                .padding(.vertical, 1)

            HStack {
                if let resetTime = model.resetTime, resetTime > Date() {
                    Text("重置时间: \(model.formattedResetTime)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("倒计时: \(model.formattedCountdown)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(rowColor)
                } else {
                    Text("配额状态稳定")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("随时可用")
                        .font(.caption2)
                        .foregroundStyle(.green)
                }
            }
        }
        .padding(.vertical, 6)
    }

    // MARK: - Legacy Active Reminders UI

    @ViewBuilder
    private func activeReminderCard(_ reminder: QuotaReminder) -> some View {
        let is5h = reminder.type == .fiveHours
        let themeColor: Color = is5h ? .blue : (reminder.type == .oneWeek ? .purple : .orange)

        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(reminder.type.title, systemImage: reminder.type.icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(themeColor)
                Spacer()
                Text(reminder.formattedTargetTime)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .firstTextBaseline) {
                Text(reminder.formattedRemaining)
                    .font(.system(size: 24, weight: .bold, design: .monospaced))
                    .foregroundStyle(themeColor)
                Spacer()
                Text("距离恢复")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            ProgressView(value: reminder.progress)
                .tint(themeColor)
        }
        .padding(12)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(themeColor.opacity(0.25), lineWidth: 1)
        )
    }

    // MARK: - Actions & Helpers

    private var availableAccounts: [String] {
        var list = model.accounts.map { $0.name }
        if !list.contains("antigravity-0") { list.append("antigravity-0") }
        if !list.contains("antigravity-1") { list.append("antigravity-1") }
        if !list.contains("codex-1") { list.append("codex-1") }
        return Array(Set(list)).sorted()
    }

    private var currentAccountActiveReminders: [QuotaReminder] {
        store.activeReminders.filter { $0.account.lowercased() == selectedAccount.lowercased() }
    }

    private func refreshNativeQuota() {
        Task {
            await store.fetchNativeQuota(server: model.server, token: model.activeIdentity?.token, account: selectedAccount)
            showBanner("已同步 \(selectedAccount) 原生配额！")
        }
    }

    private func rescanConversations() {
        store.scanAndSyncFromChatStore()
        showBanner("已重新扫描 \(chatStore.sessions.count) 场对话记录！")
    }

    private func simulateQuotaError() {
        let sid = chatStore.selectedSessionId
        let fakeMsg = ChatMessageItem(
            id: "fake_429_\(UUID().uuidString.prefix(6))",
            sessionId: sid,
            seq: 9999,
            replyTo: nil,
            sender: "agent",
            type: "text",
            status: "failed",
            content: "ResourceExhausted: 429 Quota exceeded for model Gemini/Codex. Your quota will reset in 5 hours.",
            toolName: nil,
            toolOutput: nil,
            createdAt: Date(),
            tokens: nil,
            duration: nil
        )
        chatStore.messagesBySession[sid, default: []].append(fakeMsg)
        store.scanAndSyncFromChatStore()
        showBanner("已模拟 429 报错消息，系统已自动读取并开启 5h 重置提醒！")
    }

    private func schedule(type: QuotaType) {
        Task {
            await store.scheduleReminder(account: selectedAccount, type: type)
            showBanner("已为 \(selectedAccount) 设定 \(type.title) 提醒！")
        }
    }

    private func showBanner(_ message: String) {
        toastMessage = message
        withAnimation(.spring()) {
            showToast = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            withAnimation(.spring()) {
                showToast = false
            }
        }
    }

    private func formattedUpdateTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            formatter.dateFormat = "今日 HH:mm:ss"
        } else {
            formatter.dateFormat = "M月d日 HH:mm:ss"
        }
        return formatter.string(from: date)
    }

    @ViewBuilder
    private func quotaActionCard(
        type: QuotaType,
        tagText: String,
        description: String,
        color: Color,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(color.opacity(0.12))
                        .frame(width: 42, height: 42)
                    Image(systemName: systemImage)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(color)
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(type.title)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.primary)

                        Text(tagText)
                            .font(.system(size: 11, weight: .bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(color.opacity(0.15), in: Capsule())
                            .foregroundStyle(color)
                    }

                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer()

                Image(systemName: "plus.circle.fill")
                    .font(.title3)
                    .foregroundStyle(color)
            }
            .padding(12)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(color.opacity(0.2), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Custom Duration Sheet

struct CustomDurationSheet: View {
    let account: String
    var onConfirm: (TimeInterval, String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedPresetHours: Int? = 5
    @State private var useExactTargetDate: Bool = false
    @State private var targetDate: Date = Date().addingTimeInterval(5 * 3600)
    @State private var note: String = ""

    private let presets: [(String, Int)] = [
        ("+1 小时", 1),
        ("+2 小时", 2),
        ("+3 小时", 3),
        ("+5 小时", 5),
        ("+12 小时", 12),
        ("+24 小时", 24),
        ("+7 天", 7 * 24)
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Text("目标账号")
                        Spacer()
                        Text(account)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }

                Section("快捷时长选择") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 80))], spacing: 10) {
                        ForEach(presets, id: \.1) { label, hours in
                            Button {
                                selectedPresetHours = hours
                                useExactTargetDate = false
                                targetDate = Date().addingTimeInterval(Double(hours) * 3600)
                            } label: {
                                Text(label)
                                    .font(.system(size: 13, weight: .medium))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 8)
                                    .background(selectedPresetHours == hours && !useExactTargetDate ? Color.accentColor : Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8))
                                    .foregroundStyle(selectedPresetHours == hours && !useExactTargetDate ? Color.white : Color.primary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section("精确重置日期与时间") {
                    Toggle("指定具体恢复时间点", isOn: $useExactTargetDate)
                        .onChange(of: useExactTargetDate) { isExact in
                            if isExact { selectedPresetHours = nil }
                        }

                    if useExactTargetDate {
                        DatePicker("目标恢复时间", selection: $targetDate, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                            .datePickerStyle(.graphical)
                    }
                }

                Section("备注说明（可选）") {
                    TextField("例如：因连续生图额度耗尽", text: $note)
                }
            }
            .navigationTitle("自选额度时长")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("确定启用") {
                        let duration: TimeInterval
                        if useExactTargetDate {
                            duration = max(60, targetDate.timeIntervalSince(Date()))
                        } else if let hours = selectedPresetHours {
                            duration = Double(hours) * 3600
                        } else {
                            duration = 5 * 3600
                        }
                        onConfirm(duration, note.isEmpty ? nil : note)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }
}
