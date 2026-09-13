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
    var onBusyChanged: ((Bool) -> Void)?

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
    @State private var hasFinishedCreateFlow = false

    init(
        initialBoard: ForumBoard? = nil,
        autoRestoreDraft: Bool = false,
        onCreated: (() -> Void)? = nil,
        onExit: (() -> Void)? = nil,
        onBusyChanged: ((Bool) -> Void)? = nil
    ) {
        self.initialBoard = initialBoard
        self.autoRestoreDraft = autoRestoreDraft
        self.onCreated = onCreated
        self.onExit = onExit
        self.onBusyChanged = onBusyChanged
        _selectedBoardID = State(initialValue: initialBoard?.id)
    }

    private var selectedBoard: ForumBoard? {
        service.boards.first { $0.id == selectedBoardID && $0.status == .active }
            ?? initialBoard.flatMap { $0.status == .active ? $0 : nil }
            ?? service.boards.first { $0.slug == "casual-chat" && $0.status == .active }
    }

    var body: some View {
        ForumPostEditorSurface(
            isEditing: false,
            isAnonymous: $isAnonymous,
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
            onSubmit: attemptSubmit,
            onSaveDraft: {
                saveDraft(showBanner: false)
                finishExitNavigation(preservingDraft: true)
            },
            onRestoreDraft: { restoreDraft(showBanner: true) },
            onClearDraft: {
                CreateDraftStore.clear(.forum)
                CreateComposerSessionStore.clear(.forum)
                showDraftBanner(L10n.tr("Draft cleared", "草稿已清空"))
            }
        )
        .alert(L10n.tr("Post not published", "帖子尚未发布"), isPresented: $showExitDraftPrompt) {
            Button(L10n.tr("Cancel", "取消"), role: .cancel) {}
            Button(L10n.tr("Discard", "不保存"), role: .destructive) {
                finishExitNavigation(preservingDraft: false)
            }
            Button(L10n.tr("Save as draft", "存为草稿")) {
                saveDraft(showBanner: false)
                finishExitNavigation(preservingDraft: true)
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
            } else {
                isAnonymous = AuthService.shared.currentUser?.isAnonymousDefault ?? false
            }

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
        .onChange(of: isLoading) { _, isBusy in
            onBusyChanged?(isBusy)
        }
        .onDisappear {
            preserveInterruptedDraftIfNeeded()
        }
        .interceptSwipeBack(when: hasDraftableContent, onAttempt: attemptClose)
    }

    private func dismissKeyboard() {
        isTitleFocused = false
        isContentFocused = false
    }

    private func attemptSubmit() {
        guard !isLoading else { return }

        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            presentValidationMessage(L10n.tr("Please enter a title", "请填写标题"))
            isTitleFocused = true
            isContentFocused = false
            return
        }

        errorMessage = nil
        dismissKeyboard()
        Task { await submit() }
    }

    private func presentValidationMessage(_ message: String) {
        errorMessage = message
        showDraftBanner(message, duration: 2)
    }

    private func submit() async {
        guard !isLoading else { return }

        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            presentValidationMessage(L10n.tr("Please enter a title", "请填写标题"))
            return
        }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        // The board is internal routing metadata, never a user-required tag.
        if selectedBoard == nil { await service.fetchBoards() }
        guard let board = selectedBoard else {
            presentValidationMessage(L10n.tr("Unable to publish right now. Please retry.", "暂时无法发布，请重试。"))
            return
        }

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
                    title: trimmedTitle,
                    content: content.trimmingCharacters(in: .whitespacesAndNewlines),
                    isAnonymous: isAnonymous,
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
            hasFinishedCreateFlow = true
            CreateComposerSessionStore.clear(.forum)
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
            subtitle: nil,
            payload: payload
        )
        CreateComposerSessionStore.save(images: selectedImages, for: .forum)
        if showBanner { showDraftBanner(L10n.tr("Draft saved", "草稿已保存")) }
    }

    private func restoreDraft(showBanner: Bool) {
        guard let payload = CreateDraftStore.load(kind: .forum, as: ForumDraftPayload.self) else { return }
        title = payload.title
        content = payload.content
        selectedBoardID = payload.boardID ?? initialBoard?.id
        isAnonymous = payload.isAnonymous
        isPrivate = payload.isPrivate ?? false
        selectedImages = CreateComposerSessionStore.images(for: .forum)
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
            finishExitNavigation(preservingDraft: false)
        }
    }

    private func finishExitNavigation(preservingDraft: Bool) {
        hasFinishedCreateFlow = true
        if preservingDraft {
            CreateComposerSessionStore.markResumable(.forum)
        }
        if let onExit {
            onExit()
        } else {
            dismiss()
        }
    }

    private func preserveInterruptedDraftIfNeeded() {
        guard !hasFinishedCreateFlow, hasDraftableContent, !isLoading else {
            return
        }
        saveDraft(showBanner: false)
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
