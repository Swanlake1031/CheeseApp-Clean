import SwiftUI

struct SystemMessageTimelineView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var authService: AuthService
    @StateObject private var service = SystemMessageService.shared
    @StateObject private var profileSocialService = ProfileSocialService.shared
    @StateObject private var viewModel: SystemMessageViewModel
    @State private var pendingSoldMessage: SystemMessageItem?
    @State private var selectedNavigationTarget: SystemMessageResolvedNavigationTarget?
    @State private var openingMessageID: UUID?
    @State private var followingActorIDs: Set<UUID> = []
    @State private var resolvedFollowActorIDs: Set<UUID> = []
    @State private var pendingFollowActorIDs: Set<UUID> = []
    @State private var selectedInteractionPage: InteractionMessagePage = .activity

    let category: SystemMessageCategory

    init(category: SystemMessageCategory) {
        self.category = category
        _viewModel = StateObject(
            wrappedValue: SystemMessageViewModel(category: category)
        )
    }

    var body: some View {
        ZStack {
            AppColors.pageBackground.ignoresSafeArea()
            timelineContent
        }
        .toolbar(.hidden, for: .navigationBar)
        .enableSwipeBackGesture()
        .safeAreaInset(edge: .top) {
            timelineTopBar
        }
        .task(id: authService.currentUser?.id) {
            followingActorIDs = []
            resolvedFollowActorIDs = []
            pendingFollowActorIDs = []
            viewModel.activateAccount(authService.currentUser?.id)
            await loadTimeline()
        }
        .refreshable {
            await loadTimeline(force: true)
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: SystemMessageInboxEvents.remoteMessageAvailable
            )
        ) { notification in
            let pushedCategory = SystemMessageInboxEvents.category(from: notification)
            guard pushedCategory == nil || pushedCategory == category else { return }
            Task {
                await loadTimeline(force: true)
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(for: ProfileSocialEvents.followingDidChange)
        ) { notification in
            guard let (targetUserID, isFollowing) = ProfileSocialEvents.change(
                from: notification
            ) else { return }
            resolvedFollowActorIDs.insert(targetUserID)
            if isFollowing {
                followingActorIDs.insert(targetUserID)
            } else {
                followingActorIDs.remove(targetUserID)
            }
        }
        .navigationDestination(item: $selectedNavigationTarget) { target in
            switch target {
            case .forum(let post, let comments, let commentID):
                ForumDetailView(
                    post: post,
                    initialCommentID: commentID,
                    initialComments: comments
                )
            case .secondhand(let item):
                SecondhandDetailView(item: item)
            case .profile(let userID):
                UserPostsView(userId: userID)
            }
        }
        .alert(
            "确认已售出？",
            isPresented: Binding(
                get: { pendingSoldMessage != nil },
                set: { if !$0 { pendingSoldMessage = nil } }
            ),
            presenting: pendingSoldMessage
        ) { item in
            Button("取消", role: .cancel) {
                pendingSoldMessage = nil
            }
            Button("标记已售出", role: .destructive) {
                pendingSoldMessage = nil
                Task { await viewModel.respond(to: item, action: .sold) }
            }
        } message: { item in
            Text("「\(item.title)」会从二手列表下架。")
        }
        .alert(
            category.title,
            isPresented: Binding(
                get: { viewModel.actionMessage != nil },
                set: { if !$0 { viewModel.actionMessage = nil } }
            )
        ) {
            Button("确定", role: .cancel) {}
        } message: {
            Text(viewModel.actionMessage ?? "")
        }
    }

    @ViewBuilder
    private var timelineContent: some View {
        if category == .interaction {
            TabView(selection: $selectedInteractionPage) {
                ForEach(InteractionMessagePage.allCases) { page in
                    interactionPage(page)
                        .tag(page)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
        } else {
            messagePage(
                items: viewModel.items,
                emptyTitle: category.emptyTitle,
                emptyDescription: category.emptyDescription,
                emptyIcon: "bell.slash"
            )
        }
    }

    @ViewBuilder
    private var timelineTopBar: some View {
        if category == .interaction {
            interactionTopBar
        } else {
            CheeseInlineTopBar {
                backButton
            } center: {
                Text(category.title)
                    .font(.system(size: 17, weight: .semibold))
            } trailing: {
                Button("全部已读") {
                    Task { await viewModel.markAllRead() }
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(AppColors.link)
                .disabled(viewModel.items.allSatisfy { $0.readAt != nil })
            }
            .background(AppColors.pageBackground)
        }
    }

    private var interactionTopBar: some View {
        HStack(spacing: 0) {
            backButton
                .padding(.trailing, 8)

            ForEach(InteractionMessagePage.allCases) { page in
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        selectedInteractionPage = page
                    }
                } label: {
                    VStack(spacing: 8) {
                        Text(page.title)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(
                                selectedInteractionPage == page
                                    ? AppColors.textPrimary
                                    : AppColors.textMuted
                            )
                            .lineLimit(1)

                        Capsule()
                            .fill(
                                selectedInteractionPage == page
                                    ? AppColors.textPrimary
                                    : Color.clear
                            )
                            .frame(width: 28, height: 3)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(
                    selectedInteractionPage == page ? .isSelected : []
                )
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .background(AppColors.pageBackground)
        .overlay(alignment: .bottom) {
            Divider().overlay(AppColors.divider)
        }
    }

    private var backButton: some View {
        Button {
            dismiss()
        } label: {
            PostToolbarIconCircle(icon: "chevron.left")
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.tr("Back", "返回"))
    }

    private func interactionPage(_ page: InteractionMessagePage) -> some View {
        let items = viewModel.items.filter { $0.interactionPage == page }

        return messagePage(
            items: items,
            emptyTitle: page.emptyTitle,
            emptyDescription: page.emptyDescription,
            emptyIcon: page == .activity ? "heart.slash" : "person.2.slash"
        )
        .task(id: "\(page.rawValue):\(viewModel.items.count):\(viewModel.hasMore)") {
            guard viewModel.hasResolvedInitialLoad,
                  items.isEmpty,
                  viewModel.hasMore
            else { return }
            await viewModel.loadNextPage()
            await refreshFollowStates()
        }
    }

    @ViewBuilder
    private func messagePage(
        items: [SystemMessageItem],
        emptyTitle: String,
        emptyDescription: String,
        emptyIcon: String
    ) -> some View {
        switch viewModel.loadState {
        case .unresolved, .initialLoading:
            loadingState
        case .empty:
            emptyState(
                title: emptyTitle,
                description: emptyDescription,
                icon: emptyIcon
            )
        case .error(let message):
            ErrorView(message) {
                Task { await loadTimeline(force: true) }
            }
        case .loaded:
            if items.isEmpty {
                emptyState(
                    title: emptyTitle,
                    description: emptyDescription,
                    icon: emptyIcon
                )
            } else {
                timeline(items: items)
            }
        }
    }

    private func timeline(items: [SystemMessageItem]) -> some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(spacing: category == .interaction ? 0 : 12) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    SystemMessageRow(
                        item: item,
                        isOpening: openingMessageID == item.id,
                        showsCardChrome: category != .interaction,
                        onOpen: { open(item) },
                        onActorTap: category == .interaction
                            ? {
                                guard let actorUserID = item.actorUserID else { return }
                                selectedNavigationTarget = .profile(actorUserID)
                            }
                            : nil,
                        isFollowingActor: item.followActorUserID.flatMap { actorUserID in
                            resolvedFollowActorIDs.contains(actorUserID)
                                ? followingActorIDs.contains(actorUserID)
                                : nil
                        },
                        isFollowPending: item.followActorUserID.map {
                            pendingFollowActorIDs.contains($0)
                        } ?? false,
                        onFollowBack: item.followActorUserID.map { actorUserID in
                            { Task { await followBack(actorUserID) } }
                        },
                        onStillAvailable: {
                            Task {
                                await viewModel.respond(
                                    to: item,
                                    action: .stillAvailable
                                )
                            }
                        },
                        onSold: {
                            pendingSoldMessage = item
                        }
                    )
                    .onAppear {
                        guard item.id == items.last?.id else { return }
                        Task {
                            await viewModel.loadNextPage()
                            await refreshFollowStates()
                        }
                    }

                    if category == .interaction,
                       index < items.count - 1 {
                        interactionMessageDivider
                    }
                }

                if viewModel.isLoadingNextPage {
                    ProgressView()
                        .padding(.vertical, 12)
                } else if let errorMessage = viewModel.errorMessage {
                    Button("加载失败，点此重试") {
                        Task {
                            await viewModel.loadNextPage()
                        }
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.red)
                    .accessibilityLabel(errorMessage)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 100)
        }
    }

    private var interactionMessageDivider: some View {
        GeometryReader { proxy in
            Path { path in
                path.move(to: CGPoint(x: 0, y: 0.5))
                path.addLine(to: CGPoint(x: proxy.size.width, y: 0.5))
            }
            .stroke(AppColors.divider, lineWidth: 1)
        }
        .frame(height: 1)
        .padding(.leading, 54)
        .padding(.trailing, 14)
        .accessibilityHidden(true)
    }

    private var loadingState: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text("正在加载\(category.title)…")
                .font(.system(size: 13))
                .foregroundStyle(AppColors.textMuted)
        }
    }

    private func emptyState(
        title: String,
        description: String,
        icon: String
    ) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 40))
                .foregroundStyle(AppColors.textMuted)
            Text(title)
                .font(.system(size: 16, weight: .semibold))
            Text(description)
                .font(.system(size: 13))
                .foregroundStyle(AppColors.textMuted)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 28)
    }

    private func open(_ item: SystemMessageItem) {
        Task { await viewModel.markRead(item) }

        guard let target = item.navigationTarget else {
            switch item.ctaKind {
            case .viewProfile:
                viewModel.actionMessage = "该用户已不可用"
            case .viewPost, .secondhandAvailability:
                viewModel.actionMessage = "原内容已删除或不可见"
            case .none:
                break
            }
            return
        }

        switch target {
        case .profile(let userID):
            selectedNavigationTarget = .profile(userID)

        case .post(let route):
            guard openingMessageID == nil else { return }
            openingMessageID = item.id

            Task { @MainActor in
                defer { openingMessageID = nil }

                do {
                    switch route.kind {
                    case .forum:
                        async let postTask = ForumService.shared.fetchPost(postId: route.postId)
                        async let commentsTask = ForumService.shared.fetchComments(postId: route.postId)
                        let (post, comments) = try await (postTask, commentsTask)
                        let targetCommentID = item.targetCommentID(in: comments)
                        selectedNavigationTarget = .forum(
                            post,
                            comments: comments,
                            commentID: targetCommentID
                        )
                    case .secondhand:
                        let secondhandItem = try await SecondhandService.shared.fetchItem(
                            postId: route.postId
                        )
                        selectedNavigationTarget = .secondhand(secondhandItem)
                    }
                } catch {
                    guard !error.isCancellationLike else { return }
                    viewModel.actionMessage = error.localizedDescription.isEmpty
                        ? "暂时无法打开这篇帖子，请稍后再试。"
                        : error.localizedDescription
                }
            }
        }
    }

    private func loadTimeline(force: Bool = false) async {
        await viewModel.loadInitial(force: force)
        await refreshFollowStates()
        if category == .interaction {
            await viewModel.markAllRead()
        }
        await service.refreshUnreadCount()
    }

    @MainActor
    private func refreshFollowStates() async {
        guard category == .interaction else { return }
        let actorIDs = Set(viewModel.items.compactMap(\.followActorUserID))
        guard !actorIDs.isEmpty else {
            followingActorIDs = []
            resolvedFollowActorIDs = []
            return
        }

        do {
            let loadedFollowingIDs = try await profileSocialService
                .loadFollowingUserIDs(among: actorIDs)
            followingActorIDs.subtract(actorIDs)
            followingActorIDs.formUnion(loadedFollowingIDs)
            resolvedFollowActorIDs.formUnion(actorIDs)
        } catch {
            guard !error.isCancellationLike else { return }
            // Keep the last known row state if this auxiliary batch lookup
            // fails; the timeline itself remains usable.
        }
    }

    @MainActor
    private func followBack(_ actorUserID: UUID) async {
        guard !followingActorIDs.contains(actorUserID),
              pendingFollowActorIDs.insert(actorUserID).inserted
        else { return }
        defer { pendingFollowActorIDs.remove(actorUserID) }

        do {
            try await profileSocialService.follow(targetUserId: actorUserID)
            followingActorIDs.insert(actorUserID)
            resolvedFollowActorIDs.insert(actorUserID)
        } catch {
            guard !error.isCancellationLike else { return }
            viewModel.actionMessage = error.localizedDescription
        }
    }
}

