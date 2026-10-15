import Darwin

/// What Meowse needs to know about the process a scroll goes to, looked up
/// (`proc_pidpath`, safe on any thread, no allocation) only when the target
/// process changes:
/// - whether it's the Dock process, which draws the Dock, Launchpad and
///   Mission Control: system UI that pages or switches instead of scrolling
///   a document, so it gets the wheel unsmoothed;
/// - whether it's inside an app the user excluded, which gets the wheel as is.
struct TargetCache {
    private var pid: pid_t = -1
    private var dock = false
    private var excluded = false
    /// Bundle paths ending in "/", as C strings.
    private var excludedPaths: [[CChar]] = []

    mutating func setExcluded(_ paths: [String]) {
        excludedPaths = paths.map { Array($0.utf8CString) }
        pid = -1
    }

    mutating func isDock(_ target: pid_t) -> Bool {
        lookUp(target)
        return dock
    }

    mutating func isExcluded(_ target: pid_t) -> Bool {
        lookUp(target)
        return excluded
    }

    private mutating func lookUp(_ target: pid_t) {
        guard target != pid else { return }
        pid = target
        dock = false
        excluded = false
        guard target > 0 else { return }
        let size = Int(4 * MAXPATHLEN)  // PROC_PIDPATHINFO_MAXSIZE
        withUnsafeTemporaryAllocation(of: CChar.self, capacity: size) { buf in
            guard let base = buf.baseAddress, proc_pidpath(target, base, UInt32(size)) > 0 else { return }
            dock = strcmp(base, "/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock") == 0
            // The app itself and anything inside it, such as its helpers.
            for prefix in excludedPaths where strncmp(base, prefix, prefix.count - 1) == 0 {
                excluded = true
                break
            }
        }
    }
}
