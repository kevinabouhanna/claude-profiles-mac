# Phase 2: Numbers you can trust

**Milestone:** Phase 2: Numbers you can trust · **Status:** Now

**Goal:** what the menu bar and the dropdown say is what Claude says, and the colours and the
forecast tell you something true about your usage.

- #61 **A refused switch says why** (a bug): picking Personal did nothing when cswap refused
  because another app ran Claude on Personal's own sign-in; the message was cleared a moment
  later by the refresh.
- #34 **An inaccurate reading** (a bug): the app showed usage that didn't match Claude's own.
  Start from the app's logs and claude-swap's output for that account.
- #20 **Pace colours by how much is used**: green, orange and red follow the share of the limit
  used (48% is orange, 80–90% red), not how far over pace a short session is; the weekly limit
  may keep pace.
- #30 **A forecast that means something**: "runs out tomorrow" only from the pace you're
  actually using it at, nothing for an account you haven't used in days; or no forecast, only
  over or under pace.
- #48 **Keep the tooling and the plan in order**, a standing item: product-kit's tools kept
  current (each update is a step of it), local CI, and the board and these pages saying the
  same, which the plan itself (#35) started on 13 Nov.
