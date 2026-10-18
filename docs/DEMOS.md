# Demo scripts

Demo scripts (`Demos/*.json`) drive the app headless through the same store, input router and scene as real
input, take snapshots and check expectations (DESIGN §4.11, §8.2). They never touch the real Desktop.

```sh
SWIFT_SCRATCH_PATH=.build-mine scripts/run-demo.sh 02-monitor-power      # one demo
scripts/run-demo.sh --out /tmp/review 00-layout 01-mirror 09-fs-events    # several, elsewhere
```

`run-demo.sh` builds `Deskterior` and `deskterior-assets`, makes a fresh `mktemp` fixture
(`scripts/make-fixture-desktop.sh`, about 40 items) and state folder per demo, and runs
`Deskterior --headless --demo Demos/<name>.json --desktop-folder <fixture> --state-dir <state> --seed 1
--snapshot-dir <out>/<name> --snapshot-scale 3`. Each snapshot is written twice: `<name>.png` (art px) and
`<name>@3x.png` (nearest ×3, for review). Exit codes: 0 pass, 1 an expectation failed, 2 script error, 64 the
folder guard refused a path.

Scene time is virtual (fixed 1/60 s frames), so animations are deterministic; the mirror and icons run in real
time, which `waitIdle` and `waitFor` wait for. Icons are the pixelated real ones (`--icons kind` for kind icons
only). `fs` steps are carried out by `run-demo.sh` in the fixture; the app itself changes files only through the
explicit file actions (M11, below), on the fixture and its drop source, trashing into `<state>/FakeTrash`.

## Script

```json
{ "name": "02-monitor-power", "display": "1470x956@2", "clock": "10:00", "seed": 1, "lights": "auto",
  "firstRun": true, "finderHidden": false,
  "steps": [ { "waitIdle": 3 }, { "snapshot": "01-start" }, { "click": "monitor.power" } ] }
```

| Field | Meaning |
|---|---|
| `name` | The demo's name (the file's base name). |
| `display` | Emulated display in points, `WxH` or `WxH@scale` (default `1470x956@2`). |
| `clock` | Fixed room time, `HH:MM` or ISO 8601 (default: the real clock). |
| `lights` | `auto`, `day`, `night` or `lamp` (Lamp Only). |
| `seed` | Reducer randomness (`--seed` wins). |
| `firstRun` | Start like a first launch: the connect prompt instead of an immediate scan. |
| `finderHidden` | With `firstRun`: Finder hides desktop items (the DESKTOP HIDDEN card). |
| `language` | `en` (default), `ko` or `system`: the language of cards, toasts and menus (M12). |
| `fixtureCount` | Visible items in the fixture `run-demo.sh` makes (`--count` wins; e.g. 500 for `11-overflow-500`). |

## Steps

Every step is an object with one key.

