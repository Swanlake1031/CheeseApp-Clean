//
//  AuthService.swift
//  CheeseApp
//
//  🔐 用户认证服务
//  使用 Supabase Auth 进行用户登录、注册、登出
//

import Foundation
import SwiftUI
import Supabase
import UIKit

enum AuthBootstrapState: Equatable {
    case restoringSession
    case ready
}

enum AccountIdentityProvider {
    case google
    case apple
}

struct AccountIdentityStatus {
    let isLinked: Bool
    let email: String?
}

struct AccountIdentityStatuses {
    let google: AccountIdentityStatus
    let apple: AccountIdentityStatus
}

enum AppLifecycleRefreshPolicy {
    static func shouldRefresh(
        hasCachedData: Bool,
        lastSuccessfulRefreshAt: Date?,
        now: Date = Date(),
        cacheLifetime: TimeInterval = 5 * 60
    ) -> Bool {
        guard hasCachedData, let lastSuccessfulRefreshAt else { return true }
        return now.timeIntervalSince(lastSuccessfulRefreshAt) >= cacheLifetime
    }
}

// MARK: - 认证服务
@MainActor
class AuthService: ObservableObject {
    typealias AccountTransitionHandler = @MainActor () -> Void
    typealias AccountActivationHandler = @MainActor (UUID?) -> Void

    private enum BootstrapTimeoutError: Error {
        case timedOut
    }

    private struct SessionRecoverySnapshot {
        let userId: UUID
        let email: String?
        let accessToken: String
        let refreshToken: String
        let profile: Profile?
    }
    
    // 单例
    static let shared = AuthService()
    
    // Supabase 客户端引用
    private let supabase = SupabaseManager.shared
    
    // MARK: - 发布的状态
    @Published var currentUser: Profile? {
        didSet {
            guard oldValue?.id != currentUser?.id else { return }
            lastSuccessfulSessionValidationAt = currentUser == nil ? nil : Date()
            activateAccountState(currentUser?.id)
        }
    }
    @Published var isLoading = false
    @Published var isAuthenticated = false
    @Published var errorMessage: String?
    @Published var requiresProfileCompletion = false
    @Published private(set) var bootstrapState: AuthBootstrapState = .restoringSession
    @Published private(set) var savedAccounts: [SavedAuthAccount] = []
    @Published private(set) var recentLoginAccounts: [RecentLoginAccount] = []

    var maxSavedAccountCount: Int { maxSavedAccounts }
    var maxRecentLoginCount: Int { maxRecentLoginAccounts }
    var canAddSavedAccount: Bool { savedAccounts.count < maxSavedAccounts }
    
    // 防止重复检查
    private var hasCheckedSession = false
    private let savedAccountPersistence = SavedAuthAccountPersistence()
    private let recentLoginAccountsKey = "auth.recent_login_accounts.v2"
    private let legacyRecentLoginAccountsKey = "auth.recent_login_accounts.v1"
    private let maxSavedAccounts = 3
    private let maxRecentLoginAccounts = 5
    private static let googleOAuthQueryParams: [(name: String, value: String?)] = [
        (name: "prompt", value: "select_account")
    ]
    private var suppressSessionValidation = false
    private let bootstrapTimeoutNanoseconds: UInt64 = 8_000_000_000
    private var accountTransitionHandler: AccountTransitionHandler?
    private var accountActivationHandler: AccountActivationHandler?
    private var sessionValidationTask: Task<Void, Never>?
    private var sessionValidationID: UUID?
    private var lastSuccessfulSessionValidationAt: Date?
    private var profileCompletionReturnSnapshot: SessionRecoverySnapshot?
    private let sessionValidationCacheLifetime: TimeInterval = 5 * 60
    
    private init() {
        // 不在 init 中自动检查，避免重复请求
        loadSavedAccounts(currentUserId: supabase.auth.currentSession?.user.id)
        loadRecentLoginAccounts()
    }

    func configureAccountStateHandlers(
        beginTransition: @escaping AccountTransitionHandler,
        activateAccount: @escaping AccountActivationHandler
    ) {
        accountTransitionHandler = beginTransition
        accountActivationHandler = activateAccount
        activateAccount(currentUser?.id)
    }
    
    // MARK: - 检查当前会话（只检查一次）
    func checkSessionOnce() async {
        // 如果已经检查过，直接返回
        guard !hasCheckedSession else {
            bootstrapState = .ready
            return
        }
        hasCheckedSession = true

        bootstrapState = .restoringSession
        defer { bootstrapState = .ready }

        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { [weak self] in
                    guard let self else { return }
                    await self.checkSession(force: true)
                }
                group.addTask { [bootstrapTimeoutNanoseconds] in
                    try await Task.sleep(nanoseconds: bootstrapTimeoutNanoseconds)
                    throw BootstrapTimeoutError.timedOut
                }

                _ = try await group.next()
                group.cancelAll()
            }

