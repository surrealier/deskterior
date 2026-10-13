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
only). The app changes no files: `fs` steps are carried out by `run-demo.sh` in the fixture.

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
| `scroll` | `{"scroll": {"at": "monitor.screen", "dx": -30, "dy": 0}}` | Two-finger scroll, art px (content direction). |
| `key` | `{"key": "shift+cmd+z"}` | `space`, `esc`, `left`/`right`/`up`/`down`, `cmd+o`, `cmd+down`, `cmd+c`, `cmd+a`, `cmd+f`, `cmd+z`, `shift+cmd+z`. |
| `menu` | `{"menu": {"at": "token:a.txt", "item": "copy"}}` | Right-clicks there and picks the item with that `MenuItem.id` (fails if it is disabled). |
| `fs` | `{"fs": {"touch": "new.txt"}}`, `{"fs": {"mv": ["a.txt", "b.txt"]}}`, `{"fs": {"mkdir": "D"}}`, `{"fs": {"rm": "c.txt"}}` | Changes the fixture through the harness (plain names only). |
| `action` | `{"action": "accessDenied"}` | Dispatches a model action by name: `powerOn`, `powerOff`, `requestConnect`, `accessDenied`, `accessGranted`, `finderHidesItems`, `cycleInput`, `selectAV`, `page:<n>`, `takeEverythingOut`, `clearDesk`, `undo`, `redo`, `cleanUp:<name\|kind\|dateAdded>`, `lights:<auto\|day\|night\|lamp>`. |
| `expect` | `{"expect": {"token:a.txt": "cell:0,3,2", "selection": 1}}` | Checks now; every failure is reported (exit 1). |
| `waitFor` | `{"waitFor": {"expect": {"token:new.txt": "screen"}, "within": 1}}` | Runs until the expectations hold, failing after `within` s (default 3). |
| `comment` | `{"comment": "…"}` | Printed. |

### Targets

| Target | Point |
|---|---|
| an anchor name | The anchor's centre (`monitor.power`, `monitor.input`, `monitor.pageDots`, `monitor.screen`, `hub`, `wastebasket.mouth`…; `Anchors.core`). |
| `token:<name>` | The centre of that token's icon (NFC name; it must be on show). |
| `cell:<col>,<row>` | A cell of the current page. |
| `screen.empty` | The first empty cell of the current page. |
| `card.<button>` | A button on a monitor card: `card.show`, `card.keepHidden`, `card.openSettings`, `card.chooseFolder`. |
| `core:<x>,<y>` / `point:<x>,<y>` | Core px / canvas px. |

### Expectations

| Key | Value |
|---|---|
| `token:<name>` | `screen`, `screen:<HDMI n>`, `cell:<page>,<col>,<row>` (page from 0), `container`, `container:<id>`, `desk`, `floor`, `present`, `missing`. |
| `hidden` | `true`/`false` for every token named in the same `expect` (Visibility matrix). |
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
| `command` | The last app command a scene request or menu asked for (`inventory`…). |

## The demos

| Demo | Shows |
|---|---|
| `00-layout` | The mirrored fixture on the monitor by day, at night and in Lamp Only darkness. |
| `01-mirror` | Select, ⌘/⇧ extend, hover tooltip, marquee, ⌘A, a carry mid-drag and its drop, a bonk on the drive hub, double-click open, Space, Copy, undo/redo, ⌘F. |
| `02-monitor-power` | First run: connect prompt, DESKTOP HIDDEN, connect; INPUT static, OSD and the AV logo; the CRT collapse, files arriving while off (amber LED, +N), the bloom and pop-in; NO SIGNAL with its buttons. |
| `09-fs-events` | Finder-side changes within a second: a new file prints in, a rename keeps its cell, a removal poofs, a new folder. |
