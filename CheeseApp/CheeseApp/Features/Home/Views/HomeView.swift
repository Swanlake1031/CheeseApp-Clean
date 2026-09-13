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

enum HomeFeedNavigationRoute {
    case forum
    case secondhand(SecondhandPost.Category?)
}

enum HomeFeedNavigationEvents {
    static let openRoute = Notification.Name("cheese.home-feed.open-route")
    static let homeReselected = Notification.Name("cheese.home-feed.reselected")

    static func post(
        _ route: HomeFeedNavigationRoute,
        center: NotificationCenter = .default
    ) {
        center.post(name: openRoute, object: route)
    }

    static func route(from notification: Notification) -> HomeFeedNavigationRoute? {
        notification.object as? HomeFeedNavigationRoute
    }

    static func postHomeReselect(center: NotificationCenter = .default) {
        center.post(name: homeReselected, object: nil)
    }
}

// MARK: - 首页视图
struct HomeView: View {
    @Environment(\.scenePhase) private var scenePhase
    /// Owned by MainTabView so tab changes and root view reconstruction do not
    /// discard loaded feed data or in-flight request de-duplication state.
    @ObservedObject var viewModel: HomeViewModel
    @EnvironmentObject private var authService: AuthService
    @ObservedObject private var interactionStore = PostInteractionStore.shared

    /// 导航状态
    @State private var showSearch = false
    @State private var shouldAutoFocusSearch = false
    @State private var showCustomerSupport = false
    @State private var showSettings = false
    @State private var showNavigationDrawer = false
    @State private var navigationDrawerOpenRequest: UInt = 0
    @State private var selectedForumPost: ForumPostItem?
    @State private var selectedFeaturedSecondhandItem: SecondhandItem?
    @State private var selectedProfileRoute: HomeProfileRoute?
    @State private var sharingPost: PostSharePayload?
    @State private var shareActionToastMessage: String?
    @State private var postOpenErrorMessage: String?
    @State private var selectedFeaturedCategory: HomeFeedTab = .forum
    @State private var forumFooterNearViewport = false
    // Start without a pager position so the initial forum selection is applied
    // after the horizontal scroll view has finished creating its targets.
    // Otherwise SwiftUI can keep the first target (`following`) visible while
    // the header already highlights `forum`.
    @State private var featuredPagerPosition: HomeFeedTab?
    @State private var isFeaturedPagerInitializing = true
    @State private var pendingFeaturedCategory: HomeFeedTab?
    @State private var isFeaturedPagerScrolling = false
    @State private var selectedSecondhandCategory: SecondhandPost.Category?
    @State private var featuredPageHeights: [HomeFeedTab: CGFloat] = [:]
    @State private var contentScrollResetID = UUID()
    @State private var scrollToTopRequest: UInt = 0
    @State private var promotedCreatedPostID: UUID?
    @State private var highlightedCreatedPostID: UUID?
    @State private var createdPostHighlightToken = UUID()

    private static let featuredCategories: [HomeFeedTab] = [.following, .forum]
    private static let featuredPagerHorizontalInset: CGFloat = 8
    private static let featuredPageHorizontalInset: CGFloat = 12
    private static let secondhandCategoryStripHorizontalInset: CGFloat = 8

