# AGENTS.md — DiskTree

Handoff notes for AI agents (Codex, Claude, etc.) working on this repo.

## What this is
DiskTree is a native macOS (SwiftUI) disk-space visualizer: a parallel filesystem
scanner with an outline tree + nested treemap, scan persistence/history, and a
stacked-area history chart. Distributed as a **notarized DMG** from the author's
site (www.libjch.com), **not** the Mac App Store — the App Store sandbox forbids
whole-disk (`/`) scanning, which is the headline feature.

## Build / run / test — no Xcode project
This builds with a **plain `swiftc` script**, not an `.xcodeproj`.

- `./build.sh` — compile `DiskTree.app` (strict concurrency, Universal 2).
- `DISKTREE_INSTALL=1 ./build.sh` — also copy the app to `/Applications`.
- `./check.sh` — CI-equivalent: shell lint, plist lint, build, codesign verify.
- `./notarize.sh` — release: sign (Developer ID + hardened runtime), notarize,
  staple → `DiskTree.dmg`. Needs a Developer ID cert + `notarytool` keychain
  profile "DiskTree" (see README "Notarized releases").
- Run: `open DiskTree.app` (or `open /Applications/DiskTree.app`).

## Source layout (`Sources/`)
| File | Responsibility |
|---|---|
| `App.swift` | App entry point |
| `AppSettings.swift` | Persisted treemap/history depth settings + Settings UI |
| `WeeklyScanScheduler.swift` | `SMAppService` registration/status for weekly scans |
| `ContentView.swift` | Main window: toolbar, outline, treemap host, actions, disk picker, history sheet |
| `Scanner.swift` | Parallel scan engine (worker pool). Inode dedup + single-volume confinement. |
| `ScanStore.swift` | Persistence + append-only history archive (custom binary format, LZFSE). Per-snapshot history loading for progressive charts. |
| `FileNode.swift` | Tree model (path-based identity) + byte formatting |
| `Treemap.swift` | Nested squarified treemap + `NodePalette` (shared colors); depth comes from `AppSettings`. |
| `HistoryChart.swift` | Progressive stacked-area history chart, drill-down, breadcrumb/back navigation |
| `FullDiskAccess.swift` | FDA guidance, stale-grant detection/reset, diagnostics |
| `UpdateChecker.swift` | Daily/manual update check against the website JSON feed |
| `DiskAccess.swift` | Foundation-only FDA probe shared with the helper |
| `ScanExecutionLock.swift` | Cross-process exclusion for GUI/helper scans |

The headless helper entry point is `Helper/ScheduledScanMain.swift`; its launchd
plist is `Resources/com.libjch.disktree.weekly-scan.plist`. `build.sh` creates and
signs it at `DiskTree.app/Contents/Helpers/DiskTreeWeeklyScan`.

## CRITICAL RULES — read before running anything
1. **Never delete or clear `~/Library/Application Support/DiskTree/`** (or its
   `history/`). That is the user's real, **un-backed-up** scan history (no Time
   Machine / snapshots on this Mac). It was wiped twice by careless test cleanup —
   do not repeat.
2. **For any test/dev run that scans or archives, set `DISKTREE_DATA_DIR` to a
   throwaway path** (e.g. `DISKTREE_DATA_DIR=/tmp/dt-test ./DiskTree.app/Contents/MacOS/DiskTree`).
   ScanStore honors it, so persistence never lands in the real directory. Clean up
   the throwaway dir, never the real one.
3. **SwiftUI hit-testing can't be driven by synthetic events** (System Events
   clicks/hover, `cliclick`). Verify logic deterministically (CLI harnesses,
   device IDs, decode round-trips) and ask the user to confirm actual
   clicks/hover/right-click/double-click interactions.
4. Never commit certs/keys (`.cer/.p12/.provisionprofile` are gitignored).
5. The scheduled helper normally scans `/`. For deterministic testing, set both
   `DISKTREE_DATA_DIR` and `DISKTREE_SCHEDULED_SCAN_ROOT` to throwaway paths.

## Handy test env vars
- `DISKTREE_DATA_DIR` — redirect all persistence (see rule 2).
- `DISKTREE_INSTALL=1` — copy build to /Applications.
- `DISKTREE_SCHEDULED_SCAN_ROOT` — helper test root; honored only when
  `DISKTREE_DATA_DIR` is also set.
- `notarize.sh`: `DISKTREE_NOTARY_PROFILE`, `DISKTREE_SIGNING_IDENTITY`, `DISKTREE_SITE_DOWNLOADS`,
  `DISKTREE_DOWNLOAD_URL`, `DISKTREE_RELEASE_NOTES`.
- `--check-full-disk-access` — prints FDA probe results and the code signature
  vs. the last signature that had access. **Launch it via `open -n -W --stdout
  FILE … --args --check-full-disk-access`**: run directly from a terminal (or a
  Claude session), TCC checks the terminal's grant, not DiskTree's.
- `--check-for-updates` — headless update check (same fetch/validation as the
  app). `DISKTREE_UPDATE_FEED_URL` overrides the feed URL for testing.
- Mac verification runbook for agents: `docs/MAC_RUNBOOK.md`.

## Current implementation notes
- History sheets support in-place drill-down through directory bands and a
  clickable legend, plus breadcrumb/back navigation.
- History loading is progressive: read the index first to fix all X-axis dates,
  then decode archives newest-to-oldest and update after every snapshot.
- Category identity uses absolute paths, preventing same-named folders from
  merging; colors remain stable while older snapshots arrive.
- Visualization depths persist in UserDefaults. Defaults: treemap 5, history 2.
- `ScanStore.folderHistorySample(entry:folderPath:depth:)` is the per-archive API
  used by the progressive loader. Keep archive decoding off the main actor.
- Weekly automatic scans use a bundled LaunchAgent registered by the user in
  Settings. Schedule: Monday 08:00; target: startup volume `/`; external volumes
  are excluded by `ScanEngine`'s device-ID confinement.
- The helper must finish synchronous persistence before exiting. Keep its nested
  signing step before the outer app signing in both `build.sh` and `notarize.sh`.
- `ScanEngine.maybeSnapshotLocked()` must return immediately when `onProgress` is
  nil. The helper has no UI consumer; deep-copying a multi-million-node tree every
  two seconds made the first scheduled scan run for more than a day.
- FDA detection (`DiskAccess`) probes several FDA-only paths; only `EPERM` counts
  as denial. `FullDiskAccess` stores the designated requirement that last had
  access (`fullDiskAccessGrantedRequirement`) and, on denial with a different
  signature, offers `tccutil reset SystemPolicyAllFiles` + re-add guidance.
- `build.sh` prefers the Developer ID identity so dev builds match releases;
  mixing signatures voids the user's FDA grant while the switch stays on.
- `UpdateChecker` reads `DiskTreeUpdateFeedURL` (Info.plist) at most daily, after
  the FDA dialog. `notarize.sh` writes `disktree-version.json`. Download links
  must be HTTPS on the feed's host; the app never installs anything itself.
