<!-- Template: .github/workflows/release.yml fills __VERSION__ and __REPO__; generated notes follow. -->
**Deskterior __VERSION__** · macOS 14 Sonoma or later · universal (Apple silicon + Intel) · [한국어 안내](https://github.com/__REPO__/blob/v__VERSION__/README.ko.md#설치)

A pixel-art desk that lives on your desktop: your Desktop files sit on its monitor, and you hide them in drawers, under the desk mat or behind the power button. Hiding only changes the layout; files change only when you ask. See the [README](https://github.com/__REPO__#readme) and the [changelog](https://github.com/__REPO__/blob/v__VERSION__/CHANGELOG.md).

## New in this version

- **Put Away and Bring Back.** Put away what you don't use (the riser drawers, the filing cabinet, the phone stand, the plant, the desk partition or its add-ons, the wall decor) from its right-click menu, Put Away ▸ in the menu bar menu or Arrange Desk…. Nothing stays hidden inside: a place that holds files says so ("Take Out 3 & Put Away Cabinet") and brings them to the monitor first, in the same undo step. Bring Back ▸ returns anything, and moves aside what rests where it returns.
- **The desk partition.** A felt partition along the back of the desk holds sticky notes (up to 24, six colours, written in the new Memos window, Korean input included), a daily memo pad whose page tears off as a dated note, memo clips for up to 5 Desktop files, a D-Day card and a clip light for the night. The wall calendar marks the days with memos, and a click opens one.
- **Save as Text File on Desktop.** A note or today's memo becomes a new .txt file in your Desktop folder, never overwriting anything; ⌘Z moves it to the Trash while it is unchanged.
- Notes live in their own `memos.json` in the state folder and survive Safe Mode's Reset Layout. Going back to 0.2.0 brings every put-away object back (the changelog has the details).

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

- **넣어 두기와 다시 놓기.** 안 쓰는 물건(받침대 서랍, 서랍장, 휴대폰 거치대, 화분, 데스크 파티션이나 그 부속품, 벽 장식)은 물건의 오른쪽 클릭 메뉴, 메뉴 막대 메뉴의 ‘넣어 두기’ ▸, ‘소품 정리…’로 넣어 둡니다. 안에 숨는 파일은 없습니다. 파일이 든 곳은 메뉴가 먼저 알려 주고(‘3개 꺼내고 서랍장 넣어 두기’) 파일을 모니터로 꺼낸 뒤 넣어 두며, 실행 취소 한 번이면 둘 다 돌아옵니다. ‘다시 놓기’ ▸로 되돌리면 그 자리에 있던 것은 옆으로 비켜 줍니다.
- **데스크 파티션.** 책상 뒤쪽의 펠트 파티션에 메모지(최대 24장, 여섯 가지 색, 새 ‘메모’ 창에서 한글로 편집), 한 장씩 뜯어 날짜가 적힌 메모지로 붙이는 데일리 메모지, 바탕화면 파일을 5개까지 집는 메모 집게, 디데이 카드, 밤을 위한 클립 조명이 있습니다. 벽 캘린더는 메모가 있는 날을 표시하고, 날짜를 클릭하면 그날이 열립니다.
- **바탕화면에 텍스트 파일로 저장.** 메모지나 오늘 메모를 바탕화면 폴더의 새 .txt 파일로 저장합니다. 어떤 파일도 덮어쓰지 않으며, 파일이 그대로인 동안에는 ⌘Z로 휴지통으로 옮깁니다.
- 메모는 상태 폴더의 `memos.json`에 따로 저장되어 안전 모드의 배치 초기화에도 남습니다. 0.2.0으로 되돌아가면 넣어 둔 물건은 모두 다시 나옵니다(자세한 내용은 변경 기록에 있습니다).

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
