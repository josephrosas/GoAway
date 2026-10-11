# GoAway

A Mac utility that permanently erases everything in Trash the moment you open it. An [R6.ai](https://r6.ai) product.

When you normally empty Trash, macOS only forgets where the files were. GoAway overwrites the data, scrambles the name, truncates the file, then unlinks it. Optionally it then scrubs the volume's free space so even the blocks APFS left behind are overwritten.

## Build

```bash
chmod +x Scripts/*.sh Scripts/swiftc-manifest-fix
Scripts/build-app.sh --install     # builds, signs, copies to /Applications
open /Applications/GoAway.app
```

Requires macOS 14+ and Swift 6.

The first build creates a self-signed code-signing identity called **GoAway Development** in your login keychain (`Scripts/make-signing-cert.sh`). This matters: macOS ties the Full Disk Access grant to the app's signature. An ad-hoc signature is just a hash of one exact binary, so every rebuild would silently break the grant while System Settings still shows it as on. With a stable identity the grant survives rebuilds. macOS may ask once to trust the certificate and once to let `codesign` use the key; choose Always Allow.

`build-app.sh` options: `debug|release`, `--install` (copy to `/Applications`), `--reset-tcc` (forget the current Full Disk Access entry so it can be re-granted cleanly), `--adhoc` (skip the stable identity; not recommended).

```bash
export SWIFT_EXEC="$PWD/Scripts/swiftc-manifest-fix"
swift run GoAwayCheck                 # engine self-test
swift run -c release GoAwayCheck --bench small=5000 big=2048 level=simple   # throughput on a fake Trash
```

`--bench` accepts `small=N` (4 KB files), `big=MB`, `level=simple|doe|dod|gutmann` and `serial` (force one worker).

## Use

Opening GoAway starts wiping Trash immediately. There is no confirmation dialog. Cancel finishes the file already being overwritten, then leaves the rest.

Grant **System Settings → Privacy & Security → Full Disk Access** to GoAway, then relaunch. Trash on modern macOS is behind that privacy gate, and the grant only applies to processes started after it was given, so the permission screen offers a **Relaunch GoAway** button.

If GoAway is already listed and on but the permission screen still appears, the stored grant belongs to an older build: toggle GoAway off and on in Full Disk Access (or remove it with − and drag the current app back in), then relaunch. `Scripts/build-app.sh --reset-tcc` does the forgetting for you. The permission screen shows what macOS actually said, e.g. `~/.Trash: EPERM (Operation not permitted)`.

To watch what GoAway is doing:

```bash
log stream --predicate 'subsystem == "com.unga.GoAway"' --level info
```

Settings live under **Settings…** (`⌘,`): wipe level, a single-pass SSD override, free-space scrub, assurance warnings, completion sound, and appearance.

When everything went cleanly the window closes by itself. It stays open only when something still holds the data: items that could not be erased (with Reveal in Finder and Retry), local APFS snapshots (with one-click delete), or FileVault being off.

## How it works

- Files and symlinks are erased first, in parallel on solid-state volumes; directories follow, deepest first.
- Each file is overwritten in 4 MB aligned writes. Files of 16 MB or more bypass the buffer cache so a big wipe does not evict your working set. Each pass ends with `fsync`; one device-wide `F_FULLFSYNC` per volume runs at the end of the job rather than per file.
- Volume facts (SSD, filesystem, encryption) are looked up once per volume, not per file.
- With **Also scrub free space** on, GoAway writes random data into a temporary folder inside each Trash until the volume is nearly full (256 MB headroom), syncs, and deletes it. This is the only user-space way to reach blocks that APFS freed.

## Honesty

No software can promise that data is physically unrecoverable. What each piece achieves:

- **HFS+, exFAT, FAT (typically external drives):** the overwrite passes land on the file's own blocks. This is the classic secure erase and it works.
- **APFS (every modern internal drive):** APFS is copy-on-write. Overwriting a file writes new blocks and frees the old ones; the overwrite does not touch the original data. GoAway still scrambles the name, truncates, and unlinks. Turn on the free-space scrub to overwrite the freed blocks.
- **Local snapshots and Time Machine:** a snapshot taken while a file sat in Trash keeps its blocks alive regardless. GoAway detects local snapshots and offers to delete them (administrator password required). Backups on other disks and in iCloud are out of reach.
- **SSD wear-leveling:** the drive may keep stale copies in cells no software can address. FileVault is the real protection here: freed blocks are ciphertext without your password. GoAway warns when FileVault is off.
- **Copies elsewhere:** Quick Look thumbnails are reset after a run; anything copied before it reached Trash is not GoAway's to find.

Extra passes on flash only add wear, so GoAway uses one random pass on SSDs unless you turn that override off.

## Feedback

[hi@r6.ai](mailto:hi@r6.ai?subject=GoAway%20Feedback)
