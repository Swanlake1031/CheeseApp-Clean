//
//  CreateSecondhandView.swift
//  CheeseApp
//
//  🛍️ 发布二手物品表单
//

import SwiftUI

private struct SecondhandDraftPayload: Codable {
    let title: String
    let description: String
    let price: String
    let originalPrice: String?
    let category: SecondhandPost.Category?
    let condition: String
    let isNegotiable: Bool
}

enum SecondhandCreateFormRules {
    static let maximumPrice = 99_999_999.99
    static let maximumPriceText = "CAD 99,999,999.99"
    static let defaultCategory: SecondhandPost.Category? = nil
    static let defaultCondition = ""
    static let defaultIsNegotiable = false

    static func normalizedRequiredText(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func validPrice(from value: String) -> Double? {
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let price = Double(trimmedValue),
              price.isFinite,
              price >= 0,
              price <= maximumPrice
        else {
            return nil
        }
        return price
    }

    static func priceExceedsMaximum(_ value: String) -> Bool {
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let price = Double(trimmedValue), price.isFinite else { return false }
        return price > maximumPrice
    }

    static func isValid(
        title: String,
        price: String,
        imageCount: Int,
        category: SecondhandPost.Category?,
        condition: String
    ) -> Bool {
        !normalizedRequiredText(title).isEmpty
            && validPrice(from: price) != nil
            && imageCount > 0
            && category != nil
            && SecondhandPost.Condition(rawValue: condition) != nil
    }

    static func validOriginalPrice(from value: String, sellingPrice: Double) -> Double? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let originalPrice = Double(trimmed),
              originalPrice.isFinite,
              originalPrice <= maximumPrice,
              originalPrice >= sellingPrice
        else { return nil }
        return originalPrice
    }
}

struct CreateSecondhandView: View {

    @Environment(\.dismiss) private var dismiss
    var autoRestoreDraft: Bool = false
    var onCreated: (() -> Void)? = nil
    var onExit: (() -> Void)? = nil
    var onBusyChanged: ((Bool) -> Void)? = nil
    
    // 表单字段
    @State private var title = ""
    @State private var description = ""
    @State private var price = ""
    @State private var originalPrice = ""
    @State private var category: SecondhandPost.Category? = SecondhandCreateFormRules.defaultCategory
    @State private var condition = SecondhandCreateFormRules.defaultCondition
    @State private var isNegotiable = SecondhandCreateFormRules.defaultIsNegotiable
    @State private var selectedImages: [UIImage] = []
    @State private var selectedMentions: [MentionCandidate] = []
    @State private var draftBannerText: String?
    @State private var hasRestoredInitialDraft = false
    @State private var showExitDraftPrompt = false
    @State private var publishRequestID = UUID()
    @State private var isDescriptionFocused = false
    @StateObject private var aiDescriptionModel = SecondhandAIDescriptionViewModel()
    @State private var showAIOverwriteConfirmation = false
    @State private var showAILateOverwriteConfirmation = false
    @State private var pendingAIDescription: String?
    @State private var aiGenerationTask: Task<Void, Never>?
    @State private var hasFinishedCreateFlow = false
    
    // 状态
    @State private var isLoading = false
    @State private var errorMessage: String?
    
    private var canAttemptPublish: Bool {
        SecondhandCreateFormRules.isValid(
            title: title,
            price: price,
            imageCount: selectedImages.count,
            category: category,
            condition: condition
        )
    }

    private var priceLimitMessage: String? {
        if SecondhandCreateFormRules.priceExceedsMaximum(price) {
            return L10n.tr(
                "The selling price cannot exceed \(SecondhandCreateFormRules.maximumPriceText).",
                "卖价不能超过 \(SecondhandCreateFormRules.maximumPriceText)"
            )
        }
        if SecondhandCreateFormRules.priceExceedsMaximum(originalPrice) {
            return L10n.tr(
                "The original price cannot exceed \(SecondhandCreateFormRules.maximumPriceText).",
                "原价不能超过 \(SecondhandCreateFormRules.maximumPriceText)"
            )
        }
        return nil
    }
    
