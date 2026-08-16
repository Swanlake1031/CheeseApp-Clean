import SwiftUI
import UIKit

private struct ProfileActivityPagerScrollViewConfiguration: UIViewRepresentable {
    func makeUIView(context: Context) -> ProfileActivityPagerConfigurationView {
        let view = ProfileActivityPagerConfigurationView()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(
        _ uiView: ProfileActivityPagerConfigurationView,
        context: Context
    ) {
        uiView.configureEnclosingScrollView()
    }
}

final class ProfileActivityPagerConfigurationView: UIView {
    private weak var configuredScrollView: UIScrollView?

    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        configureEnclosingScrollView()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        configureEnclosingScrollView()
    }

    func configureEnclosingScrollView() {
        var ancestor = superview

        while let currentView = ancestor {
            if let scrollView = currentView as? UIScrollView {
                guard configuredScrollView !== scrollView
                    || scrollView.bounces
                    || scrollView.alwaysBounceHorizontal
                    || !scrollView.isDirectionalLockEnabled
                else { return }

                // The picker sits outside this horizontal pager, so allowing
                // the pager to rubber-band makes the two regions visibly
                // separate after a Menu dismissal drag. Keep bounce disabled
                // only for this pager; the profile's vertical ScrollView keeps
                // its normal system behavior.
                scrollView.bounces = false
                scrollView.alwaysBounceHorizontal = false
                scrollView.isDirectionalLockEnabled = true
                configuredScrollView = scrollView
                return
            }

            ancestor = currentView.superview
        }
    }
}

private struct ProfileActivityPageHeightPreferenceKey: PreferenceKey {
    static var defaultValue: [ProfileActivityKind: CGFloat] = [:]

    static func reduce(
        value: inout [ProfileActivityKind: CGFloat],
        nextValue: () -> [ProfileActivityKind: CGFloat]
    ) {
        value.merge(nextValue(), uniquingKeysWith: { _, newValue in newValue })
    }
}

enum ProfileActivityPostAction {
    case makePrivate
    case edit
    case share
    case delete
}

private struct NativeProfilePostMenuButton: UIViewRepresentable {
    let isPrivate: Bool
    let isDisabled: Bool
    let onAction: (ProfileActivityPostAction) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onAction: onAction)
    }

    func makeUIView(context: Context) -> ProfilePostMenuButton {
        let button = ProfilePostMenuButton(type: .system)
        button.lifecycleDelegate = context.coordinator
        button.showsMenuAsPrimaryAction = true
        button.changesSelectionAsPrimaryAction = false
        button.backgroundColor = .clear
        button.isOpaque = false
        button.configuration = buttonConfiguration
        button.menu = makeMenu(coordinator: context.coordinator)
        button.accessibilityLabel = "帖子操作"
        return button
    }

    func updateUIView(_ button: ProfilePostMenuButton, context: Context) {
        context.coordinator.onAction = onAction
        button.isEnabled = !isDisabled
        button.configuration = buttonConfiguration
        button.menu = makeMenu(coordinator: context.coordinator)
    }

    private var buttonConfiguration: UIButton.Configuration {
        var configuration = UIButton.Configuration.plain()
        configuration.contentInsets = .zero
        configuration.background.backgroundColor = .clear
        return configuration
    }

    private func makeMenu(coordinator: Coordinator) -> UIMenu {
        var children: [UIMenuElement] = []

        if !isPrivate {
            children.append(
                action(
                    title: "私密",
                    systemImage: "lock.fill",
                    value: .makePrivate,
                    coordinator: coordinator
                )
            )
        }

        children.append(
            action(
                title: "编辑",
                systemImage: "square.and.pencil",
                value: .edit,
                coordinator: coordinator
            )
        )

        if !isPrivate {
            children.append(
                action(
                    title: "分享",
                    systemImage: "square.and.arrow.up",
                    value: .share,
                    coordinator: coordinator
                )
            )
        }

        let delete = UIAction(
            title: "删除",
            image: UIImage(systemName: "trash"),
            attributes: .destructive
        ) { _ in
            coordinator.request(.delete)
        }
        children.append(delete)

        return UIMenu(children: children)
    }

    private func action(
        title: String,
        systemImage: String,
        value: ProfileActivityPostAction,
        coordinator: Coordinator
    ) -> UIAction {
        UIAction(title: title, image: UIImage(systemName: systemImage)) { _ in
            coordinator.request(value)
        }
    }

    final class Coordinator: NSObject, ProfilePostMenuButtonLifecycleDelegate {
        var onAction: (ProfileActivityPostAction) -> Void
        private var pendingAction: ProfileActivityPostAction?

        init(onAction: @escaping (ProfileActivityPostAction) -> Void) {
            self.onAction = onAction
        }

        func request(_ action: ProfileActivityPostAction) {
            if case .delete = action {
                // Match ForumDetailView: request the system confirmation as
                // soon as the destructive menu item is selected. UIKit will
                // coordinate the menu dismissal and alert presentation.
                pendingAction = nil
                onAction(action)
            } else {
                pendingAction = action
            }
        }

        func menuDidFinishDismissing() {
            let action = pendingAction
            pendingAction = nil
            if let action {
                onAction(action)
            }
        }
    }
}

