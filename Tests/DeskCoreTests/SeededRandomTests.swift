import Testing
@testable import DeskCore

@Suite struct SeededRandomTests {
    @Test func knownOutputsForSeedZero() {
        // Reference SplitMix64 (Vigna's splitmix64.c) from state 0.
        var rng = SplitMix64(seed: 0)
        #expect(rng.next() == 0xE220_A839_7B1D_CDAF)
        #expect(rng.next() == 0x6E78_9E6A_A1B9_65F4)
        #expect(rng.next() == 0x06C4_5D18_8009_454F)
        #expect(rng.next() == 0xF88B_B8A8_724C_81EC)
        #expect(rng.state == 4 &* SplitMix64.gamma)
    }

    @Test func knownOutputsForSeed42() {
        var rng = SplitMix64(seed: 42)
        #expect(rng.next() == 0xBDD7_3226_2FEB_6E95)
        #expect(rng.next() == 0x28EF_E333_B266_F103)
    }

    @Test func mixIsTheOutputFinalizer() {
        #expect(SplitMix64.mix(SplitMix64.gamma) == 0xE220_A839_7B1D_CDAF)
        #expect(SplitMix64.mix(0) == 0)
    }

    @Test func sameSeedSameSequence() {
        var a = SplitMix64(seed: 0xDE5C), b = SplitMix64(seed: 0xDE5C)
        for _ in 0..<1000 { #expect(a.next() == b.next()) }
        #expect(a == b)
        var c = SplitMix64(seed: 0xDE5D)
        a = SplitMix64(seed: 0xDE5C)
        #expect((0..<8).map { _ in a.next() } != (0..<8).map { _ in c.next() })
    }

    @Test func derivedValuesAreDeterministic() {
        func sample(_ seed: UInt64) -> [Double] {
            var r = SplitMix64(seed: seed)
            return [Double(r.nextFloat01()), r.nextDouble01(), Double(r.nextInt(below: 7)), Double(r.nextInt(in: -3...3)),
                    r.nextBool() ? 1 : 0]
        }
        #expect(sample(9) == sample(9))
        var r = SplitMix64(seed: 0)
        // First output 0xE220A839... → top 24 bits 0xE220A8.
        #expect(r.nextFloat01() == Float(0xE2_20A8) / 16_777_216)
    }

    @Test func unitIntervalsStayInRange() {
        var r = SplitMix64(seed: 1)
        for _ in 0..<5000 {
            let f = r.nextFloat01()
            #expect(f >= 0 && f < 1)
            let d = r.nextDouble01()
            #expect(d >= 0 && d < 1)
        }
    }

    @Test func integersAreInRangeAndCoverIt() {
        var r = SplitMix64(seed: 7)
        var seen = Set<Int>()
        for _ in 0..<2000 {
            let v = r.nextInt(below: 10)
            #expect((0..<10).contains(v))
            seen.insert(v)
            let w = r.nextInt(in: -2...2)
            #expect((-2...2).contains(w))
        }
        #expect(seen == Set(0..<10))
        #expect(r.nextInt(below: 1) == 0)
        #expect(r.nextInt(in: 5...5) == 5)
    }

    @Test func boolProbabilityExtremes() {
        var r = SplitMix64(seed: 3)
        for _ in 0..<200 {
            let never = r.nextBool(probability: 0), always = r.nextBool(probability: 1)
            #expect(!never)
            #expect(always)
        }
    }

    @Test func worksAsAStandardLibraryGenerator() {
        var a = SplitMix64(seed: 11), b = SplitMix64(seed: 11)
        let xs = (0..<20).map { _ in Int.random(in: 0..<100, using: &a) }
        let ys = (0..<20).map { _ in Int.random(in: 0..<100, using: &b) }
        #expect(xs == ys)
        #expect(xs.allSatisfy { (0..<100).contains($0) })
    }
}
