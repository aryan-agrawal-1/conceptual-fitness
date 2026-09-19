# Account export verification

Issue: #12 — selectable, complete account data export

## Committed behavior

- Users select health/workouts, journal, derived insights, and personalization independently; all are selected by default.
- The server streams a versioned ZIP containing an always-present manifest and one documented JSON file per selected category.
- Empty categories retain their documented table keys with empty arrays. Provider credentials, app tokens, OAuth state, one-time grants, sync page tokens, and internal errors are excluded.
- Daily briefs cached only on the exporting device are included with their date, slot, kind, text, and generation time. The backend uses them only while assembling the archive and does not persist them.
- Export requires a five-minute, single-use Google authorization grant bound to the app user, device, and export purpose. Missing, expired, stale, mismatched, wrong-purpose, wrong-device, and replayed evidence fails closed.
- Sensitive export authorization requests only OpenID identity scopes plus Google Health profile identity. It does not request activity, sleep, metric, or offline access again.

## Verification evidence

- The integrated backend suite passed: **162 tests** with one existing Starlette/httpx deprecation warning.
- Export tests cover every current user-owned health/workout table, tenant isolation, category selection, empty output, manifest counts, local insight inclusion, secret exclusion, and grant user/device/purpose/expiry/replay enforcement.
- OAuth tests cover the reduced scope request and missing, stale, expired, issuer, audience, subject, and provider-identity evidence failures.
- Changed-file Ruff and `git diff --check` passed.
- The app built and launched on an iPhone 17e simulator running iOS 26.5. Idle, loading, error/retry, and success/share states were inspected; category, retry, and share controls expose accessibility labels and hints.
- The installed app also launched on an iPhone 17 Pro Max simulator running iOS 26.5. A real connected account loaded Dashboard → Profile → Export without onboarding or profile decoding errors. The selectable export screen fit without clipping.

## Live Google verification blocker

The real-account export reached `ASWebAuthenticationSession`, continued to `accounts.google.com`, and displayed Google's fresh email-or-phone sign-in screen. The simulator has no authenticated Google session, so verification stopped without entering credentials. A user must sign in once in that simulator to confirm that this Google Cloud project returns the requested `auth_time` claim and to complete a real ZIP download. Until then, the server rejects a callback with missing or stale `auth_time`; the live provider step-up and archive download remain unverified.

Google can satisfy the fresh authentication request through its available account authentication method, so this flow must not be described as password reauthentication.

## Current product scope

No coach conversation, memory, plan, evidence vault, encrypted vault, or E2EE record type exists in the current repository. Those categories were not added speculatively. Before adding any such storage, its export format and on-device decryption/assembly boundary need a product decision and durable coverage.

No frontend tests or production dependencies were added.