private protocol ProfilePostMenuButtonLifecycleDelegate: AnyObject {
    func menuDidFinishDismissing()
}

private final class ProfilePostMenuButton: UIButton {
    weak var lifecycleDelegate: ProfilePostMenuButtonLifecycleDelegate?

    override func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        willEndFor configuration: UIContextMenuConfiguration,
        animator: (any UIContextMenuInteractionAnimating)?
    ) {
        super.contextMenuInteraction(
            interaction,
            willEndFor: configuration,
            animator: animator
        )
        if let animator {
            animator.addCompletion { [weak self] in
                self?.lifecycleDelegate?.menuDidFinishDismissing()
            }
        } else {
            lifecycleDelegate?.menuDidFinishDismissing()
        }
    }
}

struct ProfileActivityView: View {
    @EnvironmentObject private var authService: AuthService
    @StateObject private var userPostsService = UserPostsService()
    @State private var selectedKind: ProfileActivityKind
    @State private var selectedPublishedKind: PostKind?
    @State private var refreshGeneration = 0
    @State private var destination: ProfileActivityDestination?
    @State private var editingPost: UserPostSummary?
    @State private var openingPostID: UUID?
    @State private var openingRequestID: UUID?
    @State private var editingPostID: UUID?
    @State private var editingRequestID: UUID?
    @State private var updatingPrivacyPostID: UUID?
    @State private var deletingPostID: UUID?
    @State private var pendingDeleteItem: ProfileActivityItem?
    @State private var sharingPost: PostSharePayload?
    @State private var shareFeedbackMessage: String?
    @State private var navigationErrorMessage: String?
    @State private var embeddedPageHeights: [ProfileActivityKind: CGFloat] = [:]
    private let showsKindPicker: Bool
    private let isEmbedded: Bool
    private let publishedVisibility: PublishedPostVisibility
    private let pageTitle: String?
    private let externalRefreshGeneration: Int
    private let minimumEmbeddedPagerHeight: CGFloat
    private let onPresentShare: ((PostSharePayload) -> Void)?
    private let onPresentEditor: ((UserPostSummary) -> Void)?

    init(
        initialKind: ProfileActivityKind = .published,
        showsKindPicker: Bool = true,
        isEmbedded: Bool = false,
        publishedVisibility: PublishedPostVisibility = .visible,
        pageTitle: String? = nil,
        externalRefreshGeneration: Int = 0,
        minimumEmbeddedPagerHeight: CGFloat = 220,
        onPresentShare: ((PostSharePayload) -> Void)? = nil,
        onPresentEditor: ((UserPostSummary) -> Void)? = nil
    ) {
        _selectedKind = State(initialValue: initialKind)
        _selectedPublishedKind = State(initialValue: nil)
        self.showsKindPicker = showsKindPicker
        self.isEmbedded = isEmbedded
        self.publishedVisibility = publishedVisibility
        self.pageTitle = pageTitle
        self.externalRefreshGeneration = externalRefreshGeneration
        self.minimumEmbeddedPagerHeight = minimumEmbeddedPagerHeight
        self.onPresentShare = onPresentShare
        self.onPresentEditor = onPresentEditor
    }

    var body: some View {
        ZStack {
            if !isEmbedded {
                AppColors.pageBackground.ignoresSafeArea()
            }

            if isEmbedded {
                embeddedContent
            } else {
                fullPageContent
            }
        }
        .if(!isEmbedded) { content in
            content.cheesePageTopBar(
                title: pageTitle ?? (showsKindPicker ? "我的活动" : selectedKind.title)
            )
        }
        .navigationDestination(item: $destination) { target in
            ProfileActivityPostDetailRouter(destination: target)
        }
        .navigationDestination(item: $editingPost) { post in
            EditPostSheet(post: post) { payload in
                try await userPostsService.update(payload: payload)
                refreshGeneration &+= 1
            }
        }
        .cheesePostSharePanel(item: $sharingPost) { message in
            ShareFeedbackPresenter.show(message) {
                shareFeedbackMessage = $0
            }
        }
        .onChange(of: destination) { previous, current in
            guard previous != nil, current == nil else { return }
            refreshGeneration &+= 1
        }
        .onChange(of: authService.currentUser?.id) { _, _ in
            cancelPendingPostActions()
            editingPost = nil
            pendingDeleteItem = nil
        }
        .alert(
            L10n.tr("Delete this post?", "确定删除这篇贴文？"),
            isPresented: Binding(
                get: { pendingDeleteItem != nil },
                set: { if !$0 { pendingDeleteItem = nil } }
            ),
            presenting: pendingDeleteItem
        ) { item in
            Button(L10n.tr("Cancel", "取消"), role: .cancel) {
                pendingDeleteItem = nil
            }
            Button(L10n.tr("Delete", "删除"), role: .destructive) {
                pendingDeleteItem = nil
                Task { await deletePost(item) }
            }
        } message: { _ in
            Text(L10n.tr("This action cannot be undone.", "删除后无法复原。"))
        }
        .alert(
            "操作失败",
            isPresented: Binding(
                get: { navigationErrorMessage != nil },
                set: { if !$0 { navigationErrorMessage = nil } }
            )
        ) {
            Button("确定", role: .cancel) {}
        } message: {
            Text(navigationErrorMessage ?? "")
        }
        .shareFeedbackToast(message: $shareFeedbackMessage)
    }

