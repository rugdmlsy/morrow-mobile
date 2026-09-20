import Foundation
import SwiftUI
import UIKit

struct WorkerSessionSettings {
    let pollTimeout: TimeInterval
    let heartbeatInterval: TimeInterval
}

enum WorkerClientError: LocalizedError {
    case invalidServer
    case invalidResponse
    case controller(String)
    case missingInvite
    case unsupportedUpgrade

    var errorDescription: String? {
        switch self {
        case .invalidServer: return "The controller URL is invalid."
        case .invalidResponse: return "The controller returned an invalid response."
        case .controller(let message): return message
        case .missingInvite: return "Enter a fresh LSM remote-worker invite code to pair this device."
        case .unsupportedUpgrade: return "The controller requested a Python worker upgrade, which is not valid for the native iOS worker."
        }
    }
}

@MainActor
struct LSMHTTPClient {
    func register(server: String, invite: String, name: String) async throws -> (WorkerIdentity, WorkerSessionSettings) {
        let payload: [String: Any] = [
            "invite": invite,
            "name": name,
            "workdir": "Documents/LSM",
            "capabilities": MobileActionExecutor.capabilities,
            "info": MobileActionExecutor.workerInfo(),
        ]
        let data = try await post(server: server, path: "/remote/register", payload: payload, token: nil, timeout: 30)
        guard let token = data["token"] as? String,
              let actualName = data["name"] as? String else {
            throw WorkerClientError.invalidResponse
        }
        return (
            WorkerIdentity(server: normalizeServer(server), name: actualName, token: token),
            settings(from: data)
        )
    }

    func resume(identity: WorkerIdentity) async throws -> WorkerSessionSettings {
        var payload: [String: Any] = [
            "workdir": "Documents/LSM",
            "capabilities": MobileActionExecutor.capabilities,
            "info": MobileActionExecutor.workerInfo(),
        ]
        let cleanName = identity.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanName.isEmpty && !cleanName.lowercased().hasPrefix("antigravity-") && !cleanName.lowercased().hasPrefix("codex-") {
            payload["name"] = cleanName
        }
        let data = try await post(
            server: identity.server,
            path: "/remote/resume",
            payload: payload,
            token: identity.token,
            timeout: 30
        )
        return settings(from: data)
    }

    func registerPushToken(identity: WorkerIdentity, token: String, environment: String) async throws {
        _ = try await post(
            server: identity.server,
            path: "/remote/push-token",
            payload: ["token": token, "environment": environment],
            token: identity.token,
            timeout: 15
        )
    }

    func poll(identity: WorkerIdentity, pollTimeout: TimeInterval) async throws -> [String: Any] {
        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
        let payload: [String: Any] = [
            "protocol_version": 2,
            "worker_version": "\(appVersion)-ios",
            "supports_self_update": false,
            "poll_timeout_s": min(max(pollTimeout, 5), 20),
            "info": MobileActionExecutor.resourceSnapshot(),
        ]
        return try await post(
            server: identity.server,
            path: "/remote/poll",
            payload: payload,
            token: identity.token,
            timeout: min(max(pollTimeout + 12, 20), 40)
        )
    }

    func heartbeat(identity: WorkerIdentity, jobID: String?) async throws -> [String: Any] {
        var payload: [String: Any] = ["info": MobileActionExecutor.resourceSnapshot()]
        if let jobID { payload["job_id"] = jobID }
        return try await post(
            server: identity.server,
            path: "/remote/heartbeat",
            payload: payload,
            token: identity.token,
            timeout: 15
        )
    }

    func submit(identity: WorkerIdentity, payload: [String: Any]) async throws {
        _ = try await post(
            server: identity.server,
            path: "/remote/result",
            payload: payload,
            token: identity.token,
            timeout: 30
        )
    }

    func acknowledgeEvents(identity: WorkerIdentity, ids: [String]) async throws {
        guard !ids.isEmpty else { return }
        _ = try await post(
            server: identity.server,
            path: "/remote/events-ack",
            payload: ["ids": ids],
            token: identity.token,
            timeout: 15
        )
    }

