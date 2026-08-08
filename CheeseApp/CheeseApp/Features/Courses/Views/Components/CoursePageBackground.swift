import SwiftUI

struct CoursePageBackground: View {
    var body: some View {
        AppColors.pageBackground.ignoresSafeArea()
    }
}

struct CourseRadarLinkButton: View {
    var courseCode: String?

    var body: some View {
        Link(destination: destination) {
            HStack(spacing: 7) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 13, weight: .bold))
                Text(L10n.tr("Get this course", "立刻抢课"))
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 11, weight: .bold))
            }
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(.black)
            .padding(.horizontal, 14)
            .frame(minHeight: 42)
            .background(AppColors.accent)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityHint(accessibilityHint)
    }

    private var destination: URL {
        guard let courseCode else { return AppExternalLinks.courseRadar }
        return AppExternalLinks.courseRadar(for: courseCode)
    }

    private var accessibilityHint: String {
        if courseCode == nil {
            return L10n.tr(
                "Opens Cheese Radar course registration",
                "打开奶酪雷达抢课"
            )
        }
        return L10n.tr(
            "Opens Cheese Radar with this course selected",
            "打开奶酪雷达并搜索这门课程"
        )
    }
}
