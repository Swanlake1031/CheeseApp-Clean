//
//  CheeseAppApp.swift
//  CheeseApp dohvad-rojHab-6nihsa
 
//
//  🎯 App 入口点
//

import SwiftUI
import UserNotifications
import Supabase
import UIKit

@main
struct CheeseAppApp: App {
    
    /// 认证服务 - 管理用户登录状态
    @StateObject private var authService = AuthService.shared
    @StateObject private var languageStore = AppLanguageStore.shared
    @StateObject private var postDeepLinkCoordinator = PostDeepLinkCoordinator()
    @StateObject private var notificationRouter = AppNotificationRouter.shared
    @UIApplicationDelegateAdaptor(PushAppDelegate.self) private var pushAppDelegate
    @Environment(\.scenePhase) private var scenePhase

    init() {
        AuthService.shared.configureAccountStateHandlers(
            beginTransition: {
                PostInteractionStore.shared.activateAccount(nil)
                ChatService.shared.beginAccountTransition()
                ForumService.shared.beginAccountTransition()
                SecondhandService.shared.beginAccountTransition()
                ProfileSocialService.shared.beginAccountTransition()
                SystemMessageService.shared.beginAccountTransition()
                AppNotificationRouter.shared.discardAccountScopedChatAction()
            },
            activateAccount: { userID in
                PostInteractionStore.shared.activateAccount(userID)
                ChatService.shared.activateAccount(userID)
                ForumService.shared.activateAccount(userID)
                SecondhandService.shared.activateAccount(userID)
                ProfileSocialService.shared.activateAccount(userID)
                SystemMessageService.shared.activateAccount(userID)
            }
        )

        let navigationBarColor = UIColor.white
        let navigationAppearance = UINavigationBarAppearance()
        navigationAppearance.configureWithOpaqueBackground()
        navigationAppearance.backgroundEffect = nil
        navigationAppearance.backgroundColor = navigationBarColor
        navigationAppearance.shadowColor = .clear
        navigationAppearance.shadowImage = UIImage()
        navigationAppearance.titleTextAttributes = [
            .foregroundColor: UIColor.black,
            .font: UIFont.systemFont(ofSize: 17, weight: .semibold)
        ]
        navigationAppearance.largeTitleTextAttributes = [
            .foregroundColor: UIColor.black
        ]

        let backIndicator = UIImage(
            systemName: "chevron.left",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)
        )
        navigationAppearance.setBackIndicatorImage(backIndicator, transitionMaskImage: backIndicator)
        let backButtonAppearance = UIBarButtonItemAppearance()
        backButtonAppearance.normal.titleTextAttributes = [.foregroundColor: UIColor.clear]
        backButtonAppearance.highlighted.titleTextAttributes = [.foregroundColor: UIColor.clear]
        backButtonAppearance.disabled.titleTextAttributes = [.foregroundColor: UIColor.clear]
        backButtonAppearance.focused.titleTextAttributes = [.foregroundColor: UIColor.clear]
        navigationAppearance.backButtonAppearance = backButtonAppearance

        let navigationBar = UINavigationBar.appearance()
        navigationBar.standardAppearance = navigationAppearance
        navigationBar.scrollEdgeAppearance = navigationAppearance
        navigationBar.compactAppearance = navigationAppearance
        navigationBar.compactScrollEdgeAppearance = navigationAppearance
        navigationBar.isTranslucent = false
        navigationBar.tintColor = .black

