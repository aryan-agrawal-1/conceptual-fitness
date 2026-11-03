# Insights journal — tracker #46, Batch 4

Verified on 3 November 2026. Implements #20 with the scope agreed below. Letting AI features read notes
remains in #34 and #38.

## Decisions agreed with the user

- Notes stay private in this batch. No AI feature reads them, and no consent switch appears on screen
  until one does.
- #29 stays in Milestone 3. Nothing here depends on it, because nothing passes a note to a model.
- Note text is encrypted on the server with a server-held key. Typed answers aren't, because #23 needs them.
- AI consent follows the account, through the existing journal preferences.
- Which existing notes consent covers doesn't matter yet, because the app hasn't shipped. #34 and #38 can
  decide this when they add the switch.

## Why notes don't reach the brief yet

The real brief prompt was run through Foundation Models on a Mac (macOS 26.6), using made-up notes and
scores, with mostly two runs per case. These results are indicative only, and weren't run on an iPhone.

- **Raw note in the prompt:** unreliable, even with markers and an instruction to treat it as data.
  A sore knee was acted on in 1 of 2 runs on a strong-readiness day, and the other said to maintain the
  routine. A cold was acted on in 1 of 2, and the other suggested a short workout.
- **Prompt injection:** a note asking for a max-effort workout was followed in 2 of 2 runs on a
  low-readiness day, and one run also said to skip sleep. On-device inference doesn't prevent this.
- **Fixed categories:** a separate call sorted the note into an enum, and the brief saw only our own
  wording for each category, never the note. Sore knee and cold moved the advice in 2 of 2 runs each, and
  the injection was ignored in 2 of 2. The categories were often wrong: a race also flagged planned hard
  training, and distress became stress with advice to do a moderate workout. Wording sometimes blamed the
  workout rather than the illness.
- **Refusals and stalls:** Apple's safety filter refused the classifier on a note about a divorce and
  medication in 2 of 2 runs. One classifier call stalled for minutes, cause unknown.
- **Size:** the model's context is 4,096 tokens. The brief prompt uses about 1,136 and a 2,000-character
  note about 510, so size isn't the limit.
- **Typed check-in answers:** they made no visible difference on a low-readiness day. They weren't tried on
  a strong-readiness day.

## Contract for later issues

- `JournalAIContext.notes(for:in:limit:)` is the only route from notes to an AI feature. It needs both
  `opt_in:reflection` and the feature's own `ai_context:<daily_brief|coach>:reflection`, and fails closed.
  Nothing calls it yet.
- Don't pass its text straight into a prompt. Use fixed categories or a stronger design, with a time limit
  on every model call and a brief that still works when a call is refused.
- The first feature to read notes must also:
  - add the visible consent switch, and decide whether turning Reflection off and on again keeps consent;
  - clear cached briefs that used a note when consent is withdrawn or the note is deleted, including the
    last brief shown while the Dashboard loads;
  - mark briefs that used a note, so they don't leave in a `derived_insights` export without Journal
    selected or reach the Coach without its consent;
  - replace "the app's AI can't read them" in the Private categories wording.
- #23 must use `STATISTICAL_BEHAVIOURS`. Note edits no longer change `analysis_revision` or
  `analysis_dirty_from`.
- `journal_entries.response` and `normalized` use `SealedJSON`, so anything reading through the model gets
  plain text. Raw SQL sees `{"type": "text", "ciphertext": ...}` instead of `value`.

## Encryption

- `JOURNAL_ENCRYPTION_KEY` is a comma-separated list of Fernet keys, newest first. Older keys keep opening
  existing notes, but nothing re-encrypts them yet. Production won't start without it.
- Set the key before running migration 0026. **Losing every key loses every note**, so it must be backed
  up separately from the database.
- This protects database dumps and backups, not a compromised server, which holds the key. Moving to the
  #32 vault would be needed for that. Ciphertext isn't tied to its row, and dates, input IDs and note
  length stay visible.
- Sync, the change feed, entries and export all return plain text. Export is unchanged for the user.

## Definition of done

- [x] Success, loading, empty, error and retry: an unreadable note or a missing key returns a retryable 503
  from journal routes, and saved changes stay queued on the device. A missing key doesn't block typed
  answers. Note deletion and the account-delete cascade work as before.
- [x] Regression coverage: `backend/tests/test_journal_sync.py` covers encryption at rest, every read route,
  export, unreadable text, a missing key, key rotation, the migration, analysis invalidation, consent keys
  and the note limit. `ios/ConceptualFitnessTests/JournalTests.swift` covers the gate, the limit and the
  per-account last brief.
- [x] Accessibility: wording changes and a simpler note sheet, with no new controls. VoiceOver traversal remains part of #57.
- [x] Observability: failures log the fixed reason `note_text_unavailable` and carry no note text.
- [x] Visual verification on iOS 27.2: iPhone 18 Pro and iPhone 17e.

## Checks

- iOS unit tests: **91 passed** on iPhone 18 Pro (iOS 27.2).
- Full backend suite: **259 passed, 1 failed**. The failure is
  `test_readiness_detail_returns_yearly_monthly_averages`, the same existing failure recorded in the batch
  2 and 3 notes, outside the journal.
- Ruff on the backend app, migration 0026 and the journal sync tests, and `git diff --check`: passed.
- Migration 0026 on local PostgreSQL: seal, retry, reverse and reseal, using fixture rows in a transaction
  that was rolled back. Version downgrade and upgrade also ran, and the local database stays at 0026. It
  held no notes.

On simulators with a throwaway local account, since deleted:

- The new wording appeared in Private categories and Privacy and data. The note sheet shows the date, the text box and, once a note exists, Delete note. It only mentions the limit in the last 200 characters.
- With Reflection on, a note saved from the iPhone 18 Pro reached the local API. Its row held ciphertext and
  no plain text, while a typed answer was unchanged, and `analysis_revision` counted only the typed answer.
- A fresh install on the iPhone 17e pulled the note and opened it with the correct text and count.

## Not verified

- Entering an emoji through the simulator, because pasting failed. The count is covered by unit tests on
  both sides.
- Switching between two accounts on one device to see the last brief. This is covered by a unit test.
- The Dashboard with real scores. The test account had no Google Health connection, so it showed its usual
  refresh message.
- Dark mode, the existing app-wide issue recorded in the batch 3 notes.

No physical-device tests were run. No new simulator runtimes or production dependencies were added.
