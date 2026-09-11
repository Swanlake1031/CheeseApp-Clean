import SwiftUI

enum ForumComposerRules {
    static let maximumTitleLength = 80

    static func limitedTitle(_ value: String) -> String {
        String(value.prefix(maximumTitleLength))
    }

    static func canSubmit(title: String) -> Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && title.count <= maximumTitleLength
    }
}

struct ForumPostEditorSurface: View {
    @State private var titleEditorHeight: CGFloat = 44

    let isEditing: Bool
    @Binding var isAnonymous: Bool
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

    private var isValid: Bool {
        ForumComposerRules.canSubmit(title: title)
    }

    private var isSubmitEnabled: Bool {
        !isSubmitting && (!isEditing || isValid)
    }

    private var usesActiveSubmitStyle: Bool {
        !isEditing || isValid
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
                .background(usesActiveSubmitStyle ? AppColors.accentStrong : Color.gray.opacity(0.38))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(!isSubmitEnabled)
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
                    .font(.system(size: 16))
                    .foregroundStyle(AppColors.textMuted)
                    .allowsHitTesting(false)
            }
            AutoFocusTextEditor(
                text: $content,
                isFirstResponder: $isContentFocused,
                fontSize: 16
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
                            .tappableImagePreview(image.url)
                        } onRemove: {
                            existingImages.removeAll { $0.id == image.id }
                        }
                    }

                    ForEach(Array(selectedImages.enumerated()), id: \.offset) { index, image in
                        removableImage {
                            Image(uiImage: image).resizable().scaledToFill()
                                .tappableImagePreview(image)
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
        RemovablePostImageThumbnail(onRemove: onRemove) {
            content()
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
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(AppColors.textPrimary)
                        .frame(width: 44, height: 44)
                }
            }

            Toggle(isOn: $isAnonymous) {
                HStack(spacing: 4) {
                    Image(systemName: isAnonymous ? "theatermasks.fill" : "theatermasks")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(AppColors.textPrimary)
                        .frame(width: 44, height: 44)

                    Text(L10n.tr("Anonymous", "匿名"))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(AppColors.textPrimary)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .tint(AppColors.accentStrong)
            .fixedSize()
            .accessibilityLabel(
                isAnonymous
                    ? L10n.tr("Posting anonymously", "已选择匿名发布")
                    : L10n.tr("Post anonymously", "匿名发布")
            )
            .accessibilityAddTraits(isAnonymous ? .isSelected : [])

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