| Step | Example | Does |
|---|---|---|
| `waitIdle` | `{"waitIdle": 3}` | Runs frames until nothing animates, no tooltip is due, the mirror has delivered and gone quiet, and icons have arrived (at most N real seconds). |
| `wait` | `{"wait": 0.3}` | Runs N seconds of frames (virtual time; tooltips and animations advance). |
| `snapshot` | `{"snapshot": "01-start"}` | Renders the lit frame; fails if any pixel is not an Apollo colour. |
| `click` | `{"click": "monitor.power"}`, `{"click": {"at": "token:a.txt", "mods": ["cmd"], "count": 2}}` | Move, press and release (`count` 2: a double-click). |
| `hover` | `{"hover": "token:a.txt"}` | Moves the pointer there. |
| `drag` | `{"drag": {"from": "token:a.txt", "to": "cell:3,2", "duration": 0.4, "hold": true, "mods": []}}` | Press, move over `duration` s (one move per frame), release unless `hold`. |
| `release` | `{"release": true}` | Releases a held drag where the pointer is. |
| `move` | `{"move": {"to": "core:290,208", "duration": 0.3, "mods": []}}` | Moves a held drag on without letting go (frame dumps of a gesture in progress). |
| `scroll` | `{"scroll": {"at": "monitor.screen", "dx": -30, "dy": 0}}` | Two-finger scroll, art px (content direction). |
| `key` | `{"key": "shift+cmd+z"}` | `space`, `esc`, `left`/`right`/`up`/`down`, `cmd+o`, `cmd+down`, `cmd+c`, `cmd+a`, `cmd+f`, `cmd+z`, `shift+cmd+z`. |
| `menu` | `{"menu": {"at": "token:a.txt", "item": "copy"}}` | Right-clicks there and picks the item with that `MenuItem.id` (fails if it is disabled). |
| `fs` | `{"fs": {"touch": "new.txt"}}`, `{"fs": {"mv": ["a.txt", "b.txt"]}}`, `{"fs": {"mkdir": "D"}}`, `{"fs": {"rm": "c.txt"}}` | Changes the fixture through the harness (plain names only). |
| `action` | `{"action": "accessDenied"}` | Dispatches a model action by name: `powerOn`, `powerOff`, `requestConnect`, `accessDenied`, `accessGranted`, `finderHidesItems`, `cycleInput`, `selectAV`, `page:<n>`, `takeEverythingOut`, `clearDesk`, `undo`, `redo`, `cleanUp:<name\|kind\|dateAdded>`, `lights:<auto\|day\|night\|lamp>`; Put Away (Erratum 30): `putAway:<StowID>`, `bringBack:<StowID>`, `bringBackAll`, `clipLight:<on\|off>`; memos (Erratum 31): `newNote:<colour>:<text>`, `noteText:<id>:<text>` and `dayMemo:<day>:<text>` (editing session 0), `noteDay:<id>:<day\|none>`, `dDay:<day>:<title>`, `clearDDay`, `tearOff:<day>`, `removeNote:<id>` (days `YYYY-MM-DD`, note ids `N1`…). |
| `expect` | `{"expect": {"token:a.txt": "cell:0,3,2", "selection": 1}}` | Checks now; every failure is reported (exit 1). |
| `waitFor` | `{"waitFor": {"expect": {"token:new.txt": "screen"}, "within": 1}}` | Runs until the expectations hold, failing after `within` s (default 3). |
| `comment` | `{"comment": "…"}` | Printed. |
| `display` | `{"display": "1920x1080@1"}` | Switches the emulated display (points, `WxH` or `WxH@scale`): a new grid and layout, as when a display changes (M12). |
| `clock` | `{"clock": "18:00"}` | Sets the room's fixed time (`HH:MM` or ISO 8601). |
| `wall` | `{"wall": "01-wall"}` | Writes the wall another display of this size would show now (`WallArt`; checked for Apollo colours like a snapshot). |

### Targets

