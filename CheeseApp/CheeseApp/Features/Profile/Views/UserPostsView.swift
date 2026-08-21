import SwiftUI

@MainActor
enum UserPostsViewMemoryCache {
    private static var blockRelations: [
        ProfileViewerTargetCacheKey: UserBlockRelation
    ] = [:]

    static func blockRelation(
        viewerID: UUID,
        targetUserID: UUID
    ) -> UserBlockRelation? {
        blockRelations[
            ProfileViewerTargetCacheKey(
                viewerID: viewerID,
                targetUserID: targetUserID
            )
        ]
    }

    static func storeBlockRelation(
        _ relation: UserBlockRelation,
        viewerID: UUID,
        targetUserID: UUID
    ) {
        blockRelations[
            ProfileViewerTargetCacheKey(
                viewerID: viewerID,
                targetUserID: targetUserID
            )
        ] = relation
    }

    static func removeAll() {
        blockRelations.removeAll()
    }
}

struct UserPostsView: View {
    private struct ProfileHighlight: Identifiable {
        let id: String
        let icon: String
        let text: String
        let lineLimit: Int

        init(id: String, icon: String, text: String, lineLimit: Int = 1) {
            self.id = id
            self.icon = icon
            self.text = text
            self.lineLimit = lineLimit
        }
    }

    let userId: UUID

    @EnvironmentObject private var authService: AuthService
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var service = UserPostsService()
    @StateObject private var chatService = ChatService.shared
    @StateObject private var profileSocialService = ProfileSocialService.shared
    @StateObject private var forumPostLoader = ProfileForumPostLoader()
    @StateObject private var secondhandPostLoader = ProfileSecondhandPostLoader()

    @State private var sharingPost: PostSharePayload?
    @State private var selectedResolvedPost: UserPostResolvedDestination?
    @State private var activeConversation: ChatConversationPreview?
    @State private var selectedKindFilter: PostKind

    @State private var isLoadingSocialSummary = false
    @State private var hasResolvedSocialSummary = false
    @State private var isTogglingFollow = false
    @State private var actionErrorMessage: String?
    @State private var isBlockedProfile = false
    @State private var hasCheckedBlockState = false
    @State private var blockRelation: UserBlockRelation = .none
    @State private var isRefreshingPostList = false
    @State private var categoryTransitionDirection: Int = 1
    @State private var uidCopyFeedbackMessage: String?
    @State private var hasRedirectedCurrentUser = false
    @State private var secondhandGridWidth: CGFloat = 0
    @State private var stopPostObservation: (() -> Void)?
    @State private var postRefreshGeneration = 0

    private let secondhandGridSpacing: CGFloat = 8

    init(
        userId: UUID,
        initialKind: PostKind = PostKind.profileDefault
    ) {
        self.userId = userId
        _selectedKindFilter = State(initialValue: initialKind)
    }

    private var isCurrentUser: Bool {
        authService.currentUser?.id == userId
    }

    private var viewerScopedTaskID: String {
        "\(authService.currentUser?.id.uuidString ?? "signed-out"):\(userId.uuidString)"
    }

    private var socialSummary: ProfileSocialSummary {
        profileSocialService.summary(for: userId)
    }

    private var shouldShowProfileGenderBadge: Bool {
        (service.profile?.isGenderVisible ?? true)
            && ["male", "female", "non_binary"].contains(service.profile?.gender ?? "")
    }

    private var visiblePosts: [UserPostSummary] {
        return service.posts.filter { $0.kind == selectedKindFilter }
    }

    private var postCategoryPages: [PostKind] {
        PostKind.profileDisplayOrder
    }

    private var selectedCategoryKey: String {
        selectedKindFilter.rawValue
    }

    private var forumPostIDs: [UUID] {
        service.posts.compactMap { post in
            post.kind == .forum ? post.id : nil
        }
    }

    private var forumPostsTaskID: String {
        let postKey = forumPostIDs.map(\.uuidString).joined(separator: ",")
        return "\(viewerScopedTaskID):\(postRefreshGeneration):\(postKey)"
    }

    private var secondhandPostIDs: [UUID] {
        service.posts.compactMap { post in
            post.kind == .secondhand ? post.id : nil
        }
    }