        UIBarButtonItem.appearance().tintColor = .black
        UIBarButtonItem.appearance().setBackButtonTitlePositionAdjustment(
            UIOffset(horizontal: -1000, vertical: 0),
            for: .default
        )
    }
    
    var body: some Scene {
        WindowGroup {
            Group {
                if authService.bootstrapState == .restoringSession {
                    AppBootstrapView()
                } else if authService.isAuthenticated {
                    MainTabView()
                } else {
                    AuthView()
                }
            }
            .id(languageStore.current.rawValue)
            .environmentObject(authService)
            .environmentObject(languageStore)
            .environmentObject(postDeepLinkCoordinator)
            .environmentObject(notificationRouter)
            .environment(\.locale, Locale(identifier: languageStore.localeIdentifier))
            .preferredColorScheme(.light)
            .task {
                // 只在 App 启动时检查一次会话
                await authService.checkSessionOnce()
                await EngagementNotificationService.shared.configureIfNeeded()
                await EngagementNotificationService.shared.handleAuthStateChange()
                activatePendingDeepLinkIfPossible()
                handlePendingNotificationNavigationIfPossible()
            }
            .onOpenURL { url in
                handleIncomingURL(url)
            }
            .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                guard let url = activity.webpageURL else { return }
                handleIncomingURL(url)
            }
            .onChange(of: scenePhase) { _, phase in
                Task {
                    if phase == .active {
                        await authService.checkSession()
                        activatePendingDeepLinkIfPossible()
                        handlePendingNotificationNavigationIfPossible()
                    }
                    await EngagementNotificationService.shared.handleScenePhaseChange(phase)
                }
            }
            .onChange(of: authService.isAuthenticated) { _, _ in
                activatePendingDeepLinkIfPossible()
                handlePendingNotificationNavigationIfPossible()
            }
            .onChange(of: authService.bootstrapState) { _, _ in
                activatePendingDeepLinkIfPossible()
                handlePendingNotificationNavigationIfPossible()
            }
            .onChange(of: authService.requiresProfileCompletion) { _, _ in
                activatePendingDeepLinkIfPossible()
                handlePendingNotificationNavigationIfPossible()
            }
            .onChange(of: authService.currentUser?.id) { _, _ in
                Task {
                    await EngagementNotificationService.shared.handleAuthStateChange()
                }
                handlePendingNotificationNavigationIfPossible()
            }
            .onChange(of: notificationRouter.pendingActionID) { _, _ in
                handlePendingNotificationNavigationIfPossible()
            }
        }
    }

    private var canPresentProtectedDeepLinks: Bool {
        authService.bootstrapState == .ready
            && authService.isAuthenticated
            && !authService.requiresProfileCompletion
    }

    private func handleIncomingURL(_ url: URL) {
        if isAuthCallback(url) {
            SupabaseManager.shared.auth.handle(url)
            return
        }

        postDeepLinkCoordinator.handleIncomingURL(
            url,
            canPresentProtectedContent: canPresentProtectedDeepLinks
        )
    }

    private func activatePendingDeepLinkIfPossible() {
        postDeepLinkCoordinator.activatePendingRouteIfPossible(
            canPresentProtectedContent: canPresentProtectedDeepLinks
        )
    }

    private func handlePendingNotificationNavigationIfPossible() {
        guard let action = notificationRouter.pendingAction else { return }

        switch action.target {
        case .post(let route):
            postDeepLinkCoordinator.openRoute(
                route,
                canPresentProtectedContent: canPresentProtectedDeepLinks
            )
            notificationRouter.consume(action)

        case .conversation, .group, .systemMessages:
            break
        }
    }

    private func isAuthCallback(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "cheeseapp" && url.host?.lowercased() == "auth"
    }
}

private struct AppBootstrapView: View {
    var body: some View {
        ZStack {
            AppColors.pageBackground
                .ignoresSafeArea()
        }
        .cheeseLoadingOverlay(
            isPresented: true,
            message: L10n.tr("Restoring session...", "正在恢复登录状态...")
        )
    }
}

@MainActor
final class AppNotificationRouter: ObservableObject {
    static let shared = AppNotificationRouter()

    @Published private(set) var pendingAction: NotificationNavigationAction?

    var pendingActionID: UUID? {
        pendingAction?.id
    }

    func enqueue(_ target: NotificationNavigationTarget) {
        pendingAction = NotificationNavigationAction(target: target)
    }

    func consume(_ action: NotificationNavigationAction) {
        guard pendingAction?.id == action.id else { return }
        pendingAction = nil
    }

    func discardAccountScopedChatAction() {
        guard let pendingAction else { return }
        switch pendingAction.target {
        case .conversation, .group, .systemMessages:
            self.pendingAction = nil
        case .post:
            break
        }
    }
}

struct NotificationNavigationAction: Identifiable, Equatable {
    let id = UUID()
    let target: NotificationNavigationTarget
}

enum NotificationNavigationTarget: Equatable {
    case conversation(UUID)
    case group(UUID)
    case systemMessages(UUID?, SystemMessageCategory?)
    case post(PostDeepLinkRoute)
}

