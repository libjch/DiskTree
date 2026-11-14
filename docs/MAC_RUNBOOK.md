# Mac runbook: verify Full Disk Access handling and the update check

Instructions for an AI agent (Claude Code, Codex, …) running **on the
maintainer's Mac** in this repository. These features were written in a Linux
cloud session that could compile through CI but never run the app. Your job is
to run everything below for real, fix what breaks, and report back.

Start the session with:

> Follow `docs/MAC_RUNBOOK.md` step by step. Ask me before each step marked 🙋.

## Ground rules (read first)

- Obey every rule in `AGENTS.md`. In particular, **never delete, move or clear
  `~/Library/Application Support/DiskTree/`**. It holds un-backed-up scan history.
  None of the steps below need to scan; if you scan anything, set
  `DISKTREE_DATA_DIR=/tmp/dt-test`.
- You cannot click SwiftUI or AppKit UI with synthetic events. Steps marked 🙋 need
  the user: say exactly what they should click or look at, then wait.
- **Never run the app executable directly from your shell to check Full Disk
  Access.** macOS checks the permission of the *responsible* process, which is
  your terminal or Claude app, and that already has Full Disk Access. Always use
  the `open` form in step 3: it launches DiskTree as its own process. The report
  prints a WARNING if it was started from a terminal.
