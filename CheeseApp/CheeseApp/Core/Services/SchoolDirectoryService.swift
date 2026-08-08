import Foundation
import Supabase

struct SchoolSelectionIDs {
    let schoolId: UUID
    let campusId: UUID?
}

@MainActor
enum SchoolDirectoryService {
    static func schoolID(named schoolName: String) async throws -> UUID {
        let row: DirectoryIDRow = try await SupabaseManager.shared
            .database("schools")
            .select("id")
            .eq("name", value: schoolName)
            .single()
            .execute()
            .value

        return row.id
    }

    static func profileSelection(named schoolName: String) async throws -> SchoolSelectionIDs {
        let schoolId = try await schoolID(named: schoolName)
        let campus: DirectoryIDRow? = try? await SupabaseManager.shared
            .database("school_campuses")
            .select("id")
            .eq("school_id", value: schoolId.uuidString)
            .eq("is_default", value: true)
            .single()
            .execute()
            .value

        return SchoolSelectionIDs(schoolId: schoolId, campusId: campus?.id)
    }
}

private struct DirectoryIDRow: Decodable {
    let id: UUID
}
