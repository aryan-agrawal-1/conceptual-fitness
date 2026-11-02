# Insights journal — tracker #46, Batch 2

Verified on 28–29 October 2026. Implements #16 and #18 within the delivery sequence
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
  30-second timer while the app is active retry queued changes. A completed
  request is persisted before the cursor advances. Pagination includes tombstones.
- Creating, reading, replacing and deleting responses are supported by
  `/journal/sync`, `/journal/entries` and `/journal/changes`. Each date/input is an
  independent register; duplicate retries do not create entries or invalidations.
- The winner is the greatest `(edited_at UTC, canonical mutation UUID)` tuple.
  Deletion uses the same ordering and clears the stored answer. Tombstones are
  retained so old offline devices cannot resurrect deleted entries. Device clocks
  more than five minutes ahead are rejected with a retryable, actionable error.
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

## #18: suggestions acceptance criteria

- Exactly five eligible suggestions are ranked with fixed rules. No model or
  generated selection participates. All catalogue inputs remain accessible.
- Scores combine pins (+1000), matching Profile goal keywords (+80), universal
  starting points (+60), record-building needs (+30), use in the last 30 days (+20)
  and daily rotation (0–78). Equal scores sort by stable behaviour ID. Expanding a
  suggestion explains the contributing rules. The implementation contains the
  explicit goal keyword mapping; unmatched free-form goals add no goal weight.
- Record-building prioritizes previously used inputs with fewer than ten answers
  in 30 days, or booleans with fewer than three answers on either side. These are
  suggestion heuristics, not statistical evidence thresholds for future analyses.
- Pins synchronize independently, have no hard limit and are accessible through
  the full catalogue even when more than five are pinned. The UI recommends roughly
  5–10 tracked inputs without enforcing a maximum.
- Sensitive suggestions require current explicit category opt-in **and** a live,
  deliberately answered response on or before the selected date. Explicit No
  counts as deliberate use; unknown, skipped, deleted and provider data do not.
- Private names/answers stay discreet in suggestions and saved-entry lists.
  Deliberately exploring an enabled category reveals input names for selection.
  Revoking access removes suggestions and stops new sensitive answers. Existing
  entries can be reviewed/deleted. Pending private changes stay on-device until
  category access is restored and do not block unrelated synchronization.
- Free text is available as private user data, excluded from suggestions and
  statistical inputs. This feature does not send journal data to AI.

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
  The temporary Swift harness covers local restart/retry, edits during upload,
  protected cache failure/corruption handling and deletion during an upload.
- [x] Relevant accessibility: native accessibility labels, disabled empty-editor
  Save, explicit missingness choices and 44-point custom row/pin/explanation
  targets were checked. The iPhone 17e layout was inspected at accessibility text
  size; content wraps in the native List. Physical-device VoiceOver traversal is
  part of the release device validation in #57.
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

- [x] Success, loading, empty, error and retry acceptance criteria: five explained
  suggestions use cached data offline, the first-use state exposes Retry, pins
  persist immediately, and the full catalogue/private-category controls remain
  available. The suggested tracking count is guidance rather than a hard limit.
- [x] Applicable regression coverage: the temporary Swift harness checks stable
  daily selection, rotation across dates, pin priority, sensitive opt-in plus
  deliberate use, No versus missing/deleted data, timezone/DST boundaries, rating
  bounds and quantity limits after conversion. Backend coverage checks durable
  per-key preference synchronization and saved consent enforcement.
- [x] Relevant accessibility: explicit Pin/Unpin labels, expanded/collapsed
  explanation state and 44-point custom button frames were measured in the
  native accessibility tree. Large-text presentation was inspected on iPhone 17e.
- [x] Observability: suggestions are fixed local rules and produce no health-data
  logs. Preference failures use the same payload-free sync diagnostics as #16.
- [x] Visual verification: inspected the journal/suggestion layout on iPhone 17
  Pro and iPhone 17e; native pin state survives offline restart. A temporary layout
  session used the same account on the second simulator and was revoked after
  verification. The original session was preserved and text-size settings restored.

## Checks and limits

- Full backend suite: **241 passed**, with the existing Starlette/httpx
  deprecation warning. Latest focused journal suite: **7 passed**, including the
  additional account-deletion race and pending-local-export assertions.
  Final timezone-preservation regression check: **1 passed**.
- Existing catalogue/route baseline before changes: **68 passed**.
- Temporary Swift verification harness: passed. No frontend tests were added to
  the tracked source tree. Durable backend regression tests are in
  `backend/tests/test_journal_sync.py`.
- Final iOS Debug simulator build: passed. Swift type checking includes all new
  journal models, storage, ranking and views, and the account/export integration.
- Changed-file Ruff, Python compilation and `git diff --check`: passed.
- Migration 0024: native PostgreSQL upgrade passed. Isolated SQLite upgrade,
  downgrade and re-upgrade passed while preserving existing users.
- Simulator plugin capture/control calls intermittently timed out; verification
  continued with Xcode and the plugin's bundled AXe driver plus `simctl`.
- Local screenshots are in the ignored `tmp/journal-verification/` directory.
- Native catalogue navigation was checked: ordinary inputs are available while
  unenabled private categories show their access controls without behaviour names.
  The private-category destination was inspected without changing consent settings.
- No physical-device tests were run. Secure Enclave/Face ID and full release
  validation remain in #57. The future analysis engine (#23) must consume the
  journal invalidation revision; this batch does not create speculative results.

No production dependencies, CI changes, commits, pushes, pull requests or GitHub
issue changes are part of this work. Real-device release validation remains #57.
