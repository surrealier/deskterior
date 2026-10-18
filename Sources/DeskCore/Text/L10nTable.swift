/// Every string the app shows in English and Korean (`L10n`). Menu, toast, card and undo keys carry exactly the
/// English that `MenuSpec`, `ToastKey`, the monitor cards and `UndoJournal` produce, so `L10n.tr` can translate it;
/// the rest are the app's own windows (Settings, Safe Mode, About, onboarding, notes, VoiceOver). `L10nTests` check
/// that every key has both languages and matching placeholders.
///
/// The in-scene wastebasket is 쓰레기통 and the system Trash 휴지통, as on a Korean Mac.
public enum L10nKey: String, CaseIterable, Sendable {
    // MARK: Desk and status menus
    case monitorPower, lights, lightsAuto, lightsDay, lightsNight, lightsLampOnly, lightsRoom, lightsDeskLamp
    case findItem, takeEverythingOut, clearDesk, peekDesk, emptyWastebasket, emptyWastebasketCount
    case undo, redo, undoLabel, redoLabel, pauseDesk, resumeDesk, openDesktopFolder, settingsItem, aboutItem, quit

    // MARK: Token menu
    case open, quickLook, quickLookNamed, showInFinder, copy, moveTo, moveToTrash, monitor, hdmi, hdmiNew
    case riserLeft, riserRight, riserCubby, cabinetTop, cabinetMiddle, cabinetFile, penCup, phone, wastebasket

    // MARK: Monitor and container menus
    case displayOff, displayOn, connectDesktop, input, hdmiCount, av, cleanUpBy, sortName, sortKind, sortDateAdded
    case closeDrawer, openDrawer, faceUp, faceDown, listMore, listContents, moveContentsTo, takeAllOut, tipOver, standUp

    // MARK: Undo labels
    case undoMove, undoMoveItems, undoCleanUp

    // MARK: Toasts
    case toastContainerFull, toastAccessDenied, toastNotYetAvailable, toastDrivesReadOnly, toastWidgetsOverlap

    // MARK: Monitor cards
    case cardPress, cardToConnect, cardDesktop, cardShowsFiles, cardConnecting, cardCannotRead, cardAllowOrChoose
    case cardOpenSettings, cardChooseFolder, cardDesktopHidden, cardFinderHides, cardShowAnyway, cardShow, cardKeepHidden

    // MARK: Peek
    case peekDone, peekDoneAX

    // MARK: Settings
    case settingsTitle, settingsDesk, settingsLook, settingsSystem, lightsMode, reduceMotion, reduceMotionFollow
    case reduceMotionOn, reduceMotionOff, matMode, matCloth, matFlat, pixelSize, pixelChunky, pixelNormal, pixelFine
    case peekHotkey, peekHotkeyNote, launchAtLogin, loginAdded, loginRemoved, loginNeedsApproval, loginFailed
    case mirroredFolder, useDesktop, folderSetByFlag, folderUnavailable, folderMissing, language, languageSystem
    case languageEnglish, languageKorean, deskDisplay, mainDisplay, coverDisplays, pauseOnBattery, aboutCredits

    // MARK: About
    case aboutTitle, version, aboutTagline, aboutInspired, aboutIndependent, aboutFont, aboutPalette, aboutLicense
    case aboutSafety, ok, close

    // MARK: Safe Mode
    case safeModeTitle, safeModeBody, startNormally, resetLayout, resetConfirm, reset, cancel, resetDone, resetNothing
    case openStateFolder, quitButton

    // MARK: Onboarding and notes
    case welcomeTitle, welcomeMonitor, welcomeHide, welcomeSafe, welcomeConnect, welcomeFind, welcomeDisplays, start
    case translocationTitle, translocationBody

    // MARK: VoiceOver
    case axDesk, axWall, axWallHelp, axMoveToMonitor, axShowDeskMenu

    // MARK: Find Item (its window, `InventoryQuery`'s location labels and the kind names)
    case findItemTitle, searchAllItems, itemCount, columnLocation, takeOut, showOnDesk
    case locMonitorPage, locRiserLeft, locRiserRight, locRiserCubby, locCabinetTop, locCabinetMiddle, locCabinetFile
    case locPenCup, locUnderMat, locFloor, locInHand
    case kindFolder, kindPackage, kindDocument, kindText, kindPDF, kindImage, kindMovie, kindAudio, kindArchive, kindApp
    case kindCode, kindDiskImage, kindScreenshot

    // MARK: Panels and status lines
    case panelUseFolder, panelChooseDesktop, resetFailed, hotkeyTaken, loginTranslocated

    // MARK: Desk mat menus (M9)
    case smoothDeskMat, smoothMat, unfoldMat, rotateMat, rotateMinus15, rotatePlus15, straightenMat, matSize, matSmall
    case matMedium, matLarge, peekUnder, listItemsUnderMat, resetMat

    // MARK: File actions (M11): the drive menu, undo labels, toasts, Empty Wastebasket's sheet, the copy progress
    case ejectNamed, undoEmptyWastebasket, undoMoveIn, undoCopyIn, undoDropIn
    case toastFileChanged, toastFileGone, toastFileNotPermitted, toastUsePutBack, toastSomeNotDone, toastFileFailed
    case toastDropHoldsDesk, toastEjectFailed, toastNameTaken, toastSomeChanged, toastSomeGone, toastSomeNotPermitted
    case toastDropWholeDrive, toastFilesUnavailable, toastNothingToUndo, toastFileBusy, toastStoppingCopy
    case toastUndidTrash, toastUndidMoveIn, toastUndidCopyIn, toastUndidDropIn, toastCantMoveBack
    case sheetEmptyOne, sheetEmptyMany, sheetAndMore, sheetEmptyExplain, copyingOne, copyingMany

