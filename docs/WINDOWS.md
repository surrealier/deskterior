# Deskterior for Windows

The Windows port keeps one codebase: the model, the scene, the pixel pipeline and the file-safety rules are shared
with macOS, and each platform supplies a thin layer underneath. This file describes that layer, what CI checks on
Windows, what still needs a person at a Windows machine, and where the implementation differs from the plan
(the "Deskterior Windows 구현 명세" document, work packages WP0–WP8).

## Building and running

On Windows with the swift.org toolchain 6.2.3 (Git Bash):

```sh
swift build -c release --product Deskterior
scripts/package-windows.sh dist/Deskterior        # exe + Swift/MSVC runtime + Resources/Fonts
dist/Deskterior/Deskterior.exe                     # mirrors %USERPROFILE%\Desktop in a window
dist/Deskterior/Deskterior.exe --snapshot desk.png # headless render of the desk, no window
```

Options: `--desktop-folder <path>`, `--state-folder <path>` (default `%APPDATA%\Deskterior`), `--connect` (start
mirroring without the first-run card), `--language ko`, `--size <w>x<h>`, `--quit-after <s>` (CI),
`--snapshot <png>` with `--frames <n>` and `--scale <s>`.

CI's `windows` job builds and tests the portable targets, runs the file-safety lint, builds and packages
`Deskterior.exe`, then runs the packaged copy with only the system folders on `PATH` twice: a headless snapshot of a
scratch folder (`scripts/make-windows-fixture.sh`: ten items, Korean and emoji names, a hidden file and
`desktop.ini` that must be left out) and a window that opens, mirrors, presents frames and quits. The folder
(`Deskterior-windows`) and the snapshot are uploaded as artifacts.

On Linux the same portable targets build and test (used for development); `Deskterior` there only renders
snapshots.

## Layers

| Layer | macOS | Windows |
|---|---|---|
| Package | `#if os(macOS)` target list unchanged | portable list: DeskCore, DeskPixels, DeskStage, DeskScene, DeskFiles, DeskteriorWin |
| Vectors, logging | simd, `os.Logger` | `VectorMath` shims, `PlatformLog` (stderr) |
| Strings | Finder, ⌘ | `L10n.platform = .windows`: File Explorer, Recycle Bin, Ctrl (`L10nTable+Windows`) |
| Scene graph | SpriteKit | `DeskStage`: the SpriteKit subset the scene uses |
| Physics | SpriteKit (Box2D) | `DeskStage/Physics.swift`: top-down AABB solver (sub-steps, push-out, restitution, friction, edges) |
| Rendering | SKRenderer → Metal lit/upscale passes | `SceneFlattener` → `SoftRaster` → `SoftPost.lit`; the window upscales with `StretchDIBits` |
| Frame loop | CVDisplayLink (`FrameTicker`) | `WinTicker` ticked by the message loop |
| Text | Galmuri9 through CoreText | `Resources/Fonts/Galmuri9.glyphs`, the same glyphs baked on macOS (`deskterior-assets bake-font`) |
| PNG | ImageIO | `PortablePNG` (zlib inflate/deflate, all PNG formats) |
| File calls | `FilePrimitives+POSIX` (the former FileOperator/FileMoves/log/state bodies) | `FilePrimitives+Windows` (Win32) |
| Scanner | resource values | `FileManager` listing + handle identity; hidden/system attributes, `desktop.ini` skipped |
| Watcher | FSEvents | `ReadDirectoryChangesW` on a thread (Linux: inotify) |
| Trash | `NSWorkspace.recycle` | `SHFileOperationW(FO_DELETE, FOF_ALLOWUNDO)`, refused on drives without a Recycle Bin |
| Aliases | Finder bookmark files | `.lnk` shortcuts (`ShellLink`) |
| Volumes, prefs | NSWorkspace, CFPreferences | `GetLogicalDrives`, Explorer's `HideIcons`/`HideFileExt` (read only) |
| App shell | DeskteriorApp (AppKit) | DeskteriorWin: Win32 window, `WinSession` |

## File safety on Windows

The promise is the same: Deskterior never moves, renames or deletes a user file on its own. Every change goes
through `FilePrimitives`, whose Windows implementation:

- renames with `MoveFileExW` without `MOVEFILE_REPLACE_EXISTING` or `MOVEFILE_COPY_ALLOWED`: a taken name is
  `EEXIST`, another volume `EXDEV`, an item in use `EPERM` (reported as locked);
- writes new files with `CREATE_NEW` (never over an existing item, never through a link) and flushes them;
- reads identity (volume serial number, file index) from a handle opened with no access, so cloud placeholders are
  not downloaded; links and junctions are not followed, OneDrive placeholders are read as the files they are;
