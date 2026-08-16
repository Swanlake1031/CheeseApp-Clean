//
//  HomeView.swift
//  CheeseApp
//
//  🏠 首页主视图
//  展示问候语、搜索栏、快捷操作、精选内容、论坛热门等
//
//  ⚠️ 注意：此视图不包含底部 Tab Bar
//  底部导航由 MainTabView 统一管理
//

import SwiftUI
import UIKit

private struct HomeProfileRoute: Identifiable, Hashable {
    let id: UUID
}

// MARK: - 首页视图
struct HomeView: View {
    /// Owned by MainTabView so tab changes and root view reconstruction do not
    /// discard loaded feed data or in-flight request de-duplication state.
    @ObservedObject var viewModel: HomeViewModel
    @EnvironmentObject private var authService: AuthService
    @Environment(\.openURL) private var openURL
    @ObservedObject private var forumService = ForumService.shared
    @ObservedObject private var interactionStore = PostInteractionStore.shared

    /// 导航状态
    @State private var showForumList = false
    @State private var showSearch = false
    @State private var shouldAutoFocusSearch = false
    @State private var showCustomerSupport = false
    @State private var selectedForumBoardID: UUID?
    @State private var showCourseDiscovery = false
    @State private var showNavigationDrawer = false
    @State private var navigationDrawerOpenRequest: UInt = 0
    @State private var selectedForumPost: ForumPostItem?
    @State private var selectedFeaturedSecondhandItem: SecondhandItem?
    @State private var selectedProfileRoute: HomeProfileRoute?
    @State private var sharingPost: PostSharePayload?
    @State private var shareActionToastMessage: String?
    @State private var postOpenErrorMessage: String?
    @State private var selectedFeaturedCategory: HomeFeedTab = .recommended
    @State private var selectedSecondhandCategory: SecondhandPost.Category?
    @State private var featuredPageHeights: [HomeFeedTab: CGFloat] = [:]
    @State private var contentScrollResetID = UUID()
    @State private var promotedCreatedPostID: UUID?
    @State private var highlightedCreatedPostID: UUID?
    @State private var createdPostHighlightToken = UUID()

    private static let featuredCategories = HomeFeedTab.allCases