| Target | Point |
|---|---|
| an anchor name | The anchor's centre (`monitor.power`, `monitor.input`, `monitor.pageDots`, `monitor.screen`, `hub`, `wastebasket.mouth`…; `Anchors.core`). A drawer's anchors follow it out: `riser.drawerL.front`, `.handle`, `.interior`, `cabinet.top.handle`… |
| `token:<name>` | The centre of that token's icon, or of the part of its mini that answers a click in an open drawer, the cubby or the face-up phone (NFC name; it must be on show). |
| `cell:<col>,<row>` | A cell of the current page. |
| `screen.empty` | The first empty cell of the current page. |
| `card.<button>` | A button on a monitor card: `card.show`, `card.keepHidden`, `card.openSettings`, `card.chooseFolder`. |
| `core:<x>,<y>` / `point:<x>,<y>` | Core px / canvas px. |
| `pencup`, `pencup.mouth`, `pencup.body`, `wastebasket`, `wastebasket.mouth`, `wastebasket.body` | Where the cup and the basket are now (the cup can be carried; `.body` grabs it rather than a pen). `token:<name>` also finds a token in a desk pile or on the floor. |
| `mat.center`, `mat.corner.nw\|ne\|se\|sw`, `mat.edge.n\|s\|e\|w`, `mat.flap`, `brush`, `keyboard` | Where the mat's parts are now (just inside each corner and each edge's middle, past the fringe and hem; `n` is the back edge; a folded flap), the brush and the keyboard. `token:<name>` also finds a token in a pile the mat's lifted cloth stands over (its front icon). |
| `partition`, `partition.tower`, `partition.post`, `partition.cube`, `partition.pad`, `partition.clips`, `partition.dday`, `partition.clipLight`, `calendar` | The desk partition (Erratum 31): its bounds, the tower's felt, the right post (a bare spot for its menu), the sticky-note cube, the daily memo pad, the memo clips, the D-Day card, the clip light; the wall calendar. `token:<name>` also finds a file clipped to the memo clips (its card). |
| `note:<id>` | Where that sticky note rests now (`note:N2`; it must be on show). |
| `calendar.day:<d>` | Day `d`'s cell on the wall calendar (the month the room's clock shows). |

### Expectations

