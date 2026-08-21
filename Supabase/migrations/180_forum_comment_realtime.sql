-- Publish forum comment mutations so an open post detail can reconcile its
-- comment thread immediately after inserts, replies, edits, and deletes.
-- Existing RLS policies continue to control which rows each client may read.

begin;

do $$
begin
  begin
    alter publication supabase_realtime add table public.comments;
  exception
    when duplicate_object then null;
  end;
end
$$;

commit;
