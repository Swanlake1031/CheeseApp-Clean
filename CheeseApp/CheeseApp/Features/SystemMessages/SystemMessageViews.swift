import SwiftUI

struct SystemMessageTimelineView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var authService: AuthService
    @StateObject private var service = SystemMessageService.shared
    @StateObject private var viewModel = SystemMessageViewModel()
    @State private var pendingSoldMessage: SystemMessageItem?

    let onOpenPost: (PostDeepLinkRoute) -> Void
    let onOpenProfile: (UUID) -> Void

    var body: some View {
        ZStack {
            AppColors.pageBackground.ignoresSafeArea()

            switch viewModel.loadState {
            case .unresolved, .initialLoading:
                loadingState
            case .empty:
                emptyState
            case .error(let message):
                ErrorView(message) {
                    Task { await viewModel.loadInitial(force: true) }
                }
            case .loaded:
                timeline
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .enableSwipeBackGesture()
        .safeAreaInset(edge: .top) {
            CheeseInlineTopBar {
                Button {
                    dismiss()
                } label: {
                    PostToolbarIconCircle(icon: "chevron.left")
                }
                .buttonStyle(.plain)
            } center: {
                Text("系统消息")
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
        .task(id: authService.currentUser?.id) {
            viewModel.activateAccount(authService.currentUser?.id)
            await viewModel.loadInitial()
            await service.refreshUnreadCount()
        }
        .refreshable {
            await viewModel.loadInitial(force: true)
            await service.refreshUnreadCount()
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
            "系统消息",
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

    private var timeline: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(spacing: 12) {
                ForEach(viewModel.items) { item in
                    SystemMessageRow(
                        item: item,
                        onOpen: { open(item) },
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
                        Task {
                            await viewModel.loadNextPageIfNeeded(
                                currentItem: item
                            )
                        }
                    }
                }

                if viewModel.isLoadingNextPage {
                    ProgressView()
                        .padding(.vertical, 12)
                } else if let errorMessage = viewModel.errorMessage {
                    Button("加载失败，点此重试") {
                        guard let last = viewModel.items.last else { return }
                        Task {
                            await viewModel.loadNextPageIfNeeded(
                                currentItem: last
                            )
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

    private var loadingState: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text("正在加载系统消息…")
                .font(.system(size: 13))
                .foregroundStyle(AppColors.textMuted)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "bell.slash")
                .font(.system(size: 40))
                .foregroundStyle(AppColors.textMuted)
            Text("还没有系统消息")
                .font(.system(size: 16, weight: .semibold))
            Text("回复、评论、提及、点赞、关注和商品状态提醒会显示在这里。")
                .font(.system(size: 13))
                .foregroundStyle(AppColors.textMuted)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 28)
    }

    private func open(_ item: SystemMessageItem) {
        Task { await viewModel.markRead(item) }

        switch item.ctaKind {
        case .viewPost, .secondhandAvailability:
            let resolvedKind: PostKind?
            if let postKind = item.postKind {
                resolvedKind = postKind
            } else if item.kind == .secondhandAvailability {
                resolvedKind = .secondhand
            } else {
                resolvedKind = nil
            }
            guard let postID = item.postID, let kind = resolvedKind else {
                viewModel.actionMessage = "原内容已删除或不可见"
                return
            }
            onOpenPost(PostDeepLinkRoute(kind: kind, postId: postID))

        case .viewProfile:
            guard let actorUserID = item.actorUserID else {
                viewModel.actionMessage = "该用户已不可用"
                return
            }
            onOpenProfile(actorUserID)

        case .none:
            break
        }
    }
}

private struct SystemMessageRow: View {
    let item: SystemMessageItem
    let onOpen: () -> Void
    let onStillAvailable: () -> Void
    let onSold: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(action: onOpen) {
                HStack(alignment: .top, spacing: 12) {
                    iconView

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

                    Spacer(minLength: 4)
                    if item.ctaKind != .none {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(AppColors.textMuted)
                            .padding(.top, 4)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

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
        .cheeseCardChrome(cornerRadius: 16)
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
