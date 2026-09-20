import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var model: WorkerViewModel
    @ObservedObject private var approvals = ApprovalPromptCoordinator.shared
    @ObservedObject private var scanner = CodeScannerCoordinator.shared
    @ObservedObject private var inbox = MobileInboxStore.shared
    @ObservedObject private var quotaStore = QuotaResetStore.shared
    @State private var showSettings = false

    var body: some View {
        TabView {
            ChatView(model: model)
                .tabItem {
                    Label("Chat", systemImage: "bubble.left.and.bubble.right.fill")
                }

            NavigationStack {
                WorkerHomeView(
                    model: model,
                    scanner: scanner,
                    showSettings: $showSettings
                )
            }
            .tabItem {
                Label("Worker", systemImage: "antenna.radiowaves.left.and.right")
            }

            NavigationStack {
                MobileDashboardView(model: model)
            }
            .tabItem {
                Label("Machines", systemImage: "desktopcomputer")
            }

            NavigationStack {
                MobileInboxView()
            }
            .tabItem {
                Label("Inbox", systemImage: "tray.full")
            }
            .badge(inbox.items.filter { !$0.read }.count)

            NavigationStack {
                QuotaResetView(model: model)
            }
            .tabItem {
                Label("额度", systemImage: "hourglass.badge.plus")
            }
            .badge(quotaStore.activeReminders.count + quotaStore.nativeQuotas.values.filter { $0.isExhausted }.count)
        }
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                WorkerSettingsView(model: model)
            }
        }
        .onAppear {
            Task {
                await quotaStore.fetchNativeQuota(server: model.server, token: model.activeIdentity?.token)
            }
            if UserDefaults.standard.bool(forKey: "mobile.intent.open_scanner") {
                UserDefaults.standard.removeObject(forKey: "mobile.intent.open_scanner")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    scanner.startLocalScan()
                }
            }
        }
        .sheet(isPresented: $scanner.presenting) {
            CodeScannerSheet(
                onScan: { value, type in scanner.record(value: value, type: type) },
                onCancel: { scanner.cancel() }
            )
            .ignoresSafeArea()
        }
        .sheet(isPresented: Binding(
            get: { approvals.request != nil },
            set: { presented in
                if !presented, approvals.request != nil { approvals.reject() }
            }
        )) {
            if let request = approvals.request {
                ApprovalPromptView(
                    request: request,
                    onApprove: { approvals.approve() },
                    onReject: { approvals.reject() }
                )
            }
        }
    }
}

private struct WorkerHomeView: View {
    @ObservedObject var model: WorkerViewModel
    @ObservedObject var scanner: CodeScannerCoordinator
    @Binding var showSettings: Bool
    @State private var showAccountSwitcher: Bool = false

