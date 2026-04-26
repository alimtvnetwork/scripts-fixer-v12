---
name: No-Questions Mode (40-task window)
description: Do NOT ask the user clarifying questions; record ambiguities to .lovable/question-and-ambiguity/ instead and proceed with best inference
type: preference
---

# No-Questions Mode

**Active from:** 2026-04-26, for the next **40 tasks**.
**Resume trigger:** the user explicitly says "ask question if any
understanding issues" (or an obvious paraphrase).

## Behaviour rules

1. **Never call** `questions--ask_questions` while this mode is active.
2. When a task is ambiguous, pick the best-suited inference based on
   project patterns, user preferences, and risk profile, and proceed.
3. **Always log** the ambiguity to a new file:
   `.lovable/question-and-ambiguity/xx-brief-title.md`
   where `xx` is the next zero-padded sequence number.
4. Append the new file to the index table in
   `.lovable/question-and-ambiguity/README.md`.
5. Each ambiguity file MUST contain:
   - Original spec reference (file path or chat excerpt)
   - Triggering task line
   - The specific point of confusion
   - Every reasonable option with pros/cons
   - A recommendation with reasoning
   - The inference actually used
   - How to revert / change course
   Use `_TEMPLATE.md` as the starting point.
6. Continue forward momentum — never stop work waiting for clarification.
7. At the end of every response, if any ambiguity was logged this turn,
   list those files in the summary so the user can see them in flight.

## Why

User wants uninterrupted execution across a 40-task batch. Clarifications
will be reviewed in bulk at the end of the window.