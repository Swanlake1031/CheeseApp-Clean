import Foundation
import SwiftUI
import Supabase

struct MentionCandidate: Decodable, Identifiable, Hashable {
    let id: UUID
    let fullName: String
    let avatarURL: String?
    let university: String?

    enum CodingKeys: String, CodingKey {
        case id
        case fullName = "full_name"
        case avatarURL = "avatar_url"
        case university
    }
}

struct MentionQuery: Equatable {
    let range: Range<String.Index>
    let value: String
}

enum MentionTextLogic {
    static func query(in text: String) -> MentionQuery? {
        guard let atIndex = text.lastIndex(of: "@") else { return nil }
        let valueStart = text.index(after: atIndex)
        let value = String(text[valueStart...])
        guard value.count <= 40,
              !value.contains(where: { $0.isWhitespace || $0.isNewline })
        else { return nil }
        return MentionQuery(
            range: atIndex..<text.endIndex,
            value: value
        )
    }

    static func insert(
        _ candidate: MentionCandidate,
        into text: String
    ) -> String {
        guard let query = query(in: text) else { return text }
        var updated = text
        updated.replaceSubrange(
            query.range,
            with: "@\(candidate.fullName) "
        )
        return updated
    }

    static func activeUserIDs(
        in text: String,
        selected: [MentionCandidate]
    ) -> [UUID] {
        var seen: Set<UUID> = []
        return selected.compactMap { candidate in
            guard text.contains("@\(candidate.fullName)"),
                  seen.insert(candidate.id).inserted
            else { return nil }
            return candidate.id
        }
    }
}

@MainActor
final class MentionService {
    static let shared = MentionService()

    private let supabase = SupabaseManager.shared

    private init() {}

    func search(query: String, limit: Int = 8) async throws -> [MentionCandidate] {
        let rows: [MentionCandidate] = try await supabase.client
            .rpc(
                "search_profiles",
                params: MentionSearchParams(
                    query: query,
                    limit: min(max(limit, 1), 20)
                )
            )
            .execute()
            .value
        let currentUserID = AuthService.shared.currentUser?.id
        return rows.filter { $0.id != currentUserID }
    }

    func fetch(
        postID: UUID,
        commentID: UUID? = nil
    ) async throws -> [MentionCandidate] {
        try await supabase.client
            .rpc(
                "get_content_mentions",
                params: GetMentionsParams(
                    postID: postID,
                    commentID: commentID
                )
            )
            .execute()
            .value
    }
}

struct MentionSuggestionPanel: View {
    @Binding var text: String
    @Binding var selectedMentions: [MentionCandidate]
    var maxVisibleCandidates: Int = 6

    @State private var candidates: [MentionCandidate] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var searchTask: Task<Void, Never>?

    private var activeQuery: MentionQuery? {
        MentionTextLogic.query(in: text)
    }

    var body: some View {
        Group {
            if activeQuery != nil {
                VStack(alignment: .leading, spacing: 8) {
                    if isLoading {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("正在查找用户…")
                        }
                        .font(.system(size: 12))
                        .foregroundStyle(AppColors.textMuted)
                    } else if let errorMessage {
                        Text(errorMessage)
                            .font(.system(size: 12))
                            .foregroundStyle(.red)
                    } else if candidates.isEmpty {
                        Text("没有匹配的用户")
                            .font(.system(size: 12))
                            .foregroundStyle(AppColors.textMuted)
                    } else {
                        ForEach(candidates.prefix(max(1, maxVisibleCandidates))) { candidate in
                            Button {
                                select(candidate)
                            } label: {
                                MentionCandidateRow(candidate: candidate)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(10)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .shadow(color: .black.opacity(0.06), radius: 8, y: 3)
            }
        }
        .onChange(of: text) { _, _ in
            scheduleSearch()
        }
        .onDisappear {
            searchTask?.cancel()
        }
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        guard let activeQuery else {
            candidates = []
            errorMessage = nil
            isLoading = false
            return
        }

        let query = activeQuery.value
        isLoading = true
        errorMessage = nil
        searchTask = Task {
            if !query.isEmpty {
                try? await Task.sleep(nanoseconds: 220_000_000)
            }
            guard !Task.isCancelled else { return }
            do {
                let results = try await MentionService.shared.search(query: query)
                guard !Task.isCancelled,
                      MentionTextLogic.query(in: text)?.value == query
                else { return }
                candidates = results
                isLoading = false
            } catch {
                guard !Task.isCancelled else { return }
                candidates = []
                isLoading = false
                errorMessage = error.localizedDescription
            }
        }
    }

    private func select(_ candidate: MentionCandidate) {
        text = MentionTextLogic.insert(candidate, into: text)
        if !selectedMentions.contains(where: { $0.id == candidate.id }) {
            selectedMentions.append(candidate)
        }
        candidates = []
        errorMessage = nil
    }
}

struct MentionedProfilesView: View {
    let postID: UUID
    var commentID: UUID?

    @State private var mentions: [MentionCandidate] = []

    var body: some View {
        Group {
            if !mentions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(mentions) { mention in
                            NavigationLink {
                                UserPostsView(userId: mention.id)
                            } label: {
                                Text("@\(mention.fullName)")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(AppColors.link)
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 5)
                                    .background(AppColors.link.opacity(0.1))
                                    .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .task(id: "\(postID.uuidString):\(commentID?.uuidString ?? "")") {
            do {
                mentions = try await MentionService.shared.fetch(
                    postID: postID,
                    commentID: commentID
                )
            } catch {
                mentions = []
            }
        }
    }
}

private struct MentionCandidateRow: View {
    let candidate: MentionCandidate

    var body: some View {
        HStack(spacing: 10) {
            if let avatarURL = candidate.avatarURL,
               let url = URL(string: avatarURL) {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    avatarFallback
                }
                .frame(width: 34, height: 34)
                .clipShape(Circle())
            } else {
                avatarFallback
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(candidate.fullName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AppColors.textPrimary)
                if let university = candidate.university {
                    Text(university)
                        .font(.system(size: 11))
                        .foregroundStyle(AppColors.textMuted)
                        .lineLimit(1)
                }
            }
            Spacer()
            Image(systemName: "at")
                .foregroundStyle(AppColors.link)
        }
        .contentShape(Rectangle())
    }

    private var avatarFallback: some View {
        Circle()
            .fill(AppColors.accent.opacity(0.2))
            .frame(width: 34, height: 34)
            .overlay {
                Text(String(candidate.fullName.prefix(1)).uppercased())
                    .font(.system(size: 12, weight: .bold))
            }
    }
}

private struct MentionSearchParams: Encodable {
    let query: String
    let limit: Int

    enum CodingKeys: String, CodingKey {
        case query = "p_query"
        case limit = "p_limit"
    }
}

private struct GetMentionsParams: Encodable {
    let postID: UUID
    let commentID: UUID?

    enum CodingKeys: String, CodingKey {
        case postID = "p_post_id"
        case commentID = "p_comment_id"
    }
}
