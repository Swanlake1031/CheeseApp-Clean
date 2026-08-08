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
    @State private var selectedType: PostKind? = nil
    @State private var navigateToForm = false
    @State private var showDraftBox = false
    @State private var autoRestoreDraftKind: PostKind?
    
    var body: some View {
        NavigationStack {
            ZStack {
                AppColors.pageBackground
                    .ignoresSafeArea()
                
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 24) {
                        // 标题
                        VStack(spacing: 8) {
                            Text(L10n.tr("What would you like to post?", "你想发布什么？"))
                                .font(.system(size: 24, weight: .bold))
                                .foregroundStyle(AppColors.textPrimary)
                            
                            Text(L10n.tr("Choose a category to get started", "先选择一个分类开始"))
                                .font(.system(size: 15))
                                .foregroundStyle(AppColors.textMuted)
                        }
                        .padding(.top, 20)
                        
                        // 发布类型选择
                        VStack(spacing: 14) {
                            ForEach(PostKind.allCases, id: \.self) { type in
                                PostTypeCard(
                                    type: type,
                                    isSelected: selectedType == type
                                ) {
                                    selectedType = type
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        
                        Spacer(minLength: 12)
                    }
                }

            }
            .navigationTitle(L10n.tr("Create Post", "发布帖子"))
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if selectedType != nil {
                    continueButton
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeOut(duration: 0.2), value: selectedType)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(L10n.tr("Cancel", "取消")) {
                        dismiss()
                    }
                    .foregroundStyle(AppColors.accentStrong)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L10n.tr("Drafts", "草稿箱")) {
                        showDraftBox = true
                    }
                    .foregroundStyle(AppColors.accentStrong)
                }
            }
            .navigationDestination(isPresented: $navigateToForm) {
                if let type = selectedType {
                    destinationView(for: type)
                }
            }
            .sheet(isPresented: $showDraftBox) {
                CreateDraftBoxSheet { kind in
                    autoRestoreDraftKind = kind
                    selectedType = kind
                    navigateToForm = true
                }
            }
        }
    }

    private var continueButton: some View {
        Button {
            navigateToForm = true
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
    
    // 根据类型返回对应的创建视图
    @ViewBuilder
    private func destinationView(for type: PostKind) -> some View {
        switch type {
        case .secondhand:
            let shouldAutoRestore = autoRestoreDraftKind == .secondhand
            CreateSecondhandView(
                autoRestoreDraft: shouldAutoRestore,
                onCreated: finishCreateFlow,
                onExit: finishCreateFlow
            )
        case .forum:
            let shouldAutoRestore = autoRestoreDraftKind == .forum
            CreateForumView(
                autoRestoreDraft: shouldAutoRestore,
                onCreated: finishCreateFlow,
                onExit: finishCreateFlow
            )
        }
    }

    private func finishCreateFlow() {
        autoRestoreDraftKind = nil
        dismiss()
    }
}

private extension PostKind {
    var createTitle: String {
        switch self {
        case .secondhand: return L10n.tr("Sell an Item", "二手出售")
        case .forum: return L10n.tr("Forum Post", "论坛贴文")
        }
    }
    
    var createSubtitle: String {
        switch self {
        case .secondhand: return L10n.tr("Sell school supplies, electronics, furniture...", "出售学业用品、电子产品、家具等")
        case .forum: return L10n.tr("Share thoughts, ask questions, confess...", "分享想法、提问、匿名发帖")
        }
    }

    var createDraftTitle: String {
        switch self {
        case .secondhand: return L10n.tr("Secondhand", "二手")
        case .forum: return L10n.tr("Forum", "论坛")
        }
    }
    
    var createColor: Color {
        switch self {
        case .secondhand:
            return AppColors.categoryColor(for: "secondhand")
        case .forum:
            return AppColors.categoryColor(for: "forum")
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
            HStack(spacing: 16) {
                // 图标
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(type.createColor.opacity(0.15))
                        .frame(width: 56, height: 56)
                    
                    Image(systemName: type.icon)
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(type.createColor)
                }
                
                // 文字
                VStack(alignment: .leading, spacing: 4) {
                    Text(type.createTitle)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(AppColors.textPrimary)
                    
                    Text(type.createSubtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(AppColors.textMuted)
                        .lineLimit(1)
                }
                
                Spacer()
                
                // 选中指示
                ZStack {
                    Circle()
                        .stroke(isSelected ? type.createColor : Color.gray.opacity(0.3), lineWidth: 2)
                        .frame(width: 24, height: 24)
                    
                    if isSelected {
                        Circle()
                            .fill(type.createColor)
                            .frame(width: 14, height: 14)
                    }
                }
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(AppColors.cardBackground)
            )
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .cheeseCardChrome(cornerRadius: 18)
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(type.createColor, lineWidth: 2)
                }
            }
        }
        .buttonStyle(CheeseContainerButtonStyle())
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