- sends items to the Recycle Bin only on a drive that has one (`SHQueryRecycleBinW` first, `FOF_WANTNUKEWARNING` as
  a second net), so a trash can never become a delete.

The file-safety lint gained Windows rules: Win32 calls that change files (`MoveFile*`, `DeleteFile*`,
`RemoveDirectory*`, `CopyFile*`, `SetFileAttributes*`, `SHFileOperation*`, `WriteFile`, `DeviceIoControl`…) only
in `FilePrimitives+Windows.swift` and `Trasher.swift`; handles opened by path only there and in the watcher;
`ShellExecute` (opening a document, as a double-click does) only in `DeskteriorWin/Shell.swift`; registry writes,
`CreateProcess`, `WinExec` and `system` nowhere. The self-test plants each of them.

**This preview of the Windows shell changes no files at all**: `WinSession` refuses trash, drop-in, eject, Save as
Text File and file undo with a toast. They return when the shared effect runner (with the intent ledger) moves into
a `DeskApp` target (below).

## Status by work package

| WP | Status |
|---|---|
| WP0 toolchain, CI | done: `windows` job (swift.org 6.2.3), LF checkout |
| WP1 DeskCore portable | done: 836 tests on Linux and Windows |
| WP2 software renderer, DeskStage | done: soft renderer matches SpriteKit+Metal pixel for pixel in the parity suite on macOS (whole room scenes, the lit pass, sprites off the grid) |
| WP3 physics | done: the scene's physics suites pass on the AABB solver |
| WP4 glyphs, PNG | done: atlas baked on macOS CI, checked against CoreText there; PortablePNG |
| WP5 DeskFiles | ported (above); the Windows-specific tests of the plan (long paths, sharing violations, overflow, 200-file burst) are not written yet |
| WP6 app shell | first shell: window, input, frame loop, mirror, layout saving, open/reveal; no tray, menus, drag and drop or desktop layer yet |
| WP7 auxiliary windows | not started (notes, inventory, settings, arrange desk) |
| WP8 packaging | a self-contained folder as a CI artifact; no installer, signing or auto-start yet |

## Differences from the plan

- **PNG**: a Swift `PortablePNG` instead of lodepng (no C sources under `Sources`, as the lint requires).
- **Physics**: a purpose-built AABB solver in `DeskStage` instead of Box2D: every body on the desk is an
  axis-aligned box that never rotates, gravity is off; the tests pin the behaviour the scene relies on.
- **Glyph atlas** carries a CRC-32 of the font file, not SHA-256.
- **SceneHost / PixelPresenter** are split by `#if canImport(Metal)` with the same API; `PixelSurface` and
  `FrameTicker` are the seams the Windows window implements.
- **FilePrimitives** is one enum with a POSIX and a Win32 implementation (macOS bodies moved unchanged); Linux has
  development-only fallbacks (no exclusive rename, no flags, no aliases, no trash).
- **Renames** use `MoveFileExW` rather than `SetFileInformationByHandle(FileRenameInfo)`; the `expecting` identity
  check stays in `FileOperator` (check → act → verify), as on macOS.
- **Staging** for copies on Windows is the desk's hidden `.deskterior-partial-*` folder (no per-volume replacement
  folder); the scanner skips it.
- **Shortcuts** are written by a small `.lnk` writer (`ShellLink`) instead of `IShellLinkW` through C++.
- **App shell**: `DeskteriorWin` drives the shared reducer and scene directly; the `DeskApp` extraction of the Mac
  app's store, effect runner, mirror controller and demo runner (WP6 step 1) has not been done, so file requests are
  refused on Windows for now.
- **Parity test** places off-grid sprites a quarter pixel from pixel centres: at exact half-pixel edges the GPU's
  rounding of SpriteKit's projection decides coverage, which no rule reproduces, and the scene never draws there.

## Checks that need a person at a Windows machine

- **W2** the desk as the wallpaper layer (behind icons, WorkerW) — the shell opens a normal window for now.
- **W3** the message loop under real use: window drag/resize (modal loop), sleep/wake, monitor changes, high DPI.
- **W5** OneDrive placeholders: scanning does not download, a placeholder shows as cloud-only.
- **W6** Recycle Bin: trash and Explorer's Restore once file requests are enabled.
- **W7** drag and drop in and out of the window.
- **W8** fonts and Korean text on a Korean Windows install; IME in note windows (with WP7).
- Opening and revealing items (`ShellExecuteW`, `SHOpenFolderAndSelectItems`) on a real desktop.
