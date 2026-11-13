# Phase 2: Numbers you can trust

**Milestone:** Phase 2: Numbers you can trust · **Status:** Now

**Goal:** what the menu bar and the dropdown say is what Claude says, and the colours and the
forecast tell you something true about your usage.

- #34 **An inaccurate reading** (a bug): the app showed usage that didn't match Claude's own.
  Start from the app's logs and claude-swap's output for that account.
- #20 **Pace colours by how much is used**: green, orange and red follow the share of the limit
  used (48% is orange, 80–90% red), not how far over pace a short session is; the weekly limit
  may keep pace.
- #30 **A forecast that means something**: "runs out tomorrow" only from the pace you're
  actually using it at, nothing for an account you haven't used in days; or no forecast, only
  over or under pace.
- #35 The plan itself, so the board and these pages say the same.
