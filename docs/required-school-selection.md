# Required school selection — 2026-09-10

## Shipped backend / pending client distribution

Migration `20260910052718_require_school_selection_and_mcmaster_backfill.sql`
was applied to the linked production project. Read-back confirmed the migration
record and enabled `zz_enforce_completed_profile_school` trigger.

- All 38 existing profiles already had McMaster's actual school ID; no profile
  required backfill (the private changed-row backup contains zero rows).
- All 22 active profiles have the canonical McMaster University display name.
- All 16 deactivated profiles retain their `已注销` display and deactivation state.
- Credentials, verification badges, post school IDs and immutable forum origins
  were not changed.

New App onboarding starts with an empty required school picker. Nickname, school
and gender are required to complete the form. The completion RPC requires a valid
active school and atomically persists its canonical name, ID and default campus.
The App adopts the returned profile so recommendation routing does not retain the
previous default school ID. Direct client writes cannot mark an incomplete profile
complete, or leave a completed active profile with an invalid/mismatched school.

Install/distribute the new App build to get the explicit picker. An old binary
that supplies a valid default McMaster value can still complete the RPC; the
server cannot distinguish that value from an explicit user choice. No App Store
or TestFlight distribution was performed by this change.

## Verification

- Local rollback-only database regression: 17 checks passed, including missing,
  blank and unsupported school rejection, direct-write bypass rejection, York
  selection, McMaster selection, campus consistency and deactivation preservation.
- Debug App build and test-bundle compilation passed.
- Share worker syntax check and `git diff --check` passed.
- Final full simulator test run could not launch the test App: simulator service
  exited with `NSMachErrorDomain -308 (ipc/mig) server died`. This is not recorded
  as a passing test run. Result path:
  `/tmp/CheeseAppDD-tests/Logs/Test/Test-CheeseApp-2026.09.10_01-31-36--0400.xcresult`.

## Rollback boundary

Use a new migration to restore the prior completion RPC from migration 147 and
remove the new guard trigger if necessary. Review subsequent user school changes
before restoring any captured values. The private backup covers changed rows
only, not the entire project; dropping it loses those captured values. Existing
production profiles needed no normalization, so there are no old values to restore
from this release's empty backup. Backend deployment precedes client distribution.