    var body: some View {
        ZStack {
            AppColors.pageBackground
                .ignoresSafeArea()
                
            // 顶部模块导航固定，只有下面的内容区参与纵向滚动。
            VStack(spacing: 0) {
                homeTopNavigationBar
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                    .padding(.bottom, 8)
                    .background(AppColors.pageBackground)
                    .zIndex(40)

                GeometryReader { contentProxy in
                    ScrollViewReader { scrollProxy in
                        ScrollView(showsIndicators: false) {
                            VStack(alignment: .leading, spacing: 0) {
                                Color.clear
                                    .frame(height: 0)
                                    .id(HomeScrollAnchor.top)

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
                            .padding(
                                .horizontal,
                                Self.featuredPagerHorizontalInset
                            )
                            .padding(
                                .bottom,
                                CheeseTabBarLayout.contentBottomClearance
                            )
                        }
                        .id(contentScrollResetID)
                        .onChange(of: scrollToTopRequest) { _, _ in
                            var transaction = Transaction(animation: nil)
                            transaction.disablesAnimations = true
                            withTransaction(transaction) {
                                scrollProxy.scrollTo(HomeScrollAnchor.top, anchor: .top)
                            }
                        }
                        .refreshable {
                            await viewModel.refresh(userID: authService.currentUser?.id, intent: .explicitPull)
                            clearCreatedPostPromotion()
                        }
                    }
                }
            }

            HomeNavigationDrawerContainer(
                openRequest: navigationDrawerOpenRequest,
                onPresentationChange: { showNavigationDrawer = $0 },
                onForumTap: {
                    selectFeaturedCategory(.forum)
                },
                onSecondhandTap: {
                    MainTabNavigationEvents.postOpenSecondhand()
                },
                onSecondhandCategoryTap: { category in
                    MainTabNavigationEvents.postOpenSecondhand(category: category)
                },
                onSettingsTap: {
                    showSettings = true
                },
                onSupportTap: {
                    showCustomerSupport = true
                }
            )
            .zIndex(100)
        }
        .navigationBarHidden(true)
        // 导航目标由 MainTabView 的 Home NavigationStack 承载。
        .navigationDestination(isPresented: $showSearch) {
            SearchView(
                shouldAutoFocus: $shouldAutoFocusSearch,
                showsBackButton: true
            )
        }
        .navigationDestination(isPresented: $showCustomerSupport) {
            SupportCenterView()
        }
        .navigationDestination(isPresented: $showSettings) {
            SettingsView()
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
            await viewModel.loadIfNeeded(userID: authService.currentUser?.id)
        }
        .onChange(of: authService.accountTransitionGeneration) { _, _ in
            viewModel.resetAccountScopedState()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await viewModel.loadIfNeeded(userID: authService.currentUser?.id) }
        }
        .onReceive(NotificationCenter.default.publisher(for: PostFeatureEvents.postsDidChange)) { notification in
            handlePostChange(notification)
        }
        .onReceive(NotificationCenter.default.publisher(for: HomeFeedNavigationEvents.openRoute)) { notification in
            guard let route = HomeFeedNavigationEvents.route(from: notification) else { return }
            switch route {
            case .forum:
                selectFeaturedCategory(.forum)
            case .secondhand(let category):
                MainTabNavigationEvents.postOpenSecondhand(category: category)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: HomeFeedNavigationEvents.homeReselected)) { _ in
            handleHomeReselect()
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
        let userID = authService.currentUser?.id.uuidString ?? "signed-out"
        let transition = authService.isAccountTransitionInProgress
            ? "transitioning"
            : "stable"
        let loading = authService.isLoading ? "loading" : "idle"
        return "\(userID)-\(authService.accountTransitionGeneration)-\(transition)-\(loading)"
    }

    // MARK: - 内容分页
    private func featuredSection(minimumPagerHeight: CGFloat) -> some View {
        let pagerHeight = selectedFeaturedPageHeight(
            minimum: minimumPagerHeight
        )

        return VStack(alignment: .leading, spacing: 10) {
            GeometryReader { pagerProxy in
                let pageWidth = max(pagerProxy.size.width, 0)

                ScrollView(.horizontal, showsIndicators: false) {
                    // This is a small fixed set of pages. Keeping them eagerly laid out is intentional:
                    // a lazy horizontal stack can report only the viewport height while a page's
                    // asynchronously loaded cards extend below it, which clips the remaining feed.
                    HStack(alignment: .top, spacing: 0) {
                        ForEach(Self.featuredCategories, id: \.self) { category in
                            featuredCategoryPage(
                                category,
                                pageWidth: pageWidth
                            )
                            .fixedSize(horizontal: false, vertical: true)
                            // Use the actual pager viewport instead of measuring an offscreen
                            // page and feeding that width back into the grid. Every page and every
                            // paging step now has exactly the same deterministic width.
                            .frame(width: pageWidth, alignment: .topLeading)
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
                            // 命中系统原生分页手势。单页裁切防止卡片或阴影渗入相邻页。
                            .background(AppColors.pageBackground)
                            .contentShape(Rectangle())
                            .clipped()
                            .id(category)
                        }
                    }
                    .scrollTargetLayout()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollTargetBehavior(.paging)
                .scrollPosition(id: $featuredPagerPosition)
                .frame(height: pagerHeight, alignment: .top)
                .padding(.vertical, 4)
                .background(AppColors.pageBackground)
                .clipped()
                .contentShape(Rectangle())
                .modifier(
                    FeaturedPagerScrollPhaseModifier(
                        isScrolling: $isFeaturedPagerScrolling
                    )
                )
            }
            .frame(height: pagerHeight + 8, alignment: .top)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task {
            guard isFeaturedPagerInitializing else { return }

            // Ignore the scroll view's transient first-page position during
            // its initial layout, then explicitly align it with the header.
            featuredPagerPosition = nil
            await Task.yield()
            guard !Task.isCancelled else { return }

            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                featuredPagerPosition = selectedFeaturedCategory
            }

            await Task.yield()
            guard !Task.isCancelled else { return }
            isFeaturedPagerInitializing = false
        }
        .onChange(of: featuredPagerPosition) { _, category in
            guard !isFeaturedPagerInitializing,
                  let category
            else { return }
            pendingFeaturedCategory = category
            commitPendingFeaturedCategoryIfSettled()
        }
        .onChange(of: isFeaturedPagerScrolling) { _, isScrolling in
            guard !isScrolling else { return }
            commitPendingFeaturedCategoryIfSettled()
        }
    }

    private func featuredCards(for category: HomeFeedTab) -> [HomeCardItem] {
        switch category {
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

    private var forumTabCards: [HomeCardItem] {
        viewModel.forumTabCards()
    }

    private func featuredLoadState(
        for category: HomeFeedTab
    ) -> CollectionLoadState {
        switch category {
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
                "Explore the forum and follow people you enjoy.",
                "去论坛发现感兴趣的内容和作者吧。"
            ))
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(AppColors.textMuted)
            .multilineTextAlignment(.center)

            Button {
                selectFeaturedCategory(.forum)
            } label: {
                Text(L10n.tr("Browse Forum", "浏览论坛"))
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
            case .following, .secondhand, .forum:
                await viewModel.refresh(userID: authService.currentUser?.id)
            }
        }
    }

    @ViewBuilder
    private func featuredCategoryPage(
        _ category: HomeFeedTab,
        pageWidth: CGFloat
    ) -> some View {
        featuredStandardCategoryPage(category, pageWidth: pageWidth)
    }

    private func featuredStandardCategoryPage(
        _ category: HomeFeedTab,
        pageWidth: CGFloat
    ) -> some View {
        let cards = featuredCards(for: category)
        let loadState = featuredLoadState(for: category)
        let horizontalInset: CGFloat = category == .secondhand
            ? 0
            : Self.featuredPageHorizontalInset

        return VStack(
            alignment: .leading,
            spacing: category == .secondhand ? 12 : 4
        ) {
            if category == .secondhand {
                secondhandCategoryStrip
                    .padding(
                        .horizontal,
                        Self.secondhandCategoryStripHorizontalInset
                    )
            }

            Group {
                switch loadState {
                case .unresolved, .initialLoading:
                    featuredLoadingStateCard
                case .empty:
                    featuredEmptyStateCard(for: category)
                case .loaded:
                    if cards.isEmpty {
                        featuredEmptyStateCard(for: category)
                    } else if category == .secondhand {
                        compactSecondhandGrid(
                            cards,
                            availableWidth: max(
                                pageWidth
                                    - horizontalInset * 2,
                                0
                            )
                        )
                    } else {
                        ForEach(cards) { card in
                            featuredCard(card, in: category)
                        }
                    }

                case .error(let message):
                    ErrorView(message) {
                        retryFeaturedCategoryLoad(category)
                    }
                }
            }
            .padding(.top, category == .forum ? 8 : 0)

            if category == .forum, viewModel.hasResolvedInitialForumLoad {
                if let error = viewModel.forumRefreshError {
                    Text(error).font(.footnote).foregroundStyle(.secondary)
                }
                forumPaginationFooter
            }
        }
        .padding(.top, category == .forum ? 2 : 6)
        .padding(.bottom, 12)
        .padding(.horizontal, horizontalInset)
        .contentShape(Rectangle())
    }

    private var forumPaginationFooter: some View {
        Group {
            if viewModel.isLoadingMoreForum {
                ProgressView()
            } else if viewModel.hasMoreForum {
                Button(viewModel.forumPaginationError ?? L10n.tr("Load more", "加载更多")) {
                    Task { await viewModel.loadMoreForum(userID: authService.currentUser?.id) }
                }
            } else {
                Text(L10n.tr("You’re all caught up", "已看完当前可见帖子"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 44)
        .onGeometryChange(for: Bool.self) { proxy in
            // The horizontal pages are eagerly laid out: onAppear would load
            // offscreen pages too. Only prefetch near the actual viewport.
            proxy.frame(in: .global).intersects(UIScreen.main.bounds.insetBy(dx: 0, dy: -200))
        } action: { forumFooterNearViewport = $0 }
        .onChange(of: "\(forumFooterNearViewport)-\(selectedFeaturedCategory)-\(viewModel.forumPageNumber)-\(viewModel.isRefreshingForum)", initial: true) { _, _ in
            guard forumFooterNearViewport, selectedFeaturedCategory == .forum,
                  HomeForumContinuationPosition.allowsAutomaticLoad(
                    refreshError: viewModel.forumRefreshError,
                    paginationError: viewModel.forumPaginationError) else { return }
            // An expired-session refresh failure must not start a footer retry
            // loop. Explicit pull/load-more remains available to retry.
            // Scrolling away must not cancel an already requested page. The
            // model rejects stale responses after refresh/account transitions.
            Task { await viewModel.loadMoreForum(userID: authService.currentUser?.id) }
        }
    }

    private func compactSecondhandGrid(
        _ cards: [HomeCardItem],
        availableWidth: CGFloat
    ) -> some View {
        let spacing: CGFloat = 8
        let safeAvailableWidth = max(availableWidth, 0)
        let cardWidth = safeAvailableWidth > spacing
            ? floor((safeAvailableWidth - spacing) / 2)
            : nil
        let columns: [GridItem]
        if let cardWidth {
            columns = [
                GridItem(.fixed(cardWidth), spacing: spacing),
                GridItem(.fixed(cardWidth), spacing: spacing)
            ]
        } else {
            columns = [
                GridItem(.flexible(minimum: 0), spacing: spacing),
                GridItem(.flexible(minimum: 0), spacing: spacing)
            ]
        }

        return LazyVGrid(
            columns: columns,
            spacing: spacing
        ) {
            ForEach(cards) { card in
                if let postID = card.postId,
                   let storedItem = viewModel.secondhandItem(id: postID) {
                    let item = compactSecondhandItem(storedItem, for: card)

                    SecondhandCardView(
                        item: item,
                        isOwnPost: item.isOwned(by: authService.currentUser?.id),
                        constrainedWidth: cardWidth,
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
        .frame(width: safeAvailableWidth, alignment: .leading)
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

    private func featuredCard(
        _ card: HomeCardItem,
        in category: HomeFeedTab
    ) -> some View {
        featuredCardContent(card, in: category)
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

    @ViewBuilder
    private func featuredCardContent(
        _ card: HomeCardItem,
        in category: HomeFeedTab
    ) -> some View {
        if card.category == .forum,
           let postID = card.postId,
           let post = viewModel.forumPost(id: postID) {
            ForumPostCardView(
                post: post,
                isOwnPost: false,
                recommendationContext: viewModel.recommendationContext(for: card),
                onTap: { openFeaturedCard(card) },
                onLikeTap: { await toggleLike(card) },
                onFavoriteTap: { await toggleFavorite(card) },
                onEditTap: nil,
                onShareTap: sharePayload(for: card).map { payload in
                    {
                        sharingPost = payload
                        Task {
                            await ForumService.shared.recordRecommendationEvent(
                                postID: post.id,
                                type: .share,
                                context: viewModel.recommendationContext(for: card)
                            )
                        }
                    }
                },
                onAuthorTap: card.authorId.map { authorID in
                    { selectedProfileRoute = HomeProfileRoute(id: authorID) }
                }
            )
        } else {
            ContentCardView(
                item: card,
                interaction: viewModel.interactionState(for: card),
                presentsSecondhandAsForumBoard: false,
                usesSecondhandRowSurface: category == .following
                    && card.category == .secondhand,
                showsCategoryMetadata: true,
                onTap: { openFeaturedCard(card) },
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
        }
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
            subtitle: card.category == .secondhand ? card.priceText : nil,
            summary: card.subtitle,
            imageURL: imageURL
        )
    }

    @MainActor
    private func toggleLike(_ card: HomeCardItem) async {
        do {
            try await viewModel.toggleLike(for: card)
        } catch {
            postOpenErrorMessage = error.postActionMessage
        }
    }

    @MainActor
    private func toggleFavorite(_ card: HomeCardItem) async {
        do {
            try await viewModel.toggleFavorite(for: card)
        } catch {
            postOpenErrorMessage = error.postActionMessage
        }
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
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            featuredPageHeights[category] = height
        }
    }

    private func selectFeaturedCategory(_ category: HomeFeedTab) {
        guard category != selectedFeaturedCategory
                || category != featuredPagerPosition
        else { return }

        updateSelectedFeaturedCategoryWithoutAnimation(category)
        pendingFeaturedCategory = nil
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            featuredPagerPosition = category
        }
    }

    private func handleHomeReselect() {
        Task { await viewModel.loadIfNeeded(userID: authService.currentUser?.id) }
        showSearch = false
        shouldAutoFocusSearch = false
        showCustomerSupport = false
        showSettings = false
        selectedForumPost = nil
        selectedFeaturedSecondhandItem = nil
        selectedProfileRoute = nil
        selectedSecondhandCategory = nil
        clearCreatedPostPromotion()
        selectFeaturedCategory(.forum)
        scrollToTopRequest &+= 1
        CheeseTabBarVisibilityController.shared.resetVisibility()
    }

    private func commitPendingFeaturedCategoryIfSettled() {
        guard !isFeaturedPagerScrolling,
              let category = pendingFeaturedCategory,
              featuredPagerPosition == category
        else { return }

        pendingFeaturedCategory = nil
        guard category != selectedFeaturedCategory else { return }
        updateSelectedFeaturedCategoryWithoutAnimation(category)
    }

    private func updateSelectedFeaturedCategoryWithoutAnimation(
        _ category: HomeFeedTab
    ) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            selectedFeaturedCategory = category
        }
        if category == .forum {
            Task { await viewModel.loadIfNeeded(userID: authService.currentUser?.id) }
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

        promotedCreatedPostID = postID
        highlightedCreatedPostID = nil
        selectedSecondhandCategory = nil
        if kind == .secondhand {
            MainTabNavigationEvents.postOpenSecondhand()
            return
        }
        selectFeaturedCategory(.forum)
        contentScrollResetID = UUID()

        ShareFeedbackPresenter.show(
            kind == .forum ? "论坛帖子发布成功，已显示在论坛" : "二手商品发布成功，已显示在二手"
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
            switch card.category {
            case .secondhand:
                postOpenErrorMessage = L10n.tr(
                    "This item is temporarily unavailable. Please refresh and try again.",
                    "该商品暂时无法打开，请刷新后重试。"
                )
            case .forum:
                postOpenErrorMessage = L10n.tr(
                    "This post is temporarily unavailable. Please refresh and try again.",
                    "该帖子暂时无法打开，请刷新后重试。"
                )
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
            } else {
                postOpenErrorMessage = L10n.tr(
                    "This post is temporarily unavailable. Please refresh and try again.",
                    "该帖子暂时无法打开，请刷新后重试。"
                )
            }
        }
    }

    // MARK: - 处理快捷操作点击
}

/// `scrollPosition` starts reporting the destination page near the middle of an
/// interactive swipe. Keep that provisional value away from the selected tab and
/// its height-dependent layout until the pager has actually stopped scrolling.
private struct FeaturedPagerScrollPhaseModifier: ViewModifier {
    @Binding var isScrolling: Bool
    @State private var fallbackReleaseTask: Task<Void, Never>?

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content
                .onScrollPhaseChange { _, phase in
                    isScrolling = phase != .idle
                }
        } else {
            content
                .simultaneousGesture(
                    DragGesture(minimumDistance: 6)
                        .onChanged { value in
                            guard abs(value.translation.width)
                                    > abs(value.translation.height)
                            else { return }

                            fallbackReleaseTask?.cancel()
                            if !isScrolling {
                                isScrolling = true
                            }
                        }
                        .onEnded { _ in
                            fallbackReleaseTask?.cancel()
                            fallbackReleaseTask = Task { @MainActor in
                                try? await Task.sleep(
                                    nanoseconds: 280_000_000
                                )
                                guard !Task.isCancelled else { return }
                                isScrolling = false
                            }
                        }
                )
                .onDisappear {
                    fallbackReleaseTask?.cancel()
                    fallbackReleaseTask = nil
                }
        }
    }
}

enum HomeFeedTab: CaseIterable, Hashable {
    case following
    case forum
    case secondhand

    var title: String {
        switch self {
        case .following:
            return L10n.tr("Following", "关注")
        case .forum:
            return L10n.tr("Forum", "论坛")
        case .secondhand:
            return L10n.tr("Secondhand", "二手")
        }
    }

}

private enum HomeScrollAnchor {
    static let top = "home-feed-top"
}

// MARK: - Preview
#Preview {
    HomeView(viewModel: HomeViewModel())
}
