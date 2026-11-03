# Insights journal — tracker #46, Batch 3

Verified on 2 and 3 November 2026. Implements #17 and #19. Streak calculation (#21), the streak hero
(#22), behaviour analysis (#23) and free-text consent (#20) remain in their own issues.

## Decisions agreed with the user

- #17 still says "five suggested inputs", but #18 replaced suggestions with a fixed pinned list.
  The check-in uses the pinned list.
- The check-in opens as a sheet once a day over the current tab, with "Not now". After that, a
  card in Insights offers it until the day is completed.
- The quick screen shows every pinned input. With fewer than five pinned, it tops up from the
  "Show other inputs" order under "To reach five", without pinning those rows.
- The prompt appears on the first open after 04:00 in the Profile timezone, at any time of day,
  while yesterday isn't completed. It doesn't appear on the day of onboarding.
- Today can be completed the same day, and the next morning's prompt is then skipped.
- A completed day that drops below five answers becomes incomplete and must be completed again.
  Its first completion time is kept, so #21 can keep streak credit already earned.
- Any past date can be completed. Days completed after the following calendar day read "Completed
  late". Days older than yesterday show "You're editing a past day." Streak credit belongs to #21.
- After user testing, completing a check-in shows only an animated tick and "Check-in complete",
  plus the reminder offer the first time. It closes by itself after two seconds when there is no
  offer. This replaces the optional inputs and automatic context step in #17, at the user's request.
  Other inputs stay available under "Show other inputs" in Insights.
- The morning check-in is about yesterday, because mood and energy for today aren't known yet. Today
  and yesterday are never late or described as past days.
- History is a custom month grid opened from the calendar button. Tapping a day opens it in
  Insights. The week strip stays. Completed days are filled, incomplete days have an orange ring and
  missing days have a dashed red ring.
- "Missing" starts from the first journal use. Earlier days stay neutral but can be filled in,
  which moves the start back.
- The reminder is off by default, defaults to 09:00 and is offered once, after the first completed
  check-in. It is managed in a Notifications section in Profile, and skips days already completed.
- Past-day notes only state what's true today. #21 and #23 must add their own wording for the
  effect of historical edits on streaks and patterns when they ship.

## Contract for later issues

- `journal_completions` (migration 0025) holds one register per date: `completed`,
  `first_completed_at`, `timezone`, `edited_at`, `mutation_id`, `revision`. `completed` is
  last-write-wins. `first_completed_at` and its `timezone` always converge on the earliest value,
  in any delivery order, on the server and on devices.
- Completions travel through `/journal/sync` and `/journal/changes` as `kind: "completion"`, and
  are included in account export (server and pending on-device) and the user-delete cascade.
- The server records completion as a fact and does not enforce five answers. Uploads are paged and
  another device can clear answers later, so rejecting would strand a queued completion. A day
  counts as completed only when `completed` is true and it has at least five answers, so #21 must
  apply both rules.
- Completion doesn't change `analysis_revision`, because it changes no observation.
- Answers count toward five only when they have a value. No and zero count. Skipped and "doesn't
  apply" don't.
- Reminder settings are device-only, under per-account `UserDefaults` keys. They are cleared by
  account deletion, and pending reminders are removed on sign-out.

## Reminder behaviour

- The wording is fixed: "Daily check-in" / "Your check-in is ready." It never names an input.
- Each date is scheduled individually for the next 30 days, in the device's current timezone, and
  rescheduled when completed days or the timezone change, and on launch and foreground.
- A reminder before 12:00 is about yesterday, and skips if yesterday or today is completed. From
  12:00 it is about today, and skips only if today is completed, so evening loggers still get it.
- Known limits of local notifications: a check-in completed on another device can't cancel a
  reminder until this device next opens the app, and reminders stop after 30 days without opening
  the app.

## Definition of done

- [x] Success, loading, empty, error and retry: the check-in, calendar and reminders use local data
  and work offline. A failed local save keeps the sheet open and shows the existing storage message.
  Denied notification permission is explained in Profile, with a link to Settings.
- [x] Regression coverage: `ios/ConceptualFitnessTests/JournalTests.swift` covers day states, first
  use, quick screen and top-up, the prompt rules and timezone boundary, reminder plans and wording,
  completion and withdrawal, merging, restart, older saved files and export.
  `backend/tests/test_journal_sync.py` covers retries, delivery order, paging, validation, export
  and cascade.
- [x] Accessibility: controls have labels, values and selected state, day states use shape as well
  as colour, and completion is announced. At the largest text size the Complete controls move inline
  and the Insights card stacks. The seven-column week strip and calendar are capped at xxLarge.
  VoiceOver traversal remains part of #57.
- [x] Observability: reminder and completion failures use fixed reason codes. Validation responses
  and logs carry no health data or timezone values.
- [x] Visual verification on iOS 27.2: iPhone 18 Pro and iPhone 17e. The final complete page, Profile
  section and calendar colours were checked on iPhone 18 Pro only. See below.

## Checks

- iOS unit tests: **84 passed** on iPhone 18 Pro (iOS 27.2).
- Full backend suite on 2 November, before the iOS-only design changes: **249 passed, 1 failed**. The
  failure is
  `test_readiness_detail_returns_yearly_monthly_averages`, the same existing failure recorded in the
  batch 2 notes, outside the journal.
- Ruff on changed backend files and `git diff --check`: passed.
- Migration 0025: upgraded and round-tripped (downgrade and upgrade) on local PostgreSQL. The local
  database stays at 0025. SQLite can't run the full chain here because an earlier migration needs
  `md5`.

On simulators with a throwaway local account, since deleted:

- The prompt opened over Dashboard with the correct date, and didn't appear on the onboarding day.
- Complete stayed locked at four answers and unlocked at five, including No answers.
- Completion reached the local API with the journal date and first completion time.
- The completed page animated, and its reminder offer and permission prompt worked. The offer didn't
  return afterwards, and the page then closed by itself. The reminder was then managed from Profile.
- The calendar showed completed, incomplete, missing and neutral days correctly, with the weekday
  alignment and next-month limit right. Tapping a day opened it in Insights.
- An old day completed from the header read "Completed late". Clearing an answer on yesterday showed
  4/5 and the explanatory note, and the card returned.
- A reminder fired on time with the fixed wording. Tapping it opened the check-in that was due with
  the app in the background. This replaced an `async` notification delegate method that finished off
  the main thread and crashed the app when a reminder was tapped; no automated test can construct a
  notification response, so this is covered by the manual check only.
- Completing while the API rejected requests stayed queued with a clear message. It uploaded after
  reconnecting, keeping the original first completion time.
- A check-in request didn't interrupt an open live workout, and appeared after it was minimised and
  the tab changed.

## Not verified

- Tapping a notification on a physical device, which remains part of #57.
- A cold launch from a notification while properly signed in opening the check-in. On the simulator's
  debug session a cold launch reached the sign-in screen without crashing, because it carries no
  debug arguments.
- The 04:00 boundary, day rollover and late-night behaviour were covered by unit tests rather than
  waiting for real time to pass.
- Dark mode. `AppBackground` is always light and nothing forces light mode, so text is unreadable in
  dark mode across Insights, on `main` as well as here. This is an app-wide issue, not fixed in this
  batch.

No physical-device tests were run. No new simulator runtimes or production dependencies were added.
