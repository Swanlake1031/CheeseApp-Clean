import Foundation

enum CourseOutlineSourceKind: String, Codable, Hashable {
    case privateStorage = "private_storage"
    case externalPDF = "external_pdf"
    case externalWeb = "external_web"
}

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
    let sourceKind: CourseOutlineSourceKind
    let sourceURL: URL?
    let sourcePageURL: URL?
    let sourceName: String
    let storagePath: String?
    let originalFilename: String?
    let mimeType: String?
    let fileSizeBytes: Int64?
    let sha256: String?
    let createdAt: Date

    var termTitle: String {
        "\(academicYear) \(term.title)"
    }

    var formattedFileSize: String {
        guard let fileSizeBytes else {
            return sourceKind == .externalWeb
                ? L10n.tr("Official page", "官方页面")
                : L10n.tr("Official link", "官方链接")
        }
        return ByteCountFormatter.string(
            fromByteCount: fileSizeBytes,
            countStyle: .file
        )
    }

    var isWebDocument: Bool {
        sourceKind == .externalWeb
    }
}
