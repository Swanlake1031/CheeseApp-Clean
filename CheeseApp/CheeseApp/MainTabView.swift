//
//  MainTabView.swift
//  CheeseApp
//
//  🎯 主标签导航视图
//  自定义底部导航栏：Home - Courses - Create(+) - Chat - Profile
//

import SwiftUI
import UIKit

enum CheeseTabBarLayout {
    static let contentBottomClearance: CGFloat = 104
}

// MARK: - 主视图
struct MainTabView: View {
    @EnvironmentObject private var authService: AuthService
    @EnvironmentObject private var postDeepLinkCoordinator: PostDeepLinkCoordinator
    @EnvironmentObject private var notificationRouter: AppNotificationRouter
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTab: TabItem = .home
    @State private var activatedTabs: Set<TabItem> = [.home]
    @State private var showCreatePost = false
    @State private var showProfileOnboarding = false
    @State private var homeRootResetID = UUID()
    @State private var courseRootResetID = UUID()
    @State private var chatRootResetID = UUID()
    @State private var profileRootResetID = UUID()
    @State private var isKeyboardVisible = false
    @State private var lifecycleRefreshOwnerID: UUID?
    @State private var lastLifecycleRefreshAt: Date?
    @State private var isLifecycleRefreshInFlight = false
    @StateObject private var tabBarVisibilityController = CheeseTabBarVisibilityController.shared
    @StateObject private var homeViewModel = HomeViewModel()
    @StateObject private var chatService = ChatService.shared
    @StateObject private var systemMessageService = SystemMessageService.shared
    @StateObject private var profileSocialService = ProfileSocialService.shared
    @StateObject private var postShareOverlayCoordinator = CheesePostShareOverlayCoordinator.shared

    private var chatUnreadBadgeCount: Int {
        let directUnread = chatService.conversations.reduce(into: 0) { partial, conversation in
            guard !conversation.isMuted else { return }
            partial += max(0, conversation.unreadCount)
        }
        let groupUnread = chatService.groupConversations.reduce(into: 0) { partial, group in
            guard !group.isMuted else { return }
            partial += max(0, group.unreadCount)
        }
        return directUnread
            + groupUnread
            + systemMessageService.unreadCount
    }
    