    var body: some View {
        ZStack {
            AppColors.pageBackground
                .ignoresSafeArea()
            
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 20) {
                        PostFormSection(
                            title: L10n.tr("Images (required)", "图片（必填）"),
                            showsTitle: false
                        ) {
                            PostImageSection(selectedImages: $selectedImages)
                        }

                        PostFormSection(title: "物品名称", showsTitle: false) {
                            SecondhandItemNameField(
                                title: $title,
                                iconColor: .secondary
                            )
                        }

                        PostFormSection(title: "详细描述", showsTitle: false) {
                            VStack(spacing: 10) {
                                ZStack(alignment: .bottomTrailing) {
                                    PostTextEditorCard(
                                        text: $description,
                                        placeholder: "描述一下商品的新旧程度、使用情况、交易方式等...",
                                        minHeight: 100,
                                        isFirstResponder: $isDescriptionFocused,
                                        bottomContentInset: 44
                                    )

                                    Button(action: requestAIDescription) {
                                        HStack(spacing: 6) {
                                            if aiDescriptionModel.isGenerating {
                                                ProgressView()
                                                    .controlSize(.small)
                                            } else {
                                                Image(systemName: "sparkles")
                                                    .font(.system(size: 12, weight: .semibold))
                                            }
                                            Text(
                                                aiDescriptionModel.isGenerating
                                                    ? L10n.tr("Generating...", "生成中...")
                                                    : L10n.tr("AI generate", "AI 生成")
                                            )
                                        }
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(
                                            canGenerateAIDescription
                                                ? AppColors.accentStrong
                                                : AppColors.textMuted
                                        )
                                        .padding(.horizontal, 12)
                                        .frame(minHeight: 36)
                                        .background(
                                            canGenerateAIDescription
                                                ? AppColors.accentStrong.opacity(0.10)
                                                : Color.secondary.opacity(0.06)
                                        )
                                        .clipShape(Capsule())
                                        .overlay {
                                            Capsule()
                                                .stroke(
                                                    canGenerateAIDescription
                                                        ? AppColors.accentStrong.opacity(0.45)
                                                        : Color.secondary.opacity(0.18),
                                                    lineWidth: 1
                                                )
                                        }
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(!canGenerateAIDescription)
                                    .padding(12)
                                    .accessibilityLabel(
                                        L10n.tr(
                                            "Generate description with AI",
                                            "使用 AI 生成简介"
                                        )
                                    )
                                }

                                if !canGenerateAIDescription,
                                   !aiDescriptionModel.isGenerating,
                                   !isLoading {
                                    Text(L10n.tr(
                                        "Add a title, valid price, category, condition, and at least one image to use AI.",
                                        "填写商品名称、有效价格、分类、成色并添加至少一张图片后，才能使用 AI 简介。"
                                    ))
                                    .font(.caption)
                                    .foregroundStyle(AppColors.textMuted)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                MentionSuggestionPanel(
                                    text: $description,
                                    selectedMentions: $selectedMentions
                                )

                                if let aiError = aiDescriptionModel.errorMessage {
                                    Label(aiError, systemImage: "exclamationmark.circle")
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundStyle(Color.red)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                        .id("secondhand-description")

                        PostFormSection(
                            title: L10n.tr("Category", "分类"),
                            showsTitle: false
                        ) {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 10) {
                                    ForEach(SecondhandPost.Category.allCases, id: \.rawValue) { option in
                                        PostChipButton(
                                            title: option.displayName,
                                            isSelected: category == option,
                                            selectedColor: .orange
                                        ) {
                                            category = option
                                        }
                                    }
                                }
                            }
                            .padding(.vertical, 4)
                        }

                        SecondhandConditionSection(
                            selection: $condition,
                            showsTitle: false
                        )

                        PostFormSection(title: "价格", showsTitle: false) {
                            SecondhandPriceFields(
                                price: $price,
                                originalPrice: $originalPrice,
                                iconColor: .secondary
                            )
                        }

                        if let priceLimitMessage {
                            Label(priceLimitMessage, systemImage: "exclamationmark.triangle.fill")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Color.red)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        SecondhandNegotiableSection(
                            isNegotiable: $isNegotiable,
                            showsTitle: false
                        )

                        PostFormSection(title: "帖子有效期", showsTitle: false) {
                            Label(
                                "发布后公开展示 30 天，第 14 天会收到提醒，满 30 天自动转为私密内容。",
                                systemImage: "clock.badge.checkmark"
                            )
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(AppColors.textMuted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                            .background(Color.white)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .cheeseInputChrome(cornerRadius: 12)
                        }

                        if let error = errorMessage {
                            Text(error)
                                .foregroundColor(.red)
                                .font(.subheadline)
                        }

                        Spacer(minLength: 40)
                    }
                    .padding()
                }
                .scrollDismissesKeyboard(.interactively)
                .contentShape(Rectangle())
                .dismissKeyboardOnTap()
                .onChange(of: isDescriptionFocused) { _, isFocused in
                    guard isFocused else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                        withAnimation(.easeOut(duration: 0.22)) {
                            proxy.scrollTo("secondhand-description", anchor: .center)
                        }
                    }
                }
            }
        }
        .navigationTitle(L10n.tr("Sell an Item", "出售二手"))
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(action: { attemptClose() }) {
                    PostToolbarIconCircle(icon: "chevron.left")
                }
                .buttonStyle(.plain)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await submit() }
                } label: {
                    if isLoading {
                        ProgressView()
                    } else {
                        Text(L10n.tr("Publish", "发布"))
                            .font(.system(size: 16, weight: .semibold))
                    }
                }
                .foregroundStyle(canAttemptPublish ? AppColors.accentStrong : AppColors.textMuted)
                .disabled(
                    !canAttemptPublish
                        || isLoading
                        || aiDescriptionModel.isGenerating
                )
            }
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
        .onAppear {
            guard autoRestoreDraft, !hasRestoredInitialDraft else { return }
            hasRestoredInitialDraft = true
            restoreDraft(showBanner: true)
        }
        .onDisappear {
            aiGenerationTask?.cancel()
            preserveInterruptedDraftIfNeeded()
        }
        .onChange(of: isLoading) { _, _ in
            reportBusyState()
        }
        .onChange(of: aiDescriptionModel.isGenerating) { _, _ in
            reportBusyState()
        }
        .alert(
            L10n.tr("Replace the current description?", "重新生成简介？"),
            isPresented: $showAIOverwriteConfirmation
        ) {
            Button(L10n.tr("Cancel", "取消"), role: .cancel) {}
            Button(L10n.tr("Replace", "替换")) {
                startAIDescriptionGeneration()
            }
        } message: {
            Text(L10n.tr(
                "The generated text will replace your current description. You can continue editing it afterward.",
                "生成内容会替换当前简介，生成后仍可继续编辑。"
            ))
        }
        .alert(
            L10n.tr("Keep the generated description?", "使用生成的简介？"),
            isPresented: $showAILateOverwriteConfirmation
        ) {
            Button(L10n.tr("Keep my text", "保留我的文字"), role: .cancel) {
                pendingAIDescription = nil
            }
            Button(L10n.tr("Use generated text", "使用生成内容")) {
                if let pendingAIDescription {
                    description = pendingAIDescription
                }
                pendingAIDescription = nil
            }
        } message: {
            Text(L10n.tr(
                "You edited the description while AI was working. Choose which version to keep.",
                "AI 生成期间你修改了简介，请选择要保留的版本。"
            ))
        }
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
        .enableSwipeBackGesture()
        .interceptSwipeBack(when: hasDraftableContent, onAttempt: attemptClose)
    }

    private var canGenerateAIDescription: Bool {
        category != nil
            && SecondhandPost.Condition(rawValue: condition) != nil
            && SecondhandAIDescriptionRules.canGenerate(
                title: title,
                price: SecondhandCreateFormRules.validPrice(from: price),
                imageCount: selectedImages.count,
                isGenerating: aiDescriptionModel.isGenerating,
                isPublishing: isLoading
            )
    }

    private func requestAIDescription() {
        guard canGenerateAIDescription else { return }
        if SecondhandAIDescriptionRules.requiresOverwriteConfirmation(description) {
            showAIOverwriteConfirmation = true
        } else {
            startAIDescriptionGeneration()
        }
    }

    private func startAIDescriptionGeneration() {
        let normalizedTitle = SecondhandCreateFormRules.normalizedRequiredText(title)
        guard canGenerateAIDescription,
              !normalizedTitle.isEmpty,
              let priceValue = SecondhandCreateFormRules.validPrice(from: price),
              let category,
              let selectedCondition = SecondhandPost.Condition(rawValue: condition)
        else { return }
        let descriptionAtRequestStart = description
        let input = SecondhandAIDescriptionInput(
            postID: publishRequestID,
            images: Array(selectedImages.prefix(3)),
            title: normalizedTitle,
            category: category,
            condition: selectedCondition,
            price: priceValue,
            isNegotiable: isNegotiable
        )
        aiGenerationTask?.cancel()
        aiGenerationTask = Task {
            if let generated = await aiDescriptionModel.generate(input: input) {
                guard !Task.isCancelled else { return }
                if SecondhandAIDescriptionRules.canApplyGeneratedDescription(
                    currentDescription: description,
                    descriptionAtRequestStart: descriptionAtRequestStart
                ) {
                    description = generated
                } else {
                    pendingAIDescription = generated
                    showAILateOverwriteConfirmation = true
                }
            }
        }
    }

    private func submit() async {
        guard !isLoading else { return }

        if SecondhandCreateFormRules.priceExceedsMaximum(price) {
            errorMessage = L10n.tr(
                "The selling price cannot exceed \(SecondhandCreateFormRules.maximumPriceText).",
                "卖价不能超过 \(SecondhandCreateFormRules.maximumPriceText)"
            )
            return
        }
        guard let priceValue = SecondhandCreateFormRules.validPrice(from: price) else {
            errorMessage = L10n.tr("Please enter a valid price", "请输入有效价格")
            return
        }
        let trimmedOriginalPrice = originalPrice.trimmingCharacters(in: .whitespacesAndNewlines)
        if SecondhandCreateFormRules.priceExceedsMaximum(originalPrice) {
            errorMessage = L10n.tr(
                "The original price cannot exceed \(SecondhandCreateFormRules.maximumPriceText).",
                "原价不能超过 \(SecondhandCreateFormRules.maximumPriceText)"
            )
            return
        }
        let originalPriceValue = SecondhandCreateFormRules.validOriginalPrice(
            from: originalPrice,
            sellingPrice: priceValue
        )
        if !trimmedOriginalPrice.isEmpty && originalPriceValue == nil {
            errorMessage = "原价必须是大于或等于卖价的有效金额"
            return
        }

        guard !selectedImages.isEmpty else {
            errorMessage = L10n.tr(
                "Please add at least one image before publishing.",
                "发布前请至少添加一张图片。"
            )
            return
        }

        guard let category else {
            errorMessage = L10n.tr("Please choose a category", "请选择分类")
            return
        }
        guard let selectedCondition = SecondhandPost.Condition(rawValue: condition) else {
            errorMessage = L10n.tr("Please choose the item condition", "请选择成色")
            return
        }

        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        let userId: UUID
        do {
            userId = try await AuthService.shared.requireAuthUserId()
        } catch {
            await AuthService.shared.checkSession()
            errorMessage = L10n.tr("Please sign in before posting", "请先登入后再发布")
            return
        }

        let defaultAnonymous = await MainActor.run {
            AuthService.shared.currentUser?.isAnonymousDefault ?? false
        }
        guard let schoolId = await MainActor.run(body: { AuthService.shared.currentUser?.schoolId }) else {
            errorMessage = "请先在个人资料中选择学校后再发布"
            return
        }
        let createInput = SecondhandCreateInput(
            postId: publishRequestID,
            userId: userId,
            schoolId: schoolId,
            title: SecondhandCreateFormRules.normalizedRequiredText(title),
            description: description.trimmingCharacters(in: .whitespacesAndNewlines),
            isAnonymous: defaultAnonymous,
            price: priceValue,
            originalPrice: originalPriceValue,
            category: category,
            condition: selectedCondition,
            isNegotiable: isNegotiable,
            mentionedUserIDs: MentionTextLogic.activeUserIDs(
                in: description,
                selected: selectedMentions
            )
        )

        do {
            let publishedID = try await SecondhandService.shared.publishPost(
                input: createInput,
                images: selectedImages
            )

            await finishPersistedPost(userId: userId, postId: publishedID)
            finishNavigation()
        } catch {
            errorMessage = SecondhandCreatePostError.userFacingMessage(for: error)
        }
    }

    private func saveDraft(showBanner: Bool = true) {
        let payload = SecondhandDraftPayload(
            title: title,
            description: description,
            price: price,
            originalPrice: originalPrice,
            category: category,
            condition: condition,
            isNegotiable: isNegotiable
        )
        CreateDraftStore.save(
            kind: .secondhand,
            title: title,
            subtitle: price.isEmpty ? nil : "CAD \(price)",
            payload: payload
        )
        CreateComposerSessionStore.save(images: selectedImages, for: .secondhand)
        if showBanner {
            showDraftBanner(L10n.tr("Draft saved", "草稿已保存"))
        }
    }

    private func restoreDraft(showBanner: Bool) {
        guard let payload = CreateDraftStore.load(kind: .secondhand, as: SecondhandDraftPayload.self) else {
            return
        }
        title = payload.title
        description = payload.description
        price = payload.price
        originalPrice = payload.originalPrice ?? ""
        category = payload.category
        condition = payload.condition
        isNegotiable = payload.isNegotiable
        selectedImages = CreateComposerSessionStore.images(for: .secondhand)
        if showBanner {
            showDraftBanner(L10n.tr("Draft restored", "草稿已恢复"))
        }
    }

    private func showDraftBanner(_ message: String) {
        withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
            draftBannerText = message
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            withAnimation(.easeInOut(duration: 0.2)) {
                draftBannerText = nil
            }
        }
    }

    private var hasDraftableContent: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !price.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !originalPrice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || category != SecondhandCreateFormRules.defaultCategory
            || condition != SecondhandCreateFormRules.defaultCondition
            || isNegotiable != SecondhandCreateFormRules.defaultIsNegotiable
            || !selectedImages.isEmpty
    }

    private func attemptClose() {
        guard !isLoading, !aiDescriptionModel.isGenerating else { return }
        if hasDraftableContent {
            showExitDraftPrompt = true
        } else {
            finishExitNavigation(preservingDraft: false)
        }
    }

    private func finishPersistedPost(userId: UUID, postId: UUID) async {
        await SecondhandService.shared.fetchItems()
        CreateDraftStore.clear(.secondhand)
        CreateComposerSessionStore.clear(.secondhand)
        PostFeatureEvents.postDidChange(
            kind: .secondhand,
            authorId: userId,
            postId: postId,
            change: .created
        )
    }

    private func finishNavigation() {
        hasFinishedCreateFlow = true
        if let onCreated {
            onCreated()
        } else {
            dismiss()
        }
    }

    private func finishExitNavigation(preservingDraft: Bool) {
        hasFinishedCreateFlow = true
        if preservingDraft {
            CreateComposerSessionStore.markResumable(.secondhand)
        }
        if let onExit {
            onExit()
        } else {
            dismiss()
        }
    }

    private func preserveInterruptedDraftIfNeeded() {
        guard !hasFinishedCreateFlow,
              hasDraftableContent,
              !isLoading
        else { return }
        saveDraft(showBanner: false)
    }

    private func reportBusyState() {
        onBusyChanged?(isLoading || aiDescriptionModel.isGenerating)
    }

}

#Preview {
    NavigationStack {
        CreateSecondhandView()
            .environmentObject(AuthService.shared)
    }
}
