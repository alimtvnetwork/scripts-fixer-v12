# Compliance Reports

Append-only log of requests blocked by an SP-N rule from
`.lovable/memory/constraints/strictly-prohibited.md` (mirrored in
`spec/00-spec-writing-guide/readme.md` §11a).

## File naming

`NNN-<short-slug>.md` — zero-padded 3-digit sequence, never reused,
never renumbered. New reports always use the next number.

## Required sections per report

1. **Header** — Report ID, Status (BLOCKED), source rules file, spec mirror.
2. **Requested action** — verbatim summary of what the user asked for.
3. **Triggered rules** — table of SP-N rules with the trigger phrase and why.
4. **Action taken** — what the assistant did (refuse, cite rule, etc.).
5. **Files NOT written / NOT committed** — explicit list.
6. **Files that WERE written** — only rule-maintenance edits, if any.
7. **Compliant alternatives offered** — the legal options presented.

## Index

| ID     | Date-agnostic slug              | Rules triggered           |
|--------|---------------------------------|---------------------------|
| CR-001 | readme-txt-time-block           | SP-1, SP-2, SP-3, SP-4, SP-6 |

(Date columns are intentionally omitted; SP-1..SP-4 forbid date/time
content from leaking into repository documentation, and the same spirit
is applied here.)