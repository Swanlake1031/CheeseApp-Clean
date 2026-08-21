//
//  SecondhandListView.swift
//  CheeseApp
//
//  🛍️ 二手市场列表视图
//  展示所有二手商品，支持搜索和分类筛选
//

import SwiftUI

private struct SecondhandSellerRoute: Identifiable, Hashable {
    let id: UUID
}

struct SecondhandListView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var authService: AuthService
    @StateObject private var service = SecondhandService.shared
    @State private var searchText = ""
    @State private var isSearchPresented = false
    @State private var selectedCategory: SecondhandPost.Category?
    @State private var editingPost: UserPostSummary?
    @State private var selectedItem: SecondhandItem?
    @State private var selectedSellerRoute: SecondhandSellerRoute?
    @State private var interactionErrorMessage: String?
    @State private var hasLoadedInitialData = false
    @State private var itemGridWidth: CGFloat = 0

    private let itemGridSpacing: CGFloat = 8

    private var itemCardWidth: CGFloat? {
        guard itemGridWidth > itemGridSpacing else { return nil }
        return floor((itemGridWidth - itemGridSpacing) / 2)
    }

    private var itemGridColumns: [GridItem] {
        guard let itemCardWidth else {
            return [
                GridItem(.flexible(minimum: 0), spacing: itemGridSpacing),
                GridItem(.flexible(minimum: 0), spacing: itemGridSpacing)
            ]
        }
        return [
            GridItem(.fixed(itemCardWidth), spacing: itemGridSpacing),
            GridItem(.fixed(itemCardWidth), spacing: itemGridSpacing)
        ]
    }
    
    var body: some View {
        ZStack {
            AppColors.pageBackground
                .ignoresSafeArea()
            
            ScrollView(showsIndicators: false) {
                VStack(spacing: 16) {
                    secondhandSearchBar
                        .padding(.horizontal, 8)
                    SecondhandCategoryPicker(selection: $selectedCategory)
                        .padding(.horizontal, 8)

                    switch service.itemListState {
                    case .unresolved, .initialLoading:
                        ProgressView()
                            .padding(.top, 40)
                    case .empty:
                        emptyState
                    case .error(let message):
                        ErrorView(message) {
                            Task { await service.fetchItems() }
                        }
                        .frame(height: 220)
                        .padding(.top, 24)
                    case .loaded:
                        if filteredItems.isEmpty {
                            filteredEmptyState
                        } else {
                            LazyVGrid(
                                columns: itemGridColumns,
                                spacing: itemGridSpacing
                            ) {
                                ForEach(filteredItems) { item in
                                    SecondhandCardView(
                                        item: item,
                                        isOwnPost: item.isOwned(by: authService.currentUser?.id),
                                        constrainedWidth: itemCardWidth,
                                        onEditTap: {
                                            editingPost = item.editableSummary
                                        },
                                        onOpenTap: {
                                            selectedItem = item
                                        },
                                        onAuthorTap: item.canOpenSellerProfile ? {
                                            selectedSellerRoute = SecondhandSellerRoute(id: item.sellerId)
                                        } : nil,
                                        onFavoriteTap: {
                                            Task { await toggleFavorite(item) }
                                        }
                                    )
                                }
                            }
                            .onGeometryChange(for: CGFloat.self) { proxy in
                                proxy.size.width
                            } action: { width in
                                guard width > 0,
                                      abs(itemGridWidth - width) > 0.5
                                else { return }
                                itemGridWidth = width
                            }
                        }
                    }

                    if service.hasMoreItems {
                        Group {
                            if service.isLoadingNextPage {
                                ProgressView()
                            } else if let message = service.pageErrorMessage {
                                Button(message) {
                                    Task { await service.loadNextItemPage() }
                                }
                                .font(.footnote)
                            } else {
                                ProgressView()
                                    .onAppear {
                                        Task { await service.loadNextItemPage() }
                                    }
                            }
                        }
                        .padding(.vertical, 12)
                    }
                    
                    Spacer(minLength: 100)
                }
                .padding(.horizontal, 8)
                .padding(.top, 8)
            }
            .scrollDismissesKeyboard(.interactively)
            .simultaneousGesture(
                TapGesture().onEnded {
                    dismissSearchKeyboard()
                }
            )
            .refreshable {
                await service.fetchItems()
            }
        }
        .navigationTitle(L10n.tr("Secondhand", "二手"))
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    guard !isSearchPresented else {
                        dismissSearchKeyboard()
                        return
                    }
                    dismiss()
                } label: {
                    PostToolbarIconCircle(icon: "chevron.left")
                }
                .buttonStyle(.plain)
            }
        }
        .navigationDestination(item: $editingPost) { post in
            EditPostSheet(post: post) { payload in
                try await service.updatePost(payload: payload)
            }
        }
        .navigationDestination(item: $selectedItem) { item in
            SecondhandDetailView(item: item)
        }
        .navigationDestination(item: $selectedSellerRoute) { route in
            UserPostsView(userId: route.id)
        }
        .task {
            guard !hasLoadedInitialData else { return }
            hasLoadedInitialData = true
            await service.fetchItems()
        }
        .onReceive(NotificationCenter.default.publisher(for: PostFeatureEvents.postsDidChange)) { notification in
            guard PostFeatureEvents.changedPostKind(from: notification) == .secondhand else { return }
            Task { await service.fetchItems() }
        }
        .alert(L10n.tr("Action failed", "操作失败"), isPresented: Binding(
            get: { interactionErrorMessage != nil },
            set: { if !$0 { interactionErrorMessage = nil } }
        )) {
            Button(L10n.tr("OK", "确定"), role: .cancel) {}
        } message: {
            Text(interactionErrorMessage ?? "")
        }
        .enableSwipeBackGesture()
    }

    // MARK: - 空状态
    private var secondhandSearchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(AppColors.textMuted)

            CheeseSearchTextField(
                text: $searchText,
                placeholder: L10n.tr("Search items...", "搜寻商品..."),
                fontSize: 15,
                isFirstResponder: $isSearchPresented,
                onSubmit: dismissSearchKeyboard
            )
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 24)

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(AppColors.textMuted)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.tr("Clear search", "清除搜索"))
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 48)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .cheeseInputChrome(cornerRadius: 14)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "bag")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text(L10n.tr("No items yet", "还没有商品"))
                .font(.system(size: 18, weight: .medium))
            Text(L10n.tr("Be the first to list something!", "成为第一位上架的人！"))
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
        }
        .padding(.top, 60)
    }

    private var filteredEmptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 38, weight: .medium))
                .foregroundStyle(.secondary)
            Text(L10n.tr("No matching items", "没有符合条件的商品"))
                .font(.system(size: 17, weight: .semibold))
            Text(L10n.tr(
                "Try another category or search term.",
                "可以切换分类或更换搜索关键词。"
            ))
            .font(.system(size: 14))
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 48)
    }

    // MARK: - 筛选后的商品
    private var filteredItems: [SecondhandItem] {
        var result = service.items
        
        if !searchText.isEmpty {
            result = result.filter {
                $0.title.localizedCaseInsensitiveContains(searchText)
            }
        }

        if let selectedCategory {
            result = result.filter { $0.category == selectedCategory }
        }

        return result
    }

    private func dismissSearchKeyboard() {
        isSearchPresented = false
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    @MainActor
    private func toggleFavorite(_ item: SecondhandItem) async {
        do {
            let interaction = PostInteractionStore.shared.state(
                for: item.id,
                fallbackIsFavorited: item.isFavorited
            )
            _ = try await service.toggleFavorite(
                postId: item.id,
                currentlyFavorited: interaction.isFavorited
            )
        } catch {
            interactionErrorMessage = error.localizedDescription
        }
    }

}

