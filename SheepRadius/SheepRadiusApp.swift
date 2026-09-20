import SwiftUI

@main
struct SheepRadiusApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1180, height: 760)
        .commands {
            // Single-window app: AppModel.shared is process-global state (same as SheepDrop/SheepTerm).
            CommandGroup(replacing: .newItem) {
                Button("Start All Servers") { Task { await AppModel.shared.startAll() } }
                    .keyboardShortcut("r", modifiers: .command)
                // **⌘⇧. , not ⌘.** (build 25, QA M-3). A SwiftUI sheet is window-modal and a
                // sheet with no `.cancelAction` in it passes ⌘. through to here — so a ⌘.
                // meant to dismiss the password, error or import sheet stopped both servers
                // behind it, silently. Every sheet binds the cancel key now (`sheetCancel`),
                // and the destructive command has moved out of its way besides: a shortcut
                // that takes a lab down should not be one keystroke from a dismissal.
                Button("Stop All Servers") { Task { await AppModel.shared.stopAll() } }
                    .keyboardShortcut(".", modifiers: [.command, .shift])
                Button("Apply Changes") { Task { await AppModel.shared.apply() } }
                    .keyboardShortcut("s", modifiers: .command)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Held for the process's lifetime — a released source stops delivering.
    private var signalSources: [any DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Dev hook for light/dark screenshots without flipping the system.
        //
        // **It reports what it did** (build 25, QA L-0). The hook has existed since build 21
        // and printed nothing, so a capture script had no way to tell "dark was applied" from
        // "the flag was misspelt and the shot is light" — and a pair of light/dark screenshots
        // that are secretly the same picture is exactly the check this exists for. An
        // unrecognised value is said out loud rather than ignored.
        if let raw = CommandLine.value(after: "-demoAppearance") {
            setvbuf(stdout, nil, _IONBF, 0)
            switch raw.lowercased() {
            case "dark":
                NSApp.appearance = NSAppearance(named: .darkAqua)
                print("[appearance] dark")
            case "light":
                NSApp.appearance = NSAppearance(named: .aqua)
                print("[appearance] light")
            default:
                print("[appearance] IGNORED \(raw) — expected dark or light")
            }
        }
        installSignalHandlers()
        applyDemoWindowSize()
        captureDemoShot()
    }

    /// `-demoShot <path.png>` — write this window to a PNG and quit.
    ///
    /// The app draws its own window rather than asking the system to photograph the screen.
    /// `screencapture` and `CGWindowListCreateImage` both need Screen Recording permission,
    /// which an automated session does not have, and both would also have to tell this dev
    /// instance apart from the copy in /Applications — which is the one thing a screenshot
    /// tool must never get wrong here. `cacheDisplay` can only ever draw *this* process's own
    /// view tree, so it cannot photograph the owner's window by accident.
    ///
    /// The delay is for the panes that fill themselves in asynchronously (`describeCertificate`
    /// shells out to openssl, the directory snapshot is a subprocess), and `-demoWindow` itself
    /// resizes on the next runloop turn.
    private func captureDemoShot() {
        guard let path = CommandLine.value(after: "-demoShot") else { return }
        let seconds = CommandLine.value(after: "-demoShotDelay").flatMap(Double.init) ?? 2.5
        // An app launched from a shell cannot activate itself on macOS 14+, and a window that
        // is not key draws every prominent button, switch and selection in its inactive grey.
        // `ContentView` forces `controlActiveState` instead — see `Chrome.isCapturing`.
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            // **A sheet is what is being looked at** (build 25). `-demoSheet` opens one so it
            // can be captured at all; without this the shot would be the window behind it,
            // which is exactly the thing the sheet is covering.
            let hosting = NSApp.windows.first { $0.isVisible && $0.attachedSheet != nil }
            guard let window = hosting?.attachedSheet ?? NSApp.windows.first(where: { $0.isVisible }),
                  let view = window.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                print("[shot] no window")
                exit(1)
            }
            view.cacheDisplay(in: view.bounds, to: rep)
            guard let data = rep.representation(using: .png, properties: [:]) else {
                print("[shot] no png")
                exit(1)
            }
            do {
                try data.write(to: URL(fileURLWithPath: path))
                print("[shot] \(Int(view.bounds.width))x\(Int(view.bounds.height)) \(path)")
            } catch {
                print("[shot] \(error.localizedDescription)")
                exit(1)
            }
            AppModel.shared.emergencyShutdown()
            exit(0)
        }
    }

    /// `-demoWindow 980x760` — put the window at a repeatable size and known origin.
    ///
    /// Layout bugs are width bugs: the Users list looks one way at the 980 pt minimum and
    /// another on a full-screen window, and "drag it wider and look" is not a repeatable check.
    /// The origin is fixed too, so a screenshot tool can tell this window from the copy in
    /// /Applications without guessing.
    ///
    /// **Clamped to the screen, except when capturing** (build 21). A requested size larger
    /// than the display used to be clamped unconditionally — asking for 1900×900 on a scaled
    /// laptop pushed the right and bottom edges off-screen and made the "wide" visual check
    /// useless. But `-demoShot` does not photograph the screen: it asks the content view to
    /// draw itself, which works at any size the window will take, on or off the display. The
    /// owner asked for 1800×900 and 2360×1400 shots of the centred column on a 1470 pt
    /// desktop, and clamping is exactly what would have made those two the same picture. So a
    /// capture run asks for the size it was given and reports what it actually got — the
    /// `[shot]` line carries the view's real bounds, and AppKit may still constrain a titled
    /// window to the screen's height.
    private func applyDemoWindowSize() {
        guard let raw = CommandLine.value(after: "-demoWindow") else { return }
        let parts = raw.lowercased().split(separator: "x").compactMap { Double($0) }
        guard parts.count == 2, parts[0] >= 200, parts[1] >= 200 else { return }
        let capturing = Chrome.isCapturing
        DispatchQueue.main.async {
            guard let window = NSApp.windows.first(where: { $0.isVisible }) else { return }
            let visible = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
            let margin: CGFloat = 20
            let available = visible?.insetBy(dx: margin, dy: margin)
            let bound = capturing ? nil : available
            let width = min(CGFloat(parts[0]), bound?.width ?? CGFloat(parts[0]))
            let height = min(CGFloat(parts[1]), bound?.height ?? CGFloat(parts[1]))
            let origin = available.map { NSPoint(x: $0.minX, y: $0.minY) }
                ?? NSPoint(x: 40, y: 60)
            // A titled window is constrained to the screen by `setFrame`; setting the content
            // size is not, which is what lets a 2360 pt capture exist on a 1470 pt desktop.
            if capturing {
                window.setContentSize(NSSize(width: width, height: height))
                window.setFrameOrigin(origin)
            } else {
                window.setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)),
                                display: true)
            }
            // **Say when the size asked for is not the size given** (build 25, QA L-0). A
            // non-capturing run is clamped to the visible frame, and AppKit constrains a
            // titled window's height besides — so "-demoWindow 1180x760 looks wrong" was
            // indistinguishable from "this display is 900 pt tall and the window was cut".
            // Printed on every `-demoWindow` run, so a script can assert on it.
            let got = window.contentView?.bounds.size ?? window.frame.size
            setvbuf(stdout, nil, _IONBF, 0)
            let clamped = abs(got.width - CGFloat(parts[0])) > 1 || abs(got.height - CGFloat(parts[1])) > 1
            print("[window] asked \(Int(parts[0]))x\(Int(parts[1])) got \(Int(got.width))x\(Int(got.height))"
                  + (clamped ? " CLAMPED to the screen" : ""))
        }
    }

    /// `applicationWillTerminate` is not called for a signal, so a `kill` (or Xcode's stop
    /// button) used to leave radiusd and slapd holding their ports. The supervisor's
    /// lifeline covers even SIGKILL, but these make an ordinary SIGTERM clean and prompt.
    ///
    /// `signal(sig, SIG_IGN)` first: a DispatchSource signal handler is delivered *in
    /// addition* to the default disposition, so without it the process still dies instantly
    /// on the default action and the handler never runs.
    private func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler {
                AppModel.shared.emergencyShutdown()
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Cheap (a handful of stats), so a `brew install` the user ran in their own Terminal is
    /// picked up when they switch back — no relaunch needed.
    func applicationDidBecomeActive(_ notification: Notification) {
        AppModel.shared.refreshToolchain()
    }

    /// The servers are children of this app on purpose: quitting the app must leave nothing listening.
    func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared.shutdownForQuit()
    }
}