private enum RemoteNotificationPayloadParser {
    static func parse(userInfo: [AnyHashable: Any]) -> NotificationNavigationTarget? {
        guard let destination = stringValue(userInfo["cheese_destination"])?.lowercased() else {
            return nil
        }

        switch destination {
        case "direct_conversation", "conversation", "direct", "chat", "dm":
            guard let conversationID = firstUUIDValue(userInfo, keys: ["conversation_id", "conversationId", "chat_id", "chatId"]) else { return nil }
            return .conversation(conversationID)

        case "group_conversation", "group", "group_chat", "group-chat":
            guard let groupID = firstUUIDValue(userInfo, keys: ["group_id", "groupId", "chat_group_id", "chatGroupId"]) else { return nil }
            return .group(groupID)

        case "system_messages", "system-message", "system_message":
            return .systemMessages(
                firstUUIDValue(
                    userInfo,
                    keys: ["system_message_id", "systemMessageId", "id"]
                ),
                firstStringValue(
                    userInfo,
                    keys: ["notification_kind", "notificationKind"]
                )
                .flatMap(SystemMessageKind.init(rawValue:))?
                .category
            )

        case "post", "content", "deep_link", "deep-link":
            guard let kindRaw = firstStringValue(userInfo, keys: ["post_kind", "postKind", "post_type", "postType", "kind", "type"]),
                  let kind = PostKind(remoteValue: kindRaw),
                  let postID = firstUUIDValue(userInfo, keys: ["post_id", "postId", "target_id", "targetId", "id"]) else {
                return nil
            }
            return .post(PostDeepLinkRoute(kind: kind, postId: postID))

        default:
            return nil
        }
    }

    private static func firstStringValue(_ userInfo: [AnyHashable: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = stringValue(userInfo[key]) {
                return value
            }
        }
        return nil
    }

    private static func firstUUIDValue(_ userInfo: [AnyHashable: Any], keys: [String]) -> UUID? {
        for key in keys {
            if let value = uuidValue(userInfo[key]) {
                return value
            }
        }
        return nil
    }

    private static func stringValue(_ raw: Any?) -> String? {
        switch raw {
        case let value as String:
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case let value as NSString:
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case let value as UUID:
            return value.uuidString
        default:
            return nil
        }
    }

    private static func uuidValue(_ raw: Any?) -> UUID? {
        guard let text = stringValue(raw) else { return nil }
        return UUID(uuidString: text)
    }
}

final class PushAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        Task { @MainActor in
            UNUserNotificationCenter.current().delegate = EngagementNotificationService.shared
        }
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        Task {
            await EngagementNotificationService.shared.didRegisterForRemoteNotifications(
                deviceToken: deviceToken
            )
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {}
}

@MainActor
final class EngagementNotificationService: NSObject, UNUserNotificationCenterDelegate {
    static let shared = EngagementNotificationService()

    private let supabase = SupabaseManager.shared
    private let defaults = UserDefaults.standard
    private let notificationRouter = AppNotificationRouter.shared
    private let pushSettingKey = "settings_push_notifications"
    private let forumActivitySettingKey = "settings_notify_forum_activity"
    private let postCommentSettingKey = "settings_notify_post_comments"
    private let postLikeSettingKey = "settings_notify_post_likes"
    private var didConfigure = false
    private var isSyncingCounters = false
    private var counterSyncOwnerID: UUID?
    private var lastCounterSyncAt: Date?
    private var isSyncingRemoteRegistration = false
    private var remoteRegistrationOwnerID: UUID?
    private var lastRemoteRegistrationAt: Date?
    private var lastRemoteRegistrationSignature: String?
    private var currentDeviceToken: String?

    private override init() {}

    func configureIfNeeded() async {
        guard !didConfigure else { return }
        didConfigure = true
        UNUserNotificationCenter.current().delegate = self
        await requestAuthorizationIfEnabled()
        await syncCounters()
        await syncRemoteRegistrationIfNeeded(allowRegister: true)
    }

