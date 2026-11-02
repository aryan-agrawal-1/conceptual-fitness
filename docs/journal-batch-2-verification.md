# Insights journal — tracker #46, Batch 2

Verified on 28–29 October and 2 November 2026. Implements #16 and #18 within the delivery sequence
in #51. The user confirmed a
usable Insights journal for this batch and automatic deterministic conflict
resolution. The guided morning check-in, explicit completion, calendar/history
presentation, reminders and AI reflection remain in their scheduled later issues.

## #16: storage and synchronization acceptance criteria

- A response is reported saved only after its account-scoped protected file is
  written atomically. Missing catalogue/Profile timezone on first use requires a
  connection; subsequent edits work offline. Local write failures keep the editor
  open. An unreadable cache is preserved and blocks writes until it can be opened.
- Opening the app or Insights, returning to the foreground, manual retry and a
  30-second timer while the app is active retry queued changes. The timer runs only
  when something needs retrying, and a pull that changes nothing doesn't rewrite the
  file. A completed request is persisted before the cursor advances. Pagination
  includes tombstones. Devices download a newer catalogue when the change feed
  advertises one.
- Creating, reading, replacing and deleting responses are supported by
  `/journal/sync`, `/journal/entries` and `/journal/changes`. Each date/input is an
  independent register; duplicate retries do not create entries or invalidations.
- The winner is the greatest `(edited_at UTC, canonical mutation UUID)` tuple.
  Deletion uses the same ordering and clears the stored answer. Tombstones are
  retained so old offline devices cannot resurrect deleted entries. Device clocks
  more than five minutes ahead are rejected with a stable `clock_ahead` code, and the
  app tells people to correct their clock. Their entries stay queued for retry.
- Dates are explicit Profile-timezone calendar keys, never inferred from upload
  time. Historical entries retain their original timezone, recording/observation
  timestamps, catalogue version, entered units and missingness; normalized values
  are saved alongside the original response. A timezone change does not move
  previously chosen dates. The editor shows the preserved input timezone and
  explains when it differs from the current Profile timezone.
- Only typed manual responses enter the journal response store. Provider context
  stays in its original provider tables and cannot impersonate an intentional
  response. No, zero and unknown remain distinct.
