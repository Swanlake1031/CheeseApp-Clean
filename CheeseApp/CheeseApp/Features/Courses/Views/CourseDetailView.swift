import SwiftUI

struct CourseDetailView: View {
    let course: CourseSummary

    @StateObject private var reviewState: CourseReviewViewModel
    @State private var outlines: [CourseOutline] = []
    @State private var isLoadingOutlines = false
    @State private var outlineErrorMessage: String?
    @State private var selectedOutline: CourseOutline?
    @State private var isReviewEditorPresented = false
    @State private var showingProfessorFilter = false

    init(course: CourseSummary) {
        self.course = course
        _reviewState = StateObject(
            wrappedValue: CourseReviewViewModel(courseID: course.id)
        )
    }

    var body: some View {
        ZStack {
            CoursePageBackground()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 22) {
                    courseHeader
                    .padding(18)
                    .background(Color(uiColor: .systemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .cheeseCardChrome(cornerRadius: 20)

                    outlinesSection

                    CourseReviewSection(state: reviewState) {
                        presentReviewEditor()
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 80)
                .contentShape(Rectangle())
                .onTapGesture {
                    hideKeyboard()
                }
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .navigationTitle(course.code)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .cheeseTabBarHidden(true)
        .sheet(item: $selectedOutline) { outline in
            CourseOutlineViewerView(outline: outline)
        }
        .sheet(isPresented: $isReviewEditorPresented) {
            CourseReviewEditorSheet(state: reviewState) {
                isReviewEditorPresented = false
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            reviewActionBar
        }
        .task(id: course.id) {
            await loadOutlines()
        }
        .task(id: course.id) {
            await reviewState.load()
        }
    }

    private var courseHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(course.code)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(AppColors.accent)
                        .clipShape(Capsule())

                    Text(course.title)
                        .font(.system(size: 25, weight: .bold))
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)

                    Text("\(course.subject.rawValue) · \(course.yearLevel.title)")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                CourseOverallRatingBadge(
                    rating: reviewState.snapshot.aggregate.overallRating,
                    isLoading: reviewState.isLoading
                )
            }

            HStack(alignment: .bottom, spacing: 14) {
                CourseRatingSummaryView(
                    aggregate: reviewState.displayedAggregate,
                    isLoading: reviewState.isLoading
                )
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .trailing, spacing: 2) {
                    CourseRadarLinkButton(courseCode: course.code)
                    professorFilter
                }
            }
        }
    }

    private var outlinesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.tr("Course Outline", "课程大纲"))
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.primary)

            if isLoadingOutlines {
                HStack(spacing: 10) {
                    ProgressView()
                    Text(L10n.tr("Loading course outlines...", "正在加载课程大纲..."))
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(18)
                .background(Color(uiColor: .systemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .cheeseCardChrome(cornerRadius: 20)
            } else if let outlineErrorMessage {
                VStack(alignment: .leading, spacing: 12) {
                    Label(
                        L10n.tr("Unable to load outlines", "课程大纲加载失败"),
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.system(size: 15, weight: .semibold))

                    Text(outlineErrorMessage)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)

                    Button(L10n.tr("Retry", "重试")) {
                        Task { await loadOutlines() }
                    }
                    .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(18)
                .background(Color(uiColor: .systemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .cheeseCardChrome(cornerRadius: 20)
            } else if outlines.isEmpty {
                Text(L10n.tr(
                    "No course outlines are available yet.",
                    "暂时没有可查看的课程大纲。"
                ))
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(18)
                .background(Color(uiColor: .systemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .cheeseCardChrome(cornerRadius: 20)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(outlines.enumerated()), id: \.element.id) { index, outline in
                        outlineRow(outline)

                        if index != outlines.count - 1 {
                            Divider()
                        }
                    }
                }
                .padding(.horizontal, 16)
                .background(Color(uiColor: .systemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .cheeseCardChrome(cornerRadius: 20)
            }
        }
    }

    private var professorFilter: some View {
        Button {
            showingProfessorFilter = true
        } label: {
            HStack(spacing: 5) {
                Text(selectedProfessorFilterTitle)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .bold))
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.primary)
            .padding(.horizontal, 6)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(reviewState.snapshot.professors.isEmpty || reviewState.isSubmitting)
        .confirmationDialog(
            L10n.tr("Select professor", "选择教授"),
            isPresented: $showingProfessorFilter,
            titleVisibility: .visible
        ) {
            Button(L10n.tr("All professors", "全部教授")) {
                reviewState.selectedProfessorID = nil
            }

            ForEach(reviewState.snapshot.professors) { professor in
                Button(professor.name) {
                    reviewState.selectedProfessorID = professor.id
                }
            }
        }
    }

    private var selectedProfessorFilterTitle: String {
        if let selectedProfessorID = reviewState.selectedProfessorID,
           let professor = reviewState.snapshot.professors.first(where: {
               $0.id == selectedProfessorID
           }) {
            return professor.name
        }

        return L10n.tr("All professors", "全部教授")
    }

    private var reviewActionBar: some View {
        HStack {
            Button {
                if reviewState.loadErrorMessage != nil
                    || reviewState.snapshot.professors.isEmpty
                    || reviewState.snapshot.academicTerms.isEmpty {
                    Task { await reviewState.load() }
                } else {
                    presentReviewEditor()
                }
            } label: {
                Label(
                    reviewActionTitle,
                    systemImage: reviewActionIcon
                )
                .font(.system(size: 15, weight: .bold))
                .frame(maxWidth: .infinity, minHeight: 50)
                .contentShape(Rectangle())
            }
            .buttonStyle(CourseActionButtonStyle())
            .foregroundStyle(.black)
            .background(AppColors.accent)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .disabled(reviewState.isLoading)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(Color(uiColor: .systemBackground))
        .overlay(alignment: .top) {
            Divider()
        }
    }

    private var reviewActionTitle: String {
        if reviewState.isLoading {
            return L10n.tr("Loading reviews...", "正在加载评价...")
        }
        if reviewState.loadErrorMessage != nil {
            return L10n.tr("Reload course reviews", "重新加载课程评价")
        }
        if reviewState.snapshot.professors.isEmpty {
            return L10n.tr("Reload professors", "重新加载教授")
        }
        if reviewState.snapshot.academicTerms.isEmpty {
            return L10n.tr("Reload academic terms", "重新加载年份学期")
        }
        return reviewState.snapshot.ownReview == nil
            ? L10n.tr("Review this course", "添加课程评价")
            : L10n.tr("Edit your review", "修改我的评价")
    }

    private var reviewActionIcon: String {
        if reviewState.isLoading {
            return "hourglass"
        }
        if reviewState.loadErrorMessage != nil
            || reviewState.snapshot.professors.isEmpty
            || reviewState.snapshot.academicTerms.isEmpty {
            return "arrow.clockwise"
        }
        return reviewState.snapshot.ownReview == nil ? "square.and.pencil" : "pencil"
    }

    private func presentReviewEditor() {
        reviewState.prepareOwnReviewForEditing()
        isReviewEditorPresented = true
    }

    private func outlineRow(_ outline: CourseOutline) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(outline.termTitle)
                    .font(.system(size: 15, weight: .bold))

                Spacer()

                Text(outline.formattedFileSize)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            if let professorName = outline.professorName, !professorName.isEmpty {
                Text("\(L10n.tr("Professor", "教授"))：\(professorName)")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }

            Text(outline.title)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                selectedOutline = outline
            } label: {
                Label(L10n.tr("View PDF", "查看 PDF"), systemImage: "doc.text")
                    .font(.system(size: 14, weight: .semibold))
            }
            .buttonStyle(.borderedProminent)
            .tint(AppColors.accentStrong)
        }
        .padding(.vertical, 16)
    }

    @MainActor
    private func loadOutlines() async {
        isLoadingOutlines = true
        outlineErrorMessage = nil
        defer { isLoadingOutlines = false }

        do {
            outlines = try await CourseOutlineService.shared.fetchOutlines(courseID: course.id)
        } catch {
            outlines = []
            outlineErrorMessage = error.localizedDescription
        }
    }

}

private struct CourseOverallRatingBadge: View {
    let rating: Double?
    let isLoading: Bool

    var body: some View {
        VStack(spacing: 4) {
            Text(L10n.tr("Overall", "总评分"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            if isLoading {
                ProgressView()
                    .frame(height: 27)
            } else {
                Text(formattedRating)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.primary)
                    .monospacedDigit()
            }
        }
        .frame(width: 82, height: 68)
        .background(AppColors.accent.opacity(0.28))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(AppColors.accentStrong.opacity(0.22), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
    }

    private var formattedRating: String {
        guard let rating else { return "—/5" }
        return "\(rating.formatted(.number.precision(.fractionLength(1))))/5"
    }
}
