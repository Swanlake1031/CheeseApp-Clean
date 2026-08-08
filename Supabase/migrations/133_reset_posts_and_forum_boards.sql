-- 133_reset_posts_and_forum_boards.sql
--
-- DESTRUCTIVE FORWARD MIGRATION
-- Deleted data:
--   * every post whose author is not an active Cheese official profile;
--   * all FK-dependent comments, reactions, favorites, reports, images,
--     mentions, feature placements, and module detail rows for those posts;
--   * non-official post-media staging rows and linked chat card payloads.
-- Preserved data:
--   * every post owned by a profile with is_official = TRUE;
--   * user accounts, profiles, follows, ordinary chat text, and course data.
-- Media safety:
--   * exact Storage identities are queued for retryable cleanup;
--   * legacy URL-only images are recorded as unresolved and are never guessed.
-- Rollback limits:
--   * a down migration cannot reconstruct deleted posts or relationships;
--   * recovery requires a database backup plus the corresponding Storage data.
-- Production order:
--   1. verify the linked project and take a database backup;
--   2. apply this migration;
--   3. verify that only official posts remain and the five boards are active;
--   4. drain exact media cleanup rows after the verification window.

BEGIN;

DO $preflight$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM public.profiles profile
    WHERE profile.is_official = TRUE
      AND profile.deactivated_at IS NULL
  ) THEN
    RAISE EXCEPTION 'Post reset aborted: no active Cheese official profile exists';
  END IF;
END;
$preflight$;

CREATE TEMP TABLE reset_post_ids (
  id UUID PRIMARY KEY,
  owner_id UUID NOT NULL
) ON COMMIT DROP;

INSERT INTO reset_post_ids (id, owner_id)
SELECT post.id, post.user_id
FROM public.posts post
WHERE NOT EXISTS (
  SELECT 1
  FROM public.profiles profile
  WHERE profile.id = post.user_id
    AND profile.is_official = TRUE
    AND profile.deactivated_at IS NULL
);

CREATE TEMP TABLE reset_comment_ids (
  id UUID PRIMARY KEY
) ON COMMIT DROP;

INSERT INTO reset_comment_ids (id)
SELECT comment.id
FROM public.comments comment
JOIN reset_post_ids reset_post ON reset_post.id = comment.post_id;

-- Preserve exact image cleanup obligations before post_images cascade away.
INSERT INTO public.post_media_cleanup_backlog (
  owner_id,
  post_image_id,
  post_id,
  bucket,
  object_path,
  stored_url,
  status,
  reason,
  candidate_count,
  next_attempt_at
)
SELECT
  reset_post.owner_id,
  image.id,
  image.post_id,
  image.bucket,
  image.object_path,
  image.url,
  CASE
    WHEN image.bucket IS NOT NULL AND image.object_path IS NOT NULL
      THEN 'pending'
    ELSE 'unresolved'
  END,
  CASE
    WHEN image.bucket IS NOT NULL AND image.object_path IS NOT NULL
      THEN 'non_official_post_reset'
    ELSE 'non_official_post_reset_legacy_identity_unknown'
  END,
  CASE
    WHEN image.bucket IS NULL OR image.object_path IS NULL THEN 0
    ELSE NULL
  END,
  NOW()
FROM public.post_images image
JOIN reset_post_ids reset_post ON reset_post.id = image.post_id
ON CONFLICT ON CONSTRAINT post_media_cleanup_source_image_key
DO UPDATE SET
  status = EXCLUDED.status,
  reason = EXCLUDED.reason,
  bucket = EXCLUDED.bucket,
  object_path = EXCLUDED.object_path,
  stored_url = EXCLUDED.stored_url,
  candidate_count = EXCLUDED.candidate_count,
  next_attempt_at = EXCLUDED.next_attempt_at,
  resolved_at = NULL,
  locked_at = NULL,
  lock_token = NULL;

-- Non-official unfinished upload operations must not publish after the reset.
INSERT INTO public.post_media_cleanup_backlog (
  owner_id,
  post_id,
  source_staging_id,
  bucket,
  object_path,
  stored_url,
  status,
  reason,
  next_attempt_at
)
SELECT
  stage.owner_id,
  stage.post_id,
  stage.id,
  stage.bucket,
  stage.object_path,
  stage.url,
  'pending',
  'non_official_post_reset_staged_asset',
  NOW()
FROM public.post_media_staging stage
WHERE NOT EXISTS (
  SELECT 1
  FROM public.profiles profile
  WHERE profile.id = stage.owner_id
    AND profile.is_official = TRUE
    AND profile.deactivated_at IS NULL
)
  AND stage.bucket IS NOT NULL
  AND stage.object_path IS NOT NULL
ON CONFLICT ON CONSTRAINT post_media_cleanup_source_staging_key
DO UPDATE SET
  status = 'pending',
  reason = EXCLUDED.reason,
  bucket = EXCLUDED.bucket,
  object_path = EXCLUDED.object_path,
  stored_url = EXCLUDED.stored_url,
  next_attempt_at = EXCLUDED.next_attempt_at,
  resolved_at = NULL,
  locked_at = NULL,
  lock_token = NULL;