    var body: some View {
        ZStack {
            AppColors.pageBackground
                .ignoresSafeArea()
                
            // 顶部模块导航固定，只有下面的内容区参与纵向滚动。
            VStack(spacing: 0) {
                homeTopNavigationBar
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                    .padding(.bottom, 18)
                    .background(AppColors.pageBackground)
                    .zIndex(40)

                GeometryReader { contentProxy in
                    ScrollView(showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 0) {
                            // 横向分页本身至少铺满整个可视内容区。帖子较少时，
                            // 下方空白仍属于分页页面，而不是外层 ScrollView。
                            featuredSection(
                                minimumPagerHeight: max(
                                    contentProxy.size.height + 24,
                                    250
                                )
                            )
                            .zIndex(30)
                        }
                        .padding(.horizontal, 16)
                        .padding(
                            .bottom,
                            CheeseTabBarLayout.contentBottomClearance
                        )
                    }
                    .id(contentScrollResetID)
                    .refreshable {
                        await viewModel.refresh(userID: authService.currentUser?.id)
                        clearCreatedPostPromotion()
                    }
                }
            }

            HomeNavigationDrawerContainer(
                openRequest: navigationDrawerOpenRequest,
                boards: forumService.boards,
                onPresentationChange: { showNavigationDrawer = $0 },
                onForumTap: {
                    selectedForumBoardID = nil
                    showForumList = false
                    selectFeaturedCategory(.forum)
                },
                onBoardTap: { board in
                    selectedForumBoardID = board.id
                    showForumList = true
                },
                onSecondhandTap: {
                    selectedSecondhandCategory = nil
                    selectFeaturedCategory(.secondhand)
                },
                onSecondhandCategoryTap: { category in
                    selectedSecondhandCategory = category
                    selectFeaturedCategory(.secondhand)
                },
                onSupportTap: {
                    showCustomerSupport = true
                },
                onCourseTap: {
                    showCourseDiscovery = true
                },
                onCourseRadarTap: {
                    openURL(AppExternalLinks.courseRadar)
                }
            )
            .zIndex(100)
        }
        .navigationBarHidden(true)
        // 导航目标由 MainTabView 的 Home NavigationStack 承载。
        .navigationDestination(isPresented: $showForumList) {
            if let selectedForumBoardID {
                ForumBoardView(boardID: selectedForumBoardID)
            }
        }
        .navigationDestination(isPresented: $showSearch) {
            SearchView(
                shouldAutoFocus: $shouldAutoFocusSearch,
                showsBackButton: true
            )
        }
        .navigationDestination(isPresented: $showCourseDiscovery) {
            CourseDiscoveryView(universityName: resolvedHomeUniversityName)
        }
        .navigationDestination(isPresented: $showCustomerSupport) {
            CheeseCustomerSupportView()
        }
        .navigationDestination(item: $selectedForumPost) { post in
            ForumDetailView(post: post)
        }
        .navigationDestination(item: $selectedFeaturedSecondhandItem) { item in
            SecondhandDetailView(item: item)
        }
        .navigationDestination(item: $selectedProfileRoute) { route in
            UserPostsView(userId: route.id)
        }
        .cheesePostSharePanel(item: $sharingPost) { targetName in
            ShareFeedbackPresenter.show("已分享到 \(targetName)") {
                shareActionToastMessage = $0
            }
        }
        .onAppear {
            CheeseTabBarVisibilityController.shared.resetVisibility()
        }
        .task(id: homeLoadScopeKey) {
            async let boards: Void = loadForumBoardsIfNeeded()
            await viewModel.loadIfNeeded(userID: authService.currentUser?.id)
            await boards
        }
        .onReceive(NotificationCenter.default.publisher(for: PostFeatureEvents.postsDidChange)) { notification in
            handlePostChange(notification)
        }
        .onReceive(NotificationCenter.default.publisher(for: ProfileSocialEvents.followingDidChange)) { notification in
            guard let (targetUserID, isFollowing) = ProfileSocialEvents.change(
                from: notification
            ) else { return }
            viewModel.applyFollowChange(
                targetUserID: targetUserID,
                isFollowing: isFollowing
            )
            Task {
                await viewModel.refreshFollowing(userID: authService.currentUser?.id)
            }
        }
        .alert(
            L10n.tr("Action failed", "操作失败"),
            isPresented: Binding(
                get: { postOpenErrorMessage != nil },
                set: { if !$0 { postOpenErrorMessage = nil } }
            )
        ) {
            Button(L10n.tr("OK", "确定"), role: .cancel) {}
        } message: {
            Text(postOpenErrorMessage ?? "")
        }
        .cheeseTabBarHidden(showNavigationDrawer)
        .shareFeedbackToast(message: $shareActionToastMessage)
    }

    private var homeTopNavigationBar: some View {
        HomeModuleGridView(
            selectedModule: selectedFeaturedCategory,
            onSelect: selectFeaturedCategory,
            onMenuTap: {
                navigationDrawerOpenRequest &+= 1
            },
            onSearchTap: {
                shouldAutoFocusSearch = true
                showSearch = true
            }
        )
        .contentShape(Rectangle())
    }

    private var homeLoadScopeKey: String {
        authService.currentUser?.id.uuidString ?? "signed-out"
    }

    private func loadForumBoardsIfNeeded() async {
        guard forumService.boards.isEmpty else { return }
        await forumService.fetchBoards()
    }

    private var resolvedHomeUniversityName: String {
        guard let rawSchool = authService.currentUser?.school else {
            return CheeseUniversityOption.defaultSchoolName
        }
        if let option = CheeseUniversityOption.option(matching: rawSchool) {
            return option.displayText
        }
        let trimmed = rawSchool.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? CheeseUniversityOption.defaultSchoolName : trimmed
    }

    // MARK: - 板块内容区
    private func featuredSection(minimumPagerHeight: CGFloat) -> some View {
        let pagerHeight = selectedFeaturedPageHeight(
            minimum: minimumPagerHeight
        )

        return VStack(alignment: .leading, spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                // This is a small fixed set of pages. Keeping them eagerly laid out is intentional:
                // a lazy horizontal stack can report only the viewport height while a page's
                // asynchronously loaded cards extend below it, which clips the remaining feed.
                HStack(alignment: .top, spacing: 0) {
                    ForEach(Self.featuredCategories, id: \.self) { category in
                        featuredCategoryPage(category)
                            .fixedSize(horizontal: false, vertical: true)
                            .containerRelativeFrame(.horizontal)
                            // Read each page's intrinsic height before it is expanded to the
                            // current pager height. `onGeometryChange` only invokes the action
                            // when the transformed value changes, avoiding the old bound-
                            // preference feedback loop during layout.
                            .onGeometryChange(for: CGFloat.self) { proxy in
                                proxy.size.height
                            } action: { height in
                                updateFeaturedPageHeight(height, for: category)
                            }
                            .frame(
                                minHeight: pagerHeight,
                                alignment: .top
                            )
                            // 与页面同色，不绘制任何辅助框；它只让空白位置也能
                            // 命中系统原生分页手势。
                            .background(AppColors.pageBackground)
                            .contentShape(Rectangle())
                            .id(category)
                    }
                }
                .scrollTargetLayout()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: selectedFeaturedCategoryBinding)
            .frame(height: pagerHeight, alignment: .top)
            .padding(.vertical, 4)
            .background(AppColors.pageBackground)
            .clipped()
            .contentShape(Rectangle())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func featuredCards(for category: HomeFeedTab) -> [HomeCardItem] {
        switch category {
        case .recommended:
            return recommendedTabCards
        case .following:
            return viewModel.followingCards
        case .forum:
            return forumTabCards
        case .secondhand:
            guard let selectedSecondhandCategory else {
                return viewModel.featuredSecondhandCards
            }
            return viewModel.featuredSecondhandCards
                .filter { card in
                    guard let postID = card.postId else { return false }
                    return viewModel.secondhandItem(id: postID)?.category == selectedSecondhandCategory
                }
                .sorted { lhs, rhs in
                    switch (lhs.createdAt, rhs.createdAt) {
                    case let (left?, right?) where left != right:
                        return left > right
                    case (.some, nil):
                        return true
                    case (nil, .some):
                        return false
                    default:
                        return lhs.id.uuidString > rhs.id.uuidString
                    }
                }
        }
    }

    private var algorithmicForumCards: [HomeCardItem] {
        viewModel.forumCards
    }

    private var officialForumCards: [HomeCardItem] {
        viewModel.homeFeaturedForumCards
    }

    private var recommendedTabCards: [HomeCardItem] {
        let rankedCards = viewModel.recommendedCards
        guard let promotedCreatedPostID,
              let createdPost = viewModel.homeCard(id: promotedCreatedPostID)
        else {
            return rankedCards
        }
        return HomeRecommendationRanker.insertingCreatedPost(
            createdPost,
            into: rankedCards,
            limit: 12
        )
    }

    private var forumTabCards: [HomeCardItem] {
        let selectedOfficialCards = officialForumCards.filter {
            selectedForumBoardID == nil || $0.boardID == selectedForumBoardID
        }
        let selectedAlgorithmicCards = algorithmicForumCards.filter {
            selectedForumBoardID == nil || $0.boardID == selectedForumBoardID
        }
        var seenPostIDs = Set<UUID>()
        let uniqueCards = (selectedOfficialCards + selectedAlgorithmicCards).filter { card in
            seenPostIDs.insert(card.postId ?? card.id).inserted
        }
        let systemPinnedCards = uniqueCards.filter(\.isSystemPinned)
        let organicCards = uniqueCards.filter { !$0.isSystemPinned }
        return Array((systemPinnedCards + organicCards).prefix(12))
    }

    private func featuredLoadState(
        for category: HomeFeedTab
    ) -> CollectionLoadState {
        switch category {
        case .recommended:
            return viewModel.recommendedLoadState
        case .following:
            return viewModel.followingLoadState
        case .forum:
            return forumTabCards.isEmpty
                ? viewModel.forumFeaturedLoadState
                : .loaded
        case .secondhand:
            return viewModel.featuredLoadState(for: .secondhand)
        }
    }

    private var featuredLoadingStateCard: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(AppColors.cardBackground)
            .frame(maxWidth: .infinity)
            .frame(height: 250)
            .overlay {
                ProgressView()
                    .progressViewStyle(.circular)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(AppColors.cardBorder, lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.065), radius: 10, y: 4)
    }

    private func featuredEmptyStateCard(for category: HomeFeedTab) -> some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(AppColors.cardBackground)
            .frame(maxWidth: .infinity)
            .frame(height: 250)
            .overlay {
                if category == .following {
                    followingEmptyState
                } else {
                    Text(L10n.tr("Nothing here yet", "暂无内容"))
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(AppColors.textMuted)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(AppColors.cardBorder, lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.065), radius: 10, y: 4)
    }

    private var followingEmptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: viewModel.isFollowingAnyone ? "clock.badge.questionmark" : "person.2")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(AppColors.link)

            Text(
                viewModel.isFollowingAnyone
                    ? L10n.tr("No new posts yet", "关注的人暂时还没有发帖")
                    : L10n.tr("You are not following anyone yet", "你还没有关注任何人")
            )
            .font(.system(size: 15, weight: .bold))
            .foregroundStyle(AppColors.textPrimary)

            Text(L10n.tr(
                "Explore recommended posts and follow people you enjoy.",
                "去推荐中发现感兴趣的内容和作者吧。"
            ))
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(AppColors.textMuted)
            .multilineTextAlignment(.center)

            Button {
                selectFeaturedCategory(.recommended)
            } label: {
                Text(L10n.tr("Browse For You", "浏览推荐"))
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.black)
                    .padding(.horizontal, 18)
                    .frame(height: 38)
                    .background(AppColors.accent)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 28)
    }

    private func retryFeaturedCategoryLoad(_ category: HomeFeedTab) {
        Task {
            switch category {
            case .recommended, .following, .secondhand, .forum:
                await viewModel.refresh(userID: authService.currentUser?.id)
            }
        }
    }

    @ViewBuilder
    private func featuredCategoryPage(_ category: HomeFeedTab) -> some View {
        featuredStandardCategoryPage(category)
    }

    private func featuredStandardCategoryPage(_ category: HomeFeedTab) -> some View {
        let cards = featuredCards(for: category)
        let loadState = featuredLoadState(for: category)

        return VStack(spacing: category == .forum ? 4 : 12) {
            if category == .forum {
                forumCategoryStrip
            } else if category == .secondhand {
                secondhandCategoryStrip
            }

            switch loadState {
            case .unresolved, .initialLoading:
                featuredLoadingStateCard
            case .empty:
                featuredEmptyStateCard(for: category)
            case .loaded:
                if cards.isEmpty {
                    featuredEmptyStateCard(for: category)
                } else if category == .secondhand {
                    compactSecondhandGrid(cards)
                } else {
                    ForEach(cards) { card in
                        featuredCard(card)
                    }
                }

            case .error(let message):
                ErrorView(message) {
                    retryFeaturedCategoryLoad(category)
                }
            }
        }
        .padding(.top, 6)
        .padding(.bottom, 12)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
    }

    private func compactSecondhandGrid(_ cards: [HomeCardItem]) -> some View {
        LazyVGrid(
            columns: [
                GridItem(.flexible(), spacing: 12),
                GridItem(.flexible(), spacing: 12)
            ],
            spacing: 12
        ) {
            ForEach(cards) { card in
                if let postID = card.postId,
                   let storedItem = viewModel.secondhandItem(id: postID) {
                    let item = compactSecondhandItem(storedItem, for: card)

                    SecondhandCardView(
                        item: item,
                        isOwnPost: item.isOwned(by: authService.currentUser?.id),
                        allowsImagePreview: false,
                        onOpenTap: { openFeaturedCard(card) },
                        onAuthorTap: item.canOpenSellerProfile ? {
                            selectedProfileRoute = HomeProfileRoute(id: item.sellerId)
                        } : nil,
                        onFavoriteTap: {
                            Task { await toggleFavorite(card) }
                        }
                    )
                }
            }
        }
    }

    private func compactSecondhandItem(
        _ storedItem: SecondhandItem,
        for card: HomeCardItem
    ) -> SecondhandItem {
        var item = storedItem
        if let interaction = viewModel.interactionState(for: card) {
            item.isFavorited = interaction.isFavorited
        }
        return item
    }

    private var secondhandCategoryStrip: some View {
        SecondhandCategoryPicker(selection: $selectedSecondhandCategory)
    }

    private var forumCategoryStrip: some View {
        ExpandableCategoryPicker(
            selection: Binding(
                get: {
                    forumService.boards.first {
                        $0.id == selectedForumBoardID && $0.status != .archived
                    }
                },
                set: { selectedForumBoardID = $0?.id }
            ),
            options: forumService.boards.filter { $0.status != .archived },
            recommendedTitle: L10n.tr("Recommended", "推荐"),
            accessibilityTitle: L10n.tr("Forum categories", "论坛分区"),
            title: { $0.name },
            icon: { $0.icon }
        )
    }

    private func featuredCard(_ card: HomeCardItem) -> some View {
        ContentCardView(
            item: card,
            interaction: viewModel.interactionState(for: card),
            onTap: { openFeaturedCard(card) },
            onBoardTap: card.category == .forum && card.boardID != nil ? {
                openForumBoard(card)
            } : nil,
            onAuthorTap: card.authorId.map { authorID in
                { selectedProfileRoute = HomeProfileRoute(id: authorID) }
            },
            onLikeTap: card.postId == nil || card.category == .secondhand ? nil : {
                Task { await toggleLike(card) }
            },
            onFavoriteTap: card.postId == nil ? nil : {
                Task { await toggleFavorite(card) }
            },
            onShareTap: sharePayload(for: card).map { payload in
                { sharingPost = payload }
            }
        )
        .overlay {
            if highlightedCreatedPostID == card.postId {
                if card.category == .forum {
                    VStack(spacing: 0) {
                        Rectangle()
                            .fill(AppColors.accent)
                            .frame(height: 3)
                        Spacer(minLength: 0)
                    }
                    .allowsHitTesting(false)
                    .transition(.opacity)
                } else {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(AppColors.accent, lineWidth: 3)
                        .shadow(color: AppColors.accent.opacity(0.48), radius: 10)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
        }
        .overlay(alignment: .topTrailing) {
            if highlightedCreatedPostID == card.postId {
                Label(
                    L10n.tr("Published", "发布成功"),
                    systemImage: "checkmark.circle.fill"
                )
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color.black)
                .padding(.horizontal, 11)
                .frame(height: 32)
                .background(AppColors.accent)
                .clipShape(Capsule())
                .padding(12)
                .allowsHitTesting(false)
                .transition(.scale(scale: 0.92).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.24), value: highlightedCreatedPostID)
    }

    private func sharePayload(for card: HomeCardItem) -> PostSharePayload? {
        guard let postID = card.postId else { return nil }

        if card.category == .secondhand,
           let item = viewModel.secondhandItem(id: postID) {
            return PostSharePayload(
                kind: .secondhand,
                postId: postID,
                title: item.title,
                subtitle: Formatters.formatUSDCompact(item.price),
                summary: item.description,
                imageURL: URL(string: item.imageUrl ?? ""),
                deepLinkURL: PostSharePayload.makeDeepLink(kind: .secondhand, postId: postID)
            )
        }

        let kind: PostKind
        switch card.category {
        case .forum:
            kind = .forum
        case .secondhand:
            kind = .secondhand
        case .course:
            return nil
        }

        let imageURL: URL?
        if case .url(let url) = card.image {
            imageURL = url
        } else {
            imageURL = nil
        }

        return PostSharePayload(
            kind: kind,
            postId: postID,
            title: card.title,
            subtitle: card.category == .secondhand ? card.priceText : card.badgeText,
            summary: card.subtitle,
            imageURL: imageURL
        )
    }

    @MainActor
    private func toggleLike(_ card: HomeCardItem) async {
        do {
            try await viewModel.toggleLike(for: card)
        } catch {
            postOpenErrorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func toggleFavorite(_ card: HomeCardItem) async {
        do {
            try await viewModel.toggleFavorite(for: card)
        } catch {
            postOpenErrorMessage = error.localizedDescription
        }
    }

    private var selectedFeaturedCategoryBinding: Binding<HomeFeedTab?> {
        Binding(
            get: { selectedFeaturedCategory },
            set: { category in
                guard let category else { return }
                selectedFeaturedCategory = category
            }
        )
    }

    private func selectedFeaturedPageHeight(minimum: CGFloat) -> CGFloat {
        max(
            featuredPageHeights[selectedFeaturedCategory] ?? minimum,
            minimum
        )
    }

    private func updateFeaturedPageHeight(_ height: CGFloat, for category: HomeFeedTab) {
        guard height > 0,
              abs((featuredPageHeights[category] ?? 0) - height) > 0.5
        else { return }
        featuredPageHeights[category] = height
    }

    private func selectFeaturedCategory(_ category: HomeFeedTab) {
        guard category != selectedFeaturedCategory else { return }
        withAnimation(.easeInOut(duration: 0.24)) {
            selectedFeaturedCategory = category
        }
    }

    private func handlePostChange(_ notification: Notification) {
        guard let kind = PostFeatureEvents.changedPostKind(from: notification) else {
            return
        }

        guard PostFeatureEvents.change(from: notification) == .created,
              let postID = PostFeatureEvents.changedPostId(from: notification)
        else {
            Task {
                await viewModel.refresh(userID: authService.currentUser?.id)
            }
            return
        }

        withAnimation(.easeInOut(duration: 0.24)) {
            promotedCreatedPostID = postID
            highlightedCreatedPostID = nil
            showForumList = false
            selectedForumBoardID = nil
            selectedSecondhandCategory = nil
            selectedFeaturedCategory = .recommended
            contentScrollResetID = UUID()
        }

        ShareFeedbackPresenter.show(
            kind == .forum ? "论坛帖子发布成功，已显示在推荐" : "二手商品发布成功，已显示在推荐"
        ) {
            shareActionToastMessage = $0
        }

        let highlightToken = UUID()
        createdPostHighlightToken = highlightToken
        Task { @MainActor in
            let promoted = await viewModel.promoteCreatedPost(
                kind: kind,
                postID: postID
            )
            if !promoted {
                await viewModel.refresh(userID: authService.currentUser?.id)
            }

            guard !Task.isCancelled,
                  createdPostHighlightToken == highlightToken,
                  promotedCreatedPostID == postID,
                  viewModel.homeCard(id: postID) != nil
            else { return }

            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled,
                  createdPostHighlightToken == highlightToken
            else { return }

            contentScrollResetID = UUID()
            withAnimation(.spring(response: 0.34, dampingFraction: 0.78)) {
                highlightedCreatedPostID = postID
            }

            try? await Task.sleep(nanoseconds: 1_800_000_000)
            guard !Task.isCancelled,
                  createdPostHighlightToken == highlightToken
            else { return }
            withAnimation(.easeOut(duration: 0.35)) {
                highlightedCreatedPostID = nil
            }
        }
    }

    private func clearCreatedPostPromotion() {
        guard promotedCreatedPostID != nil || highlightedCreatedPostID != nil else {
            return
        }
        promotedCreatedPostID = nil
        highlightedCreatedPostID = nil
        createdPostHighlightToken = UUID()
    }

    private func openFeaturedCard(_ card: HomeCardItem) {
        guard let postId = card.postId else {
            if card.isSeatRadar {
                openURL(AppExternalLinks.courseRadar)
                return
            }

            switch card.category {
            case .secondhand:
                postOpenErrorMessage = L10n.tr(
                    "This item is temporarily unavailable. Please refresh and try again.",
                    "该商品暂时无法打开，请刷新后重试。"
                )
            case .forum:
                if let boardID = card.boardID {
                    selectedForumBoardID = boardID
                    showForumList = true
                } else {
                    postOpenErrorMessage = L10n.tr(
                        "This post is temporarily unavailable. Please refresh and try again.",
                        "该帖子暂时无法打开，请刷新后重试。"
                    )
                }
            case .course:
                showCourseDiscovery = true
            }
            return
        }

        switch card.category {
        case .secondhand:
            if let item = viewModel.secondhandItem(id: postId) {
                selectedFeaturedSecondhandItem = item
            } else {
                postOpenErrorMessage = L10n.tr(
                    "This item is temporarily unavailable. Please refresh and try again.",
                    "该商品暂时无法打开，请刷新后重试。"
                )
            }
        case .forum:
            if let post = viewModel.forumPost(id: postId) {
                selectedForumPost = post
            } else if let boardID = card.boardID {
                selectedForumBoardID = boardID
                showForumList = true
            } else {
                postOpenErrorMessage = L10n.tr(
                    "This post is temporarily unavailable. Please refresh and try again.",
                    "该帖子暂时无法打开，请刷新后重试。"
                )
            }
        case .course:
            showCourseDiscovery = true
        }
    }

    private func openForumBoard(_ card: HomeCardItem) {
        guard let boardID = card.boardID else { return }
        selectedForumBoardID = boardID
        showForumList = true
    }

    // MARK: - 处理快捷操作点击
}

enum HomeFeedTab: CaseIterable, Hashable {
    case recommended
    case following
    case forum
    case secondhand

    var title: String {
        switch self {
        case .recommended:
            return L10n.tr("For You", "推荐")
        case .following:
            return L10n.tr("Following", "关注")
        case .forum:
            return L10n.tr("Forum", "论坛")
        case .secondhand:
            return L10n.tr("Secondhand", "二手")
        }
    }

}

// MARK: - Preview
#Preview {
    HomeView(viewModel: HomeViewModel())
}