    // MARK: harden: locked drops, moves that came in as copies, leftovers of an interrupted copy (Errata 25)
    case toastFileLocked, toastCopiedInstead, toastLeftoverCopies, leftoversTitle, leftoversOne, leftoversMany
    case leftoversExplain, leftoversTrashed, toastSomeLocked, toastSomeCopiedInstead, toastCopiedNoUndo, leftoversNone
    // MARK: w6-polish
    case cardNoSignal
    // MARK: alias: apps dropped in become aliases, and ⌘⌥ makes one of anything (Erratum 29)
    case undoMakeAlias, toastAliasMade, toastAliasesMade, toastAliasMadeOriginal, toastAliasesMadeOriginals
    case toastAppAliasedRestIn, toastAppsAliasedRestIn, toastAliasNoUndo, toastUndidAlias, toastUndidAliases
    case toastUndidAliasMix, toastUndidAliasesMix, kindAlias
    // MARK: tidy (0.3.0): Put Away and Bring Back (Erratum 30): menus, object names, undo labels, toasts, Arrange Desk
    case putAwayMenu, bringBackMenu, bringBackAll, arrangeDesk, putAwayNamed, takeOutPutAway, bringBackNamed
    case stowRiserDrawers, stowCabinet, stowPhoneStand, stowPlant, stowPartition, stowDailyPad, stowMemoClips
    case stowClipLight, stowDDayCard, stowWallShelf, stowPegboard, stowStringLights, stowFloorPlant, stowWallArt
    case undoPutAway, undoBringBack, undoBringBackAll
    case toastPutAwayPlace, toastTookFilesOut, toastDrawersPutAway, toastMadeRoom
    case arrangeTitle, groupStorage, groupDesk, groupPartition, groupWall, onTheDesk, inside, takesOut, withPartition
    case arrangeFooter
    // MARK: memos (0.3.0): the partition, sticky notes, the daily memo pad, the calendar and memo files (Erratum 31)
    case newNote, memos, todayMemo, calendarItem, addOns, clipLightOn, clipLightOff, setDDay, clearDDay, editNote
    case colourMenu, colourYellow, colourPink, colourSky, colourLime, colourOrange, colourCream, bringToFront
    case saveTextFile, saveTodayFile, removeNote, tearOff, dayMemo, locMemoClips
    case undoAddNote, undoEditNote, undoNoteColour, undoNoteDay, undoMoveNote, undoRaiseNote, undoRemoveNote
    case undoEditDayPage, undoTearOffPage, undoSetDDay, undoClearDDay, undoSaveTextFile
    case toastPartitionFull, toastMemoClipsFull, toastNoteRemoved, toastSavedTextFile, toastUndidSaveTextFile
    case toastSavedNoUndo, toastMemosNotSaved
    case stickyNote, stickyCube, stickyCubeHelp, padHelp, dDayNamed, daysLeft, dDayToday, daysAgo
    case clipLightHelpOn, clipLightHelpOff, memoWord, notesCount, oneNote
    case axStickyNote, axDailyPad, axHasMemo, axCalendar, axMemoClips, axPartition, axClipLight, on, off
    case axMemoClipsOne, clipsEmpty, clipsOne, clipsCount, clipsFull
    case memosTitle, tabCalendar, tabNotes, today, dayPlaceholder, notesForDay, newNoteForDay, setAsDDay, dDayTitle
    case dateToggle, noNotes, emptyNote, partitionAway, noteGone, connectToSave

    public var en: String { Self.table[self]?.en ?? rawValue }
    public var ko: String { Self.table[self]?.ko ?? rawValue }

    private struct Pair: Sendable {
        let en: String
        let ko: String
    }

    private static func p(_ en: String, _ ko: String) -> Pair { Pair(en: en, ko: ko) }