    private var secondhandPostsTaskID: String {
        let postKey = secondhandPostIDs.map(\.uuidString).joined(separator: ",")
        return "\(viewerScopedTaskID):secondhand:\(postRefreshGeneration):\(postKey)"
    }

    private var profileHighlights: [ProfileHighlight] {
        guard let profile = service.profile else { return [] }

        var highlights: [ProfileHighlight] = []
        if let school = compactText(profile.school) {
            highlights.append(.init(id: "school", icon: "graduationcap.fill", text: school))
        }
        highlights.append(
            .init(
                id: "bio",
                icon: "text.alignleft",
                text: compactText(profile.bio) ?? "暂无个性签名",
                lineLimit: 3
            )
        )
        return highlights
    }

    private var initialSurfaceState: CollectionLoadState {
        guard hasCheckedBlockState else { return .initialLoading }
        if isBlockedProfile { return .loaded }
        guard hasResolvedSocialSummary else { return .initialLoading }

        switch service.surfaceLoadState {
        case .unresolved, .initialLoading:
            return .initialLoading
        case .error(let message):
            return .error(message: message)
        case .empty, .loaded:
            return .loaded
        }
    }

    var body: some View {
        Group {
            if isCurrentUser {
                currentUserProfileRedirect
            } else {
                presentedScene
            }
        }
    }

    private var currentUserProfileRedirect: some View {
        AppColors.pageBackground
            .ignoresSafeArea()
            .task(id: userId) {
                guard !hasRedirectedCurrentUser else { return }
                hasRedirectedCurrentUser = true
                MainTabNavigationEvents.postOpenCurrentUserProfile()
                dismiss()
            }
    }

