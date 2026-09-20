# Profile schema — issue #11

Implemented issue #11 from tracker #45, within milestone 1 of #51. Checked on
19 September 2026. The implementation is submitted for review; the issue stays
open until merge.

The profile API now stores one primary goal, secondary goals, typed coach
constraints, and a metric/imperial display preference. Existing `fitness_goal`
requests and responses remain valid as an alias for `primary_goal`; body values
remain stored in canonical centimetres and kilograms. Height and weight report
their selected manual/provider source and the winning measurement timestamp.

## Definition of done

- [x] Success, empty, error and retry behavior: new profiles return stable empty
  collections and metric units; PATCH supports partial updates and explicit
  clears; invalid and conflicting values return 422 without writes; retrying the
  same update is idempotent. Loading and offline presentation belong to the
  blocked Profile UI issue #14 and are not introduced by this backend contract.
- [x] Durable regression coverage: tests cover defaults, legacy goal compatibility,
  complete and partial updates, explicit clears, validation, idempotent retry,
  deterministic manual/provider precedence, active source and measurement time.
- [x] Accessibility: no controls or visible content are added by this backend
  issue. The existing onboarding decoder and requests remain source-compatible;
  presentation and accessibility checks for the new fields remain in issue #14.
- [x] Observability: validation and authentication failures use existing HTTP
  status handling. The new paths do not log profile or health payloads.
- [x] User-facing visual behavior: no new fields are displayed before issue #14.
  The existing iOS onboarding and Profile destination remain build-compatible
  with the additive response contract.

## Checks

- Focused profile and body API suite: **16 passed**.
- Changed-file Ruff, Python compilation and `git diff --check`: passed.
- Migration 0020 targeted upgrade and downgrade from a stamped 0019 schema:
  passed; existing `fitness_goal` is untouched.
- Alembic revision chain: one head, ordered 0020 → 0021 → 0022.
- Integrated backend suite: **162 passed** with one existing Starlette/httpx
  deprecation warning.
- Final iOS build and simulator verification are owned by issue #12 and will be
  recorded in the Batch 1 pull request after its UI changes are integrated.

No frontend tests or new production dependencies were added.