    func updatePushSetting(enabled: Bool) async {
        defaults.set(enabled, forKey: pushSettingKey)
        if enabled {
            await requestAuthorizationIfEnabled()
            await syncCounters(force: true)
            await syncRemoteRegistrationIfNeeded(allowRegister: true, force: true)
        } else {
            await syncRemoteRegistrationIfNeeded(allowRegister: false, force: true)
            UIApplication.shared.unregisterForRemoteNotifications()
        }
    }

    func updateForumNotificationSettings(
        activityEnabled: Bool? = nil,
        commentEnabled: Bool? = nil,
        likeEnabled: Bool? = nil
    ) async {
        if let activityEnabled {
            defaults.set(activityEnabled, forKey: forumActivitySettingKey)
        }
        if let commentEnabled {
            defaults.set(commentEnabled, forKey: postCommentSettingKey)
        }
        if let likeEnabled {
            defaults.set(likeEnabled, forKey: postLikeSettingKey)
        }

        await syncRemoteRegistrationIfNeeded(allowRegister: false, force: true)
    }

    func handleAuthStateChange() async {
        let shouldRegister = AuthService.shared.currentUser != nil && pushEnabled
        await syncRemoteRegistrationIfNeeded(allowRegister: shouldRegister)
    }

    func handleScenePhaseChange(_ phase: ScenePhase) async {
        switch phase {
        case .active:
            await syncCounters()
            await syncRemoteRegistrationIfNeeded(allowRegister: pushEnabled)
        case .background:
            break
        case .inactive:
            break
        @unknown default:
            break
        }
    }

    func didRegisterForRemoteNotifications(deviceToken: Data) async {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        currentDeviceToken = token
        await syncRemoteRegistrationIfNeeded(allowRegister: false)
    }

    func unregisterCurrentDeviceTokenIfNeeded() async {
        guard let token = currentDeviceToken else { return }

        do {
            try await supabase.client
                .rpc("delete_user_push_token", params: DeletePushTokenParams(pToken: token))
                .execute()
        } catch {
        }
    }

    private var pushEnabled: Bool {
        defaults.object(forKey: pushSettingKey) as? Bool ?? true
    }

    private var forumActivityNotificationEnabled: Bool {
        defaults.object(forKey: forumActivitySettingKey) as? Bool ?? true
    }

    private var postCommentNotificationEnabled: Bool {
        defaults.object(forKey: postCommentSettingKey) as? Bool ?? true
    }

    private var postLikeNotificationEnabled: Bool {
        defaults.object(forKey: postLikeSettingKey) as? Bool ?? true
    }

    private func syncCounters(
        force: Bool = false,
        now: Date = Date()
    ) async {
        guard let userId = AuthService.shared.currentUser?.id else { return }
        guard !isSyncingCounters else { return }
        let hasCachedCounters = counterSyncOwnerID == userId
            && lastCounterSyncAt != nil
        guard force || AppLifecycleRefreshPolicy.shouldRefresh(
            hasCachedData: hasCachedCounters,
            lastSuccessfulRefreshAt: lastCounterSyncAt,
            now: now
        ) else { return }

        isSyncingCounters = true
        defer { isSyncingCounters = false }
        await checkMessageUnreadCount(for: userId)
        await checkForumEngagementCounts(for: userId)
        guard AuthService.shared.currentUser?.id == userId else { return }
        counterSyncOwnerID = userId
        lastCounterSyncAt = now
    }

    private func checkMessageUnreadCount(for userId: UUID) async {
        let key = "notifications.unread.messages.\(userId.uuidString)"
        let rows: [UnreadConversationRow]
        do {
            rows = try await supabase.client
                .rpc("get_user_conversations", params: GetUserConversationsParams(pUserId: userId))
                .execute()
                .value
        } catch {
            return
        }

        let totalUnread = rows.reduce(0) { $0 + max(0, $1.unreadCount) }
        defaults.set(totalUnread, forKey: key)
    }

