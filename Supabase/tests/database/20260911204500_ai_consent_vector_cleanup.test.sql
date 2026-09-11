BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path = public, extensions, pg_temp;

SELECT plan(6);

INSERT INTO auth.users (id, email)
VALUES (
  '20450000-0000-4000-8000-000000000001',
  'ai-consent-withdrawal@example.invalid'
);

INSERT INTO public.posts (
  id, user_id, school_id, type, title, description, status, is_anonymous, is_private
)
SELECT
  '20450000-0000-4000-8000-000000000002',
  profile.id,
  profile.school_id,
  'forum',
  'AI consent withdrawal fixture',
  'A fixture post for queued embedding and profile-vector cleanup.',
  'active',
  FALSE,
  FALSE
FROM public.profiles AS profile
WHERE profile.id = '20450000-0000-4000-8000-000000000001';

INSERT INTO public.forum_posts (id, board_id, allow_comments, is_pinned, is_locked)
SELECT
  '20450000-0000-4000-8000-000000000002',
  board.id,
  TRUE,
  FALSE,
  FALSE
FROM public.forum_boards AS board
WHERE board.status <> 'archived'
ORDER BY board.id
LIMIT 1;

DELETE FROM public.post_embedding_jobs
WHERE post_id = '20450000-0000-4000-8000-000000000002';
DELETE FROM public.post_embeddings
WHERE post_id = '20450000-0000-4000-8000-000000000002';

INSERT INTO public.post_embedding_jobs (
  post_id, input_hash, embedding_version, model, input_format_version
)
VALUES (
  '20450000-0000-4000-8000-000000000002',
  repeat('a', 64),
  'cheese-semantic-v1',
  'gemini-embedding-2',
  1
);

INSERT INTO public.post_embeddings (
  post_id, embedding_version, embedding, model, input_format_version,
  input_hash, status
)
VALUES (
  '20450000-0000-4000-8000-000000000002',
  'cheese-semantic-v1',
  NULL,
  'gemini-embedding-2',
  1,
  repeat('b', 64),
  'pending'
);

INSERT INTO public.user_interest_profiles (user_id)
VALUES ('20450000-0000-4000-8000-000000000001');

INSERT INTO public.user_post_signal_state (
  user_id, post_id, effective_weight
)
VALUES (
  '20450000-0000-4000-8000-000000000001',
  '20450000-0000-4000-8000-000000000002',
  3
);

INSERT INTO public.ai_processing_consents (user_id, version)
VALUES ('20450000-0000-4000-8000-000000000001', '2026-09-11');

SELECT set_config(
  'request.jwt.claim.sub',
  '20450000-0000-4000-8000-000000000001',
  TRUE
);
SELECT set_config(
  'request.jwt.claims',
  '{"sub":"20450000-0000-4000-8000-000000000001","role":"authenticated"}',
  TRUE
);
SET LOCAL ROLE authenticated;

SELECT is(
  public.set_my_ai_consent(FALSE),
  TRUE,
  'optional AI consent withdrawal completes'
);

RESET ROLE;

SELECT is(
  (
    SELECT COUNT(*)
    FROM public.ai_processing_consents
    WHERE user_id = '20450000-0000-4000-8000-000000000001'
  ),
  0::bigint,
  'withdrawal removes the account consent record'
);

SELECT is(
  (
    SELECT COUNT(*)
    FROM public.post_embedding_jobs
    WHERE post_id = '20450000-0000-4000-8000-000000000002'
  ),
  0::bigint,
  'withdrawal removes queued embedding work for authored posts'
);

SELECT is(
  (
    SELECT COUNT(*)
    FROM public.post_embeddings
    WHERE post_id = '20450000-0000-4000-8000-000000000002'
  ),
  0::bigint,
  'withdrawal removes authored embedding rows'
);

SELECT is(
  (
    SELECT COUNT(*)
    FROM public.user_interest_profiles
    WHERE user_id = '20450000-0000-4000-8000-000000000001'
  ),
  0::bigint,
  'withdrawal removes the account recommendation vector'
);

SELECT is(
  (
    SELECT COUNT(*)
    FROM public.user_post_signal_state
    WHERE user_id = '20450000-0000-4000-8000-000000000001'
      AND post_id = '20450000-0000-4000-8000-000000000002'
  ),
  1::bigint,
  'withdrawal preserves non-AI recommendation signals'
);

SELECT * FROM finish();

ROLLBACK;
