//
//  QuickActionsRowView.swift
//  CheeseApp
//
//  首页紧凑板块导航。顺序由 HomeFeedTab 统一定义，避免分页与顶栏漂移。
//

import SwiftUI

struct HomeModuleGridView: View {
    let selectedModule: HomeFeedTab
    let onSelect: (HomeFeedTab) -> Void
    let onMenuTap: () -> Void
    let onSearchTap: () -> Void

    private let modules = HomeFeedTab.allCases

    init(
        selectedModule: HomeFeedTab,
        onSelect: @escaping (HomeFeedTab) -> Void,
        onMenuTap: @escaping () -> Void = {},
        onSearchTap: @escaping () -> Void = {}
    ) {
        self.selectedModule = selectedModule
        self.onSelect = onSelect
        self.onMenuTap = onMenuTap
        self.onSearchTap = onSearchTap
    }

    var body: some View {
        ZStack {
            HStack(spacing: 6) {
                ForEach(modules, id: \.self) { module in
                    Button {
                        onSelect(module)
                    } label: {
                        VStack(spacing: 3) {
                            HStack(spacing: 4) {
                                Image(systemName: module.homeIcon)
                                    .font(.system(size: 12, weight: .bold))
                                Text(module.title)
                                    .font(.system(size: 13, weight: .bold))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.75)
                            }
                            .foregroundStyle(
                                selectedModule == module
                                    ? AppColors.textPrimary
                                    : AppColors.textMuted
                            )

                            Capsule()
                                .fill(selectedModule == module ? AppColors.accentStrong : Color.clear)
                                .frame(width: 24, height: 3)
                        }
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selectedModule == module ? .isSelected : [])
                }
            }
            .frame(width: 228)

            HStack {
                Button(action: onMenuTap) {
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(AppColors.textPrimary)
                        .frame(width: 36, height: 40)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.tr("Open navigation", "打开导航"))

                Spacer(minLength: 0)

                Button(action: onSearchTap) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(AppColors.textPrimary)
                        .frame(width: 36, height: 40)
                        .offset(y: -2)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.tr("Open search", "打开搜索"))
            }
        }
        .frame(height: 44)
    }
}

struct HomeNavigationDrawerContainer: View {
    let openRequest: UInt
    let boards: [ForumBoard]
    let onPresentationChange: (Bool) -> Void
    let onForumTap: () -> Void
    let onBoardTap: (ForumBoard) -> Void
    let onSecondhandTap: () -> Void
    let onSecondhandCategoryTap: (SecondhandPost.Category) -> Void
    let onCourseTap: () -> Void
    let onCourseRadarTap: () -> Void

    @State private var isOpen = false
    @State private var reveal: CGFloat = 0
    @State private var isClosing = false

    var body: some View {
        ZStack {
            if !isOpen {
                edgeGestureZone
                    .zIndex(0)
            }

            if isOpen || reveal > 0 || isClosing {
                drawerOverlay
                    .zIndex(1)
            }
        }
        .onChange(of: openRequest) { _, _ in
            openDrawer(animation: .easeOut(duration: 0.22))
        }
    }

    private var drawerOverlay: some View {
        GeometryReader { proxy in
            let drawerWidth = min(304, proxy.size.width * 0.80)
            let boundedReveal = min(max(reveal, 0), drawerWidth)
            let revealProgress = isOpen ? 1 : boundedReveal / max(drawerWidth, 1)

            ZStack(alignment: .leading) {
                Color.black.opacity(0.30 * revealProgress)
                    .ignoresSafeArea()
                    .onTapGesture(perform: closeDrawer)

                HomeNavigationDrawerView(
                    boards: boards,
                    topSafeAreaInset: max(proxy.safeAreaInsets.top, 52),
                    onClose: closeDrawer,
                    onForumTap: {
                        closeDrawer()
                        onForumTap()
                    },
                    onBoardTap: { board in
                        closeDrawer()
                        onBoardTap(board)
                    },
                    onSecondhandTap: {
                        closeDrawer()
                        onSecondhandTap()
                    },
                    onSecondhandCategoryTap: { category in
                        closeDrawer()
                        onSecondhandCategoryTap(category)
                    },
                    onCourseTap: {
                        closeDrawer()
                        onCourseTap()
                    },
                    onCourseRadarTap: {
                        closeDrawer()
                        onCourseRadarTap()
                    }
                )
                .frame(width: drawerWidth)
                .frame(maxHeight: .infinity)
                .clipShape(
                    UnevenRoundedRectangle(
                        bottomTrailingRadius: 28,
                        topTrailingRadius: 28
                    )
                )
                .compositingGroup()
                .shadow(color: .black.opacity(0.18), radius: 24, x: 8)
                .offset(x: isOpen ? 0 : -drawerWidth + boundedReveal)
                .transition(.move(edge: .leading))
            }
        }
        .ignoresSafeArea()
        .transition(.asymmetric(insertion: .opacity, removal: .identity))
    }

