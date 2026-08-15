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
    
    var body: some View {
        ZStack {
            AppColors.pageBackground
                .ignoresSafeArea()
            
            ScrollView(showsIndicators: false) {
                VStack(spacing: 16) {
                    secondhandSearchBar
                    SecondhandCategoryPicker(selection: $selectedCategory)

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
                            LazyVGrid(columns: [
                                GridItem(.flexible(), spacing: 14),
                                GridItem(.flexible(), spacing: 14)
                            ], spacing: 14) {
                                ForEach(filteredItems) { item in
                                    SecondhandCardView(
                                        item: item,
                                        isOwnPost: item.isOwned(by: authService.currentUser?.id),
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
                .padding(.horizontal, 16)
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
    var allowsImagePreview = true
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

                    if let originalPrice = item.originalPrice, originalPrice > 0 {
                        Text(Formatters.formatUSDCompact(originalPrice))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(AppColors.textMuted)
                            .strikethrough(true, color: AppColors.textMuted)
                            .lineLimit(1)
                    }
                }

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
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .cheeseCardChrome(cornerRadius: 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onTapGesture { onOpenTap?() }
    }

    private var cardImage: some View {
        ZStack {
            placeholderImage

            if let imageUrl = item.displayImageUrls.first, let url = URL(string: imageUrl) {
                CachedRemoteImage(url: url, targetPixelWidth: 640) { image in
                    image
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: .infinity)
                        .frame(height: 150)
                        .clipped()
                        .if(allowsImagePreview) { content in
                            content.tappableImagePreview(item.displayImageUrls, selected: imageUrl)
                        }
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

#Preview {
    NavigationStack {
        SecondhandListView()
    }
}

struct SecondhandDetailView: View {
    let item: SecondhandItem

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

    init(item: SecondhandItem) {
        self.item = item
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
            return L10n.tr("Your Post", "自己的帖子")
        }
        if hasSentContactCard {
            return L10n.tr("Already Contacted", "已发送联系")
        }
        return L10n.tr("Contact Seller", "联系卖家")
    }

    private var contactBarSubtitle: String? {
        if isOwnPost {
            return L10n.tr(
                "You cannot message yourself, but you can still save this post.",
                "不能给自己发私信，但仍然可以收藏。"
            )
        }
        if hasSentContactCard {
            return L10n.tr(
                "You already sent a contact card for this item. Each post can only be contacted once.",
                "你已经给这条商品发过联系卡了，每个帖子只能联系一次。"
            )
        }
        return nil
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
                VStack(spacing: 14) {
                    headerSection
                    mediaSection
                    detailsSection
                    sellerSection
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 120)
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .cheeseTabBarHidden(true)
        .safeAreaInset(edge: .top) {
            PostDetailTopBar(title: L10n.tr("Secondhand Post", "二手贴文"), onBack: { dismiss() }) {
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
            PostDetailContactBar(
                title: contactBarTitle,
                subtitle: contactBarSubtitle,
                isLoading: isOpeningChat,
                isDisabled: isOpeningChat || isOwnPost || hasSentContactCard,
                favoriteTitle: isFavorited ? L10n.tr("Saved", "已收藏") : L10n.tr("Save", "收藏"),
                isFavorited: isFavorited,
                isFavoriteDisabled: isOpeningChat,
                favoriteAction: {
                    Task { await toggleFavorite() }
                }
            ) {
                showContactComposer = true
            }
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
                try await secondhandService.updatePost(payload: payload)
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
        .shareFeedbackToast(message: $shareFeedbackMessage)
        .enableSwipeBackGesture()
    }

    private var mediaSection: some View {
        PostImageCarousel(
            urlStrings: item.displayImageUrls,
            height: 240,
            cornerRadius: 20
        ) {
            Group {
                placeholderImage
            }
        }
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(item.title)
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(AppColors.textPrimary)
                .singleLineEllipsized()

            VStack(alignment: .leading, spacing: 6) {
                if let originalPrice = item.originalPrice {
                    HStack(spacing: 6) {
                        Text("原价：")
                            .foregroundStyle(AppColors.textMuted)
                        Text(Formatters.formatUSDCompact(originalPrice))
                            .strikethrough()
                            .foregroundStyle(AppColors.textMuted)
                    }
                    .font(.system(size: 14, weight: .medium))
                }

                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("二手价：")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(AppColors.textMuted)
                    Text(Formatters.formatUSDCompact(item.price))
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(AppColors.categoryColor(for: "secondhand"))
                }
            }

        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColors.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .cheeseCardChrome(cornerRadius: 18)
    }

    private var detailsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            descriptionCardContent

            HStack(spacing: 8) {
                detailChip(item.category.displayName)
                detailChip(item.condition)
                detailChip(
                    item.isNegotiable
                    ? L10n.tr("Negotiable", "可议价")
                    : L10n.tr("Fixed price", "不议价")
                )
            }

            Text(item.timeAgo)
                .font(.system(size: 13))
                .foregroundStyle(AppColors.textMuted)
        }
        .padding(16)
        .background(AppColors.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .cheeseCardChrome(cornerRadius: 18)
    }

    private func detailChip(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(AppColors.textMuted)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Color(.systemGray6))
            .clipShape(Capsule())
    }

    private var descriptionCardContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.tr("Description", "描述"))
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(AppColors.textPrimary)

            Text(item.description.isEmpty ? L10n.tr("No description", "尚无描述") : item.description)
                .font(.system(size: 15))
                .foregroundStyle(AppColors.textMuted)
                .lineSpacing(4)
                .frame(maxWidth: .infinity, minHeight: 88, alignment: .topLeading)
                .padding(14)
                .background(Color(.systemGray6))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            MentionedProfilesView(postID: item.id)
        }
    }

    private var sellerSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.tr("Seller", "卖家"))
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(AppColors.textPrimary)

            Button {
                guard item.canOpenSellerProfile else { return }
                selectedSellerRoute = SecondhandSellerRoute(id: item.sellerId)
            } label: {
                SecondhandSellerIdentityLabel(
                    item: item,
                    avatarSize: 38,
                    showsHint: true,
                    showsDisclosure: item.canOpenSellerProfile
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!item.canOpenSellerProfile)
        }
        .padding(16)
        .background(AppColors.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .cheeseCardChrome(cornerRadius: 18)
    }

    private var placeholderImage: some View {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        AppColors.categoryColor(for: "secondhand").opacity(0.22),
                        AppColors.accent.opacity(0.24)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay {
                Image(systemName: "bag")
                    .font(.system(size: 34, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
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
