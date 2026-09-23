import Combine
import Foundation
import Synchronization

struct LogLine: Identifiable, Sendable {
    /// What the line is, for the Log pane's colouring.
    ///
    /// **Deliberately computed, not stored.** The first attempt in build 12 classified every
    /// line as it arrived, which looked like the cheaper place — and made the app *five times*
    /// slower per request, because `String.contains` is a grapheme-aware search and it was now
    /// running four times over every one of the ~375,000 lines a five-thousand-request flood
    /// produces. The Log pane's `LazyVStack` only ever builds the rows that are on screen, so
    /// asking there costs ~40 rows × 4 searches per redraw and nothing at all when the pane is
    /// closed. Measured both ways; see HANDOFF.
    enum Kind: Sendable { case plain, accept, reject, note, request, quiet }

    let id: Int
    let text: String
    /// When the app received it (build 32). radiusd at `-x` prints no clock at all, so this is
    /// the only time a RADIUS line has; one `Date` per drained batch, not per line.
    var time: Date? = nil

    var kind: Kind {
        if text.hasPrefix("——") { return .note }
        // Build 32: the start of a request, and the chatter between requests. Checked before
        // the verdicts so a header is never taken for one ("Sent Access-Reject" is a verdict).
        if text.contains("Received Access-Request") || text.contains("Received Accounting-Request")
            || text.contains(" ACCEPT from IP=") { return .request }
        if LogPresentation.isQuiet(text) { return .quiet }
        if text.contains("Login OK") || text.contains("Access-Accept") { return .accept }
        // The domain controller's own verdicts, same rule as radiusd's: `NT_STATUS_OK` and
        // nothing else is a success. The OK test must come first — every failure constant also
        // begins `NT_STATUS_`.
        if text.contains("NT_STATUS_OK") { return .accept }
        if text.contains("NT_STATUS_") { return .reject }
        if text.contains("Login incorrect") || text.contains("Access-Reject")
            || text.contains("Error") || text.contains("unknown client")
            || text.contains("Dropping packet without response")
            || text.contains(" RESULT tag=97 err=") && !text.contains(" RESULT tag=97 err=0 ") { return .reject }
        if text.contains(" RESULT tag=97 err=0 ") { return .accept }
        return .plain
    }
}

/// One supervised child process (radiusd or slapd) with its merged stdout/stderr streamed into `log`.
final class ServerProcess: ObservableObject {
    enum State: Equatable {
        case stopped, running
        case failed(String)
    }

    let title: String
    @Published private(set) var state = State.stopped
    @Published private(set) var pid: Int32?
    /// **Published at most `publishesPerSecond` times a second, never once per line.**
    ///
    /// `@Published` sends `objectWillChange` on *every* mutation, so appending each line
    /// individually made one radiusd request at `-xx` (410 lines) invalidate every view that
    /// observes this object 410 times. Measured in build 12: a 1000-request PAP flood pushed
    /// the app's resident size up by ~42 MB of transient SwiftUI allocation per flood, whether
    /// or not the Log pane was even on screen — the sidebar's `ServerRow` observes this object
    /// too. `drainTask` collects whole lines from `ServerLineBuffer` and appends them in one go.
    @Published private(set) var log: [LogLine] = []
    var onLines: (([String]) -> Void)?
    /// Called with the exit status once the process has finished and its output drained.
    var onExit: ((Int32) -> Void)?

    /// 10 Hz. Faster buys nothing a person can read; slower makes the Log pane feel broken.
    static let publishesPerSecond = 10
    /// Whole lines, filled by the reader queue and emptied by `drainTask`.
    private var lineBuffer: ServerLineBuffer?
    private var drainTask: Task<Void, Never>?

    private var process: Process?
    /// Held open for the child's whole life — closing it is what tells the wrapper to kill
    /// the server, and the kernel closes it for us if the app dies without running any code.
    private var lifeline: Pipe?
    /// The read end of the output pipe, kept so a forced stop can take the readability handler
    /// off it. Without this the dispatch source stays armed on a descriptor nobody closes.
    private var readHandle: FileHandle?
    private var stopping = false
    private var nextLineID = 0
    private let maxLines = 4000

    init(title: String) { self.title = title }

    var isRunning: Bool { state == .running }

