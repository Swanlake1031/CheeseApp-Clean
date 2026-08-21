import {
  buildDescription,
  fallbackDescription,
  fallbackTitle,
  formatForumStat,
  formatRelativeTimeText
} from "../utils/format.js";

export async function fetchForumMetadata({
  postID,
  config,
  fetchSingleRow,
  firstImageURL,
  unavailableMetadata
}) {
  const row = await fetchSingleRow({
    config,
    table: "rpc/get_public_forum_share_post",
    idParameter: "p_post_id",
    select:
      "id,title,description,board_name,is_anonymous,images,created_at,user_name,user_avatar,like_count,comment_count,view_count",
    postID
  });

  if (!row) {
    return unavailableMetadata("forum");
  }

  const imageURLs = Array.isArray(row.images)
    ? row.images
        .slice()
        .sort((left, right) => {
          const lhs = Number.isFinite(left?.order_index) ? left.order_index : Number.MAX_SAFE_INTEGER;
          const rhs = Number.isFinite(right?.order_index) ? right.order_index : Number.MAX_SAFE_INTEGER;
          return lhs - rhs;
        })
        .map((item) => item?.url)
        .filter((value) => typeof value === "string" && value.trim())
    : [];

  return {
    status: "ok",
    title: row.title || fallbackTitle("forum"),
    description: buildDescription([
      row.board_name,
      row.is_anonymous ? "匿名帖子" : null,
      row.description
    ], fallbackDescription("forum")),
    imageURL: firstImageURL(row.images),
    imageURLs,
    chips: [
      row.board_name || "论坛",
      row.is_anonymous ? "匿名" : "校园"
    ],
    detailRows: [],
    bodyTitle: "Post",
    bodyText: row.description,
    boardLabel: row.board_name || "论坛",
    postedAtText: formatRelativeTimeText(row.created_at),
    authorName: row.user_name || "Cheese 用户",
    authorAvatarURL: row.user_avatar || "",
    isAnonymous: row.is_anonymous === true,
    likeText: formatForumStat(row.like_count, "赞"),
    commentText: formatForumStat(row.comment_count, "评论"),
    viewText: formatForumStat(row.view_count, "浏览")
  };
}
