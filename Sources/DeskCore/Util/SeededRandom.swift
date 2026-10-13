/// SplitMix64 (Steele, Lea & Flood 2014): a tiny, fast, fully deterministic 64-bit generator.
///
/// All randomness in Deskterior is seeded through this type so simulations, goldens and demos replay
/// bit-identically. The helpers below use fixed algorithms (not the standard library's `random(in:)`,
/// whose internals may change between toolchains), so a seed always yields the same values.
public struct SplitMix64: RandomNumberGenerator, Hashable, Sendable {
    /// The golden-ratio increment added to the state on every step.
    public static let gamma: UInt64 = 0x9E37_79B9_7F4A_7C15

    /// Current internal state; equal states produce equal futures.
    public private(set) var state: UInt64

    public init(seed: UInt64) {
        state = seed
    }

    public mutating func next() -> UInt64 {
        state &+= Self.gamma
        return Self.mix(state)
    }

    /// The SplitMix64 output finalizer: a stateless, well-distributed 64-bit hash. Handy for
    /// coordinate-keyed noise (hash a packed `(x, y, seed)`) where no generator state should be kept.
    @inlinable
    public static func mix(_ value: UInt64) -> UInt64 {
        var z = value
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in `[0, 1)` with 24 random bits (every value is exactly representable).
    public mutating func nextFloat01() -> Float {
        Float(next() >> 40) * 0x1p-24
    }

    /// Uniform in `[0, 1)` with 53 random bits.
    public mutating func nextDouble01() -> Double {
        Double(next() >> 11) * 0x1p-53
    }

    /// Unbiased integer in `0..<bound` (Lemire's multiply-shift with rejection). `bound` must be > 0.
    public mutating func nextInt(below bound: Int) -> Int {
        precondition(bound > 0, "SplitMix64.nextInt(below:) needs a positive bound, got \(bound)")
        let b = UInt64(bound)
        var m = next().multipliedFullWidth(by: b)
        if m.low < b {
            let threshold = (0 &- b) % b
            while m.low < threshold { m = next().multipliedFullWidth(by: b) }
        }
        return Int(m.high)
    }

    /// Unbiased integer in `range` (both bounds inclusive).
    public mutating func nextInt(in range: ClosedRange<Int>) -> Int {
        let span = range.upperBound.subtractingReportingOverflow(range.lowerBound)
        precondition(!span.overflow && span.partialValue < Int.max, "SplitMix64.nextInt(in:) range too wide")
        return range.lowerBound + nextInt(below: span.partialValue + 1)
    }

    /// `true` with the given probability (`<= 0` never, `>= 1` always).
    public mutating func nextBool(probability p: Double = 0.5) -> Bool {
        nextDouble01() < p
    }
}
