# Phase 2: Numbers you can trust

**Milestone:** Phase 2: Numbers you can trust · **Status:** Now

**Goal:** what the menu bar and the dropdown say is what Claude says, and the colours and the
forecast tell you something true about your usage.

- #61 **Switching works while Home Control runs** (a bug): picking Personal did nothing when
  cswap refused because Home Control's assistant ran Claude on Personal's own sign-in, and the
  refresh cleared the message. The app now stops such background helpers and switches, and
  says plainly why when it still can't.
- #63 **Menu bar colours readable on a light menu bar**: the menu bar's usage colours come
  from the dropdown's palette, a darker shade on a light bar, every one at least 4.5:1 contrast.
- #20 **Usage colours by how close you are to running out**: the 5-hour session is green under
  40%, orange to 79%, red from 80%; a weekly limit is orange when it won't last until its reset,
  red a day or more early, and never coloured before its forecast shows.
- #34 **Say when a reading is old** (a bug): Claude's server paused cswap's usage checks for an
  hour and the app showed the last reading as current. A reading over 10 minutes old now dims in
  the menu bar and the dropdown says when it last checked.
- #68 **Session colour follows the forecast**: a session on track to last until its reset is
  green (44%, on track for 64%), orange when it will run out first, red from 80%.
- #30 **A forecast that means something**: "runs out tomorrow" only from the pace you're
  actually using it at, nothing for an account you haven't used in days; or no forecast, only
  over or under pace.
- #48 **Keep the tooling and the plan in order**, a standing item: product-kit's tools kept
  current (each update is a step of it), local CI, and the board and these pages saying the
  same, which the plan itself (#35) started on 13 Nov.
