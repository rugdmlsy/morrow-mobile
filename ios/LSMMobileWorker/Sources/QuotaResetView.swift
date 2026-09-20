import SwiftUI
import UserNotifications

struct QuotaResetView: View {
    @ObservedObject var model: WorkerViewModel
    @ObservedObject private var store = QuotaResetStore.shared
    @ObservedObject private var chatStore = MobileChatStore.shared

    @State private var selectedAccount: String = "antigravity-0"
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
                    emptyQuotaStateView
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

            // 4. Notification & Testing
            Section {
                Button {
                    Task {
                        await store.triggerTestNotification()
                        showBanner("已发送测试通知，请留意 2 秒后的系统推送！")
                    }
                } label: {
                    HStack {
                        Label("发送测试推送通知", systemImage: "paperplane.fill")
                            .font(.system(size: 14, weight: .medium))
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .foregroundStyle(.primary)

                Button {
                    refreshNativeQuota()
                } label: {
                    HStack {
                        Label("立即从 Mac 重新拉取配额", systemImage: "arrow.clockwise")
                            .font(.system(size: 14, weight: .medium))
                        Spacer()
                    }
                }
                .foregroundStyle(.blue)
            } header: {
                Text("通知与测试")
            }
        }
        .navigationTitle("额度重置提醒")
        .refreshable {
            await store.fetchNativeQuota(server: model.server, token: model.activeIdentity?.token, account: selectedAccount)
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
            refreshNativeQuota()
        }
        .onChange(of: selectedAccount) { _ in
            refreshNativeQuota()
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

    private var emptyQuotaStateView: some View {
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

    @ViewBuilder
    private func nativeQuotaOverviewCard(_ quota: NativeAccountQuota) -> some View {
        let isExhausted = quota.isExhausted
        let isWarning = quota.isWarning
        let themeColor: Color = isExhausted ? .red : (isWarning ? .orange : .green)

        VStack(alignment: .leading, spacing: 12) {
            // Account Info & Tier (Original clean icon & layout)
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

    // MARK: - Helpers

    private var availableAccounts: [String] {
        var set = Set(model.accounts.map { $0.name })
        set.formUnion(store.nativeQuotas.keys)
        set.insert("antigravity-0")
        set.insert("antigravity-1")
        return Array(set).filter { !$0.isEmpty }.sorted()
    }

    private func refreshNativeQuota() {
        Task {
            await store.fetchNativeQuota(server: model.server, token: model.activeIdentity?.token, account: selectedAccount)
            showBanner("已同步 \(selectedAccount) 原生配额！")
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
}
