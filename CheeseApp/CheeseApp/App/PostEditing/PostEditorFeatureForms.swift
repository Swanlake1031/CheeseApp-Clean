// App-level forms that compose feature-specific edit fields.
import SwiftUI

struct SecondhandPostEditFormView: View {
    let accentColor: Color
    @Binding var title: String
    @Binding var priceText: String
    @Binding var originalPriceText: String
    @Binding var category: SecondhandPost.Category
    @Binding var condition: String
    @Binding var isNegotiable: Bool
    @Binding var description: String
    @Binding var selectedImages: [UIImage]

    var body: some View {
        VStack(spacing: 20) {
            SecondhandBasicInfoSection(
                title: $title,
                price: $priceText,
                originalPrice: $originalPriceText,
                iconColor: accentColor
            )

            PostFormSection(title: L10n.tr("Category", "分类")) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(SecondhandPost.Category.allCases, id: \.rawValue) { option in
                            PostChipButton(
                                title: option.displayName,
                                isSelected: category == option,
                                selectedColor: accentColor
                            ) {
                                category = option
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            SecondhandConditionSection(
                selection: $condition,
                accentColor: accentColor
            )

            SecondhandNegotiableSection(
                isNegotiable: $isNegotiable,
                accentColor: accentColor
            )

            PostFormSection(title: "详细描述") {
                PostTextEditorCard(
                    text: $description,
                    placeholder: "描述一下商品的新旧程度、使用情况、交易方式等...",
                    minHeight: 100
                )
            }

            PostFormSection(title: "图片（可选）") {
                PostImageSection(selectedImages: $selectedImages)
            }
        }
    }
}
