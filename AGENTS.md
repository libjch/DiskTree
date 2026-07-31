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
| `ContentView.swift` | Main window: toolbar, outline, treemap host, actions, disk picker, history sheet |
| `Scanner.swift` | Parallel scan engine (worker pool). Inode dedup + single-volume confinement. |
| `ScanStore.swift` | Persistence + append-only history archive (custom binary format, LZFSE). `folderHistory()` for the chart. |
| `FileNode.swift` | Tree model (path-based identity) + byte formatting |
| `Treemap.swift` | Nested squarified treemap + `NodePalette` (shared colors), `TreemapLayout.maxDepth` |
| `HistoryChart.swift` | Stacked-area history chart (Swift Charts) |
| `FullDiskAccess.swift` | FDA detection + guidance |

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

## Handy test env vars
- `DISKTREE_DATA_DIR` — redirect all persistence (see rule 2).
- `DISKTREE_INSTALL=1` — copy build to /Applications.
- `notarize.sh`: `DISKTREE_NOTARY_PROFILE`, `DISKTREE_SIGNING_IDENTITY`, `DISKTREE_SITE_DOWNLOADS`.

## Current working-tree state (uncommitted, on `main`)
These 6 files have unstaged edits from the latest session, **not yet committed**:
`ContentView.swift`, `Scanner.swift`, `ScanStore.swift`, `Treemap.swift`,
`HistoryChart.swift`, `README.md`. They add, since the last commit
(`0eaa891 Distribute DiskTree as a notarized DMG`):
- Nested treemap (4 layers) + shared hierarchical palette (`NodePalette`).
- Scan persistence + append-only history; **folder-scoped** stacked-area history
  chart (double-click an outline folder, or right-click → "Show History").
- Consolidated toolbar (Scan Disk / Choose Folder / Refresh / History; Reveal +
  Trash on the right).
- Single-volume scan confinement + a **disk picker** when multiple volumes are
  mounted.
- `DISKTREE_DATA_DIR` safety override.

Consider committing before large new work so changes are isolated.

## Next planned task (requested, not started)
1. **Interactive drill-down inside the "Show History" popup** — let the user click
   a folder / colored band / legend entry in `HistoryChartView` to re-scope the
   chart to that folder without closing it (add breadcrumb/back). Data is ready via
   `ScanStore.folderHistory(rootPath:folderPath:)`.
2. **Settings menu for recursion depth** (persist in UserDefaults):
   - Treemap depth — currently hard-coded `TreemapLayout.maxDepth = 4`; make
     configurable (user wants default ~5).
   - History chart depth — currently only the folder's **direct children** (1
     level); make configurable, default 2.
