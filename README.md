**English** · [한국어](README.ko.md) · [简体中文](README.zh-CN.md) · [日本語](README.ja.md) · [Español](README.es.md)

<div align="center">

<img src="Packaging/AppIcon-master.png" width="128" alt="Deskterior's app icon: a pixel-art desk with a red lamp, a monitor and a small plant against a night-blue wall">

# Deskterior

Tidy your Mac's desktop the way you tidy a real desk, in pixel art.

[![Latest release](https://img.shields.io/github/v/release/surrealier/deskterior?label=release)](../../releases/latest)
[![CI](https://github.com/surrealier/deskterior/actions/workflows/ci.yml/badge.svg)](../../actions/workflows/ci.yml)
[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue)](#requirements)
[![License: MIT](https://img.shields.io/badge/license-MIT-green)](LICENSE)

<img src="docs/media/hero.gif" width="588" alt="A real screen recording of Deskterior on a Mac: Music and Notes are dragged from a Finder window onto the pixel-art monitor, where Claude, ChatGPT, Safari, Books and Weather already sit, and turn into pixel icons; three files are dropped on the desk mat and slide under it; the mat is peeled back, turned and carried; files go into the riser drawers; one is flicked into the wastebasket (SWISH!), which is then tipped over; the lights are set to Night, the room light is switched off so only the desk lamp shines, and the lamp is clicked off and on">

<sub>Above: a real screen recording of the app on a Mac. The still pictures further down use the desk's built-in file
icons. On your Mac each file shows its own icon or thumbnail, in pixels.</sub>

</div>

**A pixel-art desk that lives on your Mac's desktop.** Deskterior covers the desktop with a small, lit room, and
the files on your Desktop show up as icons on the desk's monitor. Tidy them away the way you would on a real desk:
drop them in the riser drawers or the filing cabinet, park them on the phone stand or in the pen cup, toss them in
the wastebasket, sweep them under the cloth desk mat with the brush, or just press the monitor's power button.
Hiding only changes the layout. Your files stay where they are and change only when you explicitly ask.

[**Download the latest release**](../../releases/latest) · macOS 14 Sonoma or later · Apple silicon and Intel ·
free and open source (MIT)

- [Features](#features) · [Everything it does](#everything-it-does) · [Where things hide](#where-things-hide) ·
  [Gestures](#gestures) · [Your files are safe](#your-files-are-safe)
- [Install](#install) · [First run](#first-run) · [Settings](#settings) · [Safe Mode](#safe-mode) · [Uninstall](#uninstall)
- [Build from source](#build-from-source) · [Requirements](#requirements) · [Known limitations](#known-limitations) ·
  [Credits](#credits) · [License](#license)

## Features

Every clip here is a real screen recording of Deskterior on a Mac. The full list is under
[Everything it does](#everything-it-does).

### On the monitor

<table>
<tr>
<td width="50%" valign="top">
<img src="docs/media/feat-apps.gif" width="__W_apps__" alt="Screen recording: apps and files are dragged from a Finder window onto the pixel-art monitor, where their real icons turn into pixel icons"><br>
<b>Real icons, in pixels</b><br>
Drop apps or files from Finder onto the monitor: their real icons turn into pixel icons.
</td>
<td width="50%" valign="top">
<img src="docs/media/feat-power.gif" width="__W_power__" alt="Screen recording: the monitor's power button is pressed and the picture collapses like an old CRT; a file arrives while it is off and an amber +1 badge lights up on the bezel"><br>
<b>A CRT power button</b><br>
⏻ collapses the picture like an old CRT and hides every file. A file that arrives while it is off lights the amber +1 badge.
</td>
</tr>
<tr>
<td width="50%" valign="top">
<img src="docs/media/feat-input.gif" width="__W_input__" alt="Screen recording: the INPUT button flips the monitor through its HDMI pages of files, then to AV, which shows a NO SIGNAL logo"><br>
<b>INPUT and AV</b><br>
INPUT flips through HDMI pages of 45 files each. AV is always empty: NO SIGNAL.
</td>
<td width="50%" valign="top">
<b>Also on the monitor</b><br>
Clean Up By name, kind or date added · select with a click, ⌘-click, a box or ⌘A · arrow keys, Space for Quick Look · a scroll on the screen turns the page.<br>
<a href="#everything-it-does">Everything it does</a>
</td>
</tr>
</table>

### Hiding places

<table>
<tr>
<td width="50%" valign="top">
<img src="docs/media/feat-drawers.gif" width="__W_drawers__" alt="Screen recording: files dropped on the riser drawers are swallowed as the drawers open and shut; a scroll over a closed drawer peeks inside; files sit in the cubby as dim silhouettes"><br>
<b>Riser drawers and cubby</b><br>
Drop a file on a closed drawer and it chomps it. Scroll over one to peek; the cubby only half hides.
</td>
<td width="50%" valign="top">
<img src="docs/media/feat-cabinet.gif" width="__W_cabinet__" alt="Screen recording: a filing cabinet drawer opens only a crack because the chair is in the way; the chair is pushed aside, and the drawer opens on its coloured folder tabs"><br>
<b>Filing cabinet and chair</b><br>
The chair blocks the cabinet: push it aside and pull again. The bottom drawer files things under folder tabs.
</td>
</tr>
<tr>
<td width="50%" valign="top">
<img src="docs/media/feat-phone.gif" width="__W_phone__" alt="Screen recording: files dropped on the phone become small app icons, and the phone is flipped face down to hide them"><br>
<b>Phone stand</b><br>
Files become mini apps on the phone. Flip it face down to hide them.
</td>
<td width="50%" valign="top">
<img src="docs/media/feat-pencup.gif" width="__W_pencup__" alt="Screen recording: files dropped in the pen cup become pens; the cup is flicked, tips over and the pens spill across the desk"><br>
<b>Pen cup</b><br>
Files become pens, capped in their kind's colour. Flick the cup and it tips, spilling them.
</td>
</tr>
<tr>
<td width="50%" valign="top">
<img src="docs/media/feat-wastebasket.gif" width="__W_wastebasket__" alt="Screen recording: a file is tossed into the wastebasket with a SWISH!, then the basket is tipped over and stood back up"><br>
<b>Wastebasket</b><br>
Toss a file in: SWISH! Tip the basket over, stand it up. Hidden, not deleted.
</td>
<td width="50%" valign="top">
<b>Also in the hiding places</b><br>
Drawers, cubby and phone list their contents, move them or take them all out from their menus · fullness shows (an overfull drawer rests ajar, then jams) · nothing comes out by itself.<br>
<a href="#where-things-hide">Where things hide</a>
</td>
</tr>
</table>

### The desk mat

<table>
<tr>
<td width="50%" valign="top">
<img src="docs/media/feat-mat.gif" width="__W_mat__" alt="Screen recording: files dropped on the desk mat slide under it and leave bumps; the mat's edge is peeled back and a file is taken out"><br>
<b>Sweep it under the mat</b><br>
Drop files on the mat: they slide under and leave bumps. Peel the edge back to take one.
</td>
<td width="50%" valign="top">
<img src="docs/media/feat-mat-moves.gif" width="__W_mat-moves__" alt="Screen recording: the desk mat is carried and creases; with Option held it is turned and resized while the keyboard on it turns too; it is folded, then tugged smooth"><br>
<b>A real piece of cloth</b><br>
Carry it and it creases. ⌥-drag to turn or resize it (the keyboard turns with it), fold it, tug it smooth.
</td>
</tr>
<tr>
<td width="50%" valign="top">
<img src="docs/media/feat-brush.gif" width="__W_brush__" alt="Screen recording: the brush pushes piles of files under the desk mat, then a sideways two-finger scroll sweeps more under"><br>
<b>Brush and scroll-broom</b><br>
Push piles under the mat with the brush, or with a sideways two-finger scroll over the desk.
</td>
<td width="50%" valign="top">
<b>Also on the mat</b><br>
Peek Under · List Items Under Mat · Rotate, Size, Smooth, Reset Mat · a Flat mode that keeps the bumps without lifting.<br>
<a href="#gestures">Gestures</a>
</td>
</tr>
</table>

### Physics

<table>
<tr>
<td width="50%" valign="top">
<img src="docs/media/feat-piles.gif" width="__W_piles__" alt="Screen recording: files set down on the desk form piles; one is flung off the edge onto the floor; the desk is knocked and everything on it wobbles"><br>
<b>Piles, the floor and knocks</b><br>
Files set on the desk pile up. Fling one onto the floor; double-click the desk's front edge to knock it.
</td>
<td width="50%" valign="top">
<img src="docs/media/feat-clear-desk.gif" width="__W_clear-desk__" alt="Screen recording: Clear the Desk turns the monitor off, flips the phone, shuts the drawers and sweeps every pile under the mat, then TIDY! appears; one Command-Z puts it all back"><br>
<b>Clear the Desk</b><br>
One menu item hides everything: TIDY! One ⌘Z puts it all back.
</td>
</tr>
</table>

### Light

<table>
<tr>
<td width="50%" valign="top">
<img src="docs/media/feat-lights.gif" width="__W_lights__" alt="Screen recording: the lights are set to Night, the room light switch on the wall is flipped off for Lamp Only, and the desk lamp is clicked"><br>
<b>Night and Lamp Only</b><br>
Set the lights to Night, flip the room switch for Lamp Only, click the desk lamp.
</td>
<td width="50%" valign="top">
<b>Also in the light</b><br>
Auto follows the clock through day, dusk and night · drag the clock's minute hand to preview another hour · in Lamp Only, files in the dark are silhouettes you cannot pick.<br>
<a href="#everything-it-does">Everything it does</a>
</td>
</tr>
</table>

### Files and finding

<table>
<tr>
<td width="50%" valign="top">
<img src="docs/media/feat-find.gif" width="__W_find__" alt="Screen recording: Command-F opens the Find Item window, which lists every file and where it is; Show on Desk opens the hiding place and points the file out"><br>
<b>Find Item…</b><br>
⌘F lists every file and where it hides. Show on Desk opens the hiding place and points the file out.
</td>
<td width="50%" valign="top">
<img src="docs/media/feat-trash.gif" width="__W_trash__" alt="Screen recording: Move to Trash sends a file to the macOS Trash, and Command-Z brings it back to the same spot on the desk"><br>
<b>Move to Trash, and back</b><br>
Move to Trash sends a file to the macOS Trash; ⌘Z brings it back to the same spot.
</td>
</tr>
<tr>
<td width="50%" valign="top">
<img src="docs/media/feat-drives.gif" width="__W_drives__" alt="Screen recording: a USB stick is plugged in and appears in the drive hub on the desk, then it is ejected from its menu"><br>
<b>Drive hub</b><br>
A USB stick plugs into the hub on the desk. Eject it from its menu.
</td>
<td width="50%" valign="top">
<b>Also with files</b><br>
Drop files in from Finder · drag them out to other apps · Empty Wastebasket… lists the names first · every action is logged.<br>
<a href="#your-files-are-safe">Your files are safe</a>
</td>
</tr>
</table>

### System

<table>
<tr>
<td width="50%" valign="top">
<img src="docs/media/feat-peek.gif" width="__W_peek__" alt="Screen recording: Peek Desk floats the desk above the open windows for a moment"><br>
<b>Peek Desk</b><br>
Peek Desk floats the desk over your windows for a moment.
</td>
<td width="50%" valign="top">
<b>Also in the system</b><br>
Pause Desk · matching walls on other displays · pauses for full-screen apps, sleep and (optionally) battery · a menu bar icon, no Dock icon.<br>
<a href="#settings">Settings</a>
</td>
</tr>
</table>

## Everything it does

The [Where things hide](#where-things-hide) and [Gestures](#gestures) tables below show how to use each part.

### On the monitor

- **Your Desktop, live.** The Desktop folder (or another folder you choose) is mirrored as it changes: new files
  print in, renamed files keep their place, removed files poof. Files are known by identity, so renames and
  safe-saves keep their spot, and a file that comes back within 7 days returns to where it was.
- **Real icons, in pixels.** Each file shows its own Finder icon, or a Quick Look thumbnail for images, videos and
  PDFs, pixelated into the desk's colours. A hand-drawn icon for its kind shows until the real one is ready.
  iCloud files that are not downloaded stay that way: they get the kind icon and are never fetched.
- **Names, Korean included.** Names are drawn in the Galmuri9 pixel font, Korean included. Names stored decomposed
  (common for Korean file names on a Mac) are composed (NFC) first, so Hangul draws whole; emoji are drawn in pixels.
- **Pages and inputs.** 45 files per page (9 × 5), each page an input: HDMI 1, 2… added as the desktop fills.
  Change page with INPUT, a two-finger scroll on the screen or the Input menu (which shows each page's count); rest
  a carried file on INPUT to flip to the next one.
- **AV.** An input that is always empty: a second way to hide everything, with a bouncing NO SIGNAL logo that settles
  after 10 seconds.
- **Power.** ⏻ collapses the picture like an old CRT and hides every page. Files that arrive while it is off light
  an amber LED and a "+N" badge.
- **Clean Up By** name, kind or date added, from the monitor's right-click menu.
- **Selection and keys.** Click, ⌘-click, drag a box on the empty screen or press ⌘A; arrow keys move the selection;
  Space opens Quick Look, ⌘O opens, ⌘C copies. Drag a file to another cell (a taken cell swaps), or carry several.
- **First run.** A welcome window explains the desk, and the monitor asks you to press ⏻ before the Desktop is read;
  it offers Open Settings and Choose Folder… if access was refused (see [First run](#first-run)).

### Hiding places

- **Riser drawers** (2). Each takes 8 files; past that it rests ajar (contents still hidden), and at 14 it jams and
  bonks. Drop a file on a closed drawer and it chomps it; click or drag the handle; scroll over it to peek; hover a
  carried file over it to spring it open; shut it hard and it slams (a slam knocks the desk).
- **Cubby.** 12 files as dim silhouettes, names on hover: it only half hides.
- **Filing cabinet** (3 drawers: 8, 12 and 20 files, jamming 6 past that). Only one drawer opens at a time; the bottom
  one files things under folder tabs coloured by kind. If the chair stands in front, a drawer opens only a crack and
  bumps the chair, which rolls aside so the next pull works.
- **Chair.** Drag it and it rolls; let go fast and it coasts and spins.
- **Phone.** Up to 6 files as mini app icons. Click to turn it face down (contents hidden, drops bonk); face up, it
  glows at night.
- **Pen cup.** Up to 6 pens, capped in their kind's colour (a seventh bonks); pull the last pen out. Drag the cup
  around the desk and it shoves piles aside. Flick it with three or more pens in it (or pick Tip Over) and it tips,
  spilling the pens as piles; click it to stand it up.
- **Wastebasket.** Up to 24 crumpled balls, heaped above the rim from the 11th. Drop or toss files in (SWISH! on a
  clean pass, rim bounces, misses land on the floor), dig the top ball out, or drag the rim sideways to tip it over
  (the balls uncrumple onto the floor). It never deletes: Empty Wastebasket… moves the contents to the macOS
  Trash after a confirmation that lists them.
- **Menus.** The drawers have Open Drawer or Close Drawer and the phone Turn Face Up or Down; the drawers, the cubby
  and the phone all have List Contents (pick a name to send it to the monitor), Move Contents to and Take All Out; the
  pen cup and the wastebasket
  have Tip Over and Stand Up. Any file's Move to ▸ sends it straight to a hiding place.
- **Nothing comes out by itself.** Knocks, slams and overfilling never empty a container; overfilling bonks.

### The desk mat

- **Cloth.** A simulated cloth mat, felt on top and rubber underneath, with the keyboard lying on it: the keyboard
  weighs it down and turns with it.
- **Under the mat.** Files dropped on it slide under and leave bumps that grow with the stack (piles close together
  share one). Whatever the cloth covers is hidden, so sliding the mat over loose piles hides them too.
- **Peel and fold.** Drag an edge or corner inward to lift it: the piles underneath stand up and can be taken. Hold
  still before letting go and it stays up a moment; pull it past the middle and it stays folded (double-click the
  flap to unfold it).
- **Carry and creases.** Drag the mat to carry it; fast carries leave creases that stay, even after a relaunch. Tug a
  corner outward, double-click an edge or pick Smooth Desk Mat to pull them flat.
- **Turn and resize.** ⌥-drag a corner to resize and turn it (⇧ snaps to 15°), ⌥-drag the middle to slide it without
  creases, or use its menu: Rotate (±15°, Straighten), Size (Small, Medium, Large), Reset Mat. It only turns or
  grows as far as it fits on the desk.
- **Peek Under** turns the mat back over the pile nearest the click for a moment; **List Items Under Mat ▸** a name
  puts that file back on the monitor.
- **Flat mode** (Settings ▸ Desk mat, or Reduce Motion): the bumps and the hiding stay, but the mat does not lift.
- **Brush.** Drag it to push piles under the mat, or off the desk's edge; double-click sends it home. A sideways
  two-finger scroll over the desk is the scroll-broom, an invisible brush.

### Physics

- **Desk piles.** Files set down on the desk form piles (with a count tag) that slide, bump and stack.
- **Flings.** Let go of a file while moving fast and it flies in an arc: off the desk's edge onto the floor, or into
  the wastebasket. Files on the floor stay visible and can be picked up.
- **Knock.** Double-click the desk's front edge: piles hop, the cup, monitor and phone wobble, the mat ripples and
  ajar drawers snap shut. No file changes place.
- **Clear the Desk.** One action: the monitor goes off, the phone turns over, the drawers shut, and the brush sweeps
  every loose pile and floor file under the mat. "TIDY!" One ⌘Z puts everything back.
- **Small things.** Poke the plant and it jiggles; click a key and it presses (it never shows your real typing).
- **Reduce Motion.** Tosses land at once with a puff, nothing shakes, and the CRT fades instead of collapsing.

### Light

- **Time of day.** Lights ▸ Auto follows the clock through day, dusk and night, with the sky in the window (drifting
  clouds; stars and a moon at night). Day, Night and Lamp Only fix it.
- **Room light and desk lamp.** Click the wall switch or the lamp. The lamp throws a warm pool across the desk; the
  monitor and a face-up phone cast a cool glow.
- **Lamp Only.** Room light off, lamp on: only the lamp's pool and the screens' glow light anything. Files in the
  dark are silhouettes you cannot pick, so the lamp works like a flashlight.
- **Clock preview.** Drag the clock's minute hand to see another time of day; let go and it springs back (a preview
  past midnight turns the calendar).

### Files and finding

- **Find Item…** (⌘F). Every file and where it is, with search. Open, Quick Look, Show in Finder, Take Out, and
  **Show on Desk**, which opens whatever hides the file (powers the monitor on, switches the page, opens the drawer,
  rolls the chair aside, turns the phone up or peeks under the mat) and points it out.
- **Take Everything Out.** Every file goes back to the monitor; one ⌘Z undoes it.
- **Everyday commands.** Open (double-click, ⌘O), Quick Look (Space), Show in Finder, Copy (⌘C), Open Desktop Folder
  in Finder.
- **File actions, only when asked.** Move to Trash (from the menu; no keyboard shortcut), Empty Wastebasket…,
  dropping files in from Finder (moved into the folder, or copied from another disk or with ⌥; a name that is taken
  gets " 2"), dragging files out to other apps, Mail or the Dock's Trash, and Eject. Locked files are never moved in.
- **Undo.** ⌘Z undoes the last 20 steps (⌘⇧Z redoes layout steps), Deskterior's own file actions included: trashed
  files come back to the same spot, dropped files go back where they came from. Eject and drags out to other apps
  cannot be undone. Every file action is written to `operations.log`.
- **Drive hub.** Mounted drives plug into the hub as USB sticks, disks or servers (four slots, then a "+n" tag).
  Double-click to open; Open, Show in Finder and Eject from the menu. Files dropped on a drive bonk: copying to
  drives is Finder's job.
- **Safety first.** Hiding is layout only, and nothing is ever deleted or overwritten: see
  [Your files are safe](#your-files-are-safe).

### System

- **Covers Finder, changes nothing.** The desk is a window just above Finder's desktop icons; Finder's settings are
  only read. Quit Deskterior or use Pause Desk and your desktop is back.
- **Menu bar icon and wall menu.** No Dock icon: the desk's commands are in the menu bar icon and in a right-click
  on the bare wall, and each object has its own right-click menu.
- **Every display.** The art is drawn at a whole-number scale (Chunky, Normal or Fine pixels) and the room extends
  to fill any screen; tall and portrait displays get a ceiling with beams, a shelf, prints and hanging plants. Other
  displays can get a matching wall (files dropped on one go to the monitor), and Settings picks the desk's display.
- **Peek Desk and Pause Desk.** Peek floats the desk over your windows (× Done or Esc; optional ⌃⌥⌘D shortcut, off by
  default). Pause puts it away and shows Finder's desktop until you resume.
- **Stays out of the way.** The desk pauses under full-screen apps, during display sleep, screen lock and user
  switching, and optionally on battery (a still frame until you use it); it stops drawing while nothing moves, and
  Low Power Mode caps it at 30 frames a second. It shifts the room a little to keep desktop widgets off the monitor
  and drawers.
- **Remembers your desk.** The layout is saved as you go, with hourly, daily and weekly backups; each mirrored folder
  keeps its own layout, and a damaged layout file is repaired or replaced by a backup.
- **[Settings](#settings).** Lights, Reduce motion, Desk mat, Pixel size, Mirrored folder, Peek Desk shortcut,
  Launch at login, Pause on battery, displays, Language, Leftover copies (after an interrupted copy), About & Credits.
- **[Safe Mode](#safe-mode).** Hold ⌥ at launch to start normally, reset the layout (kept as a backup) or open the
  state folder.
- **Accessibility.** VoiceOver lists every file and control and reads out messages; Find Item… reaches every file;
  Reduce Motion (following the system by default) replaces shakes, flickers and flights.
- **Languages.** English and Korean menus, cards, messages, windows and Settings. Language ▸ System picks the first of
  your preferred languages that Deskterior speaks; any other language shows English.
- **Private.** No network access at all, no analytics, no telemetry, no updater. The one permission it needs is your
  Desktop folder.
- **Packaging.** One universal app for Apple silicon and Intel on macOS 14 and later, built with the Command Line
  Tools (no Xcode). Releases are ad-hoc signed (not notarized) and come with a SHA-256 checksum and a build
  provenance attestation; CI runs over 1,000 tests.

## Where things hide

<img src="docs/media/hiding.png" width="600" alt="The hiding places in use by day, close up: an open riser drawer with three photos, a note in the cubby, two pens in the pen cup, the phone face up with three app icons, and the filing cabinet's bottom drawer open on its folder tabs">

| Place | How you hide | How you get it back |
|---|---|---|
| **Monitor** ⏻ / **INPUT** / **AV** | Press the power button: the picture collapses like an old CRT and every file is hidden. Files that arrive while it is off light an amber LED and a "+N" badge. INPUT steps through pages (HDMI 1, 2…, one per 45 files) and AV, a page that is always empty. | Press power again, or pick another input. |
| **Riser drawers** (2) and **cubby** | Drop a file on a closed drawer and it opens, takes it and shuts. An overfull drawer rests ajar; a jammed one refuses more (BONK). The cubby only half hides: you see dim silhouettes, names on hover. | Click the handle, drag the handle, or scroll over a closed drawer to peek. Drag the small icons back out. |
| **Filing cabinet** (3 drawers) and **chair** | The same as the riser drawers; the bottom drawer files things under coloured folder tabs. Only one drawer opens at a time. | If the chair is in the way a drawer only opens a crack: the chair rolls aside and the next pull works. |
| **Phone stand** | Drop files on the face-up phone; they become app icons. Click the phone to turn it face down (a face-up phone glows at night, like a real one). | Click it again, or Turn Face Up from its menu. |
| **Pen cup** | Drop a file in and it becomes a pen; the cap colour tells its kind. | Drag the last pen out of the cup. A quick flick of the cup with three or more pens in it tips it over, and the pens spill onto the desk; click it to stand it up. |
| **Wastebasket** | Drop or toss a file in. It is crumpled up, **not deleted**: "hidden, not deleted". | Drag the top ball out, or drag the rim sideways to tip the basket over. *Empty Wastebasket…* moves its contents to the macOS Trash, after a confirmation that lists them. |
| **Desk mat** and **brush** | Drop a file on the mat and it slides under, leaving a bump; taller stacks make bigger bumps. Push piles in with the brush, or with a sideways two-finger scroll over the desk. | Peel an edge or corner back: the piles underneath stand up and can be taken. Or right-click ▸ Peek Under. With the Flat mat (or Reduce Motion) the mat does not lift: right-click it ▸ List Items Under Mat ▸ a name puts that file back on the monitor, and Find Item… (⌘F) works too. |
| **Lamp** and **Lamp Only** | At night, switch the room light off and keep the desk lamp on: only the lamp's pool, the monitor's glow and the phone's glow light anything. Files in the dark are silhouettes: no names, no clicks. | Files in the lamp's pool or the monitor's or face-up phone's glow can still be picked; switch the room light back on, or pick Lights ▸ Auto. |
| **Drive hub** | Deskterior covers Finder's drive icons too, so mounted drives plug into the hub on the desk. | Double-click to open; Eject from the drive's menu. |
| **Clear the Desk** | One menu item: the monitor goes off, the phone turns over, drawers shut and the brush sweeps every loose pile under the mat. "TIDY!" | One ⌘Z puts everything back exactly. |
| **Find Item…** (⌘F) | — | Lists every file and where it is (with search). **Show on Desk** opens whatever hides it and points the file out; **Take Out** brings it back to the monitor. **Take Everything Out** (menu) brings them all back. |
| **Peek Desk** / **Pause Desk** | — | Peek Desk lifts the desk above your windows for a moment (× Done or Esc to go back; optional shortcut ⌃⌥⌘D). Pause Desk puts it away and shows Finder's own desktop until you resume. |

Nothing comes out of hiding by itself. Knocks, slams and overfilling never empty a container; a hidden file shows
again only when you open its container, peel or move the mat, flip the phone, tip the cup or basket, switch input, use
a menu, Find Item…, Show on Desk or Take Everything Out.

## Gestures

| Gesture | What it does |
|---|---|
| **Click** | Selects a file (⌘-click adds or removes one; drag on the empty screen to select several; ⌘A selects the page). Also flips switches and presses buttons: the power button, INPUT, the lamp, the room light switch, a drawer handle, the phone. |
| **Double-click** | Opens a file. On the desk's front edge (the apron): **knocks the desk**: things wobble, but no file changes place. On the mat's edge: smooths it. On a folded flap: unfolds it. On the brush: sends it home. |
| **Drag** | Carries files (several at once if several are selected) to the monitor, a hiding place, the desk or the floor. Hovering a carried file over a closed drawer for a moment opens it. Drags the brush, the chair (it rolls), the pen cup, drawer handles, the clock's minute hand (previews another time of day). |
| **Flick / toss** | Let go of a carried file while moving fast and it flies: off the desk's edge onto the floor, or into the wastebasket (SWISH!). A fast flick of the pen cup (with three or more pens in it) tips it over. |
| **Drag the mat** | Carries the whole mat (and the keyboard on it); fast carries leave creases. |
| **Peel** | Drag an edge or corner of the mat inward: it lifts and the piles under it stand up so you can take one. Hold still a moment before letting go and it stays up briefly; pull it past the middle and it stays folded. |
| **Tug** | Drag a corner of the mat outward to pull its creases flat (or double-click an edge, or Smooth Desk Mat). |
| **⌥ (Option)** | Over the mat, shows its handles: ⌥-drag a corner to resize and turn it (⇧ snaps to 15°); ⌥-drag the middle to slide it without creases. |
| **Two-finger scroll** | Sideways over the desk: the **scroll-broom** sweeps piles under the mat. Over the screen: changes page. Over a closed drawer: peeks inside. |
| **Right-click** | A menu for everything: files (Open, Quick Look, Show in Finder, Copy, **Move to ▸** a monitor page or a drawer, the cubby, the phone, the pen cup or the wastebasket, Move to Trash), the monitor, each container, the mat (Peek Under, Smooth, Rotate, Size, List Items Under Mat ▸), drives. Right-click the bare wall for the same menu as the menu bar icon. |
| **Keys** (after clicking the desk) | Space: Quick Look · ⌘O / ⌘↓: open · arrows: move the selection · ⌘A · ⌘C: copy · ⌘F: Find Item… · ⌘Z / ⌘⇧Z: undo and redo · Esc: cancel a carry or end a peek. There is no delete key. |

<img src="docs/media/mat-peel.png" width="576" alt="The desk around the mat: its front edge peeled back, rubber side up, and a pile of three files standing where it lay">

Deskterior has no Dock icon. Its menu is the small pixel icon in the menu bar, or a right-click on the bare wall
(handy if you hide menu bar items).

## Your files are safe

- **Hiding is layout only.** A file in a drawer, under the mat or in the wastebasket is still in your Desktop
  folder, untouched. Finder, Spotlight and every other app see it exactly as before. Deskterior only remembers
  where you put it.
- **Files change only when you explicitly ask**, through one of these actions:
  - **Move to Trash** from a file's right-click menu (no keyboard shortcut);
  - **Empty Wastebasket…**, after a confirmation that lists the names;
  - dropping files from Finder onto the desk (moved into your Desktop folder; copied when they come from another
    disk, or when you hold ⌥);
  - dragging a file out to another app (that app does what it would do with a drag from Finder; dropped on the
    Dock's Trash, Deskterior moves it to the Trash itself if the Dock has not);
  - **Eject** from a drive's menu;
  - **Move to Trash** under Settings ▸ Leftover copies, which appears only after an interrupted copy (below).
- **Trash, never delete.** Deskterior moves files to the macOS Trash and never deletes anything. It never
  overwrites a file: a name that is taken gets " 2", " 3"…
- **Locked files stay put.** A locked file dropped onto the desk is not moved into your Desktop folder (hold ⌥ to
  copy it instead). If a copy is cut short, for example by quitting mid-copy, it can leave a hidden
  `.deskterior-partial-…` folder in your Desktop folder (only when macOS offers no temporary folder on that disk):
  Deskterior tells you once each launch while it is there and lists it under Settings ▸ Leftover copies (Show in
  Finder, Move to Trash), but never removes it by itself.
- **Undo.** ⌘Z undoes layout changes and Deskterior's own file actions (Move to Trash, Empty Wastebasket…, drops
  onto the desk): trashed files come back to the same spot on the desk, dropped files go back where they came from
  (copies go to the Trash). Eject and drags out to other apps cannot be undone, except a drag onto the Dock's Trash
  that Deskterior carried out. If macOS will not let Deskterior reach the Trash, it says so and you can use Finder's
  Put Back.
- **Finder is left alone.** The desk is a window just above Finder's desktop icons: it covers them, it does not hide
  them by changing any Finder setting (Finder's settings are only read). Quit Deskterior, or use Pause Desk, and your
  normal desktop is back.
- **Private.** No network access at all, no analytics, no telemetry. The one permission it needs is your Desktop
  folder (macOS may also ask once when you drop in files from Downloads, Documents or another drive); no
  Accessibility, Screen Recording or Input Monitoring. Every file action is written to `operations.log` in its state
  folder.

## Install

Deskterior is free and is not notarized by Apple (that needs a paid developer account). The release is ad-hoc
signed, so macOS blocks the first launch of every downloaded version once. That is expected.

1. Download **Deskterior-*version*.zip** from the [latest release](../../releases/latest) and double-click it to unzip.
2. **Move `Deskterior.app` to your Applications folder first.** Opened straight from Downloads, macOS runs it from a
   hidden read-only copy (App Translocation), where it can forget its permissions; Deskterior notices and asks you to
   move it.
3. Open Deskterior.
   - **macOS 15 Sequoia and later:** macOS says *"Deskterior" Not Opened*. Click **Done** (not Move to Trash). Open
     **System Settings ▸ Privacy & Security**, scroll down to **Security** and click **Open Anyway** next to the
     message about Deskterior (it is there for about an hour), then confirm with **Open Anyway** and your password or
     Touch ID. Control-click ▸ Open no longer skips this step.
   - **macOS 14 Sonoma:** Control-click (or right-click) the app, choose **Open**, then **Open** again. The Open
     Anyway button in Privacy & Security works too.
4. Do this again after each update. Because the build is ad-hoc signed, macOS may also ask for Desktop folder access
   again after an update.

To check a download, open Terminal in the folder you downloaded both files to (usually: `cd ~/Downloads`) and compare
it with the `.sha256` file from the same release, or verify that the release workflow built it from this repository
(with the GitHub CLI; replace OWNER with the account in this page's URL):

```sh
shasum -a 256 -c Deskterior-0.1.0.zip.sha256
gh attestation verify Deskterior-0.1.0.zip --repo OWNER/deskterior
```

## First run

1. A welcome window explains the desk. The monitor shows **PRESS ⏻ TO CONNECT DESKTOP**.
2. Click the monitor's power button ⏻. macOS asks whether Deskterior may access the files in your Desktop folder:
   click **Allow**. Your files appear on the monitor. Deskterior only asks after you press ⏻.
3. If you clicked **Don't Allow**, the monitor shows **NO SIGNAL** with two buttons: **Open Settings** (System
   Settings ▸ Privacy & Security ▸ Files & Folders, where you can turn Desktop on for Deskterior) and
   **Choose Folder…** (pick your Desktop folder; choosing it gives access).
4. If Finder is set not to show items on the desktop, the monitor first asks **Show them on the desk anyway?**
   (Show / Keep Hidden).
5. With more than one display, the welcome window asks whether to cover the other displays with a matching wall.
   Files dropped on a wall go to the monitor.

<img src="docs/media/desk.png" width="588" alt="The desk by day, connected: the Desktop's files on the monitor, the mat and keyboard, the riser, phone stand, pen cup and drive hub on the desk, the chair, filing cabinet and wastebasket below">

## Settings

Menu bar icon ▸ **Settings…**

| Setting | Choices | Default |
|---|---|---|
| Lights | Auto (follows the time of day), Day, Night, Lamp Only | Auto |
| Reduce motion | Follow System, Always, Never: no shakes or flickers, the CRT fades instead of collapsing, the mat lies flat, tossed files land without flying, the AV logo holds still | Follow System |
| Desk mat | Cloth (lifts, folds, creases) or Flat (bumps only) | Cloth |
| Pixel size | Chunky, Normal, Fine | Normal |
| Mirrored folder | Your Desktop, or another folder (Choose Folder… / Use Desktop) | Desktop |
| Peek Desk shortcut ⌃⌥⌘D | On / off (needs no Accessibility permission) | **Off** |
| Launch at login | On / off | **Off** |
| Pause the desk on battery power | On / off (a still frame until you use it) | Off |
| Desk display, cover other displays | Shown with more than one display | Menu bar display |
| Language | System, English, 한국어 | System |

If the chosen folder is missing at launch (renamed, deleted, or on a drive that is not mounted yet), the desk shows
your Desktop for that launch and Settings says so; the choice is kept for the next launch.

Settings ▸ **About & Credits…** shows the version and credits.

<img src="docs/media/lamp-only.png" width="588" alt="Lamp Only at night: the room is dark blue, the desk lamp throws a warm pool across the desk, and the monitor and the phone glow">

## Safe Mode

Hold **⌥ (Option)** while Deskterior starts. A Safe Mode window appears before the desk does, and nothing has been
touched yet:

- **Start Normally**;
- **Reset Layout…**: every file goes back to the monitor; the old layout is kept as a backup in the state folder
  (no file is deleted);
- **Open State Folder**;
- **Quit**.

If the desk ever stops responding, `killall Deskterior` in Terminal removes it at once and your normal desktop is
back; your files were never touched.

## Uninstall

1. If you turned on **Launch at login**, turn it off in Settings.
2. Quit Deskterior (menu bar icon ▸ Quit Deskterior).
3. Optionally remove its layout, icon cache, settings and privacy permissions. They are named after the app's
   bundle identifier, so read it before deleting the app. Paste the whole block into Terminal at once:

   ```sh
   ID="$(defaults read /Applications/Deskterior.app/Contents/Info CFBundleIdentifier)" &&
   case "$ID" in io.github.*.deskterior | io.github.deskterior.dev)
     rm -rf ~/Library/Application\ Support/"$ID" ~/Library/Caches/"$ID"
     defaults delete "$ID"
     tccutil reset All "$ID"
   esac
   ```

   If the first line prints an error, stop: Deskterior is not in /Applications. The block removes the layout, its
   backups and `operations.log` (Application Support), the icon cache (Caches), the settings (`defaults`) and the
   Desktop folder permission (`tccutil`), and does nothing unless the identifier is Deskterior's.

4. Move `Deskterior.app` to the Trash.

## Build from source

You need macOS 15.6 or later with the Command Line Tools for Xcode 26 (Swift 6.2; `xcode-select --install`). Xcode
is not needed. The app you build runs on macOS 14 and later. Then, in a clone of this repository:

| Command | Does |
|---|---|
| `make build` | `swift build` |
| `make test` | the test suites (`scripts/swift-test.sh`) |
| `make lint` | the file-safety lint (`scripts/check-file-safety.sh`) |
| `make app` | `build/Deskterior.app` for this Mac's processor, ad-hoc signed (`VERSION=0.1.0` sets the version) |
| `make universal` | the same for Apple silicon and Intel in one app |
| `make install` | `make app`, then copies the app to /Applications |
| `make run` | runs the desk in a window on a fresh scratch folder of sample files |
| `make gif` | records `Demos/hero.json` and rebuilds `docs/media` (needs ffmpeg) |

An app you built yourself is not quarantined, so Gatekeeper does not stop it. The bundle identifier comes from your
clone's GitHub remote (`io.github.OWNER.deskterior`, as in the release); without one it is the development identifier
`io.github.deskterior.dev`. Signing with a free self-signed certificate keeps the Desktop permission across rebuilds:
see [docs/SIGNING.md](docs/SIGNING.md).

Development runs never touch your real Desktop: they need a scratch folder, and the app refuses (exit 64) the real
Desktop or anything inside it. Scripted demos run headless on a fresh fixture folder and write PNGs (this one to
`.build/demo-out/10-clear-desk`); the last two lines are what `make run` does:

```sh
scripts/run-demo.sh 10-clear-desk
FIX="$(mktemp -d)"; scripts/make-fixture-desktop.sh "$FIX/desk"
swift run Deskterior --windowed --desktop-folder "$FIX/desk" --state-dir "$FIX/state"
```

More: [docs/DESIGN.md](docs/DESIGN.md) (the design), [docs/DEMOS.md](docs/DEMOS.md) (the demo scripts),
[docs/SPIKES.md](docs/SPIKES.md) (platform checks), [CHANGELOG.md](CHANGELOG.md).

## Requirements

- macOS 14 Sonoma or later.
- A Mac with Apple silicon or Intel (one universal app).
- Permission to read your Desktop folder (asked when you first press ⏻).

## Known limitations

- **Not notarized.** Every downloaded version needs the Open Anyway step above, and after an update macOS may ask
  for Desktop access again (the ad-hoc signature changes with every build).
- **Tested on one Mac** (a MacBook Air M2 on macOS 26). Deskterior is built for macOS 14 and 15 too, but it has
  never been run on them, and the Intel half of the app has not been run on an Intel Mac.
- **Some platform behaviour needs a human check** that automation cannot do: clicks and hover while another app is
  in front, Quick Look and ⌘Z after clicking the desk, pausing under full-screen apps, drags out to Finder, Mail and
  the Dock's Trash, undoing a trash through the real Trash, and drops from Downloads. See
  [docs/SPIKES.md](docs/SPIKES.md).
- Clicking the wallpaper to reveal the desktop (macOS 14 and later) does not work over the desk; use Show Desktop,
  Peek Desk or Pause Desk.
- Desktop widgets stay above the desk; Deskterior shifts the room a little to keep them off the monitor and drawers
  when it can.
- In scaled display modes the pixels are slightly soft.
- A mirrored folder on an **exFAT** drive cannot take drops, and ⌘Z cannot bring trashed files back into it: exFAT
  does not support the no-overwrite rename Deskterior uses for every move, so it refuses and changes nothing. FAT32
  and APFS work.
- Finder's own desktop is still there underneath. If Finder had icons selected on the desktop before Deskterior
  covered it, ⌘⌫ in Finder can still move them to the Trash (Finder's Undo puts them back).
- Parts of the scene stay in English in v0.1, also with the Korean language setting: its tooltips, VoiceOver's names
  for the desk's objects, the AV input's NO SIGNAL logo, BONK, SWISH! and TIDY!.

## Credits

- Font: [Galmuri9](https://github.com/quiple/galmuri) by Lee Minseo (quiple), SIL Open Font License 1.1, bundled
  unmodified with its license.
- Palette: [Apollo](https://lospec.com/palette-list/apollo) by AdamCYounis. Every pixel on the desk is one of its 46
  colours.
- Deskterior is an independent project inspired by Terkel Gjervig's desktop-rug prototype *Desktop Cleaning*
  (desktop.cleaning). It is not affiliated with or endorsed by him or GitHub, and uses none of its code, name, art or
  branding.

## License

The code is MIT licensed: see [LICENSE](LICENSE). Bundled third-party material keeps its own license: see
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
