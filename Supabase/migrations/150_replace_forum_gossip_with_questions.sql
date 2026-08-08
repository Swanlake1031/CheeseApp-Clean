-- 150_replace_forum_gossip_with_questions.sql
-- Keep the stable canonical board IDs while replacing the unused Gossip board
-- with Questions. Existing references remain valid if a post is created during
-- deployment; that post simply belongs to Questions after the migration.

BEGIN;

-- Release the canonical slug if a legacy/custom board already occupies it.
UPDATE public.forum_boards AS board
SET
  slug = 'archived-' || REPLACE(board.id::TEXT, '-', ''),
  status = 'archived',
  updated_at = NOW()
WHERE board.slug = 'questions'
  AND board.id <> 'f0000000-0000-0000-0000-000000000003'::UUID;

UPDATE public.forum_boards AS board
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
      'questions', '提问',
      '课程、校园生活、办事流程及各类问题求助。',
      '请清楚描述问题并友善交流；禁止泄露隐私、恶意攻击、欺诈及违法内容。',
      'questionmark.bubble.fill', FALSE, 2::SMALLINT
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

UPDATE public.forum_boards AS board
SET
  status = 'archived',
  updated_at = NOW()
WHERE board.id NOT IN (
  'f0000000-0000-0000-0000-000000000001'::UUID,
  'f0000000-0000-0000-0000-000000000002'::UUID,
  'f0000000-0000-0000-0000-000000000003'::UUID,
  'f0000000-0000-0000-0000-000000000004'::UUID,
  'f0000000-0000-0000-0000-000000000005'::UUID
);

DO $verification$
BEGIN
  IF (
    SELECT ARRAY_AGG(board.name ORDER BY board.display_order)
    FROM public.forum_boards AS board
    WHERE board.status = 'active'
  ) IS DISTINCT FROM ARRAY['校园', '兴趣', '提问', '闲聊', '匿名']::TEXT[] THEN
    RAISE EXCEPTION 'Forum board category verification failed';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.forum_boards AS board
    WHERE board.status = 'active'
      AND (board.slug = 'gossip' OR board.name = '八卦')
  ) THEN
    RAISE EXCEPTION 'The retired Gossip board remains active';
  END IF;
END;
$verification$;

COMMIT;

NOTIFY pgrst, 'reload schema';
