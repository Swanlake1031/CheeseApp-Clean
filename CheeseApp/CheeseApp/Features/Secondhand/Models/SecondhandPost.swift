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
