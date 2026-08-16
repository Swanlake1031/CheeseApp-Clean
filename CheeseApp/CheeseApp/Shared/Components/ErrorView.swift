//
//  ErrorView.swift
//  CheeseApp
//
//  🎯 错误视图组件
//

import SwiftUI
import UIKit

// ============================================
// 错误视图
// ============================================

struct ErrorView: View {
    let message: String
    let retryAction: (() -> Void)?
    
    init(_ message: String, retryAction: (() -> Void)? = nil) {
        self.message = message
        self.retryAction = retryAction
    }
    
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48))
                .foregroundColor(AppColors.warning)
            
            Text(message)
                .font(AppFonts.body)
                .foregroundColor(AppColors.secondaryText)
                .multilineTextAlignment(.center)
            
            if let retry = retryAction {
                Button("重试", action: retry)
                    .buttonStyle(.borderedProminent)
                    .tint(AppColors.primary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    ErrorView("加载失败，请检查网络") {}
}

// ============================================
// 帖子详情页统一顶部工具栏
// ============================================

struct PostDetailTopBar<Trailing: View>: View {
    let title: String
    let onBack: () -> Void
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        ZStack {
            HStack(spacing: 10) {
                Button(action: onBack) {
                    PostToolbarIconCircle(icon: "chevron.left")
                }
                .buttonStyle(.plain)

                Spacer()

                HStack(spacing: 10) {
                    trailing()
                }
            }

            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(AppColors.textPrimary)
                .lineLimit(1)
                .padding(.horizontal, 72)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .background(AppColors.pageBackground.opacity(0.96))
    }
}

struct CheeseInlineTopBar<Leading: View, Center: View, Trailing: View>: View {
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var center: () -> Center
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        ZStack {
            HStack(spacing: 10) {
                leading()

                Spacer(minLength: 0)

                HStack(spacing: 10) {
                    trailing()
                }
            }

            center()
                .padding(.horizontal, 72)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .background(AppColors.pageBackground)
    }
}

struct PostToolbarIconCircle: View {
    let icon: String
    var tint: Color = AppColors.textPrimary
    var size: CGFloat = 18
    var frameSize: CGFloat = 30

    var body: some View {
        Image(systemName: icon)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: frameSize, height: frameSize)
            .contentShape(Rectangle())
    }
}

struct PostContactComposerSheet: View {
    let badgeText: String
    let title: String
    let helperText: String
    let previewTitle: String
    let previewSubtitle: String?
    let previewSummary: String?
    let previewImageURL: String?
    let placeholder: String
    let sendButtonTitle: String
    let accentColor: Color
    let onSend: (String) async -> Bool

    @Environment(\.dismiss) private var dismiss
    @FocusState private var isEditorFocused: Bool
    @State private var noteText = ""
    @State private var isSending = false

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(badgeText)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(accentColor)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(accentColor.opacity(0.12))
                            .clipShape(Capsule())

                        Text(title)
                            .font(.system(size: 28, weight: .bold))
                            .foregroundStyle(AppColors.textPrimary)

