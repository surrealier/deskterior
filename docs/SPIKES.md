# Spike gate (M2) — results and decisions

Machine: MacBook Air M2 (Mac14,2), macOS 26.6.2, Swift 6.2.3 (Command Line Tools only), display
"looks like 1470×956" @2x (2940×1912 backing on a 2560×1664 panel), Dock auto-hidden, menu bar 33 pt
(`safeAreaInsets.top` = 32), two desktop widgets top-left.

| Spike | Question | Result | Decision |
|---|---|---|---|
| S1 | icon+1 window covers Finder icons, stays below widgets; clicks/right-click/scroll/hover with another app frontmost; reveal-click; top strip | **Layering: pass (automated).** Desk mode run: `CGWindowListCopyWindowInfo` shows the Deskterior window at icon+1, 1470×956, ordered in front of Finder's icon window (icon+0) and behind the Window Server menu-bar strip (also icon+1, listed first = in front) and the widgets (icon+2). Clean exit after `--exit-after 6`. **Interaction (clicks with another app frontmost, hover, right-click, reveal-click): pending a human check.** | Keep icon+1. |
| S2 | Activating borderless window: keys, Quick Look, ⌘Z | _pending (human)_ | — |
| S3 | Occlusion notification under a full-screen app | _pending (human)_ | — |
| S4 | Drag-out operation for Finder / Mail / Dock Trash | **M11: implemented, pending a human check** (no real drags in automation). `DragOutController` hands the carry to an `NSDraggingSession` with the file URLs; `DragOutRule` (unit-tested) maps the ending operation: our own trash only on exactly `.delete` over a window the Dock owns (`CGWindowListCopyWindowInfo` owner PID; no titles read), and never when Finder came forward during the wait. Demo `13-file-actions` drives the `.copy` and `.delete` endings through the same code. The human check must also confirm the Dock's window is found at the drop point (if not, a Dock drop only waits like a move: the token comes back, nothing is trashed by us). | §3.6 dual rule covers both outcomes |
| S5 | SKRenderer exactness: palette round-trip, row order, drawableSize | **Pass.** In the `--windowed` run `drawableSize` stayed 2940×1912 across frames (re-asserted in `layout()`/`viewDidChangeBackingProperties()`). Offscreen `SKRenderer` → `bgra8Unorm` 64×32 target: 16/16 palette swatch pixels exact, rotated `.nearest` sprite produced only palette colours, row 0 of the target = top of the scene. **Gotcha:** `SKRenderer` ignores `scene.backgroundColor`; the render pass `clearColor` shows instead. | SKRenderer path. Always draw a full backdrop (or set the pass clear colour to the backdrop). |
| S6 | Desktop TCC prompt in a built .app (ad-hoc vs self-signed) | _deferred to M4/M12 (needs the mirror in a built app)_ | README documents re-prompts for ad-hoc builds |
| S7 | `--triple x86_64` under the CLT | **Pass.** `swift build -c release --triple x86_64-apple-macosx14.0` links a `Mach-O 64-bit executable x86_64` in 33 s. | Universal builds work locally and on CI (per-triple + `lipo`). |
| S8 | `SKMutableTexture.modifyPixelData` vs per-frame `SKTexture(data:)` at 60 fps (496×104) | **Both fine.** 1,800 frames each: RSS growth 0.02 MB, ~0.31 ms/frame including the CPU fill and an art-res render. `SKTexture(data:size:)` reads rows **bottom-up** (pinned by `TextureFactoryTests`). | Per-frame `SKTexture(data:size:)` via `TextureFactory.dynamicTexture` (flips rows). |
| S9 | Read Finder/WindowManager prefs | **Pass** via `CFPreferencesCopyAppValue`. This Mac: `CreateDesktop` unset (shown), `ShowExternalHardDrivesOnDesktop`=1, `ShowRemovableMediaOnDesktop`=1, `ShowMountedServersOnDesktop` unset, `ShowHardDrivesOnDesktop`=0, `WindowManager.StandardHideDesktopIcons` unset, `WindowManager.HideDesktop`=1. | "Finder hides desktop items" = `CreateDesktop == false` **or** `StandardHideDesktopIcons == true`. `HideDesktop` is the *Stage Manager* "show items" toggle — consult it only when Stage Manager (`GloballyEnabled`) is on. Unset `Show*OnDesktop` keys use Finder defaults (external/removable on, servers off). |
| S10 | Widget frames without Screen Recording | **Pass.** `CGWindowListCopyWindowInfo(.optionAll)` lists two 180×180 widget windows at icon+2 owned by `com.apple.notificationcenterui` (name localized: "알림 센터") at (8,45) and (188,45) pt; Finder icon window at icon+0; a 1470×81 Window Server strip at icon+1 (menu-bar backdrop). | `WidgetProbe` matches by bundle id via PID. Widgets here only overlap the decorative wall window, not interactive rects. |
| S11 | Undo by renaming out of `~/.Trash` | **M11: in-app undo verified on the FakeTrash only** (demo `13-file-actions`: same inode back in the same cell). The real Trash is never exercised by automation; a human check remains. | Fallback built: a refused put-back toasts "Use Finder's Put Back" and opens the Trash in Finder (desk mode) |
| S12 | Drop-in move from `~/Downloads` | **M11: pending a human check** (automation never touches `~/Downloads`). `FileOperator.importItems` copies when the move gets EPERM/EACCES/EXDEV; demo `13-file-actions` moves and copies in from a scratch folder. | Fallback built: copy on EPERM |

