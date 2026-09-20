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
            // 1. Notification Permission Notice (if not granted)
            if !store.notificationAuthorized {
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: "bell.badge.slash.fill")
                            .font(.title2)
                            .foregroundStyle(Color.orange)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("未开启系统通知权限")
                                .font(.system(size: 15, weight: .semibold))
                            Text("开启后，当模型配额到期重置时，即使锁屏也会收到本地推送。")
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
                            Text(accountDisplayName(acct)).tag(acct)
                        }
                    }
                    .pickerStyle(.menu)
                }
            } header: {
                Text("选择账号")
            }

            // 3. User Info Overview Card
            if let nativeQuota = currentNativeQuota {
                Section {
                    accountOverviewCard(nativeQuota)
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                        .listRowBackground(Color.clear)
                }
            }

            // 4. Two Model Quota Cards: Gemini & GPT/Claude
            Section {
                if let nativeQuota = currentNativeQuota, !nativeQuota.displayModels.isEmpty {
                    ForEach(nativeQuota.displayModels) { modelQuota in
                        modelQuotaCard(modelQuota)
                            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                            .listRowBackground(Color.clear)
                    }
                } else {
                    emptyQuotaStateView
                }
            } header: {
                HStack {
                    Text("模型额度与重置时间")
                    Spacer()
                    if store.isFetchingNativeQuota {
                        ProgressView()
                            .controlSize(.mini)
                    }
                }
            } footer: {
                if let nativeQuota = currentNativeQuota {
                    Text("最近同步：\(formattedUpdateTime(nativeQuota.updatedAt)) · 准确度 100%（官方 RPC 实时数据）")
                } else {
                    Text("由 Mac 本地 Antigravity 核心引擎自动上报，无需手动计算。")
                }
            }

            // 5. Notification Settings & Actions
            Section {
                Toggle(isOn: $store.enableNativeNotifications) {
                    Label("额度恢复时自动发送系统推送", systemImage: "bell.badge.fill")
                        .font(.system(size: 15, weight: .medium))
                }
                .tint(.blue)
                .padding(.vertical, 2)

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
                Text("通知与同步")
            }
        }
        .navigationTitle("额度重置监控")
        .refreshable {
            await store.fetchNativeQuota(server: model.server, token: model.activeIdentity?.token, account: selectedAccount)
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

    // MARK: - Subviews

    private var emptyQuotaStateView: some View {
        VStack(spacing: 12) {
            Image(systemName: "gauge.with.needle")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text("尚未获取到 \(selectedAccount) 的原生配额")
                .font(.system(size: 15, weight: .semibold))
            Text("请确保 Mac 本地 Antigravity 正在运行，且桥接服务已启动。")
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
        .padding(.vertical, 20)
        .listRowBackground(Color.clear)
    }

    @ViewBuilder
    private func accountOverviewCard(_ quota: NativeAccountQuota) -> some View {
        let isExhausted = quota.isExhausted
        let isWarning = quota.isWarning
        let themeColor: Color = isExhausted ? .red : (isWarning ? .orange : .green)

        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(themeColor.opacity(0.15))
                    .frame(width: 44, height: 44)
                Image(systemName: "person.crop.circle.badge.checkmark")
                    .font(.system(size: 22))
                    .foregroundStyle(themeColor)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(quota.email ?? quota.name ?? quota.account)
                        .font(.system(size: 15, weight: .bold))
                        .lineLimit(1)

                    if let tier = quota.tier, !tier.isEmpty {
                        Text(tier)
                            .font(.system(size: 10, weight: .bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.blue.opacity(0.12), in: Capsule())
                            .foregroundStyle(Color.blue)
                    }
                }

                Text(quota.account == "antigravity-0" ? "工作主账号 (Work)" : "个人独立账号 (Personal)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(isExhausted ? "配额耗尽" : (isWarning ? "配额偏低" : "状态良好"))
                .font(.caption2.weight(.bold))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(themeColor.opacity(0.12), in: Capsule())
                .foregroundStyle(themeColor)
        }
        .padding(14)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
        .shadow(color: Color.black.opacity(0.03), radius: 4, y: 1)
    }

    @ViewBuilder
    private func modelQuotaCard(_ model: NativeModelQuota) -> some View {
        let isEx = model.isExhausted
        let isWarn = model.isWarning
        let statusColor: Color = isEx ? .red : (isWarn ? .orange : .green)
        let isGemini = model.isGemini
        let iconName = model.groupIcon
        let iconColor: Color = isGemini ? .blue : .purple

        VStack(alignment: .leading, spacing: 10) {
            // Header: Icon + Title + Percent
            HStack(spacing: 10) {
                Image(systemName: iconName)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(iconColor)
                    .frame(width: 32, height: 32)
                    .background(iconColor.opacity(0.12), in: Circle())

                VStack(alignment: .leading, spacing: 2) {
                    Text(model.label)
                        .font(.system(size: 16, weight: .bold))
                    if let desc = model.description, !desc.isEmpty {
                        Text(desc)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text(model.remainingPercentFormatted)
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundStyle(statusColor)

                    Text(isEx ? "配额已用尽" : (isWarn ? "余量偏低" : "余量充足"))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(statusColor)
                }
            }

            // Progress Bar
            ProgressView(value: min(1.0, max(0.0, model.remainingFraction)))
                .tint(statusColor)
                .scaleEffect(x: 1, y: 1.4, anchor: .center)
                .padding(.vertical, 2)

            // Reset Info / Live Countdown
            HStack(alignment: .center) {
                if let resetTime = model.resetTime, resetTime > Date(), model.remainingFraction < 0.99 {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("重置时间: \(model.formattedResetTime)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    HStack(spacing: 4) {
                        Image(systemName: "timer")
                            .font(.caption2)
                        Text(model.formattedCountdown)
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(statusColor.opacity(0.12), in: Capsule())
                    .foregroundStyle(statusColor)
                } else {
                    Text("当前额度充足，随时可调用")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    Spacer()

                    Text("可正常使用")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.green)
                }
            }
        }
        .padding(14)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(statusColor.opacity(isEx ? 0.4 : 0.15), lineWidth: isEx ? 1.5 : 1)
        )
        .shadow(color: Color.black.opacity(0.03), radius: 4, y: 1)
    }

    // MARK: - Helpers

    private var availableAccounts: [String] {
        var set = Set(model.accounts.map { $0.name })
        set.formUnion(store.nativeQuotas.keys)
        set.insert("antigravity-0")
        set.insert("antigravity-1")
        return Array(set).filter { !$0.isEmpty }.sorted()
    }

    private var currentNativeQuota: NativeAccountQuota? {
        store.nativeQuotas[selectedAccount] ?? store.nativeQuotas[selectedAccount.lowercased()]
    }

    private func accountDisplayName(_ acct: String) -> String {
        if let q = store.nativeQuotas[acct], let email = q.email, !email.isEmpty {
            return "\(acct) (\(email))"
        }
        if acct == "antigravity-0" { return "antigravity-0 (Work)" }
        if acct == "antigravity-1" { return "antigravity-1 (Personal)" }
        return acct
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
