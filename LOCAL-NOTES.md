# Local Notes — grmrobertson fork

Fork-only notes; not for upstream PRs.

## Current State (2026-09-30)

- **Installed app:** public stable release **v0.7.12** (notarised, Developer ID: SUNSTORY LLC), bundle id `com.robinebers.openusage`. Sparkle auto-update is active — no manual redeploy needed.
- **Custom build retired.** Backup of the last custom `.app` left in `$TMPDIR` (`OpenUsage-custom.app.bak-*`); disposable.
- **Archived** on fork branch `origin/archive/claude-multi-account-desktop` (grmrobertson/openusage):
  - fix: scan all Claude account subdirectories to discover multiple accounts
  - this notes file
  - Based on `upstream/main` @ `2d2eabe5`. Local `main` reset to a clean upstream mirror.
- To revive: `git fetch origin && git switch -c multi-account origin/archive/claude-multi-account-desktop && git rebase upstream/main`.
- Task: OPE-2 (in review).

## What the Fork Commit Does

- `discoverDesktopOrganizations()` (`Sources/OpenUsage/Services/ProviderAccountAssembly.swift`) scans every account UUID folder under Claude Desktop's `claude-code-sessions/` and `local-agent-mode-sessions/`, not just `lastKnownAccountUUID`. Upstream still only scans the last-known account, so a second Desktop account gets no card.
- Pins KeyboardShortcuts to 2.x — only needed when building with Command Line Tools; unnecessary with full Xcode.
- Regression test: `testMultipleDesktopAccountsAreEachDiscovered` (made `async` because upstream made `ProviderAccountAssembly.make` async).
- Candidate for an upstream PR if multi-account Desktop support is needed again.

## Multi-Account Alternative: Claude Swap

- Upstream (v0.7.13-beta+) discovers accounts saved by Claude Swap in `~/.claude-swap-backup/sequence.json` — one card per saved account.
- Installed: `uv tool install claude-swap` (v0.26.0, `cswap`). No accounts added yet.
- Setup: log in with `claude`, then `cswap add`; repeat per account; `cswap list`; restart OpenUsage. Stale card → `cswap run <email>`, then refresh.
- Swap support isn't in stable v0.7.12 — needs the beta update channel or the next stable release.
- Don't mix `cswap` switching with `clauth` profiles (`claude-personal`); both change the active login.
- OpenUsage does not read `~/.claude-personal` or clauth profiles as separate accounts.

## Rebuilding a Custom Build (If Needed Again)

```sh
git fetch upstream && git rebase upstream/main
export DEVELOPER_DIR=/Applications/Xcode-27.0.0.app/Contents/Developer   # xcode-select points at CLT; avoids sudo
BUNDLE_ID=com.robinebers.openusage ./script/build_and_run.sh build
pkill -x OpenUsage; sleep 1
mv /Applications/OpenUsage.app "$TMPDIR/OpenUsage.app.bak-$(date +%s)"
ditto dist/OpenUsage.app /Applications/OpenUsage.app
open /Applications/OpenUsage.app
```

- The Xcode beta path in older notes (`Xcode-27.0.0-Beta.6.app`) no longer exists.
- Custom builds have no Sparkle feed (no auto-update) and no iCloud Sync (no provisioning profile).
- Switching between public and custom builds keeps settings (same bundle id) but may trigger a one-time keychain prompt (different signing identity).
