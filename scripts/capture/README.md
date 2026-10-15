# Real-screen captures for the README

The README's GIFs (`docs/media/hero.gif` and `docs/media/feat-*.gif`) are real screen recordings: the app runs in desk
mode over the real macOS desktop, with a real Finder window and the real cursor. Synthetic input, posted as CGEvents,
drives each scene. This folder holds the tooling. It takes over the screen and the mouse while it runs, so only run it
on a Mac nobody is using.

**Requirements:**
- The terminal needs **Accessibility** permission (to post input and hide apps) and **Screen Recording** permission (for
  ffmpeg).
- ffmpeg.
- Python 3 with numpy (for `bin/gifcut.py`).
- The tools assume a 1470×956 pt @2x display (the art grid is 5 device px per art px). Re-measure the scene coordinates
  on any other display.

**Never your real Desktop.** The desk mirrors a showcase folder that `mkshowcase.sh` builds. It holds Finder aliases to
apps (Claude, ChatGPT, Safari, Books, Weather, Calendar, Maps, Photos, when installed) and generated files. Apps are
dragged in from a scratch `Apps` folder of copies, with ⌥ held so they are copied. Nothing outside the work folder is
changed. The trash scene's file is put back with ⌘Z.

## Setup

Run everything from a work folder outside the repository: copy this folder there. Then:

1. Build a capture bundle with its own settings domain, so your installed copy is never touched, and copy it into the
   work folder as `Deskterior.app`:
   `BUNDLE_ID=io.github.deskterior.capture scripts/build-app.sh`
2. Compile the tools:
   `for f in tools/*.swift; do swiftc -O "$f" -o "tools/$(basename "$f" .swift)"; done`
3. Copy a few small apps (Calculator, Notes, Music) into `Apps/` with `cp -R`.
4. Once, set the capture app's Settings ▸ Language to English (desk mode keeps its own settings; `--language` only
   applies to development modes). The scripts never write preferences themselves (the file-safety lint).
5. `./reset.sh` quits the capture app and rebuilds the showcase. It then:
   - relaunches the app in desk mode at 16:00 in English;
   - presses ⏻ to connect;
   - places the Finder `Apps` window with its sidebar hidden;
   - hides other apps.

## A take

- `./take.sh NAME N full` records `scenes/NAME.json` over the whole room into `takes/NAME-N.mkv`. It uses ffmpeg's
  avfoundation device, a lossless bgr0 capture art-aligned at device y 69, and an area downscale to 2 px per art px.
- For a close-up, pass `W:H:X:Y` in device px instead of `full`. Keep X ≡ 0 and Y ≡ 4 (mod 5) so art pixels stay
  whole; close-ups are scaled to 4 px per art px.
- The director (`tools/director run SCENE.json`) aborts if the cursor moves on its own (someone touched the mouse), or
  if a click would land on a window that is not Deskterior's or Finder's.
- `bin/gifcut.py IN.mkv OUT.gif --seg START:END[:SPEED] ... [--crop W:H:X:Y] [--room]` cuts and speeds up segments.
  It builds the GIF with a palette from the clip and no dithering.
- `--room` covers the top-left corner of the room with the app's own rendering, if desktop widgets sit there. The
  plates come from `plates.json`, rendered headless with `scripts/run-demo.sh --scale 1`, cropped at art row 14 and
  scaled ×2 nearest. The patch is matched per lighting phase and colour-corrected row by row against the live wall.

## Afterwards

- Quit the capture app (`tools/quitapp Deskterior`).
- Unhide the hidden apps: `tools/director unhide hidden-all.txt`.
- Show Finder's sidebar again (`tools/menupress Finder View "Show Sidebar"`; use the menu titles of your macOS
  language).
- Detach any disk image you attached.
