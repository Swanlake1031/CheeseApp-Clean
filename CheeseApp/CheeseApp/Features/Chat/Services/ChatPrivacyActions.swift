//
//  ChatPrivacyActions.swift
//  CheeseApp
//
//  Feature-owned chat settings, block/report actions, and read markers.
//

import Foundation
import Supabase

struct ChatPrivacyActions {
    private let supabase = SupabaseManager.shared

    func fetchMutedConversationIDs(userId: UUID) async -> Set<UUID> {
        await fetchConversationSettingsIDSet(
            userId: userId,
            flagColumn: "is_muted"
        )
    }

    func fetchManualUnreadConversationIDs(userId: UUID) async -> Set<UUID> {
        await fetchConversationSettingsIDSet(
            userId: userId,
            flagColumn: "manual_unread"
        )
    }

    func fetchHiddenConversationUntilMap(userId: UUID) async -> [UUID: Date] {
        do {
            let rows: [HiddenConversationUntilRow] = try await supabase
                .database("user_conversation_settings")
                .select("conversation_id,hide_until_at")
                .eq("user_id", value: userId.uuidString)
                .execute()
                .value

            return Dictionary(uniqueKeysWithValues: rows.compactMap { row in
                guard let hideUntilAt = row.hideUntilAt else { return nil }
                return (row.conversationId, hideUntilAt)
            })
        } catch {
            return [:]
        }
    }

    func fetchMutedGroupIDs(userId: UUID) async -> Set<UUID> {
        await fetchGroupSettingsIDSet(
            userId: userId,
            flagColumn: "is_muted"
        )
    }

    func fetchDirectConversationSettings(conversationId: UUID) async -> DirectConversationSettings {
        let userId: UUID
        do {
            userId = try await AuthService.shared.requireAuthUserId()
        } catch {
            return .default
        }

        do {
            let rows: [ConversationSettingsRow] = try await supabase
                .database("user_conversation_settings")
                .select("is_muted,clear_before_at,manual_unread,hide_until_at")
                .eq("user_id", value: userId.uuidString)
                .eq("conversation_id", value: conversationId.uuidString)
                .limit(1)
                .execute()
                .value

            guard let row = rows.first else {
                return .default
            }

            return DirectConversationSettings(
                isMuted: row.isMuted,
                clearBeforeAt: row.clearBeforeAt,
                manualUnread: row.manualUnread,
                hideUntilAt: row.hideUntilAt
            )
        } catch {
            return .default
        }
    }

    func fetchGroupConversationSettings(groupId: UUID) async -> GroupConversationSettings {
        let userId: UUID
        do {
            userId = try await AuthService.shared.requireAuthUserId()
        } catch {
            return .default
        }

        do {
            let rows: [GroupConversationSettingsRow] = try await supabase
                .database("user_chat_group_settings")
                .select("is_muted")
                .eq("user_id", value: userId.uuidString)
                .eq("group_id", value: groupId.uuidString)
                .limit(1)
                .execute()
                .value

            guard let row = rows.first else {
                return .default
            }
            return GroupConversationSettings(isMuted: row.isMuted)
        } catch {
            return .default
        }
    }

    func persistConversationMute(conversationId: UUID, isMuted: Bool) async throws {
        let settings = await fetchDirectConversationSettings(conversationId: conversationId)
        try await saveConversationSettings(
            conversationId: conversationId,
            isMuted: isMuted,
            clearBeforeAt: settings.clearBeforeAt,
            manualUnread: settings.manualUnread,
            hideUntilAt: settings.hideUntilAt
        )
    }

    func clearConversationHistory(conversationId: UUID) async throws -> Date {
        let clearedAt = Date()
        let settings = await fetchDirectConversationSettings(conversationId: conversationId)
        try await saveConversationSettings(
            conversationId: conversationId,
            isMuted: settings.isMuted,
            clearBeforeAt: clearedAt,
            manualUnread: false,
            hideUntilAt: settings.hideUntilAt
        )
        return clearedAt
    }