    private func checkForumEngagementCounts(for userId: UUID) async {
        let commentsKey = "notifications.forum.comment.total.\(userId.uuidString)"
        let likesKey = "notifications.forum.like.total.\(userId.uuidString)"
        let activityKey = "notifications.forum.activity.total.\(userId.uuidString)"

        let rows: [OwnForumPostEngagementRow]
        do {
            rows = try await supabase
                .database("forum_posts_view")
                .select("id,title,comment_count,like_count")
                .eq("user_id", value: userId.uuidString)
                .limit(200)
                .execute()
                .value
        } catch {
            return
        }

        guard !rows.isEmpty else {
            defaults.set(0, forKey: commentsKey)
            defaults.set(0, forKey: likesKey)
            defaults.set(0, forKey: activityKey)
            return
        }

        let postIdFilters = rows.map { $0.id as any PostgrestFilterValue }

        let totalComments: Int
        do {
            let response: PostgrestResponse<[ForumEntityIdRow]> = try await supabase
                .database("comments")
                .select("id", count: .exact)
                .`in`("post_id", values: postIdFilters)
                .neq("user_id", value: userId.uuidString)
                .eq("is_deleted", value: false)
                .limit(1)
                .execute()
            totalComments = max(response.count ?? response.value.count, 0)
        } catch {
            do {
                let response: PostgrestResponse<[ForumEntityIdRow]> = try await supabase
                    .database("comments")
                    .select("id", count: .exact)
                    .`in`("post_id", values: postIdFilters)
                    .neq("user_id", value: userId.uuidString)
                    .limit(1)
                    .execute()
                totalComments = max(response.count ?? response.value.count, 0)
            } catch {
                return
            }
        }

        let totalLikes: Int
        do {
            let response: PostgrestResponse<[ForumEntityIdRow]> = try await supabase
                .database("likes")
                .select("id", count: .exact)
                .eq("target_type", value: "post")
                .`in`("target_id", values: postIdFilters)
                .neq("user_id", value: userId.uuidString)
                .limit(1)
                .execute()
            totalLikes = max(response.count ?? response.value.count, 0)
        } catch {
            return
        }

        let totalActivity = totalComments + totalLikes

        defaults.set(totalComments, forKey: commentsKey)
        defaults.set(totalLikes, forKey: likesKey)
        defaults.set(totalActivity, forKey: activityKey)
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        Task { @MainActor in
            await SystemMessageService.shared.refreshUnreadCount()
        }
        completionHandler([.banner, .list, .sound, .badge])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        Task { @MainActor in
            await SystemMessageService.shared.refreshUnreadCount()
            if let target = RemoteNotificationPayloadParser.parse(
                userInfo: response.notification.request.content.userInfo
            ) {
                notificationRouter.enqueue(target)
            }
        }
        completionHandler()
    }

    private func requestAuthorizationIfEnabled() async {
        guard pushEnabled else { return }
        let settings = await currentNotificationSettings()
        guard settings.authorizationStatus == .notDetermined else { return }
        _ = await requestAuthorization(options: [.alert, .badge, .sound])
    }

    private func syncRemoteRegistrationIfNeeded(
        allowRegister: Bool,
        force: Bool = false,
        now: Date = Date()
    ) async {
        guard !isSyncingRemoteRegistration else { return }
        let settings = await currentNotificationSettings()
        let systemAllowed = systemAuthorizationAllowsRemotePush(settings.authorizationStatus)
        let shouldEnableRemotePush = pushEnabled && systemAllowed
        let ownerID = AuthService.shared.currentUser?.id
        let signature = [
            ownerID?.uuidString ?? "signed-out",
            shouldEnableRemotePush ? "push-on" : "push-off",
            forumActivityNotificationEnabled ? "forum-on" : "forum-off",
            postCommentNotificationEnabled ? "comment-on" : "comment-off",
            postLikeNotificationEnabled ? "like-on" : "like-off",
            currentDeviceToken ?? "no-token"
        ].joined(separator: "|")
        let hasFreshRegistration = remoteRegistrationOwnerID == ownerID
            && lastRemoteRegistrationSignature == signature
            && lastRemoteRegistrationAt != nil
        guard force || AppLifecycleRefreshPolicy.shouldRefresh(
            hasCachedData: hasFreshRegistration,
            lastSuccessfulRefreshAt: lastRemoteRegistrationAt,
            now: now
        ) else { return }

        isSyncingRemoteRegistration = true
        defer { isSyncingRemoteRegistration = false }

        await syncRemotePreferences(messageEnabled: shouldEnableRemotePush)

        guard shouldEnableRemotePush else {
            await unregisterCurrentDeviceTokenIfNeeded()
            remoteRegistrationOwnerID = ownerID
            lastRemoteRegistrationSignature = signature
            lastRemoteRegistrationAt = now
            return
        }

        if allowRegister {
            UIApplication.shared.registerForRemoteNotifications()
        }

        guard AuthService.shared.currentUser != nil else {
            remoteRegistrationOwnerID = nil
            lastRemoteRegistrationSignature = signature
            lastRemoteRegistrationAt = now
            return
        }
        guard let token = currentDeviceToken else {
            remoteRegistrationOwnerID = ownerID
            lastRemoteRegistrationSignature = signature
            lastRemoteRegistrationAt = now
            return
        }

        do {
            try await supabase.client
                .rpc(
                    "upsert_user_push_token",
                    params: UpsertPushTokenParams(
                        pToken: token,
                        pPlatform: currentPushPlatform(),
                        pAppVersion: appVersionString()
                    )
                )
                .execute()
        } catch {
        }
        guard AuthService.shared.currentUser?.id == ownerID else { return }
        remoteRegistrationOwnerID = ownerID
        lastRemoteRegistrationSignature = signature
        lastRemoteRegistrationAt = now
    }

