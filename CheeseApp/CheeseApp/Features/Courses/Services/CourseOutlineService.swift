import CryptoKit
import Foundation

final class CourseOutlineService {
    static let shared = CourseOutlineService()

    private let bucketName = "course-outlines"

    private init() {}

    func fetchOutlines(courseID: UUID) async throws -> [CourseOutline] {
        do {
            async let storedRows: [StoredCourseOutlineRow] = SupabaseManager.shared
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

            async let externalRows: [ExternalCourseOutlineRow] = SupabaseManager.shared
                .database("course_external_outlines")
                .select(
                    """
                    id, course_id, academic_year, term, professor_name, title,
                    source_kind, source_url, source_page_url, source_name,
                    mime_type, created_at
                    """
                )
                .eq("course_id", value: courseID)
                .order("academic_year", ascending: false)
                .order("term", ascending: false)
                .execute()
                .value

            let (stored, external) = try await (storedRows, externalRows)
            let outlines = stored.map(\.model) + external.map(\.model)
            return outlines.sorted(by: CourseOutline.newestFirst)
        } catch {
            throw CourseOutlineServiceError.metadataLoadFailed
        }
    }

    func downloadPDF(for outline: CourseOutline) async throws -> Data {
        switch outline.sourceKind {
        case .privateStorage:
            return try await downloadPrivatePDF(for: outline)
        case .externalPDF:
            return try await downloadExternalPDF(for: outline)
        case .externalWeb:
            throw CourseOutlineServiceError.unsupportedSource
        }
    }

    private func downloadPrivatePDF(for outline: CourseOutline) async throws -> Data {
        guard outline.mimeType == "application/pdf",
              let storagePath = outline.storagePath,
              storagePath.hasSuffix(".pdf"),
              let expectedSize = outline.fileSizeBytes,
              let expectedSHA256 = outline.sha256 else {
            throw CourseOutlineServiceError.invalidPDF
        }

        do {
            let data = try await SupabaseManager.shared
                .storage(bucketName)
                .download(path: storagePath)

            guard Int64(data.count) == expectedSize,
                  data.count <= 20 * 1_024 * 1_024,
                  data.starts(with: Data("%PDF-".utf8)),
                  SHA256.hash(data: data).hexString == expectedSHA256 else {
                throw CourseOutlineServiceError.invalidPDF
            }
            return data
        } catch let error as CourseOutlineServiceError {
            throw error
        } catch {
            throw CourseOutlineServiceError.downloadFailed
        }
    }

    private func downloadExternalPDF(for outline: CourseOutline) async throws -> Data {
        guard outline.mimeType == "application/pdf",
              let sourceURL = outline.sourceURL,
              isAllowedOfficialURL(sourceURL) else {
            throw CourseOutlineServiceError.invalidSourceURL
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60

        var request = URLRequest(url: sourceURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData

        do {
            let (data, response) = try await URLSession(configuration: configuration)
                .data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  http.expectedContentLength <= 20 * 1_024 * 1_024,
                  data.count <= 20 * 1_024 * 1_024,
                  data.starts(with: Data("%PDF-".utf8)) else {
                throw CourseOutlineServiceError.invalidPDF
            }
            return data
        } catch let error as CourseOutlineServiceError {
            throw error
        } catch {
            throw CourseOutlineServiceError.downloadFailed
        }
    }

    func validatedWebURL(for outline: CourseOutline) -> URL? {
        guard outline.sourceKind == .externalWeb,
              let sourceURL = outline.sourceURL,
              isAllowedOfficialURL(sourceURL) else {
            return nil
        }
        return sourceURL
    }

    private func isAllowedOfficialURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased() else {
            return false
        }
        return host == "mcmaster.ca"
            || host.hasSuffix(".mcmaster.ca")
            || host == "simplesyllabusca.com"
            || host.hasSuffix(".simplesyllabusca.com")
    }
}

enum CourseOutlineServiceError: LocalizedError {
    case metadataLoadFailed
    case downloadFailed
    case invalidPDF
    case invalidSourceURL
    case unsupportedSource

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
        case .invalidSourceURL:
            return L10n.tr(
                "This course outline link is not an approved official source.",
                "这份课程大纲的链接不是允许的官方来源。"
            )
        case .unsupportedSource:
            return L10n.tr(
                "This course outline must be opened as a web page.",
                "这份课程大纲需要以网页方式打开。"
            )
        }
    }
}

private extension SHA256.Digest {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

private struct StoredCourseOutlineRow: Decodable {
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
            sourceKind: .privateStorage,
            sourceURL: nil,
            sourcePageURL: nil,
            sourceName: "supabase_storage",
            storagePath: storagePath,
            originalFilename: originalFilename,
            mimeType: mimeType,
            fileSizeBytes: fileSizeBytes,
            sha256: sha256,
            createdAt: createdAt
        )
    }
}

private struct ExternalCourseOutlineRow: Decodable {
    let id: UUID
    let courseID: UUID
    let academicYear: Int
    let term: CourseAcademicTerm
    let professorName: String?
    let title: String
    let sourceKind: CourseOutlineSourceKind
    let sourceURL: URL
    let sourcePageURL: URL?
    let sourceName: String
    let mimeType: String
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case courseID = "course_id"
        case academicYear = "academic_year"
        case term
        case professorName = "professor_name"
        case title
        case sourceKind = "source_kind"
        case sourceURL = "source_url"
        case sourcePageURL = "source_page_url"
        case sourceName = "source_name"
        case mimeType = "mime_type"
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
            sourceKind: sourceKind,
            sourceURL: sourceURL,
            sourcePageURL: sourcePageURL,
            sourceName: sourceName,
            storagePath: nil,
            originalFilename: nil,
            mimeType: mimeType,
            fileSizeBytes: nil,
            sha256: nil,
            createdAt: createdAt
        )
    }
}

private extension CourseOutline {
    static func newestFirst(_ lhs: CourseOutline, _ rhs: CourseOutline) -> Bool {
        if lhs.academicYear != rhs.academicYear {
            return lhs.academicYear > rhs.academicYear
        }
        if lhs.term.sortOrder != rhs.term.sortOrder {
            return lhs.term.sortOrder > rhs.term.sortOrder
        }
        return lhs.createdAt > rhs.createdAt
    }
}

private extension CourseAcademicTerm {
    var sortOrder: Int {
        switch self {
        case .winter: return 1
        case .spring: return 2
        case .summer: return 3
        case .fall: return 4
        }
    }
}
