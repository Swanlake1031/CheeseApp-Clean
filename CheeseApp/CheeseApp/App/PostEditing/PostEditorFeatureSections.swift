// App-level sections shared by the multi-feature post editor.
import SwiftUI

struct SecondhandBasicInfoSection: View {
    @Binding var title: String
    @Binding var price: String
    @Binding var originalPrice: String
    let iconColor: Color

    init(
        title: Binding<String>,
        price: Binding<String>,
        originalPrice: Binding<String>,
        iconColor: Color = .secondary
    ) {
        self._title = title
        self._price = price
        self._originalPrice = originalPrice
        self.iconColor = iconColor
    }

    var body: some View {
        PostFormSection(title: "物品信息") {
            PostFormTextField(
                icon: "tag",
                iconColor: iconColor,
                placeholder: "物品名称",
                text: $title
            )
            PostCurrencyPriceField(
                label: "卖价",
                placeholder: "输入卖价",
                iconColor: iconColor,
                text: $price
            )
            PostCurrencyPriceField(
                label: "原价",
                placeholder: "选填",
                iconColor: iconColor,
                text: $originalPrice
            )
        }
    }
}

struct SecondhandConditionSection: View {
    @Binding var selection: String
    let accentColor: Color

    init(selection: Binding<String>, accentColor: Color = .orange) {
        self._selection = selection
        self.accentColor = accentColor
    }

    var body: some View {
        PostFormSection(title: "成色") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(SecondhandPost.Condition.allCases, id: \.rawValue) { condition in
                        PostChipButton(
                            title: condition.displayName,
                            isSelected: selection == condition.rawValue,
                            selectedColor: accentColor
                        ) {
                            selection = condition.rawValue
                        }
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }
}

struct SecondhandNegotiableSection: View {
    @Binding var isNegotiable: Bool
    let accentColor: Color

    init(isNegotiable: Binding<Bool>, accentColor: Color = .secondary) {
        self._isNegotiable = isNegotiable
        self.accentColor = accentColor
    }

    var body: some View {
        PostFormSection(title: "交易设置") {
            Toggle(isOn: $isNegotiable) {
                HStack(spacing: 10) {
                    Image(systemName: "tag.circle")
                        .foregroundColor(accentColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.tr("Negotiable", "可议价"))
                            .font(.system(size: 15, weight: .semibold))
                        Text(
                            isNegotiable
                            ? L10n.tr("Open to offers", "买家可议价")
                            : L10n.tr("Fixed price only", "标价固定，不接受议价")
                        )
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    }
                }
            }
            .padding()
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }
}