| Key | Value |
|---|---|
| `token:<name>` | `screen`, `screen:<HDMI n>`, `cell:<page>,<col>,<row>` (page from 0), `container`, `container:<id>`, `desk`, `floor`, `present`, `missing`. |
| `hidden` | `true`/`false` for every token named in the same `expect` (Visibility matrix; a pile the mat covers is hidden). |
| `monitor.power` | `on` / `off` (the model). |
| `monitor.input` | `HDMI 1`, `HDMI 2`… or `AV`. |
| `monitor.phase` | `on`, `poweringOff`, `off`, `poweringOn` (the scene's `MonitorMachine`). |
| `monitor.overlay` | `none`, `connectPrompt`, `connecting`, `noAccess`, `desktopHidden`, `av`. |
| `monitor.led` / `monitor.badge` / `monitor.pendingNew` | `on`/`amber`/`off`; `+3` or `none`; a number. |
| `access` | `notConnected`, `finderHidden`, `connecting`, `connected`, `denied`. |
| `tokens` / `screen.tokens` / `pages` / `selection` | Counts: all tokens, tokens drawn on the screen, HDMI pages, selected tokens. |
| `undo` | The undo label (`Move`, `Take Everything Out`…) or `none`. |
| `effect` | The last file effect the dry-run effect runner recorded: `open`, `reveal`, `quickLook`, `copy`, `openPrivacySettings`, `chooseFolder`, or `none`. |
| `toast` | The toast on show (`drivesReadOnly`…) or `none`. |
| `tooltip` | `none`, or text the tooltip's title contains (a token's tooltip is its kind and date; its name is on the label). |
| `hover` | `none`, or the name of the token under the pointer. |
| `carrying` / `bonks` | A drag in hand; refused drops so far. |
| `command` | The last app command a scene request or menu asked for (`inventory`…; the memo ones as `MenuCommand.demoName` says them: `newNote`, `editNote:N1`, `openMemos:today`, `openMemos:day:2026-10-30`, `openMemos:note:N1`, `openMemos:notes`, `openMemos:dDay`, `arrangeDesk`). |
| `drawer:<id>` | A drawer's opening in the model: `closed` (0), `ajar` (under 8 px: a peek, overfull, the chair in the way) or `open`. Ids are `ContainerID`s (`riserLeft`, `cabinetFile`…). |
| `phone` | `faceUp` / `faceDown` (the model). |
| `minis` | Count: tokens the containers show as selectable minis (open drawers, the cubby, the face-up phone). |
| `chair.blocksCabinet` | `true` while the model's chair overlaps the cabinet fronts by more than 16 px. |
| `lights.mode` / `lights.room` / `lights.lamp` | The model's Lights: `auto`/`day`/`night`/`lamp`; `on`/`off` as the room shows them. |
| `ambient` / `phase` / `clock` | The room's ambient level (0–7), phase (`dawn`/`day`/`dusk`/`night`) and the time the clock shows (`HH:MM`, a preview included). |
| `glow.monitor` / `glow.phone` / `glow.lamp` | Whether the monitor's glow, the phone's glow and the lamp's pool (a flicker frame included; only at ambient 5 or less) light the room: `on`/`off`. |
| `lit:<target>` / `light:<target>` | Whether a 16-px token drawn at the target would be seen, hovered and picked (`true`/`false`, `DarkHit`); the light level there. |
| `hover.part` | The part the pointer rests on (`token`, `token.dark` for a token in the dark, `lamp.switch`…) or `none`. |
| `keyboard.key` / `plant.jiggle` | The keyboard key drawn pressed (`row,col`) or `none`; whether the plant jiggles. |
| `penCup` / `wastebasket` | The model's state: `upright`, `lyingLeft`/`lyingRight`; `upright`, `tippedLeft`/`tippedRight`. (`penCup.pose` / `wastebasket.pose`: the scene machine's phase.) |
| `pens` / `balls` / `piles` / `floor` / `flying` / `swishes` / `knocks` | Counts: tokens in the cup, in the basket; desk piles holding tokens; floor tokens; tokens in the air; clean tosses into the basket; desk knocks. |
| `underMat` / `revealed` / `visible` | Counts: tokens the mat covers; tokens on show inside the mat's rectangle (under lifted or folded cloth); tokens not hidden (Visibility matrix with the mat's coverage). |
| `bumps` / `bump.max` | Bump groups under the mat; the tallest bump (px). |
| `mat.folded` / `mat.asleep` / `mat.saved` / `mat.wrinkled` / `mat.handles` | `true`/`false`: a flap lies folded; the cloth sleeps; the model holds its resting pose (it survives a relaunch); wrinkle metric W > 0.25 px, or one crease at least 1 px high; the ⌥ transform handles show. |
| `mat.grab` / `mat.size` / `mat.angle` / `mat.keyboard` / `mat.mode` | The grab mode (`carry`, `peel`, `tug`, `transform`, `slide`, `unpeel`, `pending` or `none`); rest size `WxD`; angle in degrees; the keyboard's plane centre `x,d`; `cloth` or `flat`. |
| `brush` / `brush.home` / `clearDesk` | The brush's plane position `x,d`; whether it is at its rest spot; Clear the Desk's pass `running` or `idle`. |
| `grid.scale` / `grid.canvas` | The emulated display's integer scale `S` and canvas (`588x383`). |
| `budget.frameMs` / `budget.peakRssMB` | Budgets (pass at or under the number): the average wall-clock ms of a frame (a fixed step and an offscreen render) over 60 frames run now, and the process's peak resident memory (`getrusage`). The measured values are printed. |
| `budget.firstFrameMs` | Budget: real ms from the session's start to the first rendered frame that shows the folder's files (the scan, the model, the scene and one offscreen render). |
| `stowed` | What is put away (Erratum 30): the `StowID`s in alphabetical order, comma-separated (`phoneStand,plant`), or `none`. |
| `out:<StowID>` | `out` while the object is in the room (an add-on only while the partition is too), `away` otherwise. |
| `routed:<element>` | `true` while the scene's element of that id takes hits, drops and menus (a put-away object's is dormant; the sealed riser stays routed). |
| `clear:<StowID>` | `true` when nothing rests where the object stands (piles on its footprint, floor files on its span, notes it would cover: `StowCatalog.blockers`), else `false`. |
| `notes` | Count: sticky notes (Erratum 31). |
| `note:<id>` / `note:<id>.pos` / `.text` / `.colour` / `.day` | `present` or `missing`; where it rests (`x,y`, core px, its top-left), its text, its colour (`yellow`, `pink`, `sky`, `lime`, `orange`, `cream`), its date (`YYYY-MM-DD` or `none`); `missing` for a note that is not there. |
| `page:<YYYY-MM-DD>` | That day's page, or `empty`. |
| `dDay` | `YYYY-MM-DD title`, or `none`. |
| `calendar.marks` | Count: days the wall calendar marks (a page, a dated note, the D-Day) in the month it shows. |
| `clipLight` | The partition's clip light in the model: `on` / `off`. |

