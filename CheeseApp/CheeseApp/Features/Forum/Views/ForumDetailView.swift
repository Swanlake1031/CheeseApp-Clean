//
//  ForumListView.swift
//  CheeseApp
//
//  💬 论坛列表视图
//  展示论坛帖子，支持分类筛选
//

import SwiftUI
import UIKit

struct ForumDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var authService: AuthService
    @ObservedObject private var service = ForumService.shared
    @ObservedObject private var interactionStore = PostInteractionStore.shared
    @StateObject private var postEditor = UserPostsService()

    @State private var post: ForumPostItem
    @State private var comments: [ForumCommentItem] = []
    @State private var commentLoadState: CollectionLoadState = .unresolved
    @State private var commentText = ""
    @State private var selectedCommentMentions: [MentionCandidate] = []
    @State private var commentRequestID = UUID()
    @State private var commentAnonymous = false
    @State private var replyingToComment: ForumCommentItem?
    @State private var isLiking = false
    @State private var isTogglingFavorite = false
    @State private var isSubmittingComment = false
    @State private var showingCommentComposer = false
    @State private var errorMessage: String?
    @State private var showingReportSheet = false
    @State private var editingPost: UserPostSummary?
    @State private var showingDeleteConfirm = false
    @State private var deletingComment: ForumCommentItem?
    @State private var reportingComment: ForumCommentItem?
    @State private var isRefreshing = false
    @State private var sharingPost: PostSharePayload?
    @State private var shareActionToastMessage: String?
    @State private var isCommentFieldFocused = false
    @State private var collapsedRootCommentIds: Set<UUID> = []
    @State private var expandedRootCommentIds: Set<UUID> = []
    @State private var suppressReplyTargetActivationForCurrentTap = false
    @State private var suppressOutsideComposerDismissForCurrentTap = false
    private let autoCollapseReplyThreshold = 3
    private let commentSectionAnchorId = "forum-comment-section-anchor"
    private let initialCommentID: UUID?

    init(post: ForumPostItem, initialCommentID: UUID? = nil) {
        _post = State(initialValue: post)
        self.initialCommentID = initialCommentID
    }

    private var interaction: PostInteractionState {
        interactionStore.state(
            for: post.id,
            fallbackLikeCount: post.likes,
            fallbackIsLiked: post.isLiked
        )
    }

    var body: some View {
        ZStack {
            AppColors.pageBackground
                .ignoresSafeArea()

            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 0) {
                        postHeader
                        postContent
                        commentSection
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                    .padding(.bottom, 12)
                }
                .scrollDismissesKeyboard(.interactively)
                .simultaneousGesture(
                    TapGesture().onEnded {
                        handleTapOutsideComposer()
                    },
                    including: .gesture
                )
                .refreshable {
                    isRefreshing = true
                    await reloadData()
                    try? await Task.sleep(nanoseconds: 450_000_000)
                    isRefreshing = false
                }
                .task(id: initialCommentID) {
                    await service.recordView(postId: post.id)
                    async let favoriteState: Void = loadFavoriteState()
                    await reloadData()
                    await favoriteState
                    await scrollToInitialComment(using: proxy)
                }
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .cheeseTabBarHidden(true)
        .safeAreaInset(edge: .top) {
            PostDetailTopBar(title: L10n.tr("Forum Post", "论坛贴文"), onBack: { dismiss() }) {
                Button {
                    sharingPost = post.sharePayload
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

                    if authService.currentUser?.id == post.authorId {
                        Button {
                            editingPost = post.editableSummary
                        } label: {
                            Label(L10n.tr("Edit", "编辑"), systemImage: "square.and.pencil")
                        }

                        Button(role: .destructive) {
                            showingDeleteConfirm = true
                        } label: {
                            Label(L10n.tr("Delete", "删除"), systemImage: "trash")
                        }
                    } else {
                        Button(role: .destructive) {
                            showingReportSheet = true
                        } label: {
                            Label(L10n.tr("Report", "检举"), systemImage: "flag.fill")
                        }
                    }
                } label: {
                    PostToolbarIconCircle(icon: "ellipsis")
                }
                .buttonStyle(.plain)
                .tint(AppColors.textPrimary)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            commentComposer
        }
        .overlay(alignment: .top) {
            if isRefreshing {
                HotpotSteamRefreshView()
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .shareFeedbackToast(message: $shareActionToastMessage)
        .sheet(isPresented: $showingReportSheet) {
            ReportPostSheet(postId: post.id, postKind: .forum)
        }
        .sheet(item: $reportingComment) { comment in
            ReportCommentSheet(commentId: comment.id)
        }
        .navigationDestination(item: $editingPost) { summary in
            EditPostSheet(post: summary) { payload in
                try await postEditor.update(payload: payload)
                await reloadData()
            }
        }
        .cheesePostSharePanel(item: $sharingPost) { targetName in
            ShareFeedbackPresenter.show("已分享到 \(targetName)") {
                shareActionToastMessage = $0
            }
        }
        .sheet(isPresented: $showingCommentComposer, onDismiss: {
            clearReplyTargetAndRestoreViewport(dismissKeyboard: true)
        }) {
            expandedCommentComposer
                // Keep the composer attached to the keyboard at its content height.
                // Offering `.medium` here lets UIKit promote the sheet when focus
                // changes, which caused the large empty panel seen on comment/reply.
                .presentationDetents([.height(commentComposerHeight)])
                .presentationDragIndicator(.hidden)
                .presentationCornerRadius(24)
                .presentationBackground(AppColors.pageBackground)
                .interactiveDismissDisabled(isSubmittingComment)
        }
        .alert(L10n.tr("Delete this post?", "确定删除这篇贴文？"), isPresented: $showingDeleteConfirm) {
            Button(L10n.tr("Cancel", "取消"), role: .cancel) {}
            Button(L10n.tr("Delete", "删除"), role: .destructive) {
                Task { await deletePost() }
            }
        } message: {
            Text(L10n.tr("This action cannot be undone.", "删除后无法复原。"))
        }
        .alert(
            L10n.tr("Delete this comment?", "确定删除这条评论？"),
            isPresented: Binding(
                get: { deletingComment != nil },
                set: { if !$0 { deletingComment = nil } }
            ),
            presenting: deletingComment
        ) { comment in
            Button(L10n.tr("Cancel", "取消"), role: .cancel) {
                deletingComment = nil
            }
            Button(L10n.tr("Delete", "删除"), role: .destructive) {
                Task { await deleteComment(comment) }
            }
        } message: { _ in
            Text(L10n.tr("This action cannot be undone.", "删除后无法复原。"))
        }
        .onReceive(service.$posts) { latestPosts in
            guard let updated = latestPosts.first(where: { $0.id == post.id }) else { return }
            var merged = updated
            merged.isLiked = interaction.isLiked
            merged.likes = interaction.likeCount
            merged.views = max(merged.views, post.views)
            merged.comments = max(merged.comments, post.comments)
            post = merged
        }
        .onChange(of: authService.currentUser?.id) { _, _ in
            Task { await loadFavoriteState() }
        }
        .enableSwipeBackGesture()
    }

    private var postHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label(post.boardName, systemImage: post.boardIcon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AppColors.textMuted)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color(.systemGray6))
                    .clipShape(Capsule())

                if post.isPinned {
                    Label(L10n.tr("Pinned", "置顶"), systemImage: "pin.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(AppColors.link)
                }

                Spacer()

                Text(post.timeAgo)
                    .font(.system(size: 12))
                    .foregroundStyle(AppColors.textMuted)
            }

            if let authorId = post.authorId, !post.isAnonymous {
                NavigationLink {
                    UserPostsView(userId: authorId)
                } label: {
                    HStack(spacing: 10) {
                        detailAuthorAvatar(size: 32)

                        HStack(spacing: 4) {
                            Text(post.authorName)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(AppColors.textPrimary)
                            if post.isAuthorMcMasterVerified {
                                McMasterStudentBadge()
                            }
                        }
                    }
                }
                .buttonStyle(.plain)
            } else {
                HStack(spacing: 10) {
                    Circle()
                        .fill(Color(.systemGray4))
                        .frame(width: 32, height: 32)
                        .overlay {
                            Image(systemName: "theatermasks.fill")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(.white)
                        }

                    Text(L10n.tr("Anonymous", "匿名"))
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(AppColors.textPrimary)
                }
            }
        }
        .padding(.top, 12)
        .padding(.bottom, 6)
    }

    private func detailAuthorAvatar(size: CGFloat) -> some View {
        Group {
            if let avatar = post.authorAvatar,
               let url = URL(string: avatar),
               !avatar.isEmpty {
                CachedRemoteImage(url: url, targetPixelWidth: 160) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    detailAuthorAvatarFallback(size: size)
                }
            } else {
                detailAuthorAvatarFallback(size: size)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }

    private func detailAuthorAvatarFallback(size: CGFloat) -> some View {
        Circle()
            .fill(AppColors.accent)
            .overlay {
                Text(String(post.authorName.prefix(1)).uppercased())
                    .font(.system(size: size * 0.42, weight: .bold))
                    .foregroundStyle(.white)
            }
    }

    private var postContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(post.title)
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(AppColors.textPrimary)

            if !post.content.isEmpty {
                Text(post.content)
                    .font(.system(size: 15))
                    .foregroundStyle(AppColors.textMuted)
                    .lineSpacing(4)
            }

            MentionedProfilesView(postID: post.id)

            if !post.imageUrls.isEmpty {
                PostImageCarousel(
                    urlStrings: post.imageUrls,
                    height: 190,
                    cornerRadius: 12
                ) {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.gray.opacity(0.15))
                }
            }

            Divider().overlay(AppColors.divider)

            HStack(spacing: 6) {
                Button(action: {
                    Task { @MainActor in
                        await toggleLike()
                    }
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: interaction.isLiked ? "heart.fill" : "heart")
                            .foregroundStyle(interaction.isLiked ? AppColors.likeActive : AppColors.textMuted)
                        Text("\(interaction.likeCount)")
                            .monospacedDigit()
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .foregroundStyle(interaction.isLiked ? AppColors.likeActive : AppColors.textMuted)
                    }
                    .font(.system(size: 14, weight: .medium))
                    .frame(minWidth: 52, alignment: .leading)
                }
                .buttonStyle(.plain)
                .disabled(isLiking)

                HStack(spacing: 4) {
                    Image(systemName: "bubble.right")
                    Text("\(post.comments)")
                        .monospacedDigit()
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(AppColors.textMuted)
                .frame(minWidth: 52, alignment: .leading)

                HStack(spacing: 4) {
                    Image(systemName: "eye")
                    Text("\(post.views)")
                        .monospacedDigit()
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(AppColors.textMuted)
                .frame(minWidth: 52, alignment: .leading)

                Spacer()

                Button {
                    Task { await toggleFavorite() }
                } label: {
                    Image(systemName: interaction.isFavorited ? "star.fill" : "star")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(interaction.isFavorited ? AppColors.accentStrong : AppColors.textMuted)
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isTogglingFavorite)
                .opacity(isTogglingFavorite ? 0.55 : 1)
                .accessibilityLabel(
                    interaction.isFavorited
                        ? L10n.tr("Remove bookmark", "取消收藏")
                        : L10n.tr("Bookmark", "收藏")
                )
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 13))
                    .foregroundStyle(.red)
                    .padding(.top, 4)
            }
        }
        .padding(.top, 10)
        .padding(.bottom, 16)
        .overlay(alignment: .bottom) {
            Divider()
                .overlay(AppColors.divider)
        }
    }

    private var commentSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.tr("Comments", "评论"))
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(AppColors.textPrimary)

            switch commentLoadState {
            case .unresolved, .initialLoading:
                ProgressView()
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 10)
            case .empty:
                Text(L10n.tr("No comments yet. Be the first to reply.", "还没有评论，来当第一位留言者吧。"))
                    .font(.system(size: 14))
                    .foregroundStyle(AppColors.textMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 14)
            case .error(let message):
                ErrorView(message) {
                    Task { await reloadData() }
                }
                .frame(maxWidth: .infinity)
            case .loaded:
                LazyVStack(spacing: 0) {
                    ForEach(threadedComments) { node in
                        let parentName = parentAuthorName(for: node.comment)
                        commentRow(node.comment, parentAuthorName: parentName, depth: node.depth, rootId: node.rootId)
                            .id(commentScrollId(for: node.comment.id))
                    }
                }
            }
        }
        .padding(.top, 18)
        .id(commentSectionAnchorId)
    }

    private struct ThreadedCommentNode: Identifiable {
        let comment: ForumCommentItem
        let depth: Int
        let rootId: UUID
        var id: UUID { comment.id }
    }

    private var commentLookup: [UUID: ForumCommentItem] {
        Dictionary(uniqueKeysWithValues: comments.map { ($0.id, $0) })
    }

    private var rootCommentIdMap: [UUID: UUID] {
        buildRootCommentIdMap(from: comments)
    }

    private var threadedComments: [ThreadedCommentNode] {
        let ordered = comments.sorted { $0.createdAt < $1.createdAt }
        guard !ordered.isEmpty else { return [] }

        let rootMap = buildRootCommentIdMap(from: ordered)
        var groupedByRoot: [UUID: [ForumCommentItem]] = [:]
        var rootOrder: [UUID] = []
        var seenRootIds: Set<UUID> = []

        var result: [ThreadedCommentNode] = []
        for comment in ordered {
            let rootId = rootMap[comment.id] ?? comment.id
            groupedByRoot[rootId, default: []].append(comment)
            if seenRootIds.insert(rootId).inserted {
                rootOrder.append(rootId)
            }
        }

        for rootId in rootOrder {
            guard let group = groupedByRoot[rootId]?.sorted(by: { $0.createdAt < $1.createdAt }),
                  let rootComment = group.first(where: { $0.id == rootId }) ?? group.first else {
                continue
            }

            result.append(ThreadedCommentNode(comment: rootComment, depth: 0, rootId: rootComment.id))

            if shouldCollapseReplies(forRootId: rootComment.id, map: rootMap) {
                continue
            }

            for reply in group where reply.id != rootComment.id {
                result.append(ThreadedCommentNode(comment: reply, depth: 1, rootId: rootComment.id))
            }
        }

        return result
    }

    private func buildRootCommentIdMap(from source: [ForumCommentItem]) -> [UUID: UUID] {
        let lookup = Dictionary(uniqueKeysWithValues: source.map { ($0.id, $0) })
        var cache: [UUID: UUID] = [:]

        func resolveRoot(for commentId: UUID) -> UUID {
            if let cached = cache[commentId] {
                return cached
            }

            guard var current = lookup[commentId] else {
                cache[commentId] = commentId
                return commentId
            }

            var path: [UUID] = [commentId]
            var visited: Set<UUID> = [commentId]

            while let parentId = current.parentId {
                guard let parent = lookup[parentId], !visited.contains(parent.id) else { break }
                visited.insert(parent.id)
                path.append(parent.id)
                current = parent
            }

            let rootId = current.id
            for pathId in path {
                cache[pathId] = rootId
            }
            return rootId
        }

        for comment in source {
            _ = resolveRoot(for: comment.id)
        }
        return cache
    }

    private func rootCommentId(for commentId: UUID, map: [UUID: UUID]? = nil) -> UUID {
        let currentMap = map ?? rootCommentIdMap
        return currentMap[commentId] ?? commentId
    }

    private func commentRow(_ comment: ForumCommentItem, parentAuthorName: String?, depth: Int, rootId: UUID) -> some View {
        let isParentComment = depth == 0
        let replyCount = isParentComment ? descendantCount(forRootId: rootId) : 0
        let isCollapsed = isParentComment ? shouldCollapseReplies(forRootId: rootId) : false
        return HStack(alignment: .top, spacing: 10) {
            commentAuthorAvatar(comment)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    commentAuthorName(comment)

                    if comment.isAuthorMcMasterVerified {
                        McMasterStudentBadge()
                    }

                    Text(comment.timeAgo)
                        .font(.system(size: 12))
                        .foregroundStyle(AppColors.textMuted)

                    Spacer()

                    if comment.likeCount > 0 {
                        HStack(spacing: 4) {
                            Image(systemName: "heart.fill")
                                .font(.system(size: 10))
                            Text("\(comment.likeCount)")
                                .font(.system(size: 11))
                        }
                        .foregroundStyle(AppColors.likeActive)
                    }

                    Menu {
                        if canDeleteComment(comment) {
                            Button(role: .destructive) {
                                requestCommentDeletion(comment)
                            } label: {
                                Label(L10n.tr("Delete", "删除"), systemImage: "trash")
                            }
                        } else {
                            Button(role: .destructive) {
                                reportingComment = comment
                            } label: {
                                Label(L10n.tr("Report", "举报"), systemImage: "flag")
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(AppColors.textMuted)
                            .frame(width: 30, height: 30)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .tint(AppColors.textMuted)
                }

                if let parentAuthorName, comment.parentId != nil {
                    Button {
                        focusParentComment(for: comment)
                    } label: {
                        Text("回复 \(parentAuthorName)")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(AppColors.link)
                    }
                    .buttonStyle(.plain)
                }

                Text(comment.content)
                    .font(.system(size: 14))
                    .foregroundStyle(AppColors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        beginReply(to: comment)
                    }

                MentionedProfilesView(
                    postID: post.id,
                    commentID: comment.id
                )

                HStack {
                    Button {
                        beginReply(to: comment)
                    } label: {
                        Text("回复")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(AppColors.textMuted)
                    }
                    .buttonStyle(.plain)

                    if isParentComment && replyCount > 0 {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                toggleRepliesCollapse(forRootId: rootId)
                            }
                        } label: {
                            Text(isCollapsed ? "展开 \(replyCount) 则回复" : "收起 \(replyCount) 则回复")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(AppColors.link)
                        }
                        .buttonStyle(.plain)
                    }

                    Spacer()
                }
            }
        }
        .padding(.vertical, 13)
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) {
            Divider()
                .overlay(AppColors.divider)
                .padding(.leading, 42)
        }
        .padding(.leading, depth == 0 ? 0 : 14)
    }

    @ViewBuilder
    private func commentAuthorAvatar(_ comment: ForumCommentItem) -> some View {
        if comment.isAnonymous {
            commentAvatarView(comment)
        } else {
            NavigationLink {
                UserPostsView(userId: comment.userId)
            } label: {
                commentAvatarView(comment)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("查看 \(comment.authorName) 的个人资料")
        }
    }

    @ViewBuilder
    private func commentAuthorName(_ comment: ForumCommentItem) -> some View {
        if comment.isAnonymous {
            commentAuthorNameLabel(comment)
        } else {
            NavigationLink {
                UserPostsView(userId: comment.userId)
            } label: {
                commentAuthorNameLabel(comment)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("查看 \(comment.authorName) 的个人资料")
        }
    }

    private func commentAuthorNameLabel(_ comment: ForumCommentItem) -> some View {
        Text(comment.authorName)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(AppColors.textPrimary)
            .lineLimit(1)
    }

    private func commentAvatarView(_ comment: ForumCommentItem) -> some View {
        Group {
            if comment.isAnonymous {
                Circle()
                    .fill(Color(.systemGray4))
                    .overlay {
                        Image(systemName: "theatermasks.fill")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white)
                    }
            } else if let avatar = comment.authorAvatar,
                      let url = URL(string: avatar),
                      !avatar.isEmpty {
                CachedRemoteImage(url: url, targetPixelWidth: 128) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    commentAvatarFallback(comment)
                }
            } else {
                commentAvatarFallback(comment)
            }
        }
        .frame(width: 30, height: 30)
        .clipShape(Circle())
    }

    private func commentAvatarFallback(_ comment: ForumCommentItem) -> some View {
        Circle()
            .fill(AppColors.accent.opacity(0.9))
            .overlay {
                Text(String(comment.authorName.prefix(1)).uppercased())
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
            }
    }

    private func canDeleteComment(_ comment: ForumCommentItem) -> Bool {
        return comment.userId == authService.currentUser?.id
    }

    private func requestCommentDeletion(_ comment: ForumCommentItem) {
        deletingComment = comment
    }

    private func beginReply(to comment: ForumCommentItem) {
        markCurrentTapAsCommentInteraction(suppressOutsideDismiss: replyingToComment == nil)
        guard !suppressReplyTargetActivationForCurrentTap else { return }
        if replyingToComment != nil {
            consumeTapToCancelActiveReply()
            return
        }

        let rootId = rootCommentId(for: comment.id)
        collapsedRootCommentIds.remove(rootId)
        expandedRootCommentIds.insert(rootId)

        replyingToComment = comment
        presentCommentComposer()
    }

    private func focusParentComment(for comment: ForumCommentItem) {
        markCurrentTapAsCommentInteraction(suppressOutsideDismiss: replyingToComment == nil)
        guard !suppressReplyTargetActivationForCurrentTap else { return }
        if replyingToComment != nil {
            consumeTapToCancelActiveReply()
            return
        }

        guard let parentId = comment.parentId else {
            beginReply(to: comment)
            return
        }

        guard let parentComment = commentLookup[parentId] else {
            beginReply(to: comment)
            return
        }

        let rootId = rootCommentId(for: parentId)
        collapsedRootCommentIds.remove(rootId)
        expandedRootCommentIds.insert(rootId)
        replyingToComment = parentComment
        presentCommentComposer()
    }

    private func toggleRepliesCollapse(forRootId rootId: UUID) {
        if shouldCollapseReplies(forRootId: rootId) {
            collapsedRootCommentIds.remove(rootId)
            expandedRootCommentIds.insert(rootId)
        } else {
            expandedRootCommentIds.remove(rootId)
            collapsedRootCommentIds.insert(rootId)
        }
    }

    private func shouldCollapseReplies(forRootId rootId: UUID, map: [UUID: UUID]? = nil) -> Bool {
        if collapsedRootCommentIds.contains(rootId) {
            return true
        }
        let autoCollapsed = descendantCount(forRootId: rootId, map: map) >= autoCollapseReplyThreshold
        if autoCollapsed && !expandedRootCommentIds.contains(rootId) {
            return true
        }
        return false
    }

    private func descendantCount(forRootId rootId: UUID, map: [UUID: UUID]? = nil) -> Int {
        let currentMap = map ?? rootCommentIdMap
        let totalInThread = currentMap.values.reduce(into: 0) { count, candidateRootId in
            if candidateRootId == rootId {
                count += 1
            }
        }
        return max(0, totalInThread - 1)
    }

    private func parentAuthorName(for comment: ForumCommentItem) -> String? {
        guard let parentId = comment.parentId else { return nil }
        return commentLookup[parentId]?.authorName
    }

    private var commentInputPlaceholder: String {
        replyingToComment == nil
            ? L10n.tr("Write a comment...", "我想说...")
            : L10n.tr("Write a reply...", "回复 \(replyingToComment?.authorName ?? "")...")
    }

    private var commentComposer: some View {
        VStack(spacing: 0) {
            Divider().overlay(AppColors.divider)

            HStack(spacing: 12) {
                Button(action: presentCommentComposer) {
                    Text(compactCommentPlaceholder)
                        .font(.system(size: 15))
                        .foregroundStyle(AppColors.textMuted)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 15)
                        .frame(height: 40)
                        .background(
                            Color(red: 0.94, green: 0.94, blue: 0.95),
                            in: Capsule(style: .continuous)
                        )
                        .overlay {
                            Capsule(style: .continuous)
                                .stroke(Color.black.opacity(0.14), lineWidth: 1)
                        }
                        .shadow(color: .black.opacity(0.04), radius: 4, x: 0, y: 2)
                }
                .buttonStyle(.plain)
                .frame(minWidth: 96, maxWidth: .infinity)

                HStack(spacing: 8) {
                    detailBottomAction(
                        icon: interaction.isLiked ? "heart.fill" : "heart",
                        count: interaction.likeCount,
                        isActive: interaction.isLiked,
                        isDisabled: isLiking
                    ) {
                        Task { await toggleLike() }
                    }

                    detailBottomAction(
                        icon: interaction.isFavorited ? "star.fill" : "star",
                        isActive: interaction.isFavorited,
                        isDisabled: isTogglingFavorite
                    ) {
                        Task { await toggleFavorite() }
                    }

                    detailBottomAction(icon: "square.and.arrow.up") {
                        sharingPost = post.sharePayload
                    }
                }
                .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
        }
        .background(AppColors.pageBackground)
    }

    private var compactCommentPlaceholder: String {
        let draft = commentText.trimmingCharacters(in: .whitespacesAndNewlines)
        return draft.isEmpty ? commentInputPlaceholder : draft
    }

    private func detailBottomAction(
        icon: String,
        count: Int? = nil,
        isActive: Bool = false,
        isDisabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 19, weight: .medium))
                if let count {
                    Text("\(count)")
                        .font(.system(size: 13, weight: .medium))
                        .monospacedDigit()
                }
            }
            .foregroundStyle(
                isActive
                    ? (icon.contains("heart") ? AppColors.likeActive : AppColors.accentStrong)
                    : AppColors.textPrimary.opacity(0.72)
            )
            .frame(minWidth: 30, minHeight: 40)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.55 : 1)
        .accessibilityLabel(bottomActionAccessibilityLabel(for: icon))
    }

    private func bottomActionAccessibilityLabel(for icon: String) -> String {
        if icon.contains("heart") {
            return interaction.isLiked ? L10n.tr("Unlike", "取消点赞") : L10n.tr("Like", "点赞")
        }
        if icon.contains("star") {
            return interaction.isFavorited ? L10n.tr("Remove bookmark", "取消收藏") : L10n.tr("Bookmark", "收藏")
        }
        return L10n.tr("Share", "分享")
    }

    private var expandedCommentComposer: some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    showingCommentComposer = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(AppColors.textPrimary)
                        .frame(width: 40, height: 40)
                }
                .buttonStyle(.plain)

                Spacer()

                Text(replyingToComment == nil ? L10n.tr("Comment", "留言") : L10n.tr("Reply", "回复"))
                    .font(.system(size: 19, weight: .bold))

                Spacer()

                Color.clear
                    .frame(width: 40, height: 40)
            }
            .padding(.horizontal, 8)
            .padding(.top, 6)
            .offset(y: -6)

            Divider().overlay(AppColors.divider)

            if let replyingToComment {
                HStack(spacing: 10) {
                    Text(
                        L10n.tr(
                            "Replying to \(replyingToComment.authorName)",
                            "正在回复 \(replyingToComment.authorName)"
                        )
                    )
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(AppColors.textMuted)
                    .lineLimit(1)

                    Spacer(minLength: 8)

                    Button {
                        clearReplyTargetAndRestoreViewport()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(AppColors.textMuted)
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.tr("Cancel reply", "取消回复"))
                }
                .padding(.horizontal, 18)
                .frame(height: 40)
                .background(Color.black.opacity(0.045))
            }

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 9) {
                    AvatarView(source: commentAuthorAvatarSource, size: 36)

                    Text(commentAuthorName)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(AppColors.textPrimary)

                    Spacer()
                }

                ZStack(alignment: .topLeading) {
                    if commentText.isEmpty {
                        Text(commentInputPlaceholder)
                            .font(.system(size: 18))
                            .foregroundStyle(AppColors.textMuted)
                            .padding(.vertical, 4)
                            .allowsHitTesting(false)
                    }

                    AutoFocusTextEditor(
                        text: $commentText,
                        isFirstResponder: $isCommentFieldFocused,
                        fontSize: 18
                    )
                        .frame(height: 58)
                }

                MentionSuggestionPanel(
                    text: $commentText,
                    selectedMentions: $selectedCommentMentions,
                    maxVisibleCandidates: 3
                )

                HStack(spacing: 12) {
                    Button {
                        commentAnonymous.toggle()
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: commentAnonymous ? "checkmark.square.fill" : "square")
                                .font(.system(size: 18, weight: .medium))
                                .foregroundStyle(commentAnonymous ? AppColors.accentStrong : AppColors.textMuted)
                            Text(
                                replyingToComment == nil
                                    ? L10n.tr("Comment anonymously", "匿名留言")
                                    : L10n.tr("Reply anonymously", "匿名回复")
                            )
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(AppColors.textPrimary)
                        }
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    Button {
                        Task { await submitComment() }
                    } label: {
                        if isSubmittingComment {
                            ProgressView()
                                .frame(width: 48, height: 30)
                        } else {
                            Text(L10n.tr("Send", "送出"))
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(canSubmitComment ? AppColors.accentStrong : AppColors.textMuted)
                                .frame(minWidth: 48, minHeight: 30)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSubmitComment || isSubmittingComment)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, 6)
        }
        .background(AppColors.pageBackground)
        .animation(.easeInOut(duration: 0.18), value: isMentionQueryActive)
    }

    private var commentAuthorName: String {
        if let fullName = authService.currentUser?.fullName?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !fullName.isEmpty {
            return fullName
        }

        if let email = authService.currentUser?.email,
           let emailName = email.split(separator: "@").first,
           !emailName.isEmpty {
            return String(emailName)
        }

        return L10n.tr("Campus user", "校园用户")
    }

    private var commentAuthorAvatarSource: ImageSource {
        guard let avatarURL = authService.currentUser?.avatarUrl?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !avatarURL.isEmpty,
              let url = URL(string: avatarURL) else {
            return .placeholder
        }
        return .url(url)
    }

    private var isMentionQueryActive: Bool {
        MentionTextLogic.query(in: commentText) != nil
    }

    private var commentComposerHeight: CGFloat {
        let compactHeight: CGFloat = replyingToComment == nil ? 216 : 252
        return isMentionQueryActive ? compactHeight + 146 : compactHeight
    }

    private var canSubmitComment: Bool {
        !commentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func reloadData() async {
        if comments.isEmpty {
            commentLoadState = .initialLoading
        }

        do {
            async let latestPostTask = service.fetchPost(postId: post.id)
            async let latestCommentsTask = service.fetchComments(postId: post.id)
            let (latestPost, latestComments) = try await (latestPostTask, latestCommentsTask)
            post = mergedDetailPost(from: latestPost)
            comments = latestComments
            commentLoadState = comments.isEmpty ? .empty : .loaded
            let validRootIds = Set(buildRootCommentIdMap(from: comments).values)
            collapsedRootCommentIds = collapsedRootCommentIds.intersection(validRootIds)
            expandedRootCommentIds = expandedRootCommentIds.intersection(validRootIds)
            if let replyingToComment, !comments.contains(where: { $0.id == replyingToComment.id }) {
                self.replyingToComment = nil
            }
            errorMessage = nil
        } catch {
            if isCancellation(error) { return }
            let loadMessage = "\(L10n.tr("Load failed", "载入失败")): \(error.localizedDescription)"
            errorMessage = loadMessage
            if comments.isEmpty {
                commentLoadState = .error(message: loadMessage)
            }
        }
    }

    private func mergedDetailPost(from fetched: ForumPostItem) -> ForumPostItem {
        let local = service.posts.first(where: { $0.id == fetched.id })
        var merged = fetched
        let resolvedInteraction = interactionStore.state(
            for: fetched.id,
            fallbackLikeCount: local?.likes ?? fetched.likes,
            fallbackIsLiked: local?.isLiked ?? fetched.isLiked
        )
        merged.likes = resolvedInteraction.likeCount
        merged.isLiked = resolvedInteraction.isLiked
        let localViews = local?.views ?? 0
        let localComments = local?.comments ?? 0
        merged.views = max(fetched.views, max(localViews, post.views))
        merged.comments = max(fetched.comments, max(localComments, post.comments))
        return merged
    }

    @MainActor
    private func toggleLike() async {
        guard !isLiking else { return }
        isLiking = true
        defer { isLiking = false }

        let previous = interaction
        let previousLiked = previous.isLiked
        let previousLikes = previous.likeCount
        let optimisticLiked = !previousLiked
        let optimisticLikes = max(previousLikes + (optimisticLiked ? 1 : -1), 0)
        interactionStore.replace(
            postID: post.id,
            with: PostInteractionState(
                likeCount: optimisticLikes,
                isLiked: optimisticLiked,
                isFavorited: previous.isFavorited
            )
        )

        do {
            let committedLiked = try await service.toggleLike(postId: post.id, currentlyLiked: previousLiked)
            var confirmed = interactionStore.state(
                for: post.id,
                fallbackLikeCount: optimisticLikes,
                fallbackIsLiked: committedLiked,
                fallbackIsFavorited: previous.isFavorited
            )
            confirmed.isLiked = committedLiked
            if let synced = service.posts.first(where: { $0.id == post.id }) {
                if synced.isLiked == committedLiked {
                    confirmed.likeCount = synced.likes
                } else {
                    confirmed.likeCount = max(previousLikes + (committedLiked ? 1 : -1), 0)
                }
            } else if committedLiked != optimisticLiked {
                confirmed.likeCount = max(previousLikes + (committedLiked ? 1 : -1), 0)
            }
            interactionStore.replace(postID: post.id, with: confirmed)
            errorMessage = nil
        } catch {
            interactionStore.replace(postID: post.id, with: previous)
            if isCancellation(error) { return }
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func loadFavoriteState() async {
        let favoriteState = await service.isFavorite(postId: post.id)
        guard !Task.isCancelled else { return }
        interactionStore.setFavorite(postID: post.id, isFavorited: favoriteState)
    }

    @MainActor
    private func toggleFavorite() async {
        guard !isTogglingFavorite else { return }
        isTogglingFavorite = true
        defer { isTogglingFavorite = false }

        let previous = interaction
        let previousValue = previous.isFavorited
        var optimistic = previous
        optimistic.isFavorited.toggle()
        interactionStore.replace(postID: post.id, with: optimistic)

        do {
            let confirmed = try await service.toggleFavorite(
                postId: post.id,
                currentlyFavorited: previousValue
            )
            interactionStore.setFavorite(postID: post.id, isFavorited: confirmed)
            errorMessage = nil
        } catch {
            interactionStore.replace(postID: post.id, with: previous)
            if isCancellation(error) { return }
            errorMessage = error.localizedDescription
        }
    }

    private func presentCommentComposer() {
        isCommentFieldFocused = true
        showingCommentComposer = true
    }

    private func submitComment() async {
        let trimmed = commentText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isSubmittingComment else { return }

        let replyTargetBeforeSubmit = replyingToComment
        let parentId = replyTargetBeforeSubmit?.id

        replyingToComment = nil
        dismissCommentKeyboard()

        isSubmittingComment = true
        defer { isSubmittingComment = false }

        do {
            _ = try await service.createComment(
                commentId: commentRequestID,
                postId: post.id,
                content: trimmed,
                isAnonymous: commentAnonymous,
                parentId: parentId,
                mentionedUserIds: MentionTextLogic.activeUserIDs(
                    in: trimmed,
                    selected: selectedCommentMentions
                )
            )
            commentText = ""
            selectedCommentMentions = []
            commentRequestID = UUID()
            commentAnonymous = false
            showingCommentComposer = false
            if let parentId {
                let rootId = rootCommentId(for: parentId)
                collapsedRootCommentIds.remove(rootId)
                expandedRootCommentIds.insert(rootId)
            }
            comments = try await service.fetchComments(postId: post.id)
            commentLoadState = comments.isEmpty ? .empty : .loaded
            let validRootIds = Set(buildRootCommentIdMap(from: comments).values)
            collapsedRootCommentIds = collapsedRootCommentIds.intersection(validRootIds)
            expandedRootCommentIds = expandedRootCommentIds.intersection(validRootIds)
            if let updated = service.posts.first(where: { $0.id == post.id }) {
                post.comments = updated.comments
            }
            errorMessage = nil
        } catch {
            if let replyTargetBeforeSubmit {
                replyingToComment = replyTargetBeforeSubmit
            }
            if isCancellation(error) { return }
            errorMessage = error.localizedDescription
        }
    }

    private func deletePost() async {
        do {
            try await postEditor.delete(postId: post.id)
            dismiss()
        } catch {
            if isCancellation(error) { return }
            errorMessage = error.localizedDescription
        }
    }

    private func deleteComment(_ comment: ForumCommentItem) async {
        do {
            try await service.deleteComment(commentId: comment.id, postId: post.id)
            deletingComment = nil
            if replyingToComment?.id == comment.id {
                replyingToComment = nil
            }
            await reloadData()
            errorMessage = nil
        } catch {
            if isCancellation(error) { return }
            errorMessage = error.localizedDescription
        }
    }

    private func isCancellation(_ error: Error) -> Bool {
        error.isCancellationLike
    }

    private func copyShareLink() {
        PostShareService.copyLink(for: post.sharePayload)
        ShareFeedbackPresenter.show(L10n.tr("Link copied", "链接已复制")) {
            shareActionToastMessage = $0
        }
    }

    private func dismissCommentKeyboard() {
        isCommentFieldFocused = false
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    private func handleTapOutsideComposer() {
        guard !suppressOutsideComposerDismissForCurrentTap else { return }
        if replyingToComment != nil {
            consumeTapToCancelActiveReply()
        } else {
            dismissCommentKeyboard()
        }
    }

    private func markCurrentTapAsCommentInteraction(suppressOutsideDismiss: Bool) {
        guard suppressOutsideDismiss else { return }
        suppressOutsideComposerDismissForCurrentTap = true
        DispatchQueue.main.async {
            suppressOutsideComposerDismissForCurrentTap = false
        }
    }

    private func commentScrollId(for commentId: UUID) -> String {
        "forum-comment-\(commentId.uuidString.lowercased())"
    }

    private func scrollToInitialComment(using proxy: ScrollViewProxy) async {
        guard let initialCommentID,
              comments.contains(where: { $0.id == initialCommentID })
        else { return }

        let rootID = rootCommentId(for: initialCommentID)
        collapsedRootCommentIds.remove(rootID)
        expandedRootCommentIds.insert(rootID)
        await Task.yield()
        try? await Task.sleep(nanoseconds: 80_000_000)
        withAnimation(.easeInOut(duration: 0.25)) {
            proxy.scrollTo(
                commentScrollId(for: initialCommentID),
                anchor: .center
            )
        }
    }

    private func consumeTapToCancelActiveReply() {
        suppressReplyTargetActivationForCurrentTap = true
        clearReplyTargetAndRestoreViewport(dismissKeyboard: true)
        DispatchQueue.main.async {
            suppressReplyTargetActivationForCurrentTap = false
        }
    }

    private func clearReplyTargetAndRestoreViewport(dismissKeyboard: Bool = false) {
        replyingToComment = nil
        if dismissKeyboard {
            dismissCommentKeyboard()
        }
    }

}

#Preview {
    NavigationStack {
        ForumDetailView(
            post: ForumPostItem(
                id: UUID(),
                authorId: UUID(),
                authorAvatar: nil,
                title: "How to find good study spots on campus?",
                content: "Need recommendations for late-night study.",
                boardID: UUID(),
                boardName: "Academic",
                boardIcon: "graduationcap.fill",
                boardAllowsAnonymous: true,
                authorName: "Alice",
                isAnonymous: false,
                isAuthorOfficial: false,
                timeAgo: "1h ago",
                createdAt: Date(),
                likes: 4,
                comments: 2,
                views: 80,
                isLiked: false,
                isPinned: false,
                imageUrls: [],
                hasImage: false
            )
        )
    }
}
