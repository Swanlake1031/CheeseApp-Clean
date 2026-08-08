//
//  SupabaseClient.swift
//  CheeseApp
//
//  Supabase 客户端配置入口
//

import Foundation
import Supabase

final class SupabaseManager {

    static let shared = SupabaseManager()

    let client: SupabaseClient

    private init() {
        let config = SupabaseConfig.load()
        guard let url = URL(string: config.url) else {
            fatalError("Invalid Supabase URL")
        }
        client = SupabaseClient(
            supabaseURL: url,
            supabaseKey: config.publishableKey,
            options: SupabaseClientOptions(
                auth: .init(
                    redirectToURL: config.authRedirectURL,
                    emitLocalSessionAsInitialSession: true
                )
            )
        )
    }

    var auth: AuthClient {
        return client.auth
    }
    
    func database(_ table: String) -> PostgrestQueryBuilder {
        return client.from(table)
    }
    
    func storage(_ bucket: String) -> StorageFileApi {
        return client.storage.from(bucket)
    }
    
    var realtime: RealtimeClientV2 {
        return client.realtimeV2
    }
}

private struct SupabaseConfig {
    let url: String
    let publishableKey: String
    let authRedirectURL: URL?

    static func load(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        infoDictionary: [String: Any] = Bundle.main.infoDictionary ?? [:]
    ) -> SupabaseConfig {
        let defaultAuthRedirectURL = "cheeseapp://auth/callback"

        let configuredURL = firstConfiguredValue(
            environment["SUPABASE_URL"],
            infoDictionary["SUPABASE_URL"] as? String
        )
        let configuredKey = firstConfiguredValue(
            environment["SUPABASE_PUBLISHABLE_KEY"],
            infoDictionary["SUPABASE_PUBLISHABLE_KEY"] as? String
        )
        let configuredRedirectURL = firstConfiguredValue(
            environment["SUPABASE_AUTH_REDIRECT_URL"],
            infoDictionary["SUPABASE_AUTH_REDIRECT_URL"] as? String
        )

        guard let configuredURL, let configuredKey else {
            // Unit tests use injected service loaders and should not require a
            // developer's local backend configuration merely to load the app module.
            if environment["XCTestConfigurationFilePath"] != nil {
                return SupabaseConfig(
                    url: "https://example.supabase.co",
                    publishableKey: "test-publishable-key",
                    authRedirectURL: URL(string: defaultAuthRedirectURL)
                )
            }
            preconditionFailure(
                "Missing SUPABASE_URL or SUPABASE_PUBLISHABLE_KEY. "
                + "Configure the Xcode scheme environment or build settings; see HANDOFF.md."
            )
        }

        return SupabaseConfig(
            url: configuredURL,
            publishableKey: configuredKey,
            authRedirectURL: URL(string: configuredRedirectURL ?? defaultAuthRedirectURL)
        )
    }

    private static func firstConfiguredValue(_ values: String?...) -> String? {
        values.lazy.compactMap { value in
            guard let value else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  !trimmed.hasPrefix("$("),
                  !trimmed.hasPrefix("${") else { return nil }
            return trimmed
        }.first
    }
}
