# DiskTree

DiskTree is a native macOS utility for finding what is using your disk space. It
combines a sortable folder outline with an interactive treemap, updates while a
scan is running, and keeps local scan history.

There is no account, subscription, or analytics. Scan data stays on your Mac; the
only network request is an optional daily update check.

## Features

- Scans a folder, your home directory, or an entire disk
- Shows allocated-on-disk sizes in a tree and nested treemap
- Streams partial results during large scans
- Reveals selected files and folders in Finder
- Re-scans individual folders and charts interactive drill-down scan history
- Configures treemap and history recursion depth in Settings
- Optionally scans the startup disk every Monday morning in the background
- Avoids following symbolic links and duplicate directory inodes
- Restores the latest scan on launch

## Requirements

- macOS 14 Sonoma or newer
- Xcode 26 or its Command Line Tools (Swift 6 language mode)

Release builds are Universal 2 and run natively on Apple silicon and Intel Macs.

## Build and run

```bash
./build.sh
open DiskTree.app
```

The build is ad-hoc signed when no Apple signing identity is installed. To also
replace your development copy in `/Applications`:

```bash
DISKTREE_INSTALL=1 ./build.sh
```

To build only one architecture:

```bash
DISKTREE_ARCHS=arm64 ./build.sh
```

Run all local checks with:

```bash
./check.sh
```

## History charts

Double-click a folder in the outline, or choose **Show History** from a folder's
context menu, to chart how its contents changed across archived scans. Click a
colored directory band or its legend entry to drill into that folder; use the
breadcrumb or back button to return.

The chart reads the small history index first, fixing the complete date range on
the X-axis. It then loads archived snapshots newest-to-oldest and updates the
colored areas after each snapshot, with progress shown at the bottom of the
sheet. This keeps the chart responsive even when individual scan archives are
large.

Use **DiskTree → Settings…** to change the nested treemap depth (default 5) and
history folder depth (default 2). Both settings persist between launches.

## Automatic weekly scans

Enable **Scan the startup disk weekly** in **DiskTree → Settings…** to register
DiskTree's bundled background helper. macOS runs it every Monday at 08:00. If
the Mac is asleep, the scan starts after it wakes; if it is powered off, that
week's occurrence is skipped.

The helper scans `/` and uses the same device-ID confinement as manual scans, so
it never descends into external mounted volumes. It requires Full Disk Access
and may also need approval under **System Settings → General → Login Items &
Extensions**. Settings shows the latest automatic scan result.

DiskTree uses an embedded, signed LaunchAgent registered through `SMAppService`.
Manual and automatic scans share a cross-process lock and cannot run at the same
time. Headless scans skip the expensive progressive UI snapshots used by the
foreground app.

## Full Disk Access

macOS protects parts of the disk. For a complete scan, add the built or installed
`DiskTree.app` in:

> System Settings → Privacy & Security → Full Disk Access

Without Full Disk Access, DiskTree still scans locations macOS allows it to read.
The app never attempts to bypass macOS permissions.

### After an update

macOS ties the grant to the code signature that was approved. Notarized releases
are all signed with the same Developer ID, so updating keeps Full Disk Access. A
copy signed differently (an ad-hoc, Apple Development, or third-party build) does
not inherit it, even though System Settings still shows the switch on.

DiskTree detects this: it remembers the signature that last had access, and if a
later copy is refused it shows **Approve DiskTree for Full Disk Access again**.
**Reset & Open Settings** removes the outdated entry (`tccutil reset
SystemPolicyAllFiles com.libjch.disktree`); then add `DiskTree.app` with “+”, turn
it on, and relaunch. If the entry remains, remove it with “−” first.

To see what the running copy sees:

```bash
/Applications/DiskTree.app/Contents/MacOS/DiskTree --check-full-disk-access
```

## Updates

