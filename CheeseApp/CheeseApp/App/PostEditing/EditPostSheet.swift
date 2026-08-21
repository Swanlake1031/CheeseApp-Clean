// App-level composition for editing feature-owned post types.
import SwiftUI

struct EditPostSheet: View {
    let post: UserPostSummary
    let onSave: (EditableUserPostPayload) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var userPostsService = UserPostsService()
    @StateObject private var forumService = ForumService.shared

    @State private var title: String
    @State private var description: String
    @State private var priceText: String
    @State private var originalPriceText: String

    @State private var secondhandCategory: SecondhandPost.Category
    @State private var secondhandCondition: String
    @State private var secondhandIsNegotiable: Bool

    @State private var forumBoardID: UUID?
    @State private var forumAllowComments: Bool
    @State private var forumIsAnonymous: Bool
    private let isPrivate: Bool

    @State private var isLoadingExtraDetails = false
    @State private var hasLoadedExtraDetails = false
    @State private var extraDetailsErrorMessage: String?
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var showEditedToast = false
    @State private var selectedImages: [UIImage]
    @State private var existingImages: [EditablePostImage]
    @State private var selectedMentions: [MentionCandidate] = []
    @State private var isForumTitleFocused = false
    @State private var isForumContentFocused = false

    init(post: UserPostSummary, onSave: @escaping (EditableUserPostPayload) async throws -> Void) {
        self.post = post
        self.onSave = onSave

        _title = State(initialValue: post.title)
        _description = State(initialValue: post.description)
        _priceText = State(initialValue: post.price.map { Formatters.formatCompactNumber($0) } ?? "")
        _originalPriceText = State(initialValue: "")

        _secondhandCategory = State(initialValue: .other)
        _secondhandCondition = State(initialValue: "good")
        _secondhandIsNegotiable = State(initialValue: true)

        _forumBoardID = State(initialValue: nil)
        _forumAllowComments = State(initialValue: true)
        _forumIsAnonymous = State(initialValue: false)
        isPrivate = post.isPrivate
        _selectedImages = State(initialValue: [])
        _existingImages = State(initialValue: [])
    }

    var body: some View {
        Group {
            if post.kind == .forum {
                forumEditor
            } else {
                secondhandEditor
            }
        }
        .cheeseTabBarHidden(true)
        .enableSwipeBackGesture()
        .overlay {
            if !hasLoadedExtraDetails {
                extraDetailsLoadingOverlay
            }
        }
        .task {
            await loadExtraDetailsIfNeeded()
        }
    }

    private var secondhandEditor: some View {
        ZStack {
                AppColors.pageBackground
                    .ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 20) {
                        editForm
                        existingImageSection

                        if let errorMessage {
                            Text(errorMessage)
                                .font(.subheadline)
                                .foregroundStyle(.red)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        Spacer(minLength: 40)
                    }
                    .padding()
                }
                .scrollDismissesKeyboard(.interactively)
                .contentShape(Rectangle())
                .dismissKeyboardOnTap()

                if showEditedToast {
                    VStack {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 14, weight: .bold))
                            Text(L10n.tr("Edited", "已编辑"))
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Color.black.opacity(0.82))
                        .clipShape(Capsule())
                        .padding(.top, 12)