DELETE FROM public.post_media_staging stage
WHERE NOT EXISTS (
  SELECT 1
  FROM public.profiles profile
  WHERE profile.id = stage.owner_id
    AND profile.is_official = TRUE
    AND profile.deactivated_at IS NULL
);

-- Keep chat text but remove cards that point at deleted content.
UPDATE public.messages message
SET metadata = message.metadata - 'shared_post_card' - 'post_contact_card'
WHERE message.metadata -> 'shared_post_card' ->> 'post_id'
        IN (SELECT id::TEXT FROM reset_post_ids)
   OR message.metadata -> 'post_contact_card' ->> 'post_id'
        IN (SELECT id::TEXT FROM reset_post_ids);

UPDATE public.group_messages message
SET metadata = message.metadata - 'shared_post_card' - 'post_contact_card'
WHERE message.metadata -> 'shared_post_card' ->> 'post_id'
        IN (SELECT id::TEXT FROM reset_post_ids)
   OR message.metadata -> 'post_contact_card' ->> 'post_id'
        IN (SELECT id::TEXT FROM reset_post_ids);

UPDATE public.conversations conversation
SET related_post_id = NULL,
    updated_at = NOW()
WHERE conversation.related_post_id IN (SELECT id FROM reset_post_ids);

DELETE FROM public.system_messages message
WHERE message.post_id IN (SELECT id FROM reset_post_ids)
   OR message.comment_id IN (SELECT id FROM reset_comment_ids);

-- Likes are polymorphic and have no target foreign key. Remove their exact
-- post/comment targets explicitly, while suppressing aggregate/push triggers
-- that should not run during a bulk reset. Other child relations cascade.
ALTER TABLE public.likes DISABLE TRIGGER USER;
ALTER TABLE public.comments DISABLE TRIGGER USER;
ALTER TABLE public.favorites DISABLE TRIGGER USER;

DELETE FROM public.likes liked
WHERE (liked.target_type = 'post' AND liked.target_id IN (SELECT id FROM reset_post_ids))
   OR (liked.target_type = 'comment' AND liked.target_id IN (SELECT id FROM reset_comment_ids));

DELETE FROM public.comments comment
WHERE comment.id IN (SELECT id FROM reset_comment_ids);

DELETE FROM public.favorites favorite
WHERE favorite.post_id IN (SELECT id FROM reset_post_ids);

ALTER TABLE public.likes ENABLE TRIGGER USER;
ALTER TABLE public.comments ENABLE TRIGGER USER;
ALTER TABLE public.favorites ENABLE TRIGGER USER;

-- Cleanup obligations intentionally have no post foreign key and therefore
-- survive this deletion.
DELETE FROM public.posts post
WHERE post.id IN (SELECT id FROM reset_post_ids);

-- Keep the original stable board IDs so existing client links and the preserved
-- official post remain valid. The explicit order is used by every board picker.
ALTER TABLE public.forum_boards
  ADD COLUMN IF NOT EXISTS display_order SMALLINT NOT NULL DEFAULT 0;

-- Prevent a custom/legacy board from occupying one of the new canonical slugs.
-- These boards are archived below and keep a deterministic, unique slug.
UPDATE public.forum_boards board
SET slug = 'archived-' || REPLACE(board.id::TEXT, '-', ''),
    status = 'archived',
    updated_at = NOW()
WHERE board.id NOT IN (
  'f0000000-0000-0000-0000-000000000001'::UUID,
  'f0000000-0000-0000-0000-000000000002'::UUID,
  'f0000000-0000-0000-0000-000000000003'::UUID,
  'f0000000-0000-0000-0000-000000000004'::UUID,
  'f0000000-0000-0000-0000-000000000005'::UUID
);

UPDATE public.forum_boards board
SET
  slug = replacement.slug,
  name = replacement.name,
  description = replacement.description,
  rules = replacement.rules,
  icon = replacement.icon,
  allows_anonymous_posts = replacement.allows_anonymous_posts,
  is_official = TRUE,
  status = 'active',
  display_order = replacement.display_order,
  created_at = NOW() + replacement.display_order * INTERVAL '1 second',
  updated_at = NOW()