                        Text(helperText)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(AppColors.textMuted)
                            .lineSpacing(4)
                    }

                    previewCard

                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text(L10n.tr("Message", "附言"))
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(AppColors.textPrimary)
                            Spacer()
                            Text(L10n.tr("Optional", "可选"))
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(AppColors.textMuted)
                        }

                        ZStack(alignment: .topLeading) {
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .fill(Color.white)

                            if noteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                Text(placeholder)
                                    .font(.system(size: 15))
                                    .foregroundStyle(AppColors.textMuted)
                                    .padding(.horizontal, 18)
                                    .padding(.vertical, 16)
                            }

                            TextEditor(text: $noteText)
                                .focused($isEditorFocused)
                                .font(.system(size: 15))
                                .foregroundStyle(AppColors.textPrimary)
                                .scrollContentBackground(.hidden)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                .frame(minHeight: 156)
                                .background(Color.clear)
                        }
                        .overlay(
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .stroke(Color.black.opacity(0.06), lineWidth: 1)
                        )

                        Text(L10n.tr(
                            "Leave it blank if you just want to send the card directly.",
                            "如果你只想直接发卡片，也可以留空。"
                        ))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(AppColors.textMuted)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    dismissComposerKeyboard()
                }
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 96)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(AppColors.pageBackground.ignoresSafeArea())
            .navigationTitle(L10n.tr("Contact", "发起联系"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.tr("Cancel", "取消")) {
                        dismiss()
                    }
                    .disabled(isSending)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    Button {
                        Task { await submit() }
                    } label: {
                        HStack(spacing: 8) {
                            if isSending {
                                ProgressView()
                                    .tint(.black)
                            } else {
                                Image(systemName: "paperplane.fill")
                                    .font(.system(size: 14, weight: .semibold))
                            }

                            Text(sendButtonTitle)
                                .font(.system(size: 15, weight: .bold))
                        }
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(accentColor)
                        .clipShape(Capsule(style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(isSending)
                    .padding(.horizontal, 20)
                    .padding(.top, 6)
                    .padding(.bottom, 6)
                }
                .background(.ultraThinMaterial)
            }
        }
        .dismissKeyboardOnTap()
        .presentationDragIndicator(.visible)
    }

    private var previewCard: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Text(previewTitle)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(AppColors.textPrimary)
                    .lineLimit(2)

                if let previewSubtitle,
                   !previewSubtitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(previewSubtitle)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(accentColor)
                        .lineLimit(2)
                }

                if let previewSummary,
                   !previewSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(previewSummary)
                        .font(.system(size: 13))
                        .foregroundStyle(AppColors.textMuted)
                        .lineSpacing(3)
                        .lineLimit(3)
                }
            }

            if let previewImageURL,
               let url = URL(string: previewImageURL),
               !previewImageURL.isEmpty {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    default:
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(accentColor.opacity(0.16))
                            .overlay {
                                Image(systemName: "bubble.left.and.bubble.right.fill")
                                    .font(.system(size: 20, weight: .semibold))
                                    .foregroundStyle(accentColor.opacity(0.8))
                            }
                    }
                }
                .frame(width: 92, height: 92)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color.white)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.black.opacity(0.06), lineWidth: 1)
        )
    }

    @MainActor
    private func submit() async {
        guard !isSending else { return }
        isSending = true
        defer { isSending = false }

        let success = await onSend(noteText.trimmingCharacters(in: .whitespacesAndNewlines))
        if success {
            dismiss()
        }
    }

    private func dismissComposerKeyboard() {
        isEditorFocused = false
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}

private struct CheesePageTopBarModifier<Trailing: View>: ViewModifier {
    @Environment(\.dismiss) private var dismiss

    let title: String
    let installsSwipeBackGesture: Bool
    @ViewBuilder let trailing: () -> Trailing

    @ViewBuilder
    func body(content: Content) -> some View {
        let presentedContent = content
            .navigationBarBackButtonHidden(true)
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .top) {
                PostDetailTopBar(title: title, onBack: { dismiss() }) {
                    trailing()
                }
            }

        if installsSwipeBackGesture {
            presentedContent.enableSwipeBackGesture()
        } else {
            presentedContent
        }
    }
}

extension View {
    func cheesePageTopBar(
        title: String,
        installsSwipeBackGesture: Bool = true
    ) -> some View {
        modifier(CheesePageTopBarModifier(
            title: title,
            installsSwipeBackGesture: installsSwipeBackGesture
        ) {
            EmptyView()
        })
    }

    func cheesePageTopBar<Trailing: View>(
        title: String,
        installsSwipeBackGesture: Bool = true,
        @ViewBuilder trailing: @escaping () -> Trailing
    ) -> some View {
        modifier(CheesePageTopBarModifier(
            title: title,
            installsSwipeBackGesture: installsSwipeBackGesture,
            trailing: trailing
        ))
    }
}
