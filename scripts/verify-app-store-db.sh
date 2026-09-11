#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="/Applications/Docker.app/Contents/Resources/bin:${PATH}"
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/cheese-appstore-db.XXXXXX")"
mkdir -p "$fixture_root/supabase"
mkdir -p "$fixture_root/supabase/migrations"
# Historical reset 133 requires an official account. Bootstrap a synthetic one
# after 132; keep every migration byte-for-byte identical to the repository.
for migration in "$repo_root"/Supabase/migrations/*.sql; do
  name="$(basename "$migration")"
  if [[ "$name" < "133_" ]]; then cp "$migration" "$fixture_root/supabase/migrations/"; fi
done
cp "$repo_root/Supabase/seed.sql" "$fixture_root/supabase/seed.sql"
cat > "$fixture_root/supabase/config.toml" <<CONFIG
project_id = "cheese-appstore-audit"
[api]
port = 55421
[studio]
port = 55423
[db.seed]
enabled = false
[db]
port = 55432
shadow_port = 55430
major_version = 17
CONFIG
# A separate local project: no production link, secrets, dumps or Storage files.
# Supabase startup output may include development keys, so keep it private.
log_file="$fixture_root/verification.log"
cleanup() {
  local status=$?
  trap - EXIT
  if [[ "$status" -ne 0 && -f "$log_file" ]]; then
    echo "Database verification failed (exit $status). Sanitized diagnostics:" >&2
    # Keep the complete log private, but expose enough stable context to
    # identify a migration or pgtap failure in CI. Long tokens/keys/UUIDs are
    # redacted before the summary reaches the public Actions log.
    grep -Ei 'error|fatal|fail|not ok|assert|syntax|migration|exception|permission|violat|could not' "$log_file" \
      | tail -n 120 \
      | sed -E 's/[A-Za-z0-9+\/_=-]{24,}/REDACTED/g' \
      | cut -c1-500 >&2 || true
  fi
  supabase stop --workdir "$fixture_root" --no-backup >/dev/null 2>&1 || true
  exit "$status"
}
trap cleanup EXIT
if ! supabase start --workdir "$fixture_root" -x realtime,imgproxy,mailpit,postgres-meta,studio,edge-runtime,logflare,vector,supavisor >"$log_file" 2>&1; then
  echo "Local database startup failed; inspect $log_file privately." >&2; exit 1
fi
container="supabase_db_cheese-appstore-audit"
local_sql() {
  docker exec -i -e 'PGOPTIONS=-c session_preload_libraries=' "$container" sh -c     'PGPASSWORD="$POSTGRES_PASSWORD" psql -X -qAt -U supabase_admin -d postgres -v ON_ERROR_STOP=1'
}
local_sql >>"$log_file" 2>&1 <<'SQL'
INSERT INTO auth.users(id,email,raw_user_meta_data)
VALUES('00000000-0000-0000-0000-000000000004','cheese_official@cheeseapp.org','{"full_name":"Local official fixture"}');
UPDATE public.profiles SET is_official=true WHERE id='00000000-0000-0000-0000-000000000004';
SQL
for migration in "$repo_root"/Supabase/migrations/*.sql; do
  name="$(basename "$migration")"
  if [[ "$name" < "196_" ]]; then cp "$migration" "$fixture_root/supabase/migrations/"; fi
done
supabase migration up --local --workdir "$fixture_root" >>"$log_file" 2>&1
# Remove the historical empty bucket through the supported Storage API.
supabase status --workdir "$fixture_root" -o json >"$fixture_root/status.json" 2>>"$log_file"
python3 - "$fixture_root/status.json" >>"$log_file" 2>&1 <<'PYTHON'
import json,sys,urllib.request
s=json.load(open(sys.argv[1]))
req=urllib.request.Request(s['API_URL']+'/storage/v1/bucket/course-outlines',method='DELETE',headers={'apikey':s['SERVICE_ROLE_KEY'],'Authorization':'Bearer '+s['SERVICE_ROLE_KEY']})
with urllib.request.urlopen(req) as r: assert r.status==200
PYTHON
rm "$fixture_root/status.json"
cp "$repo_root"/Supabase/migrations/*.sql "$fixture_root/supabase/migrations/"
supabase migration up --local --workdir "$fixture_root" >>"$log_file" 2>&1
local_sql <"$repo_root/Supabase/seed.sql" >>"$log_file" 2>&1
# supautils in the local image crashes on auth schema privilege probes. Use the
# owner connection with only that preload disabled; SET ROLE/RLS still apply.
local_sql >>"$log_file" 2>&1 <<'SQL'
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SQL
for suite in \
  102_critical_security_boundaries.test.sql \
  141_release_school_binding_on_deactivation.test.sql \
  20260910052718_required_school.test.sql \
  190_recommendation_v1.test.sql \
  20260911165358_no_manual_tags.test.sql \
  20260911164610_session_ttl.test.sql \
  20260911184137_app_store_safety.test.sql \
  20260911194713_media_safety_release_gate.test.sql \
  20260911202000_account_deletion_media_cleanup.test.sql \
  20260911204500_ai_consent_vector_cleanup.test.sql; do
  { echo 'SET search_path=public,extensions,pg_temp;'; cat "$repo_root/Supabase/tests/database/$suite"; } | local_sql >"$fixture_root/test.tap" 2>>"$log_file"
  cat "$fixture_root/test.tap" >>"$log_file"
  python3 - "$fixture_root/test.tap" "$suite" <<'PYTHON'
import re,sys
s=open(sys.argv[1]).read().splitlines()
plans=[int(m.group(1)) for l in s if (m:=re.match(r'^1\.\.(\d+)',l))]
checks=[l for l in s if re.match(r'^(not )?ok \d+',l)]
assert len(plans)==1 and plans[0]>0 and len(checks)==plans[0], 'Incomplete TAP: '+sys.argv[2]
assert not any(l.startswith('not ok ') for l in checks), 'Failed assertions: '+sys.argv[2]
print('PASS:',sys.argv[2],len(checks),'checks')
PYTHON
done
echo "PASS: clean local migration replay and App Store database security suites. Log: $log_file"