## The demos

| Demo | Shows |
|---|---|
| `00-layout` | The mirrored fixture on the monitor by day, at night and in Lamp Only darkness. |
| `01-mirror` | Select, ⌘/⇧ extend, hover tooltip, marquee, ⌘A, a carry mid-drag and its drop, a bonk on the drive hub, double-click open, Space, Copy, undo/redo, ⌘F. |
| `02-monitor-power` | First run: connect prompt, DESKTOP HIDDEN, connect; INPUT static, OSD and the AV logo; the CRT collapse, files arriving while off (amber LED, +N), the bloom and pop-in; NO SIGNAL with its buttons. |
| `03-drawers` | The riser: a chomp into the shut left drawer, a stack of eight leaving it overfull and ajar, a scroll peek, click open (minis, hover name, select), five more jamming it (a click shut boings off the paper; the next drop bonks). The cubby's silhouettes, one dragged back out. The chair rolled in front of the cabinet: a pull opens 3 px and thunks it aside, then opens fully. Four into the file drawer (the chomp shuts the open top drawer: interlocked), its folder tabs; spring-loading the middle drawer. The right drawer opened from its menu and flicked shut (slam), then Take All Out (the emptied drawer slides shut). |
| `04-rug-homage` | The homage to the rug, O1–O10: the felt mat with the keyboard on it; a file dropped on it tucks under (a bump), four more on the same spot make the bump taller; the brush pushes a pile set down beside the mat in under its edge (frames), and the scroll-broom sweeps another under the left edge; Peek Under turns up a rounded tongue of the edge nearest the click (rubber side up, the piles under it standing before it); the pile's front file is picked out alone and then, with ⇧, the rest of the pile is carried back to the monitor; the front-right corner peeled back past the middle stays folded (frames), persists, and a double-click on the flap unfolds it; a fast carry moves the mat as a whole with the keyboard riding along and leaves creases that are saved; a corner tugged outward (frames) and Smooth Mat pull them flat; ⌥-dragging a corner shows the handles and grows the mat (wider, and only as deep as the desk allows); Size ▸ Small, then Rotate +15°, which the smaller mat has room for (the keyboard turns with it); Reset Mat. |
| `05-pencup-spill` | Pens dropped in the cup (hover lists them), piles set down on the desk (a second joins the first), the cup carried along the desk, a flick that tips it (mid-tip and spill frames), pens sliding out of the lying cup's mouth as piles along the flick, a click standing it up, a desk knock (nothing moves house), a pen pulled back out, Tip Over / Stand Up from the menu. |
| `06-wastebasket` | Tosses off the desk's front edge: a SWISH! (mid-arc frame), a rim bounce (the basket jiggles, the rim sparks), a miss to the floor; a sideways toss from the floor up over the rim; the heap above the rim from the 11th ball, full at 24 and the cap bonk; a dig; a sustained rim drag that tips it and the balls rolling out onto the floor, clear of the chair (those that do not fit stand as one floor stack with its count); standing it up; Tip Over / Stand Up from the menu. |
| `07-night-lamp` | Dusk; the clock's minute hand dragged to 19:10 (night falls, the room light warms the room) and its spring back; a file set down on the right of the desk; Lights ▸ Lamp Only from the wall menu; only the lamp's pool, the monitor's glow and the phone light a token (`lit:`); the pile in the dark hovers as `token.dark`; the wall switch in and out of Lamp Only; the lamp's three-frame flicker and the room without it; the monitor's glow leaving with the CRT; a key press and the plant's jiggle; Lights ▸ Auto. |
| `08-phone` | Drops become 5×5 app minis with a sparkle; six fill it and a seventh bonks; hover and select a mini; a click on the stand flips it face down (three edge frames; the minis hide and drops bonk), Turn Face Up from its menu, and a mini carried back to the screen. |
| `09-fs-events` | Finder-side changes within a second: a new file prints in, a rename keeps its cell, a removal poofs, a new folder. |
| `10-clear-desk` | A busy desk (piles beside the mat, files on the floor, an open drawer, an app on the phone, the monitor on) cleared with one menu pick: the monitor's CRT collapses, the phone turns over, the drawer shuts, the brush goes round the mat pushing each pile under an edge (the edge slides over it, the hem rides up and its bump grows in), the floor files hop onto the mat's edge and tuck under (frames), "TIDY!" over the dark monitor; nothing is left on show. One ⌘Z puts every token, the drawer, the phone and the monitor back exactly. |
| `11-overflow-500` | A 500-file fixture: twelve HDMI pages of 45 (the last holding 5), paging by action and from the monitor's Input menu, a page selected with ⌘A bonking off a drawer ("That's full."), a new file landing on the last page, Clean Up By Kind over all 501; the §5 budgets: first frame with the files (1 s), frame time (4 ms) and peak memory (150 MB). |
| `12-sizes` | The nine displays of DESIGN §1.2 (scale and canvas checked) by day, at dusk and at night, each with the wall another display of that size would show at night; the portrait display's tall wall with its upper shelf, prints, beamed ceiling and ceiling lamp (Errata 26). |
| `13-file-actions` | M11 for real on the fixture, with `ls -li` of the fixture, the source folder and the FakeTrash in the log: Move to Trash from a token's menu (the poof) and ⌘Z back under the same inode into the same cell ("Put back from the Trash."); three files into the wastebasket, Empty Wastebasket… cancelled at its sheet (picture `02-sheet.png`, captioned with its default button, since an offscreen window draws none), then confirmed, and undone back into the basket; drop-in from a second scratch folder (a same-volume move into a cell, "Move In", `notes.md` arriving as `notes 2.md`, an ⌥ copy chomped into the left drawer, "Copy In", a new pile on the bare desk); a move whose file the harness then removes, so the next ⌘Z only says "Nothing to undo" and changes no file (`05b-stale-undo.png`); three undos (moved back, the copy trashed, each with its toast); apps as aliases (Erratum 29): a scratch copy of Calculator dropped with no key becomes the alias `Calculator` ("Make Alias", "Made an alias; the app stayed put.", the app still in the source, its real icon with the alias mark, `05c-alias.png`, and a double-click opens it), ⌘⌥ makes an alias of a text file chomped into the left drawer, ⌘ moves the app itself onto the desk (`05d-alias-and-move.png`), and three undos (the app back to the source, each alias to the FakeTrash); a desk item dropped back only moving; the drive hub with five fake volumes (four drives and "+1", hover, Open, Eject refused in demo mode, Show in Finder from the tag) and a bonk on a drive; drag-outs ending in a copy (nothing happens) and on the Dock Trash (trashed after 1.5 s, undoable). |
| `14-tidy-up` | Put Away and Bring Back (Erratum 30): a photo put in the cabinet, the monitor switched off, then the cabinet's menu takes the photo out first (the monitor comes on with it on HDMI 1; "Took the files out first.") and puts the cabinet away; the chair rolled where it stood, and one ⌘Z brings back both the cabinet and the photo in its drawer, behind the chair; the plant, phone stand (its glow goes too), riser drawers (the riser stays, sealed, under the monitor), string lights and wall shelf put away, by day and in Lamp Only; a drop on the sealed riser bonks ("The drawers are put away."); a file set down where the plant stood is moved aside when the plant comes back ("Moved things aside to make room."); the riser drawers back from the sealed riser's menu; Bring Everything Back from the wall's menu; Arrange Desk…. |
| `15-partition-memos` | The desk partition (Erratum 31) at night: a click on the sticky-note cube makes a note on the tower and opens its editor (`editNote:N1`); three notes, today's page and a D-Day written; a note's tooltip; a note dragged to the right wing (snapped); a file clipped to the memo clips; today's page torn off the pad into a cream note dated today (the page goes blank); a click on the calendar's 30th; Lamp Only with the lamp's wash on the left wing, an unlit note's anonymous tooltip ("Sticky Note"), the clip light switched on for the tower and right wing; a note dropped in the wastebasket and ⌘Z putting it back; Save as Text File on Desktop from a note's menu (the new file clipped up, `ls` of the fixture) and ⌘Z moving it to the FakeTrash; the partition put away with its clipped file taken out first, and ⌘Z. |

