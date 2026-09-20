import SwiftUI
import UserNotifications

struct QuotaResetView: View {
    @ObservedObject var model: WorkerViewModel
    @ObservedObject private var store = QuotaResetStore.shared

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

            // 2. Account Selector Section
            Section {
                HStack {
                    Image(systemName: "person.crop.circle.fill")
                        .font(.title3)
                        .foregroundStyle(Color.accentColor)
                    Text("当前目标账号")
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
                Text("可单独为不同 Agent 账号设定重置提醒。")
            }

            // 3. Quick Action Presets (5h & 1w)
            Section {
                VStack(spacing: 12) {
                    // 5 Hours Card
                    quotaActionCard(
                        type: .fiveHours,
                        tagText: "5h 突发限制",
                        description: "适用于短时间高频请求受限，5小时后准时提醒。",
                        color: Color.blue,
                        systemImage: "bolt.hourglass.bottomhalf.fill"
                    ) {
                        schedule(type: .fiveHours)
                    }

                    // 1 Week Card
                    quotaActionCard(
                        type: .oneWeek,
                        tagText: "1 week 周度预算",
                        description: "适用于周期性总配额耗尽，7天后准时提醒。",
                        color: Color.purple,
                        systemImage: "calendar.badge.clock"
                    ) {
                        schedule(type: .oneWeek)
                    }

                    // Custom Option Button
                    Button {
                        showCustomSheet = true
                    } label: {
                        HStack {
                            Image(systemName: "slider.horizontal.3")
                                .font(.system(size: 14, weight: .semibold))
                            Text("自选其他时长（+1h、+2h、+3h、+24h 或自选）...")
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
                Text("快捷设定额度重置提醒")
            }

            // 4. Active Timers Section
            Section {
                if store.activeReminders.isEmpty {
                    HStack(spacing: 12) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.green)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("暂无冷却中的额度")
                                .font(.system(size: 15, weight: .medium))
                            Text("所有 Agent 额度均正常，或未设定重置倒计时。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 8)
                } else {
                    ForEach(store.activeReminders) { reminder in
                        activeReminderCard(reminder)
                            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                            .listRowBackground(Color.clear)
                    }
                }
            } header: {
                HStack {
                    Text("进行中的额度冷却倒计时")
                    Spacer()
                    if !store.activeReminders.isEmpty {
                        Text("\(store.activeReminders.count) 个活跃")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // 5. History / Completed Section
            if !store.completedReminders.isEmpty {
                Section {
                    ForEach(store.completedReminders) { reminder in
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
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
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
            store.refreshState()
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

    private var availableAccounts: [String] {
        var list = model.accounts.map { $0.name }
        if !list.contains("antigravity-0") { list.append("antigravity-0") }
        if !list.contains("antigravity-1") { list.append("antigravity-1") }
        if !list.contains("codex-1") { list.append("codex-1") }
        return Array(Set(list)).sorted()
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

    @ViewBuilder
    private func quotaActionCard(
        type: QuotaType,
        tagText: String,
        description: String,
        color: Color,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(color)
                    .frame(width: 32, height: 32)
                    .background(color.opacity(0.12), in: Circle())

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(type.title)
                            .font(.system(size: 16, weight: .semibold))
                        Text(tagText)
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(color)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(color.opacity(0.15), in: Capsule())
                    }
                    Text(description)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
            }

            Button(action: action) {
                HStack {
                    Spacer()
                    Image(systemName: "bell.badge.fill")
                        .font(.caption)
                    Text("设定 \(type.shortTag) 重置提醒")
                        .font(.system(size: 14, weight: .semibold))
                    Spacer()
                }
                .padding(.vertical, 8)
                .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
                .foregroundStyle(color)
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(color.opacity(0.2), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func activeReminderCard(_ reminder: QuotaReminder) -> some View {
        let is5h = reminder.type == .fiveHours
        let themeColor: Color = is5h ? .blue : (reminder.type == .oneWeek ? .purple : .orange)

        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Image(systemName: reminder.type.icon)
                            .foregroundStyle(themeColor)
                        Text(reminder.type.title)
                            .font(.system(size: 16, weight: .bold))
                        Text(reminder.account)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.15), in: Capsule())
                    }

                    if let note = reminder.note, !note.isEmpty {
                        Text(note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button(role: .destructive) {
                    store.cancelReminder(id: reminder.id)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary.opacity(0.6))
                }
                .buttonStyle(.plain)
            }

            // Big Countdown Display
            HStack(alignment: .firstTextBaseline) {
                Text(reminder.formattedRemaining)
                    .font(.system(size: 28, weight: .heavy, design: .monospaced))
                    .foregroundStyle(themeColor)
                Spacer()
                Text("预计恢复")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(reminder.formattedTargetTime)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.primary)
            }

            // Progress Bar
            ProgressView(value: reminder.progress)
                .tint(themeColor)
                .scaleEffect(x: 1, y: 1.5, anchor: .center)
        }
        .padding(14)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(themeColor.opacity(0.25), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.04), radius: 6, y: 2)
    }
}

struct CustomDurationSheet: View {
    let account: String
    let onSchedule: (TimeInterval, String?) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var selectedPresetHours: Double = 3.0
    @State private var note: String = ""
    @State private var useExactDatePicker: Bool = false
    @State private var exactDate: Date = Date().addingTimeInterval(3600 * 3)

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Text("目标账号")
                        Spacer()
                        Text(account)
                            .foregroundStyle(.secondary)
                            .fontWeight(.semibold)
                    }
                }

                Section("预设快捷时长") {
                    HStack(spacing: 8) {
                        presetButton(label: "+1 小时", hours: 1.0)
                        presetButton(label: "+2 小时", hours: 2.0)
                        presetButton(label: "+3 小时", hours: 3.0)
                        presetButton(label: "+12 小时", hours: 12.0)
                        presetButton(label: "+24 小时", hours: 24.0)
                    }
                    .padding(.vertical, 2)
                }

                Section("或自定义时间") {
                    Toggle("选择精确到期时间点", isOn: $useExactDatePicker)

                    if useExactDatePicker {
                        DatePicker("到期时间", selection: $exactDate, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                            .datePickerStyle(.graphical)
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("时长: \(String(format: "%.1f", selectedPresetHours)) 小时")
                                .font(.system(size: 15, weight: .medium))
                            Slider(value: $selectedPresetHours, in: 0.5...48.0, step: 0.5)
                        }
                        .padding(.vertical, 4)
                    }
                }

                Section("备注说明 (可选)") {
                    TextField("如：等待深夜重置 / 尝试切换模型", text: $note)
                }

                Section {
                    Button {
                        let duration: TimeInterval
                        if useExactDatePicker {
                            duration = max(60, exactDate.timeIntervalSince(Date()))
                        } else {
                            duration = selectedPresetHours * 3600
                        }
                        onSchedule(duration, note.isEmpty ? nil : note)
                        dismiss()
                    } label: {
                        HStack {
                            Spacer()
                            Text("确认并启动提醒")
                                .fontWeight(.semibold)
                            Spacer()
                        }
                    }
                }
            }
            .navigationTitle("自定义额度时长")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func presetButton(label: String, hours: Double) -> some View {
        Button {
            selectedPresetHours = hours
            useExactDatePicker = false
        } label: {
            Text(label)
                .font(.system(size: 11, weight: selectedPresetHours == hours && !useExactDatePicker ? .bold : .regular))
                .padding(.horizontal, 6)
                .padding(.vertical, 6)
                .background(selectedPresetHours == hours && !useExactDatePicker ? Color.accentColor : Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8))
                .foregroundStyle(selectedPresetHours == hours && !useExactDatePicker ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
    }
}
