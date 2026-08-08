import {
  buildDescription,
  formatPriceCAD,
  formatRelativeTimeText,
  localizeNegotiable,
  localizeSecondhandCategory,
  localizeSecondhandCondition,
  normalizeText
} from "../utils/format.js";

export async function fetchSecondhandMetadata({
  postID,
  config,
  fetchSingleRow,
  firstImageURL,
  fallbackDescription,
  fallbackTitle,
  unavailableMetadata
}) {
  const row = await fetchSingleRow({
    config,
    table: "secondhand_posts_view",
    select:
      "id,title,description,price,condition,images,is_expired,category,is_negotiable,created_at,user_name,user_avatar",
    postID
  });

  if (!row || row.is_expired === true) {
    return unavailableMetadata("secondhand");
  }

  const conditionLabel = localizeSecondhandCondition(row.condition);
  const negotiableLabel = localizeNegotiable(row.is_negotiable);
  const categoryLabel = localizeSecondhandCategory(row.category);
  const postedAtText = formatRelativeTimeText(row.created_at);
  return {
    status: "ok",
    title: row.title || fallbackTitle("secondhand"),
    description: buildDescription([
      formatPriceCAD(row.price),
      conditionLabel,
      row.description
    ], fallbackDescription("secondhand")),
    imageURL: firstImageURL(row.images),
    chips: [
      formatPriceCAD(row.price),
      conditionLabel
    ],
    detailRows: [
      { label: "Category", value: categoryLabel }
    ],
    priceText: formatPriceCAD(row.price),
    conditionLabel,
    negotiableLabel,
    categoryLabel,
    sellerName: normalizeText(row.user_name),
    sellerAvatarURL: normalizeText(row.user_avatar),
    postedAtText,
    bodyTitle: "Description",
    bodyText: row.description
  };
}