    /// `fdLimit`: Apple's slapd sizes its descriptor table from RLIMIT_NOFILE — 545 MB RSS at the
    /// default limit vs ~10 MB at 256 — so it is launched through `sh -c 'ulimit -n …; exec …'`.
    /// The wrapper every server is launched through.
    ///
    /// It exists for one reason: **a server must not outlive the app, however the app dies.**
    /// `applicationWillTerminate` covers a normal Quit and nothing else — not SIGKILL, not a
    /// crash — and an orphaned radiusd keeps udp/1812 and an orphaned slapd keeps tcp/389,
    /// so the next launch cannot start.
    ///
    /// The app hands the wrapper a pipe as stdin and keeps the only write end. When the app
    /// goes away the kernel closes that end for us, the `read` below hits EOF, and the
    /// wrapper kills the server. No extra binary to ship and nothing to codesign — which is
    /// why this rather than a compiled helper or a kqueue NOTE_EXIT watcher.
    ///
    /// It also writes the *server's* pid (not this shell's) where `AppModel` can find it
    /// again after an unclean exit, forwards SIGTERM, keeps the `ulimit -n` wrapper, and
    /// exits with the server's own status.
    static func supervisor(fdLimit: Int?) -> String {
        (fdLimit.map { "ulimit -n \($0)\n" } ?? "") + """
        exec 3<&0
        "$0" "$@" </dev/null &
        srv=$!
        [ -n "$SHEEP_PIDFILE" ] && printf '%s\\n' "$srv" > "$SHEEP_PIDFILE"
        trap 'kill -TERM "$srv" 2>/dev/null' TERM INT HUP
        # fd 3, not stdin: a background job in a non-interactive shell gets /dev/null.
        ( while read -r _ <&3; do :; done; kill -TERM "$srv" 2>/dev/null ) &
        guard=$!
        wait "$srv"; status=$?
        kill -0 "$srv" 2>/dev/null && { wait "$srv"; status=$?; }
        kill "$guard" 2>/dev/null
        [ -n "$SHEEP_PIDFILE" ] && rm -f "$SHEEP_PIDFILE"
        exit "$status"
        """
    }

    func start(executable: String, arguments: [String], fdLimit: Int? = nil,
               environment: [String: String]? = nil, pidFile: URL? = nil) {
        guard process == nil else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", Self.supervisor(fdLimit: fdLimit), executable] + arguments
        var childEnvironment = environment ?? [:]
        childEnvironment["SHEEP_PIDFILE"] = pidFile?.path ?? ""
        p.environment = Shell.childEnvironment(adding: childEnvironment)
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe

        // The lifeline. FD_CLOEXEC on the write end matters: without it the *other* server's
        // wrapper would inherit this one's write end and hold it open after the app died.
        let lifeline = Pipe()
        _ = fcntl(lifeline.fileHandleForWriting.fileDescriptor, F_SETFD, FD_CLOEXEC)
        p.standardInput = lifeline.fileHandleForReading
        self.lifeline = lifeline

        // **Nothing on the main actor is in the child's way.** `readabilityHandler` runs on a
        // dispatch queue, and radiusd writes one line at a time, so the handler fires once per
        // line: hopping to the main actor there made the app the RADIUS server's pacemaker.
        // Measured in build 12 — the app answered 852 requests/s where the same radiusd piped
        // into `cat` answered 9082, because every line cost a queue hop, a main-actor hop and
        // a SwiftUI invalidation, and radiusd blocks on a full pipe in between. Splitting into
        // lines happens here, off the main actor; `drain` picks whole lines up ten times a
        // second. See HANDOFF.
        let buffer = ServerLineBuffer()
        lineBuffer = buffer
        readHandle = pipe.fileHandleForReading
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                buffer.finish()
            } else {
                buffer.ingest(data)
            }
        }
        drainTask?.cancel()
        drainTask = Task { [weak self] in
            // **`try?` swallows `CancellationError`, so the sleep cannot end this loop.** A
            // cancelled task whose buffer never reached EOF — which is exactly the task a
            // forced stop leaves behind — would otherwise spin the main actor at 100 % for
            // the rest of the app's life, because this body is created on the main actor and
            // therefore runs on it. `ADController`'s follower already checks; this did not.
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(1000 / Self.publishesPerSecond))
                if Task.isCancelled { return }
                guard let self else { return }
                let lines = buffer.drain()
                if !lines.isEmpty { self.append(lines) }
                if lines.isEmpty, buffer.isFinished { break }
            }
            guard !Task.isCancelled, let self else { return }
            self.didExit(p)
        }

        append(["—— start \(title): \((executable as NSString).lastPathComponent) \(arguments.joined(separator: " "))"])
        do {
            try p.run()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            readHandle = nil
            drainTask?.cancel()
            drainTask = nil
            buffer.finish()
            lineBuffer = nil
            self.lifeline = nil
            state = .failed(error.localizedDescription)
            return
        }
        process = p
        pid = p.processIdentifier
        stopping = false
        state = .running
    }

    /// SIGTERM, then SIGKILL after 3 s. `process` is cleared by `didExit`, which only runs
    /// once the output pipe reaches EOF — a child that leaked the write end to a grandchild
    /// would otherwise wedge this (and therefore Apply) forever, so give up after 5 s more
    /// and force the state. The process is dead by then either way; only the reader is stuck.
    func stop() async {
        guard let p = process else { return }
        stopping = true
        p.terminate()
        for _ in 0..<30 where p.isRunning { try? await Task.sleep(for: .milliseconds(100)) }
        if p.isRunning { kill(p.processIdentifier, SIGKILL) }
        for _ in 0..<100 where process != nil { try? await Task.sleep(for: .milliseconds(50)) }
        // `process === p`, not `process != nil`: by the time this is reached the reader may
        // already have reported the exit *and* a later `start()` may have installed a new
        // process. Forcing the state then would tear down a server that is running.
        if process === p {
            append(["—— \(title): exit was not reported within 5s, forcing stopped"])
            forceRelease(code: -1)
        }
    }

    /// Everything `didExit` would have done, for the case where the reader never reached EOF.
    ///
    /// Without this the readability handler stays armed on a descriptor nobody closes, the
    /// drain task keeps running against a buffer that never finishes, and `onExit` — which is
    /// how the installer and the image build learn they are over — is never called at all.
    private func forceRelease(code: Int32) {
        readHandle?.readabilityHandler = nil
        readHandle = nil
        drainTask?.cancel()
        drainTask = nil
        lineBuffer?.finish()
        lineBuffer = nil
        process = nil
        pid = nil
        lifeline = nil
        state = .stopped
        onExit?(code)
    }

    /// Synchronous best-effort shutdown for app termination.
    func terminateNow() {
        stopping = true
        process?.terminate()
    }

    func clearLog() { log.removeAll() }

    /// Put a line in this server's log without a process being involved.
    func note(_ text: String) { append([text]) }

    /// The same, for a batch — one publish for the lot.
    func note(contentsOf lines: [String]) { append(lines) }

    /// **One publish per batch, not one per line.** `@Published` sends `objectWillChange` on
    /// every mutation, so appending lines individually invalidated every observing view once
    /// per line — including the sidebar's `ServerRow`, whether or not the Log pane was open.
    private func append(_ lines: [String]) {
        var next = log
        let now = Date()
        for text in lines {
            next.append(LogLine(id: nextLineID, text: text, time: now))
            nextLineID += 1
        }
        if next.count > maxLines { next.removeFirst(next.count - maxLines) }
        log = next
        onLines?(lines)
    }

    private func didExit(_ p: Process) {
        // **The process that ended may not be the one this object is supervising.** A forced
        // stop clears `process` while the old drain task is still alive, so a later `start()`
        // can install a new server before the old reader reaches EOF. Reporting the old exit
        // then would null out the *new* process (orphaning it, and releasing the lifeline
        // whose EOF makes the supervisor kill it) and overwrite `.running` with `.stopped`.
        // It also covers the launch-failure path, where `process` was never assigned at all
        // and `waitUntilExit()` on a task that never ran raises NSInvalidArgumentException.
        guard p === process else { return }
        p.waitUntilExit()
        let code = p.terminationStatus
        append(["—— \(title) exited (\(code))"])
        process = nil
        pid = nil
        lifeline = nil
        lineBuffer = nil
        drainTask = nil
        readHandle = nil
        onExit?(code)
        if stopping || code == 0 {
            state = .stopped
        } else {
            let hint = log.dropLast().last(where: { $0.text.localizedCaseInsensitiveContains("error") || $0.text.contains("Failed") })?.text
            state = .failed(hint ?? "exit code \(code)")
        }
    }
}

