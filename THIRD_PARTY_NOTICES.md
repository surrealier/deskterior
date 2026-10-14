# Third-party notices

Deskterior's own code is MIT-licensed (see `LICENSE`). The following third-party material is bundled or
credited and keeps its own terms.

## Galmuri (font)
- Author: Lee Minseo (quiple) — https://github.com/quiple/galmuri
- License: SIL Open Font License 1.1 (see `Resources/Fonts/OFL-Galmuri.txt`, a verbatim copy of the
  release's `LICENSE.txt`). Copyright (c) 2019–2025 Lee Minseo. No Reserved Font Name.
- Version: v2.40.4, from https://github.com/quiple/galmuri/releases/download/v2.40.4/Galmuri-v2.40.4.zip
  (zip sha256 `c8b3d9861a62ae73c8b1178091401cd79994812437ef386413f6dd54856e60e7`).
- Bundled file(s): `Resources/Fonts/Galmuri9.ttf` — the outline TrueType (not the "Bitmap" variant), unmodified,
  4,649,144 bytes, sha256 `e84e821b18be15b9e3a907ceb83cfba25fabf51c80b7edf0d2921cf8f8e1a11d`; and its license,
  `Resources/Fonts/OFL-Galmuri.txt` (sha256 `86a3ee9495f942f0243f18c103da9faca27adb88142613edb8bb852e56c892c1`).
  In the app: `Deskterior.app/Contents/Resources/Fonts/`.

## Apollo palette
- Author: AdamCYounis — https://lospec.com/palette-list/apollo
- 46-colour pixel-art palette; used with credit per Lospec community norms.

## Not bundled

The app links only Apple's system frameworks (AppKit, SpriteKit, Metal, SwiftUI…) and the Swift runtime that ships
with macOS, and uses the system's fonts (Apple Color Emoji included) only as fallbacks at run time. Development tools
(the Command Line Tools, and ffmpeg for `make gif`) are not part of the app. All other art, including the app icon and
the screenshots in `docs/media`, is Deskterior's own, drawn in code.

## Inspiration
Deskterior is an independent project inspired by Terkel Gjervig's desktop-rug prototype *Desktop Cleaning*
(desktop.cleaning). It is not affiliated with or endorsed by him or GitHub, and uses none of its code, name,
art or branding.
