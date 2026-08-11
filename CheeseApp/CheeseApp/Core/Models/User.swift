//
//  User.swift
//  CheeseApp
//
//  🎯 用户数据模型
//

import Foundation

// ============================================
// 用户资料
// ============================================

struct Profile: Codable, Identifiable {
    let id: UUID
    let publicID: String?
    let email: String?
    var fullName: String?
    var avatarUrl: String?
    var school: String?
    var schoolId: UUID?
    var campusId: UUID?
    var major: String?
    var gender: String?
    var isGenderVisible: Bool?
    var occupation: String?
    var phoneNumber: String?
    var gradYear: Int?
    var bio: String?
    var wechatId: String?
    var profileCompleted: Bool?
    var createdAt: Date?
    var updatedAt: Date?
    var is_verified: Bool?
    var isAnonymousDefault: Bool?
    var isOfficial: Bool?
    var isMcMasterVerified: Bool?

    var isOfficialAccount: Bool { isOfficial == true }
    var hasMcMasterStudentBadge: Bool { isMcMasterVerified == true }
    
    enum CodingKeys: String, CodingKey {
        case id, email
        case publicID = "public_uid"
        case fullName = "full_name"
        case avatarUrl = "avatar_url"
        case school = "university"
        case schoolId = "school_id"
        case campusId = "campus_id"
        case major
        case gender
        case isGenderVisible = "show_gender"
        case occupation
        case phoneNumber = "phone"
        case gradYear = "grad_year"
        case bio
        case wechatId = "wechat_id"
        case profileCompleted = "profile_completed"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case is_verified = "verified"
        case isAnonymousDefault = "is_anonymous"
        case isOfficial = "is_official"
        case isMcMasterVerified = "is_mcmaster_verified"
    }
}

struct CheeseUniversityOption: Identifiable, Hashable {
    let id: String
    let name: String
    let city: String

    var displayText: String { "\(name), \(city)" }

    static let all: [CheeseUniversityOption] = [
        .init(id: "university_of_toronto", name: "University of Toronto", city: "Toronto"),
        .init(id: "york_university", name: "York University", city: "Toronto"),
        .init(id: "toronto_metropolitan_university", name: "Toronto Metropolitan University", city: "Toronto"),
        .init(id: "ocad_university", name: "OCAD University", city: "Toronto"),
        .init(id: "ontario_tech_university", name: "Ontario Tech University", city: "Oshawa"),
        .init(id: "mcmaster_university", name: "McMaster University", city: "Hamilton"),
        .init(id: "redeemer_university", name: "Redeemer University", city: "Hamilton"),
        .init(id: "university_of_guelph_humber", name: "University of Guelph-Humber", city: "Toronto"),
        .init(id: "seneca_polytechnic", name: "Seneca Polytechnic", city: "Toronto / York Region"),
        .init(id: "humber_polytechnic", name: "Humber Polytechnic", city: "Toronto"),
        .init(id: "george_brown_college", name: "George Brown College", city: "Toronto"),
        .init(id: "centennial_college", name: "Centennial College", city: "Toronto"),
        .init(id: "sheridan_college", name: "Sheridan College", city: "Oakville / Brampton / Mississauga"),
        .init(id: "durham_college", name: "Durham College", city: "Oshawa"),
        .init(id: "mohawk_college", name: "Mohawk College", city: "Hamilton")
    ]

    static var defaultSchoolName: String {
        "McMaster University"
    }

    static func option(matching rawSchool: String?) -> CheeseUniversityOption? {
        guard let raw = rawSchool?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }

        if let exact = all.first(where: { $0.name.caseInsensitiveCompare(raw) == .orderedSame }) {
            return exact
        }

        if let display = all.first(where: { $0.displayText.caseInsensitiveCompare(raw) == .orderedSame }) {
            return display
        }

        let normalizedName = raw.components(separatedBy: ",").first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? raw
        return all.first(where: { $0.name.caseInsensitiveCompare(normalizedName) == .orderedSame })
    }

}

enum ProfileCompletionPolicy {
    static func needsCompletion(profileCompleted: Bool?, school _: String?) -> Bool {
        profileCompleted != true
    }
}
