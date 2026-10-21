<!-- Template: .github/workflows/release.yml fills __VERSION__ and __REPO__; generated notes follow. -->
**Deskterior __VERSION__** · macOS 14 Sonoma or later · universal (Apple silicon + Intel) · [한국어 안내](https://github.com/__REPO__/blob/v__VERSION__/README.ko.md#설치)

A pixel-art desk that lives on your desktop: your Desktop files sit on its monitor, and you hide them in drawers, under the desk mat or behind the power button. Hiding only changes the layout; files change only when you ask. See the [README](https://github.com/__REPO__#readme) and the [changelog](https://github.com/__REPO__/blob/v__VERSION__/CHANGELOG.md).

## New in this version

- **Picture frame.** Hang a photo of your own in the framed print above the wall shelf: right-click the frame and pick Choose Photo… (or just click the empty frame), drag an image from the monitor onto it, pick Hang in Picture Frame from an image's right-click menu, or drop one from Finder onto the frame (or onto the framed print on another display's wall). It is drawn in the room's 46 colours at 26×34 pixels, dims with the room at night and hangs on your other displays' walls too.
- **Your file is only read.** The photo is read once and never moved, copied or changed, and its name never shows; one dropped on the frame from Finder stays where it is. The frame keeps its own small pixel copy in `frame.json` in the state folder, which survives Safe Mode's Reset Layout. ⌘Z takes a hang back; Remove Photo brings the print back.
- Dragging a photo straight out of the Photos app is not supported: export it as a file first, then choose or drop that file.
- Going back to 0.3.0 brings the framed print back; `frame.json` stays for 0.4.0 (the changelog has the details).

## Install

Deskterior is free and is not notarized by Apple (that needs a paid developer account). macOS blocks the first launch of each downloaded version once; that is expected.

1. Download **Deskterior-__VERSION__.zip** below and double-click it to unzip.
2. **Move `Deskterior.app` to `/Applications` first.** Opened straight from Downloads, macOS runs a read-only copy from a random location (App Translocation).
3. Open Deskterior.
   - **macOS 15 Sequoia and later:** macOS says it was **Not Opened**: click **Done** (not Move to Trash). Open **System Settings › Privacy & Security**, scroll to **Security**, and click **Open Anyway** next to the message about Deskterior. The button is there for about an hour. Then confirm with **Open Anyway** and your password or Touch ID. Control-click → Open no longer skips this.
   - **macOS 14 Sonoma:** Control-click the app, choose **Open**, then **Open** again.
4. Repeat for every new version.

Deskterior asks for access to your **Desktop folder** when you first press the monitor's ⏻. It only reads the folder; files change only when you explicitly ask. macOS may ask again after an update.

### Check the download

In the folder you downloaded to, check the checksum, and (with the [GitHub CLI](https://cli.github.com)) that this repository's release workflow built the zip from this tag:

```sh
shasum -a 256 -c Deskterior-__VERSION__.zip.sha256
gh attestation verify Deskterior-__VERSION__.zip --repo __REPO__
```

### Advanced

- Skip the Gatekeeper check for this copy (only if you trust where you downloaded it from):
  `xattr -dr com.apple.quarantine /Applications/Deskterior.app`

## 새 기능 (한국어)

- **사진 액자.** 벽 선반 위의 액자 그림 자리에 내 사진을 걸 수 있습니다. 액자를 오른쪽 클릭해 ‘사진 선택…’을 고르거나(빈 액자는 클릭만 해도 됩니다), 모니터의 사진을 끌어다 액자에 놓거나, 사진 파일의 오른쪽 클릭 메뉴에서 ‘사진 액자에 걸기’를 고르거나, Finder에서 사진을 끌어다 액자(다른 디스플레이 벽의 액자도 됩니다)에 놓으세요. 사진은 방의 46가지 색으로 26×34픽셀에 그려지고, 밤에는 방과 함께 어두워지며, 다른 디스플레이의 벽에도 걸립니다.
- **파일은 읽기만 합니다.** 사진 파일은 한 번 읽을 뿐 옮기거나 복사하거나 바꾸지 않고, 파일 이름도 보이지 않습니다. Finder에서 액자에 놓은 사진도 원래 있던 곳에 그대로 남습니다. 액자는 상태 폴더의 `frame.json`에 작은 픽셀 사본을 따로 두어서 안전 모드의 배치 초기화에도 남습니다. ⌘Z로 건 사진을 되돌리고, ‘사진 빼기’를 고르면 원래 그림이 돌아옵니다.
- 사진 앱에서 바로 끌어 오는 것은 지원하지 않습니다. 먼저 사진을 파일로 내보낸 뒤, 그 파일을 고르거나 끌어다 놓으세요.
- 0.3.0으로 되돌아가면 원래 액자 그림이 다시 나오고, `frame.json`은 0.4.0을 위해 그대로 남습니다(자세한 내용은 변경 기록에 있습니다).

## 설치 (한국어)

Deskterior는 유료 Apple 개발자 계정 없이 배포해서 공증(notarization)을 받지 않았습니다. 새 버전을 내려받을 때마다 첫 실행을 macOS가 한 번 막는데, 정상입니다.

1. 아래 **Deskterior-__VERSION__.zip**을 내려받아 더블클릭해 압축을 풉니다.
2. **먼저 `Deskterior.app`을 `/Applications`(응용 프로그램) 폴더로 옮기세요.** 다운로드 폴더에서 바로 열면 macOS가 임의 위치의 읽기 전용 사본으로 실행합니다(App Translocation).
3. Deskterior를 엽니다.
   - **macOS 15 Sequoia 이상:** 열 수 없다는 안내가 나오면 **완료**를 누릅니다(휴지통으로 이동 말고요). **시스템 설정 › 개인정보 보호 및 보안**을 열고 **보안** 항목까지 내려가 Deskterior 안내 옆의 **그래도 열기**를 누릅니다. 이 버튼은 약 1시간 동안만 보입니다. 이어서 **그래도 열기**와 암호나 Touch ID로 확인합니다. Control-클릭 → 열기로는 더 이상 건너뛸 수 없습니다.
   - **macOS 14 Sonoma:** 앱을 Control-클릭해 **열기**를 고르고, 한 번 더 **열기**를 누릅니다.
4. 새 버전마다 반복합니다.

모니터의 ⏻ 버튼을 처음 누를 때 Deskterior가 **바탕화면 폴더** 접근을 요청합니다. 폴더를 읽기만 하며, 직접 요청할 때만 파일이 바뀝니다. 업데이트 후 macOS가 다시 물어볼 수 있습니다.

### 내려받은 파일 확인

내려받은 폴더에서 체크섬을 확인하고, ([GitHub CLI](https://cli.github.com)로) 이 저장소의 릴리스 워크플로가 이 태그에서 만든 zip인지 확인합니다.

```sh
shasum -a 256 -c Deskterior-__VERSION__.zip.sha256
gh attestation verify Deskterior-__VERSION__.zip --repo __REPO__
```

### 고급

- 이 사본의 Gatekeeper 확인 건너뛰기(다운로드 출처를 신뢰할 때만):
  `xattr -dr com.apple.quarantine /Applications/Deskterior.app`
