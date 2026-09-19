# Account deletion verification

Issue: #13 — recoverable account deletion with permanent erasure

## Committed behavior

- An authenticated, purpose-bound deletion request schedules permanent erasure exactly 14 days later.
- Scheduling is idempotent: retries do not extend the original deadline.
- All existing app sessions, access tokens, and refresh tokens are revoked immediately.
- Google Health accounts are disconnected immediately, scheduled sync excludes the account, and an in-flight sync cannot reconnect it.
- The daily Celery task attempts to revoke stored Google credentials, then deletes the user at the deadline. Provider revocation failure is logged safely and never delays local erasure.
- Deleting the user cascades through all current user-owned application tables. SQLite connections explicitly enable foreign-key enforcement; PostgreSQL uses the existing `ON DELETE CASCADE` constraints.
- Logs use a short keyed digest of the user ID and exception type. They contain no email, provider identity, token, or health value.

Commits: `f35672f`, `b71dc62`, `8357921`, `cc1052c`.

## Verification evidence

- 57 focused deletion, authentication, and sync tests passed.
- The integrated backend suite passed: 162 tests with one existing Starlette/httpx deprecation warning.
- Migration `0022_account_deletion` passed upgrade from a schema stamped at `0021_sensitive_action_grants`, downgrade to 0021, and re-upgrade to 0022 on an isolated database.
- Tests cover exact confirmation, wrong-purpose and wrong-device grants, immediate rejection of old access and refresh tokens, ordinary token exchange rejection while deletion is pending, idempotent scheduling, the exact grace-period boundary, provider-revocation failure, cascade erasure, and the sync/deletion race.
- No real account was scheduled or deleted; lifecycle checks use isolated fixtures.

## Retention and scope

- Active application data is retained during the 14-day grace period solely so deletion can remain recoverable. The app implements no other retention exception.
- Infrastructure backup retention is not defined in this repository. Production disclosure and erasure claims must reflect the hosting provider's actual backup policy before release.
- Journal, conversation, AI memory, encrypted vault, wrapper, and recovery-envelope stores do not exist in the current schema. They were not added speculatively. Any future user-owned store must join the user deletion cascade, export contract, and lifecycle regression coverage before release.

## Operational requirement

The repository already defines Celery worker and beat services, and the purge task is registered in the beat schedule. Production must run both services and monitor purge failures. Repository verification does not prove those production processes are deployed or healthy.

## Pending definition-of-done items

- Final recovery authentication behavior is awaiting the product decision. Recovery API/session issuance remains provisional and uncommitted.
- The iOS deletion and suspended-account UI remains pending that decision. It must cover confirmation, loading, success, offline/error retry, countdown, recovery, local cache clearing, and the post-deadline state.
- Accessibility verification remains pending for the iOS surface: VoiceOver labels and focus, Dynamic Type, destructive action semantics, and state communication without color alone.
- Representative-device visual verification remains pending for small and large iPhones, light and dark appearance, and large text.
