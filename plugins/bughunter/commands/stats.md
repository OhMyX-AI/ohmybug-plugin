---
description: Show my OhMyBug hunting record — bugs found, reviews run, balance
---

Call the `ohmybug` MCP tool `get_balance` and present the result as a short
human table:

- bugs confirmed (real) and minor bugs (never billed)
- reviews run, and how many actually found bugs
- false positives the cloud sent (cost the user nothing)
- free reviews left, balance, total billed
- the hunt modes from `modes`: each mode the service runs for this key and
  its price; no `modes` (an older server): leave the row out, never fill it
  from memory

One screen, no fluff. If the call fails with an authentication error, follow
the sign-in instructions from the `bughunter` skill.
