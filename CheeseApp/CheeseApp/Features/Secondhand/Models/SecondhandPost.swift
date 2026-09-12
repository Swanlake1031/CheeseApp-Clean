//
//  SecondhandPost.swift
//  CheeseApp
//
//  🎯 二手交易帖子模型
//

import Foundation

enum SecondhandPost {
    enum Category: String, Codable, CaseIterable {
        case homeAppliances = "home_appliances"
        case dailyEssentials = "daily_essentials"
        case fashionAccessories = "fashion_accessories"
        case beautyCare = "beauty_care"
        case sportsOutdoors = "sports_outdoors"
        case digitalElectronics = "digital_electronics"
        case booksAcademic = "books_academic"
        case petSupplies = "pet_supplies"
        case other = "other"

        init(normalizing rawValue: String) {
            switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "home_appliances", "furniture", "appliances":
                self = .homeAppliances
            case "daily_essentials", "daily", "household":
                self = .dailyEssentials
            case "fashion_accessories", "fashion", "clothing":
                self = .fashionAccessories
            case "beauty_care", "beauty":
                self = .beautyCare
            case "sports_outdoors", "sports":
                self = .sportsOutdoors
            case "digital_electronics", "electronics":
                self = .digitalElectronics
            case "books_academic", "academic", "books", "textbooks":
                self = .booksAcademic
            case "pet_supplies", "pets":
                self = .petSupplies
            default:
                self = .other
            }
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            self.init(normalizing: try container.decode(String.self))
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }

        var displayName: String {
            switch self {
            case .homeAppliances: return "家居家电"
            case .dailyEssentials: return "生活用品"
            case .fashionAccessories: return "服饰鞋包"
            case .beautyCare: return "美妆护理"
            case .sportsOutdoors: return "运动户外"
            case .digitalElectronics: return "数码电子"
            case .booksAcademic: return "图书学业"
            case .petSupplies: return "宠物用品"
            case .other: return "其他"
            }
        }

        var iconName: String {
            switch self {
            case .homeAppliances: return "sofa.fill"
            case .dailyEssentials: return "basket.fill"
            case .fashionAccessories: return "tshirt.fill"
            case .beautyCare: return "sparkles"
            case .sportsOutdoors: return "figure.run"
            case .digitalElectronics: return "laptopcomputer"
            case .booksAcademic: return "books.vertical.fill"
            case .petSupplies: return "pawprint.fill"
            case .other: return "shippingbox.fill"
            }
        }
    }

    enum Condition: String, Codable, CaseIterable {
        case new = "new"
        case likeNew = "like_new"
        case good = "good"
        case fair = "fair"
        case poor = "poor"

        init(normalizing rawValue: String) {
            self = Self(rawValue: rawValue.lowercased()) ?? .good
        }

        static func displayName(for rawValue: String) -> String {
            Self(normalizing: rawValue).displayName
        }

        var displayName: String {
            switch self {
            case .new: return "全新"
            case .likeNew: return "99新"
            case .good: return "良好"
            case .fair: return "一般"
            case .poor: return "明显使用"
            }
        }
    }
}

/// A manually selected marketplace area. This stays separate from device
/// location, so Marketplace never requests or stores GPS coordinates.
enum MarketplaceRegion: String, Codable, CaseIterable, Identifiable {
    case greaterTorontoArea = "greater_toronto_area"
    case hamilton
    case waterlooRegion = "waterloo_region"
    case guelph
    case ottawa
    case montreal
    case metroVancouver = "metro_vancouver"
    case calgary
    case edmonton
    case halifax
    case winnipeg
    case oshawaDurham = "oshawa_durham"
    case kingston
    case peterborough
    case niagaraRegion = "niagara_region"
    case thunderBay = "thunder_bay"
    case otherCanada = "other_canada"
    case unitedStates = "united_states"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .greaterTorontoArea: return L10n.tr("Greater Toronto Area", "大多伦多地区")
        case .hamilton: return "Hamilton"
        case .waterlooRegion: return L10n.tr("Waterloo Region", "滑铁卢地区")
        case .guelph: return "Guelph"
        case .ottawa: return "Ottawa"
        case .montreal: return "Montréal"
        case .metroVancouver: return L10n.tr("Metro Vancouver", "大温哥华地区")
        case .calgary: return "Calgary"
        case .edmonton: return "Edmonton"
        case .halifax: return "Halifax"
        case .winnipeg: return "Winnipeg"
        case .oshawaDurham: return L10n.tr("Oshawa / Durham", "奥沙瓦 / 杜林区")
        case .kingston: return "Kingston"
        case .peterborough: return "Peterborough"
        case .niagaraRegion: return L10n.tr("Niagara Region", "尼亚加拉地区")
        case .thunderBay: return "Thunder Bay"
        case .otherCanada: return L10n.tr("Other Canada", "加拿大其他地区")
        case .unitedStates: return L10n.tr("United States", "美国")
        }
    }
}

enum MarketplaceRegionPreference {
    private static let keyPrefix = "marketplace.selected-region."

    static func selected(for userID: UUID?) -> MarketplaceRegion? {
        guard let userID,
              let rawValue = UserDefaults.standard.string(
                forKey: keyPrefix + userID.uuidString.lowercased()
              )
        else { return nil }
        return MarketplaceRegion(rawValue: rawValue)
    }

    static func save(_ region: MarketplaceRegion, for userID: UUID?) {
        guard let userID else { return }
        UserDefaults.standard.set(
            region.rawValue,
            forKey: keyPrefix + userID.uuidString.lowercased()
        )
    }
}