## File actions (M11)

Demos run the explicit file actions for real on the fixture: `FileOperator` with the FakeTrash in the demo's state
folder, confined to the fixture, the state folder and the drop source (`FileActionScope`); ejects are always refused
and Open/Show in Finder are only recorded. `run-demo.sh` makes an empty mktemp `source` folder beside the fixture for
each demo (`DESKTERIOR_DEMO_SOURCE`); the app takes only a scratch folder strictly inside a temporary folder
(`TMPDIR`, `/private/tmp`, `/private/var/folders`; never one in the home folder) apart from the fixture and the state
folder (`SafetyGuard.scratchSource`), since demos move files in from it. File requests in a demo come from its `menu`,
`key` (⌘Z), `dropIn` and `dragOut` steps, each with its gesture; an `action` step names none, so it changes no file.

| Step | Example | Does |
|---|---|---|
| `fs` (source) | `{"fs": {"source": "a.txt"}}`, `{"fs": {"sourceDir": "Folder"}}`, `{"fs": {"sourceApp": "Calculator.app"}}` | The harness makes a small file (or a folder with one file) in the drop source, or copies an app of `/System/Applications` there (`ditto`, else `cp -R`): a drop never takes an installed app from where it is. |
| `fs` (listing) | `{"fs": {"ls": "desk"}}` | The harness prints `ls -li` of `desk` (the fixture), `source` or `trash` (the FakeTrash) into the log. |
| `menu` (sheet) | `{"menu": {"at": "wastebasket.body", "item": "emptyWastebasket", "confirm": true, "sheetSnapshot": "02-sheet"}}` | A confirmation sheet the command asks for is confirmed (`confirm: true`) or cancelled (otherwise); `sheetSnapshot` writes the app's own sheet, drawn offscreen, as `<name>.png`. |
| `dropIn` | `{"dropIn": {"files": ["a.txt"], "at": "cell:7,4", "from": "source", "mods": ["opt"]}}` | Hands the files to the app's drop-in path (`DropInController`) at a target, as Finder would: `from` is `source` (default) or `desk` (the fixture itself: a layout move only); `opt` copies, `cmd` moves (apps too), both make aliases; with neither an app becomes an alias (Erratum 29). |
| `volumes` | `{"volumes": [{"id": "V1", "name": "Backup", "path": "/Volumes/Backup", "kind": "externalDisk", "isEjectable": true}]}` | The mounted volumes the drive hub shows (`VolumeEntry`; `kind` is `removable`, `externalDisk`, `internalDisk` or `server`). Demos never list the real ones. |
| `dragOut` | `{"dragOut": {"from": "token:a.txt", "operation": "delete"}}` | Picks the token up, hands the carry off as when it leaves the window, and ends the system's drag with `none`, `copy`, `link`, `move`, `generic` or `delete` (the Dock Trash; `DragOutRule`). |

