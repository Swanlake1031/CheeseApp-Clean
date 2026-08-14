import SwiftUI

enum ForumComposerRules {
    static let maximumTitleLength = 80

    static func limitedTitle(_ value: String) -> String {
        String(value.prefix(maximumTitleLength))
    }
}

struct ForumPostEditorSurface: View {
    @State private var titleEditorHeight: CGFloat = 44

    let isEditing: Bool
    let boards: [ForumBoard]
    @Binding var selectedBoardID: UUID?
    @Binding var title: String
    @Binding var content: String
    @Binding var selectedImages: [UIImage]
    @Binding var existingImages: [EditablePostImage]
    @Binding var selectedMentions: [MentionCandidate]
    @Binding var isTitleFocused: Bool
    @Binding var isContentFocused: Bool
    let isSubmitting: Bool
    let errorMessage: String?
    let hasDraft: Bool
    let installsSwipeBackGesture: Bool
    let onClose: () -> Void
    let onSubmit: () -> Void
    let onSaveDraft: () -> Void
    let onRestoreDraft: () -> Void
    let onClearDraft: () -> Void
    let onBoardSelected: (ForumBoard) -> Void

    private var selectedBoard: ForumBoard? {
        boards.first { $0.id == selectedBoardID && $0.status == .active }
    }

    private var isValid: Bool {
        selectedBoard != nil
            && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && title.count <= ForumComposerRules.maximumTitleLength
    }

    var body: some View {
        ZStack {
            AppColors.pageBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                header

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 18) {
                        titleEditor
                        contentEditor

                        MentionSuggestionPanel(
                            text: $content,
                            selectedMentions: $selectedMentions
                        )

                        imagePreview

                        if let errorMessage {
                            Text(errorMessage)
                                .font(.subheadline)
                                .foregroundStyle(.red)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.top, 18)
                    .padding(.bottom, 28)
                }
                .scrollDismissesKeyboard(.interactively)
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            accessoryBar
        }
        .onChange(of: title) { _, value in
            let limited = ForumComposerRules.limitedTitle(value)
            if limited != value { title = limited }
        }
        .if(installsSwipeBackGesture) { content in
            content.enableSwipeBackGesture()
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button(action: onClose) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(AppColors.textPrimary)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)

            Menu {
                ForEach(boards.filter { $0.status == .active }) { board in
                    Button {
                        onBoardSelected(board)
                    } label: {
                        Label(board.name, systemImage: board.icon)
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: selectedBoard?.icon ?? "square.grid.2x2")
                        .foregroundStyle(AppColors.accentStrong)
                    Text(selectedBoard?.name ?? "选择板块")
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .bold))
                }
                .foregroundStyle(AppColors.textPrimary)
                .padding(.horizontal, 13)
                .frame(height: 40)
                .background(AppColors.cardBackground)
                .clipShape(Capsule())
                .overlay { Capsule().stroke(Color.black.opacity(0.16)) }
            }
            .buttonStyle(.plain)

            Spacer(minLength: 4)

            Button(action: onSubmit) {
                Group {
                    if isSubmitting {
                        ProgressView().tint(.white)
                    } else {
                        Text(isEditing ? "保存" : "发布")
                            .font(.system(size: 15, weight: .bold))
                    }
                }
                .foregroundStyle(.white)
                .frame(minWidth: 62)
                .frame(height: 40)
                .background(isValid ? AppColors.accentStrong : Color.gray.opacity(0.38))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(!isValid || isSubmitting)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(AppColors.pageBackground)
    }

    private var titleEditor: some View {
        ZStack(alignment: .topLeading) {
            if title.isEmpty {
                Text("标题")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(AppColors.textMuted)
                    .allowsHitTesting(false)
            }
            AutoFocusTextEditor(
                text: $title,
                isFirstResponder: $isTitleFocused,
                fontSize: 28,
                fontWeight: .bold,
                maximumLength: ForumComposerRules.maximumTitleLength,
                dynamicHeight: $titleEditorHeight,
                minimumHeight: 44
            )
            .frame(maxWidth: .infinity)
            .frame(height: titleEditorHeight)
            .clipped()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: titleEditorHeight)
        .clipped()
    }

    private var contentEditor: some View {
        ZStack(alignment: .topLeading) {
            if content.isEmpty {
                Text("正文")
                    .font(.system(size: 18))
                    .foregroundStyle(AppColors.textMuted)
                    .allowsHitTesting(false)
            }
            AutoFocusTextEditor(
                text: $content,
                isFirstResponder: $isContentFocused,
                fontSize: 18
            )
            .frame(minHeight: 300)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var imagePreview: some View {
        if !existingImages.isEmpty || !selectedImages.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(existingImages) { image in
                        removableImage {
                            AsyncImage(url: URL(string: image.url)) { phase in
                                if let loaded = phase.image {
                                    loaded.resizable().scaledToFill()
                                } else {
                                    Color(.systemGray5)
                                }
                            }
                        } onRemove: {
                            existingImages.removeAll { $0.id == image.id }
                        }
                    }

                    ForEach(Array(selectedImages.enumerated()), id: \.offset) { index, image in
                        removableImage {
                            Image(uiImage: image).resizable().scaledToFill()
                        } onRemove: {
                            selectedImages.remove(at: index)
                        }
                    }
                }
                .padding(.top, 7)
                .padding(.trailing, 7)
            }
        }
    }

    private func removableImage<Content: View>(
        @ViewBuilder content: () -> Content,
        onRemove: @escaping () -> Void
    ) -> some View {
        ZStack(alignment: .topTrailing) {
            content()
                .frame(width: 84, height: 84)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(Color.black.opacity(0.72))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .offset(x: 7, y: -7)
        }
    }

    private var accessoryBar: some View {
        HStack(spacing: 4) {
            ImagePicker(
                selectedImages: $selectedImages,
                maxCount: 6,
                existingImageCount: existingImages.count,
                presentationStyle: .composerToolbar
            )

            if !isEditing {
                Menu {
                    Button("保存草稿", action: onSaveDraft)
                    if hasDraft {
                        Button("恢复草稿", action: onRestoreDraft)
                        Button("清空草稿", role: .destructive, action: onClearDraft)
                    }
                } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(AppColors.textPrimary)
                        .frame(width: 44, height: 44)
                }
            }

            Spacer()

            Button {
                if isTitleFocused || isContentFocused {
                    isTitleFocused = false
                    isContentFocused = false
                } else {
                    isContentFocused = true
                }
            } label: {
                Image(systemName: "keyboard")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(AppColors.textPrimary)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(Color.white)
    }
}
