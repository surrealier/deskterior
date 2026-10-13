/// The hand-composed 512×320 core scene (DESIGN §1.3), in **core** art px (y-down, origin at the core's
/// top-left). `SceneLayout` moves these into canvas coordinates.
public enum CoreLayout {
    public static let size = PixelGrid.coreSize

    // MARK: Horizontal lines

    /// Where furniture stands (front floor line).
    public static let floorY = PixelGrid.coreFloorY
    /// The desk's back edge, where the desk top meets the wall (desk depth 128).
    public static let deskBackY = 168
    /// The desk's front edge (desk depth 0); the apron hangs below it.
    public static let deskFrontY = 232
    /// Where the back wall meets the floor: the floor point 128 px of depth behind the front floor line.
    public static let wallBaseY = 248

    // MARK: Wall

    public static let window = ArtRect(16, 12, 84, 96)
    public static let roomSwitch = ArtRect(108, 84, 8, 12)
    public static let clock = ArtRect(120, 20, 28, 28)
    public static let calendar = ArtRect(392, 24, 32, 36)

    // MARK: Monitor

    public static let monitorBody = ArtRect(160, 12, 208, 132)
    public static let bezel = 6
    public static let screen = ArtRect(166, 18, 196, 108)
    public static let chin = ArtRect(160, 126, 208, 18)
    /// Top-left of the 9×5 token grid on the screen.
    public static let screenGridOrigin = ArtPoint(174, 22)
    public static let screenCell = 20
    public static let screenColumns = 9
    public static let screenRows = 5
    public static let input = ArtRect(172, 130, 20, 10)
    /// The page-dot strip (up to 8 dots, 4-px pitch, starting at core (196, 133)).
    public static let pageDots = ArtRect(196, 133, 32, 4)
    public static let pageDotPitch = 4
    public static let led = ArtRect(336, 134, 2, 2)
    public static let power = ArtRect(344, 130, 12, 10)
    /// The power button's generous hit rect.
    public static let powerHit = ArtRect(340, 128, 20, 14)
    public static let neck = ArtRect(254, 144, 20, 10)

    /// Screen cell `(col, row)` (20×20, token art centred inside).
    public static func screenCellRect(col: Int, row: Int) -> ArtRect {
        ArtRect(screenGridOrigin.x + col * screenCell, screenGridOrigin.y + row * screenCell, screenCell, screenCell)
    }

    // MARK: Riser

    public static let riser = ArtRect(184, 154, 160, 22)
    public static let riserDrawerL = ArtRect(190, 160, 56, 12)
    public static let riserCubby = ArtRect(250, 160, 28, 12)
    public static let riserDrawerR = ArtRect(282, 160, 56, 12)
    public static let riserTravel = 10

    // MARK: Desk-back props

    public static let lampBase = ArtRect(112, 160, 28, 8)
    public static let lampSwitch = ArtRect(118, 158, 6, 3)
    public static let lampHead = ArtRect(136, 100, 24, 16)
    public static let plant = ArtRect(36, 136, 24, 34)
    public static let penCup = ArtRect(360, 150, 14, 22)
    public static let phone = ArtRect(384, 144, 16, 28)
    public static let driveHub = ArtRect(408, 162, 24, 8)

    // MARK: Desk

    public static let deskTop = ArtRect(12, 168, 488, 64)
    /// The mat's default footprint on screen (plane x 154–358, d 8–92).
    public static let matDefault = ArtRect(154, 186, 204, 42)
    /// Keyboard sprite (plane x 206–302, d 40–64; top face rows 200–211, front face 212–213).
    public static let keyboard = ArtRect(206, 200, 96, 14)
    /// Brush at rest (plane x 430–454 around d 60).
    public static let brush = ArtRect(430, 196, 24, 10)
    public static let apron = ArtRect(12, 232, 488, 12)
    public static let legLeft = ArtRect(18, 244, 8, 68)
    public static let legRight = ArtRect(486, 244, 8, 68)

    // MARK: Under the desk

    public static let chair = ArtRect(200, 236, 64, 76)
    /// The chair rolls with its left edge in this range.
    public static let chairTravel = 64...440
    public static let cabinet = ArtRect(392, 248, 80, 64)
    /// Drawer front heights top → bottom (top, middle, file), then the 6-px plinth.
    public static let cabinetFrontHeights = [16, 18, 24]
    public static let cabinetPlinth = 6
    public static let cabinetTravels = [12, 14, 18]
    public static let wastebasket = ArtRect(48, 272, 32, 40)
    public static let wastebasketMouth = ArtRect(48, 272, 32, 6)

    /// Cabinet drawer front `i` (0 top, 1 middle, 2 file) in core px.
    public static func cabinetFront(_ i: Int) -> ArtRect {
        precondition(cabinetFrontHeights.indices.contains(i), "cabinet drawer index out of range: \(i)")
        let y = cabinet.y + cabinetFrontHeights.prefix(i).reduce(0, +)
        return ArtRect(cabinet.x, y, cabinet.w, cabinetFrontHeights[i])
    }

    /// Lamp light (core px): a pool on the desk under the shade, spilling a little up the wall behind it.
    public static let lampConeTop = (x0: 132, x1: 220, y: 160)
    public static let lampConeBottom = (x0: 108, x1: 286, y: 236)

    /// Monitor glow on the keyboard and mat (core px): screen-wide under the chin, wider on the desk.
    public static let monitorGlowTop = (x0: 176, x1: 352, y: 176)
    public static let monitorGlowBottom = (x0: 150, x1: 378, y: 232)
}
