# Spike gate (M2) — results and decisions

Machine: MacBook Air M2 (Mac14,2), macOS 26.6.2, Swift 6.2.3 (Command Line Tools only), display
"looks like 1470×956" @2x (2940×1912 backing on a 2560×1664 panel), Dock auto-hidden, menu bar 33 pt
(`safeAreaInsets.top` = 32), two desktop widgets top-left.

| Spike | Question | Result | Decision |
|---|---|---|---|
| S1 | icon+1 window covers Finder icons, stays below widgets; clicks/right-click/scroll/hover with another app frontmost; reveal-click; top strip | **Layering: pass (automated).** Desk mode run: `CGWindowListCopyWindowInfo` shows the Deskterior window at icon+1, 1470×956, ordered in front of Finder's icon window (icon+0) and behind the Window Server menu-bar strip (also icon+1, listed first = in front) and the widgets (icon+2). Clean exit after `--exit-after 6`. **Interaction (clicks with another app frontmost, hover, right-click, reveal-click): pending a human check.** | Keep icon+1. |
| S2 | Activating borderless window: keys, Quick Look, ⌘Z | _pending (human)_ | — |
| S3 | Occlusion notification under a full-screen app | _pending (human)_ | — |
| S4 | Drag-out operation for Finder / Mail / Dock Trash | _deferred to M11 (needs drag-out)_ | §3.6 dual rule covers both outcomes |
| S5 | SKRenderer exactness: palette round-trip, row order, drawableSize | **Pass.** In the `--windowed` run `drawableSize` stayed 2940×1912 across frames (re-asserted in `layout()`/`viewDidChangeBackingProperties()`). Offscreen `SKRenderer` → `bgra8Unorm` 64×32 target: 16/16 palette swatch pixels exact, rotated `.nearest` sprite produced only palette colours, row 0 of the target = top of the scene. **Gotcha:** `SKRenderer` ignores `scene.backgroundColor`; the render pass `clearColor` shows instead. | SKRenderer path. Always draw a full backdrop (or set the pass clear colour to the backdrop). |
| S6 | Desktop TCC prompt in a built .app (ad-hoc vs self-signed) | _deferred to M4/M12 (needs the mirror in a built app)_ | README documents re-prompts for ad-hoc builds |
| S7 | `--triple x86_64` under the CLT | **Pass.** `swift build -c release --triple x86_64-apple-macosx14.0` links a `Mach-O 64-bit executable x86_64` in 33 s. | Universal builds work locally and on CI (per-triple + `lipo`). |
| S8 | `SKMutableTexture.modifyPixelData` vs per-frame `SKTexture(data:)` at 60 fps (496×104) | **Both fine.** 1,800 frames each: RSS growth 0.02 MB, ~0.31 ms/frame including the CPU fill and an art-res render. `SKTexture(data:size:)` reads rows **bottom-up** (pinned by `TextureFactoryTests`). | Per-frame `SKTexture(data:size:)` via `TextureFactory.dynamicTexture` (flips rows). |
| S9 | Read Finder/WindowManager prefs | **Pass** via `CFPreferencesCopyAppValue`. This Mac: `CreateDesktop` unset (shown), `ShowExternalHardDrivesOnDesktop`=1, `ShowRemovableMediaOnDesktop`=1, `ShowMountedServersOnDesktop` unset, `ShowHardDrivesOnDesktop`=0, `WindowManager.StandardHideDesktopIcons` unset, `WindowManager.HideDesktop`=1. | "Finder hides desktop items" = `CreateDesktop == false` **or** `StandardHideDesktopIcons == true`. `HideDesktop` is the *Stage Manager* "show items" toggle — consult it only when Stage Manager (`GloballyEnabled`) is on. Unset `Show*OnDesktop` keys use Finder defaults (external/removable on, servers off). |
| S10 | Widget frames without Screen Recording | **Pass.** `CGWindowListCopyWindowInfo(.optionAll)` lists two 180×180 widget windows at icon+2 owned by `com.apple.notificationcenterui` (name localized: "알림 센터") at (8,45) and (188,45) pt; Finder icon window at icon+0; a 1470×81 Window Server strip at icon+1 (menu-bar backdrop). | `WidgetProbe` matches by bundle id via PID. Widgets here only overlap the decorative wall window, not interactive rects. |
| S11 | Undo by renaming out of `~/.Trash` | _pending (M11)_ | Fallback: toast "Use Finder's Put Back" |
| S12 | Drop-in move from `~/Downloads` | _pending (M11)_ | Fallback: copy on EPERM |
