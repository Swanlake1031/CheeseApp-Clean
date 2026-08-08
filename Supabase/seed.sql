-- ============================================
-- Cheese App 测试数据（与当前 migrations 对齐）
-- ============================================
--
-- 使用说明：
-- 1) 请先执行当前全部迁移。
-- 2) 以下账号只用于本地开发，不包含可登录密码或真实凭据。

-- ============================================
-- 0) Local auth users
-- ============================================

INSERT INTO auth.users (
  instance_id,
  id,
  aud,
  role,
  email,
  email_confirmed_at,
  raw_app_meta_data,
  raw_user_meta_data,
  created_at,
  updated_at
)
VALUES
  (
    '00000000-0000-0000-0000-000000000000',
    '00000000-0000-0000-0000-000000000001',
    'authenticated',
    'authenticated',
    'alice@test.com',
    NOW(),
    '{"provider":"email","providers":["email"]}'::JSONB,
    '{"full_name":"Alice","university":"McMaster University"}'::JSONB,
    NOW(),
    NOW()
  ),
  (
    '00000000-0000-0000-0000-000000000000',
    '00000000-0000-0000-0000-000000000002',
    'authenticated',
    'authenticated',
    'bob@test.com',
    NOW(),
    '{"provider":"email","providers":["email"]}'::JSONB,
    '{"full_name":"Bob","university":"McMaster University"}'::JSONB,
    NOW(),
    NOW()
  ),
  (
    '00000000-0000-0000-0000-000000000000',
    '00000000-0000-0000-0000-000000000003',
    'authenticated',
    'authenticated',
    'carol@test.com',
    NOW(),
    '{"provider":"email","providers":["email"]}'::JSONB,
    '{"full_name":"Carol","university":"McMaster University"}'::JSONB,
    NOW(),
    NOW()
  ),
  (
    '00000000-0000-0000-0000-000000000000',
    '00000000-0000-0000-0000-000000000004',
    'authenticated',
    'authenticated',
    'cheese_official@cheeseapp.org',
    NOW(),
    '{"provider":"email","providers":["email"]}'::JSONB,
    '{"full_name":"奶酪官方","university":"McMaster University"}'::JSONB,
    NOW(),
    NOW()
  )
ON CONFLICT (id) DO NOTHING;

-- ============================================
-- 1) Profiles
-- ============================================

WITH mcmaster AS (
  SELECT
    school.id AS school_id,
    campus.id AS campus_id
  FROM public.schools AS school
  LEFT JOIN public.school_campuses AS campus
    ON campus.school_id = school.id
   AND campus.is_default = TRUE
  WHERE school.name = 'McMaster University'
  ORDER BY campus.created_at
  LIMIT 1
)
INSERT INTO profiles (
  id, email, full_name, avatar_url, university, student_id, verified, is_anonymous,
  school_id, campus_id
)
SELECT
  seed.id::UUID,
  seed.email,
  seed.full_name,
  seed.avatar_url,
  'McMaster University',
  NULL,
  seed.verified,
  FALSE,
  mcmaster.school_id,
  mcmaster.campus_id
FROM (
  VALUES
  (
    '00000000-0000-0000-0000-000000000001',
    'alice@test.com',
    'Alice',
    'https://api.dicebear.com/7.x/avataaars/svg?seed=alice',
    TRUE
  ),
  (
    '00000000-0000-0000-0000-000000000002',
    'bob@test.com',
    'Bob',
    'https://api.dicebear.com/7.x/avataaars/svg?seed=bob',
    FALSE
  ),
  (
    '00000000-0000-0000-0000-000000000003',
    'carol@test.com',
    'Carol',
    'https://api.dicebear.com/7.x/avataaars/svg?seed=carol',
    FALSE
  ),
  (
    '00000000-0000-0000-0000-000000000004',
    'cheese_official@cheeseapp.org',
    '奶酪官方',
    '',
    TRUE
  )
) AS seed(id, email, full_name, avatar_url, verified)
CROSS JOIN mcmaster
ON CONFLICT (id) DO UPDATE SET
  email = EXCLUDED.email,
  full_name = EXCLUDED.full_name,
  avatar_url = EXCLUDED.avatar_url,
  university = EXCLUDED.university,
  verified = EXCLUDED.verified,
  school_id = EXCLUDED.school_id,
  campus_id = EXCLUDED.campus_id,
  updated_at = NOW();