    func setConversationManualUnread(
        conversationId: UUID,
        manualUnread: Bool
    ) async throws {
        let userId = try await AuthService.shared.requireAuthUserId()
        let insertPayload = ConversationManualUnreadInsert(
            userId: userId,
            conversationId: conversationId,
            manualUnread: manualUnread
        )
        try await insertOrUpdateByUserTarget(
            table: "user_conversation_settings",
            insertPayload: insertPayload,
            updatePayload: ConversationManualUnreadUpdate(
                manualUnread: manualUnread
            ),
            userId: userId,
            targetColumn: "conversation_id",
            targetId: conversationId,
            normalizeError: { error in
                normalizedPrivacyError(from: error)
            }
        )
    }

    func hideConversation(conversationId: UUID) async throws {
        let settings = await fetchDirectConversationSettings(conversationId: conversationId)
        let hideUntilAt = Date()
        try await saveConversationSettings(
            conversationId: conversationId,
            isMuted: settings.isMuted,
            clearBeforeAt: settings.clearBeforeAt,
            manualUnread: false,
            hideUntilAt: hideUntilAt
        )
    }

    func deleteConversation(conversationId: UUID) async throws {
        let settings = await fetchDirectConversationSettings(conversationId: conversationId)
        let deleteAt = Date()
        try await saveConversationSettings(
            conversationId: conversationId,
            isMuted: settings.isMuted,
            clearBeforeAt: deleteAt,
            manualUnread: false,
            hideUntilAt: deleteAt
        )
    }

    func persistGroupConversationMute(groupId: UUID, isMuted: Bool) async throws {
        do {
            try await saveGroupConversationSettings(groupId: groupId, isMuted: isMuted)
        } catch {
            throw normalizedGroupDetailsError(from: error)
        }
    }

    func saveGroupConversationReadMarker(groupId: UUID, lastReadAt: Date) async throws {
        try await saveGroupLastReadAt(groupId: groupId, lastReadAt: lastReadAt)
    }

    func markConversationRead(conversationId: UUID) async {
        do {
            let userId = try await AuthService.shared.requireAuthUserId()
            _ = try await supabase.client
                .rpc(
                    "mark_messages_as_read",
                    params: ChatMarkMessagesAsReadParams(
                        pConversationId: conversationId,
                        pUserId: userId
                    )
                )
                .execute()
        } catch {
        }

        do {
            try await setConversationManualUnread(conversationId: conversationId, manualUnread: false)
        } catch {
        }
    }

    func isUserBlocked(with otherUserId: UUID) async -> Bool {
        let userId: UUID
        do {
            userId = try await AuthService.shared.requireAuthUserId()
        } catch {
            return false
        }

        do {
            let blocked: Bool = try await supabase.client
                .rpc(
                    "is_user_blocked",
                    params: ChatIsUserBlockedParams(
                        pUserA: userId,
                        pUserB: otherUserId
                    )
                )
                .execute()
                .value
            return blocked
        } catch {
            return false
        }
    }

    func fetchBlockRelation(with otherUserId: UUID) async -> UserBlockRelation {
        let userId: UUID
        do {
            userId = try await AuthService.shared.requireAuthUserId()
        } catch {
            return .none
        }

        do {
            let rows: [UserBlockRow] = try await supabase
                .database("user_blocks")
                .select("blocker_id,blocked_id,blocked_at")
                .or(
                    "and(blocker_id.eq.\(userId.uuidString),blocked_id.eq.\(otherUserId.uuidString)),and(blocker_id.eq.\(otherUserId.uuidString),blocked_id.eq.\(userId.uuidString))"
                )
                .execute()
                .value

            let blockedByMe = rows.contains {
                $0.blockerId == userId && $0.blockedId == otherUserId
            }
            let blockedByOther = rows.contains {
                $0.blockerId == otherUserId && $0.blockedId == userId
            }

            return UserBlockRelation(
                isBlockedByMe: blockedByMe,
                isBlockedByOther: blockedByOther
            )
        } catch {
            return .none
        }
    }

