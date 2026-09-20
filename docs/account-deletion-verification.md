# Account deletion verification

Issue: #13 — recoverable account deletion with permanent erasure

## Implemented lifecycle

- `POST /account/deletion` requires the exact `DELETE` confirmation, an authenticated session, and a five-minute, one-use Google step-up grant bound to the requesting device and deletion purpose.
- Scheduling is idempotent and locks the account transition. It immediately revokes every app session and access token, disconnects Google Health, stops sync, clears app-owned local caches and temporary export ZIPs, and moves the iOS app to a persistent suspended state.
- During the 14-day grace period, the explicit **Restore account** action authenticates the same Google identity on any device. The server locks and re-checks the account, cancels deletion, reconnects the refreshed Google credential, and issues one fresh device session. Revoked sessions remain revoked.
- The daily Celery purge locks and re-checks each due account at the exact UTC deadline. It best-effort revokes Google credentials, then permanently deletes the user and every current user-owned row through database cascades even if provider revocation fails.
- The iOS deletion flow covers idle, confirmation, loading, error/retry, suspended, recovery, and locally elapsed deadline states. Device time is display-only; the server decides whether recovery is still allowed.
- Logs use a short keyed user digest and exception type. They contain no email, provider identity, credential, or health value.

## Verification evidence

- 60 focused deletion, authentication, OAuth, and sync tests pass. Durable route and service coverage includes exact confirmation; wrong-purpose, wrong-device, consumed, and expired grants; immediate rejection of old access and refresh tokens; ordinary sign-in rejection while deletion is pending; fresh recovery-session issuance; same-Google recovery; idempotence; exact deadline handling; provider-revocation failure; full current-schema cascade erasure; and sync/OAuth transition guards.
- The final integrated backend suite passes 162 tests with one existing Starlette/httpx deprecation warning.
- Migration `0022_account_deletion` passed upgrade from a schema stamped at `0021_sensitive_action_grants`, downgrade to 0021, and re-upgrade to 0022 on an isolated database. A fresh SQLite migration from zero remains blocked by pre-existing migration 0008's PostgreSQL-only `md5()` expression.
- The Debug iOS app builds successfully for iPhone 17 Pro and iPhone 17e simulators. Runtime accessibility snapshots on an iPhone 17 Pro expose the deletion confirmation field, destructive scheduling action, retry action, and Restore account action with meaningful labels and hints. The screen communicates state in text and symbols as well as color.
- Light-appearance visual checks at 368×800 cover the complete deletion form, enabled confirmation/error state, and suspended Restore screen without clipping. The second-device build was verified, but its screenshot surface returned black and does not count as visual evidence. No real account was scheduled or deleted; lifecycle tests use isolated fixtures and iOS checks use debug preview states.

## Retention and future stores

- Active application data remains during the 14-day grace period only so deletion can be recovered. The app implements no other retention exception.
- Infrastructure backup retention is not defined in this repository. Production disclosure and erasure claims must reflect the hosting provider's actual backup policy before release.
- Current health, workout, journal/tag, derived score/baseline, profile/preference, session, provider credential, and connection records participate in the user cascade. Conversation, future coach memory, encrypted vault, wrapper, and recovery-envelope stores do not exist yet; each future user-owned store must join deletion, export, sync exclusion, and lifecycle regression coverage before release.
- Files a user has already shared or saved outside the app sandbox remain under that user's control and cannot be erased by the app.

## Operational requirement

The repository already defines Celery worker and beat services, and the purge task is registered in the beat schedule. Production must run both services and monitor purge failures. Repository verification does not prove those production processes are deployed or healthy.