            if requiresProfileCompletion {
                await leaveProfileCompletion()
            }
        } catch BootstrapTimeoutError.timedOut {
            resetAuthState()
        } catch {
            resetAuthState()
        }
    }
    
    // MARK: - 检查当前会话
    func checkSession(
        force: Bool = false,
        now: Date = Date()
    ) async {
        guard !suppressSessionValidation else { return }
        guard !isLoading else { return }

        let hasCachedSession = isAuthenticated
            && currentUser != nil
            && localSessionUserId() == currentUser?.id
        guard force || AppLifecycleRefreshPolicy.shouldRefresh(
            hasCachedData: hasCachedSession,
            lastSuccessfulRefreshAt: lastSuccessfulSessionValidationAt,
            now: now,
            cacheLifetime: sessionValidationCacheLifetime
        ) else { return }

        if let sessionValidationTask {
            await sessionValidationTask.value
            return
        }

        let validationID = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performSessionCheck(
                validatedAt: now,
                validationID: validationID
            )
        }
        sessionValidationID = validationID
        sessionValidationTask = task
        await task.value

        if sessionValidationID == validationID {
            sessionValidationTask = nil
            sessionValidationID = nil
        }
    }

    private func performSessionCheck(
        validatedAt: Date,
        validationID: UUID
    ) async {
        do {
            let userId = try await requireAuthUserId()
            guard isCurrentSessionValidation(validationID) else { return }

            if currentUser?.id != userId {
                beginAccountStateTransition()
                currentUser = nil
                let profile = try? await fetchProfileWithRetry(userId: userId)
                guard isCurrentSessionValidation(validationID) else { return }
                currentUser = profile
            }
            guard isCurrentSessionValidation(validationID) else { return }

            // 只要 auth session 有效，就保持登录态，资料缺失时走完善资料流程而非踢回登录页。
            isAuthenticated = true
            requiresProfileCompletion = needsProfileCompletion(currentUser)
            _ = await persistCurrentSessionForAccountSwitching()
            lastSuccessfulSessionValidationAt = validatedAt
        } catch {
            // 前台恢复遇到瞬时网络错误时保留同账号的可用缓存；下一次恢复会重试。
            if isAuthenticated,
               let currentUser,
               localSessionUserId() == currentUser.id {
                return
            }
            resetAuthState()
        }
    }

    private func isCurrentSessionValidation(_ validationID: UUID) -> Bool {
        !Task.isCancelled && sessionValidationID == validationID
    }

    private func currentValidSession() async throws -> Session {
        do {
            let current = try await supabase.auth.session
            if current.isExpired {
                return try await supabase.auth.refreshSession()
            }
            return current
        } catch {
            return try await supabase.auth.refreshSession()
        }
    }

    private func localSessionUserId() -> UUID? {
        supabase.auth.currentSession?.user.id
    }

    private func clearResidualLoggedOutSessionIfNeeded() async {
        guard currentUser == nil, !isAuthenticated else { return }
        guard supabase.auth.currentSession != nil else { return }

        do {
            try await supabase.auth.signOut(scope: .local)
        } catch {
        }
    }

    // MARK: - 获取可用会话对应的用户 ID（含 refresh 与服务端校验）
    func requireAuthUserId() async throws -> UUID {
        let session = try await currentValidSession()

        // 2) 服务端校验，避免本地残留 session
        let serverUser = try await supabase.auth.user()
        guard serverUser.id == session.user.id else {
            throw NSError(domain: "", code: 401, userInfo: [NSLocalizedDescriptionKey: "登录状态无效，请重新登录"])
        }

        return session.user.id
    }

    // MARK: - 统一重置认证状态
    private func resetAuthState() {
        sessionValidationTask?.cancel()
        sessionValidationTask = nil
        sessionValidationID = nil
        beginAccountStateTransition()
        Task {
            try? await supabase.auth.signOut()
        }
        currentUser = nil
        isAuthenticated = false
        requiresProfileCompletion = false
        profileCompletionReturnSnapshot = nil
        bootstrapState = .ready
        hasCheckedSession = false
        lastSuccessfulSessionValidationAt = nil
        activateAccountState(nil)
    }

    private func beginAccountStateTransition() {
        accountTransitionHandler?()
    }

    private func activateAccountState(_ userID: UUID?) {
        accountActivationHandler?(userID)
    }
    
    // MARK: - 获取用户资料
    func fetchUserProfile(userId: UUID) async {
        do {
            let profile = try await fetchProfileWithRetry(userId: userId)
            currentUser = profile
            requiresProfileCompletion = needsProfileCompletion(profile)
        } catch {
            currentUser = nil
            requiresProfileCompletion = true
        }
    }
    
    // MARK: - 邮箱密码登录
    func signIn(email: String, password: String) async throws {
        guard !isLoading else { return }
        profileCompletionReturnSnapshot = nil
        let normalizedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        
        isLoading = true
        errorMessage = nil
        
        defer { isLoading = false }

        await clearResidualLoggedOutSessionIfNeeded()
        
        do {
            let response = try await supabase.auth.signIn(
                email: normalizedEmail,
                password: password
            )
            
            isAuthenticated = true
            await fetchUserProfile(userId: response.user.id)
            _ = await persistCurrentSessionForAccountSwitching(
                recordAsRecent: true,
                recentSignInMethod: .password
            )
        } catch {
            errorMessage = "登录失败: \(error.localizedDescription)"
            throw error
        }
    }

    // MARK: - Google 登录
    func signInWithGoogle() async throws {
        guard !isLoading else { return }
        profileCompletionReturnSnapshot = nil
        let previousSessionUserId = localSessionUserId()

        isLoading = true
        errorMessage = nil

        defer { isLoading = false }

        await clearResidualLoggedOutSessionIfNeeded()

        do {
            let redirectURL = URL(string: "cheeseapp://auth/callback")
            let session = try await supabase.auth.signInWithOAuth(
                provider: .google,
                redirectTo: redirectURL,
                scopes: "openid email profile",
                queryParams: Self.googleOAuthQueryParams
            )

            isAuthenticated = true
            await fetchUserProfile(userId: session.user.id)
            requiresProfileCompletion = needsProfileCompletion(currentUser)
            _ = await persistCurrentSessionForAccountSwitching(
                recordAsRecent: true,
                recentSignInMethod: .google
            )
        } catch {
            // 某些设备/网络下 OAuth 回跳后 SDK 可能先抛错，但会话已建立；这里做一次兜底确认。
            if let currentSession = supabase.auth.currentSession,
               previousSessionUserId == nil || currentSession.user.id != previousSessionUserId,
               let userId = try? await requireAuthUserId(),
               userId == currentSession.user.id {
                await fetchUserProfile(userId: userId)
                if let profile = currentUser {
                    isAuthenticated = true
                    requiresProfileCompletion = needsProfileCompletion(profile)
                    _ = await persistCurrentSessionForAccountSwitching(
                        recordAsRecent: true,
                        recentSignInMethod: .google
                    )
                    return
                }
            }
            let message = socialSignInMessage(for: error, provider: "谷歌")
            errorMessage = message
            throw NSError(
                domain: "",
                code: (error as NSError).code,
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }
    }

    // MARK: - Apple 登录
    func signInWithApple() async throws {
        guard !isLoading else { return }
        profileCompletionReturnSnapshot = nil
        let previousSessionUserId = localSessionUserId()

        isLoading = true
        errorMessage = nil

        defer { isLoading = false }

        await clearResidualLoggedOutSessionIfNeeded()

        do {
            let redirectURL = URL(string: "cheeseapp://auth/callback")
            let session = try await supabase.auth.signInWithOAuth(
                provider: .apple,
                redirectTo: redirectURL,
                scopes: "name email"
            )

            isAuthenticated = true
            await fetchUserProfile(userId: session.user.id)
            requiresProfileCompletion = needsProfileCompletion(currentUser)
            _ = await persistCurrentSessionForAccountSwitching(
                recordAsRecent: true,
                recentSignInMethod: .apple
            )
        } catch {
            // 某些设备/网络下 OAuth 回跳后 SDK 可能先抛错，但会话已建立；这里做一次兜底确认。
            if let currentSession = supabase.auth.currentSession,
               previousSessionUserId == nil || currentSession.user.id != previousSessionUserId,
               let userId = try? await requireAuthUserId(),
               userId == currentSession.user.id {
                await fetchUserProfile(userId: userId)
                if let profile = currentUser {
                    isAuthenticated = true
                    requiresProfileCompletion = needsProfileCompletion(profile)
                    _ = await persistCurrentSessionForAccountSwitching(
                        recordAsRecent: true,
                        recentSignInMethod: .apple
                    )
                    return
                }
            }
            let message = socialSignInMessage(for: error, provider: "Apple")
            errorMessage = message
            throw NSError(
                domain: "",
                code: (error as NSError).code,
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }
    }

    func accountIdentityStatuses() async throws -> AccountIdentityStatuses {
        let authUser = try await supabase.auth.user()
        let fallbackEmail = authUser.email ?? currentUser?.email
        let googleIdentity = authUser.identities?.first { $0.provider.lowercased() == "google" }
        let appleIdentity = authUser.identities?.first { $0.provider.lowercased() == "apple" }

        return AccountIdentityStatuses(
            google: AccountIdentityStatus(
                isLinked: googleIdentity != nil,
                email: googleIdentity?.identityData?["email"]?.stringValue ?? fallbackEmail
            ),
            apple: AccountIdentityStatus(
                isLinked: appleIdentity != nil,
                email: appleIdentity?.identityData?["email"]?.stringValue ?? fallbackEmail
            )
        )
    }

    func linkAccountIdentity(_ provider: AccountIdentityProvider) async throws {
        let redirectURL = URL(string: "cheeseapp://auth/callback")

        do {
            switch provider {
            case .google:
                try await supabase.auth.linkIdentity(
                    provider: .google,
                    scopes: "openid email profile",
                    redirectTo: redirectURL,
                    queryParams: Self.googleOAuthQueryParams
                )
            case .apple:
                try await supabase.auth.linkIdentity(
                    provider: .apple,
                    scopes: "name email",
                    redirectTo: redirectURL
                )
            }
        } catch {
            throw accountIdentityLinkError(for: error, provider: provider)
        }
    }
    
    // MARK: - 注册
    func signUp(email: String, password: String) async throws {
        guard !isLoading else { return }
        profileCompletionReturnSnapshot = nil
        let normalizedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if isGmailAddress(normalizedEmail) {
            let message = "检测到 Gmail 邮箱，请使用 Google 登录/注册（更安全）。"
            errorMessage = message
            throw NSError(domain: "AuthService", code: 400, userInfo: [NSLocalizedDescriptionKey: message])
        }
        isLoading = true
        errorMessage = nil
        
        defer { isLoading = false }

        await clearResidualLoggedOutSessionIfNeeded()
        
        do {
            // 仅保留基础注册信息：邮箱 + 密码
            _ = try await supabase.auth.signUp(
                email: normalizedEmail,
                password: password
            )

            // 若有会话则直接进入 App，并在首登补充资料
            if let session = try? await supabase.auth.session {
                isAuthenticated = true
                await fetchUserProfile(userId: session.user.id)
                requiresProfileCompletion = true
                _ = await persistCurrentSessionForAccountSwitching(
                    recordAsRecent: true,
                    recentSignInMethod: .password
                )
            } else {
                isAuthenticated = false
                currentUser = nil
                errorMessage = "注册成功，请先完成邮箱验证后登录"
            }
        } catch {
            let message = signUpErrorMessage(for: error)
            errorMessage = message
            throw NSError(
                domain: "AuthService",
                code: (error as NSError).code,
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }
    }
    
    // MARK: - 登出
    func signOut() async throws {
        guard !isLoading else { return }

        beginAccountStateTransition()
        isLoading = true
        defer {
            isLoading = false
            activateAccountState(nil)
        }

        await EngagementNotificationService.shared.unregisterCurrentDeviceTokenIfNeeded()
        UIApplication.shared.unregisterForRemoteNotifications()

        // 安全策略：任意账号登出时，清空本机所有可切换账号会话。
        clearSavedAccountsFromStorage()
        currentUser = nil
        isAuthenticated = false
        requiresProfileCompletion = false
        profileCompletionReturnSnapshot = nil
        bootstrapState = .ready
        hasCheckedSession = false // 重置，允许下次检查

        do {
            try await supabase.auth.signOut()
        } catch {
            // 云端 sign out 失败不应阻止本地登出完成。
            if !error.isCancellationLike {
            }
        }
    }

    func leaveProfileCompletion() async {
        guard requiresProfileCompletion else { return }
        let incompleteUserId = currentUser?.id ?? localSessionUserId()

        if let returnSnapshot = profileCompletionReturnSnapshot {
            await persistPendingProfileCompletionSession(
                returningToUserId: returnSnapshot.userId
            )
            profileCompletionReturnSnapshot = nil
            beginAccountStateTransition()
            suppressSessionValidation = true
            isLoading = true
            let restoredPreviousAccount = await restoreRecoverySnapshot(returnSnapshot)
            isLoading = false
            suppressSessionValidation = false
            activateAccountState(currentUser?.id)

            if restoredPreviousAccount {
                return
            }
        }

        try? await signOut()
        if let incompleteUserId {
            removeRecentLoginAccountFromStorage(userId: incompleteUserId)
        }
    }

    func reloadSavedAccounts() {
        loadSavedAccounts(currentUserId: supabase.auth.currentSession?.user.id)
    }

    func switchToAccount(userId: UUID) async throws {
        guard !isLoading else { return }
        guard currentUser?.id != userId else { return }
        guard let account = savedAccounts.first(where: { $0.id == userId }) else {
            throw NSError(
                domain: "AuthService",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: "未找到该账号，请重新登录后再试。"]
            )
        }

        let recoverySnapshot = await currentSessionRecoverySnapshot()

        beginAccountStateTransition()
        isLoading = true
        errorMessage = nil
        defer {
            isLoading = false
            activateAccountState(currentUser?.id)
        }

        do {
            if let recoverySnapshot {
                try savedAccountPersistence.saveCredential(
                    AuthCredential(
                        accessToken: recoverySnapshot.accessToken,
                        refreshToken: recoverySnapshot.refreshToken
                    ),
                    for: recoverySnapshot.userId
                )
            }
            guard let credential = try savedAccountPersistence.credential(for: account.id) else {
                throw NSError(
                    domain: "AuthService",
                    code: 401,
                    userInfo: [NSLocalizedDescriptionKey: "该账号的安全凭据不存在，请重新登录后再试。"]
                )
            }
            let session = try await restoreSession(
                accessToken: credential.accessToken,
                refreshToken: credential.refreshToken
            )
            guard session.user.id == account.id else {
                throw NSError(
                    domain: "AuthService",
                    code: 401,
                    userInfo: [NSLocalizedDescriptionKey: "切换账号失败：账号凭证不匹配，请重新登录该账号。"]
                )
            }
            await fetchUserProfile(userId: session.user.id)
            isAuthenticated = currentUser != nil
            requiresProfileCompletion = needsProfileCompletion(currentUser)
            profileCompletionReturnSnapshot = requiresProfileCompletion ? recoverySnapshot : nil
            let signInMethod = recentLoginAccounts
                .first(where: { $0.id == session.user.id })?
                .signInMethod
                ?? inferSignInMethod(from: session.user)
            recordRecentLoginAccount(
                userId: session.user.id,
                email: session.user.email,
                profile: currentUser,
                signInMethod: signInMethod
            )
            if requiresProfileCompletion {
                _ = try storeInactiveSavedAccount(
                    userId: session.user.id,
                    email: session.user.email,
                    accessToken: session.accessToken,
                    refreshToken: session.refreshToken,
                    profile: currentUser
                )
            } else {
                _ = try upsertCurrentSavedAccount(
                    userId: session.user.id,
                    email: session.user.email,
                    profile: currentUser
                )
            }
        } catch {
            _ = await restoreRecoverySnapshot(recoverySnapshot)
            profileCompletionReturnSnapshot = nil

            // 目标账号会话失效时，从可切换列表移除，避免反复出现“会话已失效”。
            let text = error.localizedDescription.lowercased()
            let shouldPrune =
                text.contains("session")
                || text.contains("expired")
                || text.contains("invalid")
                || text.contains("jwt")
                || text.contains("refresh")
                || text.contains("401")
            if shouldPrune {
                removeSavedAccountFromStorage(userId: userId)
            }
            let message = "切换账号失败：该账号会话已失效，请重新登录。"
            errorMessage = message
            throw NSError(domain: "AuthService", code: 401, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    func addAccount(email: String, password: String) async throws -> UUID {
        let normalizedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedEmail.isEmpty else {
            throw NSError(
                domain: "AuthService",
                code: 400,
                userInfo: [NSLocalizedDescriptionKey: "请输入邮箱地址。"]
            )
        }
        return try await addAccountBySigningIn(signInMethod: .password) {
            try await supabase.auth.signIn(
                email: normalizedEmail,
                password: password
            )
        }
    }

    func addAccountWithGoogle() async throws -> UUID {
        let previousUserId = currentUser?.id
        return try await addAccountBySigningIn(signInMethod: .google) {
            do {
                let redirectURL = URL(string: "cheeseapp://auth/callback")
                return try await supabase.auth.signInWithOAuth(
                    provider: .google,
                    redirectTo: redirectURL,
                    scopes: "openid email profile",
                    queryParams: Self.googleOAuthQueryParams
                )
            } catch {
                // 某些设备回跳后会先抛错，这里做一次会话兜底。
                guard let session = try? await supabase.auth.session else {
                    throw error
                }
                if session.user.id == previousUserId {
                    throw error
                }
                return session
            }
        }
    }

    func addAccountWithApple() async throws -> UUID {
        try await addAccountBySigningIn(signInMethod: .apple) {
            let redirectURL = URL(string: "cheeseapp://auth/callback")
            let session = try await supabase.auth.signInWithOAuth(
                provider: .apple,
                redirectTo: redirectURL,
                scopes: "name email"
            )
            return session
        }
    }

    func removeSavedAccount(userId: UUID) {
        if currentUser?.id == userId {
            return
        }
        removeSavedAccountFromStorage(userId: userId)
    }

    func removeRecentLoginAccount(userId: UUID) {
        removeRecentLoginAccountFromStorage(userId: userId)
        if currentUser?.id != userId {
            removeSavedAccountFromStorage(userId: userId)
        }
    }

    func deactivateCurrentAccount() async throws {
        guard !isLoading else { return }
        let userId = try await requireAuthUserId()

        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let _: Bool = try await supabase.client
                .rpc("deactivate_my_account")
                .execute()
                .value

            beginAccountStateTransition()
            try? await supabase.auth.signOut()
            clearSavedAccountsFromStorage()
            removeRecentLoginAccountFromStorage(userId: userId)
            currentUser = nil
            isAuthenticated = false
            requiresProfileCompletion = false
            bootstrapState = .ready
            hasCheckedSession = false
            activateAccountState(nil)
        } catch {
            let message = "注销账号失败：\(error.localizedDescription)"
            errorMessage = message
            throw NSError(domain: "AuthService", code: 500, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }
    
    // MARK: - 重置密码
    func resetPassword(email: String) async throws {
        do {
            try await supabase.auth.resetPasswordForEmail(email)
        } catch {
            errorMessage = "发送重置邮件失败"
            throw error
        }
    }

    func completeProfile(
        fullName: String?,
        school: String,
        gender: String,
        occupation: String
    ) async throws {
        let normalizedFullName = fullName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let normalizedSchool = school.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let selectedSchoolOption = CheeseUniversityOption.option(matching: normalizedSchool)
        if normalizedSchool != nil, selectedSchoolOption == nil {
            throw NSError(
                domain: "AuthService",
                code: 400,
                userInfo: [NSLocalizedDescriptionKey: "请选择下拉列表中的正确学校"]
            )
        }
        let normalizedGender = gender.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ["male", "female", "non_binary", "prefer_not_to_say"].contains(normalizedGender) else {
            throw NSError(
                domain: "AuthService",
                code: 400,
                userInfo: [NSLocalizedDescriptionKey: "请选择性别"]
            )
        }
        let normalizedOccupation = occupation.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty

        // Google / OAuth 场景下，极少数账号会出现 profiles 行缺失，先兜底确保存在。
        let userId = try await ensureOwnProfileRowIfNeeded(
            schoolName: selectedSchoolOption?.name ?? CheeseUniversityOption.defaultSchoolName,
            fullName: normalizedFullName
        )

        let params = CompleteProfileParams(
            pFullName: normalizedFullName,
            pUniversity: selectedSchoolOption?.name,
            pGender: normalizedGender,
            pOccupation: normalizedOccupation
        )
        _ = try await supabase.client
            .rpc("complete_profile", params: params)
            .execute()

        // 先乐观更新本地状态，避免因短暂读取失败把用户卡在“完善资料”页。
        if var profile = currentUser {
            if let normalizedFullName {
                profile.fullName = normalizedFullName
            }
            profile.school = selectedSchoolOption?.name
            profile.gender = normalizedGender
            profile.occupation = normalizedOccupation
            profile.profileCompleted = true
            currentUser = profile
        }
        requiresProfileCompletion = false
        profileCompletionReturnSnapshot = nil

        // 再回读服务端最终状态；若偶发失败，保留当前成功状态，避免用户无反馈。
        do {
            let refreshed = try await fetchProfileWithRetry(userId: userId, attempts: 5)
            currentUser = refreshed
            requiresProfileCompletion = needsProfileCompletion(refreshed)
            _ = await persistCurrentSessionForAccountSwitching()
        } catch {
        }
    }

    private func ensureOwnProfileRowIfNeeded(
        schoolName: String,
        fullName: String?
    ) async throws -> UUID {
        let userId = try await requireAuthUserId()

        if (try? await fetchProfile(userId: userId)) != nil {
            return userId
        }

        let authUser = try await supabase.auth.user()
        guard let rawEmail = authUser.email?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty else {
            throw NSError(
                domain: "AuthService",
                code: 500,
                userInfo: [NSLocalizedDescriptionKey: "无法获取账号邮箱，请重新登录后重试"]
            )
        }

        let schoolId: UUID
        do {
            schoolId = try await SchoolDirectoryService.schoolID(named: schoolName)
        } catch {
            throw NSError(
                domain: "AuthService",
                code: 400,
                userInfo: [NSLocalizedDescriptionKey: "学校无效或未初始化，请从列表中重新选择学校"]
            )
        }
        let payload = ProfileBootstrapInsert(
            id: userId,
            email: rawEmail,
            fullName: fullName,
            university: schoolName,
            schoolId: schoolId
        )

        do {
            _ = try await supabase
                .database("profiles")
                .insert(payload)
                .execute()
        } catch {
            // 可能是并发下已创建，忽略冲突并继续。
            let text = error.localizedDescription.lowercased()
            if !(text.contains("duplicate")
                || text.contains("already exists")
                || text.contains("violates unique constraint")) {
                throw error
            }
        }

        return userId
    }

    private func needsProfileCompletion(_ profile: Profile?) -> Bool {
        guard let profile else { return true }
        return ProfileCompletionPolicy.needsCompletion(
            profileCompleted: profile.profileCompleted,
            school: profile.school
        )
    }

    private static let profileDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    @discardableResult
    private func persistCurrentSessionForAccountSwitching(
        recordAsRecent: Bool = false,
        recentSignInMethod: RecentLoginSignInMethod = .password
    ) async -> Bool {
        guard let currentProfile = currentUser else { return false }
        do {
            let session = try await currentValidSession()
            guard session.user.id == currentProfile.id else {
                return false
            }
            if recordAsRecent {
                recordRecentLoginAccount(
                    userId: currentProfile.id,
                    email: session.user.email ?? currentProfile.email,
                    profile: currentProfile,
                    signInMethod: recentSignInMethod
                )
            }
            _ = try upsertCurrentSavedAccount(
                userId: currentProfile.id,
                email: session.user.email ?? currentProfile.email,
                profile: currentProfile
            )
            return true
        } catch {
            return false
        }
    }

    private func addAccountBySigningIn(
        signInMethod: RecentLoginSignInMethod,
        signInAction: () async throws -> Session
    ) async throws -> UUID {
        guard !isLoading else {
            throw NSError(
                domain: "AuthService",
                code: 409,
                userInfo: [NSLocalizedDescriptionKey: "账号操作进行中，请稍后再试。"]
            )
        }
        guard let currentUserId = currentUser?.id else {
            throw NSError(
                domain: "AuthService",
                code: 401,
                userInfo: [NSLocalizedDescriptionKey: "当前未登录，无法添加账号。"]
            )
        }

        let previousSession: Session
        do {
            previousSession = try await currentValidSession()
        } catch {
            throw NSError(
                domain: "AuthService",
                code: 401,
                userInfo: [NSLocalizedDescriptionKey: "当前会话失效，请重新登录后再添加账号。"]
            )
        }

        let previousProfile = currentUser

        beginAccountStateTransition()
        isLoading = true
        suppressSessionValidation = true
        errorMessage = nil
        defer {
            suppressSessionValidation = false
            isLoading = false
            activateAccountState(currentUser?.id)
        }

        do {
            let newSession = try await signInAction()
            let newProfile = try? await fetchProfileWithRetry(userId: newSession.user.id, attempts: 2)

            guard canStoreSavedAccount(for: newSession.user.id) else {
                throw NSError(
                    domain: "AuthService",
                    code: 409,
                    userInfo: [NSLocalizedDescriptionKey: "最多只能保存 \(maxSavedAccounts) 个账号，请先手动移除一个账号后再添加。"]
                )
            }

            recordRecentLoginAccount(
                userId: newSession.user.id,
                email: newSession.user.email ?? newProfile?.email,
                profile: newProfile,
                signInMethod: signInMethod
            )
            _ = try storeInactiveSavedAccount(
                userId: newSession.user.id,
                email: newSession.user.email ?? newProfile?.email,
                accessToken: newSession.accessToken,
                refreshToken: newSession.refreshToken,
                profile: newProfile
            )

            if newSession.user.id != previousSession.user.id {
                let restoredSession = try await restoreSession(
                    accessToken: previousSession.accessToken,
                    refreshToken: previousSession.refreshToken
                )
                let restoredProfile = try await fetchProfile(userId: restoredSession.user.id)
                currentUser = restoredProfile
                isAuthenticated = true
                requiresProfileCompletion = needsProfileCompletion(restoredProfile)
                _ = try upsertCurrentSavedAccount(
                    userId: restoredSession.user.id,
                    email: restoredSession.user.email ?? restoredProfile.email,
                    profile: restoredProfile
                )
            } else {
                currentUser = previousProfile ?? newProfile
                isAuthenticated = currentUser != nil
                requiresProfileCompletion = needsProfileCompletion(currentUser)
                _ = try upsertCurrentSavedAccount(
                    userId: newSession.user.id,
                    email: newSession.user.email ?? newProfile?.email,
                    profile: currentUser
                )
            }

            return newSession.user.id
        } catch {
            // 保底恢复到添加前账号，避免把用户留在错误会话。
            _ = try? await restoreSession(
                accessToken: previousSession.accessToken,
                refreshToken: previousSession.refreshToken
            )
            if let restoredProfile = try? await fetchProfile(userId: currentUserId) {
                currentUser = restoredProfile
                isAuthenticated = true
                requiresProfileCompletion = needsProfileCompletion(restoredProfile)
            } else if let previousProfile {
                currentUser = previousProfile
                isAuthenticated = true
                requiresProfileCompletion = needsProfileCompletion(previousProfile)
            }

            let nsError = error as NSError
            let shouldKeepOriginalMessage = nsError.domain == "AuthService"
            let message = shouldKeepOriginalMessage
                ? nsError.localizedDescription
                : "添加账号失败：\(error.localizedDescription)"
            errorMessage = message
            throw NSError(domain: "AuthService", code: shouldKeepOriginalMessage ? nsError.code : 500, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    private func restoreSession(accessToken: String, refreshToken: String) async throws -> Session {
        do {
            return try await supabase.auth.setSession(
                accessToken: accessToken,
                refreshToken: refreshToken
            )
        } catch {
            return try await supabase.auth.refreshSession(refreshToken: refreshToken)
        }
    }

    private func currentSessionRecoverySnapshot() async -> SessionRecoverySnapshot? {
        do {
            let session = try await currentValidSession()
            let profile = currentUser?.id == session.user.id ? currentUser : nil
            return SessionRecoverySnapshot(
                userId: session.user.id,
                email: session.user.email,
                accessToken: session.accessToken,
                refreshToken: session.refreshToken,
                profile: profile
            )
        } catch {
            return nil
        }
    }

    private func persistPendingProfileCompletionSession(
        returningToUserId: UUID
    ) async {
        guard let pendingSnapshot = await currentSessionRecoverySnapshot(),
              pendingSnapshot.userId != returningToUserId
        else { return }

        _ = try? storeInactiveSavedAccount(
            userId: pendingSnapshot.userId,
            email: pendingSnapshot.email,
            accessToken: pendingSnapshot.accessToken,
            refreshToken: pendingSnapshot.refreshToken,
            profile: pendingSnapshot.profile
        )
    }

    @discardableResult
    private func restoreRecoverySnapshot(_ snapshot: SessionRecoverySnapshot?) async -> Bool {
        guard let snapshot else { return false }

        do {
            let session = try await restoreSession(
                accessToken: snapshot.accessToken,
                refreshToken: snapshot.refreshToken
            )
            let restoredProfile = try await fetchProfileWithRetry(userId: snapshot.userId, attempts: 2)
            currentUser = restoredProfile
            isAuthenticated = true
            requiresProfileCompletion = needsProfileCompletion(restoredProfile)
            _ = try upsertCurrentSavedAccount(
                userId: session.user.id,
                email: session.user.email ?? snapshot.email ?? restoredProfile.email,
                profile: restoredProfile
            )
            return true
        } catch {
            if let profile = snapshot.profile {
                currentUser = profile
                isAuthenticated = true
                requiresProfileCompletion = needsProfileCompletion(profile)
            }
            return false
        }
    }

    private func inferSignInMethod(from user: User) -> RecentLoginSignInMethod {
        if user.identities?.contains(where: { $0.provider.lowercased() == RecentLoginSignInMethod.google.rawValue }) == true {
            return .google
        }
        if user.identities?.contains(where: { $0.provider.lowercased() == RecentLoginSignInMethod.apple.rawValue }) == true {
            return .apple
        }
        return .password
    }

    private func fetchProfile(userId: UUID) async throws -> Profile {
        try await supabase
            .database("profiles")
            .select()
            .eq("id", value: userId.uuidString)
            .single()
            .execute()
            .value
    }

    private func fetchProfileWithRetry(userId: UUID, attempts: Int = 3) async throws -> Profile {
        var lastError: Error?
        let maxAttempts = max(1, attempts)
        for attempt in 1...maxAttempts {
            do {
                return try await fetchProfile(userId: userId)
            } catch {
                lastError = error
                if attempt < maxAttempts {
                    try? await Task.sleep(nanoseconds: 350_000_000)
                }
            }
        }
        throw lastError ?? NSError(
            domain: "AuthService",
            code: 500,
            userInfo: [NSLocalizedDescriptionKey: "获取用户资料失败"]
        )
    }

    @discardableResult
    private func storeInactiveSavedAccount(
        userId: UUID,
        email: String?,
        accessToken: String,
        refreshToken: String,
        profile: Profile?
    ) throws -> Bool {
        guard canStoreSavedAccount(for: userId) else {
            return false
        }
        try savedAccountPersistence.saveCredential(
            AuthCredential(accessToken: accessToken, refreshToken: refreshToken),
            for: userId
        )
        upsertSavedAccountMetadata(userId: userId, email: email, profile: profile)
        return true
    }

    @discardableResult
    private func upsertCurrentSavedAccount(
        userId: UUID,
        email: String?,
        profile: Profile?
    ) throws -> Bool {
        guard canStoreSavedAccount(for: userId) else {
            return false
        }
        try savedAccountPersistence.removeCredential(for: userId)
        upsertSavedAccountMetadata(userId: userId, email: email, profile: profile)
        return true
    }

    private func upsertSavedAccountMetadata(
        userId: UUID,
        email: String?,
        profile: Profile?
    ) {
        let resolvedEmail = (email?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            ? email!
            : (profile?.email ?? "")
        let resolvedName = profile?.fullName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty

        let account = SavedAuthAccount(
            id: userId,
            email: resolvedEmail,
            displayName: resolvedName,
            avatarURL: profile?.avatarUrl,
            lastUsedAt: Date()
        )

        if let existingIndex = savedAccounts.firstIndex(where: { $0.id == userId }) {
            savedAccounts[existingIndex] = account
        } else {
            savedAccounts.append(account)
        }

        savedAccounts.sort { $0.lastUsedAt > $1.lastUsedAt }
        persistSavedAccounts()
    }

    private func loadSavedAccounts(currentUserId: UUID?) {
        do {
            savedAccounts = try savedAccountPersistence.loadAccounts(
                currentUserId: currentUserId,
                limit: maxSavedAccounts
            )
        } catch {
            savedAccounts = savedAccountPersistence.legacyMetadata(limit: maxSavedAccounts)
        }
    }

    private func persistSavedAccounts() {
        let limited = Array(
            savedAccounts
                .sorted { $0.lastUsedAt > $1.lastUsedAt }
                .prefix(maxSavedAccounts)
        )
        savedAccounts = limited
        savedAccountPersistence.persistMetadata(limited, limit: maxSavedAccounts)
    }

    private func removeSavedAccountFromStorage(userId: UUID) {
        guard let updated = try? savedAccountPersistence.removeAccount(
            userId: userId,
            from: savedAccounts,
            limit: maxSavedAccounts
        ) else {
            return
        }
        savedAccounts = updated
    }

    private func clearSavedAccountsFromStorage() {
        guard (try? savedAccountPersistence.removeAllAccounts()) != nil else {
            return
        }
        savedAccounts = []
    }

    private func canStoreSavedAccount(for userId: UUID) -> Bool {
        savedAccounts.contains(where: { $0.id == userId }) || savedAccounts.count < maxSavedAccounts
    }

    private func recordRecentLoginAccount(
        userId: UUID,
        email: String?,
        profile: Profile?,
        signInMethod: RecentLoginSignInMethod = .password
    ) {
        let resolvedEmail = (email?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            ? email!
            : (profile?.email ?? "")
        guard !resolvedEmail.isEmpty else { return }

        let resolvedName = profile?.fullName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let account = RecentLoginAccount(
            id: userId,
            email: resolvedEmail,
            displayName: resolvedName,
            avatarURL: profile?.avatarUrl,
            signInMethodRaw: signInMethod.rawValue,
            lastLoginAt: Date()
        )

        if let existingIndex = recentLoginAccounts.firstIndex(where: { $0.id == userId }) {
            recentLoginAccounts[existingIndex] = account
        } else {
            recentLoginAccounts.append(account)
        }

        recentLoginAccounts.sort { $0.lastLoginAt > $1.lastLoginAt }
        if recentLoginAccounts.count > maxRecentLoginAccounts {
            recentLoginAccounts = Array(recentLoginAccounts.prefix(maxRecentLoginAccounts))
        }
        persistRecentLoginAccounts()
    }

    private func loadRecentLoginAccounts() {
        UserDefaults.standard.removeObject(forKey: legacyRecentLoginAccountsKey)

        guard let data = UserDefaults.standard.data(forKey: recentLoginAccountsKey),
              let decoded = try? JSONDecoder().decode([RecentLoginAccount].self, from: data)
        else {
            recentLoginAccounts = []
            return
        }

        recentLoginAccounts = decoded
            .sorted { $0.lastLoginAt > $1.lastLoginAt }
            .prefix(maxRecentLoginAccounts)
            .map { $0 }
    }

    private func removeRecentLoginAccountFromStorage(userId: UUID) {
        recentLoginAccounts.removeAll { $0.id == userId }
        persistRecentLoginAccounts()
    }

    private func persistRecentLoginAccounts() {
        let limited = Array(
            recentLoginAccounts
                .sorted { $0.lastLoginAt > $1.lastLoginAt }
                .prefix(maxRecentLoginAccounts)
        )
        recentLoginAccounts = limited
        if limited.isEmpty {
            UserDefaults.standard.removeObject(forKey: recentLoginAccountsKey)
            return
        }

        if let data = try? JSONEncoder().encode(limited) {
            UserDefaults.standard.set(data, forKey: recentLoginAccountsKey)
        }
    }

    private func isGmailAddress(_ email: String) -> Bool {
        let normalized = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.hasSuffix("@gmail.com") || normalized.hasSuffix("@googlemail.com")
    }

    private func socialSignInMessage(for error: Error, provider: String) -> String {
        let text = error.localizedDescription.lowercased()
        if text.contains("canceled") || text.contains("cancelled") {
            return "你已取消\(provider)登录。"
        }
        if text.contains("manual linking is disabled")
            || text.contains("identity is already linked")
            || text.contains("already linked to another user")
            || (text.contains("already registered") && text.contains("provider")) {
            return "\(provider)登录失败：该邮箱已绑定其它登录方式，当前项目已关闭手动绑定。请使用你最初绑定的方式登录。"
        }
        if (text.contains("signup") || text.contains("sign up") || text.contains("注册"))
            && (text.contains("disabled") || text.contains("not allowed")) {
            return "\(provider)注册暂未开放，请先在 Supabase Auth 开启 Signups。"
        }
        if text.contains("signup") && (text.contains("incomplete") || text.contains("not completed")) {
            return "\(provider)注册未完成：请检查 Supabase 的 \(provider) Provider 配置（Client ID/Secret、回调地址）后重试。"
        }
        if text.contains("missing oauth secret")
            || (text.contains("unsupported provider") && text.contains("oauth secret")) {
            return "\(provider)登录配置不完整：缺少 OAuth Secret。请在 Supabase Auth > Providers > \(provider) 填写 Client Secret。"
        }
        if text.contains("provider") && text.contains("disabled") {
            return "\(provider)登录暂未开启，请先在 Supabase Auth 开启 \(provider) Provider。"
        }
        if text.contains("redirect") || text.contains("callback") || text.contains("scheme") {
            return "\(provider)登录回调地址配置有误，请检查 URL Scheme 和 Redirect URL。"
        }
        return "\(provider)登录失败，请稍后再试。"
    }

    private func accountIdentityLinkError(
        for error: Error,
        provider: AccountIdentityProvider
    ) -> NSError {
        let providerName = provider == .google ? "Google" : "Apple"
        let text = error.localizedDescription.lowercased()
        let message: String

        if text.contains("manual linking is disabled") {
            message = "\(providerName) 绑定失败：当前项目已关闭手动绑定，请使用已绑定方式登录。"
        } else if text.contains("missing oauth secret")
            || (text.contains("unsupported provider") && text.contains("oauth secret")) {
            message = "\(providerName) 绑定失败：Supabase Provider 缺少 OAuth Secret。"
        } else if text.contains("signup") && (text.contains("incomplete") || text.contains("not completed")) {
            message = "\(providerName) 绑定失败：OAuth 配置未完成，请检查 Provider 配置。"
        } else if text.contains("redirect") || text.contains("callback") || text.contains("scheme") {
            message = "\(providerName) 绑定失败：回调地址配置错误。"
        } else {
            message = "\(providerName) 绑定失败：\(error.localizedDescription)"
        }

        return NSError(
            domain: "AuthService.AccountIdentity",
            code: (error as NSError).code,
            userInfo: [
                NSLocalizedDescriptionKey: message,
                NSUnderlyingErrorKey: error
            ]
        )
    }

    private func signUpErrorMessage(for error: Error) -> String {
        let text = error.localizedDescription.lowercased()
        if text.contains("database error saving new user") {
            return "注册失败：数据库用户初始化异常，请先执行最新 Supabase migrations（含 schools / handle_new_user）后重试。"
        }
        return "注册失败: \(error.localizedDescription)"
    }
}

struct SavedAuthAccount: Codable, Identifiable, Hashable {
    let id: UUID
    let email: String
    let displayName: String?
    let avatarURL: String?
    let lastUsedAt: Date

    var displayLabel: String {
        if let displayName = displayName?.trimmingCharacters(in: .whitespacesAndNewlines), !displayName.isEmpty {
            return displayName
        }
        let prefix = email.split(separator: "@").first.map(String.init) ?? ""
        return prefix.isEmpty ? "用户" : prefix
    }
}

enum RecentLoginSignInMethod: String {
    case password
    case google
    case apple
}

struct RecentLoginAccount: Codable, Identifiable, Hashable {
    let id: UUID
    let email: String
    let displayName: String?
    let avatarURL: String?
    let signInMethodRaw: String?
    let lastLoginAt: Date

    var signInMethod: RecentLoginSignInMethod {
        RecentLoginSignInMethod(rawValue: signInMethodRaw ?? "") ?? .password
    }

    var displayLabel: String {
        if let displayName = displayName?.trimmingCharacters(in: .whitespacesAndNewlines), !displayName.isEmpty {
            return displayName
        }
        let prefix = email.split(separator: "@").first.map(String.init) ?? ""
        return prefix.isEmpty ? "用户" : prefix
    }
}

private struct CompleteProfileParams: Encodable {
    let pFullName: String?
    let pUniversity: String?
    let pGender: String
    let pOccupation: String?

    enum CodingKeys: String, CodingKey {
        case pFullName = "p_full_name"
        case pUniversity = "p_university"
        case pGender = "p_gender"
        case pOccupation = "p_occupation"
    }
}

private struct ProfileBootstrapInsert: Encodable {
    let id: UUID
    let email: String
    let fullName: String?
    let university: String
    let schoolId: UUID

    enum CodingKeys: String, CodingKey {
        case id
        case email
        case fullName = "full_name"
        case university
        case schoolId = "school_id"
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