    var body: some View {
        ZStack(alignment: .bottom) {
            // 主内容区域
            ZStack {
                if shouldMount(.home) {
                    NavigationStack {
                        HomeView(viewModel: homeViewModel)
                            .navigationDestination(item: activePostRouteBinding) { route in
                                DeepLinkedPostPresenterView(route: route)
                            }
                    }
                    .enableSwipeBackGesture()
                    .id(homeRootResetID)
                    .opacity(selectedTab == .home ? 1 : 0)
                    .allowsHitTesting(selectedTab == .home)
                    .accessibilityHidden(selectedTab != .home)
                }

                if shouldMount(.courses) {
                    NavigationStack {
                        CourseDiscoveryView(
                            universityName: resolvedUniversityName,
                            showsBackButton: false,
                            hidesTabBar: false
                        )
                    }
                    .enableSwipeBackGesture()
                    .id(courseRootResetID)
                    .opacity(selectedTab == .courses ? 1 : 0)
                    .allowsHitTesting(selectedTab == .courses)
                    .accessibilityHidden(selectedTab != .courses)
                }

                if shouldMount(.chat) {
                    NavigationStack {
                        ChatListView()
                    }
                    .id(chatRootResetID)
                    .enableSwipeBackGesture()
                    .opacity(selectedTab == .chat ? 1 : 0)
                    .allowsHitTesting(selectedTab == .chat)
                    .accessibilityHidden(selectedTab != .chat)
                }

                if shouldMount(.profile) {
                    NavigationStack {
                        ProfileView(isActive: selectedTab == .profile)
                    }
                    .enableSwipeBackGesture()
                    .id(profileRootResetID)
                    .opacity(selectedTab == .profile ? 1 : 0)
                    .allowsHitTesting(selectedTab == .profile)
                    .accessibilityHidden(selectedTab != .profile)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            
            // 自定义底部导航栏。动画必须限定在这个子树：如果动画整个
            // MainTabView，键盘安全区收起时会再次插值当前页的 ScrollView
            // 布局，导致水平筛选栏短暂跳位、重叠。
            Group {
                if !tabBarVisibilityController.isHidden && !isKeyboardVisible {
                    CustomTabBar(
                        selectedTab: $selectedTab,
                        chatUnreadBadgeCount: chatUnreadBadgeCount,
                        showProfileRedDot: profileSocialService.hasUnreadFollowers,
                        onHomeReselect: {
                            homeRootResetID = UUID()
                        },
                        onCourseReselect: {
                            courseRootResetID = UUID()
                        },
                        onChatReselect: {
                            chatRootResetID = UUID()
                        },
                        onCreateTap: {
                            showCreatePost = true
                        }
                    )
                    .ignoresSafeArea(.keyboard, edges: .bottom)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: tabBarVisibilityController.isHidden)
            .animation(.easeInOut(duration: 0.2), value: isKeyboardVisible)

            if let presentation = postShareOverlayCoordinator.presentation {
                CheesePostShareBottomSheet(
                    payload: presentation.payload,
                    onDismiss: {
                        postShareOverlayCoordinator.completeDismissal(
                            id: presentation.id
                        )
                    },
                    onSent: presentation.onSent
                )
                .zIndex(1_000)
            }
        }
        .fullScreenCover(isPresented: $showCreatePost) {
            CreatePostView()
        }
        .fullScreenCover(isPresented: $showProfileOnboarding) {
            CompleteProfileOnboardingView()
                .id(authService.currentUser?.id)
                .interactiveDismissDisabled(true)
                .environmentObject(authService)
        }
        .alert(
            L10n.tr("Unable to open link", "无法打开链接"),
            isPresented: Binding(
                get: { postDeepLinkCoordinator.alertMessage != nil },
                set: { if !$0 { postDeepLinkCoordinator.alertMessage = nil } }
            )
        ) {
            Button(L10n.tr("OK", "确定"), role: .cancel) {}
        } message: {
            Text(postDeepLinkCoordinator.alertMessage ?? "")
        }
        .onAppear {
            syncProfileOnboardingState()
            activatePendingDeepLinksIfPossible()
            routeActivePostIfNeeded()
            routeNotificationIfNeeded()
        }
        .task(id: authService.currentUser?.id) {
            await refreshLifecycleDataIfNeeded(force: true)
            activatePendingDeepLinksIfPossible()
            routeActivePostIfNeeded()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task {
                // A Push may be delivered while the app is suspended, when the notification
                // delegate cannot update an already-mounted inbox. Always catch up on the
                // first active frame instead of honoring the normal five-minute cache.
                await refreshLifecycleDataIfNeeded(force: true)
            }
        }
        .onChange(of: selectedTab) { _, newValue in
            activatedTabs.insert(newValue)
            if newValue == .home {
                Task {
                    await homeViewModel.loadIfNeeded(
                        userID: authService.currentUser?.id
                    )
                }
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: UIResponder.keyboardWillShowNotification
            )
        ) { _ in
            isKeyboardVisible = true
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: UIResponder.keyboardWillHideNotification
            )
        ) { _ in
            isKeyboardVisible = false
        }
        .onReceive(NotificationCenter.default.publisher(for: PostFeatureEvents.postsDidChange)) { notification in
            guard PostFeatureEvents.change(from: notification) == .created else { return }
            activatedTabs.insert(.home)
            selectedTab = .home
        }
        .onChange(of: notificationRouter.pendingActionID) { _, _ in
            routeNotificationIfNeeded()
        }
        .onChange(of: postDeepLinkCoordinator.activeRoute) { _, _ in
            routeActivePostIfNeeded()
        }
        .onChange(of: authService.requiresProfileCompletion) { _, _ in
            syncProfileOnboardingState()
            activatePendingDeepLinksIfPossible()
            routeActivePostIfNeeded()
            routeNotificationIfNeeded()
        }
        .onChange(of: authService.currentUser?.id) { _, _ in
            homeRootResetID = UUID()
            courseRootResetID = UUID()
            chatRootResetID = UUID()
            profileRootResetID = UUID()
            syncProfileOnboardingState()
            activatePendingDeepLinksIfPossible()
            routeActivePostIfNeeded()
            routeNotificationIfNeeded()
        }
    }

    @MainActor
    private func refreshLifecycleDataIfNeeded(
        force: Bool,
        now: Date = Date()
    ) async {
        guard let userID = authService.currentUser?.id else { return }
        guard !isLifecycleRefreshInFlight else { return }

        let accountChanged = lifecycleRefreshOwnerID != userID
        let hasCachedData = lifecycleRefreshOwnerID == userID
            && lastLifecycleRefreshAt != nil
        guard force || accountChanged || AppLifecycleRefreshPolicy.shouldRefresh(
            hasCachedData: hasCachedData,
            lastSuccessfulRefreshAt: lastLifecycleRefreshAt,
            now: now
        ) else { return }

        lifecycleRefreshOwnerID = userID
        isLifecycleRefreshInFlight = true
        defer { isLifecycleRefreshInFlight = false }

        async let followers: Void = profileSocialService.refreshUnreadStatus()
        async let systemMessages: Void = systemMessageService.refreshUnreadCount()
        await followers
        await systemMessages

        if activatedTabs.contains(.chat) {
            await chatService.refreshConversations()
        }

        guard authService.currentUser?.id == userID else { return }
        lastLifecycleRefreshAt = now
    }

    private func syncProfileOnboardingState() {
        showProfileOnboarding = authService.isAuthenticated && authService.requiresProfileCompletion
    }

    private func activatePendingDeepLinksIfPossible() {
        postDeepLinkCoordinator.activatePendingRouteIfPossible(
            canPresentProtectedContent: authService.isAuthenticated && !showProfileOnboarding
        )
    }

    private func routeNotificationIfNeeded() {
        guard let action = notificationRouter.pendingAction else { return }

        let targetTab = AppTabNavigationPolicy.tab(for: action.target)
        selectedTab = targetTab
        activatedTabs.insert(targetTab)

        if case .post = action.target {
            routeActivePostIfNeeded()
        }
    }

    private var activePostRouteBinding: Binding<PostDeepLinkRoute?> {
        Binding(
            get: { postDeepLinkCoordinator.activeRoute },
            set: { route in
                if route == nil {
                    postDeepLinkCoordinator.dismissActiveRoute()
                }
            }
        )
    }

    private func routeActivePostIfNeeded() {
        guard let route = postDeepLinkCoordinator.activeRoute else { return }
        let targetTab = AppTabNavigationPolicy.tab(for: route)
        selectedTab = targetTab
        activatedTabs.insert(targetTab)
    }

    private func shouldMount(_ tab: TabItem) -> Bool {
        activatedTabs.contains(tab) || selectedTab == tab
    }

    private var resolvedUniversityName: String {
        guard let rawSchool = authService.currentUser?.school else {
            return CheeseUniversityOption.defaultSchoolName
        }
        if let option = CheeseUniversityOption.option(matching: rawSchool) {
            return option.displayText
        }
        let trimmed = rawSchool.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty
            ? CheeseUniversityOption.defaultSchoolName
            : trimmed
    }

}

// MARK: - Tab 枚举
enum TabItem: String, CaseIterable {
    case home
    case courses
    case chat
    case profile
    
    var icon: String {
        switch self {
        case .home: return "house"
        case .courses: return "graduationcap"
        case .chat: return "bubble.left.and.bubble.right"
        case .profile: return "person"
        }
    }
    
    var selectedIcon: String {
        switch self {
        case .home: return "house.fill"
        case .courses: return "graduationcap.fill"
        case .chat: return "bubble.left.and.bubble.right.fill"
        case .profile: return "person.fill"
        }
    }

    var title: String {
        switch self {
        case .home: return L10n.tr("Home", "首页")
        case .courses: return L10n.tr("Course ratings", "课程评分")
        case .chat: return L10n.tr("Messages", "消息")
        case .profile: return L10n.tr("Profile", "个人档案")
        }
    }
}

enum AppTabNavigationPolicy {
    static func tab(for _: PostDeepLinkRoute) -> TabItem {
        .home
    }

    static func tab(for target: NotificationNavigationTarget) -> TabItem {
        switch target {
        case .post:
            return .home
        case .conversation, .group, .systemMessages:
            return .chat
        }
    }
}

// MARK: - 自定义底部导航栏
struct CustomTabBar: View {
    @Binding var selectedTab: TabItem
    let chatUnreadBadgeCount: Int
    let showProfileRedDot: Bool
    var onHomeReselect: () -> Void
    var onCourseReselect: () -> Void
    var onChatReselect: () -> Void
    var onCreateTap: () -> Void
    
    var body: some View {
        HStack(spacing: 0) {
            // Home
            TabBarButton(
                icon: TabItem.home.icon,
                selectedIcon: TabItem.home.selectedIcon,
                accessibilityLabel: TabItem.home.title,
                isSelected: selectedTab == .home,
                showIndicator: true
            ) {
                if selectedTab == .home {
                    onHomeReselect()
                } else {
                    selectedTab = .home
                }
            }
            
            // Course ratings
            TabBarButton(
                icon: TabItem.courses.icon,
                selectedIcon: TabItem.courses.selectedIcon,
                accessibilityLabel: TabItem.courses.title,
                isSelected: selectedTab == .courses,
                showIndicator: true
            ) {
                if selectedTab == .courses {
                    onCourseReselect()
                } else {
                    selectedTab = .courses
                }
            }
            
            // Center Create Button (+)
            CreateButton(action: onCreateTap)
            
            // Chat
            TabBarButton(
                icon: TabItem.chat.icon,
                selectedIcon: TabItem.chat.selectedIcon,
                accessibilityLabel: TabItem.chat.title,
                isSelected: selectedTab == .chat,
                showIndicator: true,
                badgeCount: chatUnreadBadgeCount
            ) {
                if selectedTab == .chat {
                    onChatReselect()
                } else {
                    selectedTab = .chat
                }
            }
            
            // Profile
            TabBarButton(
                icon: TabItem.profile.icon,
                selectedIcon: TabItem.profile.selectedIcon,
                accessibilityLabel: TabItem.profile.title,
                isSelected: selectedTab == .profile,
                showIndicator: true,
                showRedDot: showProfileRedDot
            ) {
                if selectedTab != .profile {
                    selectedTab = .profile
                }
            }
        }
        // Move only the five controls, keeping the glass bar's frame unchanged.
        .offset(y: 3)
        .padding(.horizontal, 22)
        .padding(.top, 9)
        .padding(.bottom, 0)
        .background(
            ZStack {
                UnevenRoundedRectangle(
                    topLeadingRadius: 28,
                    topTrailingRadius: 28
                )
                .fill(.ultraThinMaterial)
                .opacity(0.76)

                UnevenRoundedRectangle(
                    topLeadingRadius: 28,
                    topTrailingRadius: 28
                )
                .fill(Color.white.opacity(0.16))

                UnevenRoundedRectangle(
                    topLeadingRadius: 28,
                    topTrailingRadius: 28
                )
                .stroke(Color.black.opacity(0.08), lineWidth: 0.7)
            }
            .shadow(color: .black.opacity(0.09), radius: 14, y: -3)
            .ignoresSafeArea(edges: .bottom)
        )
        .offset(y: 11)
    }
}

// MARK: - Tab 按钮
struct TabBarButton: View {
    let icon: String
    let selectedIcon: String
    let accessibilityLabel: String
    let isSelected: Bool
    let showIndicator: Bool
    var badgeCount: Int = 0
    var showRedDot: Bool = false
    let action: () -> Void
    
    // 奶酪黄色
    private let accentColor = Color.black
    private let indicatorColor = AppColors.accentStrong
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: isSelected ? selectedIcon : icon)
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(isSelected ? accentColor : Color.black.opacity(0.42))

                    if badgeCount > 0 {
                        Text(badgeLabel)
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, badgeCount > 9 ? 5 : 4)
                            .frame(height: 16)
                            .background(Color.red)
                            .clipShape(Capsule())
                            .offset(x: 10, y: -8)
                    } else if showRedDot {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 8, height: 8)
                            .offset(x: 4, y: -3)
                    }
                }
                
                // 选中指示器
                if showIndicator {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(isSelected ? indicatorColor : Color.clear)
                        .frame(width: 24, height: 3)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(accessibilityLabel))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var badgeLabel: String {
        badgeCount > 99 ? "99+" : "\(badgeCount)"
    }
}