                        Spacer()
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .safeAreaInset(edge: .top) {
            PostDetailTopBar(
                title: L10n.tr("Edit Post", "编辑帖子"),
                onBack: { dismiss() }
            ) {
                secondhandSaveButton
            }
        }
    }

    private var secondhandSaveButton: some View {
        Button {
            Task { await save() }
        } label: {
            Group {
                if isSaving {
                    ProgressView()
                        .tint(.white)
                } else {
                    Text(L10n.tr("Save", "保存"))
                        .font(.system(size: 15, weight: .bold))
                }
            }
            .foregroundStyle(.white)
            .frame(minWidth: 62)
            .frame(height: 40)
            .background(isFormValid ? accentColor : Color.gray.opacity(0.38))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(isSaving || !isFormValid)
    }

    private var forumEditor: some View {
        ForumPostEditorSurface(
            isEditing: true,
            boards: forumService.boards,
            selectedBoardID: $forumBoardID,
            title: $title,
            content: $description,
            selectedImages: $selectedImages,
            existingImages: $existingImages,
            selectedMentions: $selectedMentions,
            isTitleFocused: $isForumTitleFocused,
            isContentFocused: $isForumContentFocused,
            isSubmitting: isSaving,
            errorMessage: errorMessage,
            hasDraft: false,
            installsSwipeBackGesture: false,
            onClose: { dismiss() },
            onSubmit: { Task { await save() } },
            onSaveDraft: {},
            onRestoreDraft: {},
            onClearDraft: {},
            onBoardSelected: { board in
                forumBoardID = board.id
                forumIsAnonymous = board.requiresAnonymousPosts
            }
        )
    }

    private var extraDetailsLoadingOverlay: some View {
        ZStack {
            AppColors.pageBackground
                .ignoresSafeArea()

            if let extraDetailsErrorMessage {
                VStack(spacing: 14) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(.orange)
                    Text(L10n.tr("Unable to load this post", "无法加载帖子资料"))
                        .font(.headline)
                    Text(extraDetailsErrorMessage)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button(L10n.tr("Try Again", "重试")) {
                        Task { await loadExtraDetailsIfNeeded() }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(accentColor)
                }
                .padding(24)
            } else {
                ProgressView(L10n.tr("Loading post…", "正在加载帖子…"))
                    .tint(accentColor)
            }
        }
        .safeAreaInset(edge: .top) {
            PostDetailTopBar(
                title: L10n.tr("Edit Post", "编辑帖子"),
                onBack: { dismiss() }
            ) {
                EmptyView()
            }
        }
    }

    private var accentColor: Color {
        switch post.kind {
        case .secondhand:
            return Color.orange
        case .forum:
            return Color.pink
        }
    }

    private var isFormValid: Bool {
        guard hasLoadedExtraDetails else { return false }
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        switch post.kind {
        case .secondhand:
            return !trimmedTitle.isEmpty && !priceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .forum:
            return !trimmedTitle.isEmpty
                && title.count <= ForumComposerRules.maximumTitleLength
                && forumBoardID != nil
        }
    }

    @ViewBuilder
    private var editForm: some View {
        VStack(spacing: 20) {
            SecondhandPostEditFormView(
                accentColor: accentColor,
                title: $title,
                priceText: $priceText,
                originalPriceText: $originalPriceText,
                category: $secondhandCategory,
                condition: $secondhandCondition,
                isNegotiable: $secondhandIsNegotiable,
                description: $description,
                selectedImages: $selectedImages,
                existingImageCount: existingImages.count
            )
        }
    }

    @ViewBuilder
    private var existingImageSection: some View {
        if !existingImages.isEmpty {
            PostFormSection(title: L10n.tr("Current images", "现有图片")) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(existingImages) { image in
                            ZStack(alignment: .topTrailing) {
                                AsyncImage(url: URL(string: image.url)) { phase in
                                    if let loaded = phase.image {
                                        loaded
                                            .resizable()
                                            .scaledToFill()
                                    } else {
                                        Color(.systemGray5)
                                            .overlay {
                                                Image(systemName: "photo")
                                                    .foregroundStyle(.secondary)
                                            }
                                    }
                                }
                                .frame(width: 82, height: 82)
                                .clipShape(RoundedRectangle(cornerRadius: 10))

                                Button {
                                    existingImages.removeAll { $0.id == image.id }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .symbolRenderingMode(.palette)
                                        .foregroundStyle(.white, Color.black.opacity(0.72))
                                        .font(.system(size: 21))
                                }
                                .buttonStyle(.plain)
                                .offset(x: 5, y: -5)
                                .accessibilityLabel(L10n.tr("Remove image", "移除图片"))
                            }
                        }
                    }
                    .padding(.top, 5)
                }
                .padding()
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private func save() async {
        guard !isSaving else { return }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        do {
            let normalizedPrice: Double?
            let normalizedOriginalPrice: Double?
            if post.kind.supportsPriceEditing {
                let trimmed = priceText.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    normalizedPrice = nil
                } else if let parsed = Double(trimmed) {
                    normalizedPrice = parsed
                } else {
                    throw NSError(
                        domain: "",
                        code: 400,
                        userInfo: [NSLocalizedDescriptionKey: L10n.tr("Invalid price", "价格格式不正确")]
                    )
                }

                let originalTrimmed = originalPriceText.trimmingCharacters(in: .whitespacesAndNewlines)
                if originalTrimmed.isEmpty {
                    normalizedOriginalPrice = nil
                } else if let parsed = Double(originalTrimmed),
                          let normalizedPrice,
                          parsed.isFinite,
                          parsed >= normalizedPrice {
                    normalizedOriginalPrice = parsed
                } else {
                    throw NSError(
                        domain: "",
                        code: 400,
                        userInfo: [NSLocalizedDescriptionKey: "原价必须大于或等于卖价"]
                    )
                }
            } else {
                normalizedPrice = nil
                normalizedOriginalPrice = nil
            }

            try await onSave(
                EditableUserPostPayload(
                    id: post.id,
                    kind: post.kind,
                    title: title,
                    description: description,
                    price: normalizedPrice,
                    secondhandDetails: post.kind == .secondhand
                    ? SecondhandEditableFields(
                        category: secondhandCategory,
                        originalPrice: normalizedOriginalPrice,
                        condition: secondhandCondition,
                        isNegotiable: secondhandIsNegotiable,
                        images: existingImages
                    )
                    : nil,
                    forumDetails: post.kind == .forum
                    ? ForumEditableFields(
                        boardID: forumBoardID,
                        allowComments: forumAllowComments,
                        isAnonymous: forumIsAnonymous
                    )
                    : nil,
                    isAnonymous: post.kind == .forum ? forumIsAnonymous : nil,
                    isPrivate: isPrivate,
                    retainedImageIDs: existingImages.map(\.id),
                    newImages: selectedImages
                )
            )

            withAnimation(.spring(response: 0.24, dampingFraction: 0.84)) {
                showEditedToast = true
            }
            HapticEngine.impact(.light)
            try? await Task.sleep(nanoseconds: 250_000_000)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadExtraDetailsIfNeeded() async {
        guard !isLoadingExtraDetails, !hasLoadedExtraDetails else { return }

        isLoadingExtraDetails = true
        extraDetailsErrorMessage = nil
        defer { isLoadingExtraDetails = false }

        do {
            switch post.kind {
            case .secondhand:
                let details = try await SecondhandService.shared.fetchEditFields(postId: post.id)
                guard let loadedCategory = details.category else {
                    throw NSError(
                        domain: "SecondhandEditing",
                        code: 422,
                        userInfo: [NSLocalizedDescriptionKey: L10n.tr(
                            "This listing's category could not be loaded. Please try again.",
                            "无法加载该商品分类，请重试。"
                        )]
                    )
                }
                secondhandCategory = loadedCategory
                originalPriceText = details.originalPrice.map {
                    Formatters.formatCompactNumber($0)
                } ?? ""
                secondhandCondition = details.condition
                secondhandIsNegotiable = details.isNegotiable
                existingImages = details.images

            case .forum:
                await forumService.fetchBoards()
                let details = try await userPostsService.fetchForumEditFields(postId: post.id)
                forumBoardID = details.boardID
                forumAllowComments = details.allowComments
                forumIsAnonymous = details.isAnonymous
                existingImages = details.images
            }
            hasLoadedExtraDetails = true
        } catch {
            if error.isCancellationLike { return }
            extraDetailsErrorMessage = error.localizedDescription
        }
    }

}
