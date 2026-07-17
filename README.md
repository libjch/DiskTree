# DiskTree

DiskTree is a native macOS utility for finding what is using your disk space. It
combines a sortable folder outline with an interactive treemap, updates while a
scan is running, and keeps local scan history.

There is no account, subscription, analytics, or network service. Scan data stays
on your Mac.

## Features

- Scans a folder, your home directory, or an entire disk
- Shows allocated-on-disk sizes in a tree and nested treemap
- Streams partial results during large scans
- Reveals files in Finder and moves selected descendants to the Trash
- Re-scans individual folders and charts scan history
- Avoids following symbolic links and duplicate directory inodes
- Restores the latest scan on launch

## Requirements

- macOS 14 Sonoma or newer
- Xcode Command Line Tools or Xcode with the macOS SDK

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

## Full Disk Access

macOS protects parts of the disk. For a complete scan, add the built or installed
`DiskTree.app` in:

> System Settings → Privacy & Security → Full Disk Access

Without Full Disk Access, DiskTree still scans locations macOS allows it to read.
The app never attempts to bypass macOS permissions.

## How sizes are calculated

DiskTree uses allocated-on-disk bytes (`totalFileAllocatedSize`), which represents
the space normally reclaimed by deleting a file. Symbolic links are not followed.
Directories already visited through the same device and inode are not traversed
again.

## Privacy and safety

- DiskTree has no telemetry and makes no network requests.
- Scan results and history are stored under the user's Application Support
  directory.
- Moving an item to the Trash always requires confirmation.
- The root selected for a scan cannot be moved to the Trash from DiskTree.

## Project layout

| Path | Purpose |
| --- | --- |
| `Sources/Scanner.swift` | Parallel filesystem scanner and UI state |
| `Sources/ScanStore.swift` | Compressed scan persistence and history |
| `Sources/FileNode.swift` | Tree model |
| `Sources/Treemap.swift` | Treemap layout, rendering, and colors |
| `Sources/ContentView.swift` | Main window and user actions |
| `Sources/HistoryChart.swift` | Historical size chart |
| `Sources/FullDiskAccess.swift` | Permission detection and guidance |
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

Then create a signed, notarized, stapled, and Gatekeeper-verified `DiskTree.zip`:

```bash
./notarize.sh
```

Optional release environment variables:

| Variable | Purpose | Default |
| --- | --- | --- |
| `DISKTREE_NOTARY_PROFILE` | Keychain profile passed to `notarytool` | `DiskTree` |
| `DISKTREE_SIGNING_IDENTITY` | Exact Developer ID identity | First matching identity |
| `DISKTREE_SITE_DOWNLOADS` | Directory that receives a copy of the ZIP | No copy |

Never commit certificates, private keys, app-specific passwords, or exported
signing identities.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Bug reports and focused pull requests are
welcome.

## Security

Please report security-sensitive problems as described in
[SECURITY.md](SECURITY.md).
