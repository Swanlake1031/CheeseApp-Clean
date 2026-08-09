//
//  CreateForumView.swift
//  CheeseApp
//
//  Board-based Forum composer.
//

import SwiftUI

private struct ForumDraftPayload: Codable {
    let title: String
    let content: String
    let isAnonymous: Bool
    let isPrivate: Bool?
    let boardID: UUID?
}

struct CreateForumView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var service = ForumService.shared

    let initialBoard: ForumBoard?
    var autoRestoreDraft: Bool
    var onCreated: (() -> Void)?
    var onExit: (() -> Void)?

    @State private var title = ""
    @State private var content = ""
    @State private var isAnonymous = false
    @State private var isPrivate = false
    @State private var selectedBoardID: UUID?
    @State private var selectedImages: [UIImage] = []
    @State private var existingImages: [EditablePostImage] = []
    @State private var selectedMentions: [MentionCandidate] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var draftBannerText: String?
    @State private var bannerDismissID = UUID()
    @State private var hasInitialized = false
    @State private var showExitDraftPrompt = false
    @State private var publishRequestID = UUID()
    @State private var isTitleFocused = false
    @State private var isContentFocused = false

    init(
        initialBoard: ForumBoard? = nil,
        autoRestoreDraft: Bool = false,
        onCreated: (() -> Void)? = nil,
        onExit: (() -> Void)? = nil
    ) {
        self.initialBoard = initialBoard
        self.autoRestoreDraft = autoRestoreDraft
        self.onCreated = onCreated
        self.onExit = onExit
        _selectedBoardID = State(initialValue: initialBoard?.id)
    }

    private var selectedBoard: ForumBoard? {
        service.boards.first { $0.id == selectedBoardID && $0.status == .active }
            ?? initialBoard.flatMap { $0.status == .active ? $0 : nil }
    }

    var body: some View {
        ForumPostEditorSurface(
            isEditing: false,
            boards: service.boards,
            selectedBoardID: $selectedBoardID,
            title: $title,
            content: $content,
            selectedImages: $selectedImages,
            existingImages: $existingImages,
            selectedMentions: $selectedMentions,
            isTitleFocused: $isTitleFocused,
            isContentFocused: $isContentFocused,
            isSubmitting: isLoading,
            errorMessage: errorMessage,
            hasDraft: CreateDraftStore.hasDraft(.forum),
            installsSwipeBackGesture: true,
            onClose: attemptClose,
            onSubmit: {
                dismissKeyboard()
                Task { await submit() }
            },
            onSaveDraft: {
                saveDraft(showBanner: false)
                finishExitNavigation()
            },
            onRestoreDraft: { restoreDraft(showBanner: true) },
            onClearDraft: {
                CreateDraftStore.clear(.forum)
                showDraftBanner(L10n.tr("Draft cleared", "草稿已清空"))
            },
            onBoardSelected: { board in
                selectedBoardID = board.id
                normalizeAnonymousChoice(
                    for: board,
                    showAutomaticAnonymousBanner: board.requiresAnonymousPosts
                )
            }
        )
        .alert(L10n.tr("Post not published", "帖子尚未发布"), isPresented: $showExitDraftPrompt) {
            Button(L10n.tr("Cancel", "取消"), role: .cancel) {}
            Button(L10n.tr("Discard", "不保存"), role: .destructive) {
                finishExitNavigation()
            }
            Button(L10n.tr("Save as draft", "存为草稿")) {
                saveDraft(showBanner: false)
                finishExitNavigation()
            }
        } message: {
            Text(L10n.tr("Save as draft?", "是否存为草稿"))
        }
        .overlay(alignment: .top) {
            if let draftBannerText {
                Text(draftBannerText)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color.black.opacity(0.82))
                    .clipShape(Capsule())
                    .padding(.top, 72)
            }
        }
        .task {
            await service.fetchBoards()
            guard !hasInitialized else { return }
            hasInitialized = true
            if autoRestoreDraft {
                restoreDraft(showBanner: true)
            }
            normalizeAnonymousChoice()

            try? await Task.sleep(nanoseconds: 160_000_000)
            guard !Task.isCancelled else { return }
            if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                isTitleFocused = true
            } else {
                isContentFocused = true
            }
        }
        .onChange(of: isTitleFocused) { _, isFocused in
            guard isFocused else { return }
            isContentFocused = false
        }
        .onChange(of: isContentFocused) { _, isFocused in
            guard isFocused else { return }
            isTitleFocused = false
        }
        .interceptSwipeBack(when: hasDraftableContent, onAttempt: attemptClose)
    }

    private func dismissKeyboard() {
        isTitleFocused = false
        isContentFocused = false
    }

    private func normalizeAnonymousChoice(
        for resolvedBoard: ForumBoard? = nil,
        showAutomaticAnonymousBanner: Bool = false
    ) {
        guard let board = resolvedBoard ?? selectedBoard else {
            isAnonymous = false
            return
        }
        if board.requiresAnonymousPosts {
            isAnonymous = true
            if showAutomaticAnonymousBanner {
                showDraftBanner("匿名板块已自动匿名", duration: 2)
            }
        } else {
            isAnonymous = false
        }
    }

    private func submit() async {
        guard !isLoading, let board = selectedBoard else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let userID = try await AuthService.shared.requireAuthUserId()
            guard let schoolID = AuthService.shared.currentUser?.schoolId else {
                errorMessage = "请先在个人资料中选择学校后再发布"
                return
            }
            let publishedID = try await service.publishPost(
                input: ForumCreateInput(
                postId: publishRequestID,
                userId: userID,
                schoolId: schoolID,
                title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                content: content.trimmingCharacters(in: .whitespacesAndNewlines),
                isAnonymous: board.requiresAnonymousPosts || isAnonymous,
                isPrivate: isPrivate,
                boardID: board.id,
                mentionedUserIDs: MentionTextLogic.activeUserIDs(
                    in: content,
                    selected: selectedMentions
                )
                ),
                images: selectedImages
            )

            await service.fetchPosts()
            CreateDraftStore.clear(.forum)
            PostFeatureEvents.postDidChange(
                kind: .forum,
                authorId: userID,
                postId: publishedID,
                change: .created
            )
            onCreated?()
            if onCreated == nil { dismiss() }
        } catch {
            errorMessage = ForumCreatePostError.userFacingMessage(for: error)
        }
    }

    private func saveDraft(showBanner: Bool = true) {
        let payload = ForumDraftPayload(
            title: title,
            content: content,
            isAnonymous: isAnonymous,
            isPrivate: isPrivate,
            boardID: selectedBoardID
        )
        CreateDraftStore.save(
            kind: .forum,
            title: title,
            subtitle: selectedBoard?.name,
            payload: payload
        )
        if showBanner { showDraftBanner(L10n.tr("Draft saved", "草稿已保存")) }
    }

    private func restoreDraft(showBanner: Bool) {
        guard let payload = CreateDraftStore.load(kind: .forum, as: ForumDraftPayload.self) else { return }
        title = payload.title
        content = payload.content
        selectedBoardID = payload.boardID ?? initialBoard?.id
        isAnonymous = payload.isAnonymous
        isPrivate = payload.isPrivate ?? false
        normalizeAnonymousChoice()
        if showBanner { showDraftBanner(L10n.tr("Draft restored", "草稿已恢复")) }
    }

    private var hasDraftableContent: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || selectedBoardID != initialBoard?.id
            || !selectedImages.isEmpty
            || isAnonymous
            || isPrivate
    }

    private func attemptClose() {
        guard !isLoading else { return }
        if hasDraftableContent {
            showExitDraftPrompt = true
        } else {
            finishExitNavigation()
        }
    }

    private func finishExitNavigation() {
        if let onExit {
            onExit()
        } else {
            dismiss()
        }
    }

    private func showDraftBanner(
        _ message: String,
        duration: TimeInterval = 1.6
    ) {
        let dismissID = UUID()
        bannerDismissID = dismissID
        withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
            draftBannerText = message
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            guard bannerDismissID == dismissID else { return }
            withAnimation(.easeInOut(duration: 0.2)) { draftBannerText = nil }
        }
    }
}

#Preview {
    NavigationStack {
        CreateForumView().environmentObject(AuthService.shared)
    }
}
