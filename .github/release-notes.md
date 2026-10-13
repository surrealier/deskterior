<!-- Template: .github/workflows/release.yml fills __VERSION__ and __REPO__; generated notes follow. -->
**Deskterior __VERSION__** · macOS 14 Sonoma or later · universal (Apple silicon + Intel) · [한국어 안내](#설치-한국어)

## Install

Deskterior is free and open source, so Apple has not notarized it. macOS blocks the first launch of each
downloaded version once; that is expected.

1. Download **Deskterior-__VERSION__.zip** below and double-click it to unzip.
2. **Move `Deskterior.app` to `/Applications` first.** Opened straight from Downloads, macOS runs a
   read-only copy from a random location (App Translocation).
3. Open Deskterior. macOS says it was **Not Opened**: click **Done** (not Move to Trash).
4. Open **System Settings › Privacy & Security**, scroll to **Security**, and click **Open Anyway** next to
   the message about Deskterior. The button is there for about an hour after step 3. Enter your password and
   confirm with **Open Anyway**.
5. Repeat for every new version. Control-click → Open no longer skips this since macOS 15.

Deskterior asks for access to your **Desktop folder** when you first connect the monitor. It only reads the
folder; files change only when you explicitly ask. macOS may ask again after an update.

### Advanced

- Skip the Gatekeeper check for this copy (only if you trust where you downloaded it from):
  `xattr -dr com.apple.quarantine /Applications/Deskterior.app`
- Check that the zip was built from this tag by this repository's release workflow:

  ```sh
  shasum -a 256 -c Deskterior-__VERSION__.zip.sha256
  gh attestation verify Deskterior-__VERSION__.zip --repo __REPO__
  ```

## 설치 (한국어)

Deskterior는 무료 오픈 소스 앱이라 Apple 공증(notarization)을 받지 않았습니다. 새 버전을 내려받을 때마다 첫 실행을
macOS가 한 번 막는데, 정상입니다.

1. 아래 **Deskterior-__VERSION__.zip** 을 내려받아 더블클릭해 압축을 풉니다.
2. **먼저 `Deskterior.app`을 `/Applications`(응용 프로그램) 폴더로 옮기세요.** 다운로드 폴더에서 바로 열면 macOS가
   임의 위치의 읽기 전용 사본으로 실행합니다(App Translocation).
3. Deskterior를 엽니다. 열리지 않았다는 안내가 나오면 **완료**를 누릅니다(휴지통으로 이동 말고).
4. **시스템 설정 › 개인정보 보호 및 보안**을 열고 **보안** 항목까지 내려가 Deskterior 안내 옆의 **그래도 열기**를
   누릅니다. 이 버튼은 3단계 후 약 1시간 동안만 보입니다. 암호를 입력하고 **그래도 열기**로 확인합니다.
5. 새 버전마다 반복합니다. macOS 15부터는 Control-클릭 → 열기로 이 과정을 건너뛸 수 없습니다.

모니터를 처음 연결할 때 Deskterior가 **바탕화면 폴더** 접근을 요청합니다. 폴더를 읽기만 하며, 직접 요청할 때만
파일이 바뀝니다. 업데이트 후 macOS가 다시 물어볼 수 있습니다.

### 고급

- 이 사본의 Gatekeeper 확인 건너뛰기(다운로드 출처를 신뢰할 때만):
  `xattr -dr com.apple.quarantine /Applications/Deskterior.app`
- 이 저장소의 릴리스 워크플로가 이 태그에서 만든 zip인지 확인:

  ```sh
  shasum -a 256 -c Deskterior-__VERSION__.zip.sha256
  gh attestation verify Deskterior-__VERSION__.zip --repo __REPO__
  ```
