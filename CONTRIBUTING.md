# Contributing to DiskTree

Thanks for helping improve DiskTree.

## Before opening a pull request

1. Keep changes focused and explain the user-visible behavior.
2. Run `./check.sh` on macOS 14 or newer.
3. Test scanning a small temporary folder before scanning a large disk.
4. Do not commit generated app bundles, ZIP files, credentials, certificates, or
   scan data.

The project intentionally uses a small shell-based build instead of an Xcode
project. New dependencies should have a clear benefit and must not introduce
telemetry or require network access at runtime.

## Code expectations

- Preserve strict Swift concurrency checking.
- Keep filesystem work off the main actor where practical.
- Treat file deletion, replacement, and permission changes as safety-sensitive.
- Maintain compatibility with both Apple silicon and Intel Macs.
- Add comments for non-obvious synchronization and binary-format assumptions.

## Reporting bugs

Include:

- macOS and Mac architecture
- The folder type being scanned (home, external drive, root disk, and so on)
- Steps to reproduce
- Relevant console or terminal output

Do not attach scan-history files if their paths or filenames contain private
information.
