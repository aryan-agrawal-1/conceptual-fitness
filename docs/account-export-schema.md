# Account export schema

Account exports are ZIP archives with a `manifest.json` and one JSON file for each category selected by the user. The manifest is always present and records the export schema version, generation time, selected categories, files, and record counts.

Schema version `1.0` supports:

- `health_and_workouts.json`: imported source records, normalized health measurements and rollups, sleep, workouts, workout provenance, exercises, sets, favorites, routines, and match decisions.
- `journal.json`: user-entered daily context and journal/tag records.
- `derived_insights.json`: summaries, personal baselines, scores with algorithm versions and inputs, strain targets, and daily briefs cached on the exporting device.
- `personalization.json`: account identity, profile and preferences, safe Google Health connection metadata, and import coverage/provenance.

Every category file has this shape:

```json
{
  "schema_version": "1.0",
  "category": "journal",
  "tables": {
    "daily_contexts": []
  }
}
```

Dates and timestamps use ISO 8601 strings. Empty selected categories contain their documented tables with empty arrays. Table and field names follow the backend storage schema so future readers can distinguish source data from derived data.

Provider refresh tokens, app access and refresh tokens, OAuth state, one-time authorization grants, sync page tokens, and internal error text are excluded. The app sends cached daily briefs to the export endpoint only while generating the archive; the backend does not persist them.

The current product has no stored coach conversation, memory, plan, evidence-version, encrypted-vault, or E2EE record types. A future encrypted-memory implementation must decrypt and assemble those records on-device rather than send plaintext memory to the backend.
