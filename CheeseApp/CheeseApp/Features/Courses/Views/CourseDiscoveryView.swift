import SwiftUI

struct CourseDiscoveryView: View {
    @Environment(\.dismiss) private var dismiss

    let universityName: String

    @StateObject private var state = CourseDiscoveryViewModel()
    @State private var query = ""
    @State private var selectedYearLevel: CourseYearLevel?
    @State private var selectedSubject: CourseSubject?
    @State private var isSearchFieldFocused = false

    private var displayedCourses: [CourseSummary] {
        CourseDiscoveryFilter.results(
            from: state.courses,
            query: query,
            yearLevel: selectedYearLevel,
            subject: selectedSubject
        )
    }

    private var isSearching: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        ZStack {
            CoursePageBackground()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 18) {
                        campusNavigationHeader
                        pageIntroduction
                    }
                    .prioritizeKeyboardDismissal(while: isSearchFieldFocused) {
                        isSearchFieldFocused = false
                    }

                    searchField

                    VStack(alignment: .leading, spacing: 18) {
                        filterControls
                        resultSection
                    }
                    .prioritizeKeyboardDismissal(while: isSearchFieldFocused) {
                        isSearchFieldFocused = false
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 32)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .cheeseTabBarHidden(true)
        .enableSwipeBackGesture()
        .onAppear {
            Task { await state.load() }
        }
    }

    private var campusNavigationHeader: some View {
        HStack(spacing: 12) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.primary)
                    .frame(width: 48, height: 48)
                    .background(Color(uiColor: .systemBackground))
                    .clipShape(Circle())
                    .shadow(color: .black.opacity(0.07), radius: 8, y: 3)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(L10n.tr("Back", "返回")))

            Spacer(minLength: 0)

            HStack(spacing: 8) {
                Image(systemName: "mappin.circle")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(AppColors.link)

                Text(universityName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .padding(.horizontal, 14)
            .frame(height: 42)
            .background(Color(uiColor: .systemBackground))
            .clipShape(Capsule())
            .overlay {
                Capsule()
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            }
            .layoutPriority(1)

            Spacer(minLength: 0)

            Color.clear
                .frame(width: 48, height: 48)
                .accessibilityHidden(true)
        }
    }

    private var pageIntroduction: some View {
        HStack(alignment: .bottom, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.tr("Campus", "校园"))
                    .font(.system(size: 40, weight: .bold))
                    .foregroundStyle(.primary)

                Text(L10n.tr("Courses · Professors", "课程 · 教授"))
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            CourseRadarLinkButton()
        }
        .padding(.top, 14)
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color(uiColor: .systemGray2))

            CheeseSearchTextField(
                text: $query,
                placeholder: L10n.tr(
                    "Search course code, title or professor",
                    "搜索课程代码、课程名或教授"
                ),
                fontSize: 15,
                textColor: .white,
                placeholderColor: .systemGray2,
                isFirstResponder: $isSearchFieldFocused,
                onSubmit: {
                    isSearchFieldFocused = false
                }
            )
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 24)

            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.white.opacity(0.7))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(L10n.tr("Clear search", "清除搜索")))
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 56)
        .background(Color.black.opacity(0.94))
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
    }

    private var filterControls: some View {
        HStack(alignment: .top, spacing: 10) {
            yearFilterMenu
                .frame(maxWidth: .infinity)
            subjectFilterMenu
                .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity)
    }

    private var yearFilterMenu: some View {
        Menu {
            filterOption(
                title: L10n.tr("All years", "全部年级"),
                isSelected: selectedYearLevel == nil
            ) {
                selectedYearLevel = nil
            }

            ForEach(CourseYearLevel.allCases, id: \.self) { yearLevel in
                filterOption(
                    title: yearLevel.title,
                    isSelected: selectedYearLevel == yearLevel
                ) {
                    selectedYearLevel = yearLevel
                }
            }
        } label: {
            CourseFilterLabel(
                icon: "graduationcap",
                category: L10n.tr("Year", "年级"),
                value: selectedYearLevel?.title ?? L10n.tr("All", "全部"),
                tint: Color(red: 0.16, green: 0.38, blue: 0.32),
                iconBackground: Color(red: 0.91, green: 0.95, blue: 0.93)
            )
        }
    }

    private var subjectFilterMenu: some View {
        Menu {
            filterOption(
                title: L10n.tr("All subjects", "全部学科"),
                isSelected: selectedSubject == nil
            ) {
                selectedSubject = nil
            }

            ForEach(CourseSubject.allCases, id: \.self) { subject in
                filterOption(
                    title: subject.rawValue,
                    isSelected: selectedSubject == subject
                ) {
                    selectedSubject = subject
                }
            }
        } label: {
            CourseFilterLabel(
                icon: "books.vertical",
                category: L10n.tr("Subject", "学科"),
                value: selectedSubject?.rawValue ?? L10n.tr("All", "全部"),
                tint: Color(red: 0.48, green: 0.35, blue: 0.08),
                iconBackground: Color(red: 0.99, green: 0.94, blue: 0.78)
            )
        }
    }

    @ViewBuilder
    private func filterOption(
        title: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            if isSelected {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }

    private var resultSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(
                isSearching
                    ? L10n.tr("Search results", "搜索结果")
                    : L10n.tr("Popular courses", "热门课程")
            )
            .font(.system(size: 22, weight: .bold))
            .foregroundStyle(.primary)

            switch state.loadState {
            case .idle, .loading:
                HStack(spacing: 10) {
                    ProgressView()
                    Text(L10n.tr("Loading course catalog...", "正在加载课程目录..."))
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(18)
                .background(Color(uiColor: .systemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            case let .failed(message):
                CourseCatalogFailureView(message: message) {
                    Task { await state.load() }
                }
            case .loaded where state.courses.isEmpty:
                CourseEmptyState(kind: .catalog)
            case .loaded where displayedCourses.isEmpty:
                CourseEmptyState(kind: .search)
            case .loaded:
                LazyVStack(spacing: 12) {
                    ForEach(displayedCourses) { course in
                        NavigationLink {
                            CourseDetailView(course: course)
                        } label: {
                            CourseSummaryCard(course: course)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

private struct CourseFilterLabel: View {
    let icon: String
    let category: String
    let value: String
    let tint: Color
    let iconBackground: Color

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 44, height: 44)
                .background(iconBackground)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(category)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color(uiColor: .label).opacity(0.65))

                Text(value)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Color(uiColor: .label))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }

            Spacer(minLength: 4)

            Image(systemName: "chevron.down")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 70)
        .background(Color(uiColor: .systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.primary.opacity(0.09), lineWidth: 1)
        }
    }
}

struct CourseSummaryCard: View {
    let course: CourseSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                Text(course.code)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(AppColors.accent)
                    .clipShape(Capsule())

                Spacer(minLength: 12)

                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }

            Text(course.title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)

            CourseMetricsView(course: course)

            Text(
                L10n.tr("Professors: ", "教授：")
                    + course.professors.prefix(2).map(\.name).joined(separator: "、")
            )
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .lineLimit(2)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .cheeseCardChrome(cornerRadius: 8)
    }
}

