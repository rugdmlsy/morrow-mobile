import Foundation
import Security

enum KeychainStore {
    private static let service = "com.xycdev.lsmmobileworker"
    private static let account = "worker-identity"
    private static let listAccount = "worker-identities-list"

    static func save(_ data: Data) throws {
        try saveRaw(data, account: account)
        if let id = try? JSONDecoder().decode(WorkerIdentity.self, from: data) {
            var list = loadAllIdentities()
            if let idx = list.firstIndex(where: { $0.id == id.id }) {
                list[idx] = id
            } else {
                list.append(id)
            }
            try? saveAllIdentities(list)
        }
    }

    static func load() throws -> Data? {
        try loadRaw(account: account)
    }

    static func clear() {
        clearRaw(account: account)
    }

    private static func saveRaw(_ data: Data, account key: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)

        var insert = query
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(insert as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    private static func loadRaw(account key: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = item as? Data else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        return data
    }

    private static func clearRaw(account key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - Multi-Account Management

    static func loadAllIdentities() -> [WorkerIdentity] {
        var rawList: [WorkerIdentity] = []
        if let listData = try? loadRaw(account: listAccount),
           let savedList = try? JSONDecoder().decode([WorkerIdentity].self, from: listData) {
            rawList = savedList
        }

        let current = loadCurrentIdentity()
        if let current {
            rawList.insert(current, at: 0)
        }

        // Deduplicate and normalize by lowercase account name
        var seenNames = Set<String>()
        var list: [WorkerIdentity] = []
        var baseServer = current?.server ?? "https://mcp.xycdev.com"
        var baseToken = current?.token ?? ""

        for item in rawList {
            let clean = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let normName = (clean.isEmpty || clean == "morrow-iphone" || clean == "default") ? "antigravity-0" : clean
            let key = normName.lowercased()
            if !seenNames.contains(key) {
                seenNames.insert(key)
                let normItem = WorkerIdentity(server: item.server, name: normName, token: item.token)
                list.append(normItem)
                if baseToken.isEmpty && !item.token.isEmpty {
                    baseToken = item.token
                    baseServer = item.server
                }
            }
        }

        // Ensure both antigravity-0 and antigravity-1 exist if we have server/token
        if !baseToken.isEmpty {
            if !seenNames.contains("antigravity-0") {
                list.append(WorkerIdentity(server: baseServer, name: "antigravity-0", token: baseToken))
                seenNames.insert("antigravity-0")
            }
            if !seenNames.contains("antigravity-1") {
                list.append(WorkerIdentity(server: baseServer, name: "antigravity-1", token: baseToken))
                seenNames.insert("antigravity-1")
            }
        }

        // Stable sort: antigravity-0 first, then antigravity-1, then others alphabetically
        list.sort { a, b in
            let na = a.name.lowercased()
            let nb = b.name.lowercased()
            if na == "antigravity-0" { return true }
            if nb == "antigravity-0" { return false }
            if na == "antigravity-1" { return true }
            if nb == "antigravity-1" { return false }
            return na < nb
        }

        try? saveAllIdentities(list)
        return list
    }

    static func saveAllIdentities(_ identities: [WorkerIdentity]) throws {
        let data = try JSONEncoder().encode(identities)
        try saveRaw(data, account: listAccount)
    }

    static func loadCurrentIdentity() -> WorkerIdentity? {
        guard let data = try? loadRaw(account: account),
              let identity = try? JSONDecoder().decode(WorkerIdentity.self, from: data) else {
            return nil
        }
        let cleanName = identity.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanName.isEmpty || cleanName == "morrow-iphone" || cleanName == "default" {
            let normalized = WorkerIdentity(server: identity.server, name: "antigravity-0", token: identity.token)
            if let normData = try? JSONEncoder().encode(normalized) {
                try? saveRaw(normData, account: account)
            }
            return normalized
        }
        return identity
    }

    static func saveCurrentIdentity(_ identity: WorkerIdentity) throws {
        let cleanName = identity.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = (cleanName.isEmpty || cleanName == "morrow-iphone" || cleanName == "default")
            ? WorkerIdentity(server: identity.server, name: "antigravity-0", token: identity.token)
            : identity
        let data = try JSONEncoder().encode(normalized)
        try saveRaw(data, account: account)

        var list = loadAllIdentities()
        if let idx = list.firstIndex(where: { $0.id == normalized.id }) {
            list[idx] = normalized
        } else {
            list.append(normalized)
        }
        try saveAllIdentities(list)
    }

    static func switchIdentity(to identity: WorkerIdentity) throws {
        let cleanName = identity.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = (cleanName.isEmpty || cleanName == "morrow-iphone" || cleanName == "default")
            ? WorkerIdentity(server: identity.server, name: "antigravity-0", token: identity.token)
            : identity
        let data = try JSONEncoder().encode(normalized)
        try saveRaw(data, account: account)
    }

    @discardableResult
    static func removeIdentity(_ identity: WorkerIdentity) throws -> WorkerIdentity? {
        var list = loadAllIdentities()
        list.removeAll(where: { $0.id == identity.id })
        try saveAllIdentities(list)

        let current = loadCurrentIdentity()
        if current?.id == identity.id {
            if let next = list.first {
                try switchIdentity(to: next)
                return next
            } else {
                clearRaw(account: account)
                return nil
            }
        }
        return current
    }
}

struct WorkerIdentity: Codable, Equatable, Identifiable, Hashable {
    var id: String { "\(server.lowercased())|\(name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())" }
    let server: String
    let name: String
    let token: String

    var displayServer: String {
        if let url = URL(string: server), let host = url.host {
            return host
        }
        return server
    }

    var agentIcon: String {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if n.contains("antigravity") {
            return "atom"
        } else if n.contains("codex") {
            return "chevron.left.forwardslash.chevron.right"
        } else {
            return "desktopcomputer"
        }
    }

    var agentDisplayName: String {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if n == "antigravity-0" {
            return "antigravity-0 (Mac 原版)"
        } else if n == "antigravity-1" {
            return "antigravity-1 (Mac Personal)"
        } else if n.starts(with: "codex") {
            return "\(name) (Codex Agent)"
        }
        return name
    }
}