private struct SystemMessageRow: View {
    let item: SystemMessageItem
    let isOpening: Bool
    let showsCardChrome: Bool
    let onOpen: () -> Void
    var onActorTap: (() -> Void)?
    var isFollowingActor: Bool?
    var isFollowPending = false
    var onFollowBack: (() -> Void)?
    let onStillAvailable: () -> Void
    let onSold: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                actorIcon

                Button(action: onOpen) {
                    messageContent
                        .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isOpening)

                if item.followActorUserID != nil {
                    Color.clear
                        .frame(width: 64)
                        .accessibilityHidden(true)
                } else {
                    trailingAction
                }
            }
            .overlay(alignment: .trailing) {
                if item.followActorUserID != nil {
                    trailingAction
                }
            }

            if item.ctaKind == .secondhandAvailability,
               item.postID != nil {
                HStack(spacing: 8) {
                    Button("仍在售") {
                        onStillAvailable()
                    }
                    .systemMessageActionStyle(tint: AppColors.link)

                    Button("已售出") {
                        onSold()
                    }
                    .systemMessageActionStyle(tint: .red)

                    Button("查看商品") {
                        onOpen()
                    }
                    .systemMessageActionStyle(tint: AppColors.textPrimary)
                }
            }
        }
        .padding(14)
        .background(
            item.readAt == nil
                ? Color.white
                : Color.white.opacity(0.72)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .modifier(
            SystemMessageCardChromeModifier(
                isEnabled: showsCardChrome,
                cornerRadius: 16
            )
        )
    }

    @ViewBuilder
    private var trailingAction: some View {
        if item.followActorUserID != nil {
            if isFollowingActor == nil || isFollowPending {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 64, height: 30)
            } else if isFollowingActor == true {
                Text("已关注")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AppColors.textMuted)
                    .frame(minWidth: 64, minHeight: 30)
                    .background(AppColors.pageBackground, in: Capsule())
            } else if let onFollowBack {
                Button("回关注", action: onFollowBack)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.black)
                    .frame(minWidth: 64, minHeight: 30)
                    .background(AppColors.accent, in: Capsule())
                    .buttonStyle(.plain)
                    .accessibilityLabel("回关注 \(item.actorName ?? "该用户")")
            }
        } else if isOpening {
            ProgressView()
                .controlSize(.small)
                .padding(.top, 2)
        } else if item.ctaKind != .none {
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(AppColors.textMuted)
                .padding(.top, 4)
        }
    }

    private var messageContent: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(item.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(AppColors.textPrimary)

                if item.readAt == nil {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 7, height: 7)
                }
            }

            Text(item.body)
                .font(.system(size: 13))
                .foregroundStyle(AppColors.textMuted)
                .multilineTextAlignment(.leading)

            Text(
                Formatters.formatCompactTimeAgo(
                    item.createdAt,
                    useJustNow: true
                )
            )
            .font(.system(size: 11))
            .foregroundStyle(AppColors.textMuted.opacity(0.85))
        }
    }

    @ViewBuilder
    private var actorIcon: some View {
        if let onActorTap, item.actorUserID != nil {
            Button(action: onActorTap) {
                iconView
            }
            .buttonStyle(.plain)
            .accessibilityLabel("查看 \(item.actorName ?? "该用户") 的主页")
        } else {
            iconView
        }
    }

    @ViewBuilder
    private var iconView: some View {
        if let avatarURL = item.actorAvatarURL,
           let url = URL(string: avatarURL) {
            AsyncImage(url: url) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                kindIcon
            }
            .frame(width: 42, height: 42)
            .clipShape(Circle())
        } else {
            kindIcon
        }
    }

    private var kindIcon: some View {
        Circle()
            .fill(iconColor.opacity(0.15))
            .frame(width: 42, height: 42)
            .overlay {
                Image(systemName: iconName)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(iconColor)
            }
    }

    private var iconName: String {
        switch item.kind {
        case .automatic: return "bell.fill"
        case .mention: return "at"
        case .postLike, .commentLike: return "heart.fill"
        case .postComment, .commentReply: return "bubble.left.fill"
        case .follow: return "person.badge.plus"
        case .secondhandAvailability: return "bag.fill"
        }
    }

    private var iconColor: Color {
        switch item.kind {
        case .automatic: return .blue
        case .mention: return .purple
        case .postLike, .commentLike: return AppColors.likeActive
        case .postComment, .commentReply: return AppColors.link
        case .follow: return .green
        case .secondhandAvailability: return .orange
        }
    }
}

private struct SystemMessageCardChromeModifier: ViewModifier {
    let isEnabled: Bool
    let cornerRadius: CGFloat

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            content.cheeseCardChrome(cornerRadius: cornerRadius)
        } else {
            content
        }
    }
}

private enum SystemMessageResolvedNavigationTarget: Hashable {
    case forum(ForumPostItem, comments: [ForumCommentItem], commentID: UUID?)
    case secondhand(SecondhandItem)
    case profile(UUID)
}

private extension View {
    func systemMessageActionStyle(tint: Color) -> some View {
        self
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(tint.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 9))
    }
}