FROM (
  VALUES
    (
      'f0000000-0000-0000-0000-000000000001'::UUID,
      'campus', '校园',
      '校园生活、学校信息、课程经验和实用指南。',
      '请提供真实、可核实的信息；尊重隐私；禁止造谣、骚扰、作弊交易及公开他人敏感信息。',
      'building.columns.fill', FALSE, 0::SMALLINT
    ),
    (
      'f0000000-0000-0000-0000-000000000002'::UUID,
      'interests', '兴趣',
      '社团、运动、游戏、影视、音乐及各类兴趣交流。',
      '请友善交流；活动信息应写明时间和地点；禁止欺诈、骚扰及未经许可的商业推广。',
      'sparkles', FALSE, 1::SMALLINT
    ),
    (
      'f0000000-0000-0000-0000-000000000003'::UUID,
      'gossip', '八卦',
      '校园热点、趣事、吐槽和公开事件讨论。',
      '禁止造谣、人肉搜索、泄露隐私及针对个人的恶意攻击；未经证实的信息请明确说明。',
      'bubble.left.and.text.bubble.right.fill', FALSE, 2::SMALLINT
    ),
    (
      'f0000000-0000-0000-0000-000000000004'::UUID,
      'casual-chat', '闲聊',
      '轻松聊天、日常分享、交友和没有固定主题的讨论。',
      '请保持基本礼貌；禁止刷屏、骚扰、仇恨内容、欺诈及违法交易。',
      'bubble.left.and.bubble.right.fill', FALSE, 3::SMALLINT
    ),
    (
      'f0000000-0000-0000-0000-000000000005'::UUID,
      'anonymous', '匿名',
      '匿名倾诉、提问、烦恼分享和不便公开身份的话题。',
      '匿名不代表免责；请保护自己和他人的隐私；禁止骚扰、威胁、仇恨内容及曝光个人信息。',
      'theatermasks.fill', TRUE, 4::SMALLINT
    )
) AS replacement(
  id, slug, name, description, rules, icon,
  allows_anonymous_posts, display_order
)
WHERE board.id = replacement.id;

-- There must be exactly these five visible system boards after the reset.
UPDATE public.forum_boards board
SET status = 'archived',
    updated_at = NOW()
WHERE board.id NOT IN (
  'f0000000-0000-0000-0000-000000000001'::UUID,
  'f0000000-0000-0000-0000-000000000002'::UUID,
  'f0000000-0000-0000-0000-000000000003'::UUID,
  'f0000000-0000-0000-0000-000000000004'::UUID,
  'f0000000-0000-0000-0000-000000000005'::UUID
);

CREATE INDEX IF NOT EXISTS forum_boards_display_order_idx
  ON public.forum_boards(status, display_order, id);

-- The official MSAF guide belongs in the new Campus board.
UPDATE public.forum_posts forum_post
SET board_id = 'f0000000-0000-0000-0000-000000000001'::UUID
WHERE forum_post.id = 'c0ffee00-0000-0000-0000-000000000101'::UUID
  AND EXISTS (
    SELECT 1
    FROM public.posts post
    JOIN public.profiles profile ON profile.id = post.user_id
    WHERE post.id = forum_post.id
      AND profile.is_official = TRUE
  );

-- Normalize the preserved official guide to the app's Simplified Chinese UI.
UPDATE public.posts post
SET
  title = '生病、不想做作业？你可能可以使用 MSAF',
  description = $content$功课、Quiz 或 Midterm 突然来不及完成？如果你因为生病或临时的个人情况缺席，MSAF 可能可以帮到你。

MSAF 全名是 McMaster Student Absence Form，是 McMaster 提供的缺席申报方式。符合条件的学生，可以通过它为未完成的课业申请相应安排。

如何找到 MSAF：

1. 登录 Mosaic
2. 进入 Student Center
3. 找到 Academics 区域
4. 在菜单中选择 MSAF
5. 按照页面提示填写并提交

一般的 MSAF Self-Report，基本无需说明理由（它的目的就是给你一个三天的豁免期），主要适用于短期缺席，以及占课程总成绩比例低于 25% 的项目（Midterm 也可能适用）。

提交 MSAF 后，也记得尽快联系 Instructor，确认补交、延期或其他安排。MSAF 并不代表你可以直接忽略原本的课业；大部分情况下，相关成绩比重会转移到期末考试。

比如，我这两天无法完成 assignment，并且这学期还没有使用过 MSAF，那么可以提交 MSAF；assignment 可能无需补做，但它的成绩比重可能会加到期末考试上。

欢迎直接在下面留言。我会把大家提出的问题逐一整理并回复。

也欢迎把这篇分享给可能需要的同学。

具体要求请以 course outline 为准。$content$,
  updated_at = NOW()
WHERE post.id = 'c0ffee00-0000-0000-0000-000000000101'::UUID
  AND EXISTS (
    SELECT 1
    FROM public.profiles profile
    WHERE profile.id = post.user_id
      AND profile.is_official = TRUE
  );

DO $postflight$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM public.posts post
    WHERE NOT EXISTS (
      SELECT 1
      FROM public.profiles profile
      WHERE profile.id = post.user_id
        AND profile.is_official = TRUE
        AND profile.deactivated_at IS NULL
    )
  ) THEN
    RAISE EXCEPTION 'Post reset verification failed: a non-official post remains';
  END IF;

  IF (
    SELECT ARRAY_AGG(board.name ORDER BY board.display_order)
    FROM public.forum_boards board
    WHERE board.status = 'active'
  ) IS DISTINCT FROM ARRAY['校园', '兴趣', '八卦', '闲聊', '匿名']::TEXT[] THEN
    RAISE EXCEPTION 'Forum board reset verification failed';
  END IF;
END;
$postflight$;

COMMIT;

NOTIFY pgrst, 'reload schema';
