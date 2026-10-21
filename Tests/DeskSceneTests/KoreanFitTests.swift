import DeskCore
import DeskPixels
import Foundation
import Testing
@testable import DeskScene

/// Galmuri9's Hangul is 10 px a syllable against 6 px for most Latin letters, so the Korean text the scene draws
/// (toasts, progress lines, the monitor cards and their buttons) is checked for fit in Korean as well as English
/// (Errata 26). `DESKTERIOR_REVIEW_DIR` also writes every Korean toast and card for review.
@Suite("Korean text fit")
struct KoreanFitTests {
    func font() throws -> PixelFont {
        try #require(PixelFont.galmuri9, "Galmuri9.ttf not found")
    }

    /// The smallest canvas the grid makes: a visible band exactly 512 art px wide.
    static let smallest = LayoutSolver.solve(display: DisplayGeometry(widthPt: 1024, heightPt: 690, backingScale: 1,
                                                                      topInsetPt: 25))

    /// Every line a toast can show: the keys' texts and the copy progress lines (up to four-digit counts).
    static func toastLines(_ language: Language) -> [String] {
        let progress = [1, 9999].map { n in
            L10n.format(n == 1 ? .copyingOne : .copyingMany, [n], language)
        }
        return ToastKey.allCases.map { $0.text(language) } + progress
    }

    @Test("Every toast's tab fits the toast band (clock to calendar) in Korean and English", arguments: Language.allCases)
    func toastsFitTheBand(language: Language) throws {
        let font = try font()
        let band = ToastView.band
        #expect(band.count == 232)
        for line in Self.toastLines(language) {
            let tab = ToastView.image(line, font: font)
            #expect(tab.width <= band.count, "\(language) toast \(tab.width) px wide: \(line)")
            #expect(tab.height == ToastView.image("Aa", font: font).height, "one line: \(line)")
        }
    }

    // MARK: tidy and memos (0.3.0)
    @Test("The new toasts (Put Away, the partition, Save as Text File) speak Korean and fit the band")
    func newToasts() throws {
        let font = try font()
        let keys: [ToastKey] = [.putAwayPlace, .tookFilesOut, .drawersPutAway, .madeRoom, .partitionFull, .memoClipsFull,
                                .noteRemoved, .savedTextFile, .undidSaveTextFile, .savedNoUndo, .memosNotSaved]
        for key in keys {
            #expect(L10n.knows(key.english), "\(key) is in the table")
            #expect(key.text(.ko) != key.english, "\(key) has its Korean")
            for language in Language.allCases {
                #expect(ToastView.image(key.text(language), font: font).width <= ToastView.band.count, "\(language) \(key)")
            }
        }
    }

    // MARK: picture frame (0.4.0)
    @Test("The picture frame's toasts are the table's English, speak Korean and fit the band (Erratum 33)")
    func frameToasts() throws {
        let font = try font()
        let keys: [(ToastKey, L10nKey)] = [
            (.notAPhoto, .toastNotAPhoto), (.onePhotoAtATime, .toastOnePhotoAtATime), (.photoInCloud, .toastPhotoInCloud),
            (.photoUnreadable, .toastPhotoUnreadable), (.frameNotSaved, .toastFrameNotSaved),
        ]
        for (key, entry) in keys {
            #expect(L10n.knows(key.english), "\(key) is in the table")
            #expect(key.english == entry.en, "\(key) is \(entry)'s English")
            #expect(key.text(.ko) == entry.ko && key.text(.ko) != key.english, "\(key) has its Korean")
            for language in Language.allCases {
                #expect(ToastView.image(key.text(language), font: font).width <= ToastView.band.count, "\(language) \(key)")
            }
        }
    }

    @Test("The toast band lies inside the visible band of the smallest canvas")
    func bandOnTheSmallestCanvas() {
        let layout = Self.smallest
        #expect(layout.visible.w == PixelGrid.coreSize.w, "smallest visible band: \(layout.visible)")
        let left = layout.x(ToastView.band.lowerBound), right = layout.x(ToastView.band.upperBound)
        #expect(left >= layout.visible.minX && right <= layout.visible.maxX)
    }

