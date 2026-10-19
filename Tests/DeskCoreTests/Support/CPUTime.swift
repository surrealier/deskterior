import Foundation

extension TestSupport {
    /// Seconds of CPU the calling thread spends in `body`. Unlike a clock on the wall, it leaves out the time a busy
    /// runner keeps the thread waiting for a core (the whole suite runs in parallel), so a bound on it is about the
    /// code. `body` is synchronous, so it stays on this thread.
    static func cpuSeconds(_ body: () throws -> Void) rethrows -> Double {
        let start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        try body()
        return Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - start) / 1e9
    }
}
