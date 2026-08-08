import CryptoKit
import Foundation

final class CourseOutlineService {
    static let shared = CourseOutlineService()

    private let bucketName = "course-outlines"

    private init() {}

    func fetchOutlines(courseID: UUID) async throws -> [CourseOutline] {
        do {
            let rows: [CourseOutlineRow] = try await SupabaseManager.shared
                .database("course_outlines")
                .select(
                    """
                    id, course_id, academic_year, term, professor_name, title,
                    storage_path, original_filename, mime_type, file_size_bytes,
                    sha256, created_at
                    """
                )
                .eq("course_id", value: courseID)
                .order("academic_year", ascending: false)
                .order("term", ascending: false)
                .execute()
                .value

            return rows.map(\.model)
        } catch {
            throw CourseOutlineServiceError.metadataLoadFailed
        }
    }

    func downloadPDF(for outline: CourseOutline) async throws -> Data {
        guard outline.mimeType == "application/pdf",
              outline.storagePath.hasSuffix(".pdf") else {
            throw CourseOutlineServiceError.invalidPDF
        }

        do {
            let data = try await SupabaseManager.shared
                .storage(bucketName)
                .download(path: outline.storagePath)

            guard data.count <= 20 * 1_024 * 1_024,
                  data.starts(with: Data("%PDF-".utf8)),
                  SHA256.hash(data: data).hexString == outline.sha256 else {
                throw CourseOutlineServiceError.invalidPDF
            }
            return data
        } catch let error as CourseOutlineServiceError {
            throw error
        } catch {
            throw CourseOutlineServiceError.downloadFailed
        }
    }
}

enum CourseOutlineServiceError: LocalizedError {
    case metadataLoadFailed
    case downloadFailed
    case invalidPDF

    var errorDescription: String? {
        switch self {
        case .metadataLoadFailed:
            return L10n.tr(
                "Unable to load course outlines. Please try again.",
                "暂时无法加载课程大纲，请重试。"
            )
        case .downloadFailed:
            return L10n.tr(
                "Unable to download this PDF. Please try again.",
                "PDF 下载失败，请重试。"
            )
        case .invalidPDF:
            return L10n.tr(
                "This course outline is not a readable PDF.",
                "这份课程大纲不是可读取的 PDF。"
            )
        }
    }
}

private extension SHA256.Digest {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

private struct CourseOutlineRow: Decodable {
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

    enum CodingKeys: String, CodingKey {
        case id
        case courseID = "course_id"
        case academicYear = "academic_year"
        case term
        case professorName = "professor_name"
        case title
        case storagePath = "storage_path"
        case originalFilename = "original_filename"
        case mimeType = "mime_type"
        case fileSizeBytes = "file_size_bytes"
        case sha256
        case createdAt = "created_at"
    }

    var model: CourseOutline {
        CourseOutline(
            id: id,
            courseID: courseID,
            academicYear: academicYear,
            term: term,
            professorName: professorName,
            title: title,
            storagePath: storagePath,
            originalFilename: originalFilename,
            mimeType: mimeType,
            fileSizeBytes: fileSizeBytes,
            sha256: sha256,
            createdAt: createdAt
        )
    }
}
