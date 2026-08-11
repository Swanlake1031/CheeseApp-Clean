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
    static let defaultCategory: SecondhandPost.Category = .homeAppliances
    static let defaultCondition = SecondhandPost.Condition.good.rawValue
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

    static func isValid(title: String, price: String, imageCount: Int) -> Bool {
        !normalizedRequiredText(title).isEmpty
            && validPrice(from: price) != nil
            && imageCount > 0
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
    
    // 表单字段
    @State private var title = ""
    @State private var description = ""
    @State private var price = ""
    @State private var originalPrice = ""
    @State private var category = SecondhandCreateFormRules.defaultCategory
    @State private var condition = SecondhandCreateFormRules.defaultCondition
    @State private var isNegotiable = SecondhandCreateFormRules.defaultIsNegotiable
    @State private var selectedImages: [UIImage] = []
    @State private var selectedMentions: [MentionCandidate] = []
    @State private var draftBannerText: String?
    @State private var hasRestoredInitialDraft = false
    @State private var showExitDraftPrompt = false
    @State private var publishRequestID = UUID()
    @State private var isDescriptionFocused = false
    
    // 状态
    @State private var isLoading = false
    @State private var errorMessage: String?
    
    private var canAttemptPublish: Bool {
        !SecondhandCreateFormRules.normalizedRequiredText(title).isEmpty
            && !price.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !selectedImages.isEmpty
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
                        SecondhandBasicInfoSection(
                            title: $title,
                            price: $price,
                            originalPrice: $originalPrice
                        )

                        if let priceLimitMessage {
                            Label(priceLimitMessage, systemImage: "exclamationmark.triangle.fill")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Color.red)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        PostFormSection(title: L10n.tr("Images (required)", "图片（必填）")) {
                            VStack(alignment: .leading, spacing: 8) {
                                PostImageSection(selectedImages: $selectedImages)
                                Text(L10n.tr(
                                    "Add at least one clear image of the item.",
                                    "请至少添加一张清晰的商品图片。"
                                ))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                        }

                        PostFormSection(title: L10n.tr("Category", "分类")) {
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

                        SecondhandConditionSection(selection: $condition)

                        SecondhandNegotiableSection(isNegotiable: $isNegotiable)

                        PostFormSection(title: "详细描述") {
                            VStack(spacing: 10) {
                                PostTextEditorCard(
                                    text: $description,
                                    placeholder: "描述一下商品的新旧程度、使用情况、交易方式等...",
                                    minHeight: 100,
                                    isFirstResponder: $isDescriptionFocused
                                )
                                MentionSuggestionPanel(
                                    text: $description,
                                    selectedMentions: $selectedMentions
                                )
                            }
                        }
                        .id("secondhand-description")

                        PostFormSection(title: "帖子有效期") {
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
                .disabled(!canAttemptPublish || isLoading)
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
        .enableSwipeBackGesture()
        .interceptSwipeBack(when: hasDraftableContent, onAttempt: attemptClose)
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
            condition: SecondhandPost.Condition(normalizing: condition),
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
        category = payload.category ?? SecondhandCreateFormRules.defaultCategory
        condition = payload.condition
        isNegotiable = payload.isNegotiable
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
        guard !isLoading else { return }
        if hasDraftableContent {
            showExitDraftPrompt = true
        } else {
            finishExitNavigation()
        }
    }

    private func finishPersistedPost(userId: UUID, postId: UUID) async {
        await SecondhandService.shared.fetchItems()
        CreateDraftStore.clear(.secondhand)
        PostFeatureEvents.postDidChange(
            kind: .secondhand,
            authorId: userId,
            postId: postId,
            change: .created
        )
    }

    private func finishNavigation() {
        if let onCreated {
            onCreated()
        } else {
            dismiss()
        }
    }

    private func finishExitNavigation() {
        if let onExit {
            onExit()
        } else {
            dismiss()
        }
    }

}

#Preview {
    NavigationStack {
        CreateSecondhandView()
            .environmentObject(AuthService.shared)
    }
}