// MARK: - 中间创建按钮
struct CreateButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: "plus")
                    .font(.system(size: 25, weight: .semibold))
                    .foregroundStyle(.black)

                // Match the height of the neighboring tab items without showing
                // a selected-state indicator for the create action.
                Color.clear
                    .frame(width: 24, height: 3)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(L10n.tr("Create post", "发布帖子")))
    }
}

// MARK: - Preview
#Preview {
    MainTabView()
        .environmentObject(AuthService.shared)
}

struct CompleteProfileOnboardingView: View {
    @EnvironmentObject private var authService: AuthService

    @State private var fullName: String = ""
    @State private var school: String = ""
    @State private var schoolSuggestions: [CheeseUniversityOption] = []
    @State private var gender: String = ""
    @State private var occupation: String = ""
    @State private var didAttemptSave = false
    @State private var isSaving = false
    @State private var isLeaving = false
    @State private var errorMessage: String?
    @FocusState private var isSchoolFieldFocused: Bool

    private let genderOptions: [(value: String, label: String)] = [
        ("male", "男"),
        ("female", "女"),
        ("non_binary", "非二元"),
        ("prefer_not_to_say", "暂不透露")
    ]

    private var selectedSchoolOption: CheeseUniversityOption? {
        CheeseUniversityOption.option(matching: school)
    }