Once a day at launch, DiskTree downloads a small JSON file from
`www.libjch.com` and compares its version with the installed one. If a newer
release exists it offers **Download** (opens the notarized DMG in your browser),
**Later**, or **Skip This Version**. Nothing is installed automatically. Use
**DiskTree → Check for Updates…** at any time, or turn the automatic check off in
Settings → Updates. The request contains no identifiers or usage data.

## How sizes are calculated

DiskTree uses allocated-on-disk bytes (`totalFileAllocatedSize`), which represents
the space normally reclaimed by deleting a file. Symbolic links are not followed.
Directories already visited through the same device and inode are not traversed
again.

## Privacy and safety

- DiskTree has no telemetry. Its only network request is the optional daily
  update check described above.
- Scan results and history are stored under the user's Application Support
  directory.
- DiskTree is read-only: it does not delete, move, or modify scanned items.

## Project layout

| Path | Purpose |
| --- | --- |
| `Sources/Scanner.swift` | Parallel filesystem scanner and UI state |
| `Sources/ScanStore.swift` | Compressed scan persistence and history |
| `Sources/FileNode.swift` | Tree model |
| `Sources/Treemap.swift` | Treemap layout, rendering, and colors |
| `Sources/ContentView.swift` | Main window and user actions |
| `Sources/HistoryChart.swift` | Historical size chart |
| `Sources/AppSettings.swift` | Persisted visualization settings |
| `Sources/WeeklyScanScheduler.swift` | Background-helper registration and status |
| `Helper/ScheduledScanMain.swift` | Headless weekly scanner entry point |
| `Sources/FullDiskAccess.swift` | Permission detection and guidance |
| `Sources/UpdateChecker.swift` | Optional update check against the website feed |
| `build.sh` | Strict Universal 2 build |
| `notarize.sh` | Developer ID signing and Apple notarization |
| `check.sh` | Local CI-equivalent checks |

## Notarized releases

Direct-download releases require an Apple Developer membership, a Developer ID
Application certificate in the login keychain, and an app-specific password.
Contributors do not need these to build the app.

Store notarization credentials once:

```bash
xcrun notarytool store-credentials "DiskTree" \
  --apple-id "YOUR_APPLE_ID" \
  --team-id "YOUR_TEAM_ID" \
  --password "YOUR_APP_SPECIFIC_PASSWORD"
```

Then create a signed, notarized, stapled, and Gatekeeper-verified `DiskTree.dmg`.
The image contains the app and an Applications shortcut for drag-to-install:

```bash
./notarize.sh
```

Optional release environment variables:

| Variable | Purpose | Default |
| --- | --- | --- |
| `DISKTREE_NOTARY_PROFILE` | Keychain profile passed to `notarytool` | `DiskTree` |
| `DISKTREE_SIGNING_IDENTITY` | Exact Developer ID identity | First matching identity |
| `DISKTREE_SITE_DOWNLOADS` | Directory that receives the DMG and update feed | No copy |
| `DISKTREE_DOWNLOAD_URL` | DMG URL written to the update feed | `https://www.libjch.com/downloads/DiskTree.dmg` |
| `DISKTREE_RELEASE_NOTES` | Notes shown in the update dialog | Empty |

To release an update, bump `CFBundleShortVersionString` and `CFBundleVersion` in
`Info.plist`, run `./notarize.sh`, then upload `DiskTree.dmg` **before**
`disktree-version.json`. The app reads the feed from the `DiskTreeUpdateFeedURL`
key in `Info.plist`, and it only follows HTTPS download links on the feed's own
host.

Never commit certificates, private keys, app-specific passwords, or exported
signing identities.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Bug reports and focused pull requests are
welcome.

## Security

Please report security-sensitive problems as described in
[SECURITY.md](SECURITY.md).

## Development data location

Scans and history live in `~/Library/Application Support/DiskTree/`. Set
`DISKTREE_DATA_DIR=/some/throwaway/path` to redirect all persistence elsewhere —
use this for tests so real history is never at risk.