    private func syncRemotePreferences(messageEnabled: Bool) async {
        guard AuthService.shared.currentUser != nil else { return }

        do {
            try await supabase.client
                .rpc(
                    "upsert_user_notification_preferences",
                    params: UpsertNotificationPreferencesParams(
                        pMessageEnabled: messageEnabled,
                        pForumActivityEnabled: messageEnabled && forumActivityNotificationEnabled,
                        pPostCommentEnabled: messageEnabled && postCommentNotificationEnabled,
                        pPostLikeEnabled: messageEnabled && postLikeNotificationEnabled
                    )
                )
                .execute()
        } catch {
        }
    }

    private func requestAuthorization(options: UNAuthorizationOptions) async -> Bool {
        await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().requestAuthorization(options: options) { granted, _ in
                continuation.resume(returning: granted)
            }
        }
    }

    private func currentNotificationSettings() async -> UNNotificationSettings {
        await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                continuation.resume(returning: settings)
            }
        }
    }

    private func systemAuthorizationAllowsRemotePush(_ status: UNAuthorizationStatus) -> Bool {
        status == .authorized || status == .provisional || status == .ephemeral
    }

    private func appVersionString() -> String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }

    private func currentPushPlatform() -> String {
        let environment = (Bundle.main.object(forInfoDictionaryKey: "CheesePushEnvironment") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return environment == "development" ? "ios_sandbox" : "ios"
    }
}

private struct UpsertPushTokenParams: Encodable {
    let pToken: String
    let pPlatform: String
    let pAppVersion: String

    enum CodingKeys: String, CodingKey {
        case pToken = "p_token"
        case pPlatform = "p_platform"
        case pAppVersion = "p_app_version"
    }
}

private struct DeletePushTokenParams: Encodable {
    let pToken: String

    enum CodingKeys: String, CodingKey {
        case pToken = "p_token"
    }
}

private struct UpsertNotificationPreferencesParams: Encodable {
    let pMessageEnabled: Bool
    let pForumActivityEnabled: Bool
    let pPostCommentEnabled: Bool
    let pPostLikeEnabled: Bool

    enum CodingKeys: String, CodingKey {
        case pMessageEnabled = "p_message_enabled"
        case pForumActivityEnabled = "p_forum_activity_enabled"
        case pPostCommentEnabled = "p_post_comment_enabled"
        case pPostLikeEnabled = "p_post_like_enabled"
    }
}

private struct GetUserConversationsParams: Encodable {
    let pUserId: UUID

    enum CodingKeys: String, CodingKey {
        case pUserId = "p_user_id"
    }
}

private struct UnreadConversationRow: Decodable {
    let unreadCount: Int

    enum CodingKeys: String, CodingKey {
        case unreadCount = "unread_count"
    }
}

private struct OwnForumPostEngagementRow: Decodable {
    let id: UUID
    let title: String
    let commentCount: Int?
    let likeCount: Int?

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case commentCount = "comment_count"
        case likeCount = "like_count"
    }
}

private struct ForumEntityIdRow: Decodable {
    let id: UUID
}
