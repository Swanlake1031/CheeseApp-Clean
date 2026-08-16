import SwiftUI

/// Independent board pages show the short description inline. The full rules
/// remain a small sheet so opening them does not create another navigation layer.
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
