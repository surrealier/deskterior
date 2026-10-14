# Deskterior — design spec (v0.1)

> This document is the judged + synthesized design produced before implementation
> (research → 3 competing designs → product & engineering judges → synthesis).
> The **Errata** section below overrides anything it contradicts further down.

## Errata (applied after review; these win)

1. **No visible main menu.** An `.accessory` / `LSUIElement` app has no menu bar
   (`NSRunningApplication.h`: "does not appear in the Dock and does not have a menu bar").
   The "Main menu (shown while active)" in §4.5 is dropped. Keys are handled in
   `DeskView.keyDown` / `performKeyEquivalent`; a hidden `NSApp.mainMenu` with standard Edit
   items (Undo/Redo/Copy/Select All) is kept only so key equivalents route. Every command lives in
   the status item, the bare-wall right-click menu, and object context menus.
2. **Bundle id / owner** is `io.github.<github-login>.deskterior`, where the login is read with
   `gh api user -q .login` after `gh auth login`. Frozen at the first release. (The spec's
   `surrealier` guess is only a placeholder.)
3. **Parallel builds** by multiple agents use distinct `--scratch-path .build-<track>` directories
   to avoid SwiftPM's `.build` lock.
4. **Commit identity** for this repo is local config `bongkj <bkj8797@gmail.com>`; before every commit
   `git rev-parse --show-toplevel` must print this project directory (the folder lives inside an
   unrelated parent repo that must never be touched).

5. **App icon** (found on macOS 26.6 while packaging): full-bleed art with transparent pixel corners, and
   any supplied 16/32-px image, get the grey "legacy icon" plate. The shipped icon is therefore a body on
   Apple's 824/1024 squircle grid (superellipse |u|⁵+|v|⁵ ≤ 1) and the `.icns` omits the 16/32-px slots so
   the system derives them (`scripts/make-icon.sh --all-sizes` restores them). Supersedes "full-bleed
   rounded square" and "16–1024" in §6.
6. **Test toolchain on CLT:** `scripts/swift-test.sh` adds the Testing framework search paths and
   `-disable-cross-import-overlays` (the CLT ship `_Testing_Foundation.framework` without its module).
7. **Scene composition (M3).**
   - §1.3 chair rect is `196,228,72,84`, with `chairTravel` `64...432`, so it stays clear of the mat.
   - §1.2: when no Dock strip is reserved, `SceneLayout.coreOrigin` rises by `floorLift` (up to 14 px), so at
     least 14 floor rows show. `PixelGrid.coreOrigin` is unchanged. Room objects are placed from
     `SceneLayout`/`Anchors`, never from the grid.
   - Tall walls get a ceiling plane, crown, pendant and hanging plant (cords ≤ 72 px). Medium walls get a
     picture rail that the string lights hang from.
8. **Light shapes (M3).** These supersede the §1.4 rows.
   - The lamp light is an ellipse pool (`CoreLayout.lampPool`): a level-7 warm core and a level-6 ring, plus a
     painted highlight overlay and a bulb bloom. It shows only at ambient ≤ 5.
   - The monitor glow is a level-5 cool band in front of the riser, fading over 20 rows (level 3–4 turns oak into
     the felt greys).
   - The phone glow is level 5.
9. **Persisted names (wave-3 integration).**
   - `LightsMode` raw values are `auto|day|night|lamp`. Lamp Only is stored as `"lamp"`, the `--lights`
     spelling.
   - `mat` (§13) gains an optional `"keyboard": [x, d]`. `particles` may be absent (lay a fresh mat from
     `origin`/`size`/`angle`).
   - Restore a mat with `ClothSim.restore(state:piles:)`, which does coverage, then bumps, then cloth.
10. **Mat gestures (M8).** These refine §2.2 E9.
    - A peel stays folded only if it turned past 120° and the held point crossed the mat's midline; otherwise it
      lays back.
    - Rotate and size are fitted: the mat turns or grows only as far as it fits the desk.
      `canTransform`/`fittedTransform` disable menu items that can't do anything.
    - Grabbing an underside-up flap and dragging it toward its flat place unpeels it.
11. **Identity and backups (M4).** These refine §3.2 and §4.8.
    - Snapshots carry `continuous`. A same-name swap re-keys in place only in a continuous scan.
    - A name-only match needs the removal to be 0–2 s ago, or size and creation date to agree.
    - Nothing enters the wastebasket by a name match.
    - A scan that would remove > 50 % (and > 20) of the tokens is held and confirmed by a rescan 2 s later.
    - Backups rotate by age: `.bak1` hourly, `.bak2` daily, `.bak3` weekly.
    - Switching the mirrored folder parks its layout as `desk.<sha1(rootPath)>.json`.
12. **Interaction core (M5).** These refine §2.1, §4.2 and §4.9.
    - `DeskElement` has a `shownTokens` requirement. The selection keeps only tokens some element shows, so
      elements that show selectable minis (open drawers, cubby, phone) must list them. Space, ⌘O, ⌘C and the
      token menu act only on tokens on show.
    - Interactive elements join the hit/drop order through `RoomContent.install(_:inSlotOf:)`.
    - `MenuSpec.pending` disables items whose milestone hasn't landed (Move to Trash, Empty Wastebasket, Clear
      the Desk, Peek Desk, Settings…). Each milestone removes its ids.
    - `--lights` in desk mode changes only what the scene shows and is never saved.
    - The drag threshold is 3 art px, but never more than 4 pt.
13. **Drawers, tosses and machines (M6/M7 sims).** These refine §2.2 E3–E8.
    - A jammed drawer rests at its gap, `min(6, n − capacity)` px, not 4 px. The boing overshoots about 1.3 px
      and returns.
    - A click on a drawer more than half open closes it; otherwise it opens. Clicks and spring-loading thunk
      into the chair (`.hitChair` → `RollerSim.pushedByDrawer()`).
    - A peek expires 0.35 s after the last scroll. Cabinet drawers are interlocked: one open at a time.
    - Floor x is the token's **centre** (`FloorLine`). The floor keeps clear of the basket and cabinet footprints.
    - A release over the desk top, or the wall above it, lands on the desk however fast (over the wall it drops
      down the back wall), keeping 0.3 of the hand's velocity for its slide; a hard flick slides off an edge and
      falls from there. Only a release below the desk's front edge, or within 6 px above it moving down faster than
      250 px/s, is a front-plane arc; whatever leaves the desk forward falls in that plane. (Revised after the M7
      review: the earlier "faster than 250 px/s above the front edge" sent ordinary drops to the floor.)
    - Tokens landing together on the floor stand as one floor stack (count tag); the floor also keeps clear of the
      desk's legs, and new landings of the chair's base.
    - The basket tips only on a sustained sideways rim drag: 3 samples in a row, |vx| > 300 px/s and > 3|vy|,
      covering more than 6 px. Its heap uses `InteriorRaster.basketSlots` (24 slots; the heap rises above the
      rim from the 11th).
