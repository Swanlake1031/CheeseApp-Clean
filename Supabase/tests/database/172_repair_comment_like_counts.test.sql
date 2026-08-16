BEGIN;

SELECT plan(4);

DELETE FROM public.user_blocks
WHERE blocker_id IN (
  '00000000-0000-0000-0000-000000000001'::UUID,
  '00000000-0000-0000-0000-000000000002'::UUID
)
OR blocked_id IN (
  '00000000-0000-0000-0000-000000000001'::UUID,
  '00000000-0000-0000-0000-000000000002'::UUID
);

INSERT INTO public.posts (
  id, user_id, school_id, type, title, description, status,
  is_anonymous, is_private
)
SELECT
  '17200000-0000-4000-8000-000000000001'::UUID,
  '00000000-0000-0000-0000-000000000001'::UUID,
  profile.school_id,
  'forum',
  'Comment like counter test post',
  'test',
  'active',
  FALSE,
  FALSE
FROM public.profiles AS profile
WHERE profile.id = '00000000-0000-0000-0000-000000000001'::UUID;

INSERT INTO public.forum_posts (id, board_id, allow_comments, is_pinned, is_locked)
VALUES (
  '17200000-0000-4000-8000-000000000001',
  'f0000000-0000-0000-0000-000000000001',
  TRUE,
  FALSE,
  FALSE
);

INSERT INTO public.comments (id, post_id, user_id, content, is_anonymous)
VALUES (
  '17200000-0000-4000-8000-000000000010',
  '17200000-0000-4000-8000-000000000001',
  '00000000-0000-0000-0000-000000000001',
  'comment owned by another user',
  FALSE
);

SELECT ok(
  (
    SELECT procedure_row.prosecdef
    FROM pg_catalog.pg_proc AS procedure_row
    JOIN pg_catalog.pg_namespace AS namespace_row
      ON namespace_row.oid = procedure_row.pronamespace
    WHERE namespace_row.nspname = 'public'
      AND procedure_row.proname = 'update_like_count'
  ),
  'the like counter trigger bypasses caller RLS through SECURITY DEFINER'
);

SELECT is(
  (
    SELECT count(*)
    FROM pg_catalog.pg_trigger AS trigger_row
    WHERE trigger_row.tgrelid = 'public.likes'::regclass
      AND trigger_row.tgname = 'likes_count_trigger'
      AND NOT trigger_row.tgisinternal
  ),
  1::BIGINT,
  'the canonical like counter trigger is installed once'
);

SELECT set_config(
  'request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-000000000002","role":"authenticated"}',
  TRUE
);
SELECT set_config(
  'request.jwt.claim.sub',
  '00000000-0000-0000-0000-000000000002',
  TRUE
);
SELECT set_config('request.jwt.claim.role', 'authenticated', TRUE);
SET LOCAL ROLE authenticated;

INSERT INTO public.likes (user_id, target_type, target_id)
VALUES (
  '00000000-0000-0000-0000-000000000002',
  'comment',
  '17200000-0000-4000-8000-000000000010'
);

SELECT is(
  (
    SELECT like_count
    FROM public.comments
    WHERE id = '17200000-0000-4000-8000-000000000010'
  ),
  1,
  'liking another user comment persists the comment count'
);

DELETE FROM public.likes
WHERE user_id = '00000000-0000-0000-0000-000000000002'
  AND target_type = 'comment'
  AND target_id = '17200000-0000-4000-8000-000000000010';

SELECT is(
  (
    SELECT like_count
    FROM public.comments
    WHERE id = '17200000-0000-4000-8000-000000000010'
  ),
  0,
  'unliking another user comment persists the decremented count'
);

RESET ROLE;

SELECT * FROM finish();
ROLLBACK;