| Target | Point |
|---|---|
| `hub.drive.<i>`, `hub.more` | A drive standing in the hub (0–3, left to right), the "+n" tag beside it. |

| Expectation | Value |
|---|---|
| `effect` | Also `trash`, `emptyWastebasket`, `import`, `undo`, `eject`, `createTextFile` (Save as Text File; the file action last asked of `FileOperator`). |
| `fileOps` | Count: `FileOperator` calls finished. |
| `sheet` | The last confirmation asked for (`emptyWastebasket:<count>`) or `none`. |
| `key:<name>` | `same` while the token has the identity (volume and inode) it had when the script first named it; `changed`, `missing`. |
| `alias:<name>` | `true` when the token is an alias (Erratum 29), `false`, or `missing`. |
| `icon:<name>` | `real` once the token's pixelated Finder icon arrived (an alias's is its target's), `kind` before, or `missing`. |
| `source:<name>` | `present` while the drop source holds an item of that name (read only), else `missing`. |
| `drives` / `drives.more` | Drives standing in the hub; volumes behind its "+n" tag. |
| `held` | Count: tokens hidden while a drag-out waits for their files to leave. |
| `toast` | Also the file toasts: `undidTrash`, `undidMoveIn`, `undidCopyIn`, `nothingToUndo`, `fileBusy`, `aliasMade`, `undidAlias`… A toast lasts 2.4 s of scene time, and a `waitFor` steps frames as fast as it can while one is up, so check a toast right after its step, before waiting on the mirror. |
| `undo` | Also the file entries: `Move to Trash`, `Empty Wastebasket`, `Move In`, `Copy In`, `Make Alias`, `Drop In` (more than one of these). |