## M12: how the decisions are applied

| Spike | In the app (M12) | Still for a human |
|---|---|---|
| S1 | Desk and wall windows stay at icon+1 (`DeskWindow`, Settings has no level picker; `--level` stays a dev flag). | Clicks, hover and right-click with another app frontmost; the reveal-click; the 81-pt strip (§8.3 items 1–4). |
| S2 | The activating `DeskWindow` is kept; Peek Desk raises it to `.floating`, makes it key and activates the app. | Keys, Quick Look and ⌘Z after a desk click (§8.3 item 3). |
| S3 | `SystemGate` holds the loop while the desk window is not `.visible`; rest-pause and hard sleep remain the fallback. | That the notification fires under a full-screen app (§8.3 item 15). |
| S6 | Unchanged: the first enumeration still follows ⏻; the translocation note asks to move the app to /Applications first. | TCC across two rebuilds of a built .app. |
| S9 | Unchanged (`FinderPrefs`); the DESKTOP HIDDEN card's text is translated. | — |
| S10 | `WidgetProbe` matches `com.apple.notificationcenterui` by PID, keeps windows below normal level of widget size, and hands canvas rects to `LayoutSolver`; a one-time toast when no nudge clears them. | Widgets moved onto the monitor or drawers (§8.3 item 1). |

## M13: packaging checks (local, Command Line Tools only)

| Spike | Result | Still for a human |
|---|---|---|
| S7 | `ARCHS="arm64 x86_64" ZIP=1 scripts/build-app.sh --version 0.1.0` builds both triples and `lipo`s them (4 min 23 s at `-j 2`): `Mach-O universal (x86_64 arm64)`, ad-hoc signed, `codesign --verify --strict` passes, the zip's `.sha256` checks. The app was not opened. | Running the Intel slice on an Intel Mac. |
| S6 | Unchanged. The bundle id of a build with no GitHub owner is now the development id `io.github.deskterior.dev` (Errata 24), so local test builds never touch a released app's permissions. | TCC across two rebuilds; the Safari-downloaded zip through Open Anyway (§8.3 item 20). |
| S12 | Info.plist now explains a Downloads, Documents, removable or network volume prompt, should macOS show one for a drop-in. | Whether a drop from Downloads prompts at all. |
## Pre-release audit (wave 6)

Desk mode traced by reading the code only (desk mode was never run). "Ours" means the state folder
`~/Library/Application Support/<bundle id>` (layout, backups, `operations.log`), the icon cache
`~/Library/Caches/<bundle id>/icons`, and the app's own defaults domain. The file-safety lint holds the writers to
`FileOperator`, `Trasher`, `OperationLog`, `StateStore`, `IconCache` and `ArtifactWriter` (dev snapshots only).

