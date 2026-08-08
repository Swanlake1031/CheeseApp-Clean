import SwiftUI

/// Board descriptions live directly in `ForumListView` when a channel is selected.
/// Rules remain a small sheet instead of introducing another board-detail page.
struct ForumBoardRulesSheet: View {
    let board: ForumBoard

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(board.rules)
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .navigationTitle(L10n.tr("Board Rules", "板块规则"))
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
    }
}
