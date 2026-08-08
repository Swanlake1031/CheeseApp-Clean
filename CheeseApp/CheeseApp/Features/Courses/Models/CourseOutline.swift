import Foundation

enum CourseAcademicTerm: String, Codable, Hashable {
    case winter
    case spring
    case summer
    case fall

    var title: String {
        switch self {
        case .winter:
            return L10n.tr("Winter", "冬季")
        case .spring:
            return L10n.tr("Spring", "春季")
        case .summer:
            return L10n.tr("Summer", "夏季")
        case .fall:
            return L10n.tr("Fall", "秋季")
        }
    }
}

struct CourseOutline: Identifiable, Hashable {
    let id: UUID
    let courseID: UUID
    let academicYear: Int
    let term: CourseAcademicTerm
    let professorName: String?
    let title: String
    let storagePath: String
    let originalFilename: String
    let mimeType: String
    let fileSizeBytes: Int64
    let sha256: String
    let createdAt: Date

    var termTitle: String {
        "\(academicYear) \(term.title)"
    }

    var formattedFileSize: String {
        ByteCountFormatter.string(
            fromByteCount: fileSizeBytes,
            countStyle: .file
        )
    }
}