| Path | (a) Changes files | (b) Registers with the system | (c) Finder or system settings | (d) Main-thread I/O | (e) After quit or crash |
|---|---|---|---|---|---|
| `main` → `AppDelegate` (desk mode) | Ours only: the state and cache folders are created (`StateStore`, `OperationLog`, `IconCache`) | The status item; `.accessory` policy (process-local). Single-instance check reads the running-app list | None. `FinderPrefs` only reads `com.apple.finder` / `WindowManager` keys | `desk.json` read (a few KB) and realpath/stat of the folders at launch | Status item and windows belong to the process |
| First run: monitor ⏻ → TCC → mirror | None until a file action. The first enumeration (the TCC prompt) runs only from ⏻ (`requestConnect` → `connectDesktop`); Choose Folder… and Open Settings only open a panel or System Settings | None | None | None (scanner, watcher and the leftover scan run on background queues; the leftover scan waits for the mirror's first snapshot) | — |
| Normal launch with saved state | Ours: `desk.json` saves (debounced, background queue), backups by age | Login item: only when `launchAtLogin` is on (`LoginItemController.launchCheck` returns at once otherwise; never from a translocated copy). Hotkey: only when `peekHotkeyEnabled` is on (`HotKeyPolicy`); other modes use recording stand-ins | None | Icon look-ups: `lstat` and `NSWorkspace.icon(forFile:)` of one item at a time (≤ 4 in flight) | — |
| Pause / Resume Desk | None | None | None | None | Windows are ordered out, nothing else |
| Peek Desk | None | Esc local key monitor and an app-activation observer while peeking (process-local) | None | None | — |
| Display changes | None | None | None | None (debounced 0.5 s; walls are CPU-rendered) | — |
| Sleep / wake, lock, session switch | Ours: the layout is saved on sleep and resign | None | None | `LayoutSaver.flush` waits for its save (`queue.sync`, a few ms) | — |
| Drop-in, drag-out, Move to Trash, Empty Wastebasket, Eject, Undo, Settings ▸ Leftover copies ▸ Move to Trash | **Only here**, only through `FileOperator`, each with a single-use intent minted in `EffectRunner` for a named gesture | None | None | Once per drag, a `volumeUUID` read for the desk folder and one per dragged item until one lies on another volume (`DropInController.crossesVolumes`), a realpath per drop (`spelled`), an `lstat` per item in reports and drag-out waits; copies and trashes run off the main actor | A copy cut short by a crash can leave a hidden `.deskterior-partial-*` folder: found and offered at the next launch, never removed by itself |
| Quit | Ours: a final save (`flush`) | Hotkey unregistered; observers removed | None | The final save | The desk windows go away with the process: Finder's icons show again. Nothing persists that covers them |
| Crash (`kill -9`) | Nothing (atomic saves; a damaged `desk.json` falls back to `.bak1…3`, and values no desk could hold are reset on load) | A registered login item stays registered (only if the user turned it on) | None | — | As quit: the Window Server drops the windows at once |

**Fixed in this wave** (Errata 25): a drop-in *move* of a locked item no longer comes in as a copy (it is refused; ⌥ copies on purpose), and a move macOS refuses for another reason that comes in as a copy now says so, also beside refusals in the same drop; a copy is reported (with its undo step) only when the item at its destination is the one it wrote, and otherwise says it cannot be undone; a running copy's staging folder is never a leftover, also after a folder switch; leftover `.deskterior-partial-*` folders are surfaced (log, a one-time toast, Settings ▸ Leftover copies) and removed only by the user, into the Trash; a `desk.json` that parses but holds impossible values (a mat grid that overflowed `Int`, counters at `Int.max`, a mile-wide mat, pages in the billions) is brought back into range before it is laid out; Quick Look's data source checks its index; the AV logo no longer runs the loop at 60 Hz.

**Accepted, documented:** the launch reads `desk.json` and the quit/sleep save waits on the main thread (both a few KB in our own folder); drag and drop answers read volume ids and realpaths on the main thread (AppKit asks for the drag operation synchronously); icons are looked up one item at a time on the main thread; a running copy is not waited for at quit (its staging goes, or is surfaced next launch); the AV logo costs more than the 0.3 % idle budget for the 10 s it bounces (measured below; never with Reduce Motion, where it holds still).

**Known limitations** (not from this wave):

- **exFAT.** On exFAT (macOS 26) the exclusive rename every file move uses (`renamex_np` with `RENAME_EXCL`) fails with `ENOTSUP` (45), so every drop-in, and every undo, into a mirrored folder on exFAT is refused ("failed(45)"); nothing changes. FAT32 works. Empty files on exFAT also take a new inode when renamed, so their identity checks would refuse even if the rename worked (a move is put back; a copy lands without an undo step). Found in review with disk images; Deskterior never falls back to a rename that could overwrite.
- **Network shares** that number items by their path (some SMB servers) would give every copy a new inode at its final rename: the copy lands but cannot be undone ("Copied in, but it can't be undone."), and moves are put back as changed. Suspected, not tested.

**Measured** (release builds, this MacBook Air M2, 2026-10-14, while other agents compiled: load average 2–5 on 8
cores, so single samples are noisy). `measure-idle.sh` samples `top` from 2.5 s after the burst until about 3 s before
the app quits; with `--exit-after 10` that is two one-second samples, about 6–9 s after launch.

| Run | Result |
|---|---|
| `measure-idle.sh --av --exit-after 10` (the AV logo bouncing), this commit | 0.55, 2.20, 3.25, 2.75, 2.65, 2.95, 3.05, 3.35, 3.05 % CPU |
| The same, the reviewed commit (`a692d2a`), interleaved with the runs above | 3.10, 3.20, 3.35 % — the same cost: the review moved when slow ticks land, not how many there are |
| The review's own runs (15 s, samples from 2.5 s after the burst to 3 s before the quit, the window checked visible in the log): slow ticks off (60 Hz) / on | 2.30, 2.23 % / 1.66, 0.90, 0.68, 0.92, 0.60 % — about 2.5–3.7× less with slow ticks |
| `measure-idle.sh --exit-after 10` (no AV), twice | 0.00 %, 0.00 % — pass (≤ 0.3 %) |
| `measure-idle.sh --exit-after 70` (DESIGN §5's 60-s average; before the review) | 0.00 % over 61 samples — pass |
| `soak.sh --minutes 10 --release` (before the review) | 239 cycles in 602 s, 0 failed expectations; RSS 51.8 MB after warm-up, 43.2 MB at the end (peak 68.6 MB): growth −8.5 MB — pass (limit 10 MB) |

The bouncing logo still costs several times the 0.3 % budget for its 10 s (each slow tick renders the whole desk). It
is accepted: it is bounded, it starts again only when AV is chosen, the monitor comes on or the glass is hovered, and
with Reduce Motion it holds still and costs nothing. An earlier version of this table gave 11–13 % at 60 Hz and 3 %
with slow ticks; the review could not reproduce the 60 Hz figure (2.3 %), so it overstated the gain about fivefold.

### Owner's manual checklist (DESIGN §8.3; release build in /Applications, macOS 26.6)

Run these yourself; no automation runs desk mode. Before you start, install the release build and write down what is
on your Desktop and how Finder is set, so you can prove nothing changed. The first line builds build/Deskterior.app
0.1.0 and copies it to /Applications; the second prints 0.1.0; the third prints the bundle id that later commands use
as `$ID`; the listing records names, inodes, flags, times and extended attributes; the last line prints Finder's two
keys (`unset` for a key never set, the usual case):

```sh
make install VERSION=0.1.0
defaults read /Applications/Deskterior.app/Contents/Info CFBundleShortVersionString
ID=$(defaults read /Applications/Deskterior.app/Contents/Info CFBundleIdentifier); echo "$ID"
ls -lAiTO@ ~/Desktop | grep -v -e '^total ' -e ' \.DS_Store$' > /tmp/desk-before.txt
{ defaults read com.apple.finder CreateDesktop 2>/dev/null || echo unset; defaults read com.apple.WindowManager StandardHideDesktopIcons 2>/dev/null || echo unset; } | tee /tmp/finder-before.txt
```

| # | Do this | Expect |
|---|---|---|
| 1 | Open /Applications/Deskterior.app. Look at the desktop, the menu bar, the notch and the top 81-pt strip; add or keep a desktop widget. | The pixel desk covers Finder's icons; widgets stay on top and clickable; the menu bar and notch look right. |
| 2 | Click empty wallpaper areas of the desk; use Mission Control, Show Desktop (F11 or the gesture), Spaces and Stage Manager. | No "click wallpaper to reveal desktop"; the desk stays put on every Space; Show Desktop and Stage Manager behave. |
| 3 | Click a token, press Space, ⌘Z, Esc; then click another app and type. | The click activates Deskterior; Quick Look opens; ⌘Z undoes; Esc works; keys never reach the desk after clicking another app. |
| 4 | With another app frontmost, hover desk objects. | Hover rings and tooltips still show. |
| 5 | A true first run: on the very first launch, or else quit Deskterior, run `tccutil reset SystemPolicyDesktopFolder "$ID"` and move its saved layout aside (`mv ~/Library/Application\ Support/"$ID" ~/Library/Application\ Support/"$ID".saved`; a saved, connected layout reconnects at launch, so the prompt would come then). Launch, watch for the Desktop access prompt, press ⏻ on the monitor. Then deny once and use Choose Folder…; turn on Finder's "hide desktop items" if you use it. Afterwards quit and put the saved layout back (`mv ~/Library/Application\ Support/"$ID" ~/Library/Application\ Support/"$ID".firstrun && mv ~/Library/Application\ Support/"$ID".saved ~/Library/Application\ Support/"$ID"`; the first-run launch made a new folder there, and a plain reverse `mv` would put the saved one inside it), and Finder's setting as it was. | The prompt appears only after ⏻. Denied → NO SIGNAL card → Choose Folder… restores the desk. With Finder hiding items, the DESKTOP HIDDEN card asks first (unless "Show them on the desk anyway" was chosen before: that is remembered). |
| 6 | Take a screenshot (⌘⇧3); have an iCloud-only (dataless) item on the Desktop. | The screenshot prints in on the monitor; the iCloud item shows its kind icon and is not downloaded. |
| 7 | Hide tokens in every spot: power off, AV input, both riser drawers, the cubby, the 3 cabinet drawers, the phone (face down), the pen cup, the wastebasket, under the mat, Lamp Only. Then Find Item, Show on Desk, Take Everything Out, Clear the Desk and its ⌘Z. | Each hides and reveals; Find/Show on Desk/Take Everything Out bring them back; Clear the Desk undoes in one step. |
| 8 | Overfill a drawer and the cup; double-click the apron to knock. | Overfill bonks; jammed drawers stay shut; nothing un-hides without a direct gesture. |
| 9 | Mat: carry it, peel a corner and grab a file, fold past the middle, tug a corner, ⌥-resize and rotate, brush and scroll-sweep piles under, stack more for taller bumps. | As described in E9; folds and creases persist across a relaunch. |
| 10 | Drag a token out to a Finder window, to Mail, and onto the Dock's Trash. | Finder: moved; Mail: copied (file stays); Dock Trash: trashed exactly once (⌘Z puts it back). |
| 11 | Drop in from the same volume, from an external drive, with ⌥, onto a taken name, and, without ⌥, a Finder-locked file (Get Info ▸ Locked) that lies on the Desktop's own volume (from another volume it is copied, as asked); then that locked file together with an unlocked one. Undo each. | Same volume: moved; external or ⌥: copied; clash: " 2"; locked: "It's locked, so it stayed. ⌥ copies it." and nothing changes; with the unlocked one: it moves in and "Some were locked, so they stayed.". Each undo returns the original state. |
| 12 | Move to Trash from a token's menu and undo; put files in the wastebasket and choose Empty Wastebasket…, first Cancel (and Esc), then Move to Trash. | The sheet lists the names, Cancel is the default and changes nothing; confirming moves them to the Trash; undo or Finder's Put Back restores them. |
| 13 | Mount a USB stick or disk image. | It plugs into the hub; Eject from its menu ejects it. |
| 14 | With a second display: answer the cover prompt; drop a file on the wall display; unplug and replug; change Settings ▸ Desk display; toggle the Dock position and auto-hide. | Walls cover the other display; wall drops land on the monitor; the desk follows the display changes. |
| 15 | Open a full-screen app; sleep and wake; lock; fast-user-switch; then turn on Low Power Mode. | The loop pauses (check Activity Monitor: ~0 % CPU) and resumes with no physics explosion; Low Power Mode does not pause it, it only caps it at 30 frames a second. |
| 16 | Peek Desk from the menu; turn on the ⌃⌥⌘D hotkey in Settings, use it, then turn it off again; quit and relaunch holding ⌥. | Peek floats the desk with "× Done" (Esc ends it); the hotkey works only while on; ⌥ at launch opens Safe Mode. |
| 17 | Look at System Settings ▸ General ▸ Login Items, then turn Launch at Login on in Settings; quit, update (`make install VERSION=0.1.1`, then `defaults read /Applications/Deskterior.app/Contents/Info CFBundleShortVersionString` prints 0.1.1), open it once, and log out and in. | Off by default (not listed); on shows "Login item added"; after the update it still launches at login. Turn it off again unless you want it (checked at the end). |
| 18 | Quit from the menu; relaunch; then `kill -9 $(pgrep -x Deskterior)`. Optionally kill it during a long drop-in copy from an external drive and relaunch. | Quit and the crash both bring Finder's icons back at once. After a killed copy, either nothing is left (the copy staged outside the Desktop) or the toast "Interrupted copy left files. See Settings." appears once and Settings ▸ Leftover copies offers Show in Finder and Move to Trash; nothing is removed until you press it. |
| 19 | Turn on VoiceOver (⌘F5) over the desk; open Find Item and use it with the keyboard only. | Tokens and controls are read; the Inventory is fully keyboard-accessible. |
| 20 | `make idle` (and `scripts/measure-idle.sh --exit-after 70`); `scripts/soak.sh --release` (1 hour); download the release zip in Safari and open it. | Idle ≤ 0.3 % CPU; the soak grows < 10 MB; the Open Anyway flow works as the README says. |
| 21 | Settings ▸ Reduce motion: Always. Fling a token off the desk, drop onto a full wastebasket, click the basket and the pen cup, double-click the apron, switch to AV, press ⏻ twice. Then set it back to Follow System. | No screen shake, jiggle or wobble; tosses land at once with a puff; the AV logo holds still; the CRT is a 2-frame fade. |
| 22 | Switch to AV and watch Deskterior in Activity Monitor (CPU) while the NO SIGNAL logo bounces and for a while after it stops (10 s). | The logo steps evenly (never a hold, then a jump of two); a few percent at most while it bounces, then ~0 %. |
| 23 | With two or more HDMI pages, carry a token and rest it on INPUT. | The page turns every 0.6 s, wrapping to HDMI 1, never to AV. |

Afterwards prove the session changed nothing. Rows 5 (Finder's setting, the moved layout), 6 (the screenshot), 10–14
(file actions, the wall drop) and 18's copy change the Desktop or Finder's keys on purpose: put those back, or skip
them, or take the "before" files again after them. Opening a file lets macOS note its last-used date
(`com.apple.lastuseddate#PS`); that attribute may differ for files you opened.

```sh
ls -lAiTO@ ~/Desktop | grep -v -e '^total ' -e ' \.DS_Store$' > /tmp/desk-after.txt
diff /tmp/desk-before.txt /tmp/desk-after.txt && echo "Desktop unchanged"
{ defaults read com.apple.finder CreateDesktop 2>/dev/null || echo unset; defaults read com.apple.WindowManager StandardHideDesktopIcons 2>/dev/null || echo unset; } > /tmp/finder-after.txt; diff /tmp/finder-before.txt /tmp/finder-after.txt && echo "Finder settings unchanged"
ls -A ~/Desktop | grep -c deskterior-partial
defaults read "$ID" launchAtLogin 2>&1; defaults read "$ID" peekHotkeyEnabled 2>&1
```

`diff` prints nothing (same names, inodes, flags, sizes, times to the second and extended attributes; `.DS_Store` is
Finder's own and left out) and the Finder keys read as before: Deskterior never writes Finder's or the WindowManager's
settings, so they cannot differ. The count prints 0 (no leftovers); the two reads print 0 or "does not exist": Launch
at Login and the hotkey are off, and System Settings ▸ General ▸ Login Items no longer lists Deskterior, unless you
chose to keep them.
