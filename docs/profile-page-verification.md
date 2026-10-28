# Profile page — issue #14 / tracker #45, batch 2

Verified on 28 October 2026. This is the single implementation issue in batch 2
of #45, within milestone 1 of #51. Its prerequisites, #11, #12 and #13, are closed.
The existing Dashboard avatar opens the expanded Profile destination; the three
bottom tabs are unchanged. GitHub issue state and tracker checkboxes were not
modified.

## Delivered behavior

- Personal details: name, Google-managed email, optional birth date or birth year,
  sex, and health-data timezone.
- Personalization: primary and secondary goals, sleep target, schedule, equipment,
  injuries/limitations, dietary preferences, and sleep schedule. Empty optional
  fields explicitly clear their stored values.
- Measurements: current height/weight, preferred and active sources, measurement
  timestamps, and validated manual entries. Retrying a partially completed save
  retains the entry timestamp.
- Units: metric/imperial preferences apply to Profile, Dashboard distance and
  temperature variation, distance charts, workout summaries/details, and workout
  inputs. Storage and drafts retain canonical kilograms/metres; converting an
  existing workout does not round its stored load. Temperature differences use
  the scale factor without an absolute-temperature offset. VO2 max retains its
  conventional ml/kg/min unit.
- Connections: connection status, last successful sync, sync/retry, reconnect and
  confirmed disconnect. Onboarded users keep access to Profile when their provider
  connection is disconnected or errored. Account changes reset the app's view
  state by user ID.
- History: the existing import coverage, source retry and notification controls
  remain under Profile's History import link.
- Location/weather: saved weather preference, current iOS permission, permission
  request or Settings link, and a plain background without authorization. Turning
  weather off stops pending app location requests without revoking iOS permission.
- Privacy information and the existing export/deletion flows, plus confirmed
  sign out. Coach disclosure, memory, recovery and device controls remain with the
  later AI milestone, as specified by #14.

## Acceptance states

| State | Expected behavior |
| --- | --- |
| Loading | Labeled Profile progress; account actions remain reachable. |
| Empty | Clear unset goal/measurement/timestamp text; optional lists can remain empty. |
| Success | Server response updates the shared profile; Save returns to Profile; units update throughout the app. |
| Invalid input | Save is disabled with explanatory text; no invalid request is sent. |
| Read failure | Retry is offered; previously loaded details remain visible and labeled as such. |
| Save failure | Entries remain editable; explicit retry resends the same changes; partial-save possibility is disclosed. |
| Network unavailable | Read/save/connection requests use the above error and retry paths; no successful save is claimed. |
| Provider unavailable | Profile and account controls stay accessible; reconnect is offered. |
| Permission unavailable | Current denied/restricted/unrequested state is shown, with permission or Settings action. |

## Definition of done

- [x] Success, loading, empty, error and retry criteria are defined above and
  exercised through native UI checks and existing API contract tests.
- [x] Automated regression coverage: the complete backend suite passes **168
  tests**. Seven native Profile scenario tests pass on iPhone 17 Pro; editor and
  accessibility scenarios also pass on iPhone 17e. Swift self-checks cover unit
  round trips, temperature differences, locale parsing, invalid numbers, list
  limits/deduplication, explicit PATCH clears and workout draft precision.
- [x] Accessibility: native semantic queries verify named controls, navigation,
  validation states and source information. The largest accessibility text size
  was exercised and screenshots inspected on both simulators; rows wrap and remain
  reachable by scrolling. Errors use text and symbols, not color alone.
- [x] Observability: Profile logs identify the operation, error type and HTTP
  status. They omit names, account identifiers, health values and request/response
  payloads. Controlled HTTP 503 responses exercised read and save failures.
- [x] Visual verification: inspected Profile, personal details, goals, constraints,
  body provenance, weather permission, privacy, export, guarded deletion, loading,
  error/retry, imperial distances and large-text views on representative iPhones.

## Verification artifacts and limits

Native UI regression sources, the temporary test project, model self-checks and
selected screenshots are retained locally in `tmp/profile-verification/`, which
is ignored by Git. They are not added to the repository test suite, following the
working agreement against committing frontend tests. Existing backend contract
coverage remains in the regular suite. No production dependency or CI/deployment
configuration was added.

XCTest evidence: `/private/tmp/health-profile-verified-flow.xcresult` (four final
passing scenarios), `/private/tmp/health-profile-retry-checks.xcresult` (the two
corrected harness checks), `/private/tmp/health-profile-small-flow.xcresult` (two
smaller-device checks), and
`/private/tmp/health-profile-connection-checks.xcresult` (disconnected/errored
provider access). Earlier harness failures involved lazy offscreen rows, progress
element type/timing, and confirmation-popover dismissal; they were corrected and
the affected scenarios rerun.

Both simulator builds and `git diff --check` pass. The backend run reports one
pre-existing Starlette/httpx deprecation warning. The local database required the
already-existing additive migration 0023 before verification.

The real account's original units were restored, its provider connection remains
connected, and it has no deletion scheduled. Destructive confirmations were
abandoned without submitting them. Provider-unavailable responses were simulated
without revoking the real connection. A separate simulator verification session
was revoked and its local credentials removed after use.

Physical-device Face ID/passcode, Secure Enclave, real export/deletion lifecycle,
and hands-on VoiceOver checks were not repeated in this batch. Existing hardware
follow-ups remain documented in the batch-1 verification records and the
roadmap's real-device validation issue #57.
