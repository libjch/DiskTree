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
| `ScanStore.swift` | Persistence + append-only history archive (custom binary format, LZFSE). Writes/reads `.dtsum` summaries; streaming prune-decoder for migration. |
| `BinaryCoding.swift` | Shared little-endian primitives. `ByteReader` borrows the decoded buffer (no per-field allocation). |
| `HistorySummary.swift` | Compact `.dtsum` snapshot format (flat, Sendable) + category slicing |
| `HistorySummaryStore.swift` | In-memory summary cache + one-time background migration |
| `HistoryBackup.swift` | One-shot clone of `history/` before anything new is written there |
| `FileNode.swift` | Tree model (path-based identity) + byte formatting |
| `Treemap.swift` | Nested squarified treemap + `NodePalette` (shared colors); depth comes from `AppSettings`. |
| `HistoryChart.swift` | Progressive stacked-area history chart, drill-down, breadcrumb/back navigation |
| `FullDiskAccess.swift` | FDA detection + guidance |
| `DiskAccess.swift` | Foundation-only FDA probe shared with the helper |
| `ScanExecutionLock.swift` | Cross-process exclusion for GUI/helper scans |

New non-UI sources must be added to the helper's explicit file list in
`build.sh`, not just to the `Sources/*.swift` glob the app uses.

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
- `notarize.sh`: `DISKTREE_NOTARY_PROFILE`, `DISKTREE_SIGNING_IDENTITY`, `DISKTREE_SITE_DOWNLOADS`.

## Current implementation notes
- History sheets support in-place drill-down through directory bands and a
  clickable legend, plus breadcrumb/back navigation.
- **History never decodes `.dtscan` archives.** Each archived scan has a coarse
  summary in `history/summaries/<archive>.dtsum` (LZFSE, "DTM1"): nodes down to
  `max(rootSize / 10_000, 1 MB)`, at most 64 children per directory and 12
  levels deep. On the author's `/` scans that is ~5,000 nodes and ~45 KB per
  snapshot, versus 20–42 MB and 4.2 M nodes for the archive.
- The summary is a flat, breadth-first `[SummaryNode]` (name, size, isDirectory,
  firstChild, childCount) — value types, `Sendable`, no path strings. Absolute
  paths are rebuilt while slicing, so category identity stays path-based.
- Pruned bytes are not lost: `HistorySummary.categories` adds
  `folder.size - sum(kept children)` to the "Other" band, so the stack still
  sums exactly to the folder's size. Verified against full decodes: the named
  top bands and the totals are byte-identical; only "Other" differs.
- Summaries are written at archive time in **both** `ScanStore.archive()` and
  `saveAndArchiveSynchronously()` (the helper writes its summary before exiting).
  `index.json` and the `.dtscan` format are unchanged, and archives are only
  ever read.
- Archives written before summaries existed are migrated once, in the
  background, by a streaming prune-decoder (`ScanStore.summary(fromArchive:)`):
  one pass over the decompressed bytes with no `FileNode`, no path strings and
  no allocation for the subtrees it skips (a subtree below the threshold can be
  skipped wholesale, since a child is never larger than its parent). ~0.2 s per
  archive; `.dtsum` files are written atomically. `HistorySummaryStore` caches
  the results and de-duplicates concurrent builds.
- `HistoryChartView` loads every summary **once** per sheet (bounded-concurrency
  TaskGroup, newest first) and keeps them in memory. Drill-down, back,
  breadcrumb and depth changes only re-slice in memory — under 1 ms, no disk
  I/O. Categories, colors, point IDs and the thinned X axis are precomputed into
  one `ChartData` value, not recomputed per `body`.
- A folder missing from a snapshot's summary contributes no point; a folder
  missing from all of them shows "Too small to be tracked in history".
- **Automatic history backup.** `HistoryBackup.ensureBackup` clones `history/`
  (archives + index) to `DiskTree Backups/history-<timestamp>/` *next to* the
  data directory before anything new is written there — new archives and the
  summary migration both call it. `FileManager.copyItem` clones on APFS, so it
  is instant and free. A `.history-backup-v<N>` marker makes it run once per
  migration version; backups are never deleted automatically. Honors
  `DISKTREE_DATA_DIR` (backups land next to the override).
- `ScanStore`'s tree decoder borrows the decompressed buffer via
  `withUnsafeBytes`/`ByteReader` instead of copying it into `[UInt8]` and
  allocating an array per field: decoding a 4.2 M-node `/` archive went from
  ~5.4–7.4 s to ~1.85 s, which also speeds up launch (`lastScan.dtscan`).
- `ScanStore.folderHistorySample(entry:folderPath:depth:)` still exists as the
  exact, full-decode reference the summaries are verified against (seconds per
  call — never on the main thread). It is no longer on any UI path.
- History loading is progressive: read the index first to fix all X-axis dates,
  then load summaries newest-to-oldest and update after every snapshot.
- Category identity uses absolute paths, preventing same-named folders from
  merging; colors remain stable while older snapshots arrive.
- Visualization depths persist in UserDefaults. Defaults: treemap 5, history 2.
- Weekly automatic scans use a bundled LaunchAgent registered by the user in
  Settings. Schedule: Monday 08:00; target: startup volume `/`; external volumes
  are excluded by `ScanEngine`'s device-ID confinement.
- The helper must finish synchronous persistence before exiting. Keep its nested
  signing step before the outer app signing in both `build.sh` and `notarize.sh`.
- `ScanEngine.maybeSnapshotLocked()` must return immediately when `onProgress` is
  nil. The helper has no UI consumer; deep-copying a multi-million-node tree every
  two seconds made the first scheduled scan run for more than a day.
