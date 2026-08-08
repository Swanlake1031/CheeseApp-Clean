#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
supabase_root="${repo_root}/Supabase"
test_file="${supabase_root}/tests/database/102_critical_security_boundaries.test.sql"
professor_identity_test_file="${supabase_root}/tests/database/103_allow_duplicate_professor_names.test.sql"

if ! command -v docker >/dev/null 2>&1 &&
  [[ -x /Applications/Docker.app/Contents/Resources/bin/docker ]]; then
  export PATH="/Applications/Docker.app/Contents/Resources/bin:${PATH}"
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "Docker is required for the disposable local Supabase database." >&2
  exit 1
fi

if ! docker info >/dev/null 2>&1; then
  echo "Docker is installed but its daemon is not running." >&2
  exit 1
fi

if ! command -v supabase >/dev/null 2>&1; then
  echo "Supabase CLI is required." >&2
  exit 1
fi

# Local-only by construction: no --linked and no external database URL.
# Supabase CLI expects --workdir to contain the `supabase` project directory.
# The repository uses `Supabase` (capital S), which resolves case-insensitively
# on supported macOS development machines.
if ! supabase status --workdir "${repo_root}" >/dev/null 2>&1; then
  # Successful `supabase start` output includes local development credentials.
  supabase start --workdir "${repo_root}" >/dev/null
  echo "Started disposable local Supabase."
fi

# Two clean resets prove that every migration can replay from an empty local
# database and that the resulting seed/bootstrap remains repeatable.
supabase db reset --local --workdir "${repo_root}"
supabase db reset --local --workdir "${repo_root}"

supabase test db "${test_file}" --local --workdir "${repo_root}"
supabase test db "${professor_identity_test_file}" --local --workdir "${repo_root}"
