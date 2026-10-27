# Account export verification

Issue: #12 — selectable, complete account data export

## Committed behavior

- Users select health/workouts, journal, derived insights, and personalization independently; all are selected by default.
- The server streams a versioned ZIP containing an always-present manifest and one documented JSON file per selected category.
- Empty categories retain their documented table keys with empty arrays. Provider credentials, app tokens, OAuth state, one-time grants, sync page tokens, and internal errors are excluded.
- Daily briefs cached only on the exporting device are included with their date, slot, kind, text, and generation time. The backend uses them only while assembling the archive and does not persist them.
- Export requires a five-minute, single-use device-key grant bound to the app user, session, device, and export purpose. The server verifies a signature made with the session’s registered key; missing, expired, mismatched, wrong-purpose, wrong-session, and replayed proof fails closed.
- Google OAuth is used for account identity and one-time enrollment of older sessions, not for routine export authorization. The flow no longer requires Google `auth_time` or `max_age`.

## Verification evidence

- Final integrated backend suite: **166 passed**, with one existing Starlette/httpx deprecation warning.
- Focused device-key authentication/export/deletion checks: **25 passed**. Coverage includes signed enrollment, legacy-session migration, signature/session/purpose binding, replay rejection, expiration, recovery, and rejection of old unbound grants.
- Export coverage includes current data categories, tenant isolation, empty output, manifest counts, local insight inclusion, and secret exclusion.
- Ruff, `git diff --check`, and isolated migration 0023 upgrade/downgrade checks passed.
- Final iOS simulator build passed. The iOS signing transcript matched the backend test vector byte-for-byte.
- Simulator checks verified explicit hardware-unavailable messages for export/deletion and that ordinary sign-in is not blocked by missing Secure Enclave support. The ordinary sign-in attempt reached a network error; it is not counted as a successful live login.
- Earlier export UI checks covered selection, loading, error/retry, and success/share preview states on iPhone simulators. Those previews do not prove a successful native-authenticated export.

## Physical-device validation deferred

The user chose to test Face ID later. Native Face ID, device-passcode fallback, Secure Enclave signing, and a real export ZIP have therefore not been verified end-to-end on hardware. There is no simulator software-key bypass.

On an iPhone with a device passcode enabled:

1. For an older session, start export and complete the one-time Google enrollment. Canceling Google or device authentication must preserve the previous session.
2. Retry export and confirm the native Face ID/device-passcode prompt. Canceling must create no archive and leave the session usable.
3. Authenticate, save and inspect the ZIP, and confirm its selected categories and manifest.
4. Export again and confirm no additional Google sign-in is required; open and cancel sharing.
5. Test system passcode fallback and persistence after relaunch.

The prior Google timestamp approach failed because the configured Testing project cannot supply the required claim. It has been replaced, rather than weakening the device-proof requirement.

## Current product scope

No coach conversation, memory, plan, evidence vault, encrypted vault, or E2EE record type exists in the current repository, so this batch exports every category currently stored. Later coach and E2EE milestones must add their records to the export, define the on-device decryption and assembly boundary, and add durable coverage when those stores are introduced.

No frontend tests or production dependencies were added.