    private var lifecycleScene: some View {
        userPostsScene
            .cheesePageTopBar(title: "个人主页")
            .overlay(alignment: .top) {
                refreshOverlay
            }
            .task(id: viewerScopedTaskID) {
                activateCurrentViewer()
                await loadInitialSurface()
            }
            .onAppear {
                startPostObservation()
                if service.hasResolvedInitialSurfaceLoad {
                    Task { await reconcilePostList() }
                }
            }
            .onDisappear {
                stopPostObservation?()
                stopPostObservation = nil
            }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                Task { await reconcilePostList() }
            }
            .task(id: forumPostsTaskID) {
                await forumPostLoader.load(
                    postIDs: forumPostIDs,
                    viewerID: authService.currentUser?.id,
                    force: postRefreshGeneration > 0
                )
            }
            .task(id: secondhandPostsTaskID) {
                await secondhandPostLoader.load(
                    postIDs: secondhandPostIDs,
                    viewerID: authService.currentUser?.id,
                    force: postRefreshGeneration > 0
                )
            }
            .onReceive(NotificationCenter.default.publisher(for: PostFeatureEvents.postsDidChange)) { notification in
                guard PostFeatureEvents.changedAuthorId(from: notification) == userId else { return }
                Task { await refreshPostListWithIndicator() }
            }
    }

    private var navigableScene: some View {
        lifecycleScene
            .navigationDestination(item: $selectedResolvedPost) { destination in
                UserPostResolvedDetailRouter(destination: destination)
            }
            .navigationDestination(item: $activeConversation) { conversation in
                ChatRoomView(conversation: conversation)
            }
    }

    private var presentedScene: some View {
        navigableScene
            .cheesePostSharePanel(item: $sharingPost) { message in
                ShareFeedbackPresenter.show(message) {
                    uidCopyFeedbackMessage = $0
                }
            }
            .shareFeedbackToast(message: $uidCopyFeedbackMessage)
            .alert(
                "操作失败",
                isPresented: actionErrorIsPresented
            ) {
                Button("确定", role: .cancel) {
                    actionErrorMessage = nil
                }
            } message: {
                Text(actionErrorMessage ?? "")
            }
    }

    private var actionErrorIsPresented: Binding<Bool> {
        Binding(
            get: { actionErrorMessage != nil },
            set: { if !$0 { actionErrorMessage = nil } }
        )
    }

    private var userPostsScene: some View {
        ZStack {
            AppColors.pageBackground
                .ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                userPostsSurfaceContent
            }
        }
    }

    @ViewBuilder
    private var userPostsSurfaceContent: some View {
        switch initialSurfaceState {
        case .unresolved, .initialLoading:
            ProgressView()
                .padding(.top, 36)
        case .error(let message):
            ErrorView(message) {
                Task { await loadInitialSurface(forceRefresh: true) }
            }
            .padding(.horizontal, 16)
            .padding(.top, 40)
        case .empty, .loaded:
            loadedSurfaceContent
        }
    }

    @ViewBuilder
    private var loadedSurfaceContent: some View {
        if isBlockedProfile {
            blockedState
                .padding(.horizontal, 16)
                .padding(.top, 40)
        } else {
            VStack(spacing: 0) {
                profileHeader
                categoryFilterBar
                    .padding(.top, 10)
                postListSection
                    .padding(.top, 12)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 120)
        }
    }

    @ViewBuilder
    private var refreshOverlay: some View {
        if isRefreshingPostList {
            HStack(spacing: 8) {
                ProgressView()
                    .scaleEffect(0.85)
                Text("正在刷新列表...")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AppColors.textPrimary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(.ultraThinMaterial)
            .clipShape(Capsule())
            .padding(.top, 66)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private var profileHeader: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                avatarView(
                    urlString: service.profile?.avatarUrl,
                    fallbackName: service.profile?.fullName ?? service.profile?.email ?? "U",
                    isOfficial: service.profile?.isOfficialAccount == true
                )
                    .frame(width: 64, height: 64)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(service.profile?.fullName ?? service.profile?.email ?? "用户")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(AppColors.textPrimary)
                            .singleLineEllipsized()
                        if service.profile?.isOfficialAccount == true {
                            OfficialVerificationBadge()
                        }
                        if service.profile?.hasMcMasterStudentBadge == true {
                            McMasterStudentBadge(style: .label)
                        }
                    }

                    Text("\(visiblePosts.count) 条帖子")
                        .font(.system(size: 14))
                        .foregroundStyle(AppColors.textMuted)
                }

                Spacer()
            }

            HStack(spacing: 16) {
                socialMetric(count: socialSummary.followerCount, label: "粉丝")
                socialMetric(count: socialSummary.followingCount, label: "关注")
                Spacer()
            }

            if !profileHighlights.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(profileHighlights) { item in
                        profileHighlightRow(item)
                    }
                }
            }

            HStack(spacing: 8) {
                if shouldShowProfileGenderBadge {
                    ProfileGenderBadge(gender: service.profile?.gender)
                }

                if let publicID = service.profile?.publicID {
                    ProfileUIDBadge(publicID: publicID) {
                        ShareFeedbackPresenter.show(
                            L10n.tr(
                                "Cheese ID copied. Paste it into Search to find this profile.",
                                "奶酪 ID 已复制，可粘贴到搜索中查找该用户"
                            )
                        ) {
                            uidCopyFeedbackMessage = $0
                        }
                    }
                }

                Spacer()
            }

            HStack(spacing: 10) {
                Button {
                    Task { await toggleFollow() }
                } label: {
                    Text(
                        socialSummary.isMutualFollow
                            ? "已互关"
                            : socialSummary.amFollowing
                            ? "已关注"
                            : (socialSummary.followsMe ? "回关" : "关注")
                    )
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(socialSummary.amFollowing ? AppColors.textPrimary : .black)
                        .frame(width: 72, height: 36)
                        .background(socialSummary.amFollowing ? Color.white : AppColors.accent)
                        .clipShape(Capsule())
                        .overlay(
                            Capsule()
                                .stroke(AppColors.textMuted.opacity(socialSummary.amFollowing ? 0.3 : 0), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .allowsHitTesting(!isTogglingFollow && !isLoadingSocialSummary)

                Button {
                    Task { await startChat() }
                } label: {
                    Text("私信")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(AppColors.accent)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 14)
    }

    private func profileHighlightRow(_ item: ProfileHighlight) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: item.icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(AppColors.textMuted)
                .frame(width: 20, alignment: .center)

            Text(item.text)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(AppColors.textMuted)
                .lineLimit(item.lineLimit)
                .truncationMode(.tail)
        }
    }

    @ViewBuilder
    private var categoryFilterBar: some View {
        if service.isLoading || service.posts.isEmpty {
            EmptyView()
        } else {
            ProfilePostKindFilterBar(
                selectedKind: selectedKindFilter,
                onSelect: selectPostCategory
            )
        }
    }

    private var postListSection: some View {
        ZStack {
            Group {
                if visiblePosts.isEmpty {
                    emptyState
                } else if selectedKindFilter == .secondhand {
                    secondhandPostGrid
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(visiblePosts) { post in
                            if post.kind == .forum {
                                if let forumPost = forumPostLoader.postsByID[post.id] {
                                    ProfileForumPostCardView(
                                        post: forumPost,
                                        onTap: {
                                            // The profile loader already supplied the complete
                                            // forum model that this shared card displays. Reusing
                                            // it avoids a second network request before navigation.
                                            selectedResolvedPost = .forum(forumPost)
                                        },
                                        onBoardTap: {
                                            selectedResolvedPost = .forumBoard(
                                                forumPost.boardID
                                            )
                                        },
                                        onShareTap: {
                                            sharingPost = forumPost.sharePayload
                                        },
                                        onActionError: { message in
                                            actionErrorMessage = message
                                        }
                                    )
                                } else {
                                    forumPostLoadingRow
                                }
                            }
                        }
                    }
                }
            }
            .id(selectedCategoryKey)
            .transition(postCategoryTransition)
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.88), value: selectedKindFilter)
        .contentShape(Rectangle())
    }

    private var secondhandPostGrid: some View {
        LazyVGrid(
            columns: secondhandGridColumns,
            spacing: secondhandGridSpacing
        ) {
            ForEach(visiblePosts) { summary in
                if let item = secondhandPostLoader.itemsByID[summary.id] {
                    SecondhandCardView(
                        item: item,
                        isOwnPost: false,
                        constrainedWidth: secondhandCardWidth,
                        onOpenTap: {
                            selectedResolvedPost = .secondhand(item)
                        },
                        onAuthorTap: nil,
                        onFavoriteTap: {
                            Task { await toggleSecondhandFavorite(item) }
                        }
                    )
                } else {
                    secondhandPostLoadingCell
                }
            }
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            guard width > 0,
                  abs(secondhandGridWidth - width) > 0.5
            else { return }
            secondhandGridWidth = width
        }
        .padding(.horizontal, -8)
    }

    private var secondhandPostLoadingCell: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Color.white)
            .frame(
                minWidth: secondhandCardWidth,
                idealWidth: secondhandCardWidth,
                maxWidth: secondhandCardWidth ?? .infinity,
                minHeight: 280
            )
            .overlay {
                if secondhandPostLoader.isLoading {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "exclamationmark.circle")
                        .foregroundStyle(AppColors.textMuted)
                }
            }
    }

    private var secondhandCardWidth: CGFloat? {
        guard secondhandGridWidth > secondhandGridSpacing else { return nil }
        return floor((secondhandGridWidth - secondhandGridSpacing) / 2)
    }

    private var secondhandGridColumns: [GridItem] {
        guard let secondhandCardWidth else {
            return [
                GridItem(.flexible(minimum: 0), spacing: secondhandGridSpacing),
                GridItem(.flexible(minimum: 0), spacing: secondhandGridSpacing)
            ]
        }
        return [
            GridItem(.fixed(secondhandCardWidth), spacing: secondhandGridSpacing),
            GridItem(.fixed(secondhandCardWidth), spacing: secondhandGridSpacing)
        ]
    }

    @MainActor
    private func toggleSecondhandFavorite(_ item: SecondhandItem) async {
        let interaction = PostInteractionStore.shared.state(
            for: item.id,
            fallbackIsFavorited: item.isFavorited
        )
        do {
            _ = try await SecondhandService.shared.toggleFavorite(
                postId: item.id,
                currentlyFavorited: interaction.isFavorited
            )
        } catch {
            if error.isCancellationLike { return }
            actionErrorMessage = error.localizedDescription
        }
    }

    private var forumPostLoadingRow: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text(
                forumPostLoader.errorMessage == nil
                    ? "正在载入论坛帖子…"
                    : "论坛帖子载入失败，下拉即可重试"
            )
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(AppColors.textMuted)
        }
        .frame(maxWidth: .infinity, minHeight: 96)
        .overlay(alignment: .bottom) {
            Divider().overlay(AppColors.divider)
        }
    }

    private var postCategoryTransition: AnyTransition {
        let isForward = categoryTransitionDirection >= 0
        return .asymmetric(
            insertion: .move(edge: isForward ? .trailing : .leading).combined(with: .opacity),
            removal: .move(edge: isForward ? .leading : .trailing).combined(with: .opacity)
        )
    }

    private func selectPostCategory(_ kind: PostKind) {
        guard kind != selectedKindFilter else { return }
        let pages = postCategoryPages
        guard let currentIndex = pages.firstIndex(of: selectedKindFilter),
              let targetIndex = pages.firstIndex(of: kind) else {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
                selectedKindFilter = kind
            }
            return
        }

        categoryTransitionDirection = targetIndex >= currentIndex ? 1 : -1
        withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
            selectedKindFilter = kind
        }
    }

    private func socialMetric(count: Int, label: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(AppColors.textMuted)
            Text("\(count)")
                .font(.system(size: 14, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(AppColors.textPrimary)
        }
        .frame(minWidth: 62, alignment: .leading)
    }

    private func compactText(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "tray")
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
            Text("还没有帖子")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(AppColors.textPrimary)
        }
        .padding(.top, 36)
    }

    private var blockedState: some View {
        VStack(spacing: 12) {
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
            Text("该用户主页暂不可访问")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(AppColors.textPrimary)
            Text("对方已将你拉黑，解除前无法查看该主页。")
                .font(.system(size: 13))
                .foregroundStyle(AppColors.textMuted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, 20)
        .background(AppColors.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .cheeseCardChrome(cornerRadius: 16)
    }

    private func avatarView(
        urlString: String?,
        fallbackName: String,
        isOfficial: Bool
    ) -> some View {
        Group {
            if isOfficial {
                OfficialAccountAvatar(size: 64)
            } else if let urlString, let url = URL(string: urlString) {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    avatarPlaceholder(name: fallbackName)
                }
            } else {
                avatarPlaceholder(name: fallbackName)
            }
        }
        .clipShape(Circle())
        .tappableAvatarPreview(urlString)
    }

    private func avatarPlaceholder(name: String) -> some View {
        Circle()
            .fill(AppColors.accent)
            .overlay {
                Text(String(name.prefix(1)).uppercased())
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.white)
            }
    }

    @MainActor
    private func restoreCachedSurfaceIfPossible() -> Bool {
        guard let viewerID = authService.currentUser?.id else {
            return false
        }
        let hasCachedSurface = service.restoreCachedSurface(userId: userId)

        if let cachedBlockRelation =
            UserPostsViewMemoryCache.blockRelation(
                viewerID: viewerID,
                targetUserID: userId
            ) {
            blockRelation = cachedBlockRelation
            isBlockedProfile = cachedBlockRelation.isBlockedByOther
            hasCheckedBlockState = true
        }

        return hasCachedSurface && hasCheckedBlockState
    }

    private func loadInitialSurface(forceRefresh: Bool = false) async {
        guard let requestViewerID = authService.currentUser?.id else {
            activateCurrentViewer()
            return
        }
        activateCurrentViewer()

        if !forceRefresh, restoreCachedSurfaceIfPossible() {
            await loadSocialSummary()
            return
        }

        hasCheckedBlockState = false
        if forceRefresh {
            hasResolvedSocialSummary = false
        }
        async let socialSummaryLoad: Void = loadSocialSummary(
            forceRefresh: forceRefresh
        )

        let relation = await chatService.fetchBlockRelation(with: userId)
        guard authService.currentUser?.id == requestViewerID else { return }
        blockRelation = relation
        isBlockedProfile = relation.isBlockedByOther
        hasCheckedBlockState = true
        UserPostsViewMemoryCache.storeBlockRelation(
            relation,
            viewerID: requestViewerID,
            targetUserID: userId
        )
        guard !isBlockedProfile else {
            _ = await socialSummaryLoad
            return
        }

        await service.load(userId: userId, forceRefresh: forceRefresh)
        _ = await socialSummaryLoad
        guard authService.currentUser?.id == requestViewerID else { return }
        guard case .loaded = service.surfaceLoadState else {
            return
        }
    }

    @MainActor
    private func activateCurrentViewer() {
        guard service.activateViewer(authService.currentUser?.id) else {
            return
        }
        blockRelation = .none
        isBlockedProfile = false
        hasCheckedBlockState = false
        hasResolvedSocialSummary = false
        selectedResolvedPost = nil
        activeConversation = nil
        actionErrorMessage = nil
    }

    @MainActor
    private func refreshPostListWithIndicator() async {
        guard !isRefreshingPostList else { return }
        isRefreshingPostList = true
        defer { isRefreshingPostList = false }
        await service.refreshPosts(userId: userId)
        postRefreshGeneration &+= 1
    }

    @MainActor
    private func startPostObservation() {
        stopPostObservation?()
        stopPostObservation = service.observePostChanges(userId: userId) {
            await reconcilePostList()
        }
    }

    @MainActor
    private func reconcilePostList() async {
        await service.refreshPosts(userId: userId)
        postRefreshGeneration &+= 1
    }

    private func loadSocialSummary(forceRefresh: Bool = false) async {
        guard !isLoadingSocialSummary else { return }
        isLoadingSocialSummary = true
        defer {
            isLoadingSocialSummary = false
            hasResolvedSocialSummary = true
        }

        await profileSocialService.loadSummary(userId: userId, forceRefresh: forceRefresh)
    }

    private func toggleFollow() async {
        guard authService.currentUser?.id != nil else {
            actionErrorMessage = "请先登录后再关注。"
            return
        }
        guard !isTogglingFollow else { return }

        isTogglingFollow = true
        defer { isTogglingFollow = false }

        do {
            if socialSummary.amFollowing {
                try await profileSocialService.unfollow(targetUserId: userId)
            } else {
                try await profileSocialService.follow(targetUserId: userId)
            }
        } catch {
            actionErrorMessage = error.localizedDescription
        }
    }

    private func startChat() async {
        let relation = await chatService.fetchBlockRelation(with: userId)
        blockRelation = relation

        if relation.isBlockedByOther {
            actionErrorMessage = "对方已将你拉黑，无法发起私信。"
            return
        }

        do {
            let conversation = try await chatService.getOrCreateConversation(otherUserId: userId, relatedPostId: nil)
            activeConversation = conversation
        } catch {
            actionErrorMessage = error.localizedDescription
        }
    }
}

