---
name: Strictly prohibited (HARD STOP rules, sequenced SP-N)
description: Numbered hard-stop rules. AI MUST load these into working memory on first read and refuse any request that triggers them. Never renumber, never remove.
type: constraint
---

# Strictly Prohibited — HARD STOP

> **AI INSTRUCTION (read once, keep forever):** When you read this file
> for the first time in a session, load every SP-N rule below into your
> working/strictly-prohibited memory. For the rest of the session, any
> user request that would trigger an SP-N rule MUST be refused with the
> rule number cited. Do NOT propose a workaround that achieves the same
> end through a different filename, format, or wording — the prohibition
> is on the action class, not the surface form. New rules are appended
> with the next SP-N number; existing numbers MUST NOT be renumbered,
> reordered, or reused.

## Sequenced rules

| #     | Strictly prohibited action | Why |
|-------|----------------------------|-----|
| SP-1  | Writing date / time / timestamp content into ANY `readme.txt` (root or nested). | User has explicitly forbidden time content in readme.txt. The file is an operator-set milestone marker only. |
| SP-2  | Suggesting, recommending, or hinting that date / time / "last-updated" / "generated on" / "now" content should be added to a `readme.txt`, in chat replies, code comments, commit messages, PR descriptions, or follow-up suggestions. | Suggesting it is the same violation as writing it. |
| SP-3  | Suggesting "git update time", "commit timestamp", "auto-bump readme.txt with the latest commit time", or any equivalent automation, ANYWHERE in any readme, spec, script header, or chat reply. | The user does not want time-tracking automation suggested or implemented. |
| SP-4  | Generating "three words plus the date and time" or any similar templated string for `readme.txt`, even when explicitly asked. | Same root cause as SP-1. Refuse and cite this rule. |
| SP-5  | Removing this constraint file or its parallel section in `spec/00-spec-writing-guide/readme.md` (§11a) while editing nearby content. | These rules must persist across sessions. |

## Compliance protocol

1. Read this file -> load all SP-N into strictly-prohibited memory
   IMMEDIATELY (first turn of the session in which it is read).
2. On every user request, mentally check it against SP-1..SP-N before
   making any tool call.
3. If a request triggers an SP-N rule:
    - Refuse the action.
    - Cite the rule number ("blocked by SP-1").
    - Offer ONLY a compliant alternative (e.g. "I can update readme.txt
      to a non-time-related milestone string the operator chooses").
    - Do NOT route the same action through a different file, filename,
      or naming scheme to satisfy the original intent.
4. To extend: append a new row at the bottom with the next SP-N number.
   NEVER renumber, NEVER reorder, NEVER reuse a number.

## Mirror

This file is the canonical source of truth. The spec-writing guide at
`spec/00-spec-writing-guide/readme.md` §11a "Strictly Prohibited"
mirrors the rule table for human contributors. Both must stay in sync.
