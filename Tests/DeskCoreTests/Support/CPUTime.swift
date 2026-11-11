import Foundation
#if os(Windows)
import WinSDK
#endif

extension TestSupport {
    /// Seconds of CPU the calling thread spends in `body`. Unlike a clock on the wall, it leaves out the time a busy
    /// runner keeps the thread waiting for a core (the whole suite runs in parallel), so a bound on it is about the
    /// code. `body` is synchronous, so it stays on this thread.
    static func cpuSeconds(_ body: () throws -> Void) rethrows -> Double {
        let start = threadCPUNanoseconds()
        try body()
        return Double(threadCPUNanoseconds() - start) / 1e9
    }

    /// CPU time of the calling thread in nanoseconds (user + system on Windows).
    static func threadCPUNanoseconds() -> UInt64 {
        #if canImport(Darwin)
        return clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        #elseif os(Windows)
        var creation = FILETIME(), exit = FILETIME(), kernel = FILETIME(), user = FILETIME()
        guard GetThreadTimes(GetCurrentThread(), &creation, &exit, &kernel, &user) else { return 0 }
        func ticks(_ t: FILETIME) -> UInt64 { UInt64(t.dwHighDateTime) << 32 | UInt64(t.dwLowDateTime) }
        return (ticks(kernel) + ticks(user)) * 100
        #else
        var ts = timespec()
        clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts)
        return UInt64(ts.tv_sec) * 1_000_000_000 + UInt64(ts.tv_nsec)
        #endif
    }
}