    func setUserBlocked(_ otherUserId: UUID, blocked: Bool) async throws {
        let userId = try await AuthService.shared.requireAuthUserId()

        if blocked {
            do {
                try await supabase
                    .database("user_blocks")
                    .insert(
                        UserBlockInsert(
                            blockerId: userId,
                            blockedId: otherUserId
                        )
                    )
                    .execute()
            } catch {
                if !isDuplicateKeyError(error) {
                    throw normalizedPrivacyError(from: error)
                }
            }
        } else {
            do {
                try await supabase
                    .database("user_blocks")
                    .delete()
                    .eq("blocker_id", value: userId.uuidString)
                    .eq("blocked_id", value: otherUserId.uuidString)
                    .execute()
            } catch {
                throw normalizedPrivacyError(from: error)
            }
        }
    }

    func fetchBlockedUsers() async throws -> [BlockedUserSummary] {
        let userId = try await AuthService.shared.requireAuthUserId()

        do {
            let rows: [BlockedUserRpcRow] = try await supabase.client
                .rpc("get_blocked_users", params: ChatGetBlockedUsersParams(pUserId: userId))
                .execute()
                .value

            return rows.map {
                BlockedUserSummary(
                    id: $0.blockedUserId,
                    displayName: $0.blockedUserName,
                    avatarURL: $0.blockedUserAvatar,
                    blockedAt: $0.blockedAt
                )
            }
        } catch {
            throw normalizedPrivacyError(from: error)
        }
    }

    func reportUser(
        reportedUserId: UUID,
        conversationId: UUID?,
        reason: String,
        details: String?
    ) async throws {
        let reporterId = try await AuthService.shared.requireAuthUserId()
        let normalizedReason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedReason.isEmpty else {
            throw NSError(
                domain: "",
                code: 400,
                userInfo: [NSLocalizedDescriptionKey: "请选择举报原因。"]
            )
        }

        do {
            try await supabase
                .database("user_reports")
                .insert(
                    UserReportInsert(
                        reporterId: reporterId,
                        reportedUserId: reportedUserId,
                        conversationId: conversationId,
                        reason: normalizedReason,
                        details: sanitizedOptionalText(details)
                    )
                )
                .execute()
        } catch {
            throw normalizedPrivacyError(from: error)
        }
    }

    private func fetchConversationSettingsIDSet(
        userId: UUID,
        flagColumn: String
    ) async -> Set<UUID> {
        do {
            let rows: [ConversationIDRow] = try await supabase
                .database("user_conversation_settings")
                .select("conversation_id")
                .eq("user_id", value: userId.uuidString)
                .eq(flagColumn, value: true)
                .execute()
                .value
            return Set(rows.map(\.conversationId))
        } catch {
            return []
        }
    }

    private func fetchGroupSettingsIDSet(
        userId: UUID,
        flagColumn: String
    ) async -> Set<UUID> {
        do {
            let rows: [GroupIDRow] = try await supabase
                .database("user_chat_group_settings")
                .select("group_id")
                .eq("user_id", value: userId.uuidString)
                .eq(flagColumn, value: true)
                .execute()
                .value
            return Set(rows.map(\.groupId))
        } catch {
            return []
        }
    }

    private func saveConversationSettings(
        conversationId: UUID,
        isMuted: Bool,
        clearBeforeAt: Date?,
        manualUnread: Bool,
        hideUntilAt: Date?
    ) async throws {
        let userId = try await AuthService.shared.requireAuthUserId()
        let insertPayload = ConversationSettingsInsert(
            userId: userId,
            conversationId: conversationId,
            isMuted: isMuted,
            clearBeforeAt: clearBeforeAt,
            manualUnread: manualUnread,
            hideUntilAt: hideUntilAt
        )
        try await insertOrUpdateByUserTarget(
            table: "user_conversation_settings",
            insertPayload: insertPayload,
            updatePayload: ConversationSettingsUpdate(
                isMuted: isMuted,
                clearBeforeAt: clearBeforeAt,
                manualUnread: manualUnread,
                hideUntilAt: hideUntilAt
            ),
            userId: userId,
            targetColumn: "conversation_id",
            targetId: conversationId,
            normalizeError: { error in
                normalizedPrivacyError(from: error)
            }
        )
    }