    var body: some View {
        List {
            Section("Connection") {
                HStack(spacing: 12) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 10, height: 10)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.status)
                            .fontWeight(.medium)
                        if let active = model.activeIdentity {
                            Text("\(active.name) · \(active.displayServer)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer()

                    Button(model.connected ? "Disconnect" : "Connect") {
                        if model.connected {
                            model.disconnect()
                        } else {
                            model.connect()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(!model.connected && !canConnect)
                }

                Button {
                    showAccountSwitcher = true
                } label: {
                    HStack {
                        Label("切换账号", systemImage: "person.2.circle")
                        Spacer()
                        if model.accounts.count > 1 {
                            Text("\(model.accounts.count) 个账号")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            Section {
                DisclosureGroup {
                    NavigationLink {
                        LANProxyDiscoveryView()
                    } label: {
                        Label("LAN Proxy", systemImage: "network")
                    }

                    Button {
                        scanner.startLocalScan()
                    } label: {
                        Label("Scan QR / Barcode", systemImage: "qrcode.viewfinder")
                    }

                    if let scan = scanner.lastScan {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Last scan")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(scan.value)
                                .font(.footnote)
                                .lineLimit(3)
                        }
                    }

                    if !scanner.message.isEmpty {
                        Text(scanner.message)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    Text("Code scanning is always started locally. Remote actions can only read the last scan result.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } label: {
                    Label("Tools", systemImage: "wrench.and.screwdriver")
                }
            }
        }
        .navigationTitle("LSM Worker")
        .sheet(isPresented: $showAccountSwitcher) {
            AccountSwitcherView(model: model)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("Settings")
            }
        }
    }

    private var canConnect: Bool {
        !model.server.isEmpty
            && !model.workerName.isEmpty
            && (model.paired || !model.invite.isEmpty)
    }

    private var statusColor: Color {
        if model.connected { return .green }
        switch model.status.lowercased() {
        case "connecting", "reconnecting": return .yellow
        case "error": return .red
        default: return .secondary
        }
    }
}

private struct WorkerSettingsView: View {
    @ObservedObject var model: WorkerViewModel
    @ObservedObject private var externalFiles = ExternalFileAccessManager.shared
    @ObservedObject private var clipboard = MobileClipboardProvider.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showFilePicker = false
    @State private var showDirectoryPicker = false
    @State private var fileAccessMessage = ""
    @State private var showAddAccountSheet = false

    var body: some View {
        Form {
            Section("Accounts / 账号管理") {
                ForEach(model.accounts) { account in
                    let isActive = (account.name.lowercased() == (model.activeIdentity?.name ?? model.workerName).lowercased())
                    Button {
                        if !isActive {
                            model.switchToAccount(account)
                        }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(account.name)
                                        .font(.body)
                                        .foregroundStyle(Color.primary)
                                    if isActive {
                                        Text("当前")
                                            .font(.system(size: 11, weight: .bold))
                                            .foregroundStyle(Color.accentColor)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Color.accentColor.opacity(0.12))
                                            .clipShape(Capsule())
                                    }
                                }
                                Text(account.server)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if isActive {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Color.accentColor)
                                    .font(.subheadline.bold())
                            }
                        }
                    }
                }
                .onDelete { indexSet in
                    for idx in indexSet {
                        model.removeAccount(model.accounts[idx])
                    }
                }

                Button {
                    showAddAccountSheet = true
                } label: {
                    Label("添加新账号", systemImage: "plus.circle")
                }
            }

            Section("Connection") {
                TextField("Controller", text: $model.server)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .disabled(model.paired)

                TextField("Worker name", text: $model.workerName)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .disabled(model.paired)

                if !model.paired {
                    SecureField("Invite code", text: $model.invite)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                if !model.detail.isEmpty {
                    Text(model.detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if model.paired {
                    Button("Unpair Device", role: .destructive) {
                        model.unpair()
                    }
                }
            }

            Section("Permissions") {
                Button("Allow Notifications") {
                    Task { await model.requestNotificationPermission() }
                }
                Button("Allow Location While Using App") {
                    model.requestLocationPermission()
                }
                Button("Allow Camera") {
                    Task { await model.requestCameraPermission() }
                }
                Button("Allow Photo Library") {
                    Task { await model.requestPhotoPermission() }
                }
                Text("Remote commands never trigger a new iOS privacy prompt. Grant permissions here first, then LSM may use only the capabilities you enabled.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Files & Clipboard") {
                Button("Grant Access to File") { showFilePicker = true }
                Button("Grant Access to Folder") { showDirectoryPicker = true }

                if externalFiles.bookmarks.isEmpty {
                    Text("No external Files access has been granted.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(externalFiles.bookmarks) { bookmark in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(bookmark.name)
                                Text(bookmark.isDirectory ? "Folder" : "File")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(role: .destructive) {
                                externalFiles.remove(id: bookmark.id)
                            } label: {
                                Image(systemName: "trash")
                            }
                        }
                    }
                }

                Toggle("Allow Remote Clipboard Read", isOn: $clipboard.remoteReadEnabled)
                Text("File/folder selection can only be initiated here. Remote actions may use only bookmarks you granted. Clipboard writes are allowed; reads require this switch and the app foreground, and iOS may still show its paste privacy UI.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                if !fileAccessMessage.isEmpty {
                    Text(fileAccessMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Mobile Capabilities") {
                capability("Device information", detail: "Model, iOS version, CPU/memory summary")
                capability("Battery", detail: "Charge state, percentage, Low Power Mode")
                capability("Notifications", detail: "Post a local notification after permission")
                capability("Location", detail: "One-shot location while the app is permitted to access it")
                capability("Open URL", detail: "Foreground only")
                capability("Sandbox files", detail: "Documents/LSM, visible in Files")
                capability("Binary transfer", detail: "Stream sandbox files/images through LSM transfer tickets")
                capability("Camera", detail: "Foreground still capture after explicit camera permission")
                capability("Photos", detail: "List/export permitted Photo Library assets into the sandbox")
                capability("Mobile network probe", detail: "Path history plus bounded public DNS/TCP/TLS/HTTP probes")
                capability("External Files", detail: "Import/export only through files or folders explicitly selected in this app")
                capability("Clipboard", detail: "Remote write; foreground read only after explicit local opt-in")
                capability("Device status", detail: "Storage, thermal state, display, locale, uptime, battery and power state")
                capability("Motion sensors", detail: "Bounded foreground accelerometer, gyro, magnetometer and attitude snapshot")
                capability("QR / barcode scanner", detail: "Local-user initiated camera scan; remote side can only read the last scan")
                capability("Mobile inbox", detail: "Receive text, URL and sandbox-file handoffs from LSM")
                capability("Controller dashboard", detail: "Read-only machine status and active-job overview")
                #if LSM_SHARE_EXTENSION
                capability("Share Extension", detail: "Send files, images, PDFs, URLs, or text from the iOS share sheet into Documents/LSM/Shared")
                #endif
                capability("Background wake", detail: "APNs + BGAppRefresh best effort; iOS still controls execution")
                capability("Shortcuts", detail: "Check In, Status, Open, Inbox, Controller and Scanner App Intents")
                capability("Approval terminal", detail: "Foreground approve/reject prompts for controller actions; the phone returns only the decision")
            }

            Section("Runtime") {
                LabeledContent("Last action", value: model.lastAction)
                LabeledContent("Worker protocol", value: "LSM poll v2")
                LabeledContent("Background model", value: "APNs + BGAppRefresh")
                Text("iOS may still suspend this app or throttle silent pushes. Background wake is best effort and bounded; the worker automatically reconnects when the app becomes active again and is not a 24/7 daemon like a Mac or Linux worker.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
        .sheet(isPresented: $showAddAccountSheet) {
            AddAccountSheet(model: model)
        }
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [.item],
            allowsMultipleSelection: false
        ) { result in
            handleFileSelection(result)
        }
        .fileImporter(
            isPresented: $showDirectoryPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            handleFileSelection(result)
        }
    }

    private func handleFileSelection(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            try externalFiles.add(url: url)
            fileAccessMessage = "Granted access to \(url.lastPathComponent)."
        } catch {
            fileAccessMessage = error.localizedDescription
        }
    }

    @ViewBuilder
    private func capability(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Multi-Account Management Views

struct AccountSwitcherView: View {
    @ObservedObject var model: WorkerViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showAddSheet = false
    @State private var accountToDelete: WorkerIdentity? = nil

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(model.accounts) { account in
                        let isActive = (account.name.lowercased() == (model.activeIdentity?.name ?? model.workerName).lowercased())
                        Button {
                            if !isActive {
                                model.switchToAccount(account)
                            }
                            dismiss()
                        } label: {
                            HStack(spacing: 14) {
                                ZStack {
                                    Circle()
                                        .fill(isActive ? Color.accentColor.opacity(0.15) : Color(uiColor: .tertiarySystemFill))
                                        .frame(width: 44, height: 44)
                                    Image(systemName: account.agentIcon)
                                        .font(.system(size: 20))
                                        .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
                                }

                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 6) {
                                        Text(account.agentDisplayName)
                                            .font(.system(size: 16, weight: .semibold))
                                            .foregroundStyle(Color.primary)
                                        if isActive {
                                            Text("当前")
                                                .font(.system(size: 11, weight: .bold))
                                                .foregroundStyle(Color.accentColor)
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(Color.accentColor.opacity(0.12))
                                                .clipShape(Capsule())
                                        }
                                    }

                                    HStack(spacing: 6) {
                                        Circle()
                                            .fill(isActive && model.connected ? Color.green : (isActive ? Color.orange : Color.secondary.opacity(0.4)))
                                            .frame(width: 6, height: 6)
                                        Text(account.server)
                                            .font(.system(size: 13))
                                            .foregroundStyle(Color.secondary)
                                            .lineLimit(1)
                                    }
                                }

                                Spacer()

                                if isActive {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 14, weight: .bold))
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                accountToDelete = account
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                    }
                } header: {
                    Text("已配置的 Agent 账号")
                } footer: {
                    Text("点击任意账号即可无缝切换连接并同步对应的历史记录与对话数据。左滑可删除历史账号。")
                }

                Section {
                    Button {
                        model.addOrSwitchProfile(name: "antigravity-0")
                        dismiss()
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "atom")
                                .font(.system(size: 18))
                                .foregroundStyle(Color.purple)
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("antigravity-0")
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundStyle(Color.primary)
                                Text("MacBook 原版默认环境 (~/.gemini)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "arrow.right.circle")
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }

                    Button {
                        model.addOrSwitchProfile(name: "antigravity-1")
                        dismiss()
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "atom")
                                .font(.system(size: 18))
                                .foregroundStyle(Color.blue)
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("antigravity-1")
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundStyle(Color.primary)
                                Text("MacBook Personal 隔离环境 (~/.antigravity-personal)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "arrow.right.circle")
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }

                    Button {
                        model.addOrSwitchProfile(name: "codex-1")
                        dismiss()
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "chevron.left.forwardslash.chevron.right")
                                .font(.system(size: 16))
                                .foregroundStyle(Color.green)
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("codex-1")
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundStyle(Color.primary)
                                Text("Codex Agent 环境")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "arrow.right.circle")
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                } header: {
                    Text("快捷切换 / 添加 Agent 账号")
                } footer: {
                    Text("在同级直接切换不同 Agent 与账号（antigravity-0 / antigravity-1 / codex），聊天历史完全隔离存储。")
                }

                Section {
                    Button {
                        showAddSheet = true
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "plus.circle.fill")
                                .font(.system(size: 20))
                                .foregroundStyle(Color.accentColor)
                            Text("添加新控制器 / 服务器...")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(Color.accentColor)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            .navigationTitle("切换账号")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showAddSheet = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 16, weight: .semibold))
                    }
                }
            }
            .onAppear {
                model.reloadAccounts()
                Task {
                    await MobileChatStore.shared.fetchProjectConversations(server: model.server, token: model.activeIdentity?.token)
                }
            }
            .sheet(isPresented: $showAddSheet) {
                AddAccountSheet(model: model)
            }
            .alert("删除账号", isPresented: Binding(
                get: { accountToDelete != nil },
                set: { if !$0 { accountToDelete = nil } }
            )) {
                Button("取消", role: .cancel) { accountToDelete = nil }
                Button("删除", role: .destructive) {
                    if let acc = accountToDelete {
                        model.removeAccount(acc)
                    }
                    accountToDelete = nil
                }
            } message: {
                Text("确定要删除此账号吗？此设备的配对密钥将从 Keychain 移除。")
            }
        }
    }
}

