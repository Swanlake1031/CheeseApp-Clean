import Foundation
import Supabase

struct ProfileUpdateInput {
    let userId: UUID
    let fullName: String
    let schoolName: String
    let avatarURL: String
    let gender: String
    let isGenderVisible: Bool
    let occupation: String
    let phoneNumber: String
    let bio: String
}

@MainActor
enum ProfileService {
    static func fetchProfile(userId: UUID) async throws -> Profile {
        let profiles: [Profile] = try await SupabaseManager.shared
            .database("profile_public_view")
            .select()
            .eq("id", value: userId.uuidString)
            .limit(1)
            .execute()
            .value

        guard let profile = profiles.first else {
            throw NSError(
                domain: "ProfileService",
                code: 404,
                userInfo: [
                    NSLocalizedDescriptionKey: "该用户主页暂不可访问。"
                ]
            )
        }
        return profile
    }

    static func fetchProfiles(userIds: [UUID]) async throws -> [UUID: Profile] {
        guard !userIds.isEmpty else { return [:] }

        let profiles: [Profile] = try await SupabaseManager.shared
            .database("profile_public_view")
            .select("id,full_name,avatar_url,university,is_official,is_mcmaster_verified")
            .`in`("id", values: userIds.map { $0 as any PostgrestFilterValue })
            .execute()
            .value

        return Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) })
    }

    static func updateProfile(
        input: ProfileUpdateInput,
        currentProfile: Profile?
    ) async throws -> Profile? {
        let normalizedSchool = input.schoolName.trimmingCharacters(in: .whitespacesAndNewlines)
        let selection = normalizedSchool.isEmpty
            ? nil
            : try await SchoolDirectoryService.profileSelection(named: normalizedSchool)
        let normalizedGender = input.gender.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedOccupation = input.occupation.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedPhoneNumber = input.phoneNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedBio = input.bio.trimmingCharacters(in: .whitespacesAndNewlines)

        let payload = ProfileUpdatePayload(
            fullName: input.fullName,
            university: normalizedSchool,
            avatarURL: input.avatarURL,
            gender: normalizedGender,
            showGender: input.isGenderVisible,
            occupation: normalizedOccupation,
            phone: normalizedPhoneNumber,
            bio: normalizedBio,
            schoolId: selection?.schoolId,
            campusId: selection?.campusId
        )

        try await SupabaseManager.shared
            .database("profiles")
            .update(payload)
            .eq("id", value: input.userId.uuidString)
            .execute()

        guard var updatedProfile = currentProfile else { return nil }
        updatedProfile.fullName = input.fullName
        updatedProfile.school = normalizedSchool.isEmpty ? nil : normalizedSchool
        if let selection {
            updatedProfile.schoolId = selection.schoolId
            updatedProfile.campusId = selection.campusId
        }
        updatedProfile.avatarUrl = input.avatarURL
        updatedProfile.gender = normalizedGender.isEmpty ? nil : normalizedGender
        updatedProfile.isGenderVisible = input.isGenderVisible
        updatedProfile.occupation = normalizedOccupation
        updatedProfile.phoneNumber = normalizedPhoneNumber
        updatedProfile.bio = normalizedBio
        return updatedProfile
    }

    static func updateAnonymousPostingDefault(userId: UUID, enabled: Bool) async throws {
        try await SupabaseManager.shared
            .database("profiles")
            .update(["is_anonymous": enabled])
            .eq("id", value: userId.uuidString)
            .execute()
    }

}

private struct ProfileUpdatePayload: Encodable {
    let fullName: String
    let university: String
    let avatarURL: String
    let gender: String
    let showGender: Bool
    let occupation: String
    let phone: String
    let bio: String
    let schoolId: UUID?
    let campusId: UUID?

    enum CodingKeys: String, CodingKey {
        case fullName = "full_name"
        case university
        case avatarURL = "avatar_url"
        case gender
        case showGender = "show_gender"
        case occupation, phone, bio
        case schoolId = "school_id"
        case campusId = "campus_id"
    }
}

struct McMasterVerificationStatus: Decodable {
    let verified: Bool
    let maskedEmail: String?
    let verifiedAt: String?

    enum CodingKeys: String, CodingKey {
        case verified
        case maskedEmail = "masked_email"
        case verifiedAt = "verified_at"
    }
}

struct McMasterVerificationSendResult: Decodable {
    let sent: Bool?
    let verified: Bool?
    let retryAfterSeconds: Int?
    let expiresInSeconds: Int?
    let message: String?

    enum CodingKeys: String, CodingKey {
        case sent, verified, message
        case retryAfterSeconds = "retry_after_seconds"
        case expiresInSeconds = "expires_in_seconds"
    }
}

enum McMasterVerificationService {
    static func status() async throws -> McMasterVerificationStatus {
        try await invoke(McMasterVerificationRequest(action: "status"))
    }

    static func sendCode(to email: String) async throws -> McMasterVerificationSendResult {
        try await invoke(McMasterVerificationRequest(action: "send", email: email))
    }

    static func verify(email: String, code: String) async throws -> McMasterVerificationStatus {
        try await invoke(McMasterVerificationRequest(action: "verify", email: email, code: code))
    }

    static func unlink() async throws -> McMasterVerificationStatus {
        try await invoke(McMasterVerificationRequest(action: "unlink"))
    }

    private static func invoke<Response: Decodable>(
        _ request: McMasterVerificationRequest
    ) async throws -> Response {
        do {
            return try await SupabaseManager.shared.client.functions.invoke(
                "mcmaster-verification",
                options: .init(body: request)
            )
        } catch let functionError as FunctionsError {
            if case .httpError(_, let data) = functionError,
               let payload = try? JSONDecoder().decode(McMasterVerificationErrorPayload.self, from: data),
               !payload.error.isEmpty {
                throw McMasterVerificationError.server(payload.error)
            }
            throw McMasterVerificationError.server("认证服务暂时不可用，请稍后再试。")
        } catch {
            throw McMasterVerificationError.server(error.localizedDescription)
        }
    }
}

private struct McMasterVerificationRequest: Encodable {
    let action: String
    var email: String?
    var code: String?
}

private struct McMasterVerificationErrorPayload: Decodable {
    let error: String
}

private enum McMasterVerificationError: LocalizedError {
    case server(String)

    var errorDescription: String? {
        switch self {
        case .server(let message): message
        }
    }
}