-- ============================================
-- 2) Secondhand
-- ============================================

INSERT INTO posts (
  id, user_id, type, title, description, status, is_anonymous, view_count, school_id
)
SELECT
  '20000000-0000-0000-0000-000000000001',
  profile.id,
  'secondhand',
  'MacBook Air M2 16GB',
  'Great condition, battery health 98%, includes charger.',
  'active',
  FALSE,
  64,
  profile.school_id
FROM profiles profile
WHERE profile.id = '00000000-0000-0000-0000-000000000002'
ON CONFLICT (id) DO NOTHING;

INSERT INTO secondhand_posts (
  id, price, original_price, is_negotiable, is_free,
  category, condition, can_ship, shipping_fee, quantity, sold_count
) VALUES (
  '20000000-0000-0000-0000-000000000001',
  850,
  1199,
  TRUE,
  FALSE,
  'digital_electronics',
  'good',
  FALSE,
  NULL,
  1,
  0
)
ON CONFLICT (id) DO NOTHING;

INSERT INTO post_images (post_id, url, order_index)
VALUES
  ('20000000-0000-0000-0000-000000000001', 'https://images.unsplash.com/photo-1517336714731-489689fd1ca8?w=1200', 0)
ON CONFLICT DO NOTHING;

-- ============================================
-- 4) Forum
-- ============================================

SELECT public.configure_cheese_official_msaf_post(
  '00000000-0000-0000-0000-000000000004'::UUID
);

INSERT INTO posts (
  id, user_id, type, title, description, status, is_anonymous, view_count, school_id
)
SELECT
  '50000000-0000-0000-0000-000000000001',
  profile.id,
  'forum',
  'How to find off-campus housing fast?',
  'Any tips for finding reliable leases near campus before the fall term?',
  'active',
  FALSE,
  132,
  profile.school_id
FROM profiles profile
WHERE profile.id = '00000000-0000-0000-0000-000000000002'
ON CONFLICT (id) DO NOTHING;

INSERT INTO forum_posts (
  id, board_id, allow_comments, is_pinned, is_locked, like_count, comment_count
) VALUES (
  '50000000-0000-0000-0000-000000000001',
  'f0000000-0000-0000-0000-000000000002',
  TRUE,
  FALSE,
  FALSE,
  4,
  1
)
ON CONFLICT (id) DO NOTHING;

INSERT INTO comments (post_id, user_id, parent_id, content, is_anonymous, like_count, is_deleted)
VALUES (
  '50000000-0000-0000-0000-000000000001',
  '00000000-0000-0000-0000-000000000001',
  NULL,
  'Try joining student housing groups and verify lease terms in writing.',
  FALSE,
  0,
  FALSE
)
ON CONFLICT DO NOTHING;

-- ============================================
-- 5) Chat
-- ============================================

INSERT INTO conversations (
  id, user1_id, user2_id, related_post_id, last_message_at, last_message_preview,
  user1_unread_count, user2_unread_count
) VALUES (
  '60000000-0000-0000-0000-000000000001',
  '00000000-0000-0000-0000-000000000001',
  '00000000-0000-0000-0000-000000000002',
  '20000000-0000-0000-0000-000000000001',
  NOW(),
  'Hi, is this still available?',
  0,
  1
)
ON CONFLICT (id) DO NOTHING;

INSERT INTO messages (conversation_id, sender_id, content, message_type, metadata, is_read, is_deleted)
VALUES (
  '60000000-0000-0000-0000-000000000001',
  '00000000-0000-0000-0000-000000000001',
  'Hi, is this still available?',
  'text',
  '{}'::jsonb,
  FALSE,
  FALSE
)
ON CONFLICT DO NOTHING;
