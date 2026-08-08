import XCTest
import Security
@testable import CheeseApp

final class AuthCredentialStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var credentialStore: TestAuthCredentialStore!
    private var persistence: SavedAuthAccountPersistence!

    override func setUp() {
        super.setUp()
        suiteName = "AuthCredentialStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        credentialStore = TestAuthCredentialStore()
        persistence = SavedAuthAccountPersistence(
            defaults: defaults,
            credentialStore: credentialStore
        )
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        persistence = nil
        credentialStore = nil
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testSavedAccountEncodingContainsMetadataOnly() throws {
        let data = try JSONEncoder().encode(makeMetadata())
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        XCTAssertNil(object["accessToken"])
        XCTAssertNil(object["refreshToken"])
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("test-access-token"))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("test-refresh-token"))
    }

    func testMetadataPersistsWithoutCredentials() throws {
        let account = makeMetadata()

        persistence.persistMetadata([account], limit: 3)

        let data = try XCTUnwrap(
            defaults.data(forKey: SavedAuthAccountPersistence.metadataKey)
        )
        XCTAssertEqual(
            try JSONDecoder().decode([SavedAuthAccount].self, from: data),
            [account]
        )
        XCTAssertTrue(credentialStore.credentials.isEmpty)
    }

    func testLegacyMigrationMovesCredentialsThenRemovesPlaintext() throws {
        let legacy = makeLegacy()
        defaults.set(
            try JSONEncoder().encode([legacy]),
            forKey: SavedAuthAccountPersistence.legacyKey
        )

        let accounts = try persistence.loadAccounts(currentUserId: nil, limit: 3)

        XCTAssertEqual(accounts, [legacy.metadata])
        XCTAssertEqual(
            credentialStore.credentials[legacy.id],
            AuthCredential(
                accessToken: "test-access-token",
                refreshToken: "test-refresh-token"
            )
        )
        XCTAssertNil(defaults.data(forKey: SavedAuthAccountPersistence.legacyKey))
        let metadataData = try XCTUnwrap(
            defaults.data(forKey: SavedAuthAccountPersistence.metadataKey)
        )
        let metadataText = String(decoding: metadataData, as: UTF8.self)
        XCTAssertFalse(metadataText.contains("test-access-token"))
        XCTAssertFalse(metadataText.contains("test-refresh-token"))
    }

    func testLegacyMigrationIsIdempotent() throws {
        let legacy = makeLegacy()
        defaults.set(
            try JSONEncoder().encode([legacy]),
            forKey: SavedAuthAccountPersistence.legacyKey
        )

        _ = try persistence.loadAccounts(currentUserId: nil, limit: 3)
        _ = try persistence.loadAccounts(currentUserId: nil, limit: 3)

        XCTAssertEqual(credentialStore.saveCount, 1)
    }

    func testMigrationFailureKeepsLegacyPlaintextUntilCredentialSaveSucceeds() throws {
        let legacy = makeLegacy()
        let legacyData = try JSONEncoder().encode([legacy])
        defaults.set(legacyData, forKey: SavedAuthAccountPersistence.legacyKey)
        credentialStore.saveError = TestCredentialError.writeFailed

        XCTAssertThrowsError(
            try persistence.loadAccounts(currentUserId: nil, limit: 3)
        )
        XCTAssertEqual(
            defaults.data(forKey: SavedAuthAccountPersistence.legacyKey),
            legacyData
        )
        XCTAssertNil(defaults.data(forKey: SavedAuthAccountPersistence.metadataKey))
    }

    func testCurrentSDKAccountIsNotCopiedIntoAdditionalCredentialStore() throws {
        let legacy = makeLegacy()
        credentialStore.credentials[legacy.id] = AuthCredential(
            accessToken: "stale-access-token",
            refreshToken: "stale-refresh-token"
        )
        defaults.set(
            try JSONEncoder().encode([legacy]),
            forKey: SavedAuthAccountPersistence.legacyKey
        )

        _ = try persistence.loadAccounts(currentUserId: legacy.id, limit: 3)

        XCTAssertNil(credentialStore.credentials[legacy.id])
        XCTAssertEqual(credentialStore.saveCount, 0)
    }

    func testLogoutStorageCleanupDeletesCredentialsAndMetadata() throws {
        let account = makeMetadata()
        credentialStore.credentials[account.id] = AuthCredential(
            accessToken: "test-access-token",
            refreshToken: "test-refresh-token"
        )
        persistence.persistMetadata([account], limit: 3)
        defaults.set(Data("legacy".utf8), forKey: SavedAuthAccountPersistence.legacyKey)

        try persistence.removeAllAccounts()

        XCTAssertTrue(credentialStore.credentials.isEmpty)
        XCTAssertEqual(credentialStore.removeAllCount, 1)
        XCTAssertNil(defaults.data(forKey: SavedAuthAccountPersistence.metadataKey))
        XCTAssertNil(defaults.data(forKey: SavedAuthAccountPersistence.legacyKey))
    }

    func testCredentialStoreErrorDoesNotExposeToken() {
        let message = AuthCredentialStoreError.keychainFailure(errSecAuthFailed)
            .localizedDescription

        XCTAssertFalse(message.contains("test-access-token"))
        XCTAssertFalse(message.contains("test-refresh-token"))
        XCTAssertFalse(message.contains(String(errSecAuthFailed)))
    }

    private func makeMetadata() -> SavedAuthAccount {
        SavedAuthAccount(
            id: UUID(uuidString: "9a000000-0000-0000-0000-000000000001")!,
            email: "student@example.com",
            displayName: "Student",
            avatarURL: nil,
            lastUsedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
    }

    private func makeLegacy() -> LegacySavedAuthAccount {
        let metadata = makeMetadata()
        return LegacySavedAuthAccount(
            id: metadata.id,
            email: metadata.email,
            displayName: metadata.displayName,
            avatarURL: metadata.avatarURL,
            accessToken: "test-access-token",
            refreshToken: "test-refresh-token",
            lastUsedAt: metadata.lastUsedAt
        )
    }
}

private enum TestCredentialError: Error {
    case writeFailed
}

private final class TestAuthCredentialStore: AuthCredentialStoring {
    var credentials: [UUID: AuthCredential] = [:]
    var saveError: Error?
    private(set) var saveCount = 0
    private(set) var removeAllCount = 0

    func credential(for userId: UUID) throws -> AuthCredential? {
        credentials[userId]
    }

    func save(_ credential: AuthCredential, for userId: UUID) throws {
        if let saveError {
            throw saveError
        }
        saveCount += 1
        credentials[userId] = credential
    }

    func remove(for userId: UUID) throws {
        credentials.removeValue(forKey: userId)
    }

    func removeAll() throws {
        removeAllCount += 1
        credentials.removeAll()
    }
}