- Outward-facing actions need explicit permission from the user first: `tccutil
  reset` (it removes the user's Full Disk Access entry), uploading anything to
  www.libjch.com, running `./notarize.sh` (it submits to Apple), pushing, and
  opening PRs.
- Work on branch `claude/new-session-a837i8` (or the branch the user names).
  Commit fixes there with clear messages.

Keep notes as you go. The results table in step 9 is the deliverable.

## 1. Get the code

```bash
git fetch origin claude/new-session-a837i8
```

```bash
git checkout claude/new-session-a837i8 && git pull
```

Files involved: `Sources/DiskAccess.swift` (probes), `Sources/FullDiskAccess.swift`
(dialogs, signature tracking, `tccutil` reset, diagnostics),
`Sources/UpdateChecker.swift`, `Sources/App.swift` (CLI flags, menu item),
`Sources/AppSettings.swift` (Updates section), `build.sh` (identity preference),
`notarize.sh` (feed generation), `Info.plist` (`DiskTreeUpdateFeedURL`).

## 2. Signing identities and the current install

```bash
security find-identity -v -p codesigning
```

Record which of `Developer ID Application` and `Apple Development` exist.
`build.sh` now prefers Developer ID, so dev builds have the same designated
requirement (DR) as notarized releases.

Record how the currently installed copy is signed, before rebuilding:

```bash
codesign -dr - /Applications/DiskTree.app 2>&1
```

```bash
codesign -dv /Applications/DiskTree.app 2>&1 | grep -E 'Authority|TeamIdentifier|Signature'
```

## 3. Full Disk Access diagnostic (helper command)

Use this exact form every time you need to know the state of Full Disk Access:

```bash
rm -f /tmp/disktree-fda.txt; open -n -W --stdout /tmp/disktree-fda.txt --stderr /tmp/disktree-fda.txt /Applications/DiskTree.app --args --check-full-disk-access; cat /tmp/disktree-fda.txt
```

On the old build (before step 4) the flag doesn't exist yet, so the app simply
opens a window. If so, quit it (`osascript -e 'quit app "DiskTree"'`) and move on.

Expected output on the new build:

```
DiskTree Full Disk Access check
Executable: /Applications/DiskTree.app/Contents/MacOS/DiskTree
Signature: identifier=com.libjch.disktree team=XXXXXXXXXX
Designated requirement: anchor apple generic and identifier "com.libjch.disktree" and …
Last copy with access: …
Probes:
  ~/Library/Application Support/com.apple.TCC/TCC.db: readable | denied (EPERM…) | …
  ~/Library/Safari: …
  ~/Library/Mail: …
  ~/Library/Messages: …
Full Disk Access: granted | denied | undetermined
```

Checks:
- No `WARNING: started from a terminal` line. If one appears, the `open` form
  didn't isolate the process; report it.
- With Full Disk Access on and valid, at least one probe is `readable` and the
  result is `granted`.
- With access off, the probes are `denied (EPERM…)` or `not present`. None should
  be `error …`; if one is, note the errno.
- Confirm that no macOS consent dialog appeared during the probe.

## 4. Build and install

```bash
./check.sh
```

It must end with `✓ All checks passed`, and the log must show `› Code signing
with: Developer ID Application: …` if that identity exists.

🙋 Installing quits a running `/Applications/DiskTree.app`. Tell the user, then:

```bash
DISKTREE_INSTALL=1 ./build.sh
```

```bash
codesign -dr - /Applications/DiskTree.app 2>&1
```

Compare this DR with the one recorded in step 2. A different DR (for example
Apple Development before, Developer ID now) explains the original bug: the
switch stays on in System Settings, but the grant doesn't apply.

Then run the step 3 diagnostic and record the result.

## 5. Restore Full Disk Access for the new build

Skip to step 6 if step 4's diagnostic says `granted`.

If it says `denied`, the grant is stale. This also tests the reset command,
which the app's **Reset & Open Settings** button runs. It is the main open
question: does it work without `sudo`?

🙋 Ask permission, then run it in your shell. It only removes DiskTree's own entry:

```bash
tccutil reset SystemPolicyAllFiles com.libjch.disktree; echo "exit=$?"
```

Record the output and exit status. Then 🙋 ask the user to:
1. Open System Settings → Privacy & Security → Full Disk Access and confirm
   whether DiskTree is **gone** from the list. If it's still there, remove it
   with "−".
2. Add `/Applications/DiskTree.app` with "+" and turn it on.

Run the step 3 diagnostic again: it must now say `granted`.

If `tccutil` fails without `sudo` (non-zero exit, or the entry stays listed),
the in-app button cannot work. Change `FullDiskAccess.promptStaleGrant` so that
it doesn't offer the reset: rename the button to "Open Settings" and lead with
the "remove with −, add with +" steps. Update the README "After an update"
section to match.

## 6. Signature tracking and the stale-grant dialog

1. 🙋 With access granted, ask the user to open DiskTree normally (`open
   /Applications/DiskTree.app`). No Full Disk Access dialog should appear. Quit it.
2. The launch must have recorded the current DR:

   ```bash
   defaults read com.libjch.disktree fullDiskAccessGrantedRequirement
   ```

   It must equal `codesign -dr -` output (the part after `designated => `).
3. Simulate a signature change without touching permissions:

   ```bash
   defaults write com.libjch.disktree fullDiskAccessGrantedRequirement 'identifier "simulated-old-build"'
   ```

   Run the step 3 diagnostic: it must print `Last copy with access had a
   DIFFERENT signature: identifier "simulated-old-build"` and still say `granted`.
4. Open DiskTree again. Because access is granted, there must be no dialog, and
   the stored value must be back to the real DR (repeat the `defaults read`).
5. 🙋 Dialog test (optional; it requires turning access off temporarily). Ask the
   user to turn DiskTree **off** in Full Disk Access. Write the fake value again
   (step 3), then ask them to open DiskTree. Expected: **"Approve DiskTree for
   Full Disk Access again"** with the "signed differently" wording and three
   buttons. Ask them to press **Open Settings** (not Reset), turn the switch back
   on, and relaunch. No dialog should appear.
6. Real-world variant (optional, only if the user agrees). An ad-hoc build
   reproduces the original bug exactly:

   ```bash
   DISKTREE_INSTALL=1 DISKTREE_ARCHS=arm64 bash -c 'security() { return 1; }; export -f security; ./build.sh'
   ```

   If that function override doesn't hide the identities, instead run
   `codesign --force --sign - /Applications/DiskTree.app/Contents/Helpers/DiskTreeWeeklyScan`
   and then `codesign --force --sign - /Applications/DiskTree.app`.
   🙋 Then ask the user to open DiskTree. Expected: the stale-grant dialog with
   the "signed differently" text. Ask them to press **Reset & Open Settings**,
   re-add the app with "+", and relaunch. Afterwards, restore the proper build
   with `DISKTREE_INSTALL=1 ./build.sh` and repeat step 5 (the ad-hoc DR voided
   the grant).

## 7. Update check

### 7a. Version file generation (no notarization)

`notarize.sh` builds the JSON with JavaScript for Automation. Test that snippet
alone, with notes that contain quotes and a newline:

```bash
osascript -l JavaScript - "1.2" "https://www.libjch.com/downloads/DiskTree.dmg" 'Fixes "stale" access
Second line' <<'JS' > /tmp/dt-feed.json
function run(argv) {
    return JSON.stringify({ version: argv[0], url: argv[1], notes: argv[2] }, null, 2);
}
JS
```

```bash
cat /tmp/dt-feed.json && python3 -m json.tool /tmp/dt-feed.json >/dev/null && plutil -convert xml1 -o /dev/null /tmp/dt-feed.json && echo valid
```


> `plutil -lint` is **not** a JSON validator — it rejects a perfectly valid JSON
> file with `Unexpected character { at line 1`. Use `python3 -m json.tool` (and
> `plutil -convert`, which does accept JSON) instead.

If `osascript -` doesn't read the script from stdin, fix `notarize.sh`, for
example by writing the script to a temp file.

### 7b. Command-line check against the real site

This flag doesn't depend on Full Disk Access, so running the executable directly
is fine here:

```bash
/Applications/DiskTree.app/Contents/MacOS/DiskTree --check-for-updates; echo "exit=$?"
```

Until the version file is published, expect `Result: check failed …` (HTTP 404)
and exit 1. Record what it says.

🙋 Ask the user where the DMG is actually served. The defaults assume
`https://www.libjch.com/downloads/DiskTree.dmg` and
`https://www.libjch.com/downloads/disktree-version.json`. If that's wrong,
update `DiskTreeUpdateFeedURL` in `Info.plist`, the `DOWNLOAD_URL` default in
`notarize.sh`, and the README table. The download link must be HTTPS on the same
host as the version file, or the app rejects it.

### 7c. End-to-end with a test file (🙋 needs upload permission)

Ask the user to publish a test file, for example
`https://www.libjch.com/downloads/disktree-version-test.json`:

```json
{ "version": "99.0", "url": "https://www.libjch.com/downloads/DiskTree.dmg", "notes": "Test release, please ignore." }
```

If the website is a local checkout (the user may point you to it; see
`DISKTREE_SITE_DOWNLOADS`), you may prepare the file there. Deploying it is the
user's call.

```bash
DISKTREE_UPDATE_FEED_URL=https://www.libjch.com/downloads/disktree-version-test.json /Applications/DiskTree.app/Contents/MacOS/DiskTree --check-for-updates; echo "exit=$?"
```

Expected: `Feed version: 99.0`, `Result: update available`, exit 0.

Negative checks: serve a test file whose `url` points at another host, or uses
`http://`. Expected: `check failed` (bad URL).

Dialog test: clear the throttle and skip state, then launch with the override.
`DISKTREE_DATA_DIR` keeps any accidental scan away from the real history:

```bash
defaults delete com.libjch.disktree lastUpdateCheck 2>/dev/null; defaults delete com.libjch.disktree skippedUpdateVersion 2>/dev/null; true
```

```bash
DISKTREE_DATA_DIR=/tmp/dt-test DISKTREE_UPDATE_FEED_URL=https://www.libjch.com/downloads/disktree-version-test.json /Applications/DiskTree.app/Contents/MacOS/DiskTree &
```

🙋 Ask the user to confirm each of the following:
- "DiskTree 99.0 is available" appears, with the notes, after the window opens
  (and after any Full Disk Access dialog, never on top of one).
- **Download** opens the DMG URL in the browser.
- Relaunch after clearing `lastUpdateCheck`, then press **Skip This Version**.
  `defaults read com.libjch.disktree skippedUpdateVersion` must print `99.0`.
  Relaunch after clearing `lastUpdateCheck` again: no dialog.
- **DiskTree → Check for Updates…** still shows the 99.0 dialog, without the
  Skip button, because a manual check ignores the skip.
- Relaunch without clearing `lastUpdateCheck`: no network check (within 24 h).
- Settings → Updates: the toggle off sets
  `defaults read com.libjch.disktree automaticallyCheckForUpdates` to `0`, and no
  automatic dialog appears afterwards. **Check Now** still works. Turn the toggle
  back on.
- Without the override, **Check for Updates…** shows "Couldn’t check for
  updates" (until the real file exists) or "DiskTree is up to date".

Clean up:

```bash
defaults delete com.libjch.disktree lastUpdateCheck 2>/dev/null; defaults delete com.libjch.disktree skippedUpdateVersion 2>/dev/null; rm -rf /tmp/dt-test /tmp/dt-feed.json /tmp/disktree-fda.txt; true
```

🙋 Remind the user to delete the test file from the website.

## 8. Release (🙋 only if the user explicitly asks)

1. Bump `CFBundleShortVersionString` and `CFBundleVersion` in `Info.plist`.
   1.1 has no update checker, so 1.2 is the first release that can announce
   later ones. 1.1 users must hear about 1.2 through the website.
2. Run:

   ```bash
   DISKTREE_SITE_DOWNLOADS=<site downloads dir> DISKTREE_RELEASE_NOTES="…" ./notarize.sh
   ```

3. Check that `disktree-version.json` has the new version and the right URL.
4. The user uploads `DiskTree.dmg` **first**, then `disktree-version.json`.
5. Run `--check-for-updates` (7b): it must report `up to date` for the new build.

## 9. Report back

Give the user this table filled in, plus any commits you made:

| Check | Result |
| --- | --- |
| Identities available / identity used by `build.sh` | |
| DR of old install vs. new build (same?) | |
| Diagnostic via `open`: no terminal warning, probes and result | |
| Any probe returning `error …` or a consent dialog? | |
| `tccutil reset` without sudo: exit code, entry removed? | |
| DR recorded in defaults after a granted launch | |
| Simulated signature change shown by the diagnostic | |
| Stale-grant dialog text and buttons (user-confirmed) | |
| Version file JSON generation (quotes, newline) valid | |
| `--check-for-updates`: real feed / test feed / rejected URLs | |
| Update dialog: Download, Skip, menu, throttle, Settings toggle | |
| Real website URLs (if different, what changed) | |

If anything failed, fix it, re-run `./check.sh`, commit, and say what changed.
Don't push or open a PR unless the user asks.