    func dashboard(identity: WorkerIdentity) async throws -> [String: Any] {
        try await post(
            server: identity.server,
            path: "/remote/mobile-dashboard",
            payload: [:],
            token: identity.token,
            timeout: 15
        )
    }

    private func settings(from data: [String: Any]) -> WorkerSessionSettings {
        WorkerSessionSettings(
            pollTimeout: (data["poll_timeout_s"] as? NSNumber)?.doubleValue ?? 20,
            heartbeatInterval: (data["heartbeat_interval_s"] as? NSNumber)?.doubleValue ?? 10
        )
    }

    private func post(
        server: String,
        path: String,
        payload: [String: Any],
        token: String?,
        timeout: TimeInterval
    ) async throws -> [String: Any] {
        let base = normalizeServer(server)
        guard let url = URL(string: base + path), let scheme = url.scheme, ["http", "https"].contains(scheme) else {
            throw WorkerClientError.invalidServer
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (body, response): (Data, URLResponse)
        do {
            (body, response) = try await URLSession.shared.data(for: request)
        } catch {
            if base.contains("mobile.xycdev.com"),
               let fallbackUrl = URL(string: base.replacingOccurrences(of: "mobile.xycdev.com", with: "mobile.51-79-159-224.sslip.io") + path) {
                var fbReq = request
                fbReq.url = fallbackUrl
                (body, response) = try await URLSession.shared.data(for: fbReq)
            } else {
                throw error
            }
        }

        guard let http = response as? HTTPURLResponse else {
            throw WorkerClientError.invalidResponse
        }
        let object = try JSONSerialization.jsonObject(with: body)
        guard let envelope = object as? [String: Any] else {
            throw WorkerClientError.invalidResponse
        }
        let message = envelope["message"] as? String ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
        guard (200..<300).contains(http.statusCode), envelope["ok"] as? Bool == true else {
            throw WorkerClientError.controller(message)
        }
        guard let data = envelope["data"] as? [String: Any] else {
            return [:]
        }
        return data
    }

    private func normalizeServer(_ value: String) -> String {
        var result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        while result.hasSuffix("/") { result.removeLast() }
        return result
    }
}

@MainActor
final class WorkerViewModel: ObservableObject {
    @Published var server: String
    @Published var workerName: String
    @Published var invite = ""
    @Published private(set) var status = "Disconnected"
    @Published private(set) var detail = ""
    @Published private(set) var connected = false
    @Published private(set) var paired = false
    @Published private(set) var lastAction = "None"

    @Published var accounts: [WorkerIdentity] = []
    @Published var activeIdentity: WorkerIdentity?

    private let http = LSMHTTPClient()
    let executor = MobileActionExecutor()
    private var identity: WorkerIdentity?
    private var connectionTask: Task<Void, Never>?
    private var sessionSettings = WorkerSessionSettings(pollTimeout: 20, heartbeatInterval: 10)

    init() {
        var savedServer = UserDefaults.standard.string(forKey: "controller.server") ?? "https://mobile.xycdev.com"
        if savedServer == "https://mcp.xycdev.com" {
            savedServer = "https://mobile.xycdev.com"
            UserDefaults.standard.set(savedServer, forKey: "controller.server")
        }
        server = savedServer
        workerName = UserDefaults.standard.string(forKey: "worker.name") ?? "morrow-iphone"
        reloadAccounts()
    }

    func reloadAccounts() {
        accounts = KeychainStore.loadAllIdentities()
        if let saved = KeychainStore.loadCurrentIdentity() {
            activeIdentity = saved
            identity = saved
            server = saved.server
            workerName = saved.name
            paired = true
            let acct = saved.name.isEmpty ? "antigravity-0" : saved.name
            if MobileChatStore.shared.currentAccount != acct {
                MobileChatStore.shared.switchAccount(server: saved.server, token: saved.token, account: acct)
            }
        } else {
            activeIdentity = nil
            identity = nil
            paired = false
        }
    }