- Accepted historical changes increment `analysis_revision` and preserve the
  earliest `analysis_dirty_from` atomically with the edit. There is no journal
  analysis engine or result store yet (#23); its implementation must consume this
  invalidation contract. Existing health scores do not consume journal responses.
  Saving does not create check-in completion or streak state (#17/#21).
- Server-side journal data and preferences participate in account export and the
  existing user-delete cascade. Pending on-device entries/preferences are included
  separately in journal exports. Account deletion clears the local file and its
  epoch prevents in-flight requests from recreating it. Sign-out preserves queued
  journal data under that account, inaccessible until that account signs in again.
- A verified session is cached in Keychain. Network/server failures on restart can
  reopen previously onboarded local data while retaining credentials; explicit
  server rejection still signs out. Remote operations continue to require normal
  server authentication. Sign-out/deletion clears the cached session.

## #18: daily list acceptance criteria

The issue asked for five ranked suggestions with daily rotation. After reviewing the
design, the user replaced that with a fixed pinned list, because a daily habit works
better when the same rows stay in the same place. The issue text still needs updating.

- Five inputs are pinned by default: Mood, Perceived stress, Energy, Worked late and
  Screen use in bed. Any input can be pinned or unpinned. There is no hard limit and
  no rotation. No model or generated selection participates.
- All other inputs sit behind "Show other inputs", ordered by matching Profile goals,
  then use in the 30 days before the selected date, then stable behaviour ID. Only
  earlier days count as use, so answering never moves a row. The section opens by
  itself when one of its inputs has an entry for the selected date.
- Pins synchronize independently. An explicit saved value overrides the defaults.
- Turning on a private category pins all of its inputs in a named section, including
  any unpinned earlier, without requiring a previous answer. Private inputs are shown by
  name in Insights only while their category is on. Notifications (#19) stay discreet.
- Turning a category off removes its rows and stops new answers. Existing entries for
  the selected date stay reviewable under a discreet label and can be deleted. Pending
  private changes stay on-device until access returns and do not block other sync.
- Yes/No and rating answers save with one tap, and tapping the same answer clears it.
  A No clears any details. Yes opens one main detail inline (stepper, slider or severity
  buttons), with other fields behind More details. Slider limits are everyday ranges;
  larger values can be typed in the answer sheet.
- The header shows answers against a target of five, then "Daily target reached". This
  is display only: it records no completion or streak (#17/#21). Skipped and not
  applicable responses do not count; No does.
- Normal saves show no status. A sync problem shows its message with Retry.
- Free text is available as private user data and excluded from statistical inputs.
  This feature does not send journal data to AI.

## #16 definition of done — explicitly checked

- [x] Success, loading, empty, error and retry acceptance criteria: the contracts
  above define first-use download, immediate local saves, historical CRUD,
  deterministic merges, tombstones, failed local writes and network recovery.
  Native verification saved an explicit skipped response, confirmed its receipt
  in PostgreSQL, and removed the temporary response through the deletion contract.
- [x] Applicable regression coverage: backend tests cover authentication,
  isolation, idempotent retries, historical invalidation, merge order/tie-breaks,
  deletion/restore, missingness, unit normalization, consent, atomic rollback,
  pagination, export, account deletion races and retryable storage failures.
  iOS tests cover local restart/retry, merge order, cache corruption handling and
  clock rejections. Edits during upload and deletion during an upload were checked by
  the earlier temporary Swift harness, which is no longer tracked.
- [x] Relevant accessibility: native accessibility labels, disabled empty-editor
  Save and explicit missingness choices were checked. Text wraps at accessibility
  sizes, and the redesigned rows stack their controls. Physical-device VoiceOver
  traversal is part of the release device validation in #57.
- [x] Observability: journal validation/storage diagnostics contain stable reason
  codes or HTTP status only. Tests verify that health values, prose and email do
  not enter new failure logs or journal validation responses.
- [x] Visual verification: iPhone 17 Pro and iPhone 17e simulators on iOS 26.5.
  Checked the journal, blank/typed editor, explicit skipped state, loading/sync,
  saved state and offline presentation. A cold launch with the API stopped kept
  the existing account signed in and opened the cached journal. An offline pin
  survived app restart and installation of the updated build, then synchronized
  after reconnection. The temporary response/pin were restored, the secondary
  session revoked and the local API left running for review.

## #18 definition of done — explicitly checked

- [x] Success, loading, empty, error and retry acceptance criteria: the pinned list and
  saved answers use cached data offline, first use exposes Retry, pins persist
  immediately, and every input and private category stays reachable.
- [x] Applicable regression coverage: iOS tests check default pin order, no rotation
  across dates, pinning and unpinning, category on/off/on behaviour, reviewable answers
  in categories that are off, stable rows while answering, goal and earlier-use ordering,
  the daily target, No clearing details, rating bounds and quantity limits after
  conversion. Backend coverage checks durable per-key preference synchronization and
  saved consent enforcement.
- [ ] Relevant accessibility: controls have explicit labels and selected state, and large
  text was inspected at the accessibility-large size. Rating steps are full row height
  but narrower than 44 points. VoiceOver traversal has not been run.
- [x] Observability: the list uses fixed local rules and produces no health-data logs.
  Preference failures use the same payload-free sync diagnostics as #16.
- [x] Visual verification: iPhone 17 Pro on iOS 26.5 and iPhone 17 on iOS 27.0. iPhone 17e
  was not rechecked after the redesign. On iPhone 17 Pro: pinning, rating and Yes/No
  answers, Substances on and off, slider and stepper values synchronizing, the answer
  sheet opening, large text and the target states. Unit tests alone cover skip, not
  applicable and the turned-off section. On simulators, the system category toggle
  responded to a drag but not to an injected tap; check it on a device in #57.

## Checks and limits

- Full backend suite on 2 November 2026: **244 passed, 1 failed**, with the existing
  Starlette/httpx deprecation warning. The failure is
  `test_readiness_detail_returns_yearly_monthly_averages`, outside the journal: it
  seeds data from the 1st of the month up to today, so it appears to have too little
  data early in a month. Focused journal suite `test_journal_sync.py`: **9 passed**.
- Existing catalogue/route baseline before changes: **68 passed**.
- iOS unit tests: **44 passed** on iPhone 17 (iOS 26.5). Durable regression tests are
  in `ios/ConceptualFitnessTests/JournalTests.swift` (daily list, validation, timestamps,
  offline saves, merging, private queues, idle syncs, catalogue refresh) and
  `backend/tests/test_journal_sync.py`.
- Native check on iPhone 17 Pro (iOS 26.5): the journal file was unchanged across 65
  idle seconds, and a pin and unpin both reached the local API with nothing left queued.
- Final iOS Debug simulator build: passed. Swift type checking includes all new
  journal models, storage, ranking and views, and the account/export integration.
- Changed-file Ruff, Python compilation and `git diff --check`: passed.
- Migration 0024: native PostgreSQL upgrade passed. Isolated SQLite upgrade,
  downgrade and re-upgrade passed while preserving existing users.
- Simulator plugin capture/control calls intermittently timed out; verification
  continued with Xcode and the plugin's bundled AXe driver plus `simctl`.
- Local screenshots are in the ignored `tmp/journal-verification/` directory.
- Inputs in private categories that are off are not listed by name until the category
  is turned on, and the private-category screen was exercised on the local account.
- No physical-device tests were run. Secure Enclave/Face ID and full release
  validation remain in #57. The future analysis engine (#23) must consume the
  journal invalidation revision; this batch does not create speculative results.

No production dependencies or CI changes are part of this work. Real-device release
validation remains #57.
