import DeskCore

/// Where carried tokens go when released (DESIGN §2.1): the first element, front to back in hit-test order, with
/// a verdict at the release point wins. Affordances answer first (open drawer, cup mouth, face-up phone, basket
/// mouth, the screen while on — or a bonk: screen off, phone face-down, a full container, drives). The mat, the
/// desk top and ballistic throws join as elements in M7/M9. No verdict means spring back.
public enum DropResolver {
    public nonisolated struct Resolution: Equatable, Sendable {
        public var verdict: DropVerdict
        /// The element that answered.
        public var element: String
    }

    /// The verdict for `tokens` released at `p`, asking `elements` in order (front to back).
    public static func resolve(_ tokens: [TokenKey], at p: ArtPoint, elements: [any DeskElement]) -> Resolution? {
        guard !tokens.isEmpty else { return nil }
        for e in elements {
            if let v = e.dropVerdict(tokens, at: p) { return Resolution(verdict: v, element: e.id) }
        }
        return nil
    }
}