    func switchToAccount(_ account: WorkerIdentity, force: Bool = false) {
        if !force && account.id == activeIdentity?.id && connected { return }
        disconnect()

        // 1. Persist new active identity to Keychain
        try? KeychainStore.switchIdentity(to: account)

        // 2. Update published state immediately
        activeIdentity = account
        identity = account
        server = account.server
        workerName = account.name
        paired = true

        UserDefaults.standard.set(account.server, forKey: "controller.server")
        UserDefaults.standard.set(account.name, forKey: "worker.name")

        // 3. Refresh accounts list
        accounts = KeychainStore.loadAllIdentities()

        // 4. Switch chat store to this account synchronously
        let acct = account.name.isEmpty ? "antigravity-0" : account.name
        MobileChatStore.shared.switchAccount(server: account.server, token: account.token, account: acct)

        // 5. Connect worker socket
        connect()

        // 6. Sync push registration in background
        Task {
            await WorkerBackgroundCoordinator.shared.syncPushRegistration(identity: account)
        }
    }

    func addOrSwitchProfile(name: String) {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { return }
        if let existing = accounts.first(where: { $0.name.lowercased() == cleanName.lowercased() }) {
            switchToAccount(existing, force: true)
            return
        }
        guard let current = activeIdentity ?? KeychainStore.loadCurrentIdentity() else { return }
        let newIdentity = WorkerIdentity(
            server: current.server,
            name: cleanName,
            token: current.token
        )
        try? KeychainStore.saveCurrentIdentity(newIdentity)
        accounts = KeychainStore.loadAllIdentities()
        switchToAccount(newIdentity, force: true)
    }

    func removeAccount(_ account: WorkerIdentity) {
        let wasActive = (activeIdentity?.id == account.id)
        if wasActive {
            disconnect()
        }
        let next = try? KeychainStore.removeIdentity(account)
        reloadAccounts()
        if wasActive {
            if let next {
                switchToAccount(next)
            } else {
                unpair()
            }
        }
    }

    func pairNewAccount(server: String, invite: String, name: String) async throws {
        disconnect()
        let cleanServer = server.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanInvite = invite.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanServer.isEmpty, !cleanInvite.isEmpty, !cleanName.isEmpty else {
            throw WorkerClientError.missingInvite
        }

        let result = try await http.register(server: cleanServer, invite: cleanInvite, name: cleanName)
        let newIdentity = result.0
        try persistIdentity(newIdentity)
        reloadAccounts()
        UserDefaults.standard.set(newIdentity.server, forKey: "controller.server")
        UserDefaults.standard.set(newIdentity.name, forKey: "worker.name")
        connect()
        await WorkerBackgroundCoordinator.shared.syncPushRegistration(identity: newIdentity)
        MobileChatStore.shared.switchAccount(server: newIdentity.server, token: newIdentity.token, account: newIdentity.name)
    }

    func startIfConfigured() {
        #if LSM_SHARE_EXTENSION
        importSharedInbox()
        #endif
        guard paired, connectionTask == nil else { return }
        connect()
    }

    func handleScenePhase(_ phase: ScenePhase) {
        if phase == .active {
            #if LSM_SHARE_EXTENSION
            importSharedInbox()
            #endif
            if paired, connectionTask == nil {
                connect()
            }
        }
    }

    func connect() {
        guard connectionTask == nil else { return }
        UserDefaults.standard.set(server, forKey: "controller.server")
        UserDefaults.standard.set(workerName, forKey: "worker.name")
        status = "Connecting"
        detail = ""
        connectionTask = Task { [weak self] in
            await self?.runConnectionLoop()
        }
    }

    func disconnect() {
        connectionTask?.cancel()
        connectionTask = nil
        connected = false
        WorkerStatusStore.recordConnected(false)
        status = "Disconnected"
        detail = "The app remains paired and will reconnect when requested."
    }

    func unpair() {
        disconnect()
        if let current = activeIdentity {
            _ = try? KeychainStore.removeIdentity(current)
        } else {
            KeychainStore.clear()
        }
        reloadAccounts()
        detail = "Pairing identity removed."
    }

    func requestNotificationPermission() async {
        do {
            let granted = try await executor.requestNotificationPermission()
            detail = granted ? "Notification permission granted." : "Notification permission was not granted."
        } catch {
            detail = error.localizedDescription
        }
    }

    func requestLocationPermission() {
        executor.requestLocationPermission()
        detail = "Location permission requested."
    }

    func requestCameraPermission() async {
        let granted = await executor.requestCameraPermission()
        detail = granted ? "Camera permission granted." : "Camera permission was not granted."
    }

