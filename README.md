# GoAway

A Mac utility that permanently erases everything in Trash the moment you open it. An [R6.ai](https://r6.ai) product.

When you normally empty Trash, macOS only forgets where the files were. GoAway overwrites the data, scrambles the name, truncates the file, then unlinks it. Optionally it then scrubs the volume's free space, which reaches files that were deleted the normal way before.

## Build

```bash
chmod +x Scripts/*.sh Scripts/swiftc-manifest-fix
Scripts/build-app.sh --install     # builds, signs, copies to /Applications
open /Applications/GoAway.app
```

Requires macOS 14+ and Xcode with Swift 6. With only the Command Line Tools installed, `build-app.sh` patches a manifest link error by itself (`Scripts/swiftc-manifest-fix`).

The first build creates a self-signed code-signing identity called **GoAway Development** in your login keychain (`Scripts/make-signing-cert.sh`). This matters: macOS ties the Full Disk Access grant to the app's signature. An ad-hoc signature is just a hash of one exact binary, so every rebuild would silently break the grant while System Settings still shows it as on. With a stable identity the grant survives rebuilds. macOS may ask once to trust the certificate and once to let `codesign` use the key; choose Always Allow.

`build-app.sh` options: `debug|release`, `--install` (copy to `/Applications`), `--reset-tcc` (forget the current Full Disk Access entry so it can be re-granted cleanly), `--adhoc` (skip the stable identity; not recommended), `--release-dist` (see Release).

```bash
swift run GoAwayCheck                 # engine self-test, includes the forensic test below
swift run GoAwayCheck --forensic      # forensic report only
swift run -c release GoAwayCheck --bench small=5000 big=2048 level=simple   # throughput on a fake Trash
swift test
```

`--bench` accepts `small=N` (4 KB files), `big=MB`, `level=simple|doe|dod|gutmann` and `serial` (force one worker).

## Release

```bash
export GOAWAY_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
export GOAWAY_SPARKLE_PUBLIC_KEY="…"   # see below
Scripts/release.sh                    # dist/GoAway-<version>.dmg, notarized and stapled
Scripts/appcast.sh ~/Sites/goaway     # adds the DMG and regenerates appcast.xml
```

`release.sh` runs `build-app.sh --release-dist`: a universal (Apple silicon + Intel) release build with the hardened runtime and a secure timestamp, the version taken from the latest `vX.Y.Z` git tag and the build number from the commit count. It packs the app into a DMG, submits it with `notarytool`, and staples the ticket. `--skip-notarize` stops after the signed DMG.

One-time setup:

- `xcrun notarytool store-credentials GoAway --apple-id you@example.com --team-id TEAMID` saves the notary credentials in your keychain (`GOAWAY_NOTARY_PROFILE` picks another profile name).
- `.build/artifacts/sparkle/Sparkle/bin/generate_keys` (after `swift package resolve`) creates the update-signing key in your keychain and prints the public key for `GOAWAY_SPARKLE_PUBLIC_KEY`. Builds without it have updates switched off.

Updates come from [Sparkle](https://sparkle-project.org). The feed is `SUFeedURL` in `Resources/Info.plist` (`https://r6.ai/goaway/appcast.xml`; `GOAWAY_FEED_URL` overrides it per build). `appcast.sh` signs each update with your key; upload the folder's contents next to the feed URL. GoAway checks once a day and waits for any update prompt before quitting; **Check for Updates…** is in the app menu.

## Use

Opening GoAway starts erasing Trash immediately.

- **Countdown:** turn on **Settings → Show a countdown before erasing** to get three seconds, the number of items and their size, and a Cancel button first.
- **Hold Option** while opening GoAway to skip erasing: it waits on a Ready screen and opens Settings.
- **Cancel** stops inside the file being overwritten; that file and everything not yet reached stay in Trash.
- **Erase specific items:** drag files or folders onto GoAway's icon (in Finder or the Dock), or choose **Finder → Services → Erase with GoAway**. After you confirm, they move to Trash and only they are erased; nothing else in Trash is touched. Whole disks, your home folder, Trash itself and GoAway are refused.
- **Shortcuts:** the built-in "Open App" action runs GoAway like opening it. A dedicated Shortcuts action would need App Intents, which requires an Xcode project rather than this Swift package.

Grant **System Settings → Privacy & Security → Full Disk Access** to GoAway. Trash on modern macOS is behind that privacy gate, and the grant only applies to processes started after it was given. While the permission screen is up, GoAway checks every two seconds with a freshly started helper (`GoAwayProbe`) and relaunches itself as soon as access is on. **Relaunch GoAway** does the same by hand.

If GoAway is already listed and on but the permission screen still appears, the stored grant belongs to an older build: toggle GoAway off and on in Full Disk Access (or remove it with − and drag the current app back in). `Scripts/build-app.sh --reset-tcc` does the forgetting for you. The permission screen shows what macOS actually said, e.g. `~/.Trash: EPERM (Operation not permitted)`.

To watch what GoAway is doing (file names are logged as private):

```bash
log stream --predicate 'subsystem == "com.unga.GoAway"' --level info
```

Settings live under **Settings…** (`⌘,`): wipe level, a single-pass SSD override, the countdown, free-space scrub, assurance warnings, completion sound, updates, and appearance.

When everything went cleanly the window closes by itself. It stays open only when something still holds the data: items that could not be erased (with Reveal in Finder and Retry), local APFS snapshots (with one-click delete), or FileVault being off. Quitting during a run cancels it first and waits for the current file to stop.

## How it works

- Files and symlinks are erased first, directories after, deepest first. Each volume gets its own workers, all volumes at once: several in parallel on a solid-state volume, one on a hard drive.
- Each file is overwritten in 4 MB aligned writes. Files of 16 MB or more bypass the buffer cache so a big wipe does not evict your working set. Each pass ends with `fsync`; one device-wide `F_FULLFSYNC` per volume runs at the end of the job rather than per file.
- Then the item is renamed to a random name, truncated, stripped of extended attributes, and unlinked. A folder is removed only once it is empty, so anything that could not be erased keeps its folder and is reported; **Retry** scans that folder again.
- Read-only and locked items you own (permissions, the locked flag, deny-delete access rules) are unlocked when the first attempt is refused.
- Volume facts (SSD, filesystem, encryption) are looked up once per volume, not per file. The Mac does not idle-sleep during a run.
- With **Also scrub free space** on, GoAway writes random data into a temporary folder inside each Trash until free space is down to a safety margin, syncs, and deletes it. The margin is 2% of the disk (at least 2 GB) on the startup and home volume, so macOS keeps room to work, and 256 MB elsewhere. A scrub folder left by a crash is deleted at the next launch.
- Local snapshots are listed before the scrub. Deleting them afterwards releases more old blocks, so GoAway scrubs again (or offers **Scrub Free Space** when the scrub is off).

## Honesty

No software can promise that data is physically unrecoverable. These statements are measured, not assumed: `GoAwayCheck --forensic` creates APFS, HFS+ and exFAT disk images, plants a 2 MB marker file, erases it, unmounts, and searches the raw image for the marker. A file deleted the normal way serves as control and must still be found, which proves the search works.

- **The file's own data is gone** on APFS, HFS+ and exFAT: no copy of the marker remains after an erase, including for read-only files. APFS rewrites a file's blocks where they are unless they are shared with a snapshot or a clone.
- **APFS clones:** when both copies of a clone are in Trash, both are overwritten. A clone outside Trash keeps its own copy, as it should.
- **Local snapshots** taken while a file existed keep its old blocks; overwriting cannot reach them. GoAway lists them and offers to delete them (administrator password required), then scrubs the space they release. Time Machine backups on other disks and copies in iCloud are out of reach.
- **Earlier deletes:** files deleted the normal way before GoAway ran stay readable in free space until something overwrites them. The scrub reaches them except inside its safety margin: in the test, part of an earlier delete on HFS+ survived in the margin, while on APFS and exFAT it was gone.
- **File names:** GoAway renames each item before unlinking it, but APFS keeps older copies of folder metadata, so original names can remain in raw blocks even after a scrub. The test cannot find names on HFS+ and exFAT even for the control, so it says nothing either way there.
- **SSD wear-leveling:** the test reads what the filesystem stored. Inside an SSD the controller may keep stale copies in cells no software can address. FileVault is the real protection: everything above, names included, is ciphertext without your password. GoAway warns when FileVault is off.
- **Network volumes:** the server decides where data lands; GoAway only unlinks there.
- **Copies elsewhere:** Quick Look thumbnails are reset after a run; anything copied before it reached Trash is not GoAway's to find.

Extra passes on flash only add wear, so GoAway uses one random pass on SSDs unless you turn that override off.

## Feedback

[hi@r6.ai](mailto:hi@r6.ai?subject=GoAway%20Feedback)
