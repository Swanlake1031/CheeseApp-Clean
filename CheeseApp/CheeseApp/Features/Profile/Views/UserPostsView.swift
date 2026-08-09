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
    var initialKind: PostKind? = nil

    @EnvironmentObject private var authService: AuthService
    @StateObject private var service = UserPostsService()
    @StateObject private var chatService = ChatService.shared
    @StateObject private var profileSocialService = ProfileSocialService.shared

    @State private var editingPost: UserPostSummary?
    @State private var reportingPost: UserPostSummary?
    @State private var deletingPost: UserPostSummary?
    @State private var selectedResolvedPost: UserPostResolvedDestination?
    @State private var activeConversation: ChatConversationPreview?
    @State private var selectedKindFilter: PostKind?

    @State private var isLoadingSocialSummary = false
    @State private var hasResolvedSocialSummary = false
    @State private var isTogglingFollow = false
    @State private var actionErrorMessage: String?
    @State private var isBlockedProfile = false
    @State private var hasCheckedBlockState = false
    @State private var blockRelation: UserBlockRelation = .none
    @State private var isRefreshingPostList = false
    @State private var categoryTransitionDirection: Int = 1
    @State private var isOpeningPost = false
    @State private var updatingPrivacyPostID: UUID?
    @State private var uidCopyFeedbackMessage: String?

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
        guard let selectedKindFilter else { return service.posts }
        return service.posts.filter { $0.kind == selectedKindFilter }
    }

    private var availableKinds: [PostKind] {
        let kinds = Set(service.posts.map(\.kind))
        return PostKind.allCases.filter { kinds.contains($0) }
    }

    private var postCategoryPages: [PostKind?] {
        [nil] + availableKinds
    }

    private var selectedCategoryKey: String {
        selectedKindFilter?.rawValue ?? "all"
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

    private var screenTitle: String {
        if isCurrentUser {
            return "管理我的帖子"
        }
        return "个人主页"
    }

    private var initialSurfaceState: CollectionLoadState {
        guard hasCheckedBlockState else { return .initialLoading }
        if !isCurrentUser && isBlockedProfile { return .loaded }
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
        presentedScene
    }

    private var lifecycleScene: some View {
        userPostsScene
            .cheesePageTopBar(title: screenTitle)
            .overlay(alignment: .top) {
                refreshOverlay
            }
            .task(id: viewerScopedTaskID) {
                activateCurrentViewer()
                await loadInitialSurface()
            }
            .onReceive(NotificationCenter.default.publisher(for: PostFeatureEvents.postsDidChange)) { notification in
                guard PostFeatureEvents.changedAuthorId(from: notification) == userId else { return }
                Task { await refreshPostListWithIndicator() }
            }
            .onChange(of: availableKinds) { _, kinds in
                guard !service.isLoading else { return }
                if let selectedKindFilter, !kinds.contains(selectedKindFilter) {
                    selectPostCategory(nil)
                }
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

    private var sheetScene: some View {
        navigableScene
            .navigationDestination(item: $editingPost) { post in
                EditPostSheet(post: post) { payload in
                    try await service.update(payload: payload)
                    await service.refreshPosts(userId: userId)
                }
            }
            .sheet(item: $reportingPost) { post in
                ReportPostSheet(
                    postId: post.id,
                    postKind: post.kind
                )
            }
    }

    private var presentedScene: some View {
        sheetScene
            .shareFeedbackToast(message: $uidCopyFeedbackMessage)
            .alert(
                L10n.tr("Delete this post?", "确定删除这篇帖子？"),
                isPresented: deleteConfirmationIsPresented,
                presenting: deletingPost
            ) { post in
                deleteAlertActions(for: post)
            } message: { _ in
                Text(L10n.tr("This action cannot be undone.", "删除后无法恢复。"))
            }
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

    private var deleteConfirmationIsPresented: Binding<Bool> {
        Binding(
            get: { deletingPost != nil },
            set: { if !$0 { deletingPost = nil } }
        )
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
        if !isCurrentUser && isBlockedProfile {
            blockedState
                .padding(.horizontal, 16)
                .padding(.top, 40)
        } else {
            VStack(spacing: 14) {
                profileHeader
                categoryFilterBar
                postListSection
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

    @ViewBuilder
    private func deleteAlertActions(for post: UserPostSummary) -> some View {
        Button(L10n.tr("Cancel", "取消"), role: .cancel) {
            deletingPost = nil
        }
        Button(L10n.tr("Delete", "删除"), role: .destructive) {
            Task {
                do {
                    try await service.delete(postId: post.id)
                    deletingPost = nil
                } catch {
                    deletingPost = nil
                }
            }
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
                if socialSummary.isMutualFollow {
                    Text("互关")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(AppColors.link)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(AppColors.link.opacity(0.12))
                        .clipShape(Capsule())
                }
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

                ProfileUIDBadge(userID: userId) {
                    ShareFeedbackPresenter.show(
                        L10n.tr(
                            "UID copied. Paste it into Search to find this profile.",
                            "UID 已复制，可粘贴到搜索中查找该用户"
                        )
                    ) {
                        uidCopyFeedbackMessage = $0
                    }
                }

                Spacer()
            }

            if !isCurrentUser {
                HStack(spacing: 10) {
                    Button {
                        Task { await toggleFollow() }
                    } label: {
                        Text(
                            socialSummary.amFollowing
                                ? "已关注"
                                : (socialSummary.followsMe ? "回关" : "关注")
                        )
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(socialSummary.amFollowing ? AppColors.textPrimary : .black)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .background(socialSummary.amFollowing ? Color.white : AppColors.accent)
                            .clipShape(Capsule())
                            .overlay(
                                Capsule()
                                    .stroke(AppColors.textMuted.opacity(socialSummary.amFollowing ? 0.3 : 0), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(isTogglingFollow || isLoadingSocialSummary)

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
        }
        .padding(18)
        .background(AppColors.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .cheeseCardChrome(cornerRadius: 20)
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
                availableKinds: availableKinds,
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
                } else {
                    LazyVStack(spacing: 12) {
                        ForEach(visiblePosts) { post in
                            UserPostCard(
                                post: post,
                                isCurrentUser: isCurrentUser,
                                onOpen: {
                                    Task { await openPost(post) }
                                },
                                onEdit: { editingPost = post },
                                onToggleHidden: {
                                    Task { await toggleHidden(post) }
                                },
                                onReport: { reportingPost = post },
                                onDelete: { deletingPost = post }
                            )
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

    private var postCategoryTransition: AnyTransition {
        let isForward = categoryTransitionDirection >= 0
        return .asymmetric(
            insertion: .move(edge: isForward ? .trailing : .leading).combined(with: .opacity),
            removal: .move(edge: isForward ? .leading : .trailing).combined(with: .opacity)
        )
    }

    private func selectPostCategory(_ kind: PostKind?) {
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

    @MainActor
    private func toggleHidden(_ post: UserPostSummary) async {
        guard updatingPrivacyPostID == nil else { return }
        updatingPrivacyPostID = post.id
        defer { updatingPrivacyPostID = nil }
        do {
            try await service.setPostHidden(
                postId: post.id,
                hidden: !post.isPrivate
            )
        } catch {
            actionErrorMessage = error.localizedDescription
        }
    }

    private func socialMetric(count: Int, label: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text("\(count)")
                .font(.system(size: 14, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(AppColors.textPrimary)
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(AppColors.textMuted)
        }
        .frame(minWidth: 62, alignment: .leading)
    }

    private func compactText(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    @MainActor
    private func openPost(_ post: UserPostSummary) async {
        guard !isOpeningPost else { return }

        isOpeningPost = true
        defer { isOpeningPost = false }

        do {
            let destination = try await resolveDestination(for: post)
            selectedResolvedPost = nil
            selectedResolvedPost = destination
        } catch {
            actionErrorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func resolveDestination(for post: UserPostSummary) async throws -> UserPostResolvedDestination {
        switch post.kind {
        case .secondhand:
            return .secondhand(try await SecondhandService.shared.fetchItem(postId: post.id))
        case .forum:
            return .forum(try await ForumService.shared.fetchPost(postId: post.id))
        }
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

        if isCurrentUser {
            blockRelation = .none
            isBlockedProfile = false
            hasCheckedBlockState = true
        } else if let cachedBlockRelation =
            UserPostsViewMemoryCache.blockRelation(
                viewerID: viewerID,
                targetUserID: userId
            ) {
            blockRelation = cachedBlockRelation
            isBlockedProfile = cachedBlockRelation.isBlockedByOther
            hasCheckedBlockState = true
        }

        if isCurrentUser, let currentProfile = authService.currentUser {
            service.primeProfile(currentProfile, for: userId)
        }

        return hasCachedSurface && hasCheckedBlockState
    }

    private func loadInitialSurface(forceRefresh: Bool = false) async {
        guard let requestViewerID = authService.currentUser?.id else {
            activateCurrentViewer()
            return
        }
        activateCurrentViewer()

        if selectedKindFilter == nil {
            selectedKindFilter = initialKind
        }

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

        if !isCurrentUser {
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
        } else {
            blockRelation = .none
            isBlockedProfile = false
            hasCheckedBlockState = true
            if let currentProfile = authService.currentUser {
                service.primeProfile(currentProfile, for: userId)
            }
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
        editingPost = nil
        reportingPost = nil
        deletingPost = nil
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
        guard !isCurrentUser else { return }
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
        guard !isCurrentUser else { return }
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
    let availableKinds: [PostKind]
    let selectedKind: PostKind?
    let onSelect: (PostKind?) -> Void

    var body: some View {
        PostFlowLayout(spacing: 8) {
            Group {
                filterChip(
                    title: L10n.tr("All", "全部"),
                    isSelected: selectedKind == nil
                ) {
                    onSelect(nil)
                }

                ForEach(availableKinds, id: \.self) { kind in
                    filterChip(
                        title: kind.displayName,
                        isSelected: selectedKind == kind
                    ) {
                        onSelect(kind)
                    }
                }
            }
            .padding(.vertical, 2)
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

private struct UserPostCard: View {
    let post: UserPostSummary
    let isCurrentUser: Bool
    let onOpen: () -> Void
    let onEdit: () -> Void
    let onToggleHidden: () -> Void
    let onReport: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label(post.kind.displayName, systemImage: post.kind.icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AppColors.textMuted)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color(.systemGray6))
                    .clipShape(Capsule())

                if post.isPrivate {
                    Label("私密", systemImage: "lock.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.orange)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.orange.opacity(0.12))
                        .clipShape(Capsule())
                }

                if post.isArchived {
                    Label("封存", systemImage: "archivebox.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.purple)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.purple.opacity(0.12))
                        .clipShape(Capsule())
                }

                Spacer()

                Text(post.relativeTimeText)
                    .font(.system(size: 12))
                    .foregroundStyle(AppColors.textMuted)

                Menu {
                    if isCurrentUser {
                        Button {
                            onEdit()
                        } label: {
                            Label("编辑", systemImage: "square.and.pencil")
                        }

                        Button {
                            onToggleHidden()
                        } label: {
                            Label(
                                post.isPrivate ? "公开帖子" : "隐藏帖子",
                                systemImage: post.isPrivate ? "eye" : "eye.slash"
                            )
                        }

                        Button(role: .destructive) {
                            onDelete()
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }

                    if !isCurrentUser {
                        Button(role: .destructive) {
                            onReport()
                        } label: {
                            Label("举报", systemImage: "flag.fill")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(AppColors.textMuted)
                        .frame(width: 28, height: 28)
                }
            }

            Text(post.title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(AppColors.textPrimary)
                .singleLineEllipsized()

            if !post.description.isEmpty {
                Text(post.description)
                    .font(.system(size: 14))
                    .foregroundStyle(AppColors.textMuted)
                    .lineLimit(2)
            }

            HStack(spacing: 8) {
                if let priceText = post.priceDisplayText {
                    Text(priceText)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(AppColors.link)
                }

                Text(post.subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(AppColors.textMuted)
                    .lineLimit(1)
            }
        }
        .padding(14)
        .background(AppColors.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .cheeseCardChrome(cornerRadius: 16)
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onTapGesture {
            onOpen()
        }
    }
}

private enum UserPostResolvedDestination: Hashable, Identifiable {
    case secondhand(SecondhandItem)
    case forum(ForumPostItem)

    var id: String {
        switch self {
        case .secondhand(let item): return "secondhand-\(item.id.uuidString)"
        case .forum(let post): return "forum-\(post.id.uuidString)"
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
        }
    }
}