    private var edgeGestureZone: some View {
        HStack(spacing: 0) {
            Color.clear
                .frame(width: 24)
                .contentShape(Rectangle())
                .gesture(openGesture)
            Spacer(minLength: 0)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    private var openGesture: some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .global)
            .onChanged { value in
                let horizontal = value.translation.width
                let vertical = value.translation.height
                guard horizontal > 0, abs(horizontal) > abs(vertical) else { return }
                reveal = horizontal
            }
            .onEnded { value in
                let horizontal = max(value.translation.width, 0)
                let vertical = value.translation.height
                guard horizontal > 0, abs(horizontal) > abs(vertical) else {
                    closeDrawer()
                    return
                }

                let predictedHorizontal = max(value.predictedEndTranslation.width, 0)
                if horizontal >= 88 || predictedHorizontal >= 170 {
                    openDrawer(animation: .interactiveSpring(response: 0.28, dampingFraction: 0.88))
                } else {
                    closeDrawer()
                }
            }
    }

    private func openDrawer(animation: Animation) {
        guard !isOpen else { return }
        isClosing = false
        onPresentationChange(true)

        withAnimation(animation) {
            isOpen = true
            reveal = 0
        }
    }

    private func closeDrawer() {
        guard isOpen || reveal > 0 else { return }
        isClosing = true

        withAnimation(
            .easeInOut(duration: 0.24),
            completionCriteria: .logicallyComplete
        ) {
            isOpen = false
            reveal = 0
        } completion: {
            guard !isOpen else { return }
            isClosing = false
            onPresentationChange(false)
        }
    }
}

struct HomeNavigationDrawerView: View {
    let boards: [ForumBoard]
    let topSafeAreaInset: CGFloat
    let onClose: () -> Void
    let onForumTap: () -> Void
    let onBoardTap: (ForumBoard) -> Void
    let onSecondhandTap: () -> Void
    let onSecondhandCategoryTap: (SecondhandPost.Category) -> Void
    let onCourseTap: () -> Void
    let onCourseRadarTap: () -> Void

    @State private var isForumExpanded = true
    @State private var isSecondhandExpanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                Image("CheeseAppLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 42, height: 42)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .cheeseInputChrome(cornerRadius: 12)
                    .accessibilityLabel(L10n.tr("Cheese app logo", "奶酪 App Logo"))

                VStack(alignment: .leading, spacing: 2) {
                    Text("Cheese")
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .foregroundStyle(AppColors.textPrimary)
                    Text(L10n.tr("Campus navigation", "校园导航"))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(AppColors.textMuted)
                }

                Spacer()

                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(AppColors.textPrimary)
                        .frame(width: 34, height: 34)
                        .background(Color.white)
                        .clipShape(Circle())
                        .overlay {
                            Circle()
                                .stroke(Color.black.opacity(0.10), lineWidth: 1)
                        }
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 18)
            .padding(.top, topSafeAreaInset + 10)
            .padding(.bottom, 14)

            Divider().overlay(AppColors.divider)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    forumNavigationSection