    private var fullPageContent: some View {
        VStack(spacing: 0) {
            if showsKindPicker {
                activityPicker
            }
            TabView(selection: selectedKindBinding) {
                ForEach(activityKinds) { kind in
                    activityPage(for: kind, embedsInParentScroll: false)
                        .tag(kind)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var embeddedContent: some View {
        VStack(spacing: 0) {
            embeddedActivityPicker

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 0) {
                    ForEach(ProfileActivityKind.allCases) { kind in
                        activityPage(for: kind, embedsInParentScroll: true)
                            .fixedSize(horizontal: false, vertical: true)
                            .containerRelativeFrame(.horizontal)
                            .background {
                                // Keep intrinsic height measurement separate
                                // from the full-height pager hit region.
                                GeometryReader { proxy in
                                    Color.clear.preference(
                                        key: ProfileActivityPageHeightPreferenceKey.self,
                                        value: [kind: proxy.size.height]
                                    )
                                }
                            }
                            .frame(
                                minHeight: embeddedPagerHeight,
                                alignment: .top
                            )
                            .background(AppColors.pageBackground)
                            .contentShape(Rectangle())
                            .id(kind)
                    }
                }
                .scrollTargetLayout()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(ProfileActivityPagerScrollViewConfiguration())
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: embeddedSelectedKindBinding)
            .frame(height: embeddedPagerHeight, alignment: .top)
            .background(AppColors.pageBackground)
            .clipped()
            .contentShape(Rectangle())
            .onPreferenceChange(ProfileActivityPageHeightPreferenceKey.self) { heights in
                for (kind, height) in heights where height > 0 {
                    guard abs((embeddedPageHeights[kind] ?? 0) - height) > 0.5 else {
                        continue
                    }
                    embeddedPageHeights[kind] = height
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func activityPage(
        for kind: ProfileActivityKind,
        embedsInParentScroll: Bool
    ) -> some View {
        ProfileActivityPageView(
            kind: kind,
            isSelected: selectedKind == kind,
            userID: authService.currentUser?.id,
            refreshGeneration: refreshGeneration &+ externalRefreshGeneration,
            openingPostID: openingPostID,
            editingPostID: editingPostID,
            updatingPrivacyPostID: updatingPrivacyPostID,
            deletingPostID: deletingPostID,
            publishedPostKind: selectedPublishedKind,
            publishedVisibility: publishedVisibility,
            embedsInParentScroll: embedsInParentScroll,
            onOpen: { item in
                Task { await openPost(item) }
            },
            onSetPrivacy: { item, hidden in
                Task { await setPostPrivacy(item, hidden: hidden) }
            },
            onShare: share,
            onPerformAction: { action, item in
                performPostAction(action, for: item)
            },
            onSelectPublishedKind: { kind in
                selectPublishedPostKind(kind)
            }
        )
    }

    private var activityPicker: some View {
        HStack(spacing: 8) {
            ForEach(ProfileActivityKind.allCases) { kind in
                Button {
                    cancelPendingPostActions()
                    withAnimation(.easeInOut(duration: 0.22)) {
                        selectedKind = kind
                    }
                } label: {
                    Text(kind.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(
                            selectedKind == kind
                                ? Color.black
                                : AppColors.textMuted
                        )
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(
                            selectedKind == kind
                                ? AppColors.accent
                                : Color.white
                        )
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var embeddedActivityPicker: some View {
        HStack(spacing: 0) {
            ForEach(ProfileActivityKind.allCases) { kind in
                Button {
                    selectActivityKind(kind)
                } label: {
                    VStack(spacing: 9) {
                        Text(kind.title)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(
                                selectedKind == kind
                                    ? AppColors.textPrimary
                                    : AppColors.textMuted
                            )

                        Capsule()
                            .fill(
                                selectedKind == kind
                                    ? AppColors.accentStrong
                                    : Color.clear
                            )
                            .frame(width: 28, height: 3)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 14)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func selectActivityKind(_ kind: ProfileActivityKind) {
        guard selectedKind != kind else { return }
        cancelPendingPostActions()
        withAnimation(.easeInOut(duration: 0.24)) {
            selectedKind = kind
        }
    }

    private func selectPublishedPostKind(_ kind: PostKind?) {
        guard selectedPublishedKind != kind else { return }
        cancelPendingPostActions()
        withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
            selectedPublishedKind = kind
        }
    }

    private var embeddedSelectedKindBinding: Binding<ProfileActivityKind?> {
        Binding(
            get: { selectedKind },
            set: { kind in
                guard let kind, kind != selectedKind else { return }
                cancelPendingPostActions()
                selectedKind = kind
            }
        )
    }

    private var embeddedPagerHeight: CGFloat {
        max(
            embeddedPageHeights.values.max() ?? minimumEmbeddedPagerHeight,
            minimumEmbeddedPagerHeight
        )
    }

    private var activityKinds: [ProfileActivityKind] {
        showsKindPicker ? ProfileActivityKind.allCases : [selectedKind]
    }

    private var selectedKindBinding: Binding<ProfileActivityKind> {
        Binding(
            get: { selectedKind },
            set: { kind in
                guard selectedKind != kind else { return }
                cancelPendingPostActions()
                selectedKind = kind
            }
        )
    }

    @MainActor
    private func openPost(_ item: ProfileActivityItem) async {
        guard openingPostID == nil,
              editingPostID == nil,
              let kind = item.kind
        else { return }
        let requestID = UUID()
        openingPostID = item.postID
        openingRequestID = requestID
        navigationErrorMessage = nil
        defer {
            if openingRequestID == requestID {
                cancelPendingPostOpen()
            }
        }

        do {
            let resolvedDestination: ProfileActivityDestination
            switch kind {
            case .secondhand:
                resolvedDestination = .secondhand(
                    try await SecondhandService.shared.fetchItem(
                        postId: item.postID
                    )
                )
            case .forum:
                resolvedDestination = .forum(
                    try await ForumService.shared.fetchPost(
                        postId: item.postID
                    ),
                    commentID: item.commentID
                )
            }
            guard openingRequestID == requestID else { return }
            destination = resolvedDestination
        } catch {
            guard openingRequestID == requestID else { return }
            if error.isCancellationLike { return }
            navigationErrorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func preparePostForEditing(
        _ item: ProfileActivityItem,
        activityKind: ProfileActivityKind
    ) async {
        guard activityKind == .published || activityKind == .privateContent,
              openingPostID == nil,
              editingPostID == nil,
              let userID = authService.currentUser?.id,
              let kind = item.kind
        else { return }

        let requestID = UUID()
        editingPostID = item.postID
        editingRequestID = requestID
        navigationErrorMessage = nil
        defer {
            if editingRequestID == requestID {
                cancelPendingPostEdit()
            }
        }

        do {
            async let privacy = userPostsService.fetchPostPrivacy(
                postId: item.postID,
                userId: userID
            )

            var resolvedPost: UserPostSummary
            switch kind {
            case .secondhand:
                resolvedPost = try await SecondhandService.shared.fetchItem(
                    postId: item.postID
                ).editableSummary
            case .forum:
                resolvedPost = try await ForumService.shared.fetchPost(
                    postId: item.postID
                ).editableSummary
            }
            resolvedPost.isPrivate = try await privacy

            guard editingRequestID == requestID,
                  authService.currentUser?.id == userID
            else { return }
            if let onPresentEditor {
                onPresentEditor(resolvedPost)
            } else {
                editingPost = resolvedPost
            }
        } catch {
            guard editingRequestID == requestID else { return }
            if error.isCancellationLike { return }
            navigationErrorMessage = error.localizedDescription
        }
    }

    private func cancelPendingPostOpen() {
        openingPostID = nil
        openingRequestID = nil
    }

    private func cancelPendingPostEdit() {
        editingPostID = nil
        editingRequestID = nil
    }

    private func cancelPendingPostActions() {
        cancelPendingPostOpen()
        cancelPendingPostEdit()
    }

    @MainActor
    private func setPostPrivacy(
        _ item: ProfileActivityItem,
        hidden: Bool
    ) async {
        guard updatingPrivacyPostID == nil,
              deletingPostID == nil
        else { return }
        updatingPrivacyPostID = item.postID
        defer { updatingPrivacyPostID = nil }

        do {
            try await userPostsService.setPostHidden(
                postId: item.postID,
                hidden: hidden,
                kind: item.kind,
                authorId: authService.currentUser?.id
            )
            refreshGeneration &+= 1
        } catch {
            if error.isCancellationLike { return }
            navigationErrorMessage = error.localizedDescription
        }
    }

    private func share(_ item: ProfileActivityItem) {
        guard let kind = item.kind else { return }
        let payload = PostSharePayload(
            kind: kind,
            postId: item.postID,
            title: item.postTitle,
            subtitle: kind.displayName,
            summary: item.postSummary,
            imageURL: item.coverImage.flatMap(URL.init(string:))
        )
        if let onPresentShare {
            onPresentShare(payload)
        } else {
            sharingPost = payload
        }
    }

    private func performPostAction(
        _ action: ProfileActivityPostAction,
        for item: ProfileActivityItem
    ) {
        switch action {
        case .makePrivate:
            Task { await setPostPrivacy(item, hidden: true) }
        case .edit:
            Task {
                await preparePostForEditing(
                    item,
                    activityKind: .published
                )
            }
        case .share:
            share(item)
        case .delete:
            pendingDeleteItem = item
        }
    }

    @MainActor
    private func deletePost(_ item: ProfileActivityItem) async {
        guard deletingPostID == nil,
              updatingPrivacyPostID == nil
        else { return }
        deletingPostID = item.postID
        defer {
            deletingPostID = nil
        }

        do {
            try await userPostsService.delete(postId: item.postID)
            refreshGeneration &+= 1
        } catch {
            if error.isCancellationLike { return }
            navigationErrorMessage = error.localizedDescription
        }
    }

}

private struct ProfileActivityPageView: View {
    let kind: ProfileActivityKind
    let isSelected: Bool
    let userID: UUID?
    let refreshGeneration: Int
    let openingPostID: UUID?
    let editingPostID: UUID?
    let updatingPrivacyPostID: UUID?
    let deletingPostID: UUID?
    let publishedPostKind: PostKind?
    let publishedVisibility: PublishedPostVisibility
    let embedsInParentScroll: Bool
    let onOpen: (ProfileActivityItem) -> Void
    let onSetPrivacy: (ProfileActivityItem, Bool) -> Void
    let onShare: (ProfileActivityItem) -> Void
    let onPerformAction: (ProfileActivityPostAction, ProfileActivityItem) -> Void
    let onSelectPublishedKind: (PostKind?) -> Void

    @StateObject private var service: ProfileActivityService
    @StateObject private var interactionStore = PostInteractionStore.shared
    @State private var appliedRefreshGeneration = 0

    init(
        kind: ProfileActivityKind,
        isSelected: Bool,
        userID: UUID?,
        refreshGeneration: Int,
        openingPostID: UUID?,
        editingPostID: UUID?,
        updatingPrivacyPostID: UUID?,
        deletingPostID: UUID?,
        publishedPostKind: PostKind?,
        publishedVisibility: PublishedPostVisibility,
        embedsInParentScroll: Bool,
        onOpen: @escaping (ProfileActivityItem) -> Void,
        onSetPrivacy: @escaping (ProfileActivityItem, Bool) -> Void,
        onShare: @escaping (ProfileActivityItem) -> Void,
        onPerformAction: @escaping (ProfileActivityPostAction, ProfileActivityItem) -> Void,
        onSelectPublishedKind: @escaping (PostKind?) -> Void
    ) {
        self.kind = kind
        self.isSelected = isSelected
        self.userID = userID
        self.refreshGeneration = refreshGeneration
        self.openingPostID = openingPostID
        self.editingPostID = editingPostID
        self.updatingPrivacyPostID = updatingPrivacyPostID
        self.deletingPostID = deletingPostID
        self.publishedPostKind = publishedPostKind
        self.publishedVisibility = publishedVisibility
        self.embedsInParentScroll = embedsInParentScroll
        self.onOpen = onOpen
        self.onSetPrivacy = onSetPrivacy
        self.onShare = onShare
        self.onPerformAction = onPerformAction
        self.onSelectPublishedKind = onSelectPublishedKind
        let initialServiceKind: ProfileActivityKind = kind == .privateContent
            ? .published
            : kind
        let initialVisibility: PublishedPostVisibility = kind == .privateContent
            ? .hidden
            : publishedVisibility
        _service = StateObject(
            wrappedValue: ProfileActivityService(
                initialKind: initialServiceKind,
                initialPublishedVisibility: initialVisibility
            )
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            if isPublishedManagement {
                if kind == .published && servicePublishedVisibility == .visible {
                    completedTransactionsEntry
                        .padding(.horizontal, embedsInParentScroll ? 12 : 16)
                        .padding(.top, 12)
                }

                ProfilePostKindFilterBar(
                    availableKinds: PostKind.allCases,
                    selectedKind: publishedPostKind,
                    onSelect: onSelectPublishedKind
                )
                .padding(.horizontal, embedsInParentScroll ? 12 : 16)
                .padding(.top, 12)
            }

            content
        }
            .frame(
                maxWidth: .infinity,
                maxHeight: embedsInParentScroll ? nil : .infinity
            )
            .task(id: loadTaskID) {
                service.activateAccount(userID)
                guard isSelected else { return }
                let shouldReconcileMembership = service.hasResolvedInitialLoad
                await service.select(
                    serviceKind,
                    publishedPostKind: publishedPostKind,
                    publishedVisibility: servicePublishedVisibility
                )
                if shouldReconcileMembership {
                    await service.loadInitial(force: true)
                }
            }
            .task(id: refreshGeneration) {
                guard isSelected,
                      refreshGeneration > appliedRefreshGeneration
                else { return }
                appliedRefreshGeneration = refreshGeneration
                service.activateAccount(userID)
                let shouldForceRefresh = service.hasResolvedInitialLoad
                await service.loadInitial(force: shouldForceRefresh)
            }
    }

    private var completedTransactionsEntry: some View {
        NavigationLink(destination: CompletedSecondhandTransactionsView()) {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AppColors.textPrimary)
                    .frame(width: 34, height: 34)
                    .background(AppColors.accent.opacity(0.22))
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text("已交易")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(AppColors.textPrimary)
                    Text("查看已完成的二手买入与卖出记录")
                        .font(.system(size: 11))
                        .foregroundStyle(AppColors.textMuted)
                }

                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AppColors.textMuted)
            }
            .padding(.vertical, 12)
            .overlay(alignment: .bottom) {
                Divider()
                    .overlay(AppColors.divider)
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var content: some View {
        switch service.loadState {
        case .unresolved, .initialLoading:
            activityStatePlaceholder {
                ProgressView()
            }
        case .empty:
            activityStatePlaceholder {
                VStack(spacing: 10) {
                    Image(systemName: emptyIcon)
                        .font(.system(size: 34))
                        .foregroundStyle(kind == .liked ? AppColors.likeActive : AppColors.textMuted)
                    Text(emptyTitle)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(AppColors.textMuted)
                }
            }
        case .error(let message):
            activityStatePlaceholder {
                ErrorView(message) {
                    Task { await service.loadInitial(force: true) }
                }
            }
        case .loaded:
            activityList
        }
    }

    private func activityStatePlaceholder<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack {
            if !embedsInParentScroll { Spacer() }
            content()
            if !embedsInParentScroll { Spacer() }
        }
        .frame(minHeight: embedsInParentScroll ? 220 : nil)
    }

    @ViewBuilder
    private var activityList: some View {
        if embedsInParentScroll {
            activityRows
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(
                    .bottom,
                    CheeseTabBarLayout.contentBottomClearance
                )
        } else {
            ScrollView(showsIndicators: false) {
                activityRows
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 90)
            }
            .refreshable {
                await service.loadInitial(force: true)
            }
        }
    }

    private var activityRows: some View {
        LazyVStack(spacing: 0) {
            ForEach(service.items) { item in
                ProfileActivityRow(
                    item: item,
                    activityKind: kind,
                    isOpening: openingPostID == item.postID,
                    isEditing: editingPostID == item.postID,
                    isUpdatingPrivacy: updatingPrivacyPostID == item.postID,
                    isDeleting: deletingPostID == item.postID,
                    isPrivate: servicePublishedVisibility == .hidden
                        || service.isPostPrivate(item.postID),
                    hiddenReason: service.hiddenReason(item.postID),
                    interactionState: interactionStore.state(
                        for: item.postID,
                        fallbackIsLiked: kind == .liked,
                        fallbackIsFavorited: kind == .favorited
                    ),
                    onOpen: { onOpen(item) },
                    onSetPrivacy: { hidden in
                        onSetPrivacy(item, hidden)
                    },
                    onShare: { onShare(item) },
                    onPerformAction: { action in
                        onPerformAction(action, item)
                    },
                    onToggleReaction: { currentlyActive in
                        Task {
                            await service.toggleReaction(
                                item,
                                currentlyActive: currentlyActive
                            )
                        }
                    }
                )
                .onAppear {
                    Task {
                        await service.loadNextPageIfNeeded(currentItem: item)
                    }
                }
                .transition(
                    .opacity.combined(
                        with: .scale(scale: 0.98, anchor: .top)
                    )
                )
            }

            if service.isLoadingNextPage {
                ProgressView().padding(.vertical, 12)
            } else if service.errorMessage != nil {
                Button("加载失败，点此重试") {
                    guard let last = service.items.last else { return }
                    Task {
                        await service.loadNextPageIfNeeded(currentItem: last)
                    }
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.red)
            }
        }
        .animation(
            .easeInOut(duration: 0.20),
            value: service.items.map(\.postID)
        )
    }

    private var loadTaskID: String {
        "\(userID?.uuidString ?? "signed-out"):\(kind.rawValue):\(publishedPostKind?.rawValue ?? "all"):\(servicePublishedVisibility.rawValue):\(isSelected)"
    }

    private var serviceKind: ProfileActivityKind {
        kind == .privateContent ? .published : kind
    }

    private var servicePublishedVisibility: PublishedPostVisibility {
        kind == .privateContent ? .hidden : publishedVisibility
    }

    private var isPublishedManagement: Bool {
        kind == .published || kind == .privateContent
    }

    private var emptyIcon: String {
        if servicePublishedVisibility == .hidden {
            return "lock"
        }
        switch kind {
        case .published: return "square.and.pencil"
        case .liked: return "heart"
        case .privateContent: return "lock.fill"
        case .favorited: return "star"
        }
    }

    private var emptyTitle: String {
        if servicePublishedVisibility == .hidden {
            return "暂无私密内容"
        }
        return kind.emptyTitle
    }
}

private struct ProfileActivityRow: View {
    let item: ProfileActivityItem
    let activityKind: ProfileActivityKind
    let isOpening: Bool
    let isEditing: Bool
    let isUpdatingPrivacy: Bool
    let isDeleting: Bool
    let isPrivate: Bool
    let hiddenReason: PostHiddenReason?
    let interactionState: PostInteractionState
    let onOpen: () -> Void
    let onSetPrivacy: (Bool) -> Void
    let onShare: () -> Void
    let onPerformAction: (ProfileActivityPostAction) -> Void
    let onToggleReaction: (Bool) -> Void

    var body: some View {
        VStack(spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    cover

                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(item.kind?.displayName ?? "内容")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(AppColors.link)
                            Spacer()
                            Text(
                                Formatters.formatCompactTimeAgo(
                                    item.activityCreatedAt,
                                    useJustNow: true
                                )
                            )
                            .font(.system(size: 10))
                            .foregroundStyle(AppColors.textMuted)
                        }

                        Text(item.postTitle)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(AppColors.textPrimary)
                            .lineLimit(2)

                        Text(item.postSummary)
                            .font(.system(size: 12))
                            .foregroundStyle(AppColors.textMuted)
                            .lineLimit(2)

                        if hiddenReason == .autoExpired {
                            Label("已自动转为私密 · 发布超过 30 天", systemImage: "clock.badge.exclamationmark")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(Color.orange)
                                .lineLimit(1)
                        }
                    }
                }

                if isOpening {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 18, height: 18)
                        .accessibilityLabel("正在打开内容")
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                guard !isOpening,
                      !isEditing,
                      !isUpdatingPrivacy,
                      !isDeleting
                else { return }
                onOpen()
            }

            if isPublishedManagement {
                HStack(spacing: 10) {
                    Spacer()

                    if isPrivate {
                        Button {
                            onSetPrivacy(false)
                        } label: {
                            HStack(spacing: 5) {
                                Text("恢复公开")
                                Image(systemName: "lock.open.fill")
                            }
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(AppColors.textPrimary)
                            .padding(.horizontal, 12)
                            .frame(height: 32)
                            .background(AppColors.accent.opacity(0.24))
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(isPublishedActionDisabled)
                        .accessibilityLabel("恢复公开帖子")
                    } else {
                        Button(action: onShare) {
                            HStack(spacing: 5) {
                                Text("分享")
                                Image(systemName: "square.and.arrow.up")
                            }
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(AppColors.textPrimary)
                            .padding(.horizontal, 12)
                            .frame(height: 32)
                            .background(Color(.systemGray6))
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(isPublishedActionDisabled)
                        .accessibilityLabel("分享帖子")
                    }

                    ZStack {
                        HStack(spacing: 5) {
                            Text("编辑")
                            Image(systemName: "ellipsis")
                        }
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(AppColors.textPrimary)
                        .frame(width: 82, height: 32)
                        .background(Color(.systemGray6))
                        .clipShape(Capsule())
                        .allowsHitTesting(false)

                        NativeProfilePostMenuButton(
                            isPrivate: isPrivate,
                            isDisabled: isPublishedActionDisabled,
                            onAction: onPerformAction
                        )
                        .frame(width: 82, height: 32)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("帖子操作")
                }
            } else if activityKind == .liked || activityKind == .favorited {
                HStack {
                    Spacer()
                    Button {
                        onToggleReaction(isReactionActive)
                    } label: {
                        Image(systemName: reactionIcon)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(reactionColor)
                            .frame(width: 36, height: 32)
                            .background(Color(.systemGray6))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(actionKindTitle)
                }
            }
        }
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) {
            Divider()
                .overlay(AppColors.divider)
        }
    }

    @ViewBuilder
    private var cover: some View {
        if let coverImage = item.coverImage,
           let url = URL(string: coverImage) {
            CachedRemoteImage(url: url, targetPixelWidth: 192) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                coverFallback
            }
            .frame(width: 62, height: 62)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        } else {
            coverFallback
        }
    }

    private var coverFallback: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(AppColors.accent.opacity(0.18))
            .frame(width: 62, height: 62)
            .overlay {
                Image(systemName: item.kind?.icon ?? "doc.text")
                    .foregroundStyle(AppColors.textMuted)
            }
    }

    private var actionKindTitle: String {
        if activityKind == .liked {
            return interactionState.isLiked ? "取消喜欢" : "重新喜欢"
        }
        return interactionState.isFavorited ? "取消收藏" : "重新收藏"
    }

    private var isPublishedManagement: Bool {
        activityKind == .published || activityKind == .privateContent
    }

    private var isReactionActive: Bool {
        activityKind == .liked
            ? interactionState.isLiked
            : interactionState.isFavorited
    }

    private var reactionIcon: String {
        if activityKind == .liked {
            return interactionState.isLiked ? "heart.fill" : "heart"
        }
        return interactionState.isFavorited ? "star.fill" : "star"
    }

    private var reactionColor: Color {
        if activityKind == .liked, interactionState.isLiked {
            return AppColors.likeActive
        }
        return interactionState.isFavorited ? AppColors.accentStrong : AppColors.textMuted
    }

    private var isPublishedActionDisabled: Bool {
        isOpening || isEditing || isUpdatingPrivacy || isDeleting
    }

}

struct CompletedSecondhandTransactionsView: View {
    @StateObject private var service = CompletedSecondhandTransactionsService()
    @State private var pendingRelist: CompletedSecondhandTransaction?

    var body: some View {
        VStack(spacing: 0) {
            rolePicker
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppColors.pageBackground.ignoresSafeArea())
        .cheesePageTopBar(title: "已交易")
        .task {
            await service.select(.buyer)
        }
        .confirmationDialog(
            "恢复上架这件商品？",
            isPresented: Binding(
                get: { pendingRelist != nil },
                set: { if !$0 { pendingRelist = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("取消", role: .cancel) {
                pendingRelist = nil
            }
            Button("恢复上架") {
                guard let item = pendingRelist else { return }
                pendingRelist = nil
                Task { _ = await service.relist(item) }
            }
        } message: {
            Text("商品将使用同一个帖子重新公开，并开启新的 30 天展示周期；原交易记录会保留。")
        }
        .alert(
            "恢复上架失败",
            isPresented: Binding(
                get: { service.mutationErrorMessage != nil },
                set: { if !$0 { service.mutationErrorMessage = nil } }
            )
        ) {
            Button("确定", role: .cancel) {}
        } message: {
            Text(service.mutationErrorMessage ?? "")
        }
    }

    private var rolePicker: some View {
        HStack(spacing: 8) {
            ForEach(CompletedSecondhandRole.allCases) { role in
                Button {
                    Task { await service.select(role) }
                } label: {
                    Text(role.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(
                            service.selectedRole == role
                                ? Color.black
                                : AppColors.textMuted
                        )
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            service.selectedRole == role
                                ? AppColors.accent
                                : Color.white
                        )
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch service.loadState {
        case .unresolved, .initialLoading:
            Spacer()
            ProgressView()
            Spacer()
        case .empty:
            Spacer()
            VStack(spacing: 10) {
                Image(systemName: "checkmark.seal")
                    .font(.system(size: 36))
                    .foregroundStyle(AppColors.textMuted)
                Text(service.selectedRole == .buyer ? "暂无买入记录" : "暂无卖出记录")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(AppColors.textMuted)
            }
            Spacer()
        case .error(let message):
            Spacer()
            ErrorView(message) {
                Task { await service.select(service.selectedRole, force: true) }
            }
            Spacer()
        case .loaded:
            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: 10) {
                    ForEach(service.items) { item in
                        CompletedSecondhandTransactionRow(
                            item: item,
                            isRelisting: service.relistingTransactionID == item.id,
                            onRelist: { pendingRelist = item }
                        )
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 2)
                .padding(.bottom, 32)
            }
            .refreshable {
                await service.select(service.selectedRole, force: true)
            }
        }
    }
}

private struct CompletedSecondhandTransactionRow: View {
    let item: CompletedSecondhandTransaction
    let isRelisting: Bool
    let onRelist: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            cover

            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    Text(statusTitle)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(AppColors.accentStrong)
                    Spacer()
                    Text(item.completedAt.formatted(date: .numeric, time: .shortened))
                        .font(.system(size: 10))
                        .foregroundStyle(AppColors.textMuted)
                }

                Text(item.listingTitle)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(AppColors.textPrimary)
                    .lineLimit(2)

                Text("CAD \(item.price, specifier: "%.2f")")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(AppColors.accentStrong)

                HStack(spacing: 6) {
                    counterpartyAvatar
                    Text("\(item.role == .buyer ? "卖家" : "买家")：\(item.counterpartyName)")
                        .font(.system(size: 11))
                        .foregroundStyle(AppColors.textMuted)
                        .lineLimit(1)

                    Spacer(minLength: 8)

                    if item.canRelist {
                        Button(action: onRelist) {
                            Group {
                                if isRelisting {
                                    ProgressView()
                                        .controlSize(.small)
                                } else {
                                    Label("恢复上架", systemImage: "arrow.up.circle.fill")
                                }
                            }
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.black)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(AppColors.accent)
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(isRelisting)
                    }
                }
            }
        }
        .padding(12)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        .cheeseCardChrome(cornerRadius: 15)
        .accessibilityElement(children: .contain)
    }

    private var statusTitle: String {
        "交易完成"
    }

    @ViewBuilder
    private var cover: some View {
        if let rawURL = item.coverImage, let url = URL(string: rawURL) {
            CachedRemoteImage(url: url, targetPixelWidth: 192) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                coverFallback
            }
            .frame(width: 72, height: 72)
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        } else {
            coverFallback
        }
    }

    private var coverFallback: some View {
        RoundedRectangle(cornerRadius: 11, style: .continuous)
            .fill(AppColors.accent.opacity(0.18))
            .frame(width: 72, height: 72)
            .overlay {
                Image(systemName: "bag.fill")
                    .foregroundStyle(AppColors.textMuted)
            }
    }

    @ViewBuilder
    private var counterpartyAvatar: some View {
        if let rawURL = item.counterpartyAvatar, let url = URL(string: rawURL) {
            CachedRemoteImage(url: url, targetPixelWidth: 72) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Circle().fill(Color(.systemGray5))
            }
            .frame(width: 18, height: 18)
            .clipShape(Circle())
        } else {
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: 18))
                .foregroundStyle(AppColors.textMuted)
        }
    }
}

struct PrivateContentView: View {
    var body: some View {
        ProfileActivityView(
            initialKind: .published,
            showsKindPicker: false,
            publishedVisibility: .hidden,
            pageTitle: "私密内容"
        )
    }
}

private enum ProfileActivityDestination: Identifiable, Hashable {
    case secondhand(SecondhandItem)
    case forum(ForumPostItem, commentID: UUID?)

    var id: String {
        switch self {
        case .secondhand(let item):
            return "secondhand:\(item.id)"
        case .forum(let post, let commentID):
            return "forum:\(post.id):\(commentID?.uuidString ?? "")"
        }
    }
}

private struct ProfileActivityPostDetailRouter: View {
    let destination: ProfileActivityDestination

    var body: some View {
        switch destination {
        case .secondhand(let item):
            SecondhandDetailView(item: item)
        case .forum(let post, let commentID):
            ForumDetailView(
                post: post,
                initialCommentID: commentID
            )
        }
    }
}
