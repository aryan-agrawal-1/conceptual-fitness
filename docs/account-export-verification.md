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
- Eleven focused export and Google Health client tests passed after the live OAuth fix. They also cover string-form token expiry, mismatched verified claims, future authentication time, and expiry at the current time.
- Changed-file Ruff and `git diff --check` passed.
- The app built and launched on an iPhone 17e simulator running iOS 26.5. Idle, loading, error/retry, and success/share states were inspected; category, retry, and share controls expose accessibility labels and hints.
- The installed app also launched on an iPhone 17 Pro Max simulator running iOS 26.5. A real connected account loaded Dashboard → Profile → Export without onboarding or profile decoding errors. The selectable export screen fit without clipping.

## Live Google verification status

The real connected account was exercised on an iPhone 17 Pro simulator running iOS 26.5 (UDID `E3E198C5-A1EA-4EC7-8640-C9EE0B611D0A`). Dashboard → Profile → Export → Create export opened `ASWebAuthenticationSession`, continued to `accounts.google.com`, and displayed the saved Google account. Selecting that account completed the provider callback, but the app showed its safe generic export error. Database evidence showed that the export OAuth state was consumed and no sensitive-action grant was created. Privacy-safe server diagnostics identified the failure as `missing_auth_time`.

The authorization request already included Google's documented essential `auth_time` claim and `max_age=0`; those fail-closed requirements were retained. The observed Google token-info verification response did not expose `auth_time`. The client now decodes the payload of that same ID token only after token-info verification succeeds, requires its issuer, audience, subject, and normalized expiry to match the verified response, and then supplies only `auth_time` when token-info omitted it. The live run did not prove that the returned signed payload contains `auth_time`; if it does not, authorization still fails closed. Known OAuth failures are logged using privacy-safe reason codes without token, identity, or health payloads.

A post-fix live callback and ZIP/share-sheet download remain unverified. The final retry reached the saved-account chooser again, but simulator automation could not activate that web row. The next manual check is to select the saved account, confirm that **Share export** appears, and verify that the share sheet contains `conceptual-fitness-export-YYYY-MM-DD.zip`.

Google can satisfy the fresh authentication request through its available account authentication method, so this flow must not be described as password reauthentication.

## Current product scope

No coach conversation, memory, plan, evidence vault, encrypted vault, or E2EE record type exists in the current repository, so this batch exports every category currently stored. Later coach and E2EE milestones must add their records to the export, define the on-device decryption and assembly boundary, and add durable coverage when those stores are introduced.

No frontend tests or production dependencies were added.
