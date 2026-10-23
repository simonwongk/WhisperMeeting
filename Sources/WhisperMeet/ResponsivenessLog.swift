import Foundation
import os

/// How long the app takes to answer (F1088, F1089), logged so a slow press or a frozen launch is read from the Mac
/// it happened on rather than guessed at: a trigger event's age when its handler ran, each phase of a dictation
/// press and release, when the pill's frame was drawn, the launch's phases, and every stall of the main thread in
/// the minutes after a launch. Durations only — nothing a person said or typed.
enum ResponsivenessLog {
    static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.whispermeet.app", category: "responsiveness")

    /// Monotonic nanoseconds, the clock every timing here is taken on.
    static func now() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

    /// Milliseconds from `start` to `end`; 0 when `end` is not after it.
    static func milliseconds(since start: UInt64, to end: UInt64 = now()) -> Double {
        end > start ? Double(end - start) / 1e6 : 0
    }

    /// How old a Quartz event's time stamp is, in milliseconds, or nil when it says nothing usable. A stamp is in
    /// host ticks on Apple silicon and in nanoseconds elsewhere, and a synthesized event's is 0; the reading that
    /// gives an age under a minute is the one taken.
    static func eventAgeMilliseconds(_ stamp: UInt64, ticks: UInt64 = mach_absolute_time(), nanoseconds: UInt64 = now()) -> Double? {
        guard stamp > 0 else { return nil }
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        if ticks >= stamp, timebase.denom > 0 {
            let age = Double(ticks - stamp) * Double(timebase.numer) / Double(timebase.denom) / 1e6
            if age < 60_000 { return age }
        }
        if nanoseconds >= stamp {
            let age = Double(nanoseconds - stamp) / 1e6
            if age < 60_000 { return age }
        }
        return nil
    }

    /// Runs `body` once the main run loop next goes to sleep — after Core Animation has committed this turn's
    /// drawing — so a log can say when what was just shown reached the screen.
    @MainActor
    static func afterThisTurnDraws(_ body: @escaping @MainActor () -> Void) {
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, false, CFIndex.max) { _, _ in
            MainActor.assumeIsolated { body() }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }

    /// When `WhisperMeetLauncher.main` began, for the launch's timings.
    nonisolated(unsafe) static var launchBegan: UInt64 = 0

    /// How old the process already was when `main` began — dyld and the system's checks of the bundle — in
    /// milliseconds, from the kernel's start time; nil when it cannot be read.
    static func processAgeAtLaunchMilliseconds() -> Double? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&name, 4, &info, &size, nil, 0) == 0 else { return nil }
        let started = info.kp_proc.p_un.__p_starttime
        let startedAt = Double(started.tv_sec) + Double(started.tv_usec) / 1e6
        let wallNow = Date().timeIntervalSince1970
        let sinceMain = milliseconds(since: launchBegan) / 1e3
        let age = (wallNow - startedAt - sinceMain) * 1e3
        return age.isFinite && age >= 0 && age < 600_000 ? age : nil
    }

    /// The milestones `launchMilestoneOnce` has logged, so a view that appears again does not log again.
    @MainActor private static var loggedOnce: Set<String> = []

    /// `launchMilestone`, the first time only.
    @MainActor
    static func launchMilestoneOnce(_ name: String) {
        guard loggedOnce.insert(name).inserted else { return }
        launchMilestone(name)
    }

    /// Logs the launch's milestone `name`, with the time since `main` began.
    static func launchMilestone(_ name: String) {
        guard launchBegan > 0 else { return }
        log.notice("launch timing: \(name, privacy: .public) \(milliseconds(since: launchBegan), format: .fixed(precision: 0)) ms after main")
    }

    /// Watches the main thread for `seconds` after a launch, from a background queue: every 50 ms, unless a ping is
    /// still waiting, it asks the main queue to answer, and logs each answer that took longer than `threshold`
    /// seconds, with when the stall began after `main`. At the end, a line with the count and the longest.
    static func watchMainThread(for seconds: Double = 180, threshold: Double = 0.25) {
        let state = OSAllocatedUnfairLock(initialState: (waiting: false, stalls: 0, longest: 0.0, longestAt: 0.0))
        let queue = DispatchQueue(label: "com.whispermeet.responsiveness", qos: .utility)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let began = now()
        timer.schedule(deadline: .now() + 0.05, repeating: 0.05, leeway: .milliseconds(10))
        timer.setEventHandler {
            if milliseconds(since: began) / 1e3 > seconds {
                timer.cancel()
                timer.setEventHandler {}   // the handler held the timer; let both go
                let summary = state.withLock { $0 }
                log.notice("launch timing: main thread over the first \(Int(seconds)) s — \(summary.stalls) stalls over \(Int(threshold * 1000)) ms, the longest \(summary.longest, format: .fixed(precision: 0)) ms at \(summary.longestAt, format: .fixed(precision: 1)) s")
                return
            }
            let sent = now()
            let alreadyWaiting = state.withLock { current -> Bool in
                if current.waiting { return true }
                current.waiting = true
                return false
            }
            guard !alreadyWaiting else { return }
            DispatchQueue.main.async {
                let waited = milliseconds(since: sent)
                let at = launchBegan > 0 ? milliseconds(since: launchBegan, to: sent) / 1e3 : 0
                state.withLock { current in
                    current.waiting = false
                    if waited > threshold * 1000 {
                        current.stalls += 1
                        if waited > current.longest { current.longest = waited; current.longestAt = at }
                    }
                }
                if waited > threshold * 1000 {
                    log.notice("launch timing: main thread stalled \(waited, format: .fixed(precision: 0)) ms at \(at, format: .fixed(precision: 1)) s after main")
                }
            }
        }
        timer.resume()
    }
}