/// The pipe reader's side of a server's output: **whole lines, assembled off the main actor**.
///
/// `FileHandle.readabilityHandler` fires as soon as *any* byte is readable, and radiusd writes
/// its debug stream a line at a time, so the handler runs once per line. Everything it does is
/// therefore on the critical path of the server it is reading: measured in build 12, doing the
/// splitting and the `@Published` append on the main actor per chunk held radiusd to 852
/// requests/s against 9082 for the same binary piped into `cat`, because radiusd blocks writing
/// into a full pipe while the app queues behind SwiftUI. Here the handler only takes a lock and
/// appends; the main actor collects whole lines ten times a second.
nonisolated final class ServerLineBuffer: Sendable {
    private struct State {
        var partial = Data()
        var lines: [String] = []
        var finished = false
    }

    private let state = Mutex(State())

    func ingest(_ chunk: Data) {
        state.withLock { s in
            s.partial.append(chunk)
            // One `firstIndex(of:)` (memchr) per line over the *remaining* bytes, and exactly
            // one `removeSubrange` per chunk — not one per line, which is O(n²).
            var lineStart = s.partial.startIndex
            while lineStart < s.partial.endIndex,
                  let newline = s.partial[lineStart...].firstIndex(of: 0x0A) {
                s.lines.append(String(decoding: s.partial[lineStart..<newline], as: UTF8.self))
                lineStart = newline + 1
            }
            if lineStart > s.partial.startIndex {
                s.partial.removeSubrange(s.partial.startIndex..<lineStart)
            }
        }
    }

    /// Everything complete so far, leaving the buffer empty.
    func drain() -> [String] {
        state.withLock { s in
            guard !s.lines.isEmpty else { return [] }
            let out = s.lines
            s.lines.removeAll(keepingCapacity: true)
            return out
        }
    }

    func finish() { state.withLock { $0.finished = true } }

    var isFinished: Bool { state.withLock { $0.finished && $0.lines.isEmpty } }
}