    @Test("Every monitor card in Korean fits the glass, panel and buttons inside it", arguments: [
        ScreenOverlay.connectPrompt, .connecting, .noAccess, .desktopHidden,
    ])
    func cardsFit(overlay: ScreenOverlay) throws {
        let font = try font()
        let wallpaper = MonitorArt.deskOSWallpaper(sky: .day)
        for language in Language.allCases {
            let card = try #require(ScreenCard.render(overlay, wallpaper: wallpaper, font: font, language: language))
            let glass = ArtRect(origin: .zero, size: CoreLayout.screen.size)
            #expect(card.image.size == glass.size)
            for (name, r) in card.buttons {
                #expect(glass.insetBy(2, 2).contains(r), "\(language) \(overlay) \(name) at \(r)")
            }
            // Text and panels keep a 4-px margin from the bezel: the outer columns and rows stay the wallpaper's.
            let base = overlay == .noAccess ? nil : wallpaper
            if let base {
                let dimmed = ScreenCard.dimmed(base, steps: overlay == .connecting ? 1 : 2)
                for y in 0..<glass.h {
                    for x in 0..<glass.w where x < 4 || x >= glass.w - 4 || y < 2 || y >= glass.h - 2 {
                        if overlay == .connectPrompt, x >= glass.w - 14, y >= glass.h - 13 { continue }  // the arrow
                        #expect(card.image[x, y] == dimmed[x, y], "\(language) \(overlay) reaches (\(x), \(y))")
                    }
                }
            }
        }
    }

    @Test("Peek Desk's “× Done” button text fits its pill in Korean")
    func peekDone() throws {
        let font = try font()
        let en = PixelText.width(L10n.text(.peekDone, .en), font: font)
        let ko = PixelText.width(L10n.text(.peekDone, .ko), font: font)
        #expect(ko <= en)
    }

    /// Review sheet (only with `DESKTERIOR_REVIEW_DIR`): every Korean toast, then the four cards, ×3.
    @Test("Review: Korean toasts and cards", .enabled(if: !(ProcessInfo.processInfo.environment["DESKTERIOR_REVIEW_DIR"] ?? "").isEmpty))
    func review() throws {
        let font = try font()
        let dir = ProcessInfo.processInfo.environment["DESKTERIOR_REVIEW_DIR"]!
        let tabs = Self.toastLines(.ko).map { ToastView.image($0, font: font) }
        let wallpaper = MonitorArt.deskOSWallpaper(sky: .night)
        let cards = [ScreenOverlay.connectPrompt, .connecting, .noAccess, .desktopHidden].compactMap {
            ScreenCard.render($0, wallpaper: wallpaper, font: font, language: .ko)?.image
        }
        let band = ToastView.band.count
        let width = max(band + 8, 2 * (CoreLayout.screen.w + 4) + 4)
        let tabH = tabs.map(\.height).max() ?? 0
        let height = 4 + tabs.count * (tabH + 2) + 2 * (CoreLayout.screen.h + 4) + 4
        var sheet = PixelCanvas(width: width, height: height, fill: Role.wallDay)
        var y = 4
        for tab in tabs {
            // The band as a faint rule behind each tab, the tab centred on it.
            sheet.hline(x: 4, y: y + tabH / 2, length: band, .neutral7)
            sheet.blit(tab, at: ArtPoint(4 + (band - tab.width) / 2, y))
            y += tabH + 2
        }
        for (i, card) in cards.enumerated() {
            sheet.blit(card, at: ArtPoint(4 + (i % 2) * (CoreLayout.screen.w + 4), y + (i / 2) * (CoreLayout.screen.h + 4)))
        }
        let url = URL(fileURLWithPath: dir).appendingPathComponent("korean-fit.png")
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: dir), withIntermediateDirectories: true)
        try PNGCodec.encode(sheet.buffer.scaledNearest(3)).write(to: url)
    }
}
