import AppKit
import DeskCore
import DeskFiles
import DeskPixels
import UniformTypeIdentifiers

/// Reads one photo for the picture frame (Erratum 33), off the main thread as `IconProvider` renders icons. First the
/// development-mode guard (a path inside the real Desktop is refused by its spelling, before anything is looked up),
/// then resource values (a refusal never reads the contents: not a photo, an alias or link, too large, an iCloud
/// placeholder), then ImageIO's small oriented thumbnail, pixelated once (`FramePixelator`). Only the latest request is
/// delivered (a quick second pick wins). The file is only read: never moved, copied, written or kept.
final class FramePhotoLoader {
    /// What one read of a photo came to (Erratum 33): the frame's pixels, or the toast that says why not.
    nonisolated enum Outcome: Sendable, Equatable {
        case photo(FramePhoto)
        case refused(ToastKey)
    }

    /// The real Desktop, refused in every mode but desk (`SafetyGuard.Mode.requiresSandboxFolder`, §3.7 item 7); nil in
    /// desk mode. Tests pass a temporary folder.
    let realDesktop: URL?
    /// Loads under way (demo idle checks).
    private(set) var inFlight = 0
    /// No load is under way (each one is counted down in its own hop back to the main thread).
    var isIdle: Bool { inFlight == 0 }
    /// The ticket of the newest load: only its outcome is delivered.
    private var latest = 0

    /// A loader with `realDesktop`'s guard (nil: none, desk mode).
    init(realDesktop: URL?) {
        self.realDesktop = realDesktop
    }

    /// Reads `url` (with `inode`, a token's: the file must still be that one) and calls `done` on the main actor once,
    /// unless a newer load started since.
    func load(_ url: URL, inode: UInt64? = nil, done: @escaping @MainActor (Outcome) -> Void) {
        latest += 1
        let ticket = latest
        inFlight += 1
        let desk = realDesktop
        DispatchQueue.global(qos: .userInitiated).async {
            let o = Self.read(url, inode: inode, realDesktop: desk)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.inFlight -= 1
                    guard ticket == self.latest else { return }
                    done(o)
                }
            }
        }
    }

    /// `Self.refusal` with this loader's guard (the drop-in asks it on the main thread before it takes a drop).
    func refusal(_ url: URL) -> ToastKey? { Self.refusal(url, realDesktop: realDesktop) }

    /// Why `url` may not be hung, never from its contents, in this order: not a file URL → `.notAPhoto`; inside
    /// `realDesktop` (by spelling first, `DesktopLocator.isInsideDesktop`) → `.photoUnreadable`, before any resource
    /// value is read; then resource values: gone → `.photoUnreadable`; a folder or package, an alias or symbolic link,
    /// or not `.image` → `.notAPhoto`; larger than `maxBytes` → `.photoUnreadable`; an iCloud placeholder →
    /// `.photoInCloud`; nil when it may be read.
    nonisolated static func refusal(_ url: URL, realDesktop: URL?,
                                    maxBytes: Int = ImageThumbnail.maxSourceBytes) -> ToastKey? {
        guard url.isFileURL else { return .notAPhoto }
        // The development-mode guard first, by the path's spelling (`isInsideDesktop` answers a path inside without
        // touching the file system): nothing of the real Desktop's files is looked up. `Log` is the main actor's.
        if let realDesktop, DesktopLocator.isInsideDesktop(url, desktop: realDesktop) {
            let line = "Deskterior: picture frame: refusing a photo inside the real Desktop in this mode\n"
            FileHandle.standardError.write(Data(line.utf8))
            return .photoUnreadable
        }
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .isPackageKey, .isAliasFileKey, .isSymbolicLinkKey, .contentTypeKey, .fileSizeKey,
        ]
        guard let v = try? url.resourceValues(forKeys: keys) else { return .photoUnreadable }
        if v.isDirectory == true || v.isPackage == true || v.isAliasFile == true || v.isSymbolicLink == true {
            return .notAPhoto
        }
        guard v.contentType?.conforms(to: .image) ?? false else { return .notAPhoto }
        // ImageIO maps what it reads (§2.1): a file this large is refused by its size, unread.
        if (v.fileSize ?? 0) > maxBytes { return .photoUnreadable }
        return DesktopScanner.isDataless(url) ? .photoInCloud : nil
    }

    /// `refusal`, the inode check, then `FramePixelator.photo(contentsOf:)` (nil → `.photoUnreadable`).
    nonisolated static func read(_ url: URL, inode: UInt64?, realDesktop: URL?) -> Outcome {
        if let r = refusal(url, realDesktop: realDesktop) { return .refused(r) }
        if let inode {
            // A token's file must still be the one the token showed (a safe-save or a rename since swaps the inode).
            var st = stat()
            guard lstat(url.path, &st) == 0, UInt64(st.st_ino) == inode else { return .refused(.photoUnreadable) }
        }
        return FramePixelator.photo(contentsOf: url).map(Outcome.photo) ?? .refused(.photoUnreadable)
    }
}
