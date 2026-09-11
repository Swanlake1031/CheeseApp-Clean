//
//  CreatePostView.swift
//  CheeseApp
//
//  ➕ 创建帖子页面
//  选择发布类型并导航到具体表单
//

import SwiftUI

struct CreatePostView: View {
    @Environment(\.dismiss) private var dismiss
    var onDismiss: (() -> Void)?
    var onOpenComposer: ((PostKind, Bool) -> Void)?
    @State private var selectedType: PostKind? = nil
    @State private var showDraftBox = false
    @State private var pendingDraftKind: PostKind?
    @State private var hasAppliedSessionResume = false

    init(
        onDismiss: (() -> Void)? = nil,
        onOpenComposer: ((PostKind, Bool) -> Void)? = nil
    ) {
        self.onDismiss = onDismiss
        self.onOpenComposer = onOpenComposer
    }
    
    var body: some View {
        NavigationStack {
            ZStack {
                AppColors.pageBackground
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    createHeader

                    VStack(spacing: 2) {
                        ForEach([PostKind.forum, .secondhand], id: \.self) { type in
                            PostTypeCard(type: type, isSelected: selectedType == type) {
                                selectedType = type
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                }
                .padding(.top, 8)
            }
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if selectedType != nil {
                    continueButton
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeOut(duration: 0.2), value: selectedType)
            .sheet(
                isPresented: $showDraftBox,
                onDismiss: {
                    guard let pendingDraftKind else { return }
                    self.pendingDraftKind = nil
                    openComposer(kind: pendingDraftKind, autoRestoreDraft: true)
                }
            ) {
                CreateDraftBoxSheet { kind in
                    pendingDraftKind = kind
                }
            }
            .onAppear {
                resumeInterruptedComposerIfNeeded()
            }
        }
    }

    private var createHeader: some View {
        HStack(spacing: 0) {
            Button(action: closeComposer) {
                Image(systemName: "xmark")
                    .font(.system(size: 19, weight: .medium))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(AppColors.textMuted)
            .accessibilityLabel(L10n.tr("Close", "关闭"))

            Spacer()

            Text(L10n.tr("Create Post", "发布帖子"))
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(AppColors.textPrimary)

            Spacer()

            Button {
                showDraftBox = true
            } label: {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 20, weight: .regular))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(AppColors.textMuted)
            .accessibilityLabel(L10n.tr("Drafts", "草稿箱"))
        }
        .padding(.horizontal, 10)
        .frame(height: 52)
    }

    private var continueButton: some View {
        Button {
            guard let selectedType else { return }
            openComposer(kind: selectedType, autoRestoreDraft: false)
        } label: {
            Text(L10n.tr("Continue", "继续"))
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(AppColors.accent)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .background(AppColors.pageBackground)
    }
    
    private func openComposer(kind: PostKind, autoRestoreDraft: Bool) {
        if let onOpenComposer {
            onOpenComposer(kind, autoRestoreDraft)
        }
    }

    private func closeComposer() {
        if let onDismiss {
            onDismiss()
        } else {
            dismiss()
        }
    }

    private func resumeInterruptedComposerIfNeeded() {
        guard !hasAppliedSessionResume else { return }
        hasAppliedSessionResume = true
        guard let kind = CreateComposerSessionStore.resumableKind,
              CreateDraftStore.hasDraft(kind)
        else { return }

        selectedType = kind
        openComposer(kind: kind, autoRestoreDraft: true)
    }
}

private extension PostKind {
    var createTitle: String {
        switch self {
        case .secondhand: return L10n.tr("Sell an Item", "二手出售")
        case .forum: return L10n.tr("Forum Post", "论坛贴文")
        }
    }
    
    var createDraftTitle: String {
        switch self {
        case .secondhand: return L10n.tr("Secondhand", "二手")
        case .forum: return L10n.tr("Forum", "论坛")
        }
    }
    
}

// MARK: - 帖子类型卡片
struct PostTypeCard: View {
    let type: PostKind
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                // 图标
                Image(systemName: type.icon)
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(isSelected ? AppColors.textPrimary : AppColors.textMuted)
                    .frame(width: 32, height: 32)
                
                // 文字
                Text(type.createTitle)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(AppColors.textPrimary)
                
                Spacer()
                
                // 选中指示
                Image(systemName: "checkmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AppColors.textPrimary)
                    .opacity(isSelected ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 8)
            .frame(minHeight: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

struct CreateDraftBoxSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var drafts: [CreateDraftMeta] = []

    let onOpenDraft: (PostKind) -> Void

    var body: some View {
        NavigationStack {
            ZStack {
                AppColors.pageBackground
                    .ignoresSafeArea()

                Group {
                    if drafts.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "tray")
                                .font(.system(size: 34))
                                .foregroundStyle(AppColors.textMuted)
                            Text(L10n.tr("No drafts yet", "还没有草稿"))
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(AppColors.textPrimary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollView(showsIndicators: false) {
                            LazyVStack(spacing: 12) {
                                ForEach(drafts) { draft in
                                    Button {
                                        onOpenDraft(draft.kind)
                                        dismiss()
                                    } label: {
                                        HStack(spacing: 12) {
                                            VStack(alignment: .leading, spacing: 4) {
                                                Text(draft.kind.createDraftTitle)
                                                    .font(.system(size: 14, weight: .semibold))
                                                    .foregroundStyle(AppColors.textPrimary)
                                                Text(draft.title.isEmpty ? L10n.tr("Untitled", "未命名草稿") : draft.title)
                                                    .font(.system(size: 13))
                                                    .foregroundStyle(AppColors.textMuted)
                                                    .lineLimit(1)
                                                if let subtitle = draft.subtitle, !subtitle.isEmpty {
                                                    Text(subtitle)
                                                        .font(.system(size: 12))
                                                        .foregroundStyle(AppColors.textMuted)
                                                        .lineLimit(1)
                                                }
                                            }
                                            Spacer()
                                            Image(systemName: "chevron.right")
                                                .font(.system(size: 12, weight: .semibold))
                                                .foregroundStyle(AppColors.textMuted)
                                        }
                                        .padding(16)
                                        .background(AppColors.cardBackground)
                                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                                        .cheeseCardChrome(cornerRadius: 16)
                                    }
                                    .buttonStyle(.plain)
                                    .swipeActions {
                                        Button(role: .destructive) {
                                            CreateDraftStore.clear(draft.kind)
                                            CreateComposerSessionStore.clear(draft.kind)
                                            reloadDrafts()
                                        } label: {
                                            Label(L10n.tr("Delete", "删除"), systemImage: "trash")
                                        }
                                    }
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 16)
                        }
                    }
                }
            }
            .navigationTitle(L10n.tr("Draft Box", "草稿箱"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(AppColors.pageBackground, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L10n.tr("Done", "完成")) {
                        dismiss()
                    }
                    .foregroundStyle(AppColors.textPrimary)
                    .buttonStyle(.plain)
                }
            }
            .onAppear {
                reloadDrafts()
            }
        }
    }

    private func reloadDrafts() {
        drafts = CreateDraftStore.listMetas()
    }
}

#Preview {
    CreatePostView()
}
