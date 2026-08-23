BEGIN;

UPDATE public.profiles
SET avatar_url = 'https://cheeseapp-ai-worker.timonayf.workers.dev/cheese-ai-avatar.jpg',
    updated_at = NOW()
WHERE id = 'e5983890-95ad-4b6c-814b-863bfde4e4fc'::UUID
  AND avatar_url IS DISTINCT FROM
      'https://cheeseapp-ai-worker.timonayf.workers.dev/cheese-ai-avatar.jpg';

COMMIT;