struct AddAccountSheet: View {
    @ObservedObject var model: WorkerViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var server: String = "https://mobile.xycdev.com"
    @State private var workerName: String = "morrow-iphone"
    @State private var invite: String = ""
    @State private var isPairing: Bool = false
    @State private var errorMessage: String? = nil

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://...", text: $server)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                } header: {
                    Text("控制器地址 (Controller URL)")
                } footer: {
                    Text("输入运行 LSM 控制器的中继或 Mac 本地服务地址。")
                }

                Section {
                    TextField("设备 / 账号名称", text: $workerName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    HStack(spacing: 8) {
                        Button("antigravity-0") { workerName = "antigravity-0" }
                            .buttonStyle(.bordered)
                            .font(.caption)
                        Button("antigravity-1") { workerName = "antigravity-1" }
                            .buttonStyle(.bordered)
                            .font(.caption)
                        Button("codex-1") { workerName = "codex-1" }
                            .buttonStyle(.bordered)
                            .font(.caption)
                    }
                } header: {
                    Text("本设备 / Agent 账号名称")
                } footer: {
                    Text("可快速选择填入常用 Agent 标识。")
                }

                Section {
                    SecureField("输入配对邀请码", text: $invite)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("配对邀请码 (Invite Code)")
                } footer: {
                    Text("在电脑端终端运行 LSM 生成邀请码后粘贴至此处。")
                }

                if let err = errorMessage {
                    Section {
                        Text(err)
                            .font(.footnote)
                            .foregroundStyle(Color.red)
                    }
                }

                Section {
                    Button {
                        Task {
                            await pair()
                        }
                    } label: {
                        HStack {
                            Spacer()
                            if isPairing {
                                ProgressView()
                                    .padding(.trailing, 8)
                                Text("正在配对并连接...")
                                    .fontWeight(.semibold)
                            } else {
                                Text("配对并切换至此账号")
                                    .fontWeight(.semibold)
                            }
                            Spacer()
                        }
                    }
                    .disabled(isPairing || server.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || invite.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .navigationTitle("添加账号")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        dismiss()
                    }
                    .disabled(isPairing)
                }
            }
        }
    }

    private func pair() async {
        isPairing = true
        errorMessage = nil
        do {
            try await model.pairNewAccount(
                server: server,
                invite: invite,
                name: workerName
            )
            isPairing = false
            dismiss()
        } catch {
            isPairing = false
            errorMessage = error.localizedDescription
        }
    }
}
