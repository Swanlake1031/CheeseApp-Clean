//
//  Constants.swift
//  CheeseApp
//
//  🎯 应用常量
//

import Foundation
import SwiftUI

enum AppExternalLinks {
    static let courseRadar = URL(string: "https://radar.cheeseapp.org")!

    static func courseRadar(for courseCode: String) -> URL {
        let normalizedCode = courseCode
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
            .uppercased()
        guard !normalizedCode.isEmpty,
              var components = URLComponents(
                url: courseRadar,
                resolvingAgainstBaseURL: false
              ) else {
            return courseRadar
        }

        components.queryItems = [
            URLQueryItem(name: "course", value: normalizedCode)
        ]
        components.fragment = "courses"
        return components.url ?? courseRadar
    }
}

enum CollectionLoadState: Equatable {
    case unresolved
    case initialLoading
    case empty
    case loaded
    case error(message: String)

    static func resolve(
        hasResolvedInitialLoad: Bool,
        isLoading: Bool,
        hasContent: Bool,
        errorMessage: String?
    ) -> CollectionLoadState {
        if hasContent {
            return .loaded
        }

        if let errorMessage, !errorMessage.isEmpty {
            return .error(message: errorMessage)
        }

        guard hasResolvedInitialLoad else {
            return isLoading ? .initialLoading : .unresolved
        }

        return .empty
    }
}

// ============================================
// 表名常量
// ============================================

enum Tables {
    static let profiles = "profiles"
    static let posts = "posts"
    static let postImages = "post_images"
    static let favorites = "favorites"
    static let secondhandPosts = "secondhand_posts"
    static let forumPosts = "forum_posts"
    static let comments = "comments"
    static let conversations = "conversations"
    static let messages = "messages"
}

// ============================================
// 存储桶常量
// ============================================

enum StorageBuckets {
    static let avatars = "avatars"
    static let postImages = "post-images"
    static let chatImages = "chat-images"
}

// ============================================
// 语言设置
// ============================================

enum AppLanguage: String, CaseIterable, Identifiable {
    case english = "en"
    case chinese = "zh-Hans"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .english: return "English"
        case .chinese: return "简体中文"
        }
    }
}

final class AppLanguageStore: ObservableObject {
    static let shared = AppLanguageStore()

    @Published private(set) var current: AppLanguage

    private let key = "app_language"

    private init() {
        let saved = UserDefaults.standard.string(forKey: key)
        current = AppLanguage(rawValue: saved ?? "") ?? .chinese
    }

    func setLanguage(_ language: AppLanguage) {
        guard current != language else { return }
        current = language
        UserDefaults.standard.set(language.rawValue, forKey: key)
    }

    var localeIdentifier: String {
        switch current {
        case .english:
            return "en"
        case .chinese:
            return "zh-Hans"
        }
    }
}

enum L10n {
    static func tr(_ english: String, _ chinese: String) -> String {
        guard AppLanguageStore.shared.current == .chinese else {
            return english
        }

        let transform = StringTransform("Traditional-Hans")
        return chinese.applyingTransform(transform, reverse: false) ?? chinese
    }
}

struct CreateDraftMeta: Identifiable, Hashable {
    let kind: PostKind
    let title: String
    let subtitle: String?
    let updatedAt: Date

    var id: String { kind.rawValue }
}

enum CreateDraftStore {
    private struct DraftEnvelope: Codable {
        let kind: String
        let title: String
        let subtitle: String?
        let updatedAt: Date
        let payload: Data
    }

    private static let defaults = UserDefaults.standard

    static func hasDraft(_ kind: PostKind) -> Bool {
        defaults.data(forKey: storageKey(for: kind)) != nil
    }

    static func save<Payload: Encodable>(
        kind: PostKind,
        title: String,
        subtitle: String? = nil,
        payload: Payload
    ) {
        let payloadEncoder = JSONEncoder()
        payloadEncoder.dateEncodingStrategy = .iso8601
        guard let payloadData = try? payloadEncoder.encode(payload) else { return }

        let envelope = DraftEnvelope(
            kind: kind.rawValue,
            title: title,
            subtitle: subtitle,
            updatedAt: Date(),
            payload: payloadData
        )
        let envelopeEncoder = JSONEncoder()
        envelopeEncoder.dateEncodingStrategy = .iso8601
        guard let envelopeData = try? envelopeEncoder.encode(envelope) else { return }
        defaults.set(envelopeData, forKey: storageKey(for: kind))
    }

    static func load<Payload: Decodable>(
        kind: PostKind,
        as type: Payload.Type
    ) -> Payload? {
        guard let envelope = loadEnvelope(kind) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(type, from: envelope.payload)
    }

    static func clear(_ kind: PostKind) {
        defaults.removeObject(forKey: storageKey(for: kind))
    }

    static func listMetas() -> [CreateDraftMeta] {
        PostKind.allCases.compactMap { kind in
            guard let envelope = loadEnvelope(kind) else { return nil }
            return CreateDraftMeta(
                kind: kind,
                title: envelope.title,
                subtitle: envelope.subtitle,
                updatedAt: envelope.updatedAt
            )
        }
        .sorted { $0.updatedAt > $1.updatedAt }
    }

    private static func loadEnvelope(_ kind: PostKind) -> DraftEnvelope? {
        guard let data = defaults.data(forKey: storageKey(for: kind)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(DraftEnvelope.self, from: data)
    }

    private static func storageKey(for kind: PostKind) -> String {
        "create_post_draft_\(kind.rawValue)"
    }
}