    private static let table: [L10nKey: Pair] = [
        // Desk and status menus
        .monitorPower: p("Monitor Power", "모니터 전원"),
        .lights: p("Lights", "조명"),
        .lightsAuto: p("Auto", "자동"),
        .lightsDay: p("Day", "낮"),
        .lightsNight: p("Night", "밤"),
        .lightsLampOnly: p("Lamp Only", "스탠드만"),
        .lightsRoom: p("Room Light", "방 조명"),
        .lightsDeskLamp: p("Desk Lamp", "책상 스탠드"),
        .findItem: p("Find Item…", "항목 찾기…"),
        .takeEverythingOut: p("Take Everything Out", "모든 파일 꺼내기"),
        .clearDesk: p("Clear the Desk", "책상 치우기"),
        .peekDesk: p("Peek Desk", "책상 엿보기"),
        .emptyWastebasket: p("Empty Wastebasket…", "쓰레기통 비우기…"),
        .emptyWastebasketCount: p("Empty Wastebasket… (%d)", "쓰레기통 비우기… (%d)"),
        .undo: p("Undo", "실행 취소"),
        .redo: p("Redo", "실행 복귀"),
        .undoLabel: p("Undo %T", "실행 취소: %T"),
        .redoLabel: p("Redo %T", "실행 복귀: %T"),
        .pauseDesk: p("Pause Desk", "책상 일시 정지"),
        .resumeDesk: p("Resume Desk", "책상 다시 켜기"),
        .openDesktopFolder: p("Open Desktop Folder in Finder", "Finder에서 바탕화면 폴더 열기"),
        .settingsItem: p("Settings…", "설정…"),
        .aboutItem: p("About Deskterior", "Deskterior에 관하여"),
        .quit: p("Quit Deskterior", "Deskterior 종료"),

        // Token menu
        .open: p("Open", "열기"),
        .quickLook: p("Quick Look", "훑어보기"),
        .quickLookNamed: p("Quick Look “%@”", "“%@” 훑어보기"),
        .showInFinder: p("Show in Finder", "Finder에서 보기"),
        .copy: p("Copy", "복사"),
        .moveTo: p("Move to", "옮기기"),
        .moveToTrash: p("Move to Trash", "휴지통으로 이동"),
        .monitor: p("Monitor", "모니터"),
        .hdmi: p("HDMI %d", "HDMI %d"),
        .hdmiNew: p("HDMI %d (New)", "HDMI %d (새 입력)"),
        .riserLeft: p("Left Riser Drawer", "받침대 왼쪽 서랍"),
        .riserRight: p("Right Riser Drawer", "받침대 오른쪽 서랍"),
        .riserCubby: p("Riser Cubby", "받침대 칸"),
        .cabinetTop: p("Top Cabinet Drawer", "서랍장 위 칸"),
        .cabinetMiddle: p("Middle Cabinet Drawer", "서랍장 가운데 칸"),
        .cabinetFile: p("File Drawer", "서랍장 서류 칸"),
        .penCup: p("Pen Cup", "펜꽂이"),
        .phone: p("Phone", "휴대폰"),
        .wastebasket: p("Wastebasket", "쓰레기통"),

        // Monitor and container menus
        .displayOff: p("Turn Display Off", "화면 끄기"),
        .displayOn: p("Turn Display On", "화면 켜기"),
        .connectDesktop: p("Connect Desktop", "바탕화면 연결"),
        .input: p("Input", "입력"),
        .hdmiCount: p("HDMI %d · %d", "HDMI %d · %d"),
        .av: p("AV", "AV"),
        .cleanUpBy: p("Clean Up By", "정리 기준"),
        .sortName: p("Name", "이름"),
        .sortKind: p("Kind", "종류"),
        .sortDateAdded: p("Date Added", "추가된 날짜"),
        .closeDrawer: p("Close Drawer", "서랍 닫기"),
        .openDrawer: p("Open Drawer", "서랍 열기"),
        .faceUp: p("Turn Face Up", "화면이 위로 오게 뒤집기"),
        .faceDown: p("Turn Face Down", "화면이 아래로 가게 뒤집기"),
        .listMore: p("%d More…", "%d개 더…"),
        .listContents: p("List Contents", "내용 보기"),
        .moveContentsTo: p("Move Contents to", "내용물 옮기기"),
        .takeAllOut: p("Take All Out", "전부 꺼내기"),
        .tipOver: p("Tip Over", "넘어뜨리기"),
        .standUp: p("Stand Up", "세우기"),

        // Undo labels
        .undoMove: p("Move", "이동"),
        .undoMoveItems: p("Move %d Items", "항목 %d개 이동"),
        .undoCleanUp: p("Clean Up", "정리"),

        // Toasts
        .toastContainerFull: p("That's full.", "가득 찼어요."),
        .toastAccessDenied: p("No access to the Desktop folder.", "바탕화면 폴더에 접근할 수 없어요."),
        .toastNotYetAvailable: p("Not available yet.", "아직 쓸 수 없어요."),
        .toastDrivesReadOnly: p("Use Finder to copy to drives.", "드라이브로 복사는 Finder에서 하세요."),
        .toastWidgetsOverlap: p("Widgets cover part of the desk.", "위젯이 책상 일부를 가려요."),

        // Monitor cards ("PRESS ⏻ TO CONNECT / DESKTOP": the glyph sits between the first two)
        .cardPress: p("PRESS", "전원"),
        .cardToConnect: p("TO CONNECT", "버튼을 눌러"),
        .cardDesktop: p("DESKTOP", "바탕화면 연결"),
        .cardShowsFiles: p("Shows your Desktop files here.", "바탕화면 파일이 여기 보여요."),
        .cardConnecting: p("CONNECTING…", "연결 중…"),
        .cardCannotRead: p("Can't read the Desktop folder.", "바탕화면 폴더를 읽을 수 없어요."),
        .cardAllowOrChoose: p("Allow access, or choose it:", "접근을 허용하거나 직접 고르세요:"),
        .cardOpenSettings: p("Open Settings", "설정 열기"),
        .cardChooseFolder: p("Choose Folder…", "폴더 선택…"),
        .cardDesktopHidden: p("DESKTOP HIDDEN", "바탕화면 숨김"),
        .cardFinderHides: p("Finder hides desktop items.", "Finder가 바탕화면 항목을 숨겨요."),
        .cardShowAnyway: p("Show them on the desk anyway?", "그래도 책상에 보여 줄까요?"),
        .cardShow: p("Show", "보이기"),
        .cardKeepHidden: p("Keep Hidden", "숨겨 두기"),

        // Peek
        .peekDone: p("× Done", "× 완료"),
        .peekDoneAX: p("Done Peeking", "엿보기 끝내기"),

        // Settings
        .settingsTitle: p("Deskterior Settings", "Deskterior 설정"),
        .settingsDesk: p("Desk", "책상"),
        .settingsLook: p("Look", "모양"),
        .settingsSystem: p("System", "시스템"),
        .lightsMode: p("Lights", "조명"),
        .reduceMotion: p("Reduce motion", "동작 줄이기"),
        .reduceMotionFollow: p("Follow System", "시스템 설정 따르기"),
        .reduceMotionOn: p("Always", "항상"),
        .reduceMotionOff: p("Never", "안 함"),
        .matMode: p("Desk mat", "책상 매트"),
        .matCloth: p("Cloth", "천"),
        .matFlat: p("Flat", "평평하게"),
        .pixelSize: p("Pixel size", "픽셀 크기"),
        .pixelChunky: p("Chunky", "큼직하게"),
        .pixelNormal: p("Normal", "보통"),
        .pixelFine: p("Fine", "촘촘하게"),
        .peekHotkey: p("Peek Desk shortcut ⌃⌥⌘D", "책상 엿보기 단축키 ⌃⌥⌘D"),
        .peekHotkeyNote: p("Off unless you turn it on. Needs no Accessibility permission.",
                           "켜기 전에는 꺼져 있어요. 손쉬운 사용 권한이 필요 없어요."),
        .launchAtLogin: p("Launch at login", "로그인 시 실행"),
        .loginAdded: p("Login item added.", "로그인 항목에 추가했어요."),
        .loginRemoved: p("Login item removed.", "로그인 항목에서 뺐어요."),
        .loginNeedsApproval: p("Approve it in System Settings ▸ General ▸ Login Items.",
                               "시스템 설정 ▸ 일반 ▸ 로그인 항목에서 승인해 주세요."),
        .loginFailed: p("Could not change the login item.", "로그인 항목을 바꾸지 못했어요."),
        .mirroredFolder: p("Mirrored folder", "보여 줄 폴더"),
        .useDesktop: p("Use Desktop", "바탕화면 쓰기"),
        .folderSetByFlag: p("Set by --desktop-folder for this run.", "이번 실행에서는 --desktop-folder로 정해졌어요."),
        .folderUnavailable: p("That folder can't be mirrored.", "그 폴더는 보여 줄 수 없어요."),
        .folderMissing: p("The chosen folder wasn't there at launch, so the desk shows the Desktop.",
                          "고른 폴더가 실행할 때 없어서 바탕화면을 보여 주고 있어요."),
        .language: p("Language", "언어"),
        .languageSystem: p("System", "시스템"),
        .languageEnglish: p("English", "English"),
        .languageKorean: p("한국어", "한국어"),
        .deskDisplay: p("Desk display", "책상 디스플레이"),
        .mainDisplay: p("Menu bar display", "메뉴 막대 디스플레이"),
        .coverDisplays: p("Cover other displays with a wall", "다른 디스플레이를 벽으로 덮기"),
        .pauseOnBattery: p("Pause the desk on battery power", "배터리 사용 중에는 책상 멈추기"),
        .aboutCredits: p("About & Credits…", "정보 및 크레딧…"),

        // About
        .aboutTitle: p("About Deskterior", "Deskterior에 관하여"),
        .version: p("Version %@", "버전 %@"),
        .aboutTagline: p("A pixel-art desk for your desktop.", "바탕화면을 위한 픽셀 아트 책상."),
        .aboutInspired: p("Deskterior is an independent project inspired by Terkel Gjervig's desktop-rug prototype “Desktop Cleaning” (desktop.cleaning).",
                          "Deskterior는 Terkel Gjervig의 데스크톱 러그 프로토타입 “Desktop Cleaning”(desktop.cleaning)에서 영감을 받은 독립 프로젝트예요."),
        .aboutIndependent: p("It is not affiliated with or endorsed by him or GitHub, and uses none of the prototype's code, name, art or branding.",
                             "원작자나 GitHub와 제휴하거나 보증받지 않았고, 원작 프로토타입의 코드·이름·그림·브랜딩을 전혀 쓰지 않아요."),
        .aboutFont: p("Galmuri9 font by Lee Minseo, SIL Open Font License 1.1.", "갈무리9 글꼴: 이민서, SIL Open Font License 1.1."),
        .aboutPalette: p("Apollo palette by AdamCYounis.", "Apollo 팔레트: AdamCYounis."),
        .aboutLicense: p("Code under the MIT License. No network, no telemetry.", "코드는 MIT 라이선스. 네트워크도, 원격 수집도 없어요."),
        .aboutSafety: p("Deskterior never moves, renames or deletes your files on its own.",
                        "Deskterior는 요청하지 않으면 파일을 옮기거나 이름을 바꾸거나 지우지 않아요."),
        .ok: p("OK", "확인"),
        .close: p("Close", "닫기"),

        // Safe Mode
        .safeModeTitle: p("Deskterior Safe Mode", "Deskterior 안전 모드"),
        .safeModeBody: p("Deskterior started in Safe Mode (⌥ held at launch). The desk has not started and no file has been touched.",
                         "실행할 때 ⌥ 키를 눌러 안전 모드로 시작했어요. 책상은 아직 시작하지 않았고 파일은 건드리지 않았어요."),
        .startNormally: p("Start Normally", "평소대로 시작"),
        .resetLayout: p("Reset Layout…", "배치 초기화…"),
        .resetConfirm: p("Every file goes back to the monitor. The current layout is kept as a backup in the state folder. No file is deleted.",
                         "모든 파일이 모니터로 돌아가요. 지금 배치는 상태 폴더에 백업으로 남고, 파일은 지우지 않아요."),
        .reset: p("Reset", "초기화"),
        .cancel: p("Cancel", "취소"),
        .resetDone: p("Layout reset. Backup: %@", "배치를 초기화했어요. 백업: %@"),
        .resetNothing: p("There was no saved layout to reset.", "초기화할 저장된 배치가 없어요."),
        .openStateFolder: p("Open State Folder", "상태 폴더 열기"),
        .quitButton: p("Quit", "종료"),

        // Onboarding and notes
        .welcomeTitle: p("Welcome to Deskterior", "Deskterior에 오신 걸 환영해요"),
        .welcomeMonitor: p("Your Desktop files show up as icons on the monitor of a little pixel desk.",
                           "바탕화면 파일이 작은 픽셀 책상의 모니터에 아이콘으로 나타나요."),
        .welcomeHide: p("Hide them in drawers, the phone, the pen cup, the wastebasket or under the desk mat, or switch the monitor off.",
                        "서랍, 휴대폰, 펜꽂이, 쓰레기통, 책상 매트 밑에 숨기거나 모니터를 꺼 보세요."),
        .welcomeSafe: p("Hiding only changes the layout. Files change only when you ask, like Move to Trash.",
                        "숨기기는 배치만 바꿔요. 파일은 ‘휴지통으로 이동’처럼 직접 요청할 때만 바뀌어요."),
        .welcomeConnect: p("Press ⏻ on the monitor to connect your Desktop folder.", "모니터의 ⏻ 버튼을 눌러 바탕화면 폴더를 연결하세요."),
        .welcomeFind: p("Lost something? Find Item… lists every file and where it is.",
                        "뭔가 안 보이면 ‘항목 찾기…’에서 모든 파일과 위치를 볼 수 있어요."),
        .welcomeDisplays: p("You have more than one display.", "디스플레이가 여러 대예요."),
        .start: p("Start", "시작"),
        .translocationTitle: p("Move Deskterior to Applications", "Deskterior를 응용 프로그램 폴더로 옮겨 주세요"),
        .translocationBody: p("macOS is running Deskterior from a temporary read-only copy (App Translocation), so it can forget its permissions and its login item. Quit, drag Deskterior.app into the Applications folder in Finder, and open it from there.",
                              "macOS가 Deskterior를 임시 읽기 전용 사본(App Translocation)에서 실행하고 있어 권한과 로그인 항목을 잊을 수 있어요. 종료한 뒤 Finder에서 Deskterior.app을 응용 프로그램 폴더로 옮기고 거기서 여세요."),

        // VoiceOver
        .axDesk: p("Deskterior desk", "Deskterior 책상"),
        .axWall: p("Deskterior wall", "Deskterior 벽"),
        .axWallHelp: p("Drop files here to put them on the monitor.", "파일을 여기 놓으면 모니터에 올라가요."),
        .axMoveToMonitor: p("Move to Monitor", "모니터로 옮기기"),
        .axShowDeskMenu: p("Show Desk Menu", "책상 메뉴 보기"),

        // Find Item
        .findItemTitle: p("Find Item", "항목 찾기"),
        .searchAllItems: p("Search all items", "모든 항목 검색"),
        .itemCount: p("%d of %d", "%d개 / 전체 %d개"),
        .columnLocation: p("Location", "위치"),
        .takeOut: p("Take Out", "꺼내기"),
        .showOnDesk: p("Show on Desk", "책상에서 보기"),
        .locMonitorPage: p("Monitor · HDMI %d", "모니터 · HDMI %d"),
        .locRiserLeft: p("Riser ▸ left drawer", "받침대 ▸ 왼쪽 서랍"),
        .locRiserRight: p("Riser ▸ right drawer", "받침대 ▸ 오른쪽 서랍"),
        .locRiserCubby: p("Riser ▸ cubby", "받침대 ▸ 칸"),
        .locCabinetTop: p("Cabinet ▸ top", "서랍장 ▸ 위 칸"),
        .locCabinetMiddle: p("Cabinet ▸ middle", "서랍장 ▸ 가운데 칸"),
        .locCabinetFile: p("Cabinet ▸ file", "서랍장 ▸ 서류 칸"),
        .locPenCup: p("Pen cup", "펜꽂이"),
        .locUnderMat: p("Under mat", "매트 밑"),
        .locFloor: p("Floor", "바닥"),
        .locInHand: p("In hand", "들고 있음"),
        .kindFolder: p("Folder", "폴더"),
        .kindPackage: p("Package", "패키지"),
        .kindDocument: p("Document", "문서"),
        .kindText: p("Plain text", "일반 텍스트"),
        .kindPDF: p("PDF document", "PDF 문서"),
        .kindImage: p("Image", "이미지"),
        .kindMovie: p("Movie", "동영상"),
        .kindAudio: p("Audio", "오디오"),
        .kindArchive: p("Archive", "압축 파일"),
        .kindApp: p("Application", "응용 프로그램"),
        .kindCode: p("Source code", "소스 코드"),
        .kindDiskImage: p("Disk image", "디스크 이미지"),
        .kindScreenshot: p("Screenshot", "스크린샷"),

        // Panels and status lines
        .panelUseFolder: p("Use Folder", "이 폴더 사용"),
        .panelChooseDesktop: p("Choose your Desktop folder so Deskterior can show it.",
                               "Deskterior가 보여 줄 수 있게 바탕화면 폴더를 선택하세요."),
        .resetFailed: p("Could not reset the layout: %@", "배치를 초기화하지 못했어요: %@"),
        .hotkeyTaken: p("Another app is using ⌃⌥⌘D, so the shortcut is off.", "다른 앱이 ⌃⌥⌘D를 쓰고 있어서 단축키를 껐어요."),
        .loginTranslocated: p("Move Deskterior to the Applications folder to launch it at login.",
                              "로그인 시 실행하려면 Deskterior를 응용 프로그램 폴더로 옮겨 주세요."),

        // Desk mat menus
        .smoothDeskMat: p("Smooth Desk Mat", "책상 매트 펴기"),
        .smoothMat: p("Smooth Mat", "매트 펴기"),
        .unfoldMat: p("Unfold", "접힌 곳 펴기"),
        .rotateMat: p("Rotate", "돌리기"),
        .rotateMinus15: p("Rotate −15°", "−15° 돌리기"),
        .rotatePlus15: p("Rotate +15°", "+15° 돌리기"),
        .straightenMat: p("Straighten", "똑바로 놓기"),
        .matSize: p("Size", "크기"),
        .matSmall: p("Small", "작게"),
        .matMedium: p("Medium", "보통"),
        .matLarge: p("Large", "크게"),
        .peekUnder: p("Peek Under", "밑 들춰 보기"),
        .listItemsUnderMat: p("List Items Under Mat", "매트 밑 항목 보기"),
        .resetMat: p("Reset Mat", "매트 처음대로"),

        // File actions
        .ejectNamed: p("Eject “%@”", "“%@” 추출"),
        .undoEmptyWastebasket: p("Empty Wastebasket", "쓰레기통 비우기"),
        .undoMoveIn: p("Move In", "옮겨 오기"),
        .undoCopyIn: p("Copy In", "복사해 오기"),
        .undoDropIn: p("Drop In", "가져오기"),
        .toastFileChanged: p("It changed on disk. Nothing was done.", "디스크에서 바뀌어서 그대로 뒀어요."),
        .toastFileGone: p("That file is gone already.", "그 파일은 이미 없어요."),
        .toastFileNotPermitted: p("macOS did not allow that.", "macOS가 허락하지 않았어요."),
        .toastUsePutBack: p("Use Finder's Put Back.", "Finder의 되돌려 놓기를 쓰세요."),
        .toastSomeNotDone: p("Some items stayed where they were.", "일부 항목은 그대로 있어요."),
        .toastFileFailed: p("That did not work. Nothing changed.", "안 됐어요. 바뀐 건 없어요."),
        .toastDropHoldsDesk: p("Can't drop the Desktop or a parent folder.", "바탕화면이나 그 상위 폴더는 놓을 수 없어요."),
        .toastEjectFailed: p("The drive could not be ejected.", "드라이브를 추출하지 못했어요."),
        .toastNameTaken: p("Too many items with that name.", "같은 이름의 항목이 너무 많아요."),
        .toastSomeChanged: p("Some changed on disk, so they stayed.", "일부는 디스크에서 바뀌어서 그대로 뒀어요."),
        .toastSomeGone: p("Some were gone already.", "일부는 이미 없었어요."),
        .toastSomeNotPermitted: p("macOS kept some items where they were.", "macOS가 일부 항목을 그대로 뒀어요."),
        .toastDropWholeDrive: p("Drag files from the drive, not the drive.", "드라이브 말고 그 안의 파일을 끌어 오세요."),
        .toastFilesUnavailable: p("The desk isn't connected to its folder.", "책상이 폴더에 연결되지 않았어요."),
        .toastNothingToUndo: p("Nothing to undo: those items are gone.", "되돌릴 게 없어요. 그 항목들은 사라졌어요."),
        .toastFileBusy: p("Still working on that.", "아직 처리 중이에요."),
        .toastStoppingCopy: p("Stopping the copy…", "복사를 멈추는 중…"),
        .toastUndidTrash: p("Put back from the Trash.", "휴지통에서 되돌려 놓았어요."),
        .toastUndidMoveIn: p("Sent back where they came from.", "원래 있던 곳으로 돌려보냈어요."),
        .toastUndidCopyIn: p("Copies moved to the Trash.", "복사본을 휴지통으로 옮겼어요."),
        .toastUndidDropIn: p("Sent back; copies moved to the Trash.", "돌려보내고 복사본은 휴지통으로 옮겼어요."),
        .toastCantMoveBack: p("macOS would not let it go back.", "macOS가 되돌리지 못하게 했어요."),
        .sheetEmptyOne: p("Move the item in the wastebasket to the Trash?", "쓰레기통의 항목을 휴지통으로 옮길까요?"),
        .sheetEmptyMany: p("Move the %d items in the wastebasket to the Trash?", "쓰레기통의 항목 %d개를 휴지통으로 옮길까요?"),
        .sheetAndMore: p("and %d more", "외 %d개"),
        .sheetEmptyExplain: p("The wastebasket only hides files on the desk. This moves them to the Trash; Undo or Finder's Put Back returns them.",
                              "쓰레기통은 책상 위 파일을 숨기기만 해요. 이 작업은 파일을 휴지통으로 옮기고, 실행 취소나 Finder의 되돌려 놓기로 돌려놓을 수 있어요."),
        .copyingOne: p("Copying %d item… ⌘Z stops", "항목 %d개 복사 중… ⌘Z로 멈춤"),
        .copyingMany: p("Copying %d items… ⌘Z stops", "항목 %d개 복사 중… ⌘Z로 멈춤"),

        // MARK: harden
        .toastFileLocked: p("It's locked, so it stayed. ⌥ copies it.", "잠겨 있어서 그대로 뒀어요. ⌥로 복사해요."),
        .toastCopiedInstead: p("Copied in; the original stayed put.", "복사해 왔어요. 원본은 그대로예요."),
        .toastLeftoverCopies: p("Interrupted copy left files. See Settings.", "중단된 복사의 파일이 남았어요. 설정을 보세요."),
        .leftoversTitle: p("Leftover copies", "남은 복사본"),
        .leftoversOne: p("%d hidden folder from an interrupted copy is in the desk folder.",
                         "중단된 복사로 생긴 숨은 폴더 %d개가 책상 폴더에 있어요."),
        .leftoversMany: p("%d hidden folders from an interrupted copy are in the desk folder.",
                          "중단된 복사로 생긴 숨은 폴더 %d개가 책상 폴더에 있어요."),
        .leftoversExplain: p("Deskterior never removes them by itself. Look inside, then move them to the Trash if you don't need them.",
                             "Deskterior는 이 폴더를 스스로 지우지 않아요. 안을 확인하고 필요 없으면 휴지통으로 옮기세요."),
        .leftoversTrashed: p("Moved to the Trash.", "휴지통으로 옮겼어요."),
        .toastSomeLocked: p("Some were locked, so they stayed.", "일부는 잠겨 있어서 그대로 뒀어요."),
        .toastSomeCopiedInstead: p("Some came in as copies; the rest stayed.", "일부는 복사해 왔고 나머지는 그대로 뒀어요."),
        .toastCopiedNoUndo: p("Copied in, but it can't be undone.", "복사해 왔지만 실행 취소할 수 없어요."),
        .leftoversNone: p("No leftover copies now.", "지금은 남은 복사본이 없어요."),
        // MARK: w6-polish
        // The badge over the NO SIGNAL card's text (the bouncing logo of an empty input stays the monitor's own).
        .cardNoSignal: p("NO SIGNAL", "신호 없음"),
        // MARK: alias (Erratum 29)
        // The undo label of a drop that made aliases ("Undo Make Alias"), Finder's own wording.
        .undoMakeAlias: p("Make Alias", "별칭 만들기"),
        .toastAliasMade: p("Made an alias; the app stayed put.", "별칭을 만들었어요. 앱은 그대로예요."),
        .toastAliasesMade: p("Made aliases; the apps stayed put.", "별칭을 만들었어요. 앱은 모두 그대로예요."),
        .toastAliasMadeOriginal: p("Made an alias; the original stayed put.", "별칭을 만들었어요. 원본은 그대로예요."),
        .toastAliasesMadeOriginals: p("Made aliases; the originals stayed put.", "별칭을 만들었어요. 원본은 모두 그대로예요."),
        // Korean says it once for one app or several: the apps got aliases only, the other items came in.
        .toastAppAliasedRestIn: p("The app became an alias; the rest came in.", "앱은 별칭만 만들고 나머지는 가져왔어요."),
        .toastAppsAliasedRestIn: p("Apps became aliases; the rest came in.", "앱은 별칭만 만들고 나머지는 가져왔어요."),
        .toastAliasNoUndo: p("Made an alias, but it can't be undone.", "별칭을 만들었지만 실행 취소할 수 없어요."),
        .toastUndidAlias: p("The alias went to the Trash.", "별칭을 휴지통으로 옮겼어요."),
        .toastUndidAliases: p("The aliases went to the Trash.", "별칭을 모두 휴지통으로 옮겼어요."),
        .toastUndidAliasMix: p("Undone; the alias went to the Trash.", "되돌리고 별칭은 휴지통으로 옮겼어요."),
        .toastUndidAliasesMix: p("Undone; the aliases went to the Trash.", "되돌리고 별칭은 모두 휴지통으로 옮겼어요."),
        // Find Item's Kind column for an alias (a Finder alias or a symbolic link).
        .kindAlias: p("Alias", "별칭"),

        // MARK: tidy (0.3.0)
        // 넣어 두기 / 다시 놓기: 치우기 is Clear the Desk's and 꺼내기 Take Out's. Object names fill the %T templates.
        .putAwayMenu: p("Put Away", "넣어 두기"),
        .bringBackMenu: p("Bring Back", "다시 놓기"),
        .bringBackAll: p("Bring Everything Back", "모두 다시 놓기"),
        .arrangeDesk: p("Arrange Desk…", "소품 정리…"),
        .putAwayNamed: p("Put Away %T", "%T 넣어 두기"),
        .takeOutPutAway: p("Take Out %d & Put Away %T", "%d개 꺼내고 %T 넣어 두기"),
        .bringBackNamed: p("Bring Back %T", "%T 다시 놓기"),
        .stowRiserDrawers: p("Riser Drawers", "받침대 서랍"),
        .stowCabinet: p("Cabinet", "서랍장"),
        .stowPhoneStand: p("Phone Stand", "휴대폰 거치대"),
        .stowPlant: p("Plant", "화분"),
        .stowPartition: p("Desk Partition", "데스크 파티션"),
        .stowDailyPad: p("Daily Memo Pad", "데일리 메모지"),
        .stowMemoClips: p("Memo Clips", "메모 집게"),
        .stowClipLight: p("Clip Light", "클립 조명"),
        .stowDDayCard: p("D-Day Card", "디데이 카드"),
        .stowWallShelf: p("Wall Shelf", "벽 선반"),
        .stowPegboard: p("Pegboard", "타공판"),
        .stowStringLights: p("String Lights", "줄전구"),
        .stowFloorPlant: p("Floor Plant", "바닥 화분"),
        .stowWallArt: p("Wall Art", "벽 장식"),
        .undoPutAway: p("Put Away", "넣어 두기"),
        .undoBringBack: p("Bring Back", "다시 놓기"),
        .undoBringBackAll: p("Bring Everything Back", "모두 다시 놓기"),
        .toastPutAwayPlace: p("That's put away.", "넣어 둔 물건이에요."),
        .toastTookFilesOut: p("Took the files out first.", "먼저 파일을 꺼냈어요."),
        .toastDrawersPutAway: p("The drawers are put away.", "서랍은 넣어 뒀어요."),
        .toastMadeRoom: p("Moved things aside to make room.", "자리를 비우려고 옆으로 옮겼어요."),
        // The Arrange Desk window.
        .arrangeTitle: p("Arrange Desk", "소품 정리"),
        .groupStorage: p("Storage", "수납"),
        .groupDesk: p("Desk", "책상"),
        .groupPartition: p("Partition", "파티션"),
        .groupWall: p("Wall", "벽"),
        .onTheDesk: p("On the Desk", "책상에 두기"),
        .inside: p("%d inside", "%d개 들어 있음"),
        .takesOut: p("Putting it away takes %d files out to the monitor.", "넣어 두면 파일 %d개를 모니터로 꺼내요."),
        .withPartition: p("Comes back with the partition.", "파티션과 함께 돌아와요."),
        .arrangeFooter: p("Put-away things leave the room. Files never stay inside them, and ⌘Z brings them back.",
                          "넣어 둔 물건은 방에서 사라져요. 그 안에 파일은 남지 않고, ⌘Z로 되돌릴 수 있어요."),

        // MARK: memos (0.3.0)
        // Menus and titles (user text never appears in a menu title).
        .newNote: p("New Sticky Note", "새 메모지"),
        .memos: p("Memos…", "메모…"),
        .todayMemo: p("Today's Memo…", "오늘 메모…"),
        .calendarItem: p("Calendar…", "캘린더…"),
        .addOns: p("Add-ons", "부속품"),
        .clipLightOn: p("Turn Clip Light On", "클립 조명 켜기"),
        .clipLightOff: p("Turn Clip Light Off", "클립 조명 끄기"),
        .setDDay: p("Set D-Day…", "디데이 설정…"),
        .clearDDay: p("Clear D-Day", "디데이 지우기"),
        .editNote: p("Edit Note…", "메모지 편집…"),
        .colourMenu: p("Colour", "색"),
        .colourYellow: p("Yellow", "노랑"),
        .colourPink: p("Pink", "분홍"),
        .colourSky: p("Sky", "하늘"),
        .colourLime: p("Lime", "연두"),
        .colourOrange: p("Orange", "주황"),
        .colourCream: p("Cream", "크림"),
        .bringToFront: p("Bring to Front", "맨 앞으로"),
        .saveTextFile: p("Save as Text File on Desktop", "바탕화면에 텍스트 파일로 저장"),
        .saveTodayFile: p("Save Today's Memo as Text File", "오늘 메모를 텍스트 파일로 저장"),
        .removeNote: p("Remove Note", "메모지 떼기"),
        .tearOff: p("Tear Off as Sticky Note", "뜯어서 메모지로 붙이기"),
        .dayMemo: p("Open Memo for This Day…", "이날 메모 열기…"),
        .locMemoClips: p("Partition ▸ memo clips", "파티션 ▸ 메모 집게"),
        // Undo labels.
        .undoAddNote: p("New Sticky Note", "새 메모지"),
        .undoEditNote: p("Edit Note", "메모지 편집"),
        .undoNoteColour: p("Note Colour", "메모지 색"),
        .undoNoteDay: p("Note Date", "메모지 날짜"),
        .undoMoveNote: p("Move Note", "메모지 옮기기"),
        .undoRaiseNote: p("Bring to Front", "맨 앞으로"),
        .undoRemoveNote: p("Remove Note", "메모지 떼기"),
        .undoEditDayPage: p("Edit Memo", "메모 편집"),
        .undoTearOffPage: p("Tear Off Page", "한 장 뜯기"),
        .undoSetDDay: p("Set D-Day", "디데이 설정"),
        .undoClearDDay: p("Clear D-Day", "디데이 지우기"),
        .undoSaveTextFile: p("Save as Text File", "텍스트 파일로 저장"),
        // Toasts.
        .toastPartitionFull: p("The partition is full.", "파티션이 가득 찼어요."),
        .toastMemoClipsFull: p("The memo clips are full.", "메모 집게가 가득 찼어요."),
        .toastNoteRemoved: p("Note taken off.", "메모지를 뗐어요."),
        .toastSavedTextFile: p("Saved as a text file.", "텍스트 파일로 저장했어요."),
        .toastUndidSaveTextFile: p("The text file went to the Trash.", "텍스트 파일을 휴지통으로 옮겼어요."),
        .toastSavedNoUndo: p("Saved, but it can't be undone.", "저장했지만 실행 취소할 수 없어요."),
        .toastMemosNotSaved: p("Memos can't be saved this time.", "이번에는 메모를 저장할 수 없어요."),
        // Scene tooltips and VoiceOver (through `L10n.tr`; an exception to Errata 21/23 for these items only).
        .stickyNote: p("Sticky Note", "메모지"),
        .stickyCube: p("Sticky Note Cube", "메모지 큐브"),
        .stickyCubeHelp: p("Click for a new note · drag to peel one off", "클릭: 새 메모지 · 드래그: 한 장 떼기"),
        .padHelp: p("Click to write today's memo", "눌러서 오늘 메모 쓰기"),
        .dDayNamed: p("D-Day: %@", "디데이: %@"),
        .daysLeft: p("%d days left", "%d일 남음"),
        .dDayToday: p("Today", "오늘"),
        .daysAgo: p("%d days ago", "%d일 지남"),
        .clipLightHelpOn: p("Click to turn it on", "눌러서 켜기"),
        .clipLightHelpOff: p("Click to turn it off", "눌러서 끄기"),
        .memoWord: p("memo", "메모"),
        .notesCount: p("%d notes", "메모지 %d장"),
        .oneNote: p("1 note", "메모지 1장"),
        .axStickyNote: p("Sticky note: %@", "메모지: %@"),
        .axDailyPad: p("Daily memo pad, %@", "데일리 메모지, %@"),
        .axHasMemo: p("has a memo", "메모 있음"),
        .axCalendar: p("Calendar, %@, %d days with memos", "캘린더, %@, 메모가 있는 날 %d일"),
        .axMemoClips: p("Memo clips, %d files", "메모 집게, 파일 %d개"),
        .axMemoClipsOne: p("Memo clips, 1 file", "메모 집게, 파일 1개"),
        // The memo clips' tooltip detail (the older containers' stay English, Errata 21/23).
        .clipsEmpty: p("Empty", "비어 있음"),
        .clipsOne: p("1 item", "1개"),
        .clipsCount: p("%d items", "%d개"),
        .clipsFull: p("Full · %d items", "가득 참 · %d개"),
        .axPartition: p("Desk partition", "데스크 파티션"),
        .axClipLight: p("Clip light, %T", "클립 조명, %T"),
        .on: p("On", "켜짐"),
        .off: p("Off", "꺼짐"),
        // The Memos window.
        .memosTitle: p("Memos", "메모"),
        .tabCalendar: p("Calendar", "캘린더"),
        .tabNotes: p("Sticky Notes", "메모지"),
        .today: p("Today", "오늘"),
        .dayPlaceholder: p("Write a memo for this day", "이 날의 메모를 적어 보세요"),
        .notesForDay: p("Notes for This Day", "이날의 메모지"),
        .newNoteForDay: p("New Note for This Day", "이날 메모지 추가"),
        .setAsDDay: p("Set as D-Day…", "이 날을 디데이로…"),
        .dDayTitle: p("D-Day title", "디데이 이름"),
        .dateToggle: p("Date", "날짜"),
        .noNotes: p("No sticky notes yet.", "아직 메모지가 없어요."),
        .emptyNote: p("Empty note", "빈 메모지"),
        .partitionAway: p("The partition is put away.", "파티션을 넣어 뒀어요."),
        .noteGone: p("This note was taken off.", "이 메모지는 떼어졌어요."),
        .connectToSave: p("Connect the Desktop folder to save files.", "파일로 저장하려면 바탕화면 폴더를 연결하세요."),
    ]
}