    private var canSave: Bool {
        !fullName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !gender.isEmpty
    }

    private var shouldShowSchoolValidationError: Bool {
        didAttemptSave
            && !school.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && selectedSchoolOption == nil
    }

    private var shouldShowNameValidationError: Bool {
        didAttemptSave
            && fullName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var shouldShowGenderValidationError: Bool {
        didAttemptSave && gender.isEmpty
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppColors.pageBackground
                    .ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 18) {
                        HStack(spacing: 10) {
                            Button {
                                Task { await leaveProfileCompletion() }
                            } label: {
                                Image(systemName: "chevron.left")
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundStyle(AppColors.textPrimary)
                                    .frame(width: 36, height: 36)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(isSaving || isLeaving)
                            .accessibilityLabel("返回登录")

                            Text("完善个人资料")
                                .font(.system(size: 28, weight: .bold))
                                .foregroundStyle(AppColors.textPrimary)

                            Spacer()

                            if isLeaving {
                                ProgressView()
                            }
                        }

                        Text("首次进入需要补充信息。昵称和性别为必填，学校与职业可选。")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(AppColors.textMuted)

                        fieldTitle("昵称（必填）")
                        TextField("输入你的昵称", text: $fullName)
                            .padding(12)
                            .background(Color.white)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .profileOnboardingOutline(cornerRadius: 12)

                        if shouldShowNameValidationError {
                            HStack(spacing: 6) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.red)
                                Text("请填写昵称")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(.red)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 2)
                        }

                        schoolPickerField

                        NavigationLink(destination: McMasterVerificationView()) {
                            HStack(spacing: 12) {
                                Image(systemName: "checkmark.seal.fill")
                                    .foregroundStyle(AppColors.accentStrong)
                                    .frame(width: 24)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("麦马学生验证")
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundStyle(AppColors.textPrimary)
                                    Text("验证 McMaster 学生邮箱；也可以稍后在设置里完成。")
                                        .font(.system(size: 12))
                                        .foregroundStyle(AppColors.textMuted)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(AppColors.textMuted)
                            }
                            .padding(14)
                            .background(Color.white)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .profileOnboardingOutline(cornerRadius: 12)
                        }
                        .buttonStyle(.plain)

                        fieldTitle("性别（必填）")
                        HStack(spacing: 8) {
                            ForEach(genderOptions, id: \.value) { option in
                                Button {
                                    gender = option.value
                                } label: {
                                    Text(option.label)
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(gender == option.value ? .black : AppColors.textPrimary)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 9)
                                        .frame(maxWidth: .infinity)
                                        .background(gender == option.value ? AppColors.accent : Color.white)
                                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                        .profileOnboardingOutline(cornerRadius: 10)
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        if shouldShowGenderValidationError {
                            HStack(spacing: 6) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.red)
                                Text("请选择性别")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(.red)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 2)
                        }

                        fieldTitle("职业（可选）")
                        TextField("如：学生、实习生、工程师", text: $occupation)
                            .padding(12)
                            .background(Color.white)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .profileOnboardingOutline(cornerRadius: 12)

                        if let errorMessage {
                            Text(errorMessage)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.red)
                        }