struct ProfilePostKindFilterBar: View {
    let selectedKind: PostKind
    let onSelect: (PostKind) -> Void

    var body: some View {
        PostFlowLayout(spacing: 8) {
            ForEach(PostKind.profileDisplayOrder, id: \.self) { kind in
                filterChip(
                    title: kind.displayName,
                    isSelected: selectedKind == kind
                ) {
                    onSelect(kind)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func filterChip(
        title: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isSelected ? .black : AppColors.textPrimary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(isSelected ? AppColors.accent : Color.white)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

extension PostKind {
    static let profileDisplayOrder: [PostKind] = [.forum, .secondhand]
    static let profileDefault: PostKind = .forum
}

private enum UserPostResolvedDestination: Hashable, Identifiable {
    case secondhand(SecondhandItem)
    case forum(ForumPostItem)
    case forumBoard(UUID)

    var id: String {
        switch self {
        case .secondhand(let item): return "secondhand-\(item.id.uuidString)"
        case .forum(let post): return "forum-\(post.id.uuidString)"
        case .forumBoard(let boardID):
            return "forum-board-\(boardID.uuidString)"
        }
    }
}

private struct UserPostResolvedDetailRouter: View {
    let destination: UserPostResolvedDestination

    var body: some View {
        switch destination {
        case .secondhand(let item):
            SecondhandDetailView(item: item)
        case .forum(let post):
            ForumDetailView(post: post)
        case .forumBoard(let boardID):
            ForumBoardView(boardID: boardID)
        }
    }
}
