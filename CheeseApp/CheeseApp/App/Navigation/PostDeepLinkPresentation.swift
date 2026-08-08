//
//  PostDeepLinkPresentation.swift
//  CheeseApp
//
//  App-level deep-link coordination and feature destination composition.
//

import SwiftUI

@MainActor
final class PostDeepLinkCoordinator: ObservableObject {
    @Published private(set) var activeRoute: PostDeepLinkRoute?
    @Published var alertMessage: String?

    private var pendingRoute: PostDeepLinkRoute?
    private var lastHandledRouteID: String?
    private var lastHandledAt: Date = .distantPast
    private let duplicateSuppressionWindow: TimeInterval = 1.0

    func handleIncomingURL(_ url: URL, canPresentProtectedContent: Bool) {
        guard let parseResult = PostDeepLinkRoute.parse(url) else { return }

        switch parseResult {
        case .success(let route):
            guard !shouldSuppress(route) else { return }
            open(route, canPresentProtectedContent: canPresentProtectedContent)
        case .failure(let error):
            alertMessage = error.localizedDescription
        }
    }

    func activatePendingRouteIfPossible(canPresentProtectedContent: Bool) {
        guard canPresentProtectedContent, let pendingRoute else { return }
        self.pendingRoute = nil
        present(pendingRoute)
    }

    func openRoute(_ route: PostDeepLinkRoute, canPresentProtectedContent: Bool) {
        guard !shouldSuppress(route) else { return }
        open(route, canPresentProtectedContent: canPresentProtectedContent)
    }

    func dismissActiveRoute() {
        activeRoute = nil
    }

    private func open(_ route: PostDeepLinkRoute, canPresentProtectedContent: Bool) {
        guard canPresentProtectedContent else {
            guard pendingRoute?.id != route.id else { return }
            pendingRoute = route
            return
        }

        pendingRoute = nil
        present(route)
    }

    private func present(_ route: PostDeepLinkRoute) {
        markHandled(route)
        guard activeRoute?.id != route.id else { return }
        activeRoute = route
    }

    private func shouldSuppress(_ route: PostDeepLinkRoute) -> Bool {
        guard lastHandledRouteID == route.id else { return false }
        return Date().timeIntervalSince(lastHandledAt) < duplicateSuppressionWindow
    }

    private func markHandled(_ route: PostDeepLinkRoute) {
        lastHandledRouteID = route.id
        lastHandledAt = Date()
    }
}

private enum DeepLinkedPostDestination {
    case secondhand(SecondhandItem)
    case forum(ForumPostItem)
}

private enum DeepLinkedPostLoadState {
    case idle
    case loading
    case loaded(DeepLinkedPostDestination)
    case unavailable(String)
    case failed(String)
}

@MainActor
private final class DeepLinkedPostLoader: ObservableObject {
    @Published private(set) var state: DeepLinkedPostLoadState = .idle

    let route: PostDeepLinkRoute

    init(route: PostDeepLinkRoute) {
        self.route = route
    }

    func loadIfNeeded() async {
        guard case .idle = state else { return }
        await load()
    }

    func load() async {
        state = .loading

        do {
            let destination: DeepLinkedPostDestination

            switch route.kind {
            case .secondhand:
                destination = .secondhand(try await SecondhandService.shared.fetchItem(postId: route.postId))
            case .forum:
                destination = .forum(try await ForumService.shared.fetchPost(postId: route.postId))
            }

            state = .loaded(destination)
        } catch {
            let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            if Self.isUnavailable(error) {
                state = .unavailable(message.isEmpty ? defaultUnavailableMessage : message)
            } else {
                state = .failed(message.isEmpty ? defaultFailureMessage : message)
            }
        }
    }

    private static func isUnavailable(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.code == 404 { return true }

        let text = nsError.localizedDescription.lowercased()
        return text.contains("not available")
            || text.contains("unavailable")
            || text.contains("not found")
            || text.contains("当前不可用")
            || text.contains("不存在")
            || text.contains("已下架")
            || text.contains("已过期")
    }

    private var defaultUnavailableMessage: String {
        L10n.tr(
            "This post is no longer available.",
            "这篇帖子已经不可用了。"
        )
    }

    private var defaultFailureMessage: String {
        L10n.tr(
            "We couldn't open this post right now. Please try again.",
            "暂时无法打开这篇帖子，请稍后再试。"
        )
    }
}

struct DeepLinkedPostPresenterView: View {
    let route: PostDeepLinkRoute

    @Environment(\.dismiss) private var dismiss
    @StateObject private var loader: DeepLinkedPostLoader

    init(route: PostDeepLinkRoute) {
        self.route = route
        _loader = StateObject(wrappedValue: DeepLinkedPostLoader(route: route))
    }

    var body: some View {
        Group {
            switch loader.state {
            case .idle, .loading:
                loadingView

            case .loaded(let destination):
                destinationView(for: destination)

            case .unavailable(let message):
                fallbackView(
                    icon: "tray.fill",
                    title: L10n.tr("Post unavailable", "帖子不可用"),
                    message: message,
                    showsRetry: false
                )

            case .failed(let message):
                fallbackView(
                    icon: "exclamationmark.triangle.fill",
                    title: L10n.tr("Unable to open post", "无法打开帖子"),
                    message: message,
                    showsRetry: true
                )
            }
        }
        .enableSwipeBackGesture()
        .task(id: route.id) {
            await loader.loadIfNeeded()
        }
    }

    @ViewBuilder
    private func destinationView(for destination: DeepLinkedPostDestination) -> some View {
        switch destination {
        case .secondhand(let item):
            SecondhandDetailView(item: item)
        case .forum(let post):
            ForumDetailView(post: post)
        }
    }

    private var loadingView: some View {
        ZStack {
            AppColors.pageBackground
                .ignoresSafeArea()

            ProgressView(L10n.tr("Opening post...", "正在打开帖子..."))
                .tint(AppColors.textPrimary)
        }
    }

    private func fallbackView(
        icon: String,
        title: String,
        message: String,
        showsRetry: Bool
    ) -> some View {
        ZStack {
            AppColors.pageBackground
                .ignoresSafeArea()

            VStack(spacing: 18) {
                Image(systemName: icon)
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(AppColors.textMuted)

                VStack(spacing: 8) {
                    Text(title)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(AppColors.textPrimary)

                    Text(message)
                        .font(.system(size: 14))
                        .foregroundStyle(AppColors.textMuted)
                        .multilineTextAlignment(.center)
                        .lineSpacing(2)
                }

                HStack(spacing: 12) {
                    Button {
                        dismiss()
                    } label: {
                        Text(L10n.tr("Close", "关闭"))
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(AppColors.textPrimary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Color.black.opacity(0.06))
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)

                    if showsRetry {
                        Button {
                            Task { await loader.load() }
                        } label: {
                            Text(L10n.tr("Retry", "重试"))
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(AppColors.textPrimary)
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 24)
        }
    }
}