## Recording and the README's tour (M13)

`Demos/hero.json` is the README's tour, outside the numbered set: files on the monitor; a photo chomped into the left
riser drawer; three files ⌘-clicked along a row, set down beside the mat as one pile and brushed under its edge (the
brush double-clicked home); the mat's front edge peeled back and held, the pile standing where it lay, its front file
carried back to the monitor while the edge stays up; the power button's CRT collapse; the clock's minute hand dragged
four turns from 16:00 into the night (the real clock is set to 20:00 before the release, so the hands stay), the wall
switch (Lamp Only), then the monitor back on, held 1.6 s. The tooltips that linger are English names. Unrecorded steps
after it set up the hiding places by day for a still. Its snapshots are the README's stills.

The first line writes frames to `.build/demo-out/hero/frames`; `make gif` writes the tour to `build/tour.gif` and the README's stills
(ffmpeg). The README's own `docs/media/hero.gif` is a real screen recording of the app in desk mode on a
showcase folder, not this tour.

```sh
SWIFT_SCRATCH_PATH=.build-mine scripts/run-demo.sh --record 3 --scale 2 hero
make gif
```

`run-demo.sh --record N` passes `--demo-record <out>/<name>/frames --demo-record-every N`: the app writes every Nth
scene frame it steps as `frame-NNNNN.png` (art px, the lit frame) with the demo's pointer drawn in (an arrow, grey while
a button is down, a ring after a press; snapshots never show it). Real-time waits write nothing, so the frames play at
60/N fps of scene time. `scripts/make-gif.sh` records with `DESKTERIOR_ICONS=kind`, so the media are the same on every
Mac, and assembles a ×2 nearest-neighbour, undithered, looping GIF (20 fps, at most 4 MB), the ×2 stills and two ×4
crops (the mat peeled; the riser, pen cup, phone and filing cabinet in use). The README shows each image at half its
width, so every art pixel covers whole screen pixels.

| Step | Example | Does |
|---|---|---|
| `record` | `{"record": true}`, `{"record": false}` | Starts or stops writing frames for `--demo-record` (a script without `record` steps records throughout). Nothing without the flag. |
| `glide` | `{"glide": {"to": "monitor.power", "duration": 0.35}}` | Moves the pointer with no button held to a target over `duration` s (default 0.3), eased in and out, one move per frame: it travels between gestures instead of jumping. Hover tooltips come and go on the way, and a bottom-row icon's label (drawn above it) wins the hit test, so pick paths that do not cross one. |