    private func saveGroupConversationSettings(
        groupId: UUID,
        isMuted: Bool
    ) async throws {
        let userId = try await AuthService.shared.requireAuthUserId()
        let insertPayload = GroupConversationSettingsInsert(
            userId: userId,
            groupId: groupId,
            isMuted: isMuted
        )
        try await insertOrUpdateByUserTarget(
            table: "user_chat_group_settings",
            insertPayload: insertPayload,
            updatePayload: GroupConversationSettingsUpdate(
                isMuted: isMuted
            ),
            userId: userId,
            targetColumn: "group_id",
            targetId: groupId,
            normalizeError: { $0 }
        )
    }

    private func saveGroupLastReadAt(
        groupId: UUID,
        lastReadAt: Date
    ) async throws {
        let userId = try await AuthService.shared.requireAuthUserId()
        let insertPayload = GroupConversationReadMarkerInsert(
            userId: userId,
            groupId: groupId,
            lastReadAt: lastReadAt
        )
        try await insertOrUpdateByUserTarget(
            table: "user_chat_group_settings",
            insertPayload: insertPayload,
            updatePayload: GroupConversationReadMarkerUpdate(
                lastReadAt: lastReadAt
            ),
            userId: userId,
            targetColumn: "group_id",
            targetId: groupId,
            normalizeError: { $0 }
        )
    }

    private func insertOrUpdateByUserTarget<InsertPayload: Encodable, UpdatePayload: Encodable>(
        table: String,
        insertPayload: InsertPayload,
        updatePayload: UpdatePayload,
        userId: UUID,
        targetColumn: String,
        targetId: UUID,
        normalizeError: (Error) -> Error
    ) async throws {
        do {
            try await supabase
                .database(table)
                .insert(insertPayload)
                .execute()
            return
        } catch {
            guard isDuplicateKeyError(error) else {
                throw normalizeError(error)
            }
        }

        do {
            try await supabase
                .database(table)
                .update(updatePayload)
                .eq("user_id", value: userId.uuidString)
                .eq(targetColumn, value: targetId.uuidString)
                .execute()
        } catch {
            throw normalizeError(error)
        }
    }

    private func normalizedPrivacyError(from error: Error) -> Error {
        let lower = error.localizedDescription.lowercased()
        if lower.contains("row-level security")
            || lower.contains("permission denied")
            || lower.contains("policy") {
            return NSError(
                domain: "",
                code: 403,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "当前账号没有权限执行该聊天隐私操作。"
                ]
            )
        }

        return error
    }

    private func normalizedGroupDetailsError(from error: Error) -> Error {
        let lower = error.localizedDescription.lowercased()
        if lower.contains("row-level security")
            || lower.contains("permission denied")
            || lower.contains("policy") {
            return NSError(
                domain: "",
                code: 403,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "当前账号没有权限执行群聊详情操作。"
                ]
            )
        }

        return error
    }

    private func isDuplicateKeyError(_ error: Error) -> Bool {
        let lower = error.localizedDescription.lowercased()
        return lower.contains("duplicate key")
            || lower.contains("already exists")
            || lower.contains("23505")
            || lower.contains("conflict")
    }

    private func sanitizedOptionalText(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func resolvedDisplayName(fullName: String?, email: String?) -> String {
        if let fullName = fullName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !fullName.isEmpty {
            return fullName
        }
        if let email,
           let localPart = email.split(separator: "@").first,
           !localPart.isEmpty {
            return String(localPart)
        }
        return "已注销"
    }
}