                    Divider()
                        .overlay(AppColors.divider)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 14)

                    secondhandNavigationSection

                    navigationRow(
                        title: L10n.tr("Course ratings", "课程评分"),
                        subtitle: L10n.tr("Courses, professors and outlines", "课程、教授与大纲"),
                        icon: "graduationcap.fill",
                        action: onCourseTap
                    )

                    navigationRow(
                        title: L10n.tr("Cheese Radar Registration", "奶酪雷达抢课"),
                        subtitle: L10n.tr("Track course seats in real time", "实时监控课程空位"),
                        icon: "bolt.fill",
                        action: onCourseRadarTap
                    )
                }
                .padding(.vertical, 18)
            }
        }
        .background(Color.white)
    }

    private var forumNavigationSection: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Button(action: onForumTap) {
                    HStack(spacing: 12) {
                        Image(systemName: "bubble.left.and.bubble.right.fill")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(AppColors.link)
                            .frame(width: 34, height: 34)
                            .background(AppColors.accent.opacity(0.16))
                            .clipShape(Circle())

                        VStack(alignment: .leading, spacing: 2) {
                            Text(L10n.tr("Forum", "论坛"))
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(AppColors.textPrimary)
                            Text(L10n.tr("Campus conversations", "校园话题讨论"))
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(AppColors.textMuted)
                        }

                        Spacer(minLength: 0)
                    }
                    .padding(.leading, 18)
                    .frame(height: 56)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button {
                    withAnimation(.easeInOut(duration: 0.20)) {
                        isForumExpanded.toggle()
                    }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(AppColors.textMuted)
                        .rotationEffect(.degrees(isForumExpanded ? 180 : 0))
                        .frame(width: 48, height: 56)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    isForumExpanded
                        ? L10n.tr("Collapse forum boards", "收起论坛板块")
                        : L10n.tr("Expand forum boards", "展开论坛板块")
                )
            }

            if isForumExpanded {
                VStack(spacing: 2) {
                    ForEach(boards.filter { $0.status != .archived }) { board in
                        Button {
                            onBoardTap(board)
                        } label: {
                            HStack(spacing: 11) {
                                Image(systemName: board.icon)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(AppColors.link)
                                    .frame(width: 28, height: 28)
                                    .background(AppColors.accent.opacity(0.12))
                                    .clipShape(Circle())

                                Text(board.name)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(AppColors.textPrimary)
                                    .lineLimit(1)

                                Spacer(minLength: 0)
                            }
                            .padding(.leading, 38)
                            .padding(.trailing, 18)
                            .frame(height: 42)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.bottom, 6)
                .transition(.move(edge: .top))
            }
        }
    }

    private var secondhandNavigationSection: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Button(action: onSecondhandTap) {
                    HStack(spacing: 12) {
                        Image(systemName: "bag.fill")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(AppColors.link)
                            .frame(width: 34, height: 34)
                            .background(AppColors.accent.opacity(0.16))
                            .clipShape(Circle())

                        VStack(alignment: .leading, spacing: 2) {
                            Text(L10n.tr("Secondhand", "二手"))
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(AppColors.textPrimary)
                            Text(L10n.tr("Campus marketplace", "校园闲置交易"))
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(AppColors.textMuted)
                        }

                        Spacer(minLength: 0)
                    }
                    .padding(.leading, 18)
                    .frame(height: 56)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button {
                    withAnimation(.easeInOut(duration: 0.20)) {
                        isSecondhandExpanded.toggle()
                    }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(AppColors.textMuted)
                        .rotationEffect(.degrees(isSecondhandExpanded ? 180 : 0))
                        .frame(width: 48, height: 56)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    isSecondhandExpanded
                        ? L10n.tr("Collapse secondhand categories", "收起二手分类")
                        : L10n.tr("Expand secondhand categories", "展开二手分类")
                )
            }

            if isSecondhandExpanded {
                VStack(spacing: 2) {
                    ForEach(SecondhandPost.Category.allCases, id: \.rawValue) { category in
                        Button {
                            onSecondhandCategoryTap(category)
                        } label: {
                            HStack(spacing: 11) {
                                Image(systemName: category.iconName)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(AppColors.link)
                                    .frame(width: 28, height: 28)
                                    .background(AppColors.accent.opacity(0.12))
                                    .clipShape(Circle())

                                Text(category.displayName)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(AppColors.textPrimary)

                                Spacer(minLength: 0)
                            }
                            .padding(.leading, 38)
                            .padding(.trailing, 18)
                            .frame(height: 42)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.bottom, 6)
                .transition(.move(edge: .top))
            }
        }
    }

    private func navigationRow(
        title: String,
        subtitle: String,
        icon: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(AppColors.link)
                    .frame(width: 34, height: 34)
                    .background(AppColors.accent.opacity(0.16))
                    .clipShape(Circle())

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(AppColors.textPrimary)
                    Text(subtitle)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(AppColors.textMuted)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(AppColors.textMuted.opacity(0.7))
            }
            .padding(.horizontal, 18)
            .frame(height: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private extension HomeFeedTab {
    var homeIcon: String {
        switch self {
        case .recommended:
            return "sparkles"
        case .following:
            return "person.2.fill"
        case .secondhand:
            return "bag.fill"
        case .forum:
            return "bubble.left.and.bubble.right.fill"
        }
    }
}

#Preview {
    VStack(spacing: 14) {
        HomeModuleGridView(selectedModule: .forum, onSelect: { _ in })
    }
    .padding()
    .background(AppColors.pageBackground)
}
