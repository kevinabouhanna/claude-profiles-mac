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

## Workflow: issue → pull request → merge → install

Nothing changes without all of these, in this order: open an issue, open a pull request that
closes it, merge it, check the issue is closed, and update the app on this Mac.

**Don't stop to ask before a routine step.** When something is requested, carry it all the way
through to the installed app: opening issues and pull requests, merging once CI is green,
closing issues and installing. Never wait to be told to open an issue or a pull request. Ask
first only for something high-risk:
- anything that can't be undone, such as deleting branches others use, rewriting history or
  force-pushing;
- a release (pushing a `v*` tag), and changing signing keys, certificates or repository secrets;
- anything that could lose the person's accounts, credentials, settings or history, or deleting
  files or data the request didn't ask for;
- a step that failed in a way you don't understand, or CI that keeps failing after a real
  attempt to fix it;
- a request whose intent is genuinely unclear.

Then explain what's at stake and ask.

1. **An issue.** Every change starts from an issue that says what and why (`gh issue create`).
   If none exists, open one first. Keep its description current: it is the record of what was
   decided.
2. **A pull request from a branch, attached to the issue.**
   - Name the branch after the issue, e.g. `reorder-accounts-12`.
   - Put `Closes #N` in the PR description, so merging closes the issue.
   - **Never push to `main` directly.**
3. **Merge it** once CI is green (`gh pr checks --watch`; fix it on the branch if it fails).
   Squash-merge and delete the branch (`gh pr merge --squash --delete-branch`), then pull `main`.
4. **Close the issue.** `Closes #N` does it on merge; check, and close it by hand if it's still
   open.
5. **Update the app on this Mac.** `./build.sh --install` from the updated `main`, so the
   installed app is what was merged.

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
