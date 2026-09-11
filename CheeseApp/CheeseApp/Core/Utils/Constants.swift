//
//  Constants.swift
//  CheeseApp
//
//  🎯 应用常量
//

import Foundation
import SwiftUI
import UIKit

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

/// Keeps selected draft media alive while the app is running. Text fields are
/// persisted by `CreateDraftStore`; UIKit images stay in memory so dismissing a
/// quick composer sheet and reopening it does not drop the current selection.
@MainActor
enum CreateComposerSessionStore {
    private static var imagesByKind: [PostKind: [UIImage]] = [:]
    private(set) static var resumableKind: PostKind?

    static func save(images: [UIImage], for kind: PostKind) {
        if images.isEmpty {
            imagesByKind.removeValue(forKey: kind)
        } else {
            imagesByKind[kind] = images
        }
        resumableKind = kind
    }

    static func images(for kind: PostKind) -> [UIImage] {
        imagesByKind[kind] ?? []
    }

    static func markResumable(_ kind: PostKind) {
        resumableKind = kind
    }

    static func clear(_ kind: PostKind) {
        imagesByKind.removeValue(forKey: kind)
        if resumableKind == kind {
            resumableKind = nil
        }
    }
}

/// UI copy never includes SQL, RPC, hostnames, tokens, or raw server messages.
enum AppErrorMessage {
    static func userMessage(for error: Error) -> String {
        if error is CancellationError { return L10n.tr("Cancelled. You can try again when ready.", "已取消，准备好后可重试。") }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost, .cannotConnectToHost:
                return L10n.tr("Connection unavailable. Check your network and try again.", "暂时无法连接，请检查网络后重试。")
            default: break
            }
        }
        let detail = String(describing: error)
        if detail.contains("content_not_allowed") || detail.contains("media_review_required") || (error as NSError).domain == "ContentSafety" {
            return L10n.tr("This content could not be published. Check the Community Rules or contact support.", "这项内容无法发布，请查看社群规则或联络客服。")
        }
        if detail.contains("account_restricted") { return L10n.tr("This account is restricted. Contact support to request a review.", "此帐号已受限制，请联络客服申请复核。") }
        return L10n.tr("Unable to complete this action. Please try again. If it continues, contact support.", "暂时无法完成操作，请重试；若问题持续，请联络客服。")
    }
}
