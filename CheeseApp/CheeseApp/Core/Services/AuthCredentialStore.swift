//
//  AuthCredentialStore.swift
//  CheeseApp
//

import Foundation
import Security

struct AuthCredential: Equatable {
    let accessToken: String
    let refreshToken: String
}

protocol AuthCredentialStoring {
    func credential(for userId: UUID) throws -> AuthCredential?
    func save(_ credential: AuthCredential, for userId: UUID) throws
    func remove(for userId: UUID) throws
    func removeAll() throws
}

enum AuthCredentialStoreError: LocalizedError {
    case invalidStoredCredential
    case keychainFailure(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidStoredCredential:
            return "本机保存的账号凭据无法读取，请重新登录该账号。"
        case .keychainFailure:
            return "本机无法安全保存账号凭据，请稍后重试。"
        }
    }
}

final class KeychainAuthCredentialStore: AuthCredentialStoring {
    private struct Payload: Codable {
        let accessToken: String
        let refreshToken: String
    }

    private let service: String

    init(service: String = "\(Bundle.main.bundleIdentifier ?? "com.cheeseapp").auth.saved-accounts") {
        self.service = service
    }

    func credential(for userId: UUID) throws -> AuthCredential? {
        var query = baseQuery(for: userId)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw AuthCredentialStoreError.keychainFailure(status)
        }
        guard let data = item as? Data,
              let payload = try? JSONDecoder().decode(Payload.self, from: data)
        else {
            throw AuthCredentialStoreError.invalidStoredCredential
        }
        return AuthCredential(
            accessToken: payload.accessToken,
            refreshToken: payload.refreshToken
        )
    }

    func save(_ credential: AuthCredential, for userId: UUID) throws {
        let payload = Payload(
            accessToken: credential.accessToken,
            refreshToken: credential.refreshToken
        )
        let data = try JSONEncoder().encode(payload)
        let query = baseQuery(for: userId)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw AuthCredentialStoreError.keychainFailure(updateStatus)
        }

        var insert = query
        attributes.forEach { insert[$0.key] = $0.value }
        let insertStatus = SecItemAdd(insert as CFDictionary, nil)
        guard insertStatus == errSecSuccess else {
            throw AuthCredentialStoreError.keychainFailure(insertStatus)
        }
    }

    func remove(for userId: UUID) throws {
        let status = SecItemDelete(baseQuery(for: userId) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AuthCredentialStoreError.keychainFailure(status)
        }
    }

    func removeAll() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AuthCredentialStoreError.keychainFailure(status)
        }
    }

    private func baseQuery(for userId: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: userId.uuidString.lowercased(),
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any
        ]
    }
}

struct LegacySavedAuthAccount: Codable {
    let id: UUID
    let email: String
    let displayName: String?
    let avatarURL: String?
    let accessToken: String?
    let refreshToken: String?
    let lastUsedAt: Date

    var metadata: SavedAuthAccount {
        SavedAuthAccount(
            id: id,
            email: email,
            displayName: displayName,
            avatarURL: avatarURL,
            lastUsedAt: lastUsedAt
        )
    }
}

struct SavedAuthAccountPersistence {
    static let legacyKey = "auth.saved_accounts.v1"
    static let metadataKey = "auth.saved_accounts.metadata.v2"

    private let defaults: UserDefaults
    private let credentialStore: AuthCredentialStoring

    init(
        defaults: UserDefaults = .standard,
        credentialStore: AuthCredentialStoring = KeychainAuthCredentialStore()
    ) {
        self.defaults = defaults
        self.credentialStore = credentialStore
    }

    func loadAccounts(currentUserId: UUID?, limit: Int) throws -> [SavedAuthAccount] {
        if let legacyData = defaults.data(forKey: Self.legacyKey) {
            return try migrateLegacyAccounts(
                from: legacyData,
                currentUserId: currentUserId,
                limit: limit
            )
        }

        guard let data = defaults.data(forKey: Self.metadataKey) else {
            return []
        }
        return limited(
            try JSONDecoder().decode([SavedAuthAccount].self, from: data),
            limit: limit
        )
    }

    func legacyMetadata(limit: Int) -> [SavedAuthAccount] {
        guard let data = defaults.data(forKey: Self.legacyKey),
              let accounts = try? JSONDecoder().decode([LegacySavedAuthAccount].self, from: data)
        else {
            return []
        }
        return limited(accounts.map(\.metadata), limit: limit)
    }

    func persistMetadata(_ accounts: [SavedAuthAccount], limit: Int) {
        let accounts = limited(accounts, limit: limit)
        if accounts.isEmpty {
            defaults.removeObject(forKey: Self.metadataKey)
            return
        }
        if let data = try? JSONEncoder().encode(accounts) {
            defaults.set(data, forKey: Self.metadataKey)
        }
    }

    func credential(for userId: UUID) throws -> AuthCredential? {
        try credentialStore.credential(for: userId)
    }

    func saveCredential(_ credential: AuthCredential, for userId: UUID) throws {
        try credentialStore.save(credential, for: userId)
    }

    func removeCredential(for userId: UUID) throws {
        try credentialStore.remove(for: userId)
    }

    func removeAccount(
        userId: UUID,
        from accounts: [SavedAuthAccount],
        limit: Int
    ) throws -> [SavedAuthAccount] {
        try credentialStore.remove(for: userId)
        let remaining = accounts.filter { $0.id != userId }
        persistMetadata(remaining, limit: limit)
        return remaining
    }

    func removeAllAccounts() throws {
        try credentialStore.removeAll()
        defaults.removeObject(forKey: Self.metadataKey)
        defaults.removeObject(forKey: Self.legacyKey)
    }

    private func migrateLegacyAccounts(
        from data: Data,
        currentUserId: UUID?,
        limit: Int
    ) throws -> [SavedAuthAccount] {
        let legacyAccounts = try JSONDecoder().decode([LegacySavedAuthAccount].self, from: data)
        let accounts = limited(legacyAccounts.map(\.metadata), limit: limit)

        for legacy in legacyAccounts where accounts.contains(where: { $0.id == legacy.id }) {
            if legacy.id == currentUserId {
                try credentialStore.remove(for: legacy.id)
                continue
            }
            guard let accessToken = legacy.accessToken,
                  let refreshToken = legacy.refreshToken
            else {
                throw AuthCredentialStoreError.invalidStoredCredential
            }
            try credentialStore.save(
                AuthCredential(accessToken: accessToken, refreshToken: refreshToken),
                for: legacy.id
            )
        }

        persistMetadata(accounts, limit: limit)
        defaults.removeObject(forKey: Self.legacyKey)
        return accounts
    }

    private func limited(_ accounts: [SavedAuthAccount], limit: Int) -> [SavedAuthAccount] {
        Array(
            accounts
                .sorted { $0.lastUsedAt > $1.lastUsedAt }
                .prefix(limit)
        )
    }
}