    func requestPhotoPermission() async {
        let granted = await executor.requestPhotoPermission()
        detail = granted ? "Photo Library permission granted." : "Photo Library permission was not granted."
    }

    func refreshDashboard() async {
        guard let identity else {
            ControllerDashboardStore.shared.fail("Pair this iPhone with the LSM controller first.")
            return
        }
        ControllerDashboardStore.shared.beginLoading()
        do {
            ControllerDashboardStore.shared.apply(try await http.dashboard(identity: identity))
        } catch {
            ControllerDashboardStore.shared.fail(error.localizedDescription)
        }
    }

    #if LSM_SHARE_EXTENSION
    func importSharedInbox() {
        do {
            let result = try SharedInboxImporter.shared.importPending()
            let count = result["imported_count"] as? Int ?? 0
            if count > 0 {
                detail = "Imported \(count) shared package(s) into Documents/LSM/Shared."
            }
        } catch {
            detail = "Share import failed: \(error.localizedDescription)"
        }
    }
    #endif

    private func runConnectionLoop() async {
        defer {
            connectionTask = nil
            connected = false
            if Task.isCancelled { status = "Disconnected" }
        }

        do {
            if identity == nil {
                guard !invite.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw WorkerClientError.missingInvite
                }
                let result = try await http.register(server: server, invite: invite, name: workerName)
                identity = result.0
                activeIdentity = result.0
                sessionSettings = result.1
                try persistIdentity(result.0)
                paired = true
                workerName = result.0.name
                server = result.0.server
                invite = ""
                reloadAccounts()
                await WorkerBackgroundCoordinator.shared.syncPushRegistration(identity: result.0)
            } else if let identity {
                sessionSettings = try await http.resume(identity: identity)
                await WorkerBackgroundCoordinator.shared.syncPushRegistration(identity: identity)
            }

            connected = true
            WorkerStatusStore.recordConnected(true)
            status = "Online"
            detail = "Connected to LSM controller. Keep the app active for continuous polling."

            var retryDelay: UInt64 = 1
            while !Task.isCancelled {
                guard let identity else { return }
                do {
                    let payload = try await http.poll(identity: identity, pollTimeout: sessionSettings.pollTimeout)
                    if let timeout = (payload["poll_timeout_s"] as? NSNumber)?.doubleValue {
                        sessionSettings = WorkerSessionSettings(
                            pollTimeout: timeout,
                            heartbeatInterval: sessionSettings.heartbeatInterval
                        )
                    }
                    if let events = payload["events"] as? [[String: Any]], !events.isEmpty {
                        let ids = await MobileEventStore.shared.process(events)
                        if !ids.isEmpty {
                            try? await http.acknowledgeEvents(identity: identity, ids: ids)
                        }
                    }
                    if let upgrade = payload["upgrade"] as? [String: Any], upgrade["required"] as? Bool == true {
                        throw WorkerClientError.unsupportedUpgrade
                    }
                    if let job = payload["job"] as? [String: Any] {
                        try await handle(job: job, identity: identity)
                    }
                    retryDelay = 1
                    connected = true
                    WorkerStatusStore.recordConnected(true)
                    status = "Online"
                } catch is CancellationError {
                    return
                } catch {
                    connected = false
                    WorkerStatusStore.recordConnected(false)
                    status = "Reconnecting"
                    detail = error.localizedDescription
                    try? await Task.sleep(for: .seconds(Double(retryDelay)))
                    retryDelay = min(retryDelay * 2, 30)
                }
            }
        } catch {
            status = "Error"
            detail = error.localizedDescription
            connected = false
            WorkerStatusStore.recordConnected(false)
        }
    }

    private func handle(job: [String: Any], identity: WorkerIdentity) async throws {
        let runner = WorkerJobRunner(http: http, executor: executor)
        try await runner.handle(
            job: job,
            identity: identity,
            heartbeatInterval: sessionSettings.heartbeatInterval,
            onAction: { [weak self] action in self?.lastAction = action }
        )
    }

    private func persistIdentity(_ identity: WorkerIdentity) throws {
        try KeychainStore.saveCurrentIdentity(identity)
    }
}
