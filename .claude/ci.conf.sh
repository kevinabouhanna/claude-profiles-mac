# .claude/ci.conf.sh: Claude Profiles' CI for `local-ci <pr>` (shared-mac). Pull requests run on
# this Mac. Jobs run in a checkout of the commit.

CI_JOBS=(build plan)    # the check names, one per job

# The app builds (plain swiftc, no Xcode project) with both architectures, and every image the
# README uses is listed (the vendored shots-kit), as GitHub's ci.yml does. The energy test opens
# the app's windows, so it stays on GitHub's runner, never this Mac's screen.
ci_job_build() {
  ./build.sh &&
    lipo -archs "build/Claude Profiles.app/Contents/MacOS/ClaudeProfiles" &&
    swiftc -O -parse-as-library scripts/shots-kit.swift scripts/AccessibilityAudit.swift -o build/shots-kit &&
    build/shots-kit coverage
}

# The plan's pages agree with GitHub's issues, milestones and board (#35).
ci_job_plan() {
  if gh auth status --hostname github.com --active >/dev/null 2>&1; then
    python3 -I scripts/docs-kit plan check
  else
    echo "plan: skipped, because gh isn't signed in to GitHub here, so the plan can't be read"
  fi
}
