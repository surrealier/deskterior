# Changelog

All notable changes to Deskterior are listed here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2026-10-14

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
  full, peek on scroll, spring-load during a drag and slam shut. List Contents, Take All Out, Move to ▸.
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
  drags out to other apps can be undone with ⌘Z. A locked file is never moved in (⌥ copies it), and the hidden
  folder an interrupted copy leaves behind is reported and listed under Settings ▸ Leftover copies, never removed
  by itself.
- **System integration.** Covers Finder's icons without changing Finder; menu bar item and bare-wall menu; walls on
  other displays (drops go to the monitor); Peek Desk (optional ⌃⌥⌘D shortcut, off by default) and Pause Desk;
  pausing for full-screen apps, sleep, lock, user switching, and optionally on battery; widget avoidance; Launch at
  Login (off by default); Settings; Safe Mode (hold ⌥ at launch); App Translocation note; welcome window; a
  template menu bar icon. A saved layout with impossible values is repaired when it loads.
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
- A mirrored folder on an exFAT drive cannot take drops (exFAT lacks the no-overwrite rename); nothing changes.
- The scene's own lettering is English only: tooltips, the NO SIGNAL logo, BONK, SWISH! and TIDY!.

[0.1.0]: ../../releases/tag/v0.1.0