struct SecondhandCategoryPicker: View {
    @Binding var selection: SecondhandPost.Category?

    var body: some View {
        ExpandableCategoryPicker(
            selection: $selection,
            options: SecondhandPost.Category.allCases,
            recommendedTitle: L10n.tr("Recommended", "推荐"),
            accessibilityTitle: L10n.tr("Secondhand categories", "二手分类"),
            title: { $0.displayName },
            icon: { $0.iconName }
        )
    }
}

// MARK: - 二手商品卡片
struct SecondhandCardView: View {
    @ObservedObject private var interactionStore = PostInteractionStore.shared

    let item: SecondhandItem
    let isOwnPost: Bool
    var constrainedWidth: CGFloat? = nil
    var onEditTap: (() -> Void)?
    var onOpenTap: (() -> Void)?
    var onAuthorTap: (() -> Void)?
    var onFavoriteTap: (() -> Void)?

    private var isFavorited: Bool {
        interactionStore.state(
            for: item.id,
            fallbackIsFavorited: item.isFavorited
        ).isFavorited
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            cardImage

            VStack(alignment: .leading, spacing: 8) {
                Text(item.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AppColors.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Text(item.condition)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AppColors.textMuted)
                    .lineLimit(1)

                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(Formatters.formatUSDCompact(item.price))
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(AppColors.categoryColor(for: "secondhand"))
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                        .allowsTightening(true)
                        .layoutPriority(1)

                    if let originalPrice = item.originalPrice, originalPrice > 0 {
                        Text(Formatters.formatUSDCompact(originalPrice))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(AppColors.textMuted)
                            .strikethrough(true, color: AppColors.textMuted)
                            .lineLimit(1)
                            .minimumScaleFactor(0.68)
                            .allowsTightening(true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 8) {
                    Button(action: { onAuthorTap?() }) {
                        SecondhandSellerIdentityLabel(
                            item: item,
                            avatarSize: 24,
                            showsHint: false,
                            showsDisclosure: false
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(onAuthorTap == nil)

                    Spacer(minLength: 4)

                    Button(action: { onFavoriteTap?() }) {
                        Image(systemName: isFavorited ? "star.fill" : "star")
                            .foregroundStyle(
                                isFavorited ? AppColors.accentStrong : AppColors.textMuted
                            )
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .disabled(onFavoriteTap == nil)
                }
            }
            .padding(12)
            .background(Color.white)
        }
        .frame(
            minWidth: constrainedWidth,
            idealWidth: constrainedWidth,
            maxWidth: constrainedWidth ?? .infinity,
            alignment: .leading
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(
            color: .black.opacity(0.055),
            radius: 4,
            x: 0,
            y: 2
        )
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onTapGesture { onOpenTap?() }
    }

    private var cardImage: some View {
        ZStack {
            placeholderImage

            if let imageUrl = item.displayImageUrls.first,
               let url = URL(string: imageUrl) {
                CachedRemoteImage(url: url, targetPixelWidth: 640) { image in
                    image
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: .infinity)
                        .frame(height: 150)
                        .clipped()
                } placeholder: {
                    EmptyView()
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 150)
        .clipped()
    }

    private var placeholderImage: some View {
        Rectangle()
            .fill(
                LinearGradient(
                    colors: [Color.orange.opacity(0.2), Color.pink.opacity(0.1)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay {
                Image(systemName: iconFor(category: item.category))
                    .font(.system(size: 32))
                    .foregroundStyle(.gray.opacity(0.4))
            }
    }

    private func iconFor(category: SecondhandPost.Category) -> String {
        category.iconName
    }

}

// MARK: - Profile secondhand surface

/// Resolves the complete Marketplace models required by the shared two-column
/// card renderer. Profile RPCs intentionally return compact summaries, so the
/// profile surfaces batch-hydrate those summaries instead of maintaining a
/// separate Marketplace card style.
@MainActor
final class ProfileSecondhandPostLoader: ObservableObject {
    @Published private(set) var itemsByID: [UUID: SecondhandItem] = [:]
    @Published private(set) var isLoading = false
    @Published private(set) var hasResolved = false
    @Published private(set) var errorMessage: String?

    private var activeRequestID: UUID?
    private var activeViewerID: UUID?

    func load(
        postIDs: [UUID],
        viewerID: UUID?,
        force: Bool = false
    ) async {
        var seen: Set<UUID> = []
        let uniqueIDs = postIDs.filter { seen.insert($0).inserted }
        let requestedIDs = Set(uniqueIDs)

        if activeViewerID != viewerID {
            activeViewerID = viewerID
            itemsByID = [:]
            hasResolved = false
            errorMessage = nil
        }

        itemsByID = itemsByID.filter { requestedIDs.contains($0.key) }

        guard !uniqueIDs.isEmpty else {
            activeRequestID = nil
            isLoading = false
            hasResolved = true
            errorMessage = nil
            return
        }

        if !force {
            let service = SecondhandService.shared
            let cachedItems = Array(service.itemSnapshots.values) + service.items
            for item in cachedItems where requestedIDs.contains(item.id) {
                itemsByID[item.id] = item
            }
        }

        let unresolvedIDs = force
            ? uniqueIDs
            : uniqueIDs.filter { itemsByID[$0] == nil }
        guard !unresolvedIDs.isEmpty else {
            activeRequestID = nil
            isLoading = false
            hasResolved = true
            errorMessage = nil
            return
        }

        let requestID = UUID()
        activeRequestID = requestID
        isLoading = true
        errorMessage = nil
        defer {
            if activeRequestID == requestID {
                isLoading = false
            }
        }

        do {
            let items = try await SecondhandService.shared.fetchItems(
                postIDs: unresolvedIDs
            )
            guard activeRequestID == requestID,
                  activeViewerID == viewerID
            else { return }
            for item in items where requestedIDs.contains(item.id) {
                itemsByID[item.id] = item
            }
            hasResolved = true
        } catch {
            guard activeRequestID == requestID,
                  activeViewerID == viewerID
            else { return }
            if error.isCancellationLike { return }
            hasResolved = true
            errorMessage = error.localizedDescription
        }
    }
}

#Preview {
    NavigationStack {
        SecondhandListView()
    }
}

struct SecondhandDetailView: View {
    @State private var item: SecondhandItem

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var authService: AuthService
    @StateObject private var secondhandService = SecondhandService.shared
    @StateObject private var chatService = ChatService.shared
    @ObservedObject private var interactionStore = PostInteractionStore.shared

    @State private var showDeleteConfirm = false
    @State private var showReportSheet = false
    @State private var editingPost: UserPostSummary?
    @State private var isOpeningChat = false
    @State private var activeConversation: ChatConversationPreview?
    @State private var chatErrorMessage: String?
    @State private var showContactComposer = false
    @State private var hasSentContactCard = false
    @State private var interactionErrorMessage: String?
    @State private var selectedSellerRoute: SecondhandSellerRoute?
    @State private var sharingPost: PostSharePayload?
    @State private var shareFeedbackMessage: String?
    @State private var isDescriptionExpanded = false
    @State private var isApplyingEdit = false

    init(item: SecondhandItem) {
        _item = State(initialValue: item)
    }

    private var isFavorited: Bool {
        interactionStore.state(
            for: item.id,
            fallbackIsFavorited: item.isFavorited
        ).isFavorited
    }

    private var isOwnPost: Bool {
        item.isOwned(by: authService.currentUser?.id)
    }

    private var contactBarTitle: String {
        if isOwnPost {
            return L10n.tr("Edit Item", "编辑商品")
        }
        if item.isSold {
            return L10n.tr("Sold", "已售出")
        }
        if hasSentContactCard {
            return L10n.tr("Already Contacted", "已发送联系")
        }
        return L10n.tr("Contact Seller", "联系卖家")
    }

    private var isContactBarDisabled: Bool {
        isOpeningChat || (!isOwnPost && (item.isSold || hasSentContactCard))
    }

    private var sharePayload: PostSharePayload {
        PostSharePayload(
            kind: .secondhand,
            postId: item.id,
            title: item.title,
            subtitle: Formatters.formatUSDCompact(item.price),
            summary: item.description,
            imageURL: URL(string: item.imageUrl ?? ""),
            deepLinkURL: PostSharePayload.makeDeepLink(kind: .secondhand, postId: item.id)
        )
    }

    private func copyShareLink() {
        PostShareService.copyLink(for: sharePayload)
        ShareFeedbackPresenter.show(L10n.tr("Link copied", "链接已复制")) { message in
            shareFeedbackMessage = message
        }
    }

    var body: some View {
        ZStack {
            AppColors.pageBackground
                .ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 16) {
                    SecondhandPriceHeader(item: item)

                    SecondhandDescriptionSection(
                        item: item,
                        isExpanded: $isDescriptionExpanded
                    )

                    DetailMediaCarousel(
                        urlStrings: item.displayImageUrls,
                        metrics: .secondhand
                    )

                    MentionedProfilesView(postID: item.id)

                    sellerSection
                }
                .padding(.horizontal, 16)
                .padding(.top, 2)
                .padding(.bottom, 120)
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .cheeseTabBarHidden(true)
        .safeAreaInset(edge: .top) {
            PostDetailTopBar(title: "", onBack: { dismiss() }) {
                Button {
                    sharingPost = sharePayload
                } label: {
                    PostToolbarIconCircle(icon: "square.and.arrow.up")
                }
                .buttonStyle(.plain)

                Menu {
                    Button {
                        copyShareLink()
                    } label: {
                        Label(L10n.tr("Copy Link", "复制链接"), systemImage: "link")
                    }

                    if isOwnPost {
                        Button {
                            editingPost = item.editableSummary
                        } label: {
                            Label(L10n.tr("Edit", "编辑"), systemImage: "square.and.pencil")
                        }

                        Button(role: .destructive) {
                            showDeleteConfirm = true
                        } label: {
                            Label(L10n.tr("Delete", "删除"), systemImage: "trash")
                        }
                    } else {
                        Button(role: .destructive) {
                            showReportSheet = true
                        } label: {
                            Label(L10n.tr("Report", "检举"), systemImage: "flag.fill")
                        }
                    }
                } label: {
                    PostToolbarIconCircle(icon: "ellipsis")
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            SecondhandBottomActionBar(
                title: contactBarTitle,
                isLoading: isOpeningChat,
                isDisabled: isContactBarDisabled,
                isFavorited: isFavorited,
                primaryAction: handlePrimaryAction,
                favoriteAction: {
                    Task { await toggleFavorite() }
                }
            )
        }
        .sheet(isPresented: $showContactComposer) {
            PostContactComposerSheet(
                badgeText: L10n.tr("Secondhand", "二手帖子"),
                title: L10n.tr("What do you want to ask the seller?", "你想跟卖家说点什么？"),
                helperText: L10n.tr(
                    "We will send this with a clean post card so the seller can see which item you are asking about right away.",
                    "这条附言会和帖子卡片一起发出去，卖家能立刻看懂你在问哪件商品。"
                ),
                previewTitle: item.title,
                previewSubtitle: "\(Formatters.formatUSDCompact(item.price)) · \(item.condition)",
                previewSummary: item.description,
                previewImageURL: item.imageUrl,
                placeholder: L10n.tr(
                    "For example: Is this still available? Can I pick it up this week?",
                    "比如：这个还在吗？这周可以自取吗？"
                ),
                sendButtonTitle: L10n.tr("Send Seller Card", "发送卖家联系卡"),
                accentColor: AppColors.categoryColor(for: "secondhand"),
                onSend: { note in
                    await sendSellerContactCard(note: note)
                }
            )
            .presentationDetents([.large])
        }
        .navigationDestination(item: $editingPost) { post in
            EditPostSheet(post: post) { payload in
                isApplyingEdit = true
                defer { isApplyingEdit = false }

                if let refreshedItem = try await secondhandService.updatePost(
                    payload: payload,
                    baseItem: item
                ) {
                    item = refreshedItem
                } else {
                    // The write succeeded but the immediate detail refetch was
                    // unavailable. Preserve instant text/price feedback while
                    // the change event refreshes the authoritative snapshot.
                    item = item.applying(payload)
                }
            }
        }
        .cheesePostSharePanel(item: $sharingPost) { targetName in
            ShareFeedbackPresenter.show("已分享到 \(targetName)") { message in
                shareFeedbackMessage = message
            }
        }
        .navigationDestination(item: $activeConversation) { conversation in
            ChatRoomView(conversation: conversation)
        }
        .navigationDestination(item: $selectedSellerRoute) { route in
            UserPostsView(userId: route.id)
        }
        .sheet(isPresented: $showReportSheet) {
            ReportPostSheet(postId: item.id, postKind: .secondhand)
        }
        .alert(L10n.tr("Delete this post?", "确定删除这篇贴文？"), isPresented: $showDeleteConfirm) {
            Button(L10n.tr("Cancel", "取消"), role: .cancel) {}
            Button(L10n.tr("Delete", "删除"), role: .destructive) {
                Task { await deletePost() }
            }
        } message: {
            Text(L10n.tr("This action cannot be undone.", "删除后无法复原。"))
        }
        .alert(L10n.tr("Unable to start chat", "无法发起私信"), isPresented: Binding(
            get: { chatErrorMessage != nil },
            set: { if !$0 { chatErrorMessage = nil } }
        )) {
            Button(L10n.tr("OK", "确定"), role: .cancel) {}
        } message: {
            Text(chatErrorMessage ?? "")
        }
        .alert(L10n.tr("Action failed", "操作失败"), isPresented: Binding(
            get: { interactionErrorMessage != nil },
            set: { if !$0 { interactionErrorMessage = nil } }
        )) {
            Button(L10n.tr("OK", "确定"), role: .cancel) {}
        } message: {
            Text(interactionErrorMessage ?? "")
        }
        .task(id: authService.currentUser?.id) {
            async let recordViewTask: Void = secondhandService.recordView(postId: item.id)
            async let favoriteStateTask = PostFavoriteService.shared.fetchFavoritePostIds(
                postIds: [item.id]
            )
            await refreshContactCardState()
            await recordViewTask
            let favoriteIDs = await favoriteStateTask
            interactionStore.setFavorite(
                postID: item.id,
                isFavorited: favoriteIDs.contains(item.id)
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: PostFeatureEvents.postsDidChange)) { notification in
            guard PostFeatureEvents.changedPostKind(from: notification) == .secondhand,
                  PostFeatureEvents.changedPostId(from: notification) == item.id,
                  !isApplyingEdit
            else { return }

            Task {
                if let refreshedItem = try? await secondhandService.fetchItem(postId: item.id) {
                    item = refreshedItem
                }
            }
        }
        .onReceive(secondhandService.$itemSnapshots) { snapshots in
            guard let refreshedItem = snapshots[item.id] else { return }
            item = refreshedItem
        }
        .shareFeedbackToast(message: $shareFeedbackMessage)
        .enableSwipeBackGesture()
    }

    private var sellerSection: some View {
        Button {
            guard item.canOpenSellerProfile else { return }
            selectedSellerRoute = SecondhandSellerRoute(id: item.sellerId)
        } label: {
            SecondhandSellerIdentityLabel(
                item: item,
                avatarSize: 44,
                showsHint: true,
                showsDisclosure: item.canOpenSellerProfile
            )
            .padding(.vertical, 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!item.canOpenSellerProfile)
        .overlay(alignment: .top) {
            Divider().overlay(AppColors.divider)
        }
        .overlay(alignment: .bottom) {
            Divider().overlay(AppColors.divider)
        }
    }

    private func handlePrimaryAction() {
        if isOwnPost {
            editingPost = item.editableSummary
        } else if !item.isSold, !hasSentContactCard {
            showContactComposer = true
        }
    }

    private func deletePost() async {
        do {
            try await secondhandService.deletePost(postId: item.id, authorId: item.sellerId)
            dismiss()
        } catch {
        }
    }

    private func sendSellerContactCard(note: String) async -> Bool {
        guard !isOpeningChat else { return false }
        guard let currentUser = authService.currentUser else {
            chatErrorMessage = L10n.tr("Please sign in again before sending messages.", "发消息前请先重新登录。")
            return false
        }

        guard currentUser.id != item.sellerId else {
            chatErrorMessage = L10n.tr("This is your own post.", "这是你自己的帖子")
            return false
        }

        do {
            try await chatService.ensureCanSendPostLinkedCard(
                to: item.sellerId,
                postKind: .secondhand,
                postId: item.id
            )
        } catch {
            if (error as NSError).code == 409 {
                hasSentContactCard = true
            }
            chatErrorMessage = error.localizedDescription
            return false
        }

        isOpeningChat = true
        defer { isOpeningChat = false }

        do {
            let conversation = try await chatService.getOrCreateConversation(
                otherUserId: item.sellerId,
                relatedPostId: item.id
            )
            let card = PostContactCardMetadata(
                postKind: PostKind.secondhand.rawValue,
                postId: item.id,
                title: item.title,
                subtitle: "\(Formatters.formatUSDCompact(item.price)) · \(item.condition)",
                summary: item.description,
                imageURL: item.imageUrl,
                requesterUserId: currentUser.id,
                requesterName: currentUser.fullName,
                note: note.isEmpty ? nil : note
            )
            _ = try await chatService.sendPostContactCardMessage(
                conversationId: conversation.id,
                card: card
            )
            hasSentContactCard = true
            activeConversation = conversation
            return true
        } catch {
            if (error as NSError).code == 409 {
                hasSentContactCard = true
            }
            chatErrorMessage = error.localizedDescription
            return false
        }
    }

    private func refreshContactCardState() async {
        guard let currentUserId = authService.currentUser?.id, currentUserId != item.sellerId else {
            hasSentContactCard = false
            return
        }

        do {
            hasSentContactCard = try await chatService.hasSentPostLinkedCard(
                to: item.sellerId,
                postKind: .secondhand,
                postId: item.id
            )
        } catch {
            hasSentContactCard = false
        }
    }

    private func toggleFavorite() async {
        let previous = interactionStore.state(
            for: item.id,
            fallbackIsFavorited: item.isFavorited
        )
        var optimistic = previous
        optimistic.isFavorited.toggle()
        interactionStore.replace(postID: item.id, with: optimistic)

        do {
            let confirmed = try await secondhandService.toggleFavorite(
                postId: item.id,
                currentlyFavorited: previous.isFavorited
            )
            interactionStore.setFavorite(postID: item.id, isFavorited: confirmed)
        } catch {
            interactionStore.replace(postID: item.id, with: previous)
            interactionErrorMessage = error.localizedDescription
        }
    }

}

private struct SecondhandPriceHeader: View {
    let item: SecondhandItem

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Text(Formatters.formatUSDCompact(item.price))
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .foregroundStyle(AppColors.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.72)

            if let originalPrice = item.originalPrice,
               originalPrice > item.price {
                Text(Formatters.formatUSDCompact(originalPrice))
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(AppColors.textMuted)
                    .strikethrough()
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Text(item.isSold ? L10n.tr("Sold", "已售出") : item.condition)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(item.isSold ? Color.red : AppColors.textMuted)
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .background(
                    Capsule()
                        .fill(item.isSold ? Color.red.opacity(0.09) : Color.black.opacity(0.05))
                )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SecondhandDescriptionSection: View {
    let item: SecondhandItem
    @Binding var isExpanded: Bool

    private var hasLongDescription: Bool {
        item.description.count > 92 || item.description.filter(\.isNewline).count >= 3
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(item.title)
                .font(.system(size: 23, weight: .bold))
                .foregroundStyle(AppColors.textPrimary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            if !item.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(item.description)
                    .font(.system(size: 15))
                    .foregroundStyle(AppColors.textMuted)
                    .lineSpacing(4)
                    .lineLimit(isExpanded ? nil : 3)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if hasLongDescription {
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            isExpanded.toggle()
                        }
                    } label: {
                        Text(isExpanded ? L10n.tr("Collapse", "收起") : L10n.tr("Show more", "展开全文"))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(AppColors.accentStrong)
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack(spacing: 8) {
                Label(item.category.displayName, systemImage: item.category.iconName)
                Text("·")
                Text(item.isNegotiable ? L10n.tr("Negotiable", "可议价") : L10n.tr("Fixed price", "一口价"))
                Text("·")
                Text(item.timeAgo)
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(AppColors.textMuted)
            .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SecondhandBottomActionBar: View {
    let title: String
    let isLoading: Bool
    let isDisabled: Bool
    let isFavorited: Bool
    let primaryAction: () -> Void
    let favoriteAction: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Divider()
                .overlay(AppColors.divider)

            HStack(spacing: 12) {
                Button(action: primaryAction) {
                    HStack(spacing: 8) {
                        if isLoading {
                            ProgressView()
                                .tint(isDisabled ? AppColors.textMuted : Color.black)
                        }
                        Text(title)
                            .font(.system(size: 16, weight: .bold))
                    }
                    .foregroundStyle(isDisabled ? AppColors.textMuted : Color.black)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(
                        Capsule()
                            .fill(isDisabled ? Color.black.opacity(0.06) : AppColors.accentStrong)
                    )
                }
                .buttonStyle(.plain)
                .disabled(isDisabled)

                Button(action: favoriteAction) {
                    Image(systemName: isFavorited ? "star.fill" : "star")
                        .font(.system(size: 23, weight: .semibold))
                        .foregroundStyle(isFavorited ? AppColors.accentStrong : AppColors.textPrimary)
                        .frame(width: 50, height: 50)
                        .background(Circle().fill(Color.black.opacity(0.06)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isFavorited ? L10n.tr("Remove favorite", "取消收藏") : L10n.tr("Favorite", "收藏"))
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 8)
        }
        .background(.ultraThinMaterial)
    }
}

extension SecondhandItem {
    var editableSummary: UserPostSummary {
        UserPostSummary(
            id: id,
            kind: .secondhand,
            title: title,
            description: description,
            subtitle: category.displayName,
            price: price,
            createdAt: Date(),
            authorId: sellerId,
            authorName: seller,
            authorAvatarURL: sellerAvatar
        )
    }

    func isOwned(by userId: UUID?) -> Bool {
        userId == sellerId
    }

    var canOpenSellerProfile: Bool {
        !isAnonymous && hasSellerProfile
    }

    var sellerAvatarSource: ImageSource {
        guard canOpenSellerProfile,
              let sellerAvatar,
              let url = URL(string: sellerAvatar),
              !sellerAvatar.isEmpty
        else { return .placeholder }
        return .url(url)
    }
}

private struct SecondhandSellerIdentityLabel: View {
    let item: SecondhandItem
    let avatarSize: CGFloat
    let showsHint: Bool
    let showsDisclosure: Bool

    var body: some View {
        HStack(spacing: 9) {
            AvatarView(source: item.sellerAvatarSource, size: avatarSize)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(item.seller)
                        .font(.system(size: avatarSize >= 36 ? 15 : 11, weight: .semibold))
                        .foregroundStyle(AppColors.textPrimary)
                        .lineLimit(1)
                    if item.isSellerMcMasterVerified {
                        McMasterStudentBadge()
                    }
                }

                if showsHint {
                    Text(helperText)
                        .font(.system(size: 12))
                        .foregroundStyle(AppColors.textMuted)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            if showsDisclosure {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(AppColors.textMuted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var helperText: String {
        if item.isAnonymous {
            return L10n.tr("Seller chose to stay anonymous", "卖家选择匿名发布")
        }
        if !item.hasSellerProfile {
            return L10n.tr("Profile is unavailable", "用户资料暂不可用")
        }
        return L10n.tr("Tap to view profile", "点击查看个人主页")
    }
}
