---
name: 68-user-mgmt shared strict-JSON-schema validator
description: helpers/_schema.sh exposes um_schema_normalize_array, um_schema_validate_record, um_schema_report, um_schema_record_name -- consumed by all four *-from-json.sh leaves
type: feature
---
## scripts-linux/68-user-mgmt/helpers/_schema.sh

Single source of truth for strict JSON-schema validation across the four
bulk loaders (`add-user`, `add-group`, `edit-user`, `remove-user`-from-json).
Replaced ~80 lines of duplicated jq + reporting logic per loader.

### Public API
- `um_schema_normalize_array <file> <wrapper-key> [--allow-strings]`
  Normalises {single object | array | wrapped object} into a JSON array on
  `UM_NORMALIZED_JSON`; sets `UM_NORMALIZED_COUNT`. `--allow-strings` maps
  bare strings to `{name: ...}` (used by `remove-user-from-json.sh`).
  Returns 2 on parse failure (already logged via `jsonParseFail` template
  when available).
- `um_schema_validate_record <rec> <allowed> <required> <specs> [<mutex>]`
  Builds and runs a single jq program. Emits TSV
  `ERROR<TAB>field<TAB>reason` / `WARN<TAB>...` rows on stdout.
  Spec DSL items: `field:rule` where rule ∈
  `nestr | str | bool | uid | nestrarr`. Mutex pairs are space-separated
  `a,b` items.
- `um_schema_report <i> <file> <out> [<mode> [<allowed>]]`
  Walks TSV; sets `UM_SCHEMA_ERR_COUNT`. Modes:
    * `rich`  -> uses um_msg templates `jsonRecordBad`,
      `schemaFieldEmpty`, `schemaFieldType`, `schemaArrayItemType`,
      `schemaUnknownField` (used by add-user-from-json).
    * `plain` -> single generic line per error (edit/remove/add-group).
- `um_schema_record_name <rec>` -> echoes `.name`, `<missing>`, or
  `<not-an-object>`. Never errors.

### CODE RED guarantee
Every error and warning line carries the exact JSON file path, the
record index, and the field path -- inherited by all four loaders.

### Verified at v0.204.0
26/26 smoke-test cases pass; rich-mode rejection messages preserved
verbatim (wrong-type / empty / missing-required / unknown-field warning
/ schemaRecordRejected summary).