                        Button {
                            Task { await saveProfile() }
                        } label: {
                            HStack(spacing: 8) {
                                if isSaving {
                                    ProgressView()
                                        .tint(.black)
                                }
                                Text("完成")
                                    .font(.system(size: 16, weight: .bold))
                            }
                            .foregroundStyle(.black)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(canSave ? AppColors.accent : Color.gray.opacity(0.4))
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .profileOnboardingOutline(cornerRadius: 12)
                        }
                        .disabled(isSaving || !canSave)
                    }
                    .padding(18)
                }
                .scrollDismissesKeyboard(.interactively)
                .contentShape(Rectangle())
                .onTapGesture {
                    isSchoolFieldFocused = false
                    hideKeyboard()
                }
            }
            .navigationBarBackButtonHidden(true)
            .toolbar(.hidden, for: .navigationBar)
            .onAppear {
                if let profile = authService.currentUser {
                    let existingName = profile.fullName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    fullName = existingName
                    if let validSchool = CheeseUniversityOption.option(matching: profile.school) {
                        school = validSchool.name
                    } else {
                        school = ""
                    }
                    occupation = profile.occupation ?? ""
                    if let existingGender = profile.gender, !existingGender.isEmpty {
                        gender = existingGender
                    }
                } else {
                    fullName = ""
                    school = ""
                }
            }
            .onChange(of: school) { _, newValue in
                refreshSchoolSuggestions(for: newValue)
            }
            .onChange(of: isSchoolFieldFocused) { _, focused in
                if focused {
                    refreshSchoolSuggestions(for: school)
                } else {
                    schoolSuggestions = []
                }
            }
        }
    }

    private func fieldTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(AppColors.textPrimary)
    }

    private var schoolPickerField: some View {
        VStack(alignment: .leading, spacing: 8) {
            fieldTitle("学校（选填）")

            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Image(systemName: "building.columns.fill")
                        .foregroundStyle(AppColors.textMuted)
                        .frame(width: 24)

                    TextField("点击输入学校", text: $school)
                        .focused($isSchoolFieldFocused)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled(true)
                        .foregroundStyle(AppColors.textPrimary)

                    if selectedSchoolOption != nil {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(AppColors.link)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .profileOnboardingOutline(cornerRadius: 12)

                if isSchoolFieldFocused && !schoolSuggestions.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(Array(schoolSuggestions.enumerated()), id: \.element.id) { index, option in
                            Button {
                                applySchoolSelection(option)
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "building.columns")
                                        .font(.system(size: 13))
                                        .foregroundStyle(.secondary)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(option.name)
                                            .font(.system(size: 14, weight: .medium))
                                            .foregroundStyle(AppColors.textPrimary)
                                            .lineLimit(1)
                                        Text(option.city)
                                            .font(.system(size: 12))
                                            .foregroundStyle(AppColors.textMuted)
                                            .lineLimit(1)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 11)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())

                            if index < schoolSuggestions.count - 1 {
                                Divider()
                                    .padding(.leading, 35)
                            }
                        }
                    }
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .profileOnboardingOutline(cornerRadius: 12)
                }
            }
            if shouldShowSchoolValidationError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                    Text("请选择下拉列表中的正确学校")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.red)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 2)
            }
        }
    }

    private func saveProfile() async {
        didAttemptSave = true
        guard !isSaving else { return }
        let normalizedSchool = school.trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalizedSchool.isEmpty, selectedSchoolOption == nil {
            errorMessage = "请选择下拉列表中的正确学校"
            isSchoolFieldFocused = true
            return
        }
        guard canSave else { return }
        if fullName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errorMessage = "请填写昵称"
            return
        }
        guard !gender.isEmpty else {
            errorMessage = "请选择性别"
            return
        }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        do {
            try await authService.completeProfile(
                fullName: fullName,
                school: selectedSchoolOption?.name ?? "",
                gender: gender,
                occupation: occupation
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func leaveProfileCompletion() async {
        guard !isLeaving, !isSaving else { return }
        isLeaving = true
        isSchoolFieldFocused = false
        hideKeyboard()
        await authService.leaveProfileCompletion()
        isLeaving = false
    }

    private func refreshSchoolSuggestions(for rawInput: String) {
        let query = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            schoolSuggestions = []
            return
        }

        let lower = query.lowercased()
        schoolSuggestions = Array(
            CheeseUniversityOption.all.filter { option in
                option.name.lowercased().contains(lower)
                    || option.displayText.lowercased().contains(lower)
                    || option.city.lowercased().contains(lower)
            }
            .prefix(12)
        )
    }

    private func applySchoolSelection(_ option: CheeseUniversityOption) {
        school = option.name
        schoolSuggestions = []
        isSchoolFieldFocused = false
    }

}

private extension View {
    func profileOnboardingOutline(cornerRadius: CGFloat) -> some View {
        overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(AppColors.textPrimary, lineWidth: 1)
        }
    }
}