14. **Intent minting (M11 DeskFiles).** These refine §3.7 and §4.2.
    - `ExplicitIntent` is minted only through `@_spi(IntentMinting) import DeskFiles`, allowed only in
      `DeskteriorApp/Store/EffectRunner.swift` (and DeskFiles' own tests). `@testable` is forbidden in Sources.
    - Each intent is single-use, and its age is measured on `ContinuousClock` (10 s).
    - Accepted origins: trash takes menuItem, sheetConfirm, dragToTrash or inventory; import takes drop; undo
      takes undo; eject takes menuItem or inventory.
    - A `FileUndoRecord` is redeemable once, and only on the operator that issued it.
    - Copies stage in an item-replacement folder on the desk's volume, report progress, and land by one
      exclusive rename. Every move is re-checked by identity afterwards and sent back if it was swapped.
15. **Lighting interactions (M10).** These refine §1.4, §2.1, §2.2 E12–E14 and §4.11, and supersede Errata 8's
    light shapes.
    - **Light shapes.** The lamp's pool steps down 7 → 6 → 5 → 4 → 3 → 2 in dithered bands (`lampPoolFalloff`), still
      only at ambient ≤ 5. The monitor's glow on the desk falls off 5 → 2 from under the screen's middle, within the
      riser's width; it leaves as the CRT starts to collapse and returns with the bloom. The phone's glow falls off
      5 → 2.
    - **Screen light.** In a dark room (ambient below 3) the monitor's and phone's glows are a third tint,
      `Tint.screen`: it dims like `cool`, but oak and walnut turn to cool greys and blues, never the felt mat's
      `394a50`/`577277` (the desk under the glow is `819796` at levels 4–5, then `3c5e8b` and `253a5e` at the
      fringe), so a glow never reads as a warm lamp. At dusk and dawn, a level or two over the ambient, the glows
      stay `cool` and leave the desk its tan. Mask bytes carry the tint in bits 3–4 (0 cool, 1 warm,
      2 screen) and the ramp texture is 46 × 24. Ambient light is only ever cool or warm.
    - **Warm room light at night** (ambient warm 6) turns walls, wainscot and paper cream and tan; metal greys
      (`a8b5b2` and darker) stay grey. The lamp's pool (warm 3–5) still warms every grey.
    - **E12.** A click anywhere on the lamp (not only its base switch) toggles it. Lights ▸ Room Light and Desk Lamp
      stay live in Lamp Only. Lamp Only is also emergent: Night with the room light off and the lamp on is Lamp Only,
      and either switch turned from it gives Night; choosing another mode from Lamp Only turns the room light back on.
    - **Darkness.** A token is dark where less than a third of its drawn rect is lit to level 3 (`DarkHit`). Hover and
      selection follow the light under a resting pointer (a lamp switch, a flicker frame, a clock preview, the minute
      tick). A dark token's hover is a faint outline (lit to level 3), never its name; clicks, drags, scrolls and
      right-clicks do nothing, and `contextMenu(at:)` is empty there. The selection lets go of tokens drawn in the dark
      (by their accessibility frames; not during a carry). Hover rings are lit to full light in the dark, so the lamp,
      the wall switch and the clock can be found by hovering. VoiceOver still lists every token.
    - **E13.** On release the preview first drops whole hours, so the minute hand springs back the short way (at most
      half a turn over 0.5 s, overshooting a minute or two) and the light jumps most of the way at once. A preview
      past midnight turns the calendar.
    - **Reduce Motion** (§2.1): no shake; no flicker, jiggle or clock spring; the CRT's collapse and bloom become a
      2-frame fade of the picture on the glass. `--reduce-motion` (§4.11) forces it on; otherwise the `reduceMotion`
      setting decides (following the system by default).
    - **Glyph fallback** (§1.4 text): Galmuri9, then the system font and its non-colour cascade without
      anti-aliasing, then colour emoji drawn large, area-averaged into a 9-px square, snapped to Apollo lightness
      first and given a mid-grey rim where their own edge is dark; a variation selector no font maps is dropped for
      its base character (text presentation, U+FE0E, always draws the base glyph); a hollow box last. The emoji
      golden holds only against the Apple Color Emoji version it was recorded with.
16. **Containers in the scene (M6) and their glue with M7.** These refine §2.2 E3–E6 and E11.
    - A chomp or a peek opens a drawer at most 7 px (`DrawerSim.concealedLimit`, below `Visibility.drawerOpen`), so
      it never reveals the contents; an overfull drawer gapes less than its 6-px jam gap while chomping.
    - Hard sleep and quit stop a drawer where it is (and commit it), but end a chomp shut. An emptied drawer resting
      at its old jam gap slides shut.
    - A drop back into the container the tokens came from springs back without a move or an undo step. "Move to ▸"
      ticks and disables the container the tokens are already in.
    - The cubby shows two staggered rows; the front row sinks 3 px behind the lip.
    - List Contents is a submenu of the members' names (up to 20, then "N More…" opens Find Item); picking one
      flies it to the monitor (E5).
    - Show on Desk for a token in a container opens it fully (`revealContainer`): interlocked siblings shut, a
      blocking chair rolls clear, the phone turns face up.
    - The phone's flip is the absolute `.phoneFace(down:)`; face down, its minis hide and drops bonk.
    - A desk knock reaches the drawers through `Knockable` (they close themselves on their live sims), and the knock
      plan sees the live drawer sims, so a held or chomping drawer is left alone. A slam knocks the desk where the
      drawer shut (§2.2 E3). Floor landings keep clear of the chair where it actually stands.
17. **The mat, the brush and Clear the Desk in the scene (M9).** These refine §2.1 (DropResolver, scroll), §2.2 E9,
    E10, E16, §4.4 and §4.7.
    - **Drawing.** The raster uploads through `TextureFactory.dynamicTexture` (SPIKES S8), only when something it draws
      changed. The bare room (no model) has no mat: the desk-surface slot holds only the keyboard's contact shadow
      (`mat.keyboardShadow`). The keyboard rides on the mat: the room's keyboard placement moves with the weighted
      particles, and its shadow is drawn on the felt.
    - **Covering.** A pile that appears or jumps (a drop, an undo, a relaunch, Clear the Desk) is judged at once; moving
      piles and moving cloth go through the 6-frame hysteresis. A covered pile has no body (`PhysicsHub.isUnderMat`).
      A pile that goes under slides in to `ClearDeskPlan.inset(count:)` = max(16, its bump's reach + 6) px inside
      the edges (not 6), so its bump never holds the hem up; a covered pile that grows (a drop joins it) slides
      further in. Bumps keep `h` and full height within `r/2`, but their skirt is max(r/2, 1.25·h), so a tall stack
      never turns its far side to the 2:1 view.
    - **Drops on the mat** go through the desk plane's landing (no separate verdict): a landing on the cloth, or within
      18 plane px in front of its front edge (a stack's base sits below the pointer), tucks under and joins a covered
      pile within 10 px. A revealed pile the cloth still lies over is drawn in the raster (`PhysicsHub.drawnByMat`) and
      picked through `owner[]`.
    - **Peek Under** (and Show on Desk) aims at the covered pile nearest the click (within 40 px), draws the edge back
      16 px past it (`ClothParams.peekBeyond`; the core's default stays 8) and carries the edge back to where it was
      before letting go, so it never falls over folded.
    - **Mat commands** are `DeskAction.mat(MatCommand)` → `.play(.matCommand, .mat(…))`, not journaled; the status and
      wall menus gain Smooth Desk Mat. List Items Under Mat picks fly a token to the monitor, as List Contents does.
    - **Brush.** `brushSettled` commits where it stopped. The scroll-broom takes horizontal scrolls over the mat or the
      bare desk below the back strip (the mat answers that band, as part `desk`; clicks and menus there pass through):
      a 6×24 invisible broom, 1.5 plane px per scroll px, ending 0.25 s after the scroll stops.
    - **Clear the Desk** also shuts open drawers. Floor stacks become new piles. The brush goes round the mat between
      pushes (in front of it, or behind when the mat lies at the desk's front) and the pass is fitted into 2.4 s;
      "TIDY!" follows. With Reduce Motion everything is under at once.
    - **`matMode=flat`** comes from the setting or Reduce Motion (`DeskScene.matFlat`).
    - **Rest.** The cloth's pose commits (`matSettled`) when it falls asleep; an awake cloth with nothing driving it
      (no grab, script or transform) accepts its pose after 4 s, so creeping creases never keep the loop awake.
    - **Demos** gain a `move` step (a held drag moved on, for frame dumps).

---

# Deskterior: final implementation spec (v0.1)

> Deskterior (데스크테리어) is a native macOS app: Swift 6.2, AppKit, SpriteKit, SwiftPM, built with the Command Line Tools only. It turns the desktop layer into a pixel-art desk diorama. The real `~/Desktop` files appear as tokens on an in-scene monitor. You hide them using real-desk metaphors:
> - turning off the monitor;
> - the riser's mini-drawers and cubby;
> - flipping a phone on its stand;
> - the pedestal cabinet;
> - the pen cup;
> - the wastebasket;
> - sweeping them under a cloth desk mat, which is the homage to Terkel Gjervig's *Desktop Cleaning* rug.
>
> Hiding only changes the layout. Files change only when the user explicitly asks.

**Base design:** fidelity-first, which the product judge picked. It is rebuilt on utility-first's engineering backbone (the engineering judge's pick): the model is the truth, a pure reducer, a single file-mutation module, `ExplicitIntent`, and a lint.

**Grafts:**
- From delight-first: the phone stand, the brush, the AV input, the juice kit, the Watchdog/Freezer, and demo assertions.
- All judge red flags are fixed. All "missing from all designs" items are covered.

**Grounding:** API claims come from R1–R3. I re-checked these in this pass:
- `CADisplayLink.preferredFramesPerSecond` is `API_UNAVAILABLE(macos)`. Use `preferredFrameRateRange` instead (`CADisplayLink.h:87-99`; the class is macOS 14+ at `:19`).
- `renamex_np` and `RENAME_EXCL` exist (`sys/stdio.h:37,52`).
- `RegisterEventHotKey` exists (`HIToolbox/CarbonEvents.h:15484`).
- `NSWorkspace` has `unmountAndEjectDevice(at:)` (`:105`), `desktopImageURL(for:)` (`:231`) and the mount notifications (`:310-312`).
- `NSAccessibilityElement` exists (`NSAccessibilityElement.h:19`).
- The SDK is 26.2 and Swift is 6.2.3.
- `Testing.framework` is present in the CLT.

**Repo state:** the project folder started empty and sits inside another, unrelated git repository. M0 runs `git init -b main` inside the project folder so Deskterior is its own repository; no git command may target the enclosing one.

---

## 1. Concept and scene composition

### 1.1 Rendering pipeline (decided)

```
DeskScene (SKScene; sim units: 1 art px = U = 4 SK units; anchor .zero; scaleMode .fill; never attached to an SKView)
  └─ SKRenderer.update(atTime: simTime += 1/60) → render(viewport 0,0,artW,artH) → artTex (bgra8Unorm, art size; + depth32Float_stencil8)
  → LitPass (MSL compiled at runtime):
        idx   = indexLUT64[rgb >> 2]                      // R8Uint 3D 64³: RGB → nearest Apollo index (absorbs ±1 colour drift)
        level = max(ambientLevel, lightMask[px])          // R8 art-res mask, CPU-built, rebuilt only on change
        out   = rampTex[idx, level, tint]                 // 46 × 8 levels × {cool, warm}
     → litTex (art size)  ← canonical frame: snapshots, goldens, frame dumps, GIFs
  → UpscalePass: full-screen triangle, texel = floor((fragCoord + crop) / S) − shake → CAMetalLayer drawable (backing px)
```

**Rules:**
- **Drawing primitives.** No `SKView`, `MTKView`, `SKAction`, `SKCropNode`, `SKLabelNode`, `SKShapeNode` or `SKEmitterNode`.
  - Clipping comes from draw order, or from CPU-composited interiors (§2, drawers).
  - Every texture is created through `TextureFactory`, which sets `.nearest` and turns mipmaps off.
- **Colour.**
  - Art rule: binary alpha, no translucency. Shadows and glows are opaque dithered palette pixels, so every output pixel is a palette colour.
  - `CAMetalLayer.colorspace = sRGB`, pixelFormat `bgra8Unorm`, `framebufferOnly = true`.
  - `drawableSize = backing size` is re-asserted in `layout()` and `viewDidChangeBackingProperties()`.
  - The LUT is 64³ because Apollo's closest pair (`172038`/`1e1d39`) is 7.7 RGB units apart. A 32³ LUT can merge them.
- **Fallback** if the M2 spike fails: present through an `SKView` with integer scene scale. The scene is unchanged.

### 1.2 Integer scale (`PixelGrid`, pure, tested)

The core composition is **512×320 art px** (16:10). Wall and floor are extended procedurally to fill the canvas.

```
S_target = round(frameHeightPx / T)            T: Chunky 320 · Normal 380 (default) · Fine 440
S_fit    = floor(min(visibleWidthPx / 512, visibleHeightPx / 320))   // visibleFrame excludes menu bar/notch and Dock
S        = max(1, min(S_target, S_fit))
artW = ceil(frameWpx / S); artH = ceil(frameHpx / S); crop = (art*S − px)/2 per side (centred)
core.x = round((artW − 512)/2) + widgetNudge;  core floor line sits on the visibleFrame bottom edge (above the Dock)
```

| Display (looks like @backing) | Backing px | S | Canvas | 1 art px |
|---|---|---|---|---|
| **MBA 13" default 1470×956 @2 (this Mac)** | 2940×1912 | **5** | 588×383 | 2.5 pt |
| 1280×832 @2 (pixel-exact on this panel) | 2560×1664 | 4 | 640×416 | 2 pt |
| 1512×982 @2 | 3024×1964 | 5 | 605×393 | 2.5 pt |
| 1710×1112 @2 | 3420×2224 | 6 | 570×371 | 3 pt |
| 1920×1080 @1 | 1920×1080 | 3 | 640×360 | 3 pt |
| 2560×1440 @1 | 2560×1440 | 4 | 640×360 | 4 pt |
| 5K 2560×1440 @2 | 5120×2880 | 8 | 640×360 | 4 pt |
| 4K looks like 1920×1080 @2 | 3840×2160 | 6 | 640×360 | 3 pt |
| Portrait 1080×1920 @1 | 1080×1920 | 2 | 540×960 (tall wall) | 2 pt |

The table assumes a bottom Dock about 70 pt tall and a menu bar of 25–37 pt.

**When the grid is recomputed:** on `didChangeScreenParameters`, on backing change, on wake, and on a Dock or widget change.

**Scaled-mode limitation:** scaled display modes resample the final image (2940→2560 on this Mac). This is documented as "crisp at looks-like 1280×832". Large flat areas must not use 1-px checker dithers.

**Widget nudge:** desktop widgets sit at icon+2, above us. `WidgetProbe` reads widget frames with `CGWindowListCopyWindowInfo`, matching the owner PID of bundle `com.apple.notificationcenterui` rather than the localized name. If a widget overlaps a critical rect (screen, chin, drawer fronts, mat default, cabinet), it tries `core.x` offsets in 8-px steps within the slack. If no offset clears it, it shows a one-time tip note.

### 1.3 Composition (core 512×320, y-down, 1 char ≈ 8 px, 1 line = 10 px; exact rects below)

```
x→ 0       64      128     192     256     320     384     448    511
  0 ................................................................  wall (extends up to canvas top)
 10 ..+----------+......+--------------------------+................
 20 ..| ~ sky ~  |.(12).|[] [] [] [] [] [] [] [] []|.....+----+.....  clock · calendar(decor)
 30 ..|  ☁   ☾   |......|                          |.....|CAL |.....
 40 ..|==blinds==|......|[] [] [] [] [] [] [] [] []|.....+----+.....
 60 ..|==========|......|[] [] [] [] [] [] [] [] []|................  MONITOR screen 9×5 cells
 80 ..|==========|.[s]..|[] [] [] [] [] [] [] [] []|................  [s] room light switch
100 ..+----------+..__..|[] [] [] [] [] [] [] [] []|................  lamp head
120 .............../__\.+[IN]·o·o·o·-------[*][⏻]-+................  chin: INPUT, page dots, LED, POWER
140 ....\|/......./..............||...................[▯]...........  plant · neck · phone on stand
150 ....\|/....../.......+-------------------------+.[U].[▯]..[hub]..  riser · pen cup · drive hub
160 ....[_]...==base==...|[drawer L]|[cby]|[drawer R]|...............
170 ==|=========================================================|===  desk back edge (y168)
190 ..|..................+~~~~~~~~~~~~~~~~~~~~~~~~~+.......brush==|..  DESK MAT (cloth) 204×84 desk-px
200 ..|..................~  [====keyboard 96====]  ~.............|..
210 ..|..................~   ^bump      ^^bump     ~.............|..
220 ..|..................+~~~~~~~~~~~~~~~~~~~~~~~~~+.............|..
232 =================================================================  desk front edge; apron 232–244
250 ..||...................+-------+..............+---CABINET----+|..
260 ..||...................| CHAIR |..............|=== top 16 ===||..
270 ..||....+----+.........|  rolls|..............|== middle 18 =||..
290 ..||....|BSKT|.........+--o-o--+..............|=== file 24 ==||..
312 __||____+----+_________________________________+--o-------o--+|__  floor line y312 (Dock strip below = decor)
```

| Element | Rect x,y,w,h (core, y-down) | Notes |
|---|---|---|
| Window and blinds | 16,12,84,96 | Day light source; sky follows the clock |
| Room light switch | 108,84,8,12 | Click toggles |
| Wall clock | 120,20,28,28 | Real time |
| Calendar | 392,24,32,36 | Decor only in v0.1 |
| Monitor body | 160,12,208,132 | Bezel 6; chin y126–144 |
| Screen | 166,18,196,108 | Grid 9×5 cells of 20 px at (174,22); 16×16 icons; 45 per page |
| INPUT · page dots · LED · POWER | 172,130,20,10 · 196,133 · 336,134,2,2 · 344,130,12,10 (hit 340,128,20,14) | |
| Neck | 254,144,20,10 | |
| Riser (받침대) | 184,154,160,22 | Drawer L 190,160,56,12 · cubby 250,160,28,12 · drawer R 282,160,56,12; travel 10 |
| Lamp | base 112,160,28,8 · switch 118,158,6,3 · head 136,100,24,16 | Aim fixed in v0.1 |
| Plant | 36,136,24,34 | Decor |
| Pen cup (펜꽂이) | 360,150,14,22 | Movable desk prop |
| Phone and stand (휴대폰 거치대) | 384,144,16,28 | |
| Drive hub | 408,162,24,8 | Mounted volumes |
| Desk top face | 12,168,488,64 | Desk plane x 12–500, d 0–128 |
| Desk mat (default) | plane x154–358, d8–92 → screen 154,186,204,42 | 35×15 particles at 6 px |
| Keyboard | plane x206–302, d40–64 (sprite 96×14) | Weighs the mat down |
| Brush (rest) | plane x430–454, d60 (sprite 24×10) | |
| Apron | 12,232,488,12 | Double-click triggers the desk knock |
| Chair | 200,236,64,76 | Rolls x ∈ [64,440] |
| Cabinet (이동식 3단 서랍) | 392,248,80,64 | Fronts 16/18/24, plinth 6; travel 12/14/18 |
| Wastebasket | 48,272,32,40 | Mouth 48,272,32,6 |
| Floor | y ≥ 312 | |

**Desk-plane projection** (oblique 2:1): `X = x`, `Y = 232 − d/2 − z`, with inverse at a known z: `d = 2·(232 − Y − z)`. Depth key = z. Back-strip static footprints sit at d ≥ 112: riser, lamp base, plant, phone, hub, and the pen cup's resting spot. The mat is confined to d ∈ [0,104].

**Layers, back to front:**
1. room backdrop
2. desk-back objects (plant, lamp, monitor, riser with drawer fronts, phone, hub)
3. **desk-surface raster** (mat plus every desk pile)
4. desk-front props (keyboard, brush, pen cup)
5. apron
6. under-desk (cabinet and interiors, basket and heap, floor tokens)
7. chair
8. FX
9. carry layer
10. UI (tooltips, toasts, notes, mat handles)

### 1.4 Palette, day/night, themes

**Palette:** Apollo by AdamCYounis, 46 colours, in 7 ramps:
- blue: `172038 253a5e 3c5e8b 4f8fba 73bed3 a4dddb`
- green: `19332d 25562e 468232 75a743 a8ca58 d0da91`
- oak: `4d2b32 7a4841 ad7757 c09473 d7b594 e7d5b3`
- walnut/glow: `341c27 602c2c 884b2b be772b de9e41 e8c170`
- red: `241527 411d31 752438 a53030 cf573c da863e`
- purple: `1e1d39 402751 7a367b a23e8c c65197 df84a5`
- neutral: `090a14 10141f 151d28 202e37 394a50 577277 819796 a8b5b2 c7cfcc ebede9`

**Roles:**

| Role | Colour |
|---|---|
| Desk | `d7b594`, highlight `e7d5b3` |
| Bezel | `151d28`/`202e37` |
| Screen off | `090a14` with a `394a50` glare streak |
| Felt mat | `394a50`/`577277` |
| Selection | `4f8fba` |
| LED on | `75a743` |
| LED amber | `de9e41` |
| Lamp glow | `e8c170`/`de9e41` |
| Label text | `ebede9` on `090a14` |

**Lighting.** `LightRamp[index][level 0…7][cool|warm]` is precomputed in pure Swift: OKLab lightness is scaled per level and the hue nudged toward `253a5e` (cool) or `de9e41` (warm), then snapped to the palette. Level 7 is the identity. Golden-tested.

| Phase (Lights = Auto; real local time) | Ambient (room light on) | Ambient (room light off) |
|---|---|---|
| Day 08–17 | 7 | 6 |
| Dusk 17–19, dawn 06–08 | 7 | 5→3 (dusk), 3→5 (dawn) |
| Night 19–06 | 6 warm | **1** (lamp-only darkness) |

**Light mask** (CPU, art resolution, 4×4 Bayer edges):
- Lamp cone: level 7 warm.
- Monitor glow trapezoid when on: 5 cool.
- Face-up phone glow: 4 cool.
- Emissive rects at 7: lit screen, LEDs, window sky.

**Themes:** Oak in v0.1. Walnut, plus Leather and Cork mat patterns, come in v0.2 as CPU palette swaps.

**Screen wallpaper:** the built-in dithered "DeskOS" sky by default.
- The user's real wallpaper loads automatically **only** if the realpath of `desktopImageURL(for:)` is under `/System/Library/Desktop Pictures` or `/Library/Desktop Pictures`. The image is area-averaged, quantized and Bayer-dithered.
- Any other location could raise a Documents, Downloads, volume or app-container TCC prompt. A "Use My Wallpaper…" picker (`NSOpenPanel`) comes in v0.2.

**Text:**
- Galmuri9 (10 px; covers all 11,172 Hangul syllables), rasterized with CoreText with anti-aliasing and smoothing off. Alpha is thresholded to binary.
- Strings are NFC-normalized first with `precomposedStringWithCanonicalMapping`, because Galmuri has no conjoining jamo.
- Missing glyphs fall back to the system font rendered without anti-aliasing, then to a box glyph.
- Labels appear only on hover or selection, as a one-line tooltip middle-truncated to 200 art px. Galmuri7 is not used.

---

## 2. Interaction catalog

### 2.0 Fidelity map (original → deskterior)

| # | Original | Deskterior |
|---|---|---|
| O1 | Rug layer above icons, below windows | Whole room at `desktopIconWindow+1`; Finder icons covered, never hidden through defaults |
| O2 | Drag the rug; it wrinkles | Carry the mat interior with a patch grab plus weak shape matching: it moves as a whole and trails wrinkles |
| O3/O4 | Resize / rotate | ⌥-drag a mat corner: the opposite corner stays anchored and the drag sets size and angle |
| O5 | Sweep icons under it | Drop a token on the mat (it tucks under), slide the mat over loose piles, or push piles into the mat with the **brush** (or the scroll-broom shortcut) |
| O6 | Taller stacks, bigger bumps | Bump h = 3 + 2·min(n−1,6); "fullness is visible" everywhere: drawers sit ajar or jam, the basket heap rises, the cup fills |
| O7 | Lift part to grab a file | Peel an edge or corner: the piles underneath pop up and can be grabbed; release lays the cloth back |
| O8 | Fold / twist | Peel past the middle and release: the flap stays folded with the underside up |
| O9 | Tug corners to smooth | Drag a corner outward; or double-click the edge (Smooth) |
| O10 | Creases from dragging | Fast carries leave wrinkles, which persist across relaunch |

### 2.1 Global gesture grammar

| Input | Meaning |
|---|---|
| Hover | 1-px outline plus a Galmuri9 tooltip after 250 ms. Affordance glyphs appear: drawer grab tick, mat edge curl, power glow. Uses an `.activeAlways` tracking area. Renders one frame only when the hover target changes. No in-scene cursor sprite. |
| Click | Switches and buttons (power, INPUT, lamp, room switch, drawer handle toggle, phone flip). Clicking a token selects it; ⌘-click toggles. |
| Double-click | Token: open. Mat edge: Smooth. Folded flap: Unfold. Apron: desk knock. Brush: return to its rest spot. |
| Drag (3 art px threshold) | Token: carry (no physics body; follows with a 1-frame lag, 2-px lift and shadow; drop target highlighted). Furniture: direct manipulation. Release velocity (EMA over 50 ms × 0.8, clamped to 1200 art px/s) becomes a fling. |
| Two-finger scroll | Screen: page. Closed drawer: peek 0–4 px. Bare desk, horizontal: broom shortcut. |
| ⌥ held | Mat transform handles (corner = size and angle; interior = rigid slide without wrinkles). |
| Right-click | Object menu built from `MenuSpec`. Every gesture has a menu equivalent, for example "Move to ▸". |
| Keys (app active, desk key) | Space: Quick Look. ⌘O / ⌘↓: open. Arrows: move selection on the screen. ⌘A: select the page. ⌘C: copy file URLs. ⌘F: Find. ⌘Z / ⌘⇧Z: undo/redo. Esc: cancel carry, exit Peek. **No destructive key equivalents. There is no ⌘⌫.** |
| Spring-loading | A carried token hovering 0.6 s over a closed drawer front opens it; it closes 0.8 s after the drop. |
| Release over an invalid spot at low speed | The token springs back to its origin over 6 frames. |

**DropResolver** (pure; first match at the release point in art space):
1. **Affordance under the pointer** (accept or bonk):
   - accepts: open drawer interior, closed drawer front (chomp: opens 6 px, the token slides in, it closes, 0.4 s), cubby opening, pen cup mouth, face-up phone, wastebasket mouth, monitor screen (only while ON).
   - bonks: screen OFF, phone face-down, container at hard cap, drive tokens. A bonk shows "BONK", a 1-px shake, and the token rebounds to its origin.
2. **Mat footprint** → under the mat at that desk point, clamped 6 px inward. It joins a pile within 10 px.
3. **Desk top face** → desk pile; the fling carries over with `vd = −2·vy`.
4. **Speed > 300 art px/s, or below the desk band** → ballistic arc (§2.2 E8): lands on the desk, in the basket or on the floor.
5. **Otherwise** → spring back.

**Visibility matrix** (`Visibility.of(location, state, coverage)`):

| Location | Shown | Hit-testable |
|---|---|---|
| Screen page, monitor ON and page current | icon | yes |
| Screen, monitor OFF / other page / AV | black / not shown | no |
| Riser drawer or cabinet drawer: closed / peek / open (p ≥ 8) | hidden / paper edges / 12-px minis | no / no / yes |
| Riser cubby | dim silhouettes (deepNight tint) | yes; names on hover |
| Phone face-up / face-down | 5×5 minis / back of the phone | yes / no |
| Pen cup | pen caps coloured by kind (anonymized) | pull the last one out |
| Wastebasket | crumpled balls | List / dig / tip |
| Desk pile, uncovered | icon stack plus count tag | yes |
| Under the mat | bump only | yes, only where the cloth is lifted away |
| Floor | icon | yes |
| Lamp-only darkness (level < 3) | silhouette | no (faint outline on hover) |

**Non-destructive un-hiding rule** (product rule; also stated in the README): a hidden token becomes visible only through
- a direct gesture on that container (open drawer, peel or move the mat, flip the phone, tip the cup or basket, switch input);
- an explicit menu action;
- Find, Show on Desk, or Take Everything Out.

Knocks, slams and overfill never empty a container. Overfill is refused with a bonk.

**Juice kit** (shared; no sound by default):
- Pre-drawn 3-frame squash on landing.
- 5-frame dust puff.
- 1-art-px screen shake for 2 frames, applied in the upscale pass.
- Sparkle; pixel text pops ("SWISH!", "BONK", "TIDY!").
- 1-px spring overshoot on drawers.
- With **Reduce Motion**: no shake, no arcs (tokens teleport with a puff), CRT becomes a 2-frame fade.

### 2.2 Elements

Legend: **MVP** ships in v0.1. Each element lists gesture, state, hiding, physics, feedback and persisted state.

**E1. Monitor and power button (모니터 전원) · MVP**
- **Gesture:** click POWER (zero latency, no double-click handling). Context menu: Turn Display Off/On.
- **States:** `on → poweringOff → off → poweringOn → on`.
  - Off: 6 frames at 12 fps: vertical squash, a 4-px band, a line, a dot, black with a glare streak.
  - On: 8-frame bloom; icons pop in row by row at a 2-frame stagger.
  - Overlay states while on: `connectPrompt` (first run), `noSignal` (access denied), `desktopHidden` (Finder hides items).
- **Hiding:** OFF hides every page. Tokens are not drawn and not hit-tested; drops bonk.
  - Files that arrive while off: the LED blinks amber 3×, then holds a steady amber pip, and a "+N" badge appears on the bezel. All static frames, no wakeups.
  - Find, Show on Desk and Take Everything Out power the monitor on automatically.
- **Physics:** none. The monitor wobbles 1 px in stepped frames on a desk knock.
- **Light:** when on at night, it emits a cool glow onto the keyboard and mat.
- **Persisted:** `power`, `pendingNew`.

**E2. Monitor screen as the desktop, INPUT pages and AV · MVP**
- **Grid:** 9×5 cells of 20 px holding 16×16 tokens. Each page is an "input": HDMI 1…n, created on overflow. Trailing empty pages are pruned (HDMI 1 always remains).
- **Gestures:**
  - select, ⌘-click, marquee on the empty screen;
  - drag to snap to the nearest free cell (swap if occupied);
  - multi-select drag shows a "+N" stack, and dropping pours tokens in at 40 ms intervals;
  - double-click opens;
  - horizontal scroll, page-dot click, or INPUT click (cycles HDMI 1…n, then AV, then HDMI 1);
  - dragging past the bezel makes the token a carried token.
- **Context menu:** Clean Up By ▸ Name / Kind / Date Added; Input ▸; Turn Display Off.
- **AV input:** always empty, which makes it a second way to hide everything. It shows a bouncing "NO SIGNAL" logo at 8 fps **for at most 10 s** after switching or hovering, then freezes. Hitting a corner exactly sparkles.
- **Feedback:**
  - Page change: 2-frame static noise (no clipping needed).
  - OSD "HDMI 2 · 45" in Galmuri9, top-right, for 1 s.
  - New file: a scanline print-in, 4 frames.
  - Removed file: poof, 5 frames.
- **Persisted:** per-token `(page, col, row)` and the current page.

**E3. Monitor riser (모니터 받침대): two mini-drawers and a cubby · MVP**
- **Drawer gestures:**
  - drag the handle toward the viewer (1D follow);
  - click to toggle;
  - scroll to peek 0–4 px;
  - drop on a closed front: chomp;
  - spring-loading;
  - fling up to slam;
  - drag a mini token out of an open interior.
- **`DrawerSim` (pure 1D rail):** `p ∈ [closedLimit, openLimit]`, follow spring k = 600, coast friction 8/s, end-stop restitution 0.25. A `slam` event fires when |v| > 120 px/s at the closed stop and triggers a desk knock.
- **`ContentJostle`:** each item is a 1D damped spring driven by −a_drawer, clamped to the interior and quantized to 1 px, so contents slide as the drawer moves.
- **Interior:** composited on the CPU into a small `PixelBuffer` by `InteriorRaster`, cropped to the revealed rows `p`, and re-uploaded only when `p` or the contents change.
- **Fullness is visible:**
  - capacity 8;
  - `closedLimit = min(6, max(0, n − 8))`: an overfull drawer rests ajar with paper pixels poking out, contents still hidden;
  - at n = 14 it is jammed: closing bounces back to 4 px ("boing") and further drops bonk.
- **Cubby:** an open slot, capacity 12. It is a *partial* hide: dim silhouettes, names on hover.
- **Persisted:** `p` and the content order per container.

**E4. Phone on a stand (휴대폰 거치대) · MVP**
- **Gestures:** drop on the face-up phone ("bloop"; the token becomes a 5×5 mini app icon in a 3×2 grid; capacity 6). Click to flip (3 frames) between face-down (back with camera bump) and face-up. Drag a mini out.
- **Hiding:** face-down hides the contents. A drop on a face-down phone bonks.
- **Night:** a face-up phone glows (emissive), so to hide it at night you flip it, as with a real phone.
- **Physics:** none (scripted).
- **Persisted:** `faceDown` and the slot order.

**E5. Pedestal 3-drawer cabinet (이동식 3단 서랍) · MVP**

| Drawer | Front | Travel | Capacity (hard cap = cap + 6) | Interior |
|---|---|---|---|---|
| Top | 16 | 12 | 8 | minis |
| Middle | 18 | 14 | 12 | minis |
| File | 24 | 18 | 20 | hanging-folder tabs coloured by kind; names on hover |

- Same `DrawerSim`, `ContentJostle`, chomp, spring-loading, peek and jam rules as E3.
- **Chair block:** if the chair's x-range overlaps the cabinet front by more than 16 px, `openLimit = 3`. Hitting the chair plays a thunk and gives the chair +120 px/s away from the cabinet, so it rolls aside and the next pull works.
- **Context menu:** List Contents… (selecting an item flies it to the monitor), Take All Out.

**E6. Chair (의자) · MVP**
- **Gesture:** drag to roll; fling to roll and spin.
- **`RollerSim`:** 1D x within [64,440], friction 1.5/s, keeps 60% of the release velocity, end restitution 0.3. Four facing frames cycle when |v| > 80 and decay.
- **Interactions:** blocks the cabinet (E5). Parks in front of floor tokens (draw order only).
- **Persisted:** `x` and `facing`.

**E7. Pen cup (펜꽂이), a holder · MVP**
- **Gesture:** drop on the mouth and the token becomes a 3×10 pen whose cap colour encodes its kind (capacity 6; a 7th bonks and the cup wobbles). Hover lists the names. Press and drag on the cup mouth pulls out the last pen (LIFO).
- **Moving it:** dragging the cup turns it into a desk-plane `prop` body (velocity drive) that pushes piles. The sprite leans across ±2 frames with acceleration.
- **States:** `upright → wobble → tipping (3 frames) → lying(dir) → righting → upright`.
  - **Tips only from a direct gesture:** release speed > 400 px/s with n ≥ 3, or the menu item "Tip Out".
  - **Spill:** pens become piles, each with a seeded impulse of 150–300 px/s within ±30° of the tip direction. Some slide under the mat (where they are covered and grow bumps); some go off the edge to the floor.
  - Click the lying cup to stand it up.
- **Persisted:** state, desk-plane position, pen order.

**E8. Wastebasket (휴지통): hides, never deletes · MVP**
- **Entering:** a gentle drop within 12 px of the mouth goes in. A fling follows an analytic `Ballistics` arc (g = 940 art px/s²) with point tests against the two rim tops (ball r = 4, rim restitution 0.4, at most 3 bounces):
  - clean pass → "SWISH!" and a sparkle;
  - rim bounce → in or out;
  - miss → lands on the floor as a visible, safe token.
- **Fullness is visible:** balls are 8-px crumples in heap slots. At 11 or more they heap above the rim. The hard cap is 24 (bonk). Nothing ever rolls out on its own.
- **Gestures:**
  - Drag the rim sideways faster than 300 px/s to **tip** it. Balls uncrumple into floor tokens. Click to set it upright.
  - Drag from the mouth to dig out the top ball, which uncrumples into your hand.
- **Context menu:** List Contents, Take All Out, **Empty Wastebasket…** A confirm sheet lists every name (or 20 plus "and N more"), then calls `NSWorkspace.recycle`, so files go to the system Trash. The basket never empties itself.
- **Tooltip:** "N items — hidden, not deleted."
- **Persisted:** state, contents, swish count.

**E9. Desk mat (데스크매트), the homage · MVP · highest risk**

*Simulation (`ClothSim`, pure DeskCore, XPBD):*
- 6-px spacing, 35×15 = 525 particles. Each particle has `x`, `prev`, `v: SIMD3<Float>`, inverse mass `w` and rest `uv`.
- Constraints (one Gauss-Seidel sweep per substep):
  - stretch α = 0;
  - shear 1e-4;
  - bend (skip-one) 1e-2.
- 60 Hz, 8 substeps × 1 iteration. Gravity z −600 px/s². Damping `v *= 1 − 2h`.
- **Floor:** `z ≥ H(x,d) + 1`, with position-based friction μs 0.7, μk 0.45. Back limit d ≤ 104; front limit d ≥ 0 (no overhang in v0.1).
- **Self-layering:** particles whose normal has n.z < 0 use floor `H + 2`, so a folded flap lies on top without self-collision.
- **Initial jitter:** ±0.01 px in z to break symmetry.

*Grab modes* (chosen from the hit particle's rest uv, the edge distance, ⌥, and the first 4 px of motion):

| Mode | Trigger | Behaviour |
|---|---|---|
| Carry | Interior | Particles within 9 px get Gaussian-weighted targets, plus global best-fit-rotation shape matching toward rest + drag delta (0.06 per substep). The mat moves as a whole with trailing wrinkles and turns naturally when grabbed off-centre. Release keeps 40% of velocity. |
| Rigid slide | ⌥ + interior | Translate `x` and `prev` together |
| Peel | Edge band ≤ 10 px or a corner, moving inward or up | Patch gets w = 0; target is the cursor at z = 12, `d = 2·(232 − Y − 12)`. Release lets it fall where it is. Underside-up particles mean the **fold persists**. |
| Tug | Corner moving outward within ±60° of the centroid→corner direction | Patch held at z = 1.5 and dragged along the desk; tension pulls wrinkles flat |
| Transform | ⌥ + corner | Opposite corner anchored. The grabbed corner sets size (96–300 × 48–104, snapped to 6 px) and angle (⇧ snaps to 15°). Rest lengths and uv rescale over 0.2 s; the pattern tiles by uv, so it never stretches. |

*Scripted actions:*
- **Smooth:** double-click the edge or use the menu. All four corners are tugged 4 px outward for 20 frames with floor friction × 0.5. Bumps remain.
- **Unfold:** double-click the flap. Flap particles are reflected back across the fold line over 0.3 s.
- **Peek Under:** menu. Scripted lift of the nearest edge for 1.5 s.

*Keyboard weight:* particles under the keyboard footprint are clamped to the floor each substep (free in xy). The keyboard's position is the mean of those particles, so it rides along with a carry and that region cannot be peeled.

*Hiding:*
- One rule: **covered = hidden.** Piles keep absolute desk positions; the mat slides over them, as a real rug does.
- **`Coverage`:** sample 5 points of a pile's footprint. A point is covered if a cloth triangle contains it in xy with interpolated z < pileTop + 6.
  - ≥ 3/5 covered for 6 consecutive frames → **covered**: the billboard squashes over 3 frames, then the Box2D body is removed.
  - ≤ 1/5 covered → **revealed**: it pops up over 2 frames, the body is recreated, and it is clickable and draggable through `owner[]`.

*Bumps (`BumpField`):*
- `PileClusterer` uses union-find with radius 10 to group covered piles.
- Each group stamps a rounded box onto a 2-px grid over the desk plane (244×64): h = 3 + 2·min(n−1,6), r = 7 + min(n,8), smoothstep falloff.
- Changes ease in over 15 frames and wake the cloth.

*Rendering (`DeskSurfaceRaster`, pure, deterministic):*
- **Buffer:** one fixed **496×104** buffer covering core x 8–504, y 144–248.
- **Geometry:** mat triangles snapped to 1/16-px fixed point (top-left fill rule) plus **pile billboards** with per-pixel depth, so a lifted flap correctly hides the piles underneath it.
- **Passes:**
  - front faces: felt pattern by uv (16×16 tile, 3-px border band, stitch dashes, fringe on the short edges);
  - back faces: rubber dot grid, with a +thickness bias.
- **Shading:** 5-level ramp with Bayer dither. 1-px outline on coverage edges and wherever depth jumps by more than 1.5 px (this draws the fold edge). Opaque shadow colour under lifted cloth.
- **Outputs:** `PixelBuffer` plus `owner[]` (−1 empty; ≥ 0 particle id; ≤ −2 pile id).
- **Upload:** one persistent `SKMutableTexture` of fixed size. Each awake frame we call `modifyPixelData` with a copied snapshot; ≤ 1 frame of latency is accepted. If spike S8 shows RSS growth, switch to a per-frame `SKTexture(data:size:)`.

*Context menu:* Smooth Mat, Unfold, Rotate −15° / +15° / Straighten, Size S/M/L, Peek Under, List Items Under Mat, Reset Mat.

*Fallbacks:*
- `matMode=flat` (hidden setting): keeps bumps and covering, drops lift and fold.
- Plan B for unruly folding: the parametric flat fold (R2 §5.4) behind the same raster.

*Persisted:* origin, size, angle, pattern, and every particle position (Float32 LE, base64, about 8 KB).

**E10. Desk brush (빗자루) and broom shortcut · MVP**
- **Gesture:** drag the brush. It is a desk-plane `prop` body driven **directly** by velocity (no joint): `v = clamp((target − pos)/dt × 0.5, 600 art px/s)`. Mass is about 20× a pile; precise collision detection on; no rotation. It shows a 2-frame bristle animation and up to 6 dust motes while moving.
- **Release:** the brush stops (no throw). Double-click returns it to its rest spot.
- **Effects:**
  - Piles pushed into the mat footprint where the cloth edge z < 4 tuck under (bump appears).
  - Piles pushed past the front or side edge leave the desk on a `Ballistics` arc to the floor, or into the basket if the arc meets its mouth.
- **Scroll-broom:** two-finger horizontal scroll over the bare desk drives an invisible brush along the same path.
- **Persisted:** brush position.

**E11. Loose desk piles, floor and desk knock · MVP**
- **Piles:** desk-plane Box2D bodies (§12) with gravity 0 and `linearDamping 4`. Two or more tokens show up to 3 offset 16×16 billboards plus a count tag.
- **Pushed off** the front, left or right edge → ballistic arc → floor or basket. The back is a wall.
- **Floor tokens:** 16×16 sprites on the floor line, stored as x only, no physics.
- **Desk knock:** double-click the apron (1 s cooldown):
  - piles hop 2 px (visual only);
  - cup, monitor and phone wobble;
  - the cloth gets a z ripple;
  - ajar, non-jammed drawers (p ≤ 3) snap shut.
  - It **never** changes where a token lives.

**E12. Lamp, room light and Lamp Only · MVP**
- **Lamp:** click the base switch for a 3-frame flicker. The cone is fixed in v0.1, aimed down-right over the desk's left and centre.
- **Room switch:** click toggles the room light.
- **Lamp Only:** night, with the room light off and the lamp on, gives ambient level 1. Tokens outside the lit areas (cone, monitor glow, phone glow) turn into silhouettes: hover shows only a faint outline with no name, and clicks are ignored. The lamp works as a flashlight for searching. The menu item "Lights ▸ Lamp Only" sets all three at once.
- **Persisted:** lamp on/off, room on/off, lights mode.

**E13. Wall clock and window · MVP**
- **Clock:** real time, re-rendered at minute boundaries. Hands are drawn with `LineRaster` (Bresenham).
- **Preview:** drag the minute hand to preview another time; phase, sky and light update live. On release the hands spring back over 0.5 s.
- **Window:** the sky follows the phase. Clouds shift 1 px per minute; stars and moon appear at night.

**E14. Keyboard and plant · MVP (decor plus small actions)**
- Clicking a key presses it 1 px for 2 frames. It never reflects real typing.
- The keyboard weighs down the mat (E9).
- The plant jiggles for 4 frames when poked.

**E15. Drive hub (mounted volumes) · MVP**
- **Purpose:** covering the Finder desktop also hides its drive icons. Each mounted volume that Finder would show is plugged into the desk hub as a USB-stick, disk or server sprite (max 4; overflow becomes a "+n" menu).
- **Which volumes:** filtered by the read-only Finder prefs `ShowExternalHardDrivesOnDesktop`, `ShowRemovableMediaOnDesktop` and `ShowMountedServersOnDesktop`. Updated on `NSWorkspace.didMount`/`didUnmount`.
- **Gestures:** hover shows the name. Double-click opens it in Finder. Menu: Open, Reveal, **Eject**, which is explicit and goes through `FileOperator` (`unmountAndEjectDevice(at:)`).
- **Drops onto drives** bonk in v0.1 ("Use Finder to copy to drives").

**E16. Global actions · MVP**

| Action | What it does |
|---|---|
| **Find Item… / Inventory** | SwiftUI `Table` window: icon, name, location label ("Monitor · HDMI 2", "Cabinet ▸ middle", "Under mat", "Wastebasket"), kind, date added, plus search. Buttons: Open, Quick Look, Reveal in Finder, Take Out, **Show on Desk** (powers on, switches the page, opens the drawer, flips the phone up or peeks the mat, then pulses the token for 2 s). It is also the accessible path to everything. |
| **Take Everything Out** | Every token parades back to the monitor in name order. Monitor on. Takes ≤ 3 s. Undoable. |
| **Clear the Desk** (presentation mode) | One action, one undo: monitor off, phone face-down, a scripted brush pass sweeps loose piles under the mat, floor tokens arc onto the mat edge and tuck under, then "TIDY!". Layout only. |
| **Peek Desk** | Raises the panel to `.floating` and activates the app. A pixel "× Done" shows top-right. Exits on Esc, ×, the hotkey, the menu item, or another app activating. Optional global hotkey ⌃⌥⌘D through Carbon `RegisterEventHotKey` (no Accessibility permission); **off by default**. |
| **Pause Desk** | Orders the panels out; Finder's real desktop shows; the loop stops. |

### 2.3 Stretch

- **v0.2:**
  - laptop on a stand (노트북 거치대): `HingeSim` plus 5 pre-drawn lid frames; a closed lid hides its 4×2 screen;
  - sticky notes on the bezel (pinned items that stay visible when the monitor is off);
  - headphone stand with a Focus vignette;
  - lamp aim with 8 pre-drawn poses and beam-width scroll;
  - blinds;
  - mug;
  - Arrange Desk mode (casters, basket, lamp, phone);
  - mat Roll Up and edge overhang;
  - Walnut theme, Leather and Cork patterns;
  - degauss (⌥-click POWER);
  - in-app Record GIF with a virtual hand drawn only into frames;
  - synthesized sound (default off);
  - haptics;
  - Rename, New Folder, Paste (⌘V) through `FileOperator`;
  - `NSFilePromiseReceiver` drops;
  - "Use My Wallpaper…";
  - explicit "Set Matching System Wallpaper" (exports a still, applies it with `setDesktopImageURL`, offers restore);
  - screenshot photo tray;
  - Show Labels option;
  - rotating tip note;
  - robot vacuum (one run per click, never autonomous).
- **v0.3:** monitor arm with portrait pivot, shelf with bookends and file holder, letter tray, pegboard, calendar time filter, cardboard box, cable-tray "crouch", chair jacket (a second `ClothSim`), plant tidiness score, desk cat.

---

## 3. Icon lifecycle and file-safety model

### 3.1 Mirroring

1. **Locate (`DesktopLocator`):** use `--desktop-folder` or `DESKTERIOR_DESKTOP` if given, else `~/Desktop`. This is the **only** file allowed to construct the Desktop path; the lint enforces it.
2. **First-run gating:**
   - **Finder hides desktop items** (`com.apple.finder CreateDesktop == false`, or `com.apple.WindowManager StandardHideDesktopIcons == true`; read-only `CFPreferencesCopyAppValue`): the monitor shows a DESKTOP HIDDEN card asking "Show them on the desk anyway? [Show] [Keep hidden]". Keep hidden means no enumeration and no TCC prompt.
   - **Otherwise:** the screen shows **"PRESS ⏻ TO CONNECT DESKTOP"** and a KO/EN onboarding sticky note. Pressing power runs the first enumeration, so the TCC prompt (`NSDesktopFolderUsageDescription`) appears right after a user action.
   - **Denied** (`CocoaError.fileReadNoPermission`): a NO SIGNAL card with **[Open Settings]** (`x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders`) and **[Choose Folder…]** (`NSOpenPanel` preselected on `~/Desktop`; picking it grants access through user intent).
   - Later launches scan immediately.
3. **Scan (`DesktopScanner`, background):** top level only, with `.skipsHiddenFiles`. Keys: `.fileIdentifierKey`, `.volumeUUIDStringKey`, `.isDirectoryKey`, `.isPackageKey`, `.localizedNameKey`, `.hasHiddenExtensionKey`, `.contentTypeKey`, `.addedToDirectoryDateKey`, `.contentModificationDateKey`, `.fileSizeKey`, `.tagNamesKey`, `.isAliasFileKey`, `.ubiquitousItemDownloadingStatusKey`. The result is a `Sendable` `DesktopSnapshot`.
4. **Watch (`DesktopWatcher`):**
   - FSEvents flags: `FileEvents | UseCFTypes | UseExtendedData | WatchRoot`, latency 0.25 s, on a dispatch queue. `FSEventStreamScheduleWithRunLoop` is deprecated.
   - Extended data keys are the string literals `"path"` and `"fileID"`.
   - Each batch triggers a debounced 250 ms rescan, then a hop to `@MainActor`.
   - `RootChanged` (for example iCloud Desktop toggled) restarts the stream and does a full rescan. The app also rescans on wake and on session-active.
5. **Reconcile (`Reconciler`, pure):** `(state, snapshot, hints, now) → (state', [DeskEvent])`.

### 3.2 Identity

- **`TokenKey {volume: volumeUUIDString, inode}`** is the only Hashable identity. Name, kind and dates are mutable `TokenMeta`, so a rename keeps the same token, location and pile.
- **Match order:** inode, then (NFC name + kind), then tombstone.
- **Safe-save swap:** the same name reappearing with a new inode within one batch or 2 s keeps the token and re-keys it.
- **Tombstones:** keyed by identity plus name, **kept 7 days and persisted**. A returning file goes back to its old place, including hidden places.
- **Display and search** use NFC. Matching uses raw values.

### 3.3 New, removed and overflow

- **New files** (screenshots included; their dot-file-then-rename sequence is covered by the hidden-file filter plus rename diffs) go to the first free monitor cell scanning from HDMI 1, with print-in.
  - Our own operations (drops, undo) register `name → Location` hints with a 10 s TTL. A drop lands exactly where it was dropped.
  - If the monitor is off: amber pip plus "+N".
  - Bursts (for example unzipping 200 files) print in at most one row per frame.
- **Removed files:** poof at the token's location. In a closed container the count drops and the handle wiggles once; under the mat the bump shrinks. A 7-day tombstone is kept.
- **Overflow:** pages are unlimited; the INPUT OSD shows the count. Containers have hard caps and bonk beyond them.

### 3.4 Icons

- **Instant:** hand-drawn 16×16 and 12×12 kind icons: folder, doc, text, pdf, image, video, audio, zip, app, code, dmg, screenshot, unknown, plus an alias overlay. A 3-px stripe shows the Finder tag colour.
- **`IconProvider`** (at most 4 requests in flight, visible tokens first):
  - images, video, PDF: `QLThumbnailGenerator` (`.thumbnail`, 64 px);
  - apps and others: `NSWorkspace.icon(forFile:)` at 64 px;
  - then `IconPixelator`: trim to the alpha bounding box, area-average down (`.high` interpolation), threshold alpha at 0.45, OKLab-nearest Apollo colour (16 colours with Bayer dither for photos), remove orphan pixels, add a 1-px outline;
  - images get a 14×14 polaroid frame.
- **Dataless iCloud items** (`ubiquitousItemDownloadingStatus != .current`) get the kind icon only, so content is never read.
- **Cache:** `~/Library/Caches/<bundleID>/icons/<sha1(inode,mtime,size,kind,paletteVersion)>.png`.

### 3.5 File actions

| Action | Trigger | Performed by | Confirm | Undo |
|---|---|---|---|---|
| Open | double-click, ⌘O/⌘↓, menu, Inventory | `NSWorkspace.open` | — | — |
| Reveal in Finder | menu, Inventory | `activateFileViewerSelecting` | — | — |
| Quick Look | Space, menu, Inventory | `QLPreviewPanel`; `DeskView` is the controller in the responder chain | — | — |
| Copy | ⌘C, menu | pasteboard `NSURL`s | — | — |
| **Move to Trash** | **token context menu only** (no key equivalent) | `FileOperator.trash` → `NSWorkspace.recycle` | no (recoverable) | yes: renamex_np back from the returned Trash URL. If TCC blocks access to `~/.Trash` (S11), a toast says "Use Finder's Put Back" and the Trash opens |
| Empty Wastebasket… | basket menu, status menu | `FileOperator.trash(all)` | **sheet listing names** | yes (same as above) |
| Eject | drive menu | `FileOperator.eject` → `unmountAndEjectDevice(at:)` | — | — |
| Drag-out to another app | real drag hand-off (§3.6) | **the receiving app** (Finder, Mail, Dock) | — | the receiver's own Undo |
| Drop-in from outside | user's drop | `FileOperator.importItems` | — | yes |

### 3.6 Drag-out and drop-in

**Drag-out:**
- During a carry, each `mouseDragged` checks `NSWindow.windowNumber(at: NSEvent.mouseLocation, belowWindowWithWindowNumber: 0)`. If the window under the cursor is not ours, or if ⌘ was held at drag start, the app calls `view.beginDraggingSession(with: [NSDraggingItem(pasteboardWriter: url as NSURL)], event:, source:)` with the pixel icon and hides the carried sprite.
- Outside mask: `[.copy, .move, .link, .generic, .delete]`. The "Drag-out: Always copy" setting narrows it to `.copy`.
- Gesture state is reset in `draggingSession(_:endedAt:operation:)`, because AppKit swallowed the mouseUp. Then:
  - `[]`, `.copy`, `.link`: the token returns to its origin;
  - `.move`: the token is marked `pendingExternal` and the app waits 5 s for FSEvents to report the removal; if the file still exists, the token is restored;
  - `.delete` (Dock Trash): the app waits 1.5 s for FSEvents. If the file still exists, the drag itself was the explicit gesture, so the app performs `FileOperator.trash(origin: .dragToTrash)`, which is undoable. This covers both possible Dock behaviours (S4).

**Drop-in:**
- `registerForDraggedTypes([.fileURL])`, with `wantsPeriodicDraggingUpdates` driving highlights and spring-loading.
- Rules:
  - The item's parent is the desktop root → placement only.
  - Same volume, no ⌥ → **move** using `renamex_np(src, dst, RENAME_EXCL)`.
  - Cross-volume, or ⌥ → **copy** into the hidden name `.deskterior-partial-<uuid>`, then `renamex_np(..., RENAME_EXCL)` to the final name.
  - ⌘ forces a move on the same volume only. **Across volumes it is always a copy, never copy-then-delete.**
  - On `EEXIST`, retry " 2", " 3" and so on up to 100.
  - Folders and packages are handled as one unit.
- The work runs on the `FileOperator` actor with a progress token. Errors become a pixel toast plus a log entry.
- **Undo** moves the item back (RENAME_EXCL), or trashes our copy.
- **Drops on secondary-display Wall panels** route to the monitor's first free cell, with a toast "Desk lives on Display 1".

### 3.7 Safety invariants (enforced in code and CI)

1. **Only `DeskFiles/FileOperator.swift`** calls `recycle`, `trashItem`, `moveItem`, `copyItem`, `replaceItem`, `renamex_np`, `rename(`, `unlink(`, `copyfile(`, `removeItem` or `unmountAndEjectDevice`.
   - `removeItem` is allowed only for our own `.deskterior-partial-*` cleanup.
   - Writes inside our own roots are allowlisted per file: `StateStore` (state dir), `IconCache` (caches dir), `OperationLog` (state dir), `ArtifactWriter` (an explicit `--snapshot-dir`/`--frames-dir`, refused if it is under the desktop root), `FakeTrash` (state dir). Each asserts its path prefix at runtime.
2. **`ExplicitIntent{origin, issuedAt}`** is required by every mutating `FileOperator` method.
   - `DeskCore` and `DeskScene` cannot import `DeskFiles`, so they cannot create intents.
   - The lint fails on `ExplicitIntent(` outside `DeskteriorApp/Store/EffectRunner.swift`, which creates intents only in menu, confirm-sheet, drop, drag-to-Trash, Undo and Inventory handlers.
   - `FileOperator` rejects intents older than 10 s.
3. **Time-of-check guard:** immediately before acting, re-stat the file. If the inode or parent differs from what the token expects, abort with a toast.
4. **Root confinement:** targets must be direct children of the realpath'd desktop root. Drop sources and Trash URLs are the only exceptions.
5. **Never overwrite** (RENAME_EXCL everywhere). **Trash, never delete.**
6. **Append-only `operations.log`** in the state dir (rotated at 1 MB), plus `os_log`. Viewable from Settings.
7. **Demo, headless and test modes** use `DryRunFileActions`/`FakeTrash`. With `--demo`, `--headless` or `--windowed`, the app exits with code **64** if the desktop folder is missing or its realpath is the real `~/Desktop` or inside it.
8. **Never touched:** `com.apple.finder` defaults (read-only access only), `killall` is never run, and no network calls are made.
9. **Persisted:** layout (§13), settings, icon cache, operations log. **Never persisted:** file contents, thumbnails outside the cache, velocities, selection.

---

## 4. Architecture

### 4.1 Targets (full tree in §10)

| Target | Imports | Isolation | Role |
|---|---|---|---|
| `DeskCore` | Foundation, simd | none (Sendable values) | Model, reducer, reconciler, layout, pixel math, sprites as data, 1D sims, ballistics, cloth, raster, lighting, persistence schema, demo schema, strings |
| `DeskPixels` | CoreGraphics, ImageIO, CoreText | none | PixelBuffer ⇄ CGImage/PNG, icon and wallpaper pixelation, Galmuri rasterization, resource lookup |
| `DeskFiles` | Foundation, CoreServices, AppKit (recycle, eject) | none (actor) | Locator, scanner, watcher, volumes, FileOperator, intents, stores, cache, log, Finder prefs |
| `DeskScene` | SpriteKit, Metal, QuartzCore | `.defaultIsolation(MainActor.self)` | Scene, presenter, frame loop, elements, input, physics, FX, WallScene |
| `DeskteriorApp` (exe) | AppKit, SwiftUI, QuickLookUI, ServiceManagement, Carbon.HIToolbox | MainActor | Windows, displays, Store and EffectRunner, menus, Inventory, Settings, system observers, demo runner |
| `DeskAssetTool` (exe `deskterior-assets`) | DeskCore, DeskPixels | none | App iconset, sprite contact sheets, fixture PNG/PDF files |

**Assets:** there are no SwiftPM `resources:`, so `Bundle.module` and its fatalError never come into play. `ResourceLocator` looks for fonts in this order:
1. `Bundle.main.resourceURL/Fonts`
2. `$DESKTERIOR_RESOURCES`
3. `#filePath`-relative `Resources/Fonts` (dev and tests)

Goldens are also found via `#filePath`.

**Without a bundle:** under `swift run`, `AppIdentity` falls back to `io.github.surrealier.deskterior.dev` for the defaults suite and state paths, and the app calls `setActivationPolicy(.accessory)`.

### 4.2 Key types

```swift
// DeskCore
public struct TokenKey: Hashable, Codable, Sendable { public var volume: String; public var inode: UInt64 }
public struct TokenMeta: Codable, Sendable, Equatable { var name, displayName /*NFC*/: String; var kind: FileKind
  var added, modified: Date?; var size: Int64?; var tags: [String]; var isPackage, isDataless: Bool }
public enum ContainerID: String, Codable, CaseIterable, Sendable {
  case riserLeft, riserRight, riserCubby, cabinetTop, cabinetMiddle, cabinetFile, penCup, phone, wastebasket }
public enum Location: Codable, Hashable, Sendable {
  case screen(page: Int, col: Int, row: Int)
  case container(ContainerID, order: Int)
  case desk(pile: PileID, order: Int)      // covered-ness is derived from cloth, never stored
  case floor(x: Int)
  case carried                              // transient; never persisted
}
public struct ContainerSpec: Sendable { let capacity, hardCap: Int; let concealment: Concealment /* hidden|partial|anonymized */ }
public struct DeskState: Codable, Sendable { /* §13; invariant: every live token has exactly one Location */ }
public enum DeskAction: Sendable {
  case snapshot(DesktopSnapshot, now: Date), volumes([VolumeEntry]), accessDenied, accessGranted
  case move([TokenKey], to: Location), settle(SettleReport)              // settle = commits from scene motion
  case power(Bool), setPage(Int), drawerSettled(ContainerID, Float), phoneFlip, cupState(PenCupState), basketState(BasketState)
  case matSettled(MatState), pilesSettled([PileID: SIMD2<Float>]), chair(Float, Int), lights(LightsState)
  case takeAllOut(ContainerID?), takeEverythingOut, clearDesk, showOnDesk(TokenKey), undo, redo
  case requestOpen([TokenKey]), requestQuickLook([TokenKey]), requestReveal([TokenKey]), requestCopy([TokenKey])
  case requestTrash([TokenKey]), requestEmptyWastebasket, requestEject(String), importDropped([URL], at: Location, op: ImportOp)
  case clock(Date) }
public enum Effect: Sendable {
  case open([URL]), reveal([URL]), quickLook([URL]), copy([URL]), eject(String)
  case trash([URL], expected: [TokenKey], confirm: ConfirmKind?), importFiles([URL], op: ImportOp, hints: [String: Location])
  case play(AnimationID, AnimTarget), toast(StringKey), persist, wakeLoop, openPrivacySettings, chooseFolder }
public func reduce(_ s: inout DeskState, _ a: DeskAction, _ env: ReduceEnv) -> [Effect]   // pure; env = now, seed, layout, specs

// DeskFiles
public struct ExplicitIntent: Sendable { public let origin: Origin; public let issuedAt: Date }   // minted only in EffectRunner (lint)
public actor FileOperator {
  init(root: URL, trasher: Trasher, log: OperationLog, sandboxRoots: [URL]?)     // sandboxRoots non-nil in demo/tests
  func trash(_ urls: [URL], expecting: [TokenKey], _ i: ExplicitIntent) async -> TrashResult
  func importItems(_ urls: [URL], op: ImportOp, _ i: ExplicitIntent) async -> ImportResult
  func eject(_ volume: URL, _ i: ExplicitIntent) async throws
  func undo(_ r: FileUndoRecord, _ i: ExplicitIntent) async throws }

// DeskScene
@MainActor protocol DeskElement: AnyObject {
  var id: ElementID { get }; var root: SKNode { get }
  func layout(_ l: SceneLayout); func apply(_ s: DeskState)
  func hitTest(_ p: ArtPoint) -> Hit?; func hover(_ h: Hit?)
  func handle(_ g: Gesture, _ h: Hit) -> GestureResponse            // .handled / .drag(DragController) / .pass
  func dropVerdict(_ t: [TokenKey], at: ArtPoint) -> DropVerdict?   // .accept(Location) / .bonk
  func step(_ dt: Float); var needsFrames: Bool { get }
  func menu(_ h: Hit) -> MenuSpec?; func accessibilityItems() -> [AXItem] }
public struct InputEvent: Sendable { var kind: Kind; var art: SIMD2<Float>; var mods: Mods; var clickCount: Int; var scroll: SIMD2<Float>; var t: Double }
```

### 4.3 Data flow

```
~/Desktop ─FSEvents─► DesktopWatcher ─250ms─► DesktopScanner ─► Snapshot ─┐
NSWorkspace mount ─► VolumeWatcher ───────────────────────────────────────┤
NSEvent ─► DeskView ─px→art─► InputEvent ─► InputRouter ─► DeskElement ───┼─► Store.dispatch(DeskAction)
DemoRunner (JSON) ────────────────────────► InputRouter                   │      │ reduce(DeskState) (pure)
FrameLoop tick: 1D sims · ClothSim · DeskPlaneWorld · Ballistics          │      ├─► SceneSync → elements.apply(state) → FrameLoop.wake
     └─ settle commits (drawerSettled/pilesSettled/matSettled/…) ─────────┘      └─► [Effect] → EffectRunner → NSWorkspace / QL / sheets
                                                                                       / FileOperator(ExplicitIntent) / StateStore (debounced 1 s)
```

Continuous motion never dispatches per frame. Only settles and user intents reach the model.

### 4.4 Scene graph

```
DeskScene (size = art × U, anchor .zero, ignoresSiblingOrder = false; explicit setup, no didMove(to:))
├─ world (core offset × U)
│  ├─ L0 backdrop: wall/floor extension tiles, window, clock, calendar, switch
│  ├─ L1 desk-back: plant, lamp, monitor(bezel, screen tokens, CRT overlay, chin, badge), riser + drawer fronts + interiors, phone stand, hub
│  ├─ L2 deskSurface sprite (DeskSurfaceRaster → SKMutableTexture)
│  ├─ L3 desk-front props: keyboard, brush, pen cup
│  ├─ L4 apron  ├─ L5 under-desk: cabinet + interiors, wastebasket + heap, floor tokens  ├─ L6 chair
│  ├─ L7 fx (puffs, sparkles, text pops, ballistic tokens)  ├─ L8 carry (carried tokens, drop highlight)
│  └─ L9 ui (tooltips, toasts, onboarding/tip notes, mat handles, Peek "× Done")
└─ physicsRoot (never transformed): desk-plane bodies only (invisible nodes; gravity (0,0))
```

**Hit-test order** (front to back, pixel-precise alpha masks, light-filtered): ui → carry → chair → under-desk → L3 props → desk surface `owner[]` → L1 (riser, phone, hub, monitor controls, screen tokens) → wall objects → background (wall menu).

**Proxy snapping:** pile positions snap to whole art px with 0.75-px hysteresis before they reach the raster.

### 4.5 Window, activation and keys (decided; spike S2)

- **`DeskWindow: NSWindow`** (borderless, *activating*, matching Finder's desktop behaviour):
  - level `CGWindowLevelForKey(.desktopIconWindow) + 1` (hidden setting: +3);
  - `collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]`;
  - `hidesOnDeactivate = false`, `canHide = false`, `isMovable = false`, `isRestorable = false`, `animationBehavior = .none`, `isExcludedFromWindowsMenu`, `hasShadow = false`, opaque black background;
  - `canBecomeKey = true`, `canBecomeMain = false`;
  - shown with `orderFrontRegardless()`; `makeKeyAndOrderFront` is never called at launch.
- **Clicks:** a click on the desk activates Deskterior (`acceptsFirstMouse = true`, so the click also acts). Keys then route normally, and `NSApp.isActive` is truthful. When the user clicks another app, focus leaves normally. This removes the stale-key problem of non-activating panels.
- **Main menu** (shown while active):
  - Deskterior: About, Settings…, Pause Desk, Quit;
  - Edit: Undo, Redo, Copy, Select All;
  - Desk: Monitor Power, Lights ▸, Find Item… ⌘F, Take Everything Out, Clear the Desk, Peek Desk;
  - Window: Inventory.
  - No destructive key equivalents.
- **Fallback if S2 fails:** a non-activating `NSPanel` whose `canBecomeKey` returns `keyArmed` (true for 60 s after a desk click; cleared on `didActivateApplicationNotification`). It accepts only the non-destructive keys and activates the app explicitly for Quick Look, Inventory and Settings.
- **`DeskView: NSView`:**
  - `wantsLayer`; `makeBackingLayer()` returns a `CAMetalLayer`;
  - `.activeAlways | .mouseMoved | .mouseEnteredAndExited | .inVisibleRect` tracking area;
  - drag source and destination;
  - `QLPreviewPanel` controller;
  - `accessibilityChildren` returns `NSAccessibilityElement`s built from `accessibilityItems()`. Visible controls, containers and tokens get a label, a frame, the press action and custom actions (Open, Move to…, Take Out). The tree is rebuilt on state change, never per frame.

### 4.6 Frame loop (`FrameLoop`)

- `view.displayLink(target:selector:)` (macOS 14+), `link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)`. `preferredFramesPerSecond` is unavailable on macOS.
- Fixed step `simTime += 1/60`, at most 2 steps per tick, so there is no dt explosion after a pause.

**Tick order:**
1. input (carry, velocity drives)
2. `element.step` (1D sims, tweens, machines, ballistics)
3. `cloth.step` if awake
4. `renderer.update(atTime:)` (Box2D)
5. `didSimulatePhysics` zone tests and settles
6. raster and proxies (only if dirty)
7. light mask (only if dirty)
8. art pass, lit pass, upscale
9. rest check

**Rest and sleep:**
- **Rest:** no carry or grab; no element needs frames; cloth asleep (max |v| < 0.5 px/s for 30 frames); bodies resting or below 2 u/s. After 30 rest frames, `link.isPaused = true`.
- **Hard sleep:** 3 s after the later of the last input and the end of the last scripted animation, the loop forces rest: `Freezer` freezes bodies, `cloth.forceSleep()` accepts the quantized pose, and the link pauses.
- **No unbounded animation:** the AV logo is capped at 10 s, the CRT at 0.7 s, parades at 3 s.

**One-shot frames:** `renderOnce()` (dt = 0) for hover changes, tooltips, the minute clock, and file events that don't move anything.

### 4.7 Physics summary

- **One Box2D world:** the top-down desk plane, gravity 0 (bitmasks in §12).
  - Covered piles have **no body**; one is recreated when the pile is revealed.
  - Bodies are never teleported. Transfers destroy and recreate them.
- **Not in Box2D:** drawers (`DrawerSim` and `ContentJostle`), chair (`RollerSim`), falls and tosses (`Ballistics`), cloth (XPBD).
- **Freezer:** a pile resting for 2 s becomes static. It thaws on a nearby brush, cup or carried token, a knock, or a drag. At most 120 dynamic bodies.
- **Watchdog:** NaN, out of bounds, or awake for more than 10 s snaps the pile to the nearest valid desk spot (the monitor as a last resort) and logs it.

### 4.8 Persistence and settings

- **Layout:** `~/Library/Application Support/<bundleID>/desk.json` (schema in §13), with rotating backups `.bak1…3`.
  - Atomic write, debounced 1 s after a committed change; also written on quit, sleep and session resign.
  - Corrupt file → load `.bak1`, then the next backup. If all fail, start fresh and keep the bad file as `desk.corrupt-<date>.json`.
- **Coordinates are element-relative:** container/order, page/cell, desk plane, mat in desk plane, floor x. Plus a `layoutVersion` with a migration table.

**Settings** (`UserDefaults`, bundle-id suite):

| Key | Default |
|---|---|
| `launchAtLogin` (mirrors `SMAppService.mainApp`; only the toggle registers) | **false** |
| `deskDisplayUUID` | menu-bar screen |
| `coverOtherDisplays` | asked once in onboarding when more than one display (preselected: Cover) |
| `pixelSize` | normal (380) |
| `lights` | auto |
| `iconStyle` | pixel (pixelated real icons) |
| `dragOutMode` | finderLike |
| `peekHotkeyEnabled` | **false** (⌃⌥⌘D) |
| `pauseOnBattery` | false |
| `reduceMotion` | follow system |
| `windowLevel` (hidden) | aboveIcons (+1) |
| `matMode` (hidden) | cloth |
| `showDespiteFinderHidden` | unset (asked) |
| `onboardingStep` | 0 |

### 4.9 Menus

- **Status item** (16-pt pixel template rendered from an `IndexedSprite`):
  - Monitor Power ✓
  - Lights ▸ (Auto · Day · Night · Lamp Only · Room Light ✓ · Desk Lamp ✓)
  - Find Item…
  - Take Everything Out
  - Clear the Desk
  - Peek Desk
  - Smooth Desk Mat
  - Empty Wastebasket… (n)
  - Undo ‹op›
  - Pause/Resume Desk
  - Open Desktop Folder in Finder
  - Desk Display ▸
  - Settings…
  - About & Credits
  - Check for Updates… (opens the Releases URL in the browser)
  - Quit Deskterior
- **Fallback:** the same items appear on right-click of the bare wall, because macOS 26 lets users hide menu-bar extras.
- **Context menus** are built from `MenuSpec` data (testable and scriptable): token, container, mat, monitor and drive menus, as listed in §2.

### 4.10 Multi-display

- **One window per `NSScreen`**, keyed by `NSScreenNumber`. `cgDirectDisplayID` is 26+ only. Persistence uses `CGDisplayCreateUUIDFromDisplayID`.
- **Desk display:** full `DeskScene` and `FrameLoop`.
- **Other displays** (if `coverOtherDisplays`): a static `WallScene` rendered once and re-rendered only on size or palette change. Zero idle cost. Accepts file drops (routed to the monitor). Right-click opens the desk menu.
- **`didChangeScreenParameters`** (debounced 0.5 s): diff the screens; `setFrame` and a new grid for existing windows; create and close as needed. If the desk display disappears, the desk moves to the menu-bar screen.

### 4.11 Dev flags (`LaunchOptions`; also `DESKTERIOR_*` env)

| Flag | Effect |
|---|---|
| `--desktop-folder <dir>` | Mirror this folder |
| `--state-dir <dir>` | Isolated persistence, cache and log |
| `--windowed [WxH@scale]` | Titled normal window emulating a display (development) |
| `--headless` | Offscreen `SKRenderer`, no window; steps as fast as possible |
| `--demo <file.json>` | Run a demo script. Requires a non-real `--desktop-folder`; implies DryRun/FakeTrash |
| `--snapshot-dir <dir>` · `--snapshot-scale N` · `--frames-dir <dir>` | PNG output (art-res plus nearest ×N); every rendered frame |
| `--clock <HH:MM or ISO8601>` · `--seed N` · `--icons kind\|live` | Determinism |
| `--lights auto\|day\|night\|lamp` · `--reduce-motion` | Lights mode (not saved); Reduce Motion forced on |
| `--level icon+1\|icon+3\|normal` | Window level |
| `--tunables <json>` | Hot-reloaded cloth and physics constants (`Tunables`; dev only) |
| `--record-input <file.json>` | Record real pointer events as a replayable demo |
| `--show-hit` · `--show-physics` · `--perf-hud` · `--perf-log <csv>` | Diagnostics |
| `--safe-mode` (or ⌥ held at launch) | Start paused; show the Safe Mode window (Resume, Take Everything Out, Reset Desk Layout…, Open State Folder, Quit) |
| `--print-window-id` · `--exit-after-demo` · `--reset-state` | Tooling |

**Demo script** (`Demos/*.json`, anchors resolved through `Anchors`; no CGEvents, so no Accessibility permission):

```json
{ "name": "drawers", "display": "2940x1912@2", "clock": "10:00", "seed": 1,
  "steps": [ { "waitIdle": 3 }, { "snapshot": "01-start" },
    { "drag": { "from": "token:보고서.pdf", "to": "cabinet.top.front", "duration": 0.6 } },
    { "expect": { "token:보고서.pdf": "container:cabinetTop", "hidden": true } },
    { "click": "cabinet.top.handle" }, { "waitIdle": 2 }, { "snapshot": "02-open" },
    { "fs": { "touch": "새 파일.txt" } }, { "waitIdle": 2 }, { "expect": { "token:새 파일.txt": "screen" } },
    { "menu": { "at": "wastebasket", "item": "emptyWastebasket", "confirm": true } },
    { "click": "monitor.power" }, { "waitIdle": 2 }, { "snapshot": "03-off" } ] }
```

Exit codes: 0 pass, 1 expectation failed, 2 script error, 64 guard refusal.

---

## 5. Performance and idle

| State | Target (M-series, release) | Mechanism |
|---|---|---|
| **Idle at rest** | **≤ 0.3% CPU** averaged over 60 s; ≤ 1 wakeup/s; 0 GPU frames | Display link paused; minute `Timer` (tolerance 2 s) → `renderOnce`; FSEvents is the only other wakeup |
| Hover | ≤ 3% | Hit-test on `mouseMoved`; render only when the target changes |
| Carry, drawers, flings | ≤ 8% | Art-res SKRenderer (~0.23 MP) plus 2 tiny passes |
| Mat awake | ≤ 12% of one core; cloth step ≤ 0.6 ms + raster ≤ 0.6 ms | Unsafe buffers; preallocated constraints; upload only while awake |
| Frame budget | ≤ 4 ms CPU | Box2D ≤ 1.0, cloth 0.6, raster 0.6, encode 0.6 |
| Launch with 500 files | First frame ≤ 1 s | Kind icons first; thumbnails streamed in |
| Memory | ≤ 150 MB RSS with 500 tokens; < 10 MB growth over a 1 h soak | Art-res textures; fixed-size mutable surface texture |

- **Pause sources:**
  - occlusion without `.visible` (verified in S3);
  - `screensDidSleep`, `sessionDidResignActive`, the `com.apple.screenIsLocked` distributed notification;
  - Pause Desk;
  - optionally running on battery.
- **Low Power Mode or `thermalState ≥ .serious`:** no AV animation, interactions capped at 30 fps.
- **Measurement:**
  - `scripts/measure-idle.sh` launches the release build with a fixture, runs a scripted interaction burst (`--demo Demos/burst.json` without exit), waits 15 s, then samples `top -l 31 -s 2 -pid $PID -stats cpu,idlew`. It fails above 0.3%.
  - `scripts/soak.sh` runs 1 h and fails on RSS growth over 10 MB.
  - Performance is profiled only with `-c release`.

---

## 6. Distribution and GitHub

**`scripts/build-app.sh --version X.Y.Z [--universal]`** (`set -euo pipefail`):
1. For each arch in `${ARCHS:-arm64}` (CI release: `arm64 x86_64`), run `swift build -c release --product Deskterior --triple $a-apple-macosx14.0`, then `lipo -create`. Never pass multiple `--arch` flags; that path needs Xcode.
2. Assemble `build/Deskterior.app/Contents/`:
   - `MacOS/Deskterior`;
   - `Info.plist` from the template via `plutil -replace` (§11), then `plutil -lint`;
   - `Resources/AppIcon.icns`, `Resources/Fonts/{Galmuri9.ttf, OFL-Galmuri.txt}`, `Resources/{LICENSE, THIRD_PARTY_NOTICES.md}`, `Resources/{en,ko}.lproj/InfoPlist.strings`.
3. **Sign last:** `codesign --force --sign "${SIGN_IDENTITY:--}" --timestamp=none build/Deskterior.app`. Ad-hoc by default; no `--deep`.
4. Verify: `codesign --verify --strict --verbose=2` and `codesign -dr -`.
5. With `ZIP=1`: `ditto -c -k --sequesterRsrc --keepParent`, then `shasum -a 256 > .sha256`.

**Optional stable identity (still zero cost):** a self-signed Code Signing certificate stored as the `SIGNING_P12_BASE64` and `SIGNING_P12_PASSWORD` secrets. `ci-import-identity.sh` imports it into a throwaway keychain (`create-keychain`, `import -T /usr/bin/codesign`, `set-key-partition-list -S apple-tool:,apple:`), and an `if: always()` step deletes it. This keeps Desktop TCC and the login item across updates. Steps are in `docs/SIGNING.md`.

**Icon:**
- `swift run deskterior-assets icon --out Packaging/AppIcon.iconset` renders the 32-px master `IndexedSprite` (a full-bleed rounded square for Tahoe: oak desk with a glowing monitor) with integer nearest scaling to 16–1024 including @2x.
- `iconutil -c icns` builds the `.icns`, which is committed. ffmpeg is not needed.

**`.github/workflows/ci.yml`** (push, PR; `permissions: contents: read`; `runs-on: macos-26`):
1. checkout@v5
2. `swift --version`
3. `swift build`
4. `swift test --disable-xctest` (Metal-gated suites may skip)
5. `scripts/check-file-safety.sh`
6. `ARCHS=arm64 scripts/build-app.sh --version 0.0.0-ci`
7. Upload the zip as an artifact on `main`

**`.github/workflows/release.yml`** (tags `v*`):
- `test` job: as in ci.yml.
- `release` job (`needs: test`; permissions `contents: write, id-token: write, attestations: write`; job-level `env: HAS_P12: ${{ secrets.SIGNING_P12_BASE64 != '' }}`, because secrets cannot be used directly in `if:`):
  1. Import the identity `if: env.HAS_P12 == 'true'`.
  2. `ARCHS="arm64 x86_64" ZIP=1 scripts/build-app.sh --version ${GITHUB_REF_NAME#v}`.
  3. Verify.
  4. `actions/attest-build-provenance@v2` on `build/Deskterior-*.zip`.
  5. `gh release create "$GITHUB_REF_NAME" build/Deskterior-* --notes-file .github/release-notes.md --generate-notes --verify-tag` with `GH_TOKEN: ${{ github.token }}`.
  6. Delete the keychain (`if: always()`).

**README.md (EN) and README.ko.md (KO)**, cross-linked at the top:
1. Hero GIF, built from `--frames-dir` with `scripts/make-gif.sh` (ffmpeg nearest ×3, palettegen with `dither=none`).
2. What it is, and a table of hiding spots.
3. Gesture table.
4. **Safety promise:** "Deskterior never moves, renames or deletes your files on its own. Files change only when you explicitly: Move to Trash, Empty Wastebasket… (with confirmation), Eject, drop files onto the desk, or drag a file out to Finder, Mail or the Trash, exactly like Finder. Quitting brings back your normal desktop. No network, no telemetry, no Accessibility, Screen Recording or Input Monitoring." Also the non-destructive un-hiding rule.
5. **Install:**
   1. Download the zip, unzip, and move `Deskterior.app` to /Applications first (this avoids App Translocation; the app also detects `/AppTranslocation/` and asks you to move it).
   2. Open it. The dialog says "Not Opened"; click **Done**.
   3. Go to System Settings → Privacy & Security → **Open Anyway** (available for about an hour), enter your password, and confirm.
   4. Repeat for every new version. Control-click → Open no longer works since macOS 15.
   - Advanced, and labelled risky: `xattr -dr com.apple.quarantine /Applications/Deskterior.app`.
   - Verify the download: `gh attestation verify Deskterior-X.zip -R <owner>/deskterior`.
6. Build from source: `make app && make install`. Locally built apps carry no quarantine.
7. **Permissions:** Desktop folder access and why; with ad-hoc builds macOS may ask again after each update.
8. **Known behaviour:**
   - Finder icons are covered, not changed (use Pause Desk, Peek Desk or Quit);
   - "click wallpaper to reveal desktop" does not work over the desk (use Show Desktop with F11 or the gesture, or Peek Desk);
   - widgets sit above the desk;
   - scaled display modes are slightly soft;
   - Finder ⌘⌫ caveat with a stale hidden Finder selection;
   - if the app hangs, run `killall Deskterior`.
9. **Uninstall:** quit, delete the app, `~/Library/Application Support/<bundleID>` and `~/Library/Caches/<bundleID>`, then `tccutil reset SystemPolicyDesktopFolder <bundleID>`.
10. **Credits:** "Deskterior is an independent project inspired by Terkel Gjervig's desktop-rug prototype *Desktop Cleaning* (desktop.cleaning). It is not affiliated with or endorsed by him or GitHub, and uses none of its code, name, art or branding." Never use "Rugs" or the site's visuals. No code from the GPL-3.0 remake t42ji2ji/desktop-rug.
11. **License:** code MIT. Galmuri by Lee Minseo, v2.40.4, SIL OFL-1.1, shipped with `OFL-Galmuri.txt` and not relicensed. Apollo palette by AdamCYounis, credited in `THIRD_PARTY_NOTICES.md` and in About.

**Publishing** happens only after the user runs `gh auth login` and gives an **explicit go-ahead**: `gh repo create deskterior --public --source . --remote origin --push`, then `git tag v0.1.0 && git push origin v0.1.0`. The bundle id is fixed before the first release and never changes afterwards.

---

## 7. Milestones (overview; detailed steps and acceptance in §14)

| # | Milestone | Depends on | Parallel track |
|---|---|---|---|
| M0 | Bootstrap (nested repo, package, lint, CI) | — | — |
| M1 | Pixel and text foundation | M0 | — |
| M2 | Presenter, window, frame loop **plus spike gate S1–S12** | M1 | after M2: A (M3), B (M8), C (M4 file layer), D (M13 skeleton) |
| M3 | Room art, layout, lighting | M2 | A |
| M4 | Mirror, model, screen, onboarding | M2 | C |
| M5 | Interaction core, monitor, Inventory | M3, M4 | — |
| M6 | Containers: riser, cabinet, phone, cup, basket, chair | M5 | — |
| M7 | Desk-plane physics, ballistics, knock, tips | M6 | — |
| M8 | Cloth core (pure) | M1 | B |
| M9 | Mat integration, brush, Clear the Desk | M7, M8 | — |
| M10 | Lighting interactions (Lamp Only, clock preview) | M3, M5 | — |
| M11 | File I/O (FileOperator, drag-out, drop-in, trash, eject, volumes) | M5 | C |
| M12 | System integration (displays, Peek, pauses, login item, settings, safe mode, accessibility, onboarding) | M9, M11 | — |
| M13 | Packaging, docs, release | M12 | D |

---

## 8. Verification plan

**8.1 Unit tests** (swift-testing; `swift test --disable-xctest`; CPU-only suites run on CI):

- **DeskCoreTests:**
  - `PixelGrid` over the §1.2 table plus Dock and menu-bar variants; the core always fits.
  - `LayoutSolver`: all interactive anchors inside the visible band, and widget nudge.
  - Projection round-trips.
  - `IndexedSprite`: ragged sprites rejected, keys valid.
  - LUT closure: every palette colour maps to itself through the 64³ index; every ramp output is in the palette.
  - `ScreenGrid`: nearest free cell, overflow and pruning, clean-up sorts.
  - `Reconciler`: rename keeps the location; safe-save swap; 7-day tombstone restore; hints; burst order; NFD→NFC.
  - `Reducer`: one test per action. **Only `.trash`, `.importFiles` and `.eject` effects touch files**, and only from request actions.
  - `TokenStore` invariant property test (random moves keep exactly one location per token).
  - `DropResolver` z-order; `MenuSpec` per target; `UndoJournal`.
  - Machines: `DrawerSim` (jam gap = f(n), slam event, chair block limit), `ContentJostle` bounds, `RollerSim`, `Ballistics` (swish, rim, miss), `MonitorMachine`, `PhoneMachine`, `PenCupMachine` (tips only by gesture), `WastebasketMachine` (cap, no auto-spill), `DeskKnock` (never changes membership).
  - `TimeOfDay` table; `LightMask` goldens.
  - Cloth:
    - settles flat;
    - bump height increases with n;
    - a tug cuts the wrinkle metric W by more than 60%;
    - a fold persists for 300 steps;
    - transform keeps area within 3%;
    - two seeded runs are bit-identical;
    - a 10k-step seeded fuzz produces no NaN;
    - coverage hysteresis.
  - Raster goldens (exact, fixed point): flat, 3 bumps, peel revealing a pile, fold, rotated 30°.
  - `DeskDocument` round-trip, v1 fixture decode, migration, corrupt-file fallback; `DemoScript` decode.
- **DeskPixelsTests:**
  - icon pixelation goldens from checked-in PNGs;
  - Galmuri goldens: "보고서 final.pdf" from NFD input equals the NFC rendering, binary alpha, middle truncation, fallback glyph;
  - PNG byte-order round-trip.
- **DeskFilesTests**, all under `FileManager.temporaryDirectory/deskterior-tests-<uuid>`:
  - scanner keys; watcher end-to-end (add, rename, safe-save, delete, dot-file then rename, burst of 200);
  - `FileOperator`: collision " 2"; **a destination planted between the check and the move is never overwritten** (`renamex_np` returns EEXIST); time-of-check abort; sandbox rejection; stale intent rejected; FakeTrash undo; partial-file cleanup; cross-volume decision with injected volume ids never deletes the source;
  - `DesktopLocator` refuses the real Desktop (exit 64 path);
  - **`FileSafetyLintTests`** runs the same scan as `check-file-safety.sh` over `Sources/` via `#filePath`, including a planted-violation fixture.
- **DeskSceneTests** (`@MainActor`, `.enabled(if: MTLCreateSystemDefaultDevice() != nil)`):
  - offscreen `SKRenderer` calibration: every palette colour round-trips; `SKTexture(data:)` row order; art→S×S upscale exactness;
  - physics calibration: velocity units, resting gap with the 1-px inset;
  - a brush sweep for 300 steps keeps all piles in bounds or properly transferred;
  - same final-state hash across two runs;
  - reference-scene snapshot with a small tolerance.

**8.2 Scripted demos and screenshots** (never the real `~/Desktop`):
- **`scripts/make-fixture-desktop.sh <dir>`** refuses any target under `$HOME/Desktop`. It creates about 40 items:
  - NFD Korean names, emoji, 80-char names;
  - a folder and an `.rtfd` package;
  - png and pdf files (made with `deskterior-assets fixture`), txt, zip;
  - a screenshot-named png and dot-files.
  - `--count 500` creates the performance fixture.
- **`scripts/run-demo.sh [name]`** creates a fresh `mktemp -d` fixture and state dir, then runs
  `swift run -c release Deskterior --headless --demo Demos/<name>.json --desktop-folder … --state-dir … --seed 1 --snapshot-dir .build/demo-out/<name> --snapshot-scale 3`.
  Failing `expect` steps return non-zero. The agent reviews the ×3 PNGs with the Read tool.
- **Demos:**
  - `00-layout`, `12-sizes` (9 displays × day/dusk/night)
  - `01-mirror`, `09-fs-events`
  - `02-monitor-power` (including AV, badge)
  - `03-drawers` (chomp, jam, chair block)
  - **`04-rug-homage`** (O1–O10, one snapshot per step plus a frame dump)
  - `05-pencup-spill`
  - `06-wastebasket` (swish, rim, miss, Empty with FakeTrash)
  - `07-night-lamp`
  - `08-phone`
  - `10-clear-desk`
  - `11-overflow-500`
  - `burst`
- **Windowed composite check:** `swift run Deskterior --windowed 1470x956@2 --desktop-folder <fixture> --state-dir <tmp> --print-window-id`, then `screencapture -x -o -l <id> .build/live.png`. This needs Screen Recording permission for the terminal, granted once by a human. Desktop-level placement is checked manually.

**8.3 Manual checklist** (release build in /Applications, macOS 26.6):
1. The desk covers Finder icons. Widgets stay on top and usable. The menu bar, notch and the 81-pt strip look right.
2. Clicking does not trigger "click wallpaper to reveal". Spaces, Mission Control, Show Desktop and Stage Manager behave.
3. Clicking activates the app (Finder-like). Space opens Quick Look, ⌘Z works, Esc works. Keys never reach the desk after clicking another app.
4. Hover works while another app is frontmost.
5. TCC: the prompt appears only after pressing ⏻. Deny → NO SIGNAL → Choose Folder works. Finder-hidden preference → the Ask card appears.
6. A screenshot lands on the monitor. An iCloud dataless item shows its icon without downloading.
7. Every hiding spot hides and reveals: power, AV, both riser drawers, cubby, 3 cabinet drawers, phone, cup, basket, mat, Lamp Only. Find, Show on Desk, Take Everything Out and Clear the Desk (with undo) work.
8. Overfill bonks; jammed drawers stay closed under a knock; nothing un-hides without a direct gesture.
9. Mat: carry wrinkles, peel→grab→lay back, fold persists, tug smooths, ⌥ resize and rotate, brush and scroll sweep under, bumps grow with stacks.
10. Drag-out: to a Finder window (move), to Mail (copy), to the Dock Trash (trashed exactly once).
11. Drop-in: same volume (move), external volume (copy), ⌥ (copy), collision (" 2"). Undo each.
12. Move to Trash and its Undo. Empty Wastebasket: confirm lists names; Cancel does nothing.
13. Drives appear in the hub; Eject works.
14. Multi-display: the cover prompt appears; drops on the Wall go to the monitor; hotplug; changing the desk display; Dock position and auto-hide.
15. Full-screen app, sleep/wake, lock, fast user switching, Low Power Mode: the loop pauses and resumes with no physics explosion.
16. Peek Desk via menu and via the opt-in hotkey. Safe mode with ⌥ at launch.
17. Launch at Login is off by default; turning it on shows "Login item added"; after a version bump it still launches.
18. Quit or crash brings Finder's icons back. `ls -li ~/Desktop` is unchanged before and after a full session without explicit file actions.
19. VoiceOver reads tokens and controls. The Inventory is fully keyboard-accessible.
20. `make idle` ≤ 0.3%. The 1-hour soak passes. The Safari-downloaded zip goes through the Open Anyway flow.

---

## 9. Risks and mitigations

| Risk | Mitigation |
|---|---|
| Cloth instability, tuning time, or debug slowness | Built as pure M8 in parallel; XPBD small steps; normal-based layering; per-substep displacement clamp; parametric fold plan B; `matMode=flat`; `--tunables` hot reload and `--record-input` replays; measured only in release |
| SKRenderer pipeline (colour drift, row order, drawable reset) | S5 calibration goldens; 64³ index LUT absorbs drift; no crop nodes; `drawableSize` re-asserted; SKView presenter fallback |
| Desktop-level window quirks (activation, 81-pt strip, reveal-click, occlusion) | Spikes S1–S3 with named fallbacks; hidden level setting; rest-pause makes occlusion non-critical |
| Data loss | One `FileOperator`; `ExplicitIntent` plus lint; RENAME_EXCL; time-of-check guard; Trash only; confirm on Empty; Undo; op log; DryRun/FakeTrash; real-Desktop guard (exit 64); no destructive key equivalents |
| Hidden files resurfacing (screen-sharing) | Non-destructive rule; overfill bonks; knocks never empty containers; secondary displays covered |
| "Where did my file go?" | Inventory, Show on Desk, Take Everything Out, contents menus, onboarding note, basket tooltip |
| Battery drain | Paused at rest, 3-s hard sleep, every animation bounded, no ambient effects in v0.1, idle gate after a burst, soak test |
| Physics explosions or tunnelling | One Box2D plane, fixed step, CCD, speed clamps, no rotation, 1-px insets, no bodies for covered piles, Freezer, Watchdog |
| Swift 6 concurrency with SpriteKit and FSEvents | MainActor default isolation in UI targets; Sendable snapshots; geometric zone tests instead of contact delegates; `@preconcurrency` where needed |
| Ad-hoc signing causing TCC re-prompts and stale login items | README; re-register the login item when the version changes; optional self-signed CI identity |
| Gatekeeper friction | EN/KO Open Anyway steps; build from source; attestation |
| Universal build failing with the CLT only | Per-triple builds plus `lipo`; local `ARCHS=arm64`; CI builds universal |
| CI VMs without Metal | Gated suites; CPU goldens carry coverage; demos run locally |
| Widgets covering the desk, notch, Dock | `WidgetProbe` nudge plus tip; layout from `visibleFrame` |
| Accidental commit into the parent repo | `git init -b main` inside the project; `show-toplevel` checked before every commit; `.claude/` ignored; parent exclude only with user consent |
| IP and branding | Original code-drawn art; credit plus "not affiliated" line; no GPL code |
| App hang blocking the desktop | All I/O off the main thread; README `killall`; status item, wall menu, opt-in hotkey; safe mode |

---

## 10. Final repository file tree

```
deskterior/ (its own git repo)
├─ Package.swift                    targets/products (§4.1); platforms .macOS(.v14); tools 6.2
├─ Makefile                         build · test · lint · app · install · run · demo · gif · idle · soak · clean
├─ LICENSE (MIT) · README.md · README.ko.md · THIRD_PARTY_NOTICES.md · CHANGELOG.md
├─ .gitignore                       .build/ build/ .claude/ .DS_Store *.xcuserstate
├─ .github/workflows/ci.yml · release.yml · .github/release-notes.md (Gatekeeper steps EN/KO)
├─ docs/DESIGN.md (this spec) · SPIKES.md (S1–S12 results) · SIGNING.md · media/{hero.gif, *.png}
├─ Packaging/Info.plist (template) · AppIcon.icns · AppIcon.iconset/ · en.lproj/InfoPlist.strings · ko.lproj/InfoPlist.strings
├─ Resources/Fonts/Galmuri9.ttf · OFL-Galmuri.txt
├─ Demos/*.json                     scripted interactions (§8.2)
├─ scripts/ build-app.sh · make-icon.sh · make-fixture-desktop.sh · run-demo.sh · make-gif.sh · measure-idle.sh · soak.sh
│          check-file-safety.sh · ci-import-identity.sh
├─ Sources/DeskCore/
│  ├─ Util/SeededRandom.swift          SplitMix64; all randomness seeded
│  ├─ Util/Tunables.swift              every feel constant in one Codable struct (hot-reloadable in dev)
│  ├─ Geometry/IntGeometry.swift       ArtPoint/ArtSize/ArtRect, y-down↔y-up conversion
│  ├─ Geometry/Projection.swift        desk plane (x,d,z) ⇄ art; inverse at z; depth keys
│  ├─ Geometry/PixelGrid.swift         S, canvas, crop, pt↔art mapping (§1.2)
│  ├─ Layout/CoreLayout.swift          512×320 rects and footprints (§1.3)
│  ├─ Layout/LayoutSolver.swift        core placement in canvas; menu/Dock bands; widget nudge
│  ├─ Layout/Anchors.swift             named anchors ("monitor.power", "cabinet.top.handle", "mat.edge.e") for hits/demos
│  ├─ Pixel/Palette.swift              Apollo 46 hexes, ramps, roles, Oak theme map
│  ├─ Pixel/OKLab.swift                colour conversion, nearest-palette search
│  ├─ Pixel/IndexLUT.swift             64³ RGB→index table bytes
│  ├─ Pixel/LightRamp.swift            index × level × tint table
│  ├─ Pixel/Dither.swift               Bayer 4×4 thresholds
│  ├─ Pixel/PixelBuffer.swift          RGBA8 buffer: blit, mask, outline, threshold, nearest upscale
│  ├─ Pixel/IndexedSprite.swift        ASCII grid + key → PixelBuffer, validation
│  ├─ Pixel/PixelCanvas.swift          rect/bevel/line/ellipse/dither fills for procedural furniture
│  ├─ Pixel/LineRaster.swift           Bresenham (clock hands, lamp arm)
│  ├─ Pixel/Quantizer.swift            area-average, median cut, orphan removal
│  ├─ Art/RoomSprites.swift            wall, window, floor, desk, apron, legs, extension tiles
│  ├─ Art/MonitorSprites.swift         bezel, chin, buttons, LED, CRT frames, NO SIGNAL logo, static noise
│  ├─ Art/StorageSprites.swift         riser, cubby, drawer fronts, cabinet, folder tabs, paper edges
│  ├─ Art/PropSprites.swift            lamp, plant, cup, pens, phone (front/back/flip), brush, keyboard, chair facings, basket, balls, hub, drives
│  ├─ Art/KindIcons.swift              16×16 and 12×12 kind icons, 5×5 minis, alias overlay
│  ├─ Art/FXSprites.swift              puff, sparkle, squash, text pops, onboarding note frame
│  ├─ Art/Digits.swift                 3×5 digits for badge/OSD counts
│  ├─ Art/AppIconArt.swift             32×32 app icon and 16-pt status template
│  ├─ Model/TokenKey.swift             TokenKey, TokenMeta, FileKind, DesktopEntry, DesktopSnapshot, VolumeEntry
│  ├─ Model/Location.swift             Location, ContainerID, PileID
│  ├─ Model/ContainerSpec.swift        capacities, hard caps, concealment
│  ├─ Model/DeskState.swift            root state (§13) and invariants
│  ├─ Model/ScreenGrid.swift           pages, cells, nearest free cell, clean-up sorts, pruning
│  ├─ Model/Visibility.swift           visibility matrix (§2.1)
│  ├─ Logic/DeskAction.swift · Effect.swift
│  ├─ Logic/Reducer.swift              reduce(state, action, env) → [Effect]
│  ├─ Logic/Reconciler.swift           snapshot diff, inode/name/tombstone matching, safe-save
│  ├─ Logic/Placement.swift            new-file placement, hints TTL, Take Everything Out order
│  ├─ Logic/ClearDesk.swift            Clear the Desk plan (target spots under mat, sequencing)
│  ├─ Logic/DropResolver.swift         release point → DropVerdict (§2.1)
│  ├─ Logic/MenuSpec.swift             menus as data, item ids
│  ├─ Logic/UndoJournal.swift          20 entries: layout snapshots + file-op records
│  ├─ Logic/InventoryQuery.swift       flattened, searchable listing with location labels
│  ├─ Logic/FileOpPlan.swift           move vs copy decision, collision names
│  ├─ Sim/Spring1D.swift · Tween.swift frame-stepped deterministic motion
│  ├─ Sim/DrawerSim.swift              1D rail: follow, coast, stops, slam, jam/block limits
│  ├─ Sim/ContentJostle.swift          per-item 1D springs from drawer acceleration
│  ├─ Sim/RollerSim.swift              chair roll + facing
│  ├─ Sim/Ballistics.swift             toss arcs, rim tests, floor/desk landing
│  ├─ Machines/MonitorMachine.swift · PhoneMachine.swift · PenCupMachine.swift · WastebasketMachine.swift · LampModel.swift · DeskKnock.swift
│  ├─ Lighting/TimeOfDay.swift         time → phase, ambient level, sky
│  ├─ Lighting/LightMask.swift         cone/glow/emissive raster (R8)
│  ├─ Cloth/ClothSim.swift             XPBD grid, friction, sleep, serialization
│  ├─ Cloth/ClothGrabs.swift           carry/slide/peel/tug/transform; smooth/unfold/peek; keyboard weight
│  ├─ Cloth/BumpField.swift · PileClusterer.swift   piles → heightfield
│  ├─ Cloth/DeskSurfaceRaster.swift    z-buffered mat + pile billboards → PixelBuffer + owner[]
│  ├─ Cloth/Coverage.swift             covered/revealed with hysteresis
│  ├─ Cloth/MatPattern.swift           felt tile, border, fringe, underside dots
│  ├─ Cloth/ClothMetrics.swift         wrinkle metric W, area, max z (tests)
│  ├─ Persistence/DeskDocument.swift · Migrations.swift · SettingsModel.swift
│  ├─ Demo/DemoScript.swift            Codable steps + expectations
│  └─ Text/TextLayout.swift · Strings.swift   NFC, middle truncation; EN/KO string table
├─ Sources/DeskPixels/
│  ├─ CGBridge.swift · PNGCodec.swift  PixelBuffer ⇄ CGImage ⇄ PNG (sRGB, premultiplied RGBA8)
│  ├─ IconPixelator.swift · WallpaperPixelator.swift
│  ├─ PixelFont.swift                  CoreText no-AA Galmuri raster, binary alpha, glyph cache, fallback
│  ├─ FontRegistry.swift               CTFontManagerRegisterFontsForURL(.process)
│  └─ ResourceLocator.swift            .app Resources → env → #filePath repo
├─ Sources/DeskFiles/
│  ├─ DesktopLocator.swift · SafetyGuard.swift   root resolution; real-Desktop refusal; path confinement
│  ├─ DesktopScanner.swift · DesktopWatcher.swift · VolumeWatcher.swift · FileKindClassifier.swift
│  ├─ FinderPrefs.swift                read-only CreateDesktop / StandardHideDesktopIcons / Show*OnDesktop
│  ├─ ExplicitIntent.swift · FileOperator.swift · Trasher.swift (System/Fake) · OperationLog.swift
│  ├─ StateStore.swift · IconCache.swift · ArtifactWriter.swift
├─ Sources/DeskScene/
│  ├─ Render/PixelPresenter.swift · PostPass.swift · TextureFactory.swift · Snapshotter.swift · OffscreenDriver.swift
│  ├─ Loop/FrameLoop.swift             display link, fixed step, rest/hard sleep, renderOnce
│  ├─ Scene/DeskScene.swift · SceneSync.swift · Layers.swift · HitTester.swift · SceneHost.swift
│  ├─ Input/InputEvent.swift · InputRouter.swift · Gestures.swift · CarrySession.swift · Selection.swift
│  ├─ Physics/PhysicsCategories.swift · DeskPlaneWorld.swift · PileBodies.swift · Freezer.swift · Watchdog.swift
│  ├─ Elements/DeskElement.swift + {Room,Monitor,Screen,Riser,Drawer,Cabinet,PhoneStand,PenCup,Wastebasket,
│  │           DeskMat,Brush,Keyboard,Lamp,LightSwitch,Clock,Chair,Floor,DriveHub,Plant}Element.swift
│  ├─ Elements/InteriorRaster.swift    CPU-composited drawer/cubby interiors
│  ├─ FX/Juice.swift · Tooltip.swift · Notes.swift
│  └─ WallScene.swift
├─ Sources/DeskteriorApp/
│  ├─ main.swift · AppDelegate.swift · AppIdentity.swift · LaunchOptions.swift
│  ├─ Store.swift · EffectRunner.swift (ONLY place minting ExplicitIntent)
│  ├─ Window/DeskWindow.swift · DeskView.swift · DisplayManager.swift · PeekController.swift · DeskAccessibility.swift
│  ├─ Desktop/MirrorController.swift · IconProvider.swift · DragOutController.swift · DropInController.swift
│  ├─ UI/StatusMenu.swift · MainMenu.swift · ContextMenus.swift · QuickLookController.swift · InventoryWindow.swift
│  │     SettingsWindow.swift · ConfirmTrashSheet.swift · AboutWindow.swift · SafeModeWindow.swift
│  ├─ System/SystemObservers.swift · LoginItem.swift · HotKey.swift · WidgetProbe.swift · Translocation.swift · L10n.swift
│  └─ Dev/DemoRunner.swift · TunablesWatcher.swift · InputRecorder.swift
├─ Sources/DeskAssetTool/main.swift    `icon`, `contact-sheet`, `fixture` subcommands
└─ Tests/ DeskCoreTests/{…,Goldens/} · DeskPixelsTests/{…,Fixtures/,Goldens/} · DeskFilesTests/ · DeskSceneTests/{…,Goldens/}
```

---

## 11. Info.plist (template; `__X__` filled by `plutil -replace`)

| Key | Value |
|---|---|
| `CFBundleIdentifier` | `__BUNDLE_ID__` → `io.github.surrealier.deskterior` (confirm the owner at M13; then frozen) |
| `CFBundleExecutable` | `Deskterior` |
| `CFBundleName` / `CFBundleDisplayName` | `Deskterior` |
| `CFBundlePackageType` | `APPL` |
| `CFBundleSignature` | `????` |
| `CFBundleShortVersionString` | `__VERSION__` (tag without the `v`) |
| `CFBundleVersion` | `__BUILD__` (`git rev-list --count HEAD`) |
| `CFBundleInfoDictionaryVersion` | `6.0` |
| `CFBundleIconFile` | `AppIcon` |
| `CFBundleDevelopmentRegion` | `en` |
| `CFBundleLocalizations` | `[en, ko]` |
| `CFBundleSupportedPlatforms` | `[MacOSX]` |
| `LSMinimumSystemVersion` | `14.0` |
| `LSUIElement` | `true` |
| `LSMultipleInstancesProhibited` | `true` |
| `LSApplicationCategoryType` | `public.app-category.productivity` |
| `NSPrincipalClass` | `NSApplication` |
| `NSHighResolutionCapable` | `true` |
| `NSSupportsAutomaticGraphicsSwitching` | `true` |
| `NSHumanReadableCopyright` | `© 2026 <owner>. MIT License.` |
| `NSDesktopFolderUsageDescription` | EN: "Deskterior shows the files on your Desktop as objects on a pixel-art desk. It only reads the folder; files are moved or trashed only when you explicitly ask." KO (via `ko.lproj/InfoPlist.strings`): "Deskterior는 바탕화면 파일을 픽셀 아트 책상 위 물건으로 보여줍니다. 폴더를 읽기만 하며, 직접 요청할 때만 파일을 옮기거나 휴지통으로 보냅니다." |

No other usage-description keys. The app reads no other protected location (the wallpaper allowlist enforces this) and sends no Apple Events.

---

## 12. Physics categories (desk-plane Box2D world only)

| Category | Bit | Members | `collisionBitMask` | Notes |
|---|---|---|---|---|
| `furniture` | `1 << 0` | Back wall edge chain; static footprints (riser, lamp base, plant, phone stand, hub; pen cup while resting) | — (static) | Edge bodies are static by definition |
| `pile` | `1 << 1` | Uncovered desk piles (rect 14×10 plane px, inset 1 px) | `furniture \| pile \| prop` | `allowsRotation = false`, friction 0.3, restitution 0.2, `linearDamping` 4, `usesPreciseCollisionDetection = true`, speed clamp 1200 art px/s |
| `prop` | `1 << 2` | Brush (24×6, about 20× a pile's mass); pen cup while carried | `furniture \| pile` | Velocity-driven directly (no joints), CCD on, clamp 600 art px/s |
| reserved | `1 << 3…7` | v0.2: laptop stand footprint, mug, figure | — | |

- **Units:** U = 4 SK units per art px; PTM 150 pt/m; world gravity `(0,0)`.
- **Contacts:** `contactTestBitMask = 0` everywhere. Zones (mat footprint, desk edges, basket line-up) use geometric tests in `didSimulatePhysics`.
- **Covered piles** have no body.
- **Not Box2D:** drawers, chair, ballistics, cloth.

---

## 13. Persisted JSON schema (`desk.json`, schema 1)

```json
{
  "schema": 1, "layoutVersion": 1, "app": "0.1.0", "savedAt": "2026-10-13T12:00:00Z",
  "root": { "path": "/Users/x/Desktop", "volume": "8F1C…" },
  "hostDisplayUUID": "37D8…",
  "monitor": { "power": "off", "page": 1, "pendingNew": 2 },
  "drawers": { "riserLeft": { "p": 0.0 }, "riserRight": { "p": 0.0 }, "cabinetTop": { "p": 12.0 },
               "cabinetMiddle": { "p": 2.0 }, "cabinetFile": { "p": 0.0 } },
  "phone": { "faceDown": true },
  "penCup": { "state": "upright", "pos": [367.0, 120.0] },
  "wastebasket": { "state": "upright", "swishes": 12 },
  "chair": { "x": 200.0, "facing": 0 },
  "lights": { "mode": "auto", "room": true, "lamp": true },
  "brush": { "pos": [442.0, 60.0] },
  "mat": { "pattern": "felt", "mode": "cloth", "origin": [154.0, 8.0], "size": [204.0, 84.0], "angle": 0.12,
           "grid": [35, 15], "particles": "<base64 Float32LE xyz × 525>" },
  "piles": [ { "id": "P1", "pos": [281.0, 44.0] } ],
  "tokens": [
    { "key": { "volume": "8F1C…", "inode": 1234567 },
      "meta": { "name": "보고서.pdf", "added": "2026-10-01T09:00:00Z", "kind": "pdf" },
      "loc": { "screen": { "page": 0, "col": 2, "row": 1 } } },
    { "key": { "volume": "8F1C…", "inode": 2345678 }, "meta": { "name": "IMG_0001.png", "kind": "image" },
      "loc": { "container": { "id": "cabinetMiddle", "order": 3 } } },
    { "key": { "volume": "8F1C…", "inode": 3456789 }, "meta": { "name": "old.zip", "kind": "zip" },
      "loc": { "desk": { "pile": "P1", "order": 0 } } },
    { "key": { "volume": "8F1C…", "inode": 4567890 }, "meta": { "name": "memo.txt", "kind": "text" },
      "loc": { "floor": { "x": 210 } } } ],
  "tombstones": [ { "key": { "volume": "8F1C…", "inode": 99 }, "name": "a.png", "kind": "image",
                    "loc": { "container": { "id": "riserLeft", "order": 0 } }, "until": "2026-10-20T12:00:00Z" } ],
  "undo": [],
  "flags": { "onboardingStep": 5, "askedCoverDisplays": true }
}
```

- `desk` coordinates are desk-plane art px; `floor.x` is in core coordinates.
- Covered-ness is never stored; it is derived from `mat.particles` and `piles`.
- `carried` is never persisted. A carry interrupted by a quit commits the token to its origin.
- Tokens whose files are missing at launch move to `tombstones` (7 days); they are not dropped.
- **Migrations:** `[Int: (Data) throws -> Data]` keyed by `schema`. A separate `layoutVersion` step clamps or re-maps desk-plane and floor coordinates when elements move between versions.

---

## 14. Build order with acceptance criteria

Every milestone ends with `swift build && swift test --disable-xctest && make lint` green and a commit in the **nested** repo. Before each commit, `git rev-parse --show-toplevel` must print the project folder itself (not an enclosing repository).

**M0: Bootstrap**
1. `git init -b main` inside `desktop_physics`; verify `show-toplevel`. Add `.gitignore` (including `.claude/`), LICENSE and Makefile.
2. `Package.swift` with all six targets as stubs, and one `@Test` per test target.
3. `scripts/check-file-safety.sh` (patterns in §3.7 plus `ExplicitIntent(`, `.desktopDirectory`, `"Desktop"`; allowlist per file) and `ci.yml`.
4. Smoke-compile checks: SwiftUI `@Observable`; `import Carbon.HIToolbox`.

**Accept:** `swift test --disable-xctest` runs swift-testing under the CLT; the lint passes; `git status` shows only project files.

**M1: Pixel and text foundation**
1. PixelGrid, IntGeometry, Projection.
2. Palette, OKLab, IndexLUT, LightRamp, Dither.
3. PixelBuffer, IndexedSprite, PixelCanvas, LineRaster, Quantizer.
4. CGBridge and PNGCodec; the golden harness (`RECORD_SNAPSHOTS=1`, `Attachment.record` on failure).
5. Fetch Galmuri v2.40.4 once (`https://github.com/quiple/galmuri/releases/download/v2.40.4/Galmuri-v2.40.4.zip`; record the sha256 in THIRD_PARTY_NOTICES). Commit `Galmuri9.ttf` and `OFL-Galmuri.txt`.
6. FontRegistry, ResourceLocator, PixelFont, TextLayout.

**Accept:** the §1.2 grid table passes; LUT and ramp closure; Hangul text goldens with NFD input equal to NFC; PNG byte order.

**M2: Presenter, window, loop and the spike gate**
1. `DeskWindow` and `DeskView` (CAMetalLayer), `PixelPresenter` (art → lit → upscale), `PostPass` (MSL compiled at runtime), `TextureFactory`, `FrameLoop`, `Snapshotter`, `OffscreenDriver`.
2. `LaunchOptions` with `--windowed`, `--headless`, `--snapshot-dir`; `StatusMenu` with Pause and Quit.
3. Calibration scene: a 1-px checker plus palette swatches.
4. Early `build-app.sh` (arm64, ad-hoc).
5. Run and record **S1–S12** in `docs/SPIKES.md`:

| Spike | Question | Default if it passes | Fallback |
|---|---|---|---|
| S1 | icon+1 window: covers Finder icons, below widgets; clicks, right-click, scroll and hover with another app frontmost; reveal-click; 81-pt strip | as specified | icon+3 setting; document |
| S2 | Activating window: keys, menu-bar behaviour, Quick Look, ⌘Z | activating `DeskWindow` | non-activating panel with `keyArmed` |
| S3 | Occlusion notification under a full-screen app | pause on occlusion | rely on rest-pause plus `activeSpaceDidChange` |
| S4 | Drag-out results: Finder window, Mail, Dock Trash (`.delete` semantics) | §3.6 rule | §3.6 rule (covers both) |
| S5 | SKRenderer exactness: palette round-trip, row order, `drawableSize` persistence | SKRenderer path | SKView integer-scale presenter |
| S6 | Desktop TCC prompt in a built .app, ad-hoc vs self-signed across 2 rebuilds | document | — |
| S7 | `--triple x86_64` build under the CLT | universal locally | `ARCHS=arm64` locally; CI universal |
| S8 | `SKMutableTexture.modifyPixelData` at 60 fps: latency and RSS | mutable texture | per-frame `SKTexture(data:)` |
| S9 | `CFPreferencesCopyAppValue` for `com.apple.finder` / `com.apple.WindowManager` keys | Ask card | skip detection; README note |
| S10 | `WidgetProbe` frames without Screen Recording | nudge | tip only |
| S11 | Undo by renaming out of `~/.Trash` (TCC) | in-app undo | toast "Use Finder's Put Back" and open Trash |
| S12 | Drop-in move from `~/Downloads` (TCC prompt?) | move | accept the prompt (user-initiated); on EPERM toast and copy |

**Accept:** the headless snapshot of the calibration scene matches its golden; the checker is crisp at S = 5 on this Mac; clicks log art coordinates; hover works while another app is frontmost; paused CPU ≈ 0%; every spike has a recorded decision.

**M3: Room, layout, lighting** (track A)
1. CoreLayout, LayoutSolver (menu, Dock, widget avoid rects), Anchors.
2. All static sprites, through PixelCanvas and IndexedSprite.
3. TimeOfDay, LightMask, the ambient and phase pipeline, the clock face, the window sky, the room switch, lamp on/off, wallpaper allowlist.
4. `deskterior-assets contact-sheet`.

**Accept:** `12-sizes` produces 9 canvases × day/dusk/night, reviewed visually; LightMask goldens; layout tests show every anchor inside the visible band.

**M4: Mirror, model, screen** (track C for the DeskFiles parts)
1. DesktopLocator and SafetyGuard (exit 64), Scanner, Watcher, FileKindClassifier, FinderPrefs.
2. Reconciler, DeskState/TokenStore, Reducer core, Placement, ScreenGrid, StateStore (backups), DeskDocument.
3. KindIcons, IconPixelator, IconProvider, IconCache.
4. ScreenElement with tooltip; MonitorMachine overlays (connect prompt, NO SIGNAL, DESKTOP HIDDEN); `make-fixture-desktop.sh`; `deskterior-assets fixture`.

**Accept:** DeskFilesTests (add, rename, safe-save, delete, dot-file rename, burst); reconciler tombstone tests; demos `01-mirror` and `09-fs-events` show `touch` and `mv` changes in under 1 s; relaunch restores cells.

**M5: Interaction core and monitor**
1. InputEvent, InputRouter, Gestures, HitTester, Selection and marquee, CarrySession (no physics), DropResolver (screen, bonk, spring-back).
2. MonitorMachine (CRT, LED, badge), INPUT pages with AV (10-s cap), MenuSpec → NSMenu, MainMenu.
3. Open, Reveal, Quick Look, Copy (EffectRunner without file mutation); UndoJournal for layout.
4. InventoryWindow with Show on Desk (screen targets); Take Everything Out.

**Accept:** `02-monitor-power` snapshots; power and page persist across relaunch; Quick Look opens after a desk click; Inventory search finds tokens on any page.

**M6: Containers**
1. DrawerSim, ContentJostle, InteriorRaster; RiserElement (L, R, cubby); CabinetElement ×3 (folder tabs).
2. Chomp, spring-loading, peek, jam, hard caps with bonk; List Contents and Take All Out; Move to ▸.
3. PhoneStandElement (PhoneMachine); PenCupElement (holding, bonk); WastebasketElement (heap, cap, dig, Empty… UI wired to a FakeTrash effect).
4. ChairElement with RollerSim and the cabinet block.

**Accept:** machine and sim unit tests; `03-drawers` and `08-phone` pass their `expect` steps; a jam-frame golden; a knock never changes membership.

**M7: Desk-plane physics and ballistics**
1. PhysicsCategories, DeskPlaneWorld, PileBodies (settle commits), Freezer, Watchdog.
2. Ballistics (swish, rim, miss, floor and desk landing); FloorElement; fling from carry.
3. Pen cup carry, tip and spill (gesture or menu only); basket tip; DeskKnock; rest detection and hard sleep.

**Accept:** Metal-gated calibration; a toss dropped above the basket ends inside; identical final hash across two runs; `05-pencup-spill` and `06-wastebasket`; `measure-idle` ≤ 0.3% after `burst`.

**M8: Cloth core (pure; track B, from M1/M2)**
ClothSim, ClothGrabs, BumpField, PileClusterer, DeskSurfaceRaster, Coverage, MatPattern, ClothMetrics.

**Accept:** every cloth test in §8.1; raster goldens; release benchmark (`swift test -c release --filter ClothPerf`): step ≤ 0.6 ms and raster ≤ 0.6 ms.

**M9: Mat, brush, Clear the Desk**
1. DeskMatElement: SKMutableTexture upload, `owner[]` picking, all five grab modes, ⌥ handles, smooth, unfold, peek, keyboard weight, cover/reveal, bumps, particle persistence, `matMode=flat`.
2. BrushElement and the scroll-broom; drops onto the mat; ClearDesk plan and animation with undo.

**Accept:** `04-rug-homage` walks O1–O10 with `expect` steps (`underMat`/revealed) and frame dumps reviewed as a GIF; a brush sweep test; `10-clear-desk` hides every visible token and undo restores them exactly; wrinkles survive relaunch.

**M10: Lighting interactions**
Lamp Only (menu, emergent states), dark-token hit filtering, monitor and phone emissive glow, clock minute-hand preview, Reduce Motion paths.

**Accept:** `07-night-lamp` (only the cone, monitor glow and phone glow are lit; dark tokens are not hoverable); preview springs back.

**M11: File I/O** (track C)
1. ExplicitIntent, FileOperator (renamex_np RENAME_EXCL, partial copies, time-of-check, stale-intent rejection), Trasher (System/Fake), OperationLog.
2. EffectRunner minting intents; Move to Trash with Undo; Empty Wastebasket sheet.
3. DragOutController (hand-off, `.move`/`.delete` rules); DropInController (move/copy/collision/undo, hints).
4. VolumeWatcher, DriveHubElement, Eject.

**Accept:** DeskFilesTests including the planted-destination race; lint test green; manual checklist items 10–13 on the fixture folder only.

**M12: System integration**
1. DisplayManager with WallScene (drops routed to the monitor) and the onboarding cover prompt.
2. SystemObservers (occlusion, sleep, lock, session, Low Power Mode, thermal, battery).
3. PeekController and the opt-in HotKey; LoginItem (opt-in; re-register on version change; status read off the main thread).
4. SettingsWindow, SafeModeWindow, Translocation note, WidgetProbe, DeskAccessibility, onboarding notes in KO/EN, L10n, About/Credits.

**Accept:** manual checklist items 1–5 and 14–19; `measure-idle` ≤ 0.3%; `soak.sh` passes.

**M13: Packaging and release** (track D skeleton from M2)
1. Final `build-app.sh --universal`, `make-icon.sh`, the Info.plist template, `release.yml`, `ci-import-identity.sh`, `docs/SIGNING.md`.
2. README EN/KO with the hero GIF from `make gif`; THIRD_PARTY_NOTICES; CHANGELOG.
3. **With explicit user approval:** `gh repo create`, push, tag `v0.1.0`.

**Accept:** CI green; the release has the zip, sha256 and attestation; `codesign --verify --strict` passes; a Safari download → Open Anyway works on 26.6; manual item 20.

**v0.1.0 is done when** M0–M13 are accepted, the §8.3 checklist is green, and idle is ≤ 0.3%.

---

## 15. Open assumptions

1. **GitHub owner and bundle id:** `io.github.<owner>.deskterior`, the owner read from the repository's remote (`scripts/build-app.sh`) or `GITHUB_REPOSITORY_OWNER` in CI. It is frozen at the first release.
2. **Enclosing repo:** the project is developed as a nested repository; the enclosing one is never modified.
3. **Activation:** a borderless activating `NSWindow` at desktop-icon level behaves like Finder's desktop (S2). LSUIElement menu-bar behaviour while active is acceptable.
4. **Dock Trash drag-out:** the outcome (S4) is handled by the dual rule in §3.6 either way.
5. **TCC edge cases:** Desktop TCC fires on first enumeration in the built .app (S6). The two system Desktop Pictures folders never prompt. Undo out of `~/.Trash` and moves out of `~/Downloads` may be TCC-restricted (S11/S12; fallbacks defined).
6. **Finder preference keys:** `CreateDesktop`, `StandardHideDesktopIcons` and `Show*OnDesktop` are the right keys and readable from an unsigned app (S9) [M].
7. **Widget frames:** readable through `CGWindowListCopyWindowInfo` without Screen Recording (observed by R1; re-checked in S10).
8. **`SKMutableTexture` vs per-frame `SKTexture`:** RSS stays flat with the mutable texture (S8); otherwise the per-frame path is used.
9. **Universal build:** x86_64 cross-compiles with the CLT only (S7); otherwise local builds are arm64 and CI builds universal.
10. **Metal on CI:** GitHub `macos-26` runners may lack Metal, so the Metal-gated suites may skip there. The CPU goldens are authoritative in CI.
11. **Galmuri9:** stays OFL-1.1 with no Reserved Font Name at v2.40.4, and its 4.6 MB TTF size is acceptable in the bundle.
12. **Apollo palette:** Lospec norms allow use with credit; there is no formal licence.
13. **Self-signed identity:** optional. Without the secret, users accept TCC re-prompts after updates, as documented.
14. **Feel constants:** cloth compliance, friction, bump formula, drawer springs and fling clamps are starting values in `Tunables`. They are tuned in M8/M9 with `--tunables` and recorded inputs; the acceptance tests, not the exact numbers, are the contract.
15. **Original's interaction set:** the original's feature list is inferred from press coverage and the announcement video (unreleased prototype). The O1–O10 mapping is our interpretation.

---

### Critical Files for Implementation
- Sources/DeskCore/Logic/Reducer.swift (with `Model/DeskState.swift`, `Model/Location.swift`, `Logic/Reconciler.swift`)
- Sources/DeskCore/Cloth/ClothSim.swift (with `ClothGrabs.swift`, `DeskSurfaceRaster.swift`, `Coverage.swift`, `BumpField.swift`)
- Sources/DeskScene/Render/PixelPresenter.swift (with `PostPass.swift`, `Loop/FrameLoop.swift`, `DeskCore/Geometry/PixelGrid.swift`)
- Sources/DeskFiles/FileOperator.swift (with `ExplicitIntent.swift`, `SafetyGuard.swift`, `DeskteriorApp/Store/EffectRunner.swift`, `scripts/check-file-safety.sh`)
- Sources/DeskteriorApp/Window/DeskWindow.swift (with `DeskView.swift`, `DisplayManager.swift`, `scripts/build-app.sh`, `.github/workflows/release.yml`)