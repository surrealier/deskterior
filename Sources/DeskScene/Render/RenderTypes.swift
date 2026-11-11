import DeskCore

/// Room light applied by the lit pass wherever the light mask is dimmer (DESIGN §1.4).
public nonisolated struct AmbientLight: Hashable, Sendable {
    /// 0…7; 7 is the identity.
    public var level: Int
    public var tint: Tint

    public init(level: Int, tint: Tint) {
        self.level = min(max(level, 0), LightRamp.maxLevel)
        self.tint = tint
    }

    /// Full light: the lit pass changes nothing.
    public static let identity = AmbientLight(level: LightRamp.maxLevel, tint: .cool)
}

/// How the upscale pass maps device pixels to lit-frame texels:
/// `texel = floor((device + crop) / scale) − shake`, clamped to the frame.
public nonisolated struct UpscaleParams: Hashable, Sendable {
    /// `S`: device px per art px.
    public var scale: Int
    public var cropLeft: Int
    public var cropTop: Int
    /// Screen-shake offset in art px.
    public var shake: ArtPoint

    public init(scale: Int, cropLeft: Int, cropTop: Int, shake: ArtPoint = .zero) {
        self.scale = max(1, scale)
        self.cropLeft = cropLeft
        self.cropTop = cropTop
        self.shake = shake
    }

    public init(grid: PixelGrid, shake: ArtPoint = .zero) {
        self.init(scale: grid.scale, cropLeft: grid.cropLeft, cropTop: grid.cropTop, shake: shake)
    }
}

public enum RenderError: Error, CustomStringConvertible {
    case noDevice
    case resource(String)

    public var description: String {
        switch self {
        case .noDevice: "no Metal device"
        case .resource(let what): "could not create \(what)"
        }
    }
}
