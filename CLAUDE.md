# Claude Profiles for Mac

A menu bar app (AppKit + SwiftUI, built with plain `swiftc` by `build.sh`, no Xcode project)
that shows Claude Code usage and switches accounts through the `cswap` CLI from
[claude-swap](https://github.com/realiti4/claude-swap). It never touches credentials itself.

## Rules

A menu bar app runs all day on battery, so its worst bug is quietly burning energy. Once,
redrawing the menu bar item made the button report a change, which redrew it again,
forever: a CPU core at 100%. These rules exist so nothing like that ships again.

1. **Redraws go through `StatusController.requestRedraw()`, never `redraw()` directly.** It
   merges requests, spaces them at least 0.25 s apart, and `redraw()` skips a picture
   identical to the last one. Anything new the image depends on goes into its key.
2. **Don't observe something the reaction changes.** A KVO, Combine or notification handler
   that updates the object it watches is a loop. If unavoidable, guard it with a
   did-anything-change check, as `redraw()` does.
3. **Make formatters, regexes and other costly objects once**, never per call in a hot path.
4. **Every repeating timer gets a tolerance** so macOS can batch wakeups.
5. **At most one `cswap auto` child, and no other child outlives its call.** `CLI.run` waits
   for its process and kills it after its timeout (60 s by default); `AutoSwitcher` owns the
   only long-lived one.
6. **Nothing polls faster than the user's refresh interval** (30 s minimum).
7. **`EnergyGuard` stays on.** It's the safety net if 1–6 fail in the field: sustained CPU
   over 20% throttles redraws, logs a fault under the `com.kevinabouhanna.ClaudeProfiles`
   subsystem, and asks the user to report it.

## Workflow

Work autonomously. Every request that changes the repo goes through an issue and a pull request,
merged without asking:

1. **Open an issue** describing the request (`gh issue create`).
2. **Branch from `main`, commit, and open a pull request** whose body says `Closes #<issue>`, so
   it's linked to the issue and closes it on merge.
3. **Wait for CI to pass** (`gh pr checks --watch`). If it fails, fix it on the branch.
4. **Squash-merge it and delete the branch** (`gh pr merge --squash --delete-branch`), then pull
   `main`. Don't ask first.

Stop and ask only when something is critical: a release (pushing a `v*` tag), anything
destructive or hard to undo (force-pushing, rewriting history, deleting branches other than the
merged one, deleting files or data the request didn't ask for), secrets or signing, CI that keeps
failing after a real attempt to fix it, or a request whose intent is genuinely unclear. Then
explain what's at stake and ask whether to push.

## Checking a change

- `./build.sh --install` builds and installs it.
- `./scripts/energy-test.sh` must pass. It runs its own copy with `-energyTest YES`, which
  leaves the installed copy's Auto-Switch process alone, so it's safe alongside it. If you
  touch the menu bar, dropdown, refresh or Auto-Switch code, check it also fails on a
  deliberately broken build: it should, loudly.
- `--selftest <cswap list --json output>` checks the logic. It needs cswap and claude installed.
- Test commands (`scripts/energy-test.sh` shows how) go to
  `com.kevinabouhanna.ClaudeProfiles.test.<pid>`, which only that process answers.

## Releasing

1. CI is green on `main`, energy test included.
2. Run the installed app for 10 minutes while switching light/dark, opening the dropdown
   and Settings, and switching accounts, with Activity Monitor's Energy tab open. The app
   should sit near 0 and never appear under the Battery menu's "Using Significant Energy".
   This catches what the script can't reproduce: an auto-hidden menu bar, several
   displays, sleep and wake.
3. `git tag vX.Y.Z && git push origin vX.Y.Z`. The release workflow reruns the energy test,
   then signs, notarizes and publishes. It refuses to publish if anything fails.
