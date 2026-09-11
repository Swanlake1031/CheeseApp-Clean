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

    @MainActor
    func testBootstrapDeadlineDoesNotWaitForUncooperativeNetworkAndIgnoresLateCompletion() async {
        var pending: CheckedContinuation<Void, Never>?
        let start = Date()
        let completed = await AuthBootstrapDeadline.run(timeoutNanoseconds: 30_000_000) {
            await withCheckedContinuation { pending = $0 }
        }
        XCTAssertFalse(completed)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
        XCTAssertNotNil(pending)
        pending?.resume() // No second resume of the deadline continuation.
        await Task.yield()
    }

    @MainActor
    func testBootstrapSuccessfulValidationWinsDeadline() async {
        let completed = await AuthBootstrapDeadline.run(timeoutNanoseconds: 1_000_000_000) {}
        XCTAssertTrue(completed)
    }

    func testAppleAuthorizationCancellationIsRecognized() {
        let cancellation = NSError(
            domain: "com.apple.AuthenticationServices.AuthorizationError",
            code: 1001
        )

        XCTAssertTrue(AuthService.isUserCancelledSocialSignIn(cancellation))
    }

    func testNonCancellationAuthorizationErrorIsNotSuppressed() {
        let failure = NSError(
            domain: "com.apple.AuthenticationServices.AuthorizationError",
            code: 1000
        )

        XCTAssertFalse(AuthService.isUserCancelledSocialSignIn(failure))
    }

    @MainActor
    func testSecureNonceRejectsInvalidLengthWithoutCrashing() {
        XCTAssertThrowsError(try AuthService.makeSecureNonce(length: 0))
    }

    func testPasswordResetFormNormalizesOnlyPlausibleEmailAddresses() {
        XCTAssertEqual(
            PasswordResetFormPolicy.normalizedEmail("  person@example.com  "),
            "person@example.com"
        )
        XCTAssertEqual(
            PasswordResetFormPolicy.normalizedEmail("person+cheese@example.co.uk"),
            "person+cheese@example.co.uk"
        )

        for invalid in [
            "",
            "person",
            "person@",
            "@example.com",
            "person@example",
            "person..name@example.com",
            "person @example.com",
            "person@example.com\nspoof"
        ] {
            XCTAssertNil(
                PasswordResetFormPolicy.normalizedEmail(invalid),
                "Expected invalid email to be rejected: \(invalid)"
            )
        }
    }

    func testAppleCredentialIdentifierStoreIsScopedBySupabaseUser() throws {
        let store = TestAppleCredentialIdentifierStore()
        let firstUser = UUID(uuidString: "1a000000-0000-0000-0000-000000000001")!
        let secondUser = UUID(uuidString: "1a000000-0000-0000-0000-000000000002")!

        try store.save("apple-user-a", for: firstUser)
        try store.save("apple-user-b", for: secondUser)
        try store.remove(for: firstUser)

        XCTAssertNil(try store.identifier(for: firstUser))
        XCTAssertEqual(try store.identifier(for: secondUser), "apple-user-b")
    }

    func testAppleCredentialRevocationPolicyRequiresAppleLinkAndIdentifier() {
        let userId = UUID(uuidString: "2a000000-0000-0000-0000-000000000001")!

        XCTAssertNil(
            AppleCredentialRevocationPolicy.verificationTarget(
                for: AppleCredentialRevocationSession(
                    userId: userId,
                    accessToken: "token",
                    isAppleLinked: false,
                    appleUserIdentifier: "apple-user"
                )
            )
        )
        XCTAssertNil(
            AppleCredentialRevocationPolicy.verificationTarget(
                for: AppleCredentialRevocationSession(
                    userId: userId,
                    accessToken: "token",
                    isAppleLinked: true,
                    appleUserIdentifier: nil
                )
            )
        )
        XCTAssertEqual(
            AppleCredentialRevocationPolicy.verificationTarget(
                for: AppleCredentialRevocationSession(
                    userId: userId,
                    accessToken: "token",
                    isAppleLinked: true,
                    appleUserIdentifier: " apple-user "
                )
            ),
            AppleCredentialVerificationTarget(
                userId: userId,
                accessToken: "token",
                appleUserIdentifier: "apple-user"
            )
        )
    }

    func testAppleCredentialRevocationPolicyResetsOnlyRevokedOrNotFound() {
        XCTAssertTrue(AppleCredentialRevocationPolicy.shouldReset(for: .revoked))
        XCTAssertTrue(AppleCredentialRevocationPolicy.shouldReset(for: .notFound))
        XCTAssertFalse(AppleCredentialRevocationPolicy.shouldReset(for: .authorized))
        XCTAssertFalse(AppleCredentialRevocationPolicy.shouldReset(for: .transferred))
        XCTAssertFalse(AppleCredentialRevocationPolicy.shouldReset(for: .unknown))
    }

    @MainActor
    func testAppleCredentialRevocationMonitorResetsOnlyMatchingCurrentAccount() async {
        let checker = TestAppleCredentialStateChecker()
        checker.result = .success(.revoked)
        let firstUser = UUID(uuidString: "3a000000-0000-0000-0000-000000000001")!
        let secondUser = UUID(uuidString: "3a000000-0000-0000-0000-000000000002")!
        var currentSession: AppleCredentialRevocationSession? = AppleCredentialRevocationSession(
            userId: firstUser,
            accessToken: "first-token",
            isAppleLinked: true,
            appleUserIdentifier: "first-apple-user"
        )
        var resetTargets: [AppleCredentialVerificationTarget] = []
        let monitor = AppleCredentialRevocationMonitor(
            checker: checker,
            sessionProvider: { currentSession },
            resetHandler: { resetTargets.append($0) },
            notificationCenter: NotificationCenter(),
            notificationName: Notification.Name("AppleCredentialRevocationMonitorTests")
        )

        await monitor.checkCurrentSession()

        XCTAssertEqual(
            resetTargets,
            [
                AppleCredentialVerificationTarget(
                    userId: firstUser,
                    accessToken: "first-token",
                    appleUserIdentifier: "first-apple-user"
                )
            ]
        )

        currentSession = AppleCredentialRevocationSession(
            userId: secondUser,
            accessToken: "second-token",
            isAppleLinked: false,
            appleUserIdentifier: nil
        )
        await monitor.checkCurrentSession()

        XCTAssertEqual(checker.requestedIdentifiers, ["first-apple-user"])
        XCTAssertEqual(resetTargets.count, 1)
    }

    @MainActor
    func testAppleCredentialRevocationMonitorPreservesAuthorizedErrorAndTransferredStates() async {
        let checker = TestAppleCredentialStateChecker()
        let userId = UUID(uuidString: "4a000000-0000-0000-0000-000000000001")!
        let session = AppleCredentialRevocationSession(
            userId: userId,
            accessToken: "token",
            isAppleLinked: true,
            appleUserIdentifier: "apple-user"
        )
        var resetTargets: [AppleCredentialVerificationTarget] = []
        let monitor = AppleCredentialRevocationMonitor(
            checker: checker,
            sessionProvider: { session },
            resetHandler: { resetTargets.append($0) },
            notificationCenter: NotificationCenter(),
            notificationName: Notification.Name("AppleCredentialRevocationMonitorTests")
        )

        checker.result = .success(.authorized)
        await monitor.checkCurrentSession()
        checker.result = .success(.transferred)
        await monitor.checkCurrentSession()
        checker.result = .failure(TestCredentialError.writeFailed)
        await monitor.checkCurrentSession()

        XCTAssertTrue(resetTargets.isEmpty)
        XCTAssertEqual(
            checker.requestedIdentifiers,
            ["apple-user", "apple-user", "apple-user"]
        )
    }

    @MainActor
    func testAppleCredentialRevocationMonitorIgnoresResultAfterAccountSwitch() async {
        let checker = DeferredAppleCredentialStateChecker()
        let firstUser = UUID(uuidString: "5a000000-0000-0000-0000-000000000001")!
        let secondUser = UUID(uuidString: "5a000000-0000-0000-0000-000000000002")!
        var currentSession: AppleCredentialRevocationSession? = AppleCredentialRevocationSession(
            userId: firstUser,
            accessToken: "first-token",
            isAppleLinked: true,
            appleUserIdentifier: "first-apple-user"
        )
        var resetTargets: [AppleCredentialVerificationTarget] = []
        let monitor = AppleCredentialRevocationMonitor(
            checker: checker,
            sessionProvider: { currentSession },
            resetHandler: { resetTargets.append($0) },
            notificationCenter: NotificationCenter(),
            notificationName: Notification.Name("AppleCredentialRevocationMonitorTests")
        )

        let check = Task { @MainActor in
            await monitor.checkCurrentSession()
        }
        for _ in 0..<20 where !checker.isWaiting {
            await Task.yield()
        }
        XCTAssertTrue(checker.isWaiting)

        currentSession = AppleCredentialRevocationSession(
            userId: secondUser,
            accessToken: "second-token",
            isAppleLinked: true,
            appleUserIdentifier: "second-apple-user"
        )
        checker.resume(with: .revoked)
        await check.value

        XCTAssertTrue(resetTargets.isEmpty)
    }

    @MainActor
    func testAppleCredentialRevocationNotificationUsesCurrentSessionCheck() async {
        let checker = TestAppleCredentialStateChecker()
        checker.result = .success(.notFound)
        let center = NotificationCenter()
        let notification = Notification.Name("AppleCredentialRevocationNotificationTests")
        let userId = UUID(uuidString: "6a000000-0000-0000-0000-000000000001")!
        let reset = expectation(description: "reset after notification")
        var resetTarget: AppleCredentialVerificationTarget?
        let monitor = AppleCredentialRevocationMonitor(
            checker: checker,
            sessionProvider: {
                AppleCredentialRevocationSession(
                    userId: userId,
                    accessToken: "token",
                    isAppleLinked: true,
                    appleUserIdentifier: "apple-user"
                )
            },
            resetHandler: {
                resetTarget = $0
                reset.fulfill()
            },
            notificationCenter: center,
            notificationName: notification
        )

        center.post(name: notification, object: nil)
        await fulfillment(of: [reset], timeout: 1)

        XCTAssertEqual(checker.requestedIdentifiers, ["apple-user"])
        XCTAssertEqual(
            resetTarget,
            AppleCredentialVerificationTarget(
                userId: userId,
                accessToken: "token",
                appleUserIdentifier: "apple-user"
            )
        )
        withExtendedLifetime(monitor) {}
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

    func testApplePrivateRelayEmailDoesNotBecomeDisplayName() {
        let account = SavedAuthAccount(
            id: UUID(),
            email: "y7whpptbj4@privaterelay.appleid.com",
            displayName: nil,
            avatarURL: nil,
            profileCompleted: true,
            lastUsedAt: Date()
        )

        XCTAssertEqual(account.displayLabel, "Apple 用户")
    }

    func testProfileNameStillOverridesApplePrivateRelayFallback() {
        let account = SavedAuthAccount(
            id: UUID(),
            email: "y7whpptbj4@privaterelay.appleid.com",
            displayName: "Timon",
            avatarURL: nil,
            profileCompleted: true,
            lastUsedAt: Date()
        )

        XCTAssertEqual(account.displayLabel, "Timon")
    }

    private func makeMetadata() -> SavedAuthAccount {
        SavedAuthAccount(
            id: UUID(uuidString: "9a000000-0000-0000-0000-000000000001")!,
            email: "student@example.com",
            displayName: "Student",
            avatarURL: nil,
            profileCompleted: true,
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

private final class TestAppleCredentialIdentifierStore: AppleCredentialIdentifierStoring {
    private var identifiers: [UUID: String] = [:]

    func identifier(for userId: UUID) throws -> String? {
        identifiers[userId]
    }

    func save(_ identifier: String, for userId: UUID) throws {
        identifiers[userId] = identifier
    }

    func remove(for userId: UUID) throws {
        identifiers.removeValue(forKey: userId)
    }

    func removeAll() throws {
        identifiers.removeAll()
    }
}

private final class TestAppleCredentialStateChecker: AppleCredentialStateChecking {
    var result: Result<AppleCredentialState, Error> = .success(.authorized)
    private(set) var requestedIdentifiers: [String] = []

    func credentialState(for userIdentifier: String) async throws -> AppleCredentialState {
        requestedIdentifiers.append(userIdentifier)
        return try result.get()
    }
}

private final class DeferredAppleCredentialStateChecker: AppleCredentialStateChecking {
    private var continuation: CheckedContinuation<AppleCredentialState, Error>?
    private(set) var isWaiting = false

    func credentialState(for userIdentifier: String) async throws -> AppleCredentialState {
        isWaiting = true
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func resume(with state: AppleCredentialState) {
        let continuation = continuation
        self.continuation = nil
        isWaiting = false
        continuation?.resume(returning: state)
    }
}
