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
    var coverImageUrl: String?
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
    var profileStatus: String?
    var profileCompleted: Bool?
    var createdAt: Date?
    var updatedAt: Date?
    var is_verified: Bool?
    var isAnonymousDefault: Bool?
    var isOfficial: Bool?
    var isMcMasterVerified: Bool?

    var isOfficialAccount: Bool { isOfficial == true }
    var hasSchoolStudentBadge: Bool { isMcMasterVerified == true }
    var isStudent: Bool { profileStatus != "working" }
    
    enum CodingKeys: String, CodingKey {
        case id, email
        case publicID = "public_uid"
        case fullName = "full_name"
        case avatarUrl = "avatar_url"
        case coverImageUrl = "cover_image_url"
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
        case profileStatus = "profile_status"
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
    let badgeCode: String
    let verificationDomains: [String]

    var displayText: String { "\(name), \(city)" }
    var localizedName: String { name == "Other" ? L10n.tr("Other", "其他") : name }
    var supportsStudentVerification: Bool { !verificationDomains.isEmpty }
    var verificationDomainHint: String {
        verificationDomains.map { "@\($0)" }.joined(separator: " / ")
    }

    static let other = CheeseUniversityOption(
        id: "other", name: "Other", city: "其他大学", badgeCode: "•", verificationDomains: []
    )

    static let all: [CheeseUniversityOption] = [
        .init(id: "university_of_alberta", name: "University of Alberta", city: "Edmonton", badgeCode: "A", verificationDomains: ["ualberta.ca"]),
        .init(id: "university_of_british_columbia", name: "University of British Columbia", city: "Vancouver", badgeCode: "UBC", verificationDomains: ["student.ubc.ca"]),
        .init(id: "brock_university", name: "Brock University", city: "St. Catharines", badgeCode: "B", verificationDomains: ["brocku.ca"]),
        .init(id: "university_of_calgary", name: "University of Calgary", city: "Calgary", badgeCode: "C", verificationDomains: ["ucalgary.ca"]),
        .init(id: "carleton_university", name: "Carleton University", city: "Ottawa", badgeCode: "C", verificationDomains: ["cmail.carleton.ca"]),
        .init(id: "concordia_university", name: "Concordia University", city: "Montréal", badgeCode: "C", verificationDomains: ["mail.concordia.ca", "live.concordia.ca"]),
        .init(id: "dalhousie_university", name: "Dalhousie University", city: "Halifax", badgeCode: "D", verificationDomains: ["dal.ca"]),
        .init(id: "university_of_guelph", name: "University of Guelph", city: "Guelph", badgeCode: "G", verificationDomains: ["uoguelph.ca"]),
        .init(id: "simon_fraser_university", name: "Simon Fraser University", city: "Burnaby", badgeCode: "S", verificationDomains: ["sfu.ca"]),
        .init(id: "lakehead_university", name: "Lakehead University", city: "Thunder Bay", badgeCode: "L", verificationDomains: ["lakeheadu.ca"]),
        .init(id: "mcgill_university", name: "McGill University", city: "Montréal", badgeCode: "M", verificationDomains: ["mail.mcgill.ca", "mcgill.ca"]),
        .init(id: "university_of_manitoba", name: "University of Manitoba", city: "Winnipeg", badgeCode: "M", verificationDomains: ["myumanitoba.ca"]),
        .init(id: "mcmaster_university", name: "McMaster University", city: "Hamilton", badgeCode: "M", verificationDomains: ["mcmaster.ca"]),
        .init(id: "universite_de_montreal", name: "Université de Montréal", city: "Montréal", badgeCode: "UdeM", verificationDomains: ["umontreal.ca"]),
        .init(id: "ontario_tech_university", name: "Ontario Tech University", city: "Oshawa", badgeCode: "OT", verificationDomains: ["ontariotechu.net"]),
        .init(id: "queens_university", name: "Queen's University", city: "Kingston", badgeCode: "Q", verificationDomains: ["queensu.ca"]),
        .init(id: "university_of_toronto", name: "University of Toronto", city: "Toronto", badgeCode: "T", verificationDomains: ["mail.utoronto.ca"]),
        .init(id: "toronto_metropolitan_university", name: "Toronto Metropolitan University", city: "Toronto", badgeCode: "TMU", verificationDomains: ["torontomu.ca"]),
        .init(id: "trent_university", name: "Trent University", city: "Peterborough", badgeCode: "T", verificationDomains: ["trentu.ca"]),
        .init(id: "university_of_waterloo", name: "University of Waterloo", city: "Waterloo", badgeCode: "W", verificationDomains: ["uwaterloo.ca"]),
        .init(id: "york_university", name: "York University", city: "Toronto", badgeCode: "Y", verificationDomains: ["my.yorku.ca", "yorku.ca"]),
        .init(id: "ocad_university", name: "OCAD University", city: "Toronto", badgeCode: "O", verificationDomains: ["ocadu.ca"]),
        .init(id: "redeemer_university", name: "Redeemer University", city: "Hamilton", badgeCode: "R", verificationDomains: ["redeemer.ca"]),
        .init(id: "university_of_guelph_humber", name: "University of Guelph-Humber", city: "Toronto", badgeCode: "GH", verificationDomains: ["guelphhumber.ca"]),
        .other
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
    static func needsCompletion(
        profileCompleted: Bool?,
        profileStatus: String?,
        school: String?
    ) -> Bool {
        guard profileCompleted == true else { return true }
        if profileStatus == "working" { return false }
        return CheeseUniversityOption.option(matching: school) == nil
    }
}
