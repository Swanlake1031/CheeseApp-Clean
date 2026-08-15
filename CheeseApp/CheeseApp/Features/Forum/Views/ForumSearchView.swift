import SwiftUI

struct ForumSearchView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var authService: AuthService
    @StateObject private var service = ForumService.shared

    let initialBoard: ForumBoard?
    @State private var query = ""
    @State private var results: [ForumPostItem] = []
    @State private var selectedPost: ForumPostItem?
    @State private var isLoading = false
    @State private var isLoadingMore = false
    @State private var hasMore = false
    @State private var errorMessage: String?
    @State private var pageErrorMessage: String?
    @State private var cursor: ForumSearchPageCursor?
    @State private var activeRequestID: UUID?
    @State private var isSearchFocused = false

    init(initialBoard: ForumBoard? = nil) {
        self.initialBoard = initialBoard
    }

    var body: some View {
        ZStack {
            AppColors.pageBackground.ignoresSafeArea()
            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    Button(action: { dismiss() }) { PostToolbarIconCircle(icon: "chevron.left") }
                        .buttonStyle(.plain)
                    HStack(spacing: 9) {
                        Image(systemName: "magnifyingglass").foregroundStyle(AppColors.textMuted)
                        CheeseSearchTextField(
                            text: $query,
                            placeholder: initialBoard.map {
                                L10n.tr("Search \($0.name)", "搜索\($0.name)")
                            } ?? L10n.tr("Search posts and boards", "搜索帖子和板块"),
                            isFirstResponder: $isSearchFocused
                        )
                        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 22)
                        if !query.isEmpty {
                            Button(action: { query = "" }) {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(AppColors.textMuted)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 13)
                    .frame(height: 44)
                    .background(AppColors.cardBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)

                content
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .navigationDestination(item: $selectedPost) { ForumDetailView(post: $0) }
        .task { isSearchFocused = true }
        .task(id: query) {
            do {
                try await Task.sleep(nanoseconds: 280_000_000)
                try Task.checkCancellation()
                await search()
            } catch {}
        }
        .enableSwipeBackGesture()
    }

    @ViewBuilder
    private var content: some View {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            ContentUnavailableView(
                L10n.tr("Search Forum", "搜索论坛"),
                systemImage: "magnifyingglass",
                description: Text(L10n.tr(
                    "Search post titles, content, or board names.",
                    "可搜索帖子标题、正文或板块名称。"
                ))
            )
        } else if isLoading {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let errorMessage {
            ErrorView(errorMessage) { Task { await search() } }
        } else if results.isEmpty {
            ContentUnavailableView.search(text: trimmed)
        } else {
            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: 0) {
                    ForEach(results, id: \.id) { (post: ForumPostItem) in
                        Button(action: { selectedPost = post }) {
                            VStack(alignment: .leading, spacing: 7) {
                                Label(post.boardName, systemImage: post.boardIcon)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(AppColors.accentStrong)
                                Text(post.title)
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(AppColors.textPrimary)
                                    .lineLimit(2)
                                Text(post.content)
                                    .font(.system(size: 13))
                                    .foregroundStyle(AppColors.textMuted)
                                    .lineLimit(2)
                                HStack {
                                    Text(post.authorName)
                                    Spacer()
                                    Text(post.timeAgo)
                                }
                                .font(.system(size: 11))
                                .foregroundStyle(AppColors.textMuted)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 14)
                            .overlay(alignment: .bottom) {
                                Divider()
                                    .overlay(AppColors.divider)
                            }
                        }
                        .buttonStyle(.plain)
                    }

                    if isLoadingMore {
                        ProgressView()
                            .padding(.vertical, 8)
                    } else if hasMore {
                        Button(L10n.tr("Load more", "加载更多")) {
                            Task { await loadMore() }
                        }
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.vertical, 8)
                    }

                    if let pageErrorMessage {
                        Button("\(pageErrorMessage) · \(L10n.tr("Retry", "重试"))") {
                            Task { await loadMore() }
                        }
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
        }
    }

    private func search() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            activeRequestID = nil
            results = []
            cursor = nil
            hasMore = false
            errorMessage = nil
            pageErrorMessage = nil
            return
        }
        let requestID = UUID()
        activeRequestID = requestID
        isLoading = true
        errorMessage = nil
        pageErrorMessage = nil
        defer {
            if activeRequestID == requestID {
                isLoading = false
            }
        }
        do {
            let page = try await service.fetchSearchPage(
                query: trimmed,
                boardID: initialBoard?.id,
                after: nil
            )
            guard activeRequestID == requestID,
                  query.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed
            else { return }
            results = page.items
            cursor = page.cursor
            hasMore = page.hasMore
        } catch {
            guard !error.isCancellationLike else { return }
            guard activeRequestID == requestID else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func loadMore() async {
        guard hasMore, !isLoading, !isLoadingMore, let cursor else { return }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let requestID = activeRequestID
        isLoadingMore = true
        pageErrorMessage = nil
        defer { isLoadingMore = false }

        do {
            let page = try await service.fetchSearchPage(
                query: trimmed,
                boardID: initialBoard?.id,
                after: cursor
            )
            guard activeRequestID == requestID,
                  query.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed
            else { return }
            let existingIDs = Set(results.map(\.id))
            results.append(contentsOf: page.items.filter { !existingIDs.contains($0.id) })
            self.cursor = page.cursor
            hasMore = page.hasMore
        } catch {
            guard activeRequestID == requestID else { return }
            if !error.isCancellationLike {
                pageErrorMessage = error.localizedDescription
            }
        }
    }
}
