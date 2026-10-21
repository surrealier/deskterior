# Changelog

All notable changes to Deskterior are listed here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.4.0] - 2026-10-21

### Added

- **Picture frame.** Hang a photo of your own in the framed print above the wall shelf: right-click the frame ▸
  Choose Photo…, drag an image from the monitor onto it, pick Hang in Picture Frame from an image's menu, or drop one
  from Finder onto it (or onto the framed print on another display's wall). It is drawn in the room's 46 colours at
  26×34 pixels, dims with the room at night and hangs on your other displays' walls too. Your file is only read, never
  moved, copied or changed: the frame keeps its own small pixel copy in `frame.json` in the state folder, which Safe
  Mode's Reset Layout and folder switches leave alone. ⌘Z takes a hang back; Remove Photo brings the print back.

### Changed

- The framed print over the wall shelf answers the pointer: a ring, a tooltip and its own menu (Choose Photo…, Remove
  Photo, Put Away Wall Shelf). Files dropped on it from Finder are never moved into the Desktop folder.
- The privacy prompts for Downloads, Documents and drives also say that a photo hung from there is only read.
- Going back to 0.3.0: the framed print comes back; `frame.json` stays for 0.4.0.

## [0.3.0] - 2026-10-19

### Added

- **Put Away and Bring Back.** Put away what you don't use: the riser drawers (the riser stays as a plain stand), the
  filing cabinet, the phone stand, the plant, the desk partition or its add-ons, and the wall shelf, pegboard, string
  lights, floor plant and wall art, from the object's menu, Put Away ▸ in the menu bar menu, or Arrange Desk…. A place
  that holds files says so ("Take Out 3 & Put Away Cabinet") and brings them to the monitor first, in the same undo
  step. Bring Back ▸ returns things one by one or all at once (Bring Everything Back) and moves aside anything resting
  where an object returns.
- **The desk partition.** A felt partition along the back of the desk, with a raised panel beside the monitor.
- **Sticky notes.** Click the sticky-note cube for a note or drag one off it; stick notes anywhere on the felt (they
  snap where they can be read); edit them in the new Memos window, in six colours, with a date; drop one in the
  wastebasket to take it off. Up to 24. A note in the dark keeps its text to itself: its tooltip only says "Sticky
  Note". Notes and memos live in their own `memos.json` in the state folder, which Safe Mode's Reset Layout and
  folder switches leave alone.
- **Daily memo pad and the wall calendar.** Today's page under the desk lamp; tear it off as a dated sticky note. The
  wall calendar marks days with memos, notes or the D-Day, and a click opens that day; the Memos window has the month.
- **Memo clips.** Clip up to 5 Desktop files to the partition (layout only).
- **D-Day card and clip light.** A countdown card ("D-12") and a clip light for the right side of the partition at
  night.
- **Save as Text File on Desktop.** From a note's or the pad's menu, or the Memos window: a new text file in your
  Desktop folder, never overwriting anything; ⌘Z moves it to the Trash while it is unchanged.

### Changed

- The room now shows the desk partition; Put Away removes it. The desk lamp lights the partition's left side.
- Going back to 0.2.0: put-away objects come back; files in the memo clips come back as new files on the monitor (if
  every file was in the clips, 0.2.0 opens the previous backup instead); notes stay in memos.json for 0.3.0.

## [0.2.0] - 2026-10-17

### Added

- **Apps become aliases.** An app dragged from Finder onto the desk now becomes a Finder alias named without ".app"
  ("Safari"), showing the app's own icon with the alias mark; double-click opens the app, and the app stays where it
  is. An app dragged out of the Trash or off a disk image, a USB stick or a card still comes in like any file. ⌘⌥
  makes an alias of anything (Finder's convention). The alias lands where it was dropped, gets " 2" on a clash, and
  ⌘Z ("Undo Make Alias") moves it to the Trash without touching the app. Toasts say what happened in English and
  Korean ("Made an alias; the app stayed put.").
- **README in five languages.** English, 한국어, 简体中文, 日本語 and Español editions with a language selector, a
  gallery of 18 real screen recordings (one per feature) and a complete feature list. The hero GIF is a real screen
  recording too.
- **Capture tooling** in `scripts/capture/` for those recordings: an input director that drives scenes with real
  mouse and keyboard events, art-aligned ffmpeg recording, and a GIF cutter that keeps the pixel art exact.

### Changed

- **Drop-in keys.** ⌘ alone now moves every dropped item, apps too (across disks it stays a copy); ⌥ still copies
  everything. Over the desk or a wall, a drag that will only make aliases shows the link cursor, and one that aliases
  an app beside other files shows the copy cursor. A drag whose source allows only a link (⌃) makes aliases. Walls
  now take ⌘ and ⌃ drags as the desk does.
- **Find Item…** lists aliases under the kind "Alias".

## [0.1.0] - 2026-10-15

The first release: milestones M0–M13 of [docs/DESIGN.md](docs/DESIGN.md).

### Added

- **The room.** A 512×320 pixel-art desk room drawn at a whole-number scale for each display (Chunky, Normal or
  Fine pixels), extended to fill any screen: window and sky, wall clock, calendar, plant, lamp, monitor on a riser,
  phone stand, pen cup, drive hub, desk mat with keyboard, brush, chair, filing cabinet and wastebasket. Every pixel
  is one of the 46 Apollo colours, with no translucency. Text is Galmuri9, Korean included. Tall and portrait
  displays get a ceiling with beams and a lamp, an upper shelf, framed prints and hanging plants.
- **Your Desktop on the monitor.** The Desktop folder (or another folder you choose) is mirrored live: new files print
  in, renames keep their place, removed files poof. Files are recognised by identity (volume and inode), so renames
  and safe-saves keep their spot, and a file that comes back within 7 days returns to where it was. Pixelated real
  icons and thumbnails, with hand-drawn kind icons first; iCloud placeholders are never downloaded.
- **The monitor.** Pages of 45 files as HDMI inputs, an always-empty AV input, Clean Up By name, kind or date added,
  marquee and ⌘-click selection, keyboard navigation; resting a carried file on INPUT flips to the next page. The
  power button collapses the picture like a CRT and hides
  everything; files arriving while it is off light an amber LED and a "+N" badge.
- **Hiding places.** Two riser drawers and a cubby, a three-drawer filing cabinet (interlocked, folder tabs in the
  bottom drawer, blocked by the chair until it rolls aside), a phone that turns face down, a pen cup, and a
  wastebasket that hides and never deletes. Drawers chomp dropped files, rest ajar when overfull, jam and bonk when
  full, peek on scroll, spring-load during a drag and slam shut. List Contents, Move Contents to ▸, Take All Out.
- **Desk physics.** Files set down on the desk form piles that slide and stack; flicks fly in arcs off the desk onto
  the floor or into the wastebasket (SWISH!, rim bounces, misses). The pen cup can be carried, tipped and stood up;
  the basket can be tipped and dug through. Double-clicking the desk's apron knocks it; knocks never change where a
  file lives.
- **The desk mat** (the homage to Terkel Gjervig's *Desktop Cleaning*). A simulated cloth mat: carry it (it creases),
  peel an edge or corner to reveal and take files, fold it, tug corners or double-click an edge to smooth it, ⌥-drag
  to resize, turn or slide it. Files dropped on it, pushed in with the brush or swept by a sideways scroll go under and
  leave bumps that grow with the stack. Peek Under, List Items Under Mat, Size, Rotate, Reset Mat. A Flat mode keeps
  the bumps without lifting. The keyboard on the mat turns with it.
- **Clear the Desk.** One action: monitor off, phone face down, drawers shut, and the brush sweeps every loose pile
  and floor file under the mat ("TIDY!"); one undo puts it all back.
- **Lighting.** Day, dusk and night follow the clock (or Lights ▸ Day, Night). Room light switch, desk lamp, and Lamp
  Only darkness where only the lamp's pool and the monitor's and phone's glow light anything, and files in the dark
  cannot be picked. Drag the clock's minute hand to preview another time.
- **Finding things.** Find Item… lists every file with its location; Show on Desk opens whatever hides it; Take Out
  and Take Everything Out bring files back to the monitor.
- **File actions, only when asked.** Move to Trash and Empty Wastebasket… (with a sheet listing the names) go to the
  macOS Trash; drop-in from Finder moves or copies files into the Desktop folder (never overwriting); drag-out hands
  files to other apps, Mail and the Dock's Trash; Eject from the drive hub. Every one is logged; all but Eject and
  drags out to other apps (save a Dock Trash drop Deskterior trashes itself) can be undone with ⌘Z. A locked file is
  never moved in (⌥ copies it), and the hidden folder an interrupted copy can leave behind is reported and listed
  under Settings ▸ Leftover copies, never removed by itself.
- **System integration.** Covers Finder's icons without changing Finder; menu bar item and bare-wall menu; walls on
  other displays (drops go to the monitor); Peek Desk (optional ⌃⌥⌘D shortcut, off by default) and Pause Desk;
  pausing for full-screen apps, sleep, lock, user switching, and optionally on battery; widget avoidance; Launch at
  Login (off by default); Settings; Safe Mode (hold ⌥ at launch); App Translocation note; welcome window; a
  template menu bar icon. A saved layout with impossible values is repaired when it loads, and a chosen folder that is
  missing at launch shows the Desktop that time instead of stopping the app.
- **Accessibility and languages.** VoiceOver lists every file and control; Reduce Motion (following the system by
  default) replaces shakes, flickers and arcs and holds the AV logo still; English and Korean menus, cards, toasts, windows and settings.
- **Packaging.** A universal (Apple silicon and Intel) app built with the Command Line Tools only, ad-hoc signed or
  with an optional free self-signed identity ([docs/SIGNING.md](docs/SIGNING.md)); GitHub Actions CI and a tagged
  release workflow with a SHA-256 checksum and a build provenance attestation.
- **Developer tooling.** Scripted headless demos on generated fixture folders ([docs/DEMOS.md](docs/DEMOS.md)),
  `make gif` for the README's tour, a file-safety lint, idle-CPU and soak scripts, 1,000+ tests.

### Known issues

- Not notarized: each downloaded version needs System Settings ▸ Privacy & Security ▸ Open Anyway, and macOS may ask
  for Desktop access again after an update.
- Tested on one Mac (MacBook Air M2, macOS 26); it has never been run on macOS 14 or 15, and the Intel build has not
  been run on an Intel Mac.
- Not yet checked by hand: clicks and hover while another app is in front, keys after a desk click, pausing under
  full-screen apps, drag-out to Finder, Mail and the Dock's Trash, undo through the real Trash, drop-in from
  Downloads ([docs/SPIKES.md](docs/SPIKES.md)).
- Clicking the wallpaper to reveal the desktop does not work over the desk; widgets stay above it.
- A Finder desktop selection made before the desk covered it can still be trashed with ⌘⌫ in Finder.
- A mirrored folder on an exFAT drive cannot take drops, and ⌘Z cannot bring trashed files back into it (exFAT lacks
  the no-overwrite rename); nothing changes.
- Parts of the scene stay English only: tooltips, VoiceOver's names for desk objects, the AV input's NO SIGNAL logo,
  BONK, SWISH! and TIDY!.

[0.4.0]: ../../compare/v0.3.0...v0.4.0
[0.3.0]: ../../compare/v0.2.0...v0.3.0
[0.2.0]: ../../compare/v0.1.0...v0.2.0
[0.1.0]: ../../releases/tag/v0.1.0
