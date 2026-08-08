BEGIN;

SELECT plan(4);

SELECT ok(
  NOT has_function_privilege(
    'anon',
    'public.enqueue_direct_message_media_cleanup()',
    'EXECUTE'
  ),
  'anon cannot execute the direct-message cleanup trigger function'
);

SELECT ok(
  NOT has_function_privilege(
    'authenticated',
    'public.enqueue_direct_message_media_cleanup()',
    'EXECUTE'
  ),
  'authenticated cannot execute the direct-message cleanup trigger function'
);

SELECT ok(
  NOT has_function_privilege(
    'anon',
    'public.enqueue_group_message_media_cleanup()',
    'EXECUTE'
  ),
  'anon cannot execute the group-message cleanup trigger function'
);

SELECT ok(
  NOT has_function_privilege(
    'authenticated',
    'public.enqueue_group_message_media_cleanup()',
    'EXECUTE'
  ),
  'authenticated cannot execute the group-message cleanup trigger function'
);

SELECT * FROM finish();
ROLLBACK;