struct CourseMetricsView: View {
    let course: CourseSummary

    var body: some View {
        Group {
            if course.aggregate.reviewCount == 0 {
                Text(L10n.tr("No verified ratings yet", "暂无真实评分"))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(spacing: 8) {
                    metric(
                        value: formattedRating(course.aggregate.overallRating),
                        label: L10n.tr("Overall", "总体评分")
                    )
                    metric(
                        value: formattedRating(course.aggregate.easyARating),
                        label: L10n.tr("Easy A", "好拿分")
                    )
                    metric(
                        value: "\(course.aggregate.reviewCount)",
                        label: L10n.tr("Reviews", "条评价")
                    )
                }
            }
        }
    }

    private func formattedRating(_ value: Double?) -> String {
        value.map {
            "\($0.formatted(.number.precision(.fractionLength(1))))/5"
        } ?? "-"
    }

    private func metric(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.primary)
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private enum CourseEmptyStateKind {
    case catalog
    case search
}

private struct CourseEmptyState: View {
    let kind: CourseEmptyStateKind

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "books.vertical")
                .font(.system(size: 32, weight: .medium))
                .foregroundStyle(AppColors.link)
                .frame(width: 64, height: 64)
                .background(Color(red: 0.91, green: 0.95, blue: 0.93))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            Text(
                kind == .catalog
                    ? L10n.tr("No courses available", "暂时没有可查看的课程")
                    : L10n.tr("No matching courses", "没有找到符合条件的课程")
            )
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.primary)

            Text(
                kind == .catalog
                    ? L10n.tr(
                        "The course catalog does not contain any active courses.",
                        "课程目录中暂时没有已开放的课程。"
                    )
                    : L10n.tr(
                        "Try another keyword or filter",
                        "试试其他关键词或筛选条件"
                    )
            )
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.vertical, 54)
        .background(Color(uiColor: .systemBackground).opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(
                    Color.primary.opacity(0.16),
                    style: StrokeStyle(lineWidth: 1, dash: [5, 5])
                )
        }
    }
}

private struct CourseCatalogFailureView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(
                L10n.tr("Unable to load courses", "课程目录加载失败"),
                systemImage: "exclamationmark.triangle"
            )
            .font(.system(size: 15, weight: .semibold))

            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)

            Button(L10n.tr("Retry", "重试"), action: retry)
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(Color(uiColor: .systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
