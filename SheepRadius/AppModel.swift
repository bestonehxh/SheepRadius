import Combine
import Foundation

/// The thirteen sidebar rows of build 18, minus the two server switches: five groups, no
/// duplicated page. Certificates is **one** pane (CA + RADIUS leaf + directory leaf) where
/// build 17 had the same CA card under RADIUS and again under Directory.
enum MainPane: String, CaseIterable {
    // Overview
    case status, test, log
    // Directory
    case users, groups, ldapServer, devices
    // RADIUS
    case clients, policy, radiusServer
    // App
    case certificates, settings

    /// `-demoPane` accepts the current ids and the ones earlier builds used, so screenshot
    /// scripts and muscle memory keep working after each regroup. Build 18 merged the two
    /// certificate panes and renamed `deviceSettings`, so both old ids land here.
    static func named(_ raw: String) -> MainPane? {
        if let exact = MainPane(rawValue: raw) { return exact }
        // Case-insensitively too, so `-demoPane Policy` works.
        if let loose = MainPane.allCases.first(where: { $0.rawValue.caseInsensitiveCompare(raw) == .orderedSame }) {
            return loose
        }
        switch raw.lowercased() {
        case "certificate", "radiuscert", "ldapcert",
             "radiuscertificate", "ldapcertificate": return .certificates
        case "radius", "server": return .radiusServer
        case "ldap", "directory": return .ldapServer
        case "device", "devicesettings", "devicesetting": return .devices
        case "nas": return .clients
        default: return nil
        }
    }
}

/// Which server decided this. Both feeds land in one list on purpose: a Wi-Fi login that the
/// NAC forwards to the domain produces a RADIUS row *and* an AD row, and seeing them next to
/// each other is the whole diagnosis.
nonisolated enum AuthSource: Sendable, Equatable {
    case radius
    case activeDirectory

    /// The badge in Status ▸ Recent authentications. RADIUS rows are unbadged — they were the
    /// only kind until build 15 and the pane would be all badge otherwise.
    var tag: String? {
        switch self {
        case .radius: nil
        case .activeDirectory: "AD"
        }
    }
}

nonisolated struct AuthEvent: Identifiable {
    let id: Int
    var time: Date
    let accepted: Bool
    let username: String
    let client: String
    /// Whatever FreeRADIUS put after the verdict: reject reason, "via TLS tunnel", station MAC…
    /// For an AD row, how the credential arrived and, on a failure, why it was refused.
    let detail: String
    var source: AuthSource = .radius
    /// How many identical events in a row this one row stands for. iMaster re-binds every
    /// thirty seconds and winbind prints the same ntlm_auth verdict three times; without this
    /// the feed is nothing but those. See `AppModel.coalesces(_:into:)`.
    var repeats = 1
    /// The Policy ▸ Rules that matched this request, in the order they fired.
    var rules: [String] = []
    /// radiusd's own request number, `(12)`, which is what ties the rule lines to the verdict.
    var request: Int?
    /// True for the inner half of a PEAP / TTLS session — the one with the real identity.
    var viaTunnel = false
    /// The anonymous outer identity of a tunnelled session, folded in from the outer verdict
    /// so one login is one row. See `scanForAuth`.
    var outerIdentity: String?
}

/// Process-global state, same shape as SheepDrop/SheepTerm: one window, one model.
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published var mainPane = MainPane.status
    /// The user selected in the Users pane (and the group in Groups), **by name**.
    ///
    /// A name and not a UUID since build 17: the rows come from a directory snapshot now, and
    /// a directory has no opinion about UUIDs. The name is what survives a refresh, which is
    /// the property the selection actually needs.
    @Published var selectedUser: String?
    @Published var selectedGroup: String?
    @Published var isFullScreen = false

    /// The edited document. `applied` is what the running servers were generated from.
    @Published var doc: LabDocument
    @Published private(set) var applied: LabDocument
    @Published private(set) var busy = false
    @Published var lastError: String?
    /// The raw output `lastError` was distilled from — a `radiusd -CX` dump, usually. Shown
    /// behind a "Details" disclosure and never as the message, because a seventeen-line parser
    /// dump is not a sentence a person can act on.
    @Published var lastErrorDetail: String?
    /// Status ▸ Recent authentications, **published at most 10 times a second**.
    ///
    /// Measured in build 12 and the app's single worst hot spot: `StatusView.body` builds the
    /// two server cards, the addresses card and forty event rows, and costs about 6 ms. Every
    /// login used to publish this list, so a 1000-request flood asked for a thousand of those
    /// renders — 31 seconds of main-thread work for five seconds of traffic, and the pane went
    /// on catching up for 26 seconds after the flood had stopped. `eventStore` is the truth;
    /// this is the copy SwiftUI sees.
    @Published private(set) var events: [AuthEvent] = []
    /// The real event list. Everything inside the model reads this, so a caller that has just
    /// driven a request sees its result without waiting for the next publish.
    private var eventStore: [AuthEvent] = []
    private var eventFlushPending = false
    /// Set by anything that changes `eventStore`, cleared by the flush. A flag rather than
    /// comparing the two arrays: folding a tunnelled session's outer identity into the row
    /// that is already published changes a field without changing the count or the newest id.
    private var eventsDirty = false
    @Published private(set) var certRevision = 0
    /// Filled in asynchronously by `readLDAPVersions()` — empty until then.
    @Published private(set) var slapdVersion = ""
    @Published private(set) var ldapsearchVersion = ""
    @Published private(set) var opensslVersion = ""
    @Published private(set) var radiusVersion = ""

    /// Not constants: `brew install freeradius-server` can make FreeRADIUS appear while the
    /// app is running, and the whole point of that button is that no relaunch is needed.
    @Published private(set) var tools: Toolchain
    @Published private(set) var env: LabEnvironment
    let installer = ServerProcess(title: "Homebrew")
    let radius = ServerProcess(title: "RADIUS")
    let ldap = ServerProcess(title: "LDAP")
    /// The Samba AD DC. Present whether or not AD mode is selected, so the Directory pane can
    /// describe the prerequisites without anything being started.
    let ad: ADController
    private let labBase: URL
    private var nextEventID = 0
    /// Rule tags seen for a request whose verdict has not come through yet, keyed by radiusd's
    /// request number. post-auth runs *before* the `Login OK:` line, so this only ever buffers
    /// forwards by a few lines.
    private var pendingRules: [Int: [String]] = [:]
    /// The last TLS cipher suite our own radiusd reported, and when. eapol_test does not print
    /// one, so this is the only source — and only for a test aimed at This Mac.
    private var lastCipherSuite: (String, Date)?
    /// How many times the **rule block itself** has run since launch, across both virtual
    /// servers.
    ///
    /// Not the number of rules that matched — several can match one request, and the events
    /// list cannot answer it either, because a tunnelled session produces two verdicts that
    /// are deliberately folded into one row. This is the only unambiguous way to say that a
    /// PEAP login evaluates the rules exactly once: not zero, and not twice.
    private(set) var ruleEvaluationsSeen = 0
    /// Watches this Mac's primary IPv4 for as long as the app is open. A lab Mac changes
    /// network often; a DC advertising an address nobody can reach fails in a way that never
    /// mentions DNS, and a device pointed at the old address fails in a way that never
    /// mentions the Mac.
    private var addressWatch: AnyCancellable?
    private var addressMonitor = AddressMonitor(current: LocalNetwork.primaryIPv4())
    /// The outstanding "this Mac moved" notice for the Status pane, kept until dismissed.
    @Published private(set) var addressChange: AddressChange?

    /// Which feed the Log pane shows. The pane binds to this rather than holding its own
    /// `@State`, so starting a server can move it — see `LogSourcePolicy` for the rule and
    /// `noteLogMode`/`chooseLogSource` for the two ways it changes.
    @Published private(set) var logSource = LogSource.opening
    private var logPolicy = LogSourcePolicy(source: LogSource.opening)
    private var backendWatch: AnyCancellable?
    /// Levels `applied` up with `doc` for whichever server is down — see `adoptStoppedHalves`.
    private var docWatch: AnyCancellable?

    // MARK: The Directory module (build 17 — see DirectoryModel.swift)
    //
    // These are `var` rather than `private(set)` only because the whole directory half lives
    // in `DirectoryModel.swift`: `private(set)` is file-scoped in Swift, and splitting the
    // model was worth more than the compiler-enforced spelling of "nobody else writes this".
    // Nothing outside that extension does.

    /// What the Users, Groups and tree panes draw. Refreshed after every edit and every
    /// thirty seconds while a backend runs. **The backend is the original; this is a copy.**
    @Published var directory = DirectorySnapshot.empty
    /// Why the snapshot is empty, when it is — shown as a banner, not an alert: a directory
    /// that is not running is a state to describe, not an error to interrupt over.
    @Published var directoryError: String?
    @Published var directoryBusy = false
    /// The "saved · 0.3 s" (or the failure) beside the row that was last edited.
    @Published var directoryStatus: DirectoryStatus?
    /// The one outstanding undo, for a move or a delete.
    @Published var directoryUndo: DirectoryUndoStep?
    /// **The one offer an edit may leave behind** (build 25, QA M-2): "Staff/Old is empty now."
    /// with a **Delete this OU** beside it. Cleared by the next edit, exactly as the undo is,
    /// and never acted on by itself — the app does not delete a container a person made.
    @Published var directoryFollowUp: DirectoryFollowUp?
    /// The one-time "import the old table" sheet, when there is something to import.
    @Published var directoryImportProposal: DirectoryImportProposal?
    /// False for OpenLDAP, which has no "account disabled" flag.
    @Published var directoryCanDisable = true
    /// **Users and Groups start the directory by being opened** (build 22 — `DirectoryPaneStart`).
    /// True while that start is in flight, so the pane shows one line and a spinner and a
    /// second appearance cannot start it twice.
    @Published private(set) var directoryStarting = false
    /// Why that start failed, shown where the table would be with a Retry button beside it —
    /// **not** as a sheet. An automatic action that puts a modal in front of somebody who did
    /// not ask for it is worse than the empty state it replaced.
    @Published private(set) var directoryStartProblem: String?
    @Published private(set) var directoryStartDetail: String?
    /// While this is set, `report` writes to the pane instead of raising the error sheet.
    private var quietErrors = false
    /// One pane-driven start at a time, before `directoryStarting` has been raised by the
    /// start itself — two `onAppear`s in one tick would otherwise both get through.
    private var paneStartInFlight = false

    var directoryWatch: AnyCancellable?
    var directoryReload = DirectoryReloadCoalescer()
    /// The last `users` file this app generated from a directory snapshot.
    ///
    /// Kept so that a moment when the directory cannot be read does not become a moment when
    /// radiusd is handed an empty user list — see `canWriteAuthorizeFromDirectory`.
    var lastDirectoryAuthorize: String?

    // MARK: Moving the lab (build 17 — see LabTransfer.swift)

    /// What the export / import is doing right now, for the one line under the button. nil
    /// when nothing is in flight — which is also what disables the buttons.
    @Published var transferStatus: String?
    /// The last file written, so Settings can say where it went and reveal it.
    @Published var lastExport: LabBackup?
    /// The unpacked archive waiting for a decision, and what importing it would mean.
    @Published var importPreview: LabImportPreview?

    /// **Show the credentials the servers print** (build 20, audit N-4). Off, and deliberately
    /// **not** persisted: the Log pane is what somebody screenshots into a ticket, so the
    /// masked view has to be what the pane is in on every launch. It is one flag rather than
    /// one per pane because the Test pane's raw client output carries the same values, and a
    /// person who has asked to see a password has asked once.
    @Published var showPasswordsInLogs = false
    /// The raw evidence behind the sentence `importLab` returned — the two digests of a
    /// refused image, for instance. It belongs behind `ErrorSheet`'s Details, never in the
    /// message itself, and the import sheet passes it to `report` when it reports the failure.
    var transferDetail: String?

    private init() {
        let found = Toolchain.detect()
        let base = CommandLine.value(after: "-labDir").map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? LabEnvironment.defaultBase
        let environment = LabEnvironment(base: base, tools: found)
        tools = found
        labBase = base
        env = environment
        try? environment.prepareDirectories()
        let loaded = environment.loadDocument()
        // `-adTest 1` is what `./Tests/run.sh ad` launches with. It is one hook rather than
        // five because the important part is that it is impossible to point the suite at the
        // REAL domain by mistake: a throwaway container, a throwaway volume and a realm of its
        // own all come together, or none of them do.
        let isADTest = CommandLine.value(after: "-adTest") == "1"
        ad = ADController(tools: found, env: environment,
                          containerName: isADTest ? ADImage.throwawayContainerName : ADImage.containerName,
                          volumeName: isADTest ? ADImage.throwawayVolumeName : ADImage.volumeName)
        doc = loaded
        applied = loaded
        if isADTest {
            doc.settings.directoryBackend = .activeDirectory
            doc.settings.ad.realm = "test.sheep"
            doc.settings.ad.netbiosDomain = "TESTSHEEP"
            doc.settings.ad.administratorPassword = "Sheep-Test-2026!"
            applied = doc
        }
        // `-radiusDebug 1` is what `Tests/perf.sh` measures the two log levels with, and the
        // only way to open at `-xx` without clicking the Log pane's switch.
        if let raw = CommandLine.value(after: "-radiusDebug") {
            doc.settings.radiusDebug = raw == "1"
            applied.settings.radiusDebug = raw == "1"
        }
        // `-policyMatrix` counts rule evaluations from the `if (…) -> TRUE` lines, and those
        // exist only at `-xx`. It is a diagnostic hook, so it turns the level up for itself
        // rather than making `-xx` everyone's default again.
        if CommandLine.value(after: "-policyMatrix") == "1" {
            doc.settings.radiusDebug = true
            applied.settings.radiusDebug = true
        }
        if let backend = CommandLine.value(after: "-demoBackend").flatMap(Self.backend(named:)) {
            doc.settings.directoryBackend = backend
            applied.settings.directoryBackend = backend
        }
        radius.onLines = { [weak self] in self?.scanForAuth($0) }
        ad.onError = { [weak self] message in self?.report(message) }
        ad.onAuth = { [weak self] in self?.ingestADAuth($0) }
        // `-demoADEvents 1` replays the lines captured from the owner's domain controller on
        // 18 Sep 2026 through the real follower path, so Status ▸ Recent authentications can be
        // seen and screenshotted with no domain controller running at all. It writes nothing
        // and starts nothing: the lines go in at the same place `container logs -f` puts them.
        if CommandLine.value(after: "-demoADEvents") == "1" {
            ad.ingestFollowedLog(ADAuthAudit.demoLines.joined(separator: "\n") + "\n")
        }
        startWatchingAddress()
        watchDirectoryBackend()
        watchDocument()
        // `-demoAddressChange <old address>` pretends this Mac used to be on that address, so
        // the Status pane's change notice is reachable for a screenshot and for the live suite
        // without anybody unplugging a cable. It seeds the *previous* address and lets the
        // watcher notice the real one, so the card shows a genuine "to".
        if let previous = CommandLine.value(after: "-demoAddressChange"), !previous.isEmpty {
            addressMonitor = AddressMonitor(current: previous)
            observeAddress(LocalNetwork.primaryIPv4() ?? "127.0.0.1", at: Date())
        }
        if let pane = CommandLine.value(after: "-demoPane").flatMap(MainPane.named) {
            mainPane = pane
        }
        if let name = CommandLine.value(after: "-demoSelect") {
            selectedUser = name
            selectedGroup = name
        }
        Task { await self.readLDAPVersions() }
        Task {
            // Before anything can try to bind a port.
            await self.reapOrphansAtLaunch()
            await self.ad.refreshPrerequisites()
            if CommandLine.value(after: "-autoStart") == "1" { await self.startAll() }
            // After the servers, so the first snapshot is of a directory that is up.
            self.startWatchingDirectory()
            // `-directoryProbe 1` drives the Users / Groups / tree panes' own code path —
            // `directoryEdit`, the function every context menu calls — against whichever
            // backend is running, and prints one `[dir] …` line per step.
            if CommandLine.value(after: "-directoryProbe") == "1" {
                try? await Task.sleep(for: .seconds(2))
                await self.runDirectoryProbe()
            }
            // `-radiusStartProbe 1` drives the sidebar's RADIUS switch on a lab where LDAP is
            // off, which build 21 made a compound action. Launched WITHOUT `-autoStart`.
            if CommandLine.value(after: "-radiusStartProbe") == "1" {
                try? await Task.sleep(for: .seconds(1))
                await self.runRadiusStartProbe()
            }
            // `-directoryPaneProbe 1` drives build 22's two decisions: opening Users starts
            // the directory, and the LDAP switch is locked while RADIUS runs. Also without
            // `-autoStart`.
            if CommandLine.value(after: "-directoryPaneProbe") == "1" {
                try? await Task.sleep(for: .seconds(1))
                await self.runDirectoryPaneProbe()
            }
            // `-transferProbe <file>` exports the lab into that file, or imports it when the
            // file is already there — the two halves of "move this lab to another Mac".
            if let path = CommandLine.value(after: "-transferProbe") {
                try? await Task.sleep(for: .seconds(1))
                await self.runTransferProbe(path)
            }
            // `-clientProbe 1` drives the Test pane's EXTERNAL-target path against this Mac's
            // own servers and prints the verdicts, so the live suite can check the one code
            // path that would otherwise need a second machine.
            if CommandLine.value(after: "-clientProbe") == "1" {
                try? await Task.sleep(for: .seconds(2))
                await TestRunner.runProbe(tools: self.tools, env: self.env, settings: self.applied.settings)
            }
            // `-eapProbe 1` is the same idea for the half radclient cannot speak: PEAP, TTLS
            // and EAP-TLS, driven through eapol_test. It is the only thing that executes the
            // inner-tunnel rule path.
            if CommandLine.value(after: "-eapProbe") == "1" {
                try? await Task.sleep(for: .seconds(2))
                await TestRunner.runEAPProbe(
                    tools: self.tools, env: self.env, settings: self.applied.settings,
                    setTLSMaxVersion: { version in
                        self.doc.settings.tlsMaxVersion = version
                        await self.apply()
                        guard self.applied.settings.tlsMaxVersion == version, self.radius.isRunning else { return false }
                        // Apply restarts radiusd; give it the moment it needs to bind again.
                        try? await Task.sleep(for: .seconds(2))
                        return true
                    },
                    addUser: { name, password in
                        // The Users pane's own door, so the account the probe authenticates as
                        // is made exactly the way a person would make it.
                        guard await self.directoryEdit("Create \(name)", { provider in
                            try await provider.createUser(name, displayName: "", ou: "",
                                                          password: password)
                        }) else { return false }
                        // The password has to be remembered **before** `authorize` is written,
                        // or the account goes into the file as `NT-Password` from the
                        // directory's hash rather than as the cleartext PEAP-MSCHAPv2 needs.
                        self.rememberDirectoryPassword(password, for: name)
                        await self.refreshDirectory()
                        // The coalescer may already have flushed the write that `directoryEdit`
                        // asked for — before the password above was known. Write it again and
                        // HUP unconditionally, rather than relying on a request that is not
                        // outstanding any more.
                        self.scheduleAuthorizeReload()
                        await self.flushAuthorizeReload()
                        await self.hupRadius()
                        // radiusd re-reads the users file on the signal, not on delivery of it.
                        try? await Task.sleep(for: .seconds(3))
                        return true
                    })
            }
            // `-clientCertProbe <path>` — issue a client certificate for alice, then revoke
            // it when the suite asks, so EAP-TLS can be driven at the server either side of it.
            if let path = CommandLine.value(after: "-clientCertProbe") {
                try? await Task.sleep(for: .seconds(2))
                await self.runClientCertificateProbe(path)
            }
            // The rule engine's equivalence check — see runPolicyMatrix.
            if CommandLine.value(after: "-policyMatrix") == "1" {
                try? await Task.sleep(for: .seconds(2))
                await self.runPolicyMatrix()
            }
            // Concurrency and lifecycle: things a person does with a mouse that no shell
            // script can reach from outside.
            if let what = CommandLine.value(after: "-lifecycleProbe") {
                try? await Task.sleep(for: .seconds(1))
                await self.runLifecycleProbe(what)
            }
            // What a build-12 lab.json became, and that it still replies the same way.
            if CommandLine.value(after: "-migrateProbe") == "1" {
                try? await Task.sleep(for: .seconds(1))
                await self.runMigrationProbe()
            }
            // The regression hook for the build-11 bug where Apply could not succeed until
            // RADIUS had been started once.
            if CommandLine.value(after: "-applyProbe") == "1" {
                try? await Task.sleep(for: .seconds(1))
                await self.runApplyProbe()
            }
            // Build 26, QA M-20: the custom unlang block is parsed while nothing is running.
            if CommandLine.value(after: "-unlangProbe") == "1" {
                try? await Task.sleep(for: .seconds(1))
                await self.runUnlangProbe()
            }
            // Build 26, decision D: the one-time directory import, run twice.
            if CommandLine.value(after: "-importProbe") == "1" {
                try? await Task.sleep(for: .seconds(1))
                await self.runImportProbe()
            }
            // `Tests/perf.sh`'s hook for the timings a shell script cannot reach: the things
            // that happen inside the app when a button is pressed.
            if let what = CommandLine.value(after: "-perfProbe") {
                try? await Task.sleep(for: .seconds(1))
                await self.runPerfProbe(what)
            }
        }
    }

    /// `-lifecycleProbe <storm|portclash>` — what a person can do with a mouse in two seconds.
    ///
    /// `storm` presses Apply ten times as fast as the model will take it and then flips both
    /// servers on and off five times, which is the shape of every "I clicked it twice and now
    /// it says running but it isn't" report. `portclash` tries to start RADIUS onto a port
    /// somebody else is holding and prints the message the user would see — the claim being
    /// that it names the port *and* the owner rather than failing generically.
    func runLifecycleProbe(_ what: String) async {
        setvbuf(stdout, nil, _IONBF, 0)
        func say(_ text: String) { print("[life] \(text)") }

        // `-lifecycleProbe fdsoak` — 200 start/stop cycles, counting this process's own open
        // descriptors before and after.
        //
        // A server that is started and stopped two hundred times is the shape that makes a
        // leak visible, and every leak this file can have is a descriptor: a `Pipe` whose read
        // end still carries a readability handler, a `Process` never reaped, a lifeline never
        // released. Counting from the inside means no `lsof` and no permission to ask for —
        // `/dev/fd` is this process's own table.
        if what == "fdsoak" {
            func openDescriptors() -> Int {
                (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? -1
            }
            // **Two hundred cycles of the RADIUS switch, which from build 21 is a compound
            // action**: it brings the directory up with it and `stopAll` takes both down
            // again. Measured on this Mac, that is still about four minutes for the two
            // hundred, and it is the stronger test — every descriptor either server allocates
            // has two hundred chances to be left behind rather than one.
            await startRadius()
            await stopAll()
            let before = openDescriptors()
            say("fd-before \(before)")
            var failures = 0
            for index in 0..<200 {
                await startRadius()
                if !radius.isRunning { failures += 1; say("fdsoak start \(index) failed: \(lastError ?? "-")"); clearError() }
                if !directoryIsLive { failures += 1; say("fdsoak start \(index) did not bring the directory up") }
                await stopAll()
                if radius.isRunning { failures += 1; say("fdsoak stop \(index) did not stop") }
            }
            let after = openDescriptors()
            say("fd-after \(after)")
            say("fd-growth \(after - before)")
            say("fdsoak-failures \(failures)")
            // One more start, because the point is not only that nothing leaked but that the
            // server still works after two hundred cycles.
            await startRadius()
            say("fdsoak-final-running \(radius.isRunning ? "yes" : "no")")
            say("fdsoak-final-ldap \(directoryIsLive ? "yes" : "no")")
            await stopAll()
            say("done")
            return
        }

        if what == "portclash" {
            await startRadius()
            let message = (lastError ?? "").replacingOccurrences(of: "\n", with: " · ")
            clearError()
            say("portclash running=\(radius.isRunning ? "yes" : "no")")
            say("portclash message: \(message)")
            say("done")
            return
        }

        await startAll()
        say("started radius=\(radius.isRunning ? "yes" : "no") ldap=\(ldap.isRunning ? "yes" : "no")")

        // Ten Applies with no waiting in between. Each one edits the document first, so none
        // of them is a no-op that the model could shortcut.
        let start = Date()
        var failures: [String] = []
        for index in 0..<10 {
            doc.clients = [NASClient(name: "storm\(index)", address: "10.99.\(index).0/24", secret: "storm-secret-\(index)")]
            await apply()
            if let error = lastError { failures.append("\(index): \(error)"); clearError() }
        }
        say(String(format: "apply-storm elapsed=%.0fms failures=%d", Date().timeIntervalSince(start) * 1000, failures.count))
        for failure in failures { say("apply-storm-failure \(failure.replacingOccurrences(of: "\n", with: " · "))") }
        say("apply-storm applied-clients=\(applied.clients.map(\.name).joined(separator: ","))")
        say("apply-storm doc-equals-applied=\(hasUnappliedChanges ? "no" : "yes")")
        say("apply-storm radius=\(radius.isRunning ? "yes" : "no") ldap=\(ldap.isRunning ? "yes" : "no")")

        // …and the same ten *without waiting for each other*, which is what a double-click on
        // "Apply & Restart" really does. `apply()` is MainActor and every await inside it is a
        // suspension point, so these genuinely interleave — the question is whether stopping
        // and starting the servers ten times over can leave the model claiming a process that
        // is not there.
        let raceStart = Date()
        doc.clients = [NASClient(name: "race", address: "10.98.0.0/24", secret: "race-secret")]
        for _ in 0..<10 { Task { await self.apply() } }
        // Quiescence, properly: idle on five consecutive samples half a second apart, so the
        // gap between two steps of one Apply cannot be mistaken for the end of all ten.
        var idleRun = 0
        for _ in 0..<600 {
            try? await Task.sleep(for: .milliseconds(100))
            idleRun = lifecycleIsIdle ? idleRun + 1 : 0
            if idleRun >= 5 { break }
        }
        try? await Task.sleep(for: .seconds(1))
        if let error = lastError { say("apply-race-error \(error.replacingOccurrences(of: "\n", with: " · "))"); clearError() }
        say(String(format: "apply-race elapsed=%.0fms", Date().timeIntervalSince(raceStart) * 1000))
        say("apply-race applied-clients=\(applied.clients.map(\.name).joined(separator: ","))")
        say("apply-race doc-equals-applied=\(hasUnappliedChanges ? "no" : "yes")")
        say("apply-race radius=\(radius.isRunning ? "yes" : "no") ldap=\(ldap.isRunning ? "yes" : "no")")

        // Start/Stop spam. The state the UI shows has to be the state the process is in.
        for _ in 0..<5 {
            await startAll()
            await stopAll()
        }
        if let error = lastError { say("startstop-error \(error.replacingOccurrences(of: "\n", with: " · "))"); clearError() }
        say("startstop-spam radius=\(radius.isRunning ? "yes" : "no") ldap=\(ldap.isRunning ? "yes" : "no")")
        await startAll()
        say("startstop-restart radius=\(radius.isRunning ? "yes" : "no") ldap=\(ldap.isRunning ? "yes" : "no")")
        await stopAll()
        say("startstop-final radius=\(radius.isRunning ? "yes" : "no") ldap=\(ldap.isRunning ? "yes" : "no")")
        say("done")
    }

    /// **`-unlangProbe 1`** — the custom unlang block parsed with **nothing running**
    /// (build 26, QA M-20).
    ///
    /// The claim the probe makes is the one the unit suite cannot: that `radiusd -CX` really
    /// does run on a staged copy with no server up, that a good block comes back clean and a
    /// broken one comes back with the parser's own sentence, and that neither of them touched
    /// `raddb/` — the live configuration is not a scratchpad. Prints `[unlang] …` per step.
    func runUnlangProbe() async {
        setvbuf(stdout, nil, _IONBF, 0)
        func say(_ text: String) { print("[unlang] \(text)") }
        say("radiusd running: \(radius.isRunning)")
        say("radiusd present: \(tools.radiusd != nil)")

        let before = (try? String(contentsOf: env.raddb.appendingPathComponent("radiusd.conf"),
                                  encoding: .utf8)) ?? ""

        doc.customUnlang = ""
        await checkCustomUnlang()
        say("empty: \(customUnlangProblem == nil ? "ok" : "PROBLEM \(customUnlangProblem!.summary)")")

        doc.customUnlang = """
        if (&NAS-Port-Type == Ethernet) {
        \tupdate reply {
        \t\tFilter-Id := "wired"
        \t}
        }
        """
        await checkCustomUnlang()
        say("good: \(customUnlangProblem == nil ? "ok" : "PROBLEM \(customUnlangProblem!.summary)")")

        doc.customUnlang = "if (&NAS-Port-Type == Ethernet) { update reply { Filter-Id := \"wired\" }"
        await checkCustomUnlang()
        if let problem = customUnlangProblem {
            say("broken: refused — \(problem.summary.split(separator: "\n").first ?? "")")
        } else {
            say("broken: NOT REFUSED")
        }

        let after = (try? String(contentsOf: env.raddb.appendingPathComponent("radiusd.conf"),
                                 encoding: .utf8)) ?? ""
        say("raddb untouched: \(before == after)")
        say("check directory removed: \(!FileManager.default.fileExists(atPath: env.checkStage.path))")
        say("done")
    }

    /// **`-importProbe 1`** — the one-time directory import, run **twice**, on a directory put
    /// into exactly the shape the owner's screenshot was taken in (build 26, decision D).
    ///
    /// *"Imported with 1 problem(s): move OU SheepRadius/Staff already exists"* was two halves
    /// of one import fighting: `DirectoryImport.plan` lists the OUs `lab.json` names and the
    /// directory does not have — including `Staff` — and creates them, while
    /// `DirectoryMigration.moveUp` separately lifts `SheepRadius/Staff` **to** `Staff`. Both
    /// plans are taken before either runs, so the lift lands on the container the create made
    /// forty milliseconds earlier and the person is shown a failure for an import that worked.
    ///
    /// **The setup is the test.** A fresh OpenLDAP lab cannot reproduce it on its own: the
    /// database is seeded *from* `lab.json`, so everything the plan would create is already
    /// there and there is nothing to collide. So the probe puts the directory back into the
    /// pre-build-16 layout first — `OU=SheepRadius/Migrated` with the account in it and no
    /// top-level `Migrated` — which is the state every lab upgraded from build 16 was in, and
    /// then asks for the two halves by name. `moveUp` reads a snapshot and does not care which
    /// backend produced it, and `runDirectoryImport` is backend-agnostic too, so slapd proves
    /// this as well as a domain controller would.
    ///
    /// The second pass is the point: it must create nothing, lift nothing and print no failure
    /// line at all. Against build 25 the **first** pass fails on the collision and the second
    /// fails again on top of it.
    func runImportProbe() async {
        setvbuf(stdout, nil, _IONBF, 0)
        func say(_ text: String) { print("[import] \(text)") }

        // The pane's own door, so the port preflight and the duplicate-DC probe still apply.
        await startDirectoryFromPane()
        for _ in 0..<60 where !directoryIsLive {
            try? await Task.sleep(for: .milliseconds(500))
        }
        guard directoryIsLive else {
            say("directory did not come up: \(directoryStartProblem ?? "no reason given")")
            say("done")
            return
        }
        await refreshDirectory()

        let root = applied.settings.ad.managedRootRDN
        let seededOU = doc.ous.first ?? "Migrated"
        let moved = "\(root)/\(seededOU)"
        let account = doc.users.first?.username ?? ""
        let provider = makeDirectoryProvider()
        do {
            try await provider.createOU(moved)
            if !account.isEmpty { try await provider.moveUser(account, toOU: moved) }
            // …and the top-level one goes, which is what makes the create half of the plan
            // want it back while the lift half is already bringing the real one up.
            try await provider.deleteOU(seededOU)
        } catch {
            say("setup failed: \((error as? DirectoryError)?.message ?? error.localizedDescription)")
            say("done")
            return
        }
        await refreshDirectory()
        say("setup \(moved) holds \(account.isEmpty ? "no account" : account)"
            + ", top-level \(seededOU) removed")

        for pass in 1...2 {
            // The two halves by name, rather than through `offerDirectoryImportIfNeeded` —
            // which computes the migration only in AD mode, and the bug is not AD's.
            let report = DirectoryImport.plan(document: doc, into: directory,
                                              backend: doc.settings.directoryBackend)
            let migration = DirectoryMigration.moveUp(snapshot: directory, managedRootRDN: root)
            say("pass \(pass): plans \(report.createOUs.count) OU(s), "
                + "\(report.createGroups.count) group(s), "
                + "\(report.createUsers.count) user(s), "
                + "\(migration.moves.count) move(s)")
            doc.directoryImported = false
            await runDirectoryImport(DirectoryImportProposal(report: report, migration: migration,
                                                             backendLabel: directoryLabel))
            let status = directoryStatus
            say("pass \(pass): \(status?.text ?? "no status")")
            say("pass \(pass): failed \(status?.isError == true ? "YES" : "no")")
        }

        await refreshDirectory()
        let ous = directory.ous.map(\.path).sorted().joined(separator: ",")
        say("ous \(ous.isEmpty ? "-" : ous)")
        // Where the account ended up is the claim that matters: it came **up** out of
        // `OU=SheepRadius`, which is what the lift is for. The empty container it left behind
        // stays — this app does not delete a container a person made (M-2).
        let landed = directory.users.first { $0.username == account }?.ou ?? "-"
        say("account \(account.isEmpty ? "-" : account) in \(landed.isEmpty ? "(top level)" : landed)")
        say("users \(directory.users.count) groups \(directory.groups.count)")
        say("done")
    }

    /// `-applyProbe 1` — Apply on a lab where **no server has ever been started**.
    ///
    /// A user hit this in build 11 on a fresh install: delete a group's reply, press Apply, and
    /// the alert says radiusd will not accept the configuration and dumps seventeen lines of
    /// `-CX` output. The cause had nothing to do with the edit — `rlm_eap_tls` opens
    /// `certs/server.key` while the parse instantiates modules, and the certificates are only
    /// generated when RADIUS starts. It is the one state the live suite never reached, because
    /// every instance it launches uses `-autoStart 1`.
    func runApplyProbe() async {
        setvbuf(stdout, nil, _IONBF, 0)
        func say(_ text: String) { print("[apply] \(text)") }
        let fm = FileManager.default
        func names(in url: URL) -> String {
            let found = (try? fm.contentsOfDirectory(atPath: url.path))?.sorted() ?? []
            return found.isEmpty ? "-" : found.joined(separator: ",")
        }

        say("radius-running-before \(radius.isRunning ? "yes" : "no")")
        say("certs-before \(names(in: env.certs))")
        say("raddb-before \(names(in: env.raddb))")
        say("lab-json-before \(fm.fileExists(atPath: env.documentURL.path) ? "yes" : "no")")

        // The edit from the report: remove the reply a group's members were getting. In build
        // 12 that was a field on the group; it is the first rule now, and deleting it is the
        // same edit from the user's point of view. Any edit would do; this is the one.
        if !doc.rules.isEmpty { doc.rules.removeFirst() }
        await apply()
        if let error = lastError {
            say("apply failed: \(error.replacingOccurrences(of: "\n", with: " · "))")
            say("apply-detail \((lastErrorDetail ?? "-").replacingOccurrences(of: "\n", with: " · "))")
            clearError()
        } else {
            say("apply ok")
        }
        say("certs-after \(names(in: env.certs))")
        say("raddb-after \(names(in: env.raddb))")
        say("lab-json-after \(fm.fileExists(atPath: env.documentURL.path) ? "yes" : "no")")
        say("stage-left \(fm.fileExists(atPath: env.stage.path) ? "yes" : "no")")

        await startRadius()
        if let error = lastError {
            say("start failed: \(error.replacingOccurrences(of: "\n", with: " · "))")
            clearError()
        }
        say("radius-running-after-start \(radius.isRunning ? "yes" : "no")")
        say("done")
    }

    /// `-migrateProbe 1` — what a **build-12 lab.json** turned into, and what it replies with.
    ///
    /// The document has already been migrated by the time this runs: it happens while the file
    /// is being decoded, which is the only place the old `vlan` / `replyAttributes` keys are
    /// ever visible. So this reports what came out, applies it, and states whether the file
    /// that was written back still carries any of them. The live suite then fires real requests
    /// at the server that is now running and compares the replies with the ones build 12 sent.
    func runMigrationProbe() async {
        setvbuf(stdout, nil, _IONBF, 0)
        func say(_ text: String) { print("[migrate] \(text)") }

        let context = PolicyContext(doc)
        say("rules \(doc.rules.count)")
        for (index, rule) in doc.rules.enumerated() {
            say("rule \(index + 1) \(rule.displayName(index: index, context: context)) stop=\(rule.stopAfterMatch ? "yes" : "no") on=\(rule.enabled ? "yes" : "no")")
        }
        for user in doc.users {
            let reply = PolicyMigration.migratedReply(for: user, groups: doc.groups(of: user),
                                                      rules: doc.rules, context: context)
            say("reply \(user.username) vlan=\(reply.vlan.isEmpty ? "-" : reply.vlan) attrs=\(reply.lines.isEmpty ? "-" : reply.lines.joined(separator: "|"))")
        }
        await apply()
        if let error = lastError {
            say("apply-failed \(error.replacingOccurrences(of: "\n", with: " · "))")
            clearError()
        } else {
            say("apply ok")
        }
        // The old keys are read once. What Apply wrote back must not carry them on a user or a
        // group any more — a *rule* has a `vlan` of its own, which is why this looks at the two
        // lists rather than grepping the file.
        var legacyFound = false
        if let data = try? Data(contentsOf: env.documentURL),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for key in ["users", "groups"] {
                for row in root[key] as? [[String: Any]] ?? []
                where row["vlan"] != nil || row["replyAttributes"] != nil {
                    legacyFound = true
                }
            }
        }
        say("legacy-keys-on-users-or-groups \(legacyFound ? "yes" : "no")")
        say("saved-rules \(applied.rules.count)")
        say("done")
    }

    /// `-perfProbe <lifecycle|ad>` — one `[perf] <name> <milliseconds>` line per measurement.
    ///
    /// These are the numbers `Tests/perf.sh` cannot take from outside: Start All, Apply &
    /// Restart at two table sizes, the log ring's cap, and an AD sync. `setvbuf` for the same
    /// reason `-adTrace` needs it — stdout is fully buffered when it is not a terminal.
    func runPerfProbe(_ what: String) async {
        setvbuf(stdout, nil, _IONBF, 0)
        func say(_ name: String, _ seconds: Double) {
            print(String(format: "[perf] %@ %.0f", name, seconds * 1000))
        }
        func timed(_ name: String, _ work: () async -> Void) async {
            let start = Date()
            await work()
            say(name, Date().timeIntervalSince(start))
        }

        if what == "ad" {
            guard ad.isRunning else {
                print("[perf] ad-unavailable the domain controller is not running")
                print("[perf] done")
                return
            }
            for count in [10, 50] {
                doc.users = Self.perfUsers(count: count, groups: doc.groups)
                await timed("ad-sync-\(count)") {
                    await self.perform { try self.commit() }
                    await self.ad.sync(doc: self.applied, settings: self.applied.settings.ad)
                }
            }
            print("[perf] done")
            return
        }

        await timed("start-all-cold") { await self.startAll() }
        await timed("stop-all") { await self.stopAll() }
        await timed("start-all-warm") { await self.startAll() }
        for count in [10, 50] {
            doc.users = Self.perfUsers(count: count, groups: doc.groups)
            await timed("apply-\(count)") { await self.apply() }
        }
        // The ring is the only thing between a chatty server and an unbounded array. Push ten
        // times its size through it and report what is left.
        let start = Date()
        let lines = (0..<10_000).map { "—— perf filler line \($0)" }
        radius.note(contentsOf: lines)
        say("log-fill-10000", Date().timeIntervalSince(start))
        print("[perf] log-lines-after-10000 \(radius.log.count)")
        print("[perf] done")
    }

    /// `count` users spread over the sample groups and two OUs, so Apply has real work to do:
    /// an `authorize` line, an LDIF entry and an OU tree for each.
    nonisolated static func perfUsers(count: Int, groups: [LabGroup]) -> [LabUser] {
        (0..<count).map { index in
            LabUser(username: "perf\(index)", displayName: "Perf User \(index)",
                    password: "perf\(index)pass",
                    ou: index % 2 == 0 ? "Staff/IT" : "Staff/Sales",
                    groups: groups.isEmpty ? [] : [groups[index % groups.count].id])
        }
    }

    /// `-demoBackend ad` opens straight in AD Domain mode, so its panes can be screenshotted
    /// without editing the saved lab.
    nonisolated static func backend(named raw: String) -> DirectoryBackend? {
        switch raw.lowercased() {
        case "ad", "activedirectory", "domain": .activeDirectory
        case "openldap", "ldap", "internal": .openLDAP
        default: nil
        }
    }

    var hasUnappliedChanges: Bool { RadiusApplyGate.differs(doc: doc, from: applied) }

    /// The other half: a listener, a base DN or a domain setting the running directory was not
    /// generated from. What the Devices pane's "these are the applied settings" line is about —
    /// that pane's tables are the *directory's* form fields, so the RADIUS diff never answered
    /// its question.
    var hasUnappliedDirectoryChanges: Bool { DirectoryApplyGate.differs(doc: doc, from: applied) }

    /// **What the Revert/Apply bar is shown for** (build 22 — `ApplyBarGate` has the reasoning).
    ///
    /// A running server, and a difference in *that* server's half of the document. With
    /// nothing running the bar's own sentence — "the servers still use the previous
    /// configuration" — is not true of anything, and `adoptStoppedHalves` has already saved
    /// the edit for the next start.
    var showsApplyBar: Bool {
        ApplyBarGate.raised(doc: doc, applied: applied,
                            radiusRunning: radius.isRunning, directoryRunning: directoryIsLive)
    }

    /// **`applied` is "what a running server was generated from" — so a server that is not
    /// running has no claim on it** (build 22).
    ///
    /// Without this, taking the directory's settings out of the RADIUS gate would strand them:
    /// the person switches backend or changes the base DN, no bar appears (correctly — nothing
    /// is running), and `startLDAPLocked`, which reads `applied`, starts the *old* one. So each
    /// half is levelled up as soon as its own server is down, lab.json is written, and the next
    /// start is generated from what is on screen.
    ///
    /// Refused while the document is invalid: the bar is up for the problems themselves then,
    /// and writing a lab.json the app would refuse to load is not a saving.
    /// **Build 25 (QA M-18, M-27, M-28)** — two corrections, both from `ApplyScope`:
    ///
    /// * the guard is on the **blocking** problems, so a half-typed new client or rule no
    ///   longer stops every unrelated edit in the app from reaching `lab.json`; and what is
    ///   adopted is `committable`, i.e. the document without that draft row;
    /// * what is **written** is `next`, not `doc`. Writing `doc` put an edit belonging to a
    ///   *running* server on disk without it reaching `applied` — so it came back at the next
    ///   launch as though a server had been generated from it, and `revert()` could never undo
    ///   it. `next` is exactly "what the running servers use, plus the halves that have none".
    func adoptStoppedHalves() {
        let target = ApplyScope.committable(doc: doc, applied: applied)
        guard Validation.problems(in: target).isEmpty else { return }
        var next = applied
        if !radius.isRunning { RadiusApplyGate.adopt(from: target, into: &next) }
        if !directoryIsLive { DirectoryApplyGate.adopt(from: target, into: &next) }
        guard RadiusApplyGate.differs(doc: next, from: applied)
                || DirectoryApplyGate.differs(doc: next, from: applied) else { return }
        applied = next
        try? env.saveDocument(next)
    }

    // MARK: The custom unlang block, checked before it is saved (build 26, QA M-20)

    /// What `radiusd -CX` made of the custom unlang block, or nil while it is good.
    ///
    /// **Why this had to exist.** The block is written verbatim into `post-auth` in both
    /// virtual servers, and until this build the only thing that ever parsed it was Apply.
    /// With radiusd stopped there is no Apply — `ApplyBarGate` shows the bar only when that
    /// half's server is running, and `adoptStoppedHalves` simply writes the edit to
    /// `lab.json` — so a broken block was saved in silence and surfaced at the *next* start,
    /// with a message that still said "the server is still running the last one that worked"
    /// about a server that had never started. That is a sentence about a state that does not
    /// exist, attached to an edit made an hour earlier.
    ///
    /// So the same `radiusd -CX` runs on a staging copy while the person is typing, whether or
    /// not anything is running. It is a *check*, not a refusal: the text is still saved, and
    /// losing what somebody typed because it does not parse yet would be worse than either.
    @Published var customUnlangProblem: (summary: String, detail: String)?
    /// True while the check is in flight, for the one spinner beside the editor.
    @Published var customUnlangChecking = false

    /// The text the last check was run on, so a check is not repeated on an unchanged block —
    /// `-CX` instantiates every module and costs about 200 ms.
    private var lastCheckedUnlang: String?
    private var unlangCheckPending = false

    /// Debounced, like every other burst in this app: one parse per pause in the typing.
    func scheduleCustomUnlangCheck() {
        guard !unlangCheckPending else { return }
        unlangCheckPending = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(700))
            self.unlangCheckPending = false
            await self.checkCustomUnlang()
        }
    }

    /// Run it now — what the **Check** button presses, and what the debounce lands on.
    func checkCustomUnlang() async {
        let text = doc.customUnlang
        guard tools.radiusd != nil else { customUnlangProblem = nil; return }
        guard text != lastCheckedUnlang else { return }
        // An empty block is always good, and is the common case — do not spend a `-CX` on it.
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            lastCheckedUnlang = text
            customUnlangProblem = nil
            return
        }
        customUnlangChecking = true
        // **The whole document, not the block alone.** unlang is only meaningful inside the
        // virtual servers `ConfigGenerator` writes, and a block that references a rule's
        // attribute parses in one configuration and not in another.
        let candidate = ApplyScope.committable(doc: doc, applied: applied)
        let problem = await env.radiusConfigProblem(candidate, in: env.checkStage)
        customUnlangChecking = false
        // Discarded if the text moved on while `-CX` ran — the answer would be about a block
        // that is no longer on screen.
        guard doc.customUnlang == text else { return }
        lastCheckedUnlang = text
        customUnlangProblem = problem
    }

    /// One adoption per burst, so holding a key down in a text field is one write and not one
    /// per character. 400 ms is the figure `DirectoryReloadCoalescer` uses for the same reason.
    private var stoppedAdoptPending = false

    private func scheduleStoppedAdopt() {
        guard !stoppedAdoptPending else { return }
        stoppedAdoptPending = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            self.stoppedAdoptPending = false
            self.adoptStoppedHalves()
        }
    }
    /// What the `Sync now` button presses. Always writes a line — see `ADSyncGate`.
    ///
    /// The "there are unapplied changes to the users, groups or OUs" gate went in build 21:
    /// nothing edits those three any more (they are the read-only seed), so it could only ever
    /// have been false, and a gate that cannot close is a gate that misleads whoever reads it.
    func syncAD() async {
        await ad.sync(doc: applied, settings: applied.settings.ad)
    }

    /// Everything wrong with the document as it is on screen — what the bar lists and what a
    /// row draws beside itself.
    var problems: [String] { Validation.problems(in: doc) }

    /// **What actually stops Apply and stops a save** (build 25 — `ApplyScope`). A client or a
    /// rule the servers have never seen is a draft: its problems are shown, on its own row,
    /// and block nothing.
    var blockingProblems: [String] {
        ApplyScope.blocking(doc: doc, applied: applied).map(\.text)
    }

    /// Every problem with the row it came out of, for the pane that owns that row (QA M-19).
    var detailedProblems: [Validation.Problem] { Validation.detailed(in: doc) }

    func problems(at site: Validation.Site) -> [String] {
        detailedProblems.filter { $0.site == site }.map(\.text)
    }

    /// The problems of one rule, its conditions included.
    func ruleProblems(_ id: UUID) -> [String] {
        detailedProblems.filter { $0.site.ruleID == id }.map(\.text)
    }

    func clientProblems(_ id: UUID) -> [String] {
        detailedProblems.filter { $0.site.clientID == id }.map(\.text)
    }

    // MARK: Lifecycle

    /// **One lifecycle operation at a time.**
    ///
    /// Apply, Start All, Stop All and the two sidebar switches all move the same two processes
    /// and rewrite the same generated files, and every one of them is full of `await`. Nothing
    /// stopped two of them interleaving, and a double-click on "Apply & Restart" did exactly
    /// that: measured in build 12 with ten concurrent `apply()` calls, one of them was starting
    /// slapd while another's `requirePortFree` looked at 636, and the user got
    /// **"LDAPS cannot start: tcp/636 is already in use by slapd (pid 65816)"** — naming our
    /// own server. The end state recovered; the alert was still wrong and alarming.
    ///
    /// Everything public takes this gate and calls a `…Locked` body; the `…Locked` bodies call
    /// each other, so there is no re-entrancy to deadlock on. The check and the set are not
    /// separated by an `await`, and this is a MainActor class, so no two callers can both see
    /// it free.
    private var lifecycleHeld = false

    /// Nothing is queued, held or running. The only honest "they have all finished" signal.
    ///
    /// `busy` alone is not one: it is set inside each `perform` block, so it goes false in the
    /// gaps *between* the steps of a single Apply. `-lifecycleProbe storm` waited on it, broke
    /// out before the ten concurrent Applies had even started, and then reported whichever
    /// server happened to be mid-restart as not running.
    var lifecycleIsIdle: Bool { !lifecycleHeld && !applyRequested && !busy }
    /// Set by `apply()` before it queues. The holder re-runs while it is set, so a burst of
    /// clicks collapses into at most two Applies and the last one carries every edit.
    private var applyRequested = false

    private func withLifecycle(_ work: () async -> Void) async {
        while lifecycleHeld { try? await Task.sleep(for: .milliseconds(25)) }
        lifecycleHeld = true
        await work()
        lifecycleHeld = false
    }

    func startAll() async { await withLifecycle { await self.startAllLocked() } }

    /// **The directory first, then RADIUS** (build 17). radiusd's user list is generated from
    /// the directory's snapshot, so starting RADIUS first means starting it with an empty
    /// `authorize` and correcting it a second later by HUP. Nothing breaks either way — that
    /// HUP still happens — but a server that is briefly up and rejecting everybody is a
    /// server somebody will test in exactly that second.
    private func startAllLocked() async {
        // **Start all starts the backend that is selected** — build 22's behaviour, and the
        // correction to build 23's first cut, which pinned here too. Start all is the
        // whole-lab button: a lab whose chooser says Samba AD means it, and `-autoStart 1` is
        // how the `ad` suite provisions a domain at all. The OpenLDAP pin belongs to the
        // RADIUS *switch* and to nothing else — see `ServerPair.StartOrigin`.
        await startDirectoryLocked()
        await startRadiusLocked(origin: .lab)
    }

    /// **Starting RADIUS starts LDAP first** (build 21, PROJECT-STATUS §18).
    ///
    /// radiusd's user list is the directory's snapshot and there is no other source of users
    /// any more, so "RADIUS on, LDAP off" is a server that answers Access-Reject to everybody.
    /// The sidebar's RADIUS switch therefore does what Start all does: brings the directory up
    /// first and stops if it will not come up. Returns the sentence to show when it did not —
    /// one line, with whatever the failure itself said kept for the sheet's Details.
    private func startDirectoryForRadius(origin: ServerPair.StartOrigin) async
        -> (message: String, detail: String?)? {
        guard !anyDirectoryIsLive else { return nil }
        // **Build 23**: and when the switch asked, the directory it brings up is OpenLDAP,
        // named. Build 21 started whichever backend the settings pointed at, so a lab left on
        // Samba AD booted a domain controller from the RADIUS switch. Start all passes
        // `.lab` and this is a no-op for it. See `ServerPair.directoryPin`.
        pinDirectoryToOpenLDAP(origin: origin)
        // **Say the real reason, before inventing a failure** (build 25, QA H-8). With the
        // "Run the LDAP server" toggle off, `startDirectoryLocked` is a no-op and build 24 then
        // reported that the directory "could not start" — about a server nothing had asked to
        // start. `ServerPair` has the sentence; the toggle is locked under a running radiusd
        // now as well, so this is for a lab.json that arrives with it off.
        if let refusal = ServerPair.radiusRefusalBeforeStart(backend: doc.settings.directoryBackend,
                                                             ldapEnabled: doc.settings.ldapEnabled) {
            return (refusal, nil)
        }
        await startDirectoryLocked()
        guard !directoryIsLive else { return nil }
        let detail = lastError
        clearError()
        return (ServerPair.radiusRefusalAfterStart(directoryLabel: directoryLabel), detail)
    }

    /// **Move the directory settings onto OpenLDAP before a light start brings one up**
    /// (build 23; build 24 adds the Users/Groups panes to it).
    ///
    /// The decision is `ServerPair.directoryPin` and is pure; this is the two lines of state it
    /// moves. It happens for the **RADIUS switch and for opening Users or Groups**, and only
    /// with nothing running — a Samba AD that is already up is used exactly as it is, and
    /// Start all starts whatever the chooser names.
    ///
    /// Adopted into `applied` and saved here rather than left to the coalesced
    /// `scheduleStoppedAdopt`: the start that follows reads `applied` 400 ms too early for it,
    /// and this is a Directory-side change with nothing running, so there is no Apply bar it
    /// could raise and nothing for a person to confirm. The save is skipped while the document
    /// is invalid, for the same reason `adoptStoppedHalves` skips it — writing a lab.json the
    /// app would refuse to load is not a saving; `commit()` throws on those same problems a
    /// moment later and the start stops there.
    private func pinDirectoryToOpenLDAP(origin: ServerPair.StartOrigin) {
        // **`anyDirectoryIsLive`, not `directoryIsLive`** (build 24) — see it for why. A
        // domain controller that is up is a directory, whatever the chooser has been left on.
        guard let pin = ServerPair.directoryPin(origin: origin,
                                                backend: doc.settings.directoryBackend,
                                                ldapEnabled: doc.settings.ldapEnabled,
                                                directoryRunning: anyDirectoryIsLive)
        else { return }
        doc.settings.directoryBackend = pin.backend
        doc.settings.ldapEnabled = pin.ldapEnabled
        DirectoryApplyGate.adopt(from: doc, into: &applied)
        if blockingProblems.isEmpty { try? env.saveDocument(applied) }
    }

    /// Whichever directory the settings name. The two are mutually exclusive: both want 389
    /// and 636, so there is never a question of starting both.
    func startDirectory() async { await withLifecycle { await self.startDirectoryLocked() } }

    private func startDirectoryLocked() async {
        switch doc.settings.directoryBackend {
        case .openLDAP:
            if doc.settings.ldapEnabled { await startLDAPLocked() }
        case .activeDirectory:
            await startADLocked()
        }
        await refreshDirectory()
    }

    func stopAll() async { await withLifecycle { await self.stopAllLocked() } }

    private func stopAllLocked() async {
        await radius.stop()
        await ldap.stop()
        await stopADLocked()
    }

    /// The DC, plus the DNS relay and the container system. Commits first, exactly like the
    /// other two, so what starts is what was applied.
    func startAD() async { await withLifecycle { await self.startADLocked() } }

    private func startADLocked() async {
        guard !ad.isRunning else { return }
        directoryStarting = true
        defer { directoryStarting = false }
        // Before the start, not after: provisioning a domain takes the best part of a minute
        // and the Log pane is where it is legible.
        noteLogMode(.adDC)
        await perform {
            try self.checkLabPath()
            try self.commit()
            // The CA has to exist before the DC's leaf can be signed by it.
            try await self.env.ensureCertificates(serverName: self.applied.settings.serverCertName)
        }
        guard lastError == nil else { return }
        // **Two controllers, one realm, one LAN.** Asked here because after the start it is
        // invisible from either of them: both answer, both carry the same domain SID, and a
        // joined PC talks to whichever DNS answered first — so a password change lands on one
        // and a login fails against the other. This is the guard the "move the lab to another
        // Mac" feature owes the person who forgot to stop the first one.
        let verdict = await duplicateDomainVerdict()
        if verdict.refuse {
            report(verdict.message ?? "Another domain controller is answering for this realm.")
            return
        }
        // No `sync:` from build 17: the domain owns its users, and the one-time import of an
        // upgraded lab.json is offered by the Directory panes with a report, not run silently
        // behind a Start button.
        await ad.start(applied.settings.ad)
        // `-adSelfTest 1` runs the pane's own button once, right after the start. It is how
        // `./Tests/run.sh ad` gets at checks that live inside the app — a CLDAP ping and a
        // kinit are not things a shell script should be reimplementing beside them.
        if ad.isRunning, CommandLine.value(after: "-adSelfTest") == "1" {
            await ad.runSelfTest(applied.settings.ad)
        }
    }

    func stopAD() async { await withLifecycle { await self.stopADLocked() } }

    /// **The LDAP switch, which is half of a pair now** (build 22 — `ServerPair`).
    ///
    /// While radiusd is running the switch is disabled, so this is only ever reached with
    /// RADIUS down; going through `ServerPair` anyway means the rule is in one place and a
    /// stop that arrives from anywhere else still cannot strand RADIUS without a directory.
    func stopDirectoryFromSwitch() async {
        guard ServerPair.directorySwitch(on: false, radiusRunning: radius.isRunning,
                                         directoryRunning: directoryIsLive) == .stopDirectory
        else { return }
        await stopDirectory()
    }

    func stopDirectory() async { await withLifecycle { await self.stopDirectoryLocked() } }

    private func stopDirectoryLocked() async {
        switch doc.settings.directoryBackend {
        case .openLDAP: await ldap.stop()
        case .activeDirectory: await stopADLocked()
        }
        await refreshDirectory()
    }



    private func stopADLocked() async {
        // The address watch stays up: the notice it raises is about the *lab*, not the DC.
        guard ad.isRunning || ad.state.isBusy else { return }
        await ad.stop()
    }

    /// Watch this Mac's primary IPv4, for as long as the app is open.
    ///
    /// Polled rather than observed: there is no one notification that covers Wi-Fi roaming, a
    /// VPN coming up and a cable being plugged in, and one `getifaddrs` every fifteen seconds
    /// costs nothing.
    ///
    /// It used to run only while the DC was up, because its only job was to re-point the
    /// domain's DNS. That is now the *second* job. The first is that every device in the lab —
    /// a notebook's DNS setting, iMaster's *Primary server address*, a NAS entry — is pointed
    /// at this address by hand, and when it changes none of them say so. So the watch runs in
    /// both backends and in neither, and the Status pane keeps the notice until it is
    /// dismissed.
    private func startWatchingAddress() {
        observeAddress(LocalNetwork.primaryIPv4(), at: Date())
        addressWatch = Timer.publish(every: 15, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.observeAddress(LocalNetwork.primaryIPv4(), at: Date())
            }
    }

    private func observeAddress(_ address: String?, at time: Date) {
        // **"There is a notice to show" and "the address changed" are different questions.**
        // `observe` returns nil when the Mac comes back to the address the notice started
        // from — correctly, there is nothing left to warn about — but the early `return` on
        // that nil also skipped the assignment below. So en0 → en1 → en0 left `primaryAddress`
        // stuck on the middle address for the rest of the session, and `primaryAddress` is
        // what the Status tile, every Device settings table, the quick-copy rows and the Test
        // pane tell a person to type into their switch. Read the monitor's own `current`
        // instead of the notice's `to`.
        addressMonitor.observe(address, at: time)
        // Only when it actually differs: `addressChange` is `@Published`, and `@Published`
        // sends `objectWillChange` on every *assignment*, equal or not. This runs from a
        // 15-second timer for the whole life of the app, so an unconditional assignment
        // invalidated every view observing the model four times a minute for nothing.
        if addressChange != addressMonitor.change { addressChange = addressMonitor.change }
        guard let current = addressMonitor.current, current != primaryAddress else { return }
        primaryAddress = current
        if ad.isRunning {
            Task { await self.ad.hostAddressChanged(to: current, settings: self.applied.settings.ad) }
        }
        reissueLDAPCertificateForNewAddress()
    }

    /// **Open finding O-1 from the build-12 audit, closed.**
    ///
    /// `ensureLDAPCertificate` only ever ran at start, so an address this Mac picked up
    /// *afterwards* was not in the leaf's SAN until the next start — and devices point at an
    /// address and do validate it. The build-12 `live` run failed once on exactly that (the
    /// iPhone hotspot flapped between the certificate being issued and the test running) and
    /// it was never reproduced, because reproducing it means changing the Mac's address at the
    /// right moment.
    ///
    /// The RADIUS leaf is deliberately left alone: Apple supplicants pin it when the user taps
    /// Trust, which is why the two certificates are separate in the first place.
    private func reissueLDAPCertificateForNewAddress() {
        guard ldap.isRunning, applied.settings.needsTLS else { return }
        Task { [weak self] in
            guard let self else { return }
            await self.withLifecycle {
                guard self.ldap.isRunning else { return }
                let note = try? await self.env.ensureLDAPCertificate(
                    serverName: self.applied.settings.serverCertName,
                    addresses: LocalNetwork.allIPv4().map(\.ip))
                // Nil means the SAN already covered every current address — nothing was
                // rewritten, so slapd has nothing to re-read and must not be restarted.
                guard let note else { return }
                self.ldap.note("—— \(note)")
                self.certRevision += 1
                // slapd reads the certificate once, at start.
                await self.ldap.stop()
                await self.startLDAPLocked()
            }
        }
    }

    // MARK: Which log is on screen

    /// The person picked a feed in the Log pane's picker. It stays picked until the mode
    /// changes under them.
    func chooseLogSource(_ source: LogSource) {
        logPolicy.choose(source)
        logSource = logPolicy.source
    }

    /// A server started, or the directory backend was switched. Moves the Log pane to it
    /// unless the person has picked a feed by hand since the last such change.
    func noteLogMode(_ mode: LogSource) {
        logPolicy.modeStarted(mode)
        logSource = logPolicy.source
    }

    /// Switching the directory backend is a mode change even before anything is started: the
    /// pane a person opens next should be the one that will have something in it. Watched here
    /// rather than in the picker's `onChange` so every route to the setting is covered —
    /// including `-demoBackend` and a lab.json that arrives with the other backend selected.
    /// Every edit, coalesced: whichever half has no server behind it is adopted and saved.
    /// On `$doc`, so it covers a field, a picker, a context menu and a launch argument alike.
    private func watchDocument() {
        docWatch = $doc
            .dropFirst()
            .sink { [weak self] _ in self?.scheduleStoppedAdopt() }
    }

    private func watchDirectoryBackend() {
        backendWatch = $doc
            .map(\.settings.directoryBackend)
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] backend in
                guard let self else { return }
                self.noteLogMode(backend == .activeDirectory ? .adDC : .ldap)
                // The other backend's snapshot is not this one's, and radiusd's user list is
                // written from whichever is running. Both no-ops with nothing up — which is
                // the only state the switch is reachable in — and the ordinary coalesced HUP
                // when radiusd is running with its directory stopped.
                Task { @MainActor in
                    self.scheduleAuthorizeReload()
                    await self.refreshDirectory()
                }
                // Switching the backend means the other directory takes over: an automatic
                // backup first, because the one the person is leaving is the one holding
                // everything they made. Only when something is actually running — switching
                // on a lab where neither has ever started has nothing to lose, and a suite
                // instance must not spend a minute tarring a volume before its first check.
                guard self.radius.isRunning || self.ldap.isRunning || self.ad.isRunning,
                      CommandLine.value(after: "-adTest") != "1" else { return }
                Task { await self.backupNow(.beforeBackendSwitch) }
            }
    }

    /// Dismiss the "this Mac's address changed" notice on the Status pane. The next change
    /// raises a new one.
    func dismissAddressChange() {
        addressMonitor.dismiss()
        addressChange = nil
    }

    /// Only for `Tests/run.sh` and the unit tests — drives the watcher without a network.
    func observeAddressForTesting(_ address: String?, at time: Date = Date()) {
        observeAddress(address, at: time)
    }

    /// The sidebar's RADIUS switch — the **one** caller that pins the directory to OpenLDAP.
    func startRadius() async {
        await withLifecycle { await self.startRadiusLocked(origin: .radiusSwitch) }
    }

    /// Stop radiusd and nothing else — LDAP on its own is a perfectly good state, which is
    /// what `ServerPair.radiusSwitch(on: false, …)` has always said. Through the lifecycle
    /// gate, so it cannot interleave with an Apply (build 25, QA M-24: RADIUS ▸ Server has a
    /// Start/Stop control now and it must be the same one the sidebar uses).
    func stopRadius() async {
        await withLifecycle {
            guard ServerPair.radiusSwitch(on: false, radiusRunning: self.radius.isRunning,
                                          directoryRunning: self.directoryIsLive) == .stopRadius
            else { return }
            await self.radius.stop()
        }
    }

    /// **Put RADIUS back the way it was** (build 25, QA M-29) — the origin every caller that
    /// is not a person reaching for the switch wants.
    ///
    /// `StartOrigin.lab`'s own doc comment has always named "a certificate reissue" as a `.lab`
    /// case, and two production callers passed the pinning one anyway:
    /// `revokeClientCertificate`, which restarts radiusd so `rlm_eap` re-reads the CRL, and
    /// `exportLab`'s restore. Combined with the AD pane's Stop button — which calls `stopAD()`
    /// directly and never goes through `ServerPair` — revoking a certificate on an AD lab whose
    /// DC had been stopped rewrote `directoryBackend` to `.openLDAP`, forced `ldapEnabled` on,
    /// wrote `lab.json` and started slapd. Nobody had asked for any of that.
    func startRadiusForLab() async {
        await withLifecycle { await self.startRadiusLocked(origin: .lab) }
    }

    /// No default for `origin`: a caller that has not thought about which of the two it is
    /// would otherwise get the pin, and the pin is the answer for exactly one control.
    private func startRadiusLocked(origin: ServerPair.StartOrigin) async {
        guard !radius.isRunning else { return }
        // **A missing binary is reported, not swallowed** (build 25, QA M-8). Until build 24
        // this was part of the `guard` above, so ⌘R and Start all on a build whose "Bundle
        // servers" phase had not run did nothing at all, silently, with every switch still
        // reading off.
        guard let radiusd = tools.radiusd else {
            report(Toolchain.missingServerMessage(server: "RADIUS", binary: "radiusd"))
            return
        }
        if let refusal = await startDirectoryForRadius(origin: origin) {
            report(refusal.message, detail: refusal.detail)
            return
        }
        noteLogMode(.radius)
        // The snapshot is what `authorize` is written from, so it has to be current — and on
        // the very first start there is none yet.
        await refreshDirectory()
        await perform {
            try self.checkLabPath()
            await self.reap("radius", executable: radiusd)
            try await LabEnvironment.requirePortFree(self.doc.settings.authPort, protocol: "UDP", for: "RADIUS")
            try self.commit()
            try await self.env.ensureCertificates(serverName: self.applied.settings.serverCertName)
            self.certRevision += 1
            // Generated into `stage/`, parsed there, and only copied into `raddb/` once
            // radiusd has accepted it — so a rejected rule or a bad block of custom unlang
            // never leaves a configuration behind for the next launch to choke on.
            //
            // `authorize` is the directory's snapshot and nothing else (build 21). nil means
            // only "nothing better than what is already there" — see `currentAuthorize`.
            let authorize = await self.currentAuthorize()
            try await self.env.commitRadiusConfig(self.applied, authorize: authorize)
            // -f foreground, debug to stdout: the debug stream IS the product for network
            // testing. The level comes from `radiusLogArguments` — `-x` by default, `-xx` when
            // the Log pane's Debug switch is on; measured, `-xx` costs 47% of the throughput.
            // -D is not optional — see LabEnvironment.radiusDictionaryArguments.
            self.radius.start(executable: radiusd,
                              arguments: ["-d", self.env.raddb.path] + self.env.radiusDictionaryArguments
                                  + self.applied.settings.radiusLogArguments,
                              environment: self.tools.childEnvironment,
                              pidFile: self.env.pidFile("radius"))
            // Spawned is not listening. See `waitForPortBound`.
            await LabEnvironment.waitForPortBound(self.applied.settings.authPort, protocol: "UDP")
        }
    }

    func startLDAP() async { await withLifecycle { await self.startLDAPLocked() } }

    private func startLDAPLocked() async {
        guard !ldap.isRunning else { return }
        guard let slapd = tools.slapd else {
            report(Toolchain.missingServerMessage(server: "OpenLDAP", binary: "slapd"))
            return
        }
        noteLogMode(.ldap)
        // The sidebar's LDAP switch reads as on — with its spinner — from here, which is what
        // makes "RADIUS on brings LDAP up with it" visible rather than a surprise (build 22).
        directoryStarting = true
        defer { directoryStarting = false }
        await perform {
            try self.checkLabPath()
            await self.reap("ldap", executable: slapd)
            if self.applied.settings.ldapPlainEnabled {
                try await LabEnvironment.requirePortFree(self.applied.settings.ldapPort, protocol: "TCP", for: "LDAP")
            }
            if self.applied.settings.ldapsEnabled {
                try await LabEnvironment.requirePortFree(self.applied.settings.ldapsPort, protocol: "TCP", for: "LDAPS")
            }
            try self.commit()
            // The CA has to exist before a leaf can be signed by it.
            try await self.env.ensureCertificates(serverName: self.applied.settings.serverCertName)
            if self.applied.settings.needsTLS {
                let note = try await self.env.ensureLDAPCertificate(
                    serverName: self.applied.settings.serverCertName,
                    addresses: LocalNetwork.allIPv4().map(\.ip))
                if let note { self.ldap.note("—— \(note)") }
                self.certRevision += 1
            }
            // A base-DN rename is the one thing `rebuildLDAP` does that a person has to be
            // told about — it moves every DN in the directory and leaves the old database on
            // disk. Everything else it does is generating files nobody edits.
            if let note = try await self.env.rebuildLDAP(self.applied) { self.ldap.note("—— " + note) }
            let conf = self.env.ldap.appendingPathComponent("slapd.conf").path
            // -d 256 = stats logging, and keeps slapd in the foreground.
            self.ldap.start(executable: slapd,
                            arguments: ["-f", conf, "-h", self.applied.settings.listenURLs().joined(separator: " "), "-d", "256"],
                            fdLimit: 256, environment: self.tools.childEnvironment,
                            pidFile: self.env.pidFile("ldap"))
            // Same reason as radiusd, and with a sharper consequence: the first thing that
            // happens after slapd starts is a directory read, and a read that arrives early
            // used to look exactly like an empty directory.
            let port = self.applied.settings.ldapPlainEnabled
                ? self.applied.settings.ldapPort : self.applied.settings.ldapsPort
            await LabEnvironment.waitForPortBound(port, protocol: "TCP")
        }
        await backfillAdminIdentity()
        await backfillGroupPlaceholders()
    }

    /// **Once per lab, at the first start after upgrading to build 24**: `cn=Users` and
    /// `cn=Administrator` are created if they are not there, so the admin DN this build moved
    /// `rootdn` to also resolves in a search. See `OpenLDAPDirectory.ensureAdminIdentity`.
    ///
    /// Marked in the lab folder rather than in `lab.json`, for the same reason
    /// `backfillGroupPlaceholders` is: it is a property of the *database*, and a lab.json
    /// restored onto a different directory must not claim it was done.
    private func backfillAdminIdentity() async {
        guard ldap.isRunning, doc.settings.directoryBackend == .openLDAP else { return }
        let marker = env.ldap.appendingPathComponent("admin-identity")
        guard !FileManager.default.fileExists(atPath: marker.path) else { return }
        guard let provider = makeDirectoryProvider() as? OpenLDAPDirectory else { return }
        let added = await provider.ensureAdminIdentity()
        try? Data("done".utf8).write(to: marker, options: .atomic)
        if added > 0 {
            ldap.note("—— created \(added) entry/entries for \(applied.settings.ldapAdminDN) (build 24)")
        }
    }

    /// Once per lab, at the first start after upgrading to build 21: every `groupOfNames` gets
    /// the admin DN as a member so its **last real member can be removed**. See
    /// `OpenLDAPDirectory.ensureGroupPlaceholders` for what goes wrong without it.
    ///
    /// Marked in the lab folder rather than in `lab.json`: it is a property of the *database*,
    /// and a lab.json restored onto a different directory must not claim it was done.
    private func backfillGroupPlaceholders() async {
        guard ldap.isRunning, doc.settings.directoryBackend == .openLDAP else { return }
        let marker = env.ldap.appendingPathComponent("group-placeholders")
        guard !FileManager.default.fileExists(atPath: marker.path) else { return }
        guard let provider = makeDirectoryProvider() as? OpenLDAPDirectory else { return }
        let touched = await provider.ensureGroupPlaceholders()
        try? Data("done".utf8).write(to: marker, options: .atomic)
        if touched > 0 { ldap.note("—— gave \(touched) group(s) the placeholder member (build 21)") }
    }

    /// Save + regenerate + restart whatever was running.
    ///
    /// Clicks collapse rather than queue: ten of them in two seconds run at most two Applies,
    /// and the last one sees every edit. `applyRequested` is set *before* the gate is taken,
    /// so an edit made while an Apply is in flight is never lost.
    func apply() async {
        discardHeldBackAttributes()
        applyRequested = true
        await withLifecycle {
            while self.applyRequested {
                self.applyRequested = false
                await self.applyLocked()
            }
        }
    }

    /// **Apply is when a switched-off "Also send attributes" gives up its text** (build 25,
    /// QA M-21). The lines stop being generated the moment the switch goes off — `alsoSend`
    /// and `sentAttributes` are empty from then on — and the editor says they are being kept
    /// until this moment, so that turning the switch back on before it brings them back whole.
    private func discardHeldBackAttributes() {
        for index in doc.rules.indices where !doc.rules[index].sendsAttributes {
            doc.rules[index].replyAttributes = ""
            doc.rules[index].sessionTimeout = ""
            doc.rules[index].sendsAttributes = true
        }
    }

    private func applyLocked() async {
        let radiusWasRunning = radius.isRunning
        let ldapWasRunning = ldap.isRunning
        let adWasRunning = ad.isRunning
        let refusals = blockingProblems
        guard refusals.isEmpty else { report(refusals.joined(separator: "\n")); return }
        // radiusd has the last word on the rules and on any custom unlang, so ask it here —
        // before anything is stopped. A refusal has to leave the running server serving.
        let authorize = await currentAuthorize()
        if tools.radiusd != nil, let problem = await env.radiusConfigProblem(doc, authorize: authorize) {
            report("""
            radiusd will not accept this configuration, so nothing was applied. \
            \(radiusWasRunning ? "The server is still running the last one that worked." : "")

            \(problem.summary)
            """, detail: problem.detail)
            return
        }
        // **A running DC is not touched by Apply at all** (build 17). Until build 16 Apply
        // reconciled the app's table into `OU=SheepRadius`; identity now belongs to the
        // directory itself and every edit has already been applied by the pane that made it.
        // What is left for Apply is RADIUS — rules, clients, ports, certificates — so the DC
        // simply stays up and only radiusd is restarted.
        if adWasRunning {
            await perform {
                try self.commit()
                if self.tools.radiusd != nil {
                    try await self.env.commitRadiusConfig(self.applied, authorize: authorize)
                }
            }
            if radiusWasRunning { await radius.stop(); await startRadiusLocked(origin: .lab) }
            return
        }
        await stopAllLocked()
        // **The directory first, then RADIUS** — the same order as `startAllLocked`, and for a
        // sharper reason here: `startRadiusLocked` writes `authorize` from the directory's
        // snapshot, so starting radiusd while slapd is still down means writing the user list
        // from whatever was last read rather than from the directory itself.
        if ldapWasRunning, doc.settings.ldapEnabled { await startLDAPLocked() }
        if radiusWasRunning { await startRadiusLocked(origin: .lab) }
        if !radiusWasRunning, !ldapWasRunning {
            // With nothing running, Apply still has to *land*: `raddb/` is otherwise only
            // written by `startRadius`, so a fresh install that was edited and applied without
            // ever starting a server saved lab.json and generated nothing. The staged parse
            // above has already approved exactly these files.
            await perform {
                try self.commit()
                if self.tools.radiusd != nil {
                    try await self.env.commitRadiusConfig(self.applied, authorize: authorize)
                }
            }
        }
        await refreshDirectory()
    }

    /// **Revert is "put back what the servers use"** — which is also, exactly, "undo what has
    /// not been adopted" (build 25, QA M-27). `applied` is what a running server was generated
    /// from and what a stopped half has already taken, so assigning it drops the unapplied
    /// edits and the draft rows together and can touch nothing else. It could never undo an
    /// adopted edit, and build 24's bar offered it as though it could; the bar asks first and
    /// names what will go (`ApplyScope.revertSummary`) instead.
    func revert() { doc = applied }

    /// What the Revert confirmation says, or nil when there is nothing to discard.
    var revertSummary: String? { ApplyScope.revertSummary(doc: doc, applied: applied) }

    func regenerateCertificates(includingCA: Bool) async {
        await withLifecycle { await self.regenerateCertificatesLocked(includingCA: includingCA) }
    }

    /// **A New CA replaces every certificate the old one signed** (build 25 — QA H-4 and H-9).
    ///
    /// Build 24 rewrote `ca.pem`, `server.pem` and, when the directory was configured for TLS,
    /// `ldap.pem`. Two things it did not touch:
    ///
    /// - `certs/clients/` and `ca-db/clients.json`, so a client certificate that had stopped
    ///   authenticating the moment the CA changed went on reading **Valid** in the Certificates
    ///   pane, which renders its status from the dates alone (**H-4**). They are marked
    ///   superseded here, the confirmation says how many there are before the button is
    ///   pressed, and the table says which.
    /// - `ad.pem`, because `ensureADCertificate` was reachable only from the DC's own start
    ///   with `force: false` (**H-9**). A domain controller therefore served a leaf signed by a
    ///   CA that no longer existed, while the container was handed the new one in `TLS_CA_B64`.
    ///   The DC is stopped and started for it the way slapd is, because Samba reads the
    ///   certificate once, at start.
    private func regenerateCertificatesLocked(includingCA: Bool) async {
        let wasRunning = radius.isRunning
        let ldapWasRunning = ldap.isRunning
        let adWasRunning = ad.isRunning
        let isAD = doc.settings.directoryBackend == .activeDirectory
        await radius.stop()
        // A new CA invalidates every leaf under it, so each running server has to come down.
        if includingCA {
            await ldap.stop()
            if isAD { await stopADLocked() }
        }
        await perform {
            try await self.env.ensureCertificates(serverName: self.doc.settings.serverCertName, forceCA: includingCA, forceServer: true)
            if includingCA, !isAD, self.doc.settings.needsTLS {
                try await self.env.ensureLDAPCertificate(serverName: self.doc.settings.serverCertName,
                                                         addresses: LocalNetwork.allIPv4().map(\.ip), force: true)
            }
            if includingCA, isAD {
                try await self.env.ensureADCertificate(settings: self.doc.settings.ad,
                                                       serverName: self.doc.settings.serverCertName,
                                                       addresses: LocalNetwork.allIPv4().map(\.ip),
                                                       force: true)
            }
            if includingCA {
                let superseded = try await self.env.supersedeClientCertificates()
                if superseded > 0 {
                    self.radius.note("—— the new CA superseded \(superseded) client certificate(s)")
                }
            }
            self.certRevision += 1
        }
        if wasRunning { await startRadiusLocked(origin: .lab) }
        if includingCA, ldapWasRunning { await startLDAPLocked() }
        if includingCA, isAD, adWasRunning { await startADLocked() }
    }

    /// **Reissue just the domain controller's leaf** (build 25, QA H-9) — the AD counterpart of
    /// `regenerateLDAPCertificate`, and the thing the Certificates pane's Domain-controller
    /// card had no button for at all.
    func regenerateADCertificate() async {
        await withLifecycle { await self.regenerateADCertificateLocked() }
    }

    private func regenerateADCertificateLocked() async {
        let wasRunning = ad.isRunning
        await stopADLocked()
        await perform {
            try await self.env.ensureCertificates(serverName: self.doc.settings.serverCertName)
            try await self.env.ensureADCertificate(settings: self.doc.settings.ad,
                                                   serverName: self.doc.settings.serverCertName,
                                                   addresses: LocalNetwork.allIPv4().map(\.ip),
                                                   force: true)
            self.certRevision += 1
        }
        if wasRunning { await startADLocked() }
    }

    /// Reissue just the LDAP leaf — the RADIUS one is deliberately left alone, because
    /// Apple supplicants pin it when the user taps Trust.
    func regenerateLDAPCertificate() async {
        await withLifecycle { await self.regenerateLDAPCertificateLocked() }
    }

    private func regenerateLDAPCertificateLocked() async {
        let wasRunning = ldap.isRunning
        await ldap.stop()
        await perform {
            try await self.env.ensureCertificates(serverName: self.doc.settings.serverCertName)
            try await self.env.ensureLDAPCertificate(serverName: self.doc.settings.serverCertName,
                                                     addresses: LocalNetwork.allIPv4().map(\.ip), force: true)
            self.certRevision += 1
        }
        if wasRunning { await startLDAPLocked() }
    }

    func shutdownForQuit() {
        // **Something saves at quit now** (build 25, QA M-28). The coalesced adopt runs 400 ms
        // after the last keystroke, so an edit made to a stopped half and quit on immediately
        // used to go nowhere at all. This is the same adoption, taken once more while the two
        // processes are still up — so a *running* server's unapplied edit is still not
        // adopted, which is what the bar and Revert have always promised.
        adoptStoppedHalves()
        radius.terminateNow()
        ldap.terminateNow()
        installer.terminateNow()
        ad.terminateNow()
    }

    /// Called from the SIGTERM/SIGINT/SIGHUP handlers, where there is no run loop left to
    /// await on. The supervisor's lifeline would kill the servers anyway once this process
    /// goes, but doing it here makes the shutdown prompt and ordered.
    func emergencyShutdown() {
        shutdownForQuit()
        // The DC is stopped by its lifeline the moment this process goes; waiting for the two
        // real children is what keeps 1812 and 389 free for the next launch.
        for _ in 0..<50 where radius.isRunning || ldap.isRunning {
            usleep(100_000)
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
    }

    // MARK: Orphans

    /// Clears anything a previous unclean exit left behind, and says so in the log.
    private func reap(_ name: String, executable: String?) async {
        guard let note = await env.reapOrphan(name, executable: executable) else { return }
        let target = name == "radius" ? radius : ldap
        target.note("—— \(note)")
    }

    /// Reaps everything at launch, before anything tries to bind a port — including a DC
    /// container an unclean exit left holding 389, 445 and the rest.
    func reapOrphansAtLaunch() async {
        await reap("radius", executable: tools.radiusd)
        await reap("ldap", executable: tools.slapd)
        await ad.reapAtLaunch()
    }

    private func checkLabPath() throws {
        if let problem = env.pathProblem { throw LabEnvironment.Failure(message: problem) }
    }

    // MARK: Toolchain

    /// Cheap (a handful of `stat`s), so it also runs whenever the app becomes active — a
    /// `brew install` the user ran in their own Terminal is picked up the same way.
    func refreshToolchain() {
        guard !radius.isRunning, !ldap.isRunning, !ad.isRunning else { return }
        let found = Toolchain.detect()
        guard found != tools else { return }
        tools = found
        env = LabEnvironment(base: labBase, tools: found)
        ad.adopt(tools: found, env: env)
        Task { await readLDAPVersions() }
    }

    /// `slapd -VV` / `ldapsearch -VV` print their banner and exit. Read once, off the main
    /// thread, so Settings and the LDAP card can say *which* OpenLDAP this is.
    func readLDAPVersions() async {
        slapdVersion = await Self.version(of: tools.slapd, named: "slapd")
        ldapsearchVersion = await Self.version(of: tools.ldapsearch, named: "ldapsearch")
        opensslVersion = await Self.opensslVersion(of: tools.openssl)
        radiusVersion = await Self.radiusVersion(of: tools.radiusd)
    }

    /// "OpenSSL 3.6.4 30 Sep 2026" → "3.6.4"
    private static func opensslVersion(of executable: String?) async -> String {
        guard let executable else { return "" }
        let result = await Shell.run(executable, ["version"], environment: [:])
        let words = result.output.split(separator: " ")
        guard words.count > 1, words[0] == "OpenSSL" || words[0] == "LibreSSL" else { return "" }
        return String(words[1])
    }

    /// "radiusd: FreeRADIUS Version 3.2.10, for host …" → "3.2.10"
    private static func radiusVersion(of executable: String?) async -> String {
        guard let executable else { return "" }
        let result = await Shell.run(executable, ["-v"], environment: [:])
        guard let line = result.output.split(separator: "\n").first(where: { $0.contains("FreeRADIUS Version") }),
              let range = line.range(of: "FreeRADIUS Version ") else { return "" }
        return String(line[range.upperBound...].prefix { $0 != "," && $0 != " " })
    }

    /// Pulls "2.7.1" out of `@(#) $OpenLDAP: slapd 2.7.1 (Sep  8 2026 21:55:18) $`.
    private static func version(of executable: String?, named tool: String) async -> String {
        guard let executable else { return "" }
        let result = await Shell.run(executable, ["-VV"], environment: [:])
        guard let line = result.output.split(separator: "\n").first(where: { $0.contains("$OpenLDAP:") }),
              let range = line.range(of: "\(tool) ") else { return "" }
        return String(line[range.upperBound...].prefix { $0 != " " })
    }

    /// "OpenLDAP 2.7.1 · bundled in the app"
    var ldapDescription: String {
        let version = slapdVersion.isEmpty ? "OpenLDAP" : "OpenLDAP \(slapdVersion)"
        guard let source = tools.ldapSource else { return "not found" }
        return "\(version) · \(source.label)"
    }

    /// The client tools come from the same OpenLDAP as the server, so one version covers both.
    var ldapClientDescription: String {
        guard tools.ldapsearch != nil else { return "not found" }
        let version = ldapsearchVersion.isEmpty ? "ldapsearch" : "ldapsearch \(ldapsearchVersion)"
        guard let source = tools.ldapSource else { return version }
        return "\(version) · \(source.label)"
    }

    /// The address a device should be pointed at.
    ///
    /// **Published, not computed.** Every device-settings table is built from it, and a table
    /// that is right but does not redraw when the Mac changes network is worse than one that is
    /// obviously stale. `addressPoll` is what moves it.
    @Published private(set) var primaryAddress = LocalNetwork.primaryIPv4() ?? "127.0.0.1"

    var radiusDescription: String {
        guard let source = tools.radiusSource else { return "not found" }
        let version = radiusVersion.isEmpty ? "FreeRADIUS" : "FreeRADIUS \(radiusVersion)"
        return "\(version) · \(source.label)"
    }

    var opensslDescription: String {
        guard let source = tools.opensslSource else { return "not found" }
        let version = opensslVersion.isEmpty ? "OpenSSL" : "OpenSSL \(opensslVersion)"
        return "\(version) · \(source.label)"
    }

    /// Runs `brew install <formulae>` as the current user — never sudo, never at launch, only
    /// when the user presses the button. Output streams into the Status card.
    func installWithHomebrew(_ formulae: [String]) {
        guard !installer.isRunning, !formulae.isEmpty, let brew = tools.brew else { return }
        // Dev hook: point the streaming runner at something harmless to exercise the UI.
        let command = CommandLine.value(after: "-demoInstallCommand")?
            .split(separator: " ").map(String.init) ?? [brew, "install"] + formulae
        guard let executable = command.first else { return }
        installer.clearLog()
        installer.onExit = { [weak self] status in
            guard status == 0 else { return }
            self?.refreshToolchain()
        }
        installer.start(executable: executable, arguments: Array(command.dropFirst()),
                        // NO_AUTO_UPDATE keeps a five-minute `brew update` out of the way;
                        // NO_ENV_HINTS keeps the epilogue out of the streamed output.
                        environment: ["HOMEBREW_NO_AUTO_UPDATE": "1", "HOMEBREW_NO_ENV_HINTS": "1"])
    }

    func clearEvents() {
        eventStore.removeAll()
        eventsDirty = false
        events.removeAll()
    }

    // MARK: The live suite's policy equivalence probe

    /// `-policyMatrix 1`. The build's most important test: it proves that `PolicyEvaluator`
    /// and the real radiusd agree, request for request, over `PolicyMatrix`.
    ///
    /// Both halves have to be driven from in here — the evaluator is Swift and the request has
    /// to reach the real server through the real client — so the comparison happens here and
    /// the shell suite only has to check that every line says `match`. It then exercises the
    /// custom-unlang path, including a broken one, which must be refused **without** taking
    /// down the configuration the server is already using.
    func runPolicyMatrix() async {
        setvbuf(stdout, nil, _IONBF, 0)
        func say(_ text: String) { print("[policy] \(text)") }

        doc = PolicyMatrix.document(doc)
        await apply()
        if let error = lastError {
            say("apply-failed \(error.replacingOccurrences(of: "\n", with: " · "))")
            return
        }
        guard radius.isRunning else { return say("radius-not-running") }
        say("rules-applied \(applied.rules.count)")
        // **Where the identity in the question came from** (build 21). A rule names its group,
        // `authorize` writes the directory's names into `Sheep-Group`, and the evaluator below
        // is asked with those same names — so this says, in the log the suite reads, that the
        // comparison was made against the directory and not against the seed table.
        say("identity-source \(directoryIsLive ? "directory" : "SEED") groups=\(directory.groups.count)")
        say("identity-alice \(directory.users.first { $0.username == "alice" }.map { "\($0.ou) · \($0.groups.joined(separator: ","))" } ?? "-")")

        let runner = TestRunner(tools: tools, env: env)
        var mismatches = 0
        // **The identity the evaluator is asked about is the directory's** (build 21). It is
        // what radiusd was handed — `authorize` writes `Sheep-OU` and `Sheep-Group` from the
        // snapshot — so predicting from anything else would be comparing the server against a
        // question nobody asked it. The seed row is still where the password comes from,
        // because a directory does not give one back.
        await refreshDirectory()
        func subject(_ username: String) -> (user: LabUser, groups: [String])? {
            guard var user = applied.users.first(where: { $0.username == username }) else { return nil }
            guard let live = directory.users.first(where: {
                $0.username.caseInsensitiveCompare(username) == .orderedSame
            }) else { return (user, applied.groups(of: user).map(\.name)) }
            user.ou = live.ou
            return (user, live.groups)
        }
        for item in PolicyMatrix.requests() {
            guard let (user, groupNames) = subject(item.user) else {
                say("\(item.name) no-such-user")
                mismatches += 1
                continue
            }
            var request = item.request
            request.date = Date()
            let predicted = PolicyMatrix.predicted(user: user, groupNames: groupNames,
                                                   doc: applied, request: request)
            let (actual, _) = await send(request, as: user, runner: runner)
            let agreed = actual == predicted
            if !agreed { mismatches += 1 }
            say("\(item.name) \(agreed ? "match" : "MISMATCH")")
            say("  evaluator: \(predicted)")
            say("  radiusd:   \(actual)")
        }
        say("matrix-done \(mismatches) mismatch(es)")

        // The same questions through a PEAP tunnel, which until eapol_test was bundled had
        // never been asked of anything. This is where the inner/outer arrangement is either
        // right or is not: the identity lives inside, the NAS attributes are copied inside,
        // the reply is carried back out, and the rules must run exactly ONCE.
        if tools.eapolTest == nil {
            say("peap-skipped \(tools.eapolTestHint ?? "no eapol_test")")
        } else {
            var tunnelMismatches = 0
            for item in PolicyMatrix.requests() where PolicyMatrix.tunnelledRows.contains(item.name) {
                guard let (user, groupNames) = subject(item.user) else { continue }
                var request = item.request
                request.date = Date()
                // Predict the request eapol_test will actually send, not the one the row
                // describes: a supplicant fills in a port type and a station MAC of its own.
                if request.nasPortType.isEmpty { request.nasPortType = EAPTestRequest.impliedPortType }
                if request.callingStationID.isEmpty {
                    request.callingStationID = EAPTestRequest.impliedCallingStationID
                }
                let predicted = PolicyMatrix.tunnelled(
                    PolicyMatrix.predicted(user: user, groupNames: groupNames,
                                           doc: applied, request: request))
                let before = ruleEvaluationsSeen
                let actual = PolicyMatrix.tunnelled(await sendThroughPEAP(request, as: user, runner: runner))
                let evaluations = ruleEvaluationsSeen - before
                let agreed = actual == predicted
                if !agreed { tunnelMismatches += 1 }
                say("peap-\(item.name) \(agreed ? "match" : "MISMATCH") evaluations=\(evaluations)")
                say("  evaluator: \(predicted)")
                say("  radiusd:   \(actual)")
            }
            say("peap-matrix-done \(tunnelMismatches) mismatch(es)")
        }

        // Custom unlang: accepted, and actually in effect.
        doc.customUnlang = """
        update reply {
        \tTermination-Action := 1
        }
        """
        await apply()
        if let error = lastError {
            say("custom-good rejected \(error.replacingOccurrences(of: "\n", with: " · "))")
            clearError()
        }
        guard let alice = applied.users.first(where: { $0.username == "alice" }) else { return }
        var plain = PolicyRequest(nasIPAddress: "127.0.0.1")
        plain.date = Date()
        let (_, attributes) = await send(plain, as: alice, runner: runner)
        say("custom-good effective=\(attributes["Termination-Action"] ?? "-")")

        // And a broken one: refused, with the parser's own file and line, while the server
        // carries on serving what it already had.
        doc.customUnlang = "if (this is not unlang {"
        await apply()
        let refused = lastError ?? ""
        clearError()
        say("custom-broken refused=\(refused.isEmpty ? "no" : "yes") running=\(radius.isRunning ? "yes" : "no")")
        say("  message: \(refused.replacingOccurrences(of: "\n", with: " · "))")
        let (_, after) = await send(plain, as: alice, runner: runner)
        say("custom-broken still-effective=\(after["Termination-Action"] ?? "-")")
        say("done")
    }

    /// One matrix request: through the real client, against the real server, with the rule
    /// names radiusd reported for it.
    private func send(_ request: PolicyRequest, as user: LabUser,
                      runner: TestRunner) async -> (fingerprint: String, attributes: [String: String]) {
        var wire = RadiusRequest()
        wire.username = user.username
        wire.password = user.password
        wire.nasIPAddress = request.nasIPAddress
        wire.nasIdentifier = request.nasIdentifier
        wire.nasPortType = request.nasPortType
        wire.calledStationID = request.calledStationID
        wire.callingStationID = request.callingStationID

        let mark = eventStore.first?.id ?? -1
        let result = await runner.radius(wire, host: "127.0.0.1", port: applied.settings.authPort,
                                         secret: localTestSecret, timeout: 3, retries: 1)
        let fired = await rulesForEvent(after: mark)
        var values: [String: String] = [:]
        for attribute in result.outcome.attributes { values[attribute.name] = attribute.value }
        let watched = values.filter { PolicyMatrix.watched.contains($0.key) }
        return (PolicyMatrix.fingerprint(rejected: result.outcome.verdict == .reject,
                                         values: watched, rules: fired), values)
    }

    /// The same request through a PEAP tunnel, with an anonymous outer identity so that the
    /// real username exists **only** inside — which is what makes this a test of the inner
    /// copy of the rules and not of the outer one.
    private func sendThroughPEAP(_ request: PolicyRequest, as user: LabUser,
                                 runner: TestRunner) async -> String {
        var wire = EAPTestRequest()
        wire.method = .peapMSCHAPv2
        wire.identity = user.username
        wire.password = user.password
        wire.anonymousIdentity = "anonymous@lab"
        wire.validation = .labCA
        wire.nasIPAddress = request.nasIPAddress
        wire.nasIdentifier = request.nasIdentifier
        wire.nasPortType = request.nasPortType
        wire.calledStationID = request.calledStationID
        wire.callingStationID = request.callingStationID
        wire.timeout = 20

        let mark = eventStore.first?.id ?? -1
        let result = await runner.eap(wire, host: "127.0.0.1", port: applied.settings.authPort,
                                      secret: localTestSecret, caPath: env.caPEM.path)
        let fired = await rulesForEvent(after: mark)
        var values: [String: String] = [:]
        for attribute in result.outcome.attributes { values[attribute.name] = attribute.value }
        let watched = values.filter { PolicyMatrix.watched.contains($0.key) }
        return PolicyMatrix.fingerprint(rejected: result.outcome.verdict != .accept,
                                        values: watched, rules: fired)
    }

    /// The rule tags for the *next* verdict after `mark`, so two requests for the same user
    /// cannot be confused with each other.
    private func rulesForEvent(after mark: Int) async -> [String] {
        for _ in 0..<60 {
            if let event = eventStore.first, event.id > mark { return event.rules }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return []
    }

    /// The Log pane's **Debug (-xx)** switch.
    ///
    /// The level is only a launch argument — nothing generated changes — so this deliberately
    /// does **not** go through Apply: it sets `doc` *and* `applied` together (so the ApplyBar
    /// stays down), saves, and restarts radiusd if it is running. A restart is unavoidable;
    /// radiusd takes its level from argv and `-HUP` re-reads the configuration, not the flags.
    func setRadiusDebug(_ on: Bool) async {
        guard applied.settings.radiusDebug != on else { return }
        doc.settings.radiusDebug = on
        applied.settings.radiusDebug = on
        try? env.saveDocument(applied)
        guard radius.isRunning else { return }
        await withLifecycle {
            self.radius.note("—— restarting radiusd at \(on ? "-xx (debug)" : "-x") logging")
            await self.radius.stop()
            await self.startRadiusLocked(origin: .lab)
        }
    }

    // MARK: Internals

    /// Move the directory-owned parts of `doc` into `applied` without going through Apply.
    ///
    /// `applied` has a private setter because everything else about it is "what the running
    /// servers were generated from", and that is Apply's business alone. These four are not:
    /// a directory edit has *already* happened by the time it is recorded, so leaving `applied`
    /// behind would raise the ApplyBar over a change the person just watched take effect.
    /// Lives here rather than in `DirectoryModel.swift` because `private(set)` is file-scoped.
    /// After a restore: `applied` is whatever was in the file, because the servers are about
    /// to be started from exactly that.
    func adoptRestoredApplied(_ document: LabDocument) {
        applied = document
    }

    /// Raise the "the lab moved" card after an import, with the honest `from`: every device is
    /// pointed at the other Mac's address by hand, and nothing in the network will say so.
    func noteLabMoved(from realm: String) {
        let here = LocalNetwork.primaryIPv4() ?? "127.0.0.1"
        addressChange = AddressChange(from: "the other Mac", to: here, at: Date())
        radius.note("—— imported the lab for \(realm); devices must be re-pointed at \(here)")
    }

    /// **Change the domain's Administrator password in one step** (owner request, build 17).
    ///
    /// Before this there were two: type a new password into Directory ▸ Server, and then find
    /// the repair button — which only appeared *after* something had already been refused — to
    /// push it into the domain. The two could differ for days, and the first thing to notice
    /// was a device failing to join.
    ///
    /// The domain is changed first and the setting only if that succeeded, because a setting
    /// that claims a password the domain does not have is the exact state this removes. Saved
    /// into `doc` **and** `applied` together: the domain already has it, so raising the
    /// ApplyBar over it would be asking a person to apply something that has happened.
    ///
    /// With no domain controller running there is nothing to change, so the setting is simply
    /// recorded — it is what the domain will be **provisioned** with.
    func changeDomainAdministratorPassword(to password: String) async -> String? {
        guard !password.isEmpty else { return "The password cannot be empty." }
        if ad.isRunning {
            if let problem = await ad.changeAdministratorPassword(to: password,
                                                                  settings: applied.settings.ad) {
                return problem
            }
        }
        doc.settings.ad.administratorPassword = password
        applied.settings.ad.administratorPassword = password
        try? env.saveDocument(doc)
        return nil
    }

    func adoptDirectoryState() {
        applied.directoryPasswords = doc.directoryPasswords
        applied.directoryImported = doc.directoryImported
    }

    /// **What a start or an Apply commits** (build 25 — `ApplyScope`): `doc` without the
    /// never-applied client or rule that is not finished yet, so adding a row cannot stop the
    /// rest of the lab being saved and generated. A draft that is valid is not a draft, so
    /// this is `doc` itself in every ordinary case.
    private func commit() throws {
        let target = ApplyScope.committable(doc: doc, applied: applied)
        let refusals = Validation.problems(in: target)
        guard refusals.isEmpty else { throw LabEnvironment.Failure(message: refusals.joined(separator: "\n")) }
        try env.saveDocument(target)
        applied = target
    }

    /// The single place an error reaches the UI, so the message and its detail always travel
    /// together and neither can be set without the other being cleared.
    ///
    /// **Build 22**: while a directory pane is starting the directory by itself, the failure
    /// belongs in the pane — the person did not press anything, so a sheet in front of the
    /// window would be the app interrupting itself.
    func report(_ message: String, detail: String? = nil) {
        if quietErrors {
            directoryStartProblem = message
            directoryStartDetail = detail
            return
        }
        lastErrorDetail = detail
        lastError = message
    }

    /// **Opening Users or Groups starts the directory** (build 22, owner's decision) — and
    /// from build 24 the directory it starts is **OpenLDAP**, by name (owner's correction).
    ///
    /// The decision itself is `DirectoryPaneStart` + `ServerPair.directoryPin`, both pure and
    /// unit-tested; this is the plumbing around them. It calls the ordinary `startDirectory()`,
    /// so the lifecycle gate, the port preflight and the duplicate-DC probe are exactly the
    /// ones the sidebar switch goes through — the pane takes no shortcut of its own.
    func startDirectoryFromPane() async {
        // **The pin goes first**, so the decision below is made about the backend that will
        // actually come up rather than the one the chooser happens to name. With a directory
        // already running it returns nil and changes nothing — which is what makes the guard
        // below see `isLive` for a domain controller the chooser is not pointing at.
        pinDirectoryToOpenLDAP(origin: .usersPane)
        guard DirectoryPaneStart.onOpeningPane(isLive: anyDirectoryIsLive,
                                               isStarting: directoryStarting || paneStartInFlight,
                                               hasFailed: directoryStartProblem != nil,
                                               isAvailable: directoryPaneIsAvailable) == .start
        else { return }
        await runDirectoryStartForPane()
    }

    /// The Retry button, which is the only thing that clears a failed start.
    func retryDirectoryFromPane() async {
        pinDirectoryToOpenLDAP(origin: .usersPane)
        guard DirectoryPaneStart.onRetry(isLive: anyDirectoryIsLive,
                                         isStarting: directoryStarting || paneStartInFlight,
                                         isAvailable: directoryPaneIsAvailable) == .start
        else { return }
        await runDirectoryStartForPane()
    }

    private func runDirectoryStartForPane() async {
        directoryStartProblem = nil
        directoryStartDetail = nil
        paneStartInFlight = true
        quietErrors = true
        await startDirectory()
        quietErrors = false
        paneStartInFlight = false
        // A start that reported nothing and brought nothing up still has to say something:
        // `startLDAPLocked` returns early when the backend is switched off underneath it.
        if !directoryIsLive, directoryStartProblem == nil {
            directoryStartProblem = "\(directoryLabel) did not start."
        }
    }

    /// Is there anything to start? The tools have to be installed and the backend switched on.
    var directoryIsAvailable: Bool {
        switch doc.settings.directoryBackend {
        case .openLDAP: tools.ldapReady && doc.settings.ldapEnabled
        case .activeDirectory: tools.containerTool != nil
        }
    }

    /// **What opening Users or Groups would actually bring up** (build 24). Not always the
    /// backend the chooser names — see `ServerPair.directoryPin`.
    var directoryBackendForPane: DirectoryBackend {
        ServerPair.directoryPin(origin: .usersPane, backend: doc.settings.directoryBackend,
                                ldapEnabled: doc.settings.ldapEnabled,
                                directoryRunning: anyDirectoryIsLive)?.backend
            ?? doc.settings.directoryBackend
    }

    /// The same question for the pane's own start. `ldapEnabled` is not tested: the pin
    /// switches it on, exactly as it does for the RADIUS switch.
    var directoryPaneIsAvailable: Bool {
        switch directoryBackendForPane {
        case .openLDAP: tools.ldapReady
        case .activeDirectory: tools.containerTool != nil
        }
    }

    /// "Starting OpenLDAP…" / "Starting Samba AD…" — one line, naming the backend that is
    /// actually coming up.
    var directoryStartingLine: String {
        "Starting \(directoryBackendForPane.label)…"
    }

    func clearError() {
        lastError = nil
        lastErrorDetail = nil
    }

    private func perform(_ work: @escaping () async throws -> Void) async {
        busy = true
        defer { busy = false }
        do {
            try await work()
        } catch let failure as LabEnvironment.Failure {
            report(failure.message, detail: failure.detail)
        } catch {
            report(error.localizedDescription)
        }
    }

    /// radiusd (log.auth = yes) prints e.g.
    ///   (12) Login OK: [alice] (from client lab-switch port 3 cli AA-BB-CC-DD-EE-FF)
    ///   (4) Login incorrect (mschap: MS-CHAP2-Response is incorrect): [bob] (from client …)
    private func scanForAuth(_ lines: [String]) {
        // `events` is `@Published`, so inserting one at a time publishes once per login — a
        // thousand-request flood made a thousand invalidations *and* a thousand O(n) memmoves
        // through a 500-element array. Collect the chunk's events and insert them in one go.
        var fresh: [AuthEvent] = []
        /// The newest event, wherever it currently lives.
        func newest() -> AuthEvent? { fresh.last ?? eventStore.first }
        for line in lines {
            // A rule tag comes before the verdict for the same request — measured, and it is
            // why this only has to buffer forwards. See `parseRuleHit`.
            // eapol_test never prints the cipher suite, but our own radiusd does — so for a
            // test aimed at This Mac the Test pane can name it, exactly the way it names the
            // rules that fired. Against another server it stays unknown and the pane says so.
            if Self.entersRuleBlock(line) {
                ruleEvaluationsSeen += 1
                continue
            }
            if let suite = Self.parseCipherSuite(line) {
                lastCipherSuite = (suite, Date())
                continue
            }
            if let hit = Self.parseRuleHit(line) {
                pendingRules[hit.request, default: []].append(hit.rule)
                // A stuck request number would otherwise leak; radiusd reuses them, and 64
                // in flight is far more than this server ever has.
                if pendingRules.count > 64 { pendingRules.removeAll() }
                continue
            }
            guard var event = Self.parseAuth(line, id: nextEventID) else { continue }
            if let number = event.request, let fired = pendingRules.removeValue(forKey: number) {
                event.rules = fired
            }
            // One tunnelled login prints TWO verdicts, which nothing before eapol_test could
            // see: the inner one with the real identity and `via TLS tunnel`, then the outer
            // one — for `anonymous@lab`, a user who does not exist. Left alone the feed shows
            // a phantom second sign-in, and the rules hang off the row that is not the one a
            // person reads. So the outer half is folded into the inner row instead.
            if let previous = newest(), Self.isOuterHalf(of: previous, following: event) {
                if previous.username != event.username {
                    if fresh.isEmpty {
                        eventStore[0].outerIdentity = event.username
                        eventsDirty = true
                        scheduleEventFlush()
                    } else {
                        fresh[fresh.count - 1].outerIdentity = event.username
                    }
                }
                continue
            }
            nextEventID += 1
            fresh.append(event)
        }
        guard !fresh.isEmpty else { return }
        // `fresh` is oldest-first and `eventStore` is newest-first.
        eventStore.insert(contentsOf: fresh.reversed(), at: 0)
        if eventStore.count > 500 { eventStore.removeLast(eventStore.count - 500) }
        eventsDirty = true
        scheduleEventFlush()
    }

    /// The domain controller's own `Auth:` lines, into the same list RADIUS writes to.
    ///
    /// Three things happen here that `scanForAuth` does not have to do, all of them because the
    /// DC's feed is much noisier than radiusd's:
    ///
    /// * **Coalescing.** iMaster NCE-Campus re-binds every thirty seconds and `winbind` prints
    ///   the same `ntlm_auth` verdict three times for one call. Identical consecutive events
    ///   become one row with a count instead of forty rows of the same sentence.
    /// * **A throttled refresh of the DC's counters**, so Users ▸ Properties' lastLogon /
    ///   logonCount / badPwdCount follow a login without a person pressing anything — at most
    ///   once every `ADController.factsRefreshInterval` seconds.
    /// * **Joined computers**, refreshed immediately when a machine account the app has never
    ///   seen sets up its secure channel. That is a device joining, and the card that answers
    ///   "did it join?" should not need a button press at the one moment it matters.
    func ingestADAuth(_ records: [ADAuthRecord]) {
        guard !records.isEmpty else { return }
        let computers = ad.computers
        let known = Set(computers.map { $0.name.replacingOccurrences(of: "$", with: "").lowercased() })
        var newComputer = false
        var fresh: [AuthEvent] = []
        func newest() -> AuthEvent? { fresh.last ?? eventStore.first }

        for record in records {
            if record.isComputerAuthentication, !known.contains(record.clientName.lowercased()) {
                newComputer = true
            }
            let event = AuthEvent(id: nextEventID, time: record.time, accepted: record.accepted,
                                  username: record.user,
                                  client: ADAuthAudit.clientLabel(record, computers: computers),
                                  detail: ADAuthAudit.detail(record),
                                  source: .activeDirectory)
            if let previous = newest(), Self.coalesces(event, into: previous) {
                if fresh.isEmpty {
                    eventStore[0].repeats += 1
                    eventStore[0].time = event.time
                } else {
                    fresh[fresh.count - 1].repeats += 1
                    fresh[fresh.count - 1].time = event.time
                }
                eventsDirty = true
                continue
            }
            nextEventID += 1
            if Self.authTracing {
                print("[event] AD \(event.accepted ? "accept" : "reject") \(event.username) \(event.client) — \(event.detail)")
            }
            fresh.append(event)
        }
        if !fresh.isEmpty {
            // `fresh` is oldest-first and `eventStore` is newest-first, exactly as in `scanForAuth`.
            eventStore.insert(contentsOf: fresh.reversed(), at: 0)
            if eventStore.count > 500 { eventStore.removeLast(eventStore.count - 500) }
            eventsDirty = true
        }
        if eventsDirty { scheduleEventFlush() }

        let settings = applied.settings.ad
        Task { [weak self] in
            guard let self else { return }
            await self.ad.refreshFactsAfterAuth(settings, force: newComputer)
        }
    }

    /// `-adTrace 1` also prints each AD row as it joins the list.
    ///
    /// `./Tests/run.sh ad` cannot see `events` — the Status pane is inside a running app — so
    /// without this the suite could prove the domain controller logged an authentication and
    /// still not know whether the app *read* it, which is exactly the gap build 15 exists to
    /// close. Unbuffered for the same reason `ADController.tracing` is: stdout is fully
    /// buffered when it is not a terminal, and the suite reads the file while the app is still
    /// running. Setting it here as well costs nothing and removes the assumption that the
    /// controller's own first trace line came first.
    private static let authTracing: Bool = {
        let on = CommandLine.value(after: "-adTrace") == "1"
        if on { setvbuf(stdout, nil, _IONBF, 0) }
        return on
    }()

    /// Is `event` the same thing happening again, straight after `previous`?
    ///
    /// Deliberately **consecutive-only and unbounded in time**: iMaster's poll is one bind
    /// every thirty seconds, for ever, and a window short enough to leave those separate would
    /// leave the feed useless on the one screen it exists for. Anything else landing in between
    /// starts a new row, so a real login is never swallowed by the noise around it — and the
    /// two feeds never merge, because a RADIUS row and an AD row are two different observations
    /// of a login and both are worth seeing.
    nonisolated static func coalesces(_ event: AuthEvent, into previous: AuthEvent) -> Bool {
        event.source == .activeDirectory && previous.source == .activeDirectory
            && event.accepted == previous.accepted
            && event.username == previous.username
            && event.client == previous.client
            && event.detail == previous.detail
    }

    /// One `events` publish per 1/`publishesPerSecond` s, however many logins arrived.
    private func scheduleEventFlush() {
        guard !eventFlushPending else { return }
        eventFlushPending = true
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1000 / ServerProcess.publishesPerSecond))
            self?.flushEvents()
        }
    }

    private func flushEvents() {
        eventFlushPending = false
        guard eventsDirty else { return }
        eventsDirty = false
        events = eventStore
    }

    /// `(12)         Sheep-Rule += "NetAdmins on Wireless"` out of the `-xx` stream.
    ///
    /// This is the observability route, chosen over a `linelog` file and over putting anything
    /// on the wire. `Sheep-Rule` is written **only** inside an `update control` block and never
    /// appears in a generated condition, so an anchored match on the attribute name cannot
    /// pick up the `if (…)` line that mentions it. The debug stream is already read, line by
    /// line, for `Login OK:` — this adds no new file, no new module and no new attribute in
    /// any packet.
    nonisolated static func parseRuleHit(_ line: String) -> (request: Int, rule: String)? {
        guard let (number, rest) = requestNumber(line) else { return nil }
        let text = rest.trimmingCharacters(in: .whitespaces)
        let prefix = "\(SheepAttribute.rule) += \""
        guard text.hasPrefix(prefix), text.hasSuffix("\"") else { return nil }
        let value = String(text.dropFirst(prefix.count).dropLast())
        guard !value.isEmpty else { return nil }
        return (number, unescaped(value))
    }

    /// `(12) rest…` → `(12, "rest…")`. Every per-request debug line carries one.
    nonisolated static func requestNumber(_ line: String) -> (Int, Substring)? {
        guard line.hasPrefix("("), let close = line.firstIndex(of: ")") else { return nil }
        let digits = line[line.index(after: line.startIndex)..<close]
        guard !digits.isEmpty, let number = Int(digits) else { return nil }
        return (number, line[line.index(after: close)...])
    }

    /// The inverse of `RuleUnlang.quoted`, in one pass — `\\` before `\"` matters, and a
    /// two-substitution version gets a name containing both wrong.
    nonisolated static func unescaped(_ s: String) -> String {
        var out = ""
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            let next = s.index(after: i)
            if c == "\\", next < s.endIndex {
                switch s[next] {
                case "\\": out.append("\\")
                case "\"": out.append("\"")
                case "n": out.append("\n")
                case "r": out.append("\r")
                case "t": out.append("\t")
                default: out.append(s[next])
                }
                i = s.index(after: next)
                continue
            }
            if c == "%", next < s.endIndex, s[next] == "%" {
                out.append("%")
                i = s.index(after: next)
                continue
            }
            out.append(c)
            i = next
        }
        return out
    }

    /// Is `candidate` the outer verdict of the tunnelled session `inner` already recorded?
    ///
    /// Measured on 3.2.10 with eapol_test: the inner verdict always carries `via TLS tunnel`
    /// and comes first, the outer one never does and comes immediately after. The request
    /// number is the **same** for TTLS and one higher for PEAP — that pair of numbers is the
    /// tightest thing available, and it is what keeps two genuinely separate logins from the
    /// same station apart.
    nonisolated static func isOuterHalf(of inner: AuthEvent, following candidate: AuthEvent) -> Bool {
        guard inner.viaTunnel, !candidate.viaTunnel,
              inner.accepted == candidate.accepted,
              inner.client == candidate.client,
              let a = inner.request, let b = candidate.request,
              b == a || b == a + 1 else { return false }
        return true
    }

    nonisolated static func parseAuth(_ line: String, id: Int, now: Date = Date()) -> AuthEvent? {
        let accepted: Bool
        let verdict: Range<String.Index>
        if let r = line.range(of: "Login OK") { accepted = true; verdict = r }
        else if let r = line.range(of: "Login incorrect") { accepted = false; verdict = r }
        else { return nil }

        let rest = line[verdict.upperBound...]
        guard let open = rest.range(of: ": ["), let close = rest[open.upperBound...].range(of: "] (from client ") else { return nil }
        var user = String(rest[open.upperBound..<close.lowerBound])
        if let slash = user.range(of: "/<") { user = String(user[..<slash.lowerBound]) }

        var tail = String(rest[close.upperBound...])
        if tail.hasSuffix(")") { tail.removeLast() }
        let words = tail.split(separator: " ")
        let client = words.first.map(String.init) ?? "?"
        var detail: [String] = []
        let reason = rest[..<open.lowerBound].trimmingCharacters(in: CharacterSet(charactersIn: " ()"))
        if !reason.isEmpty { detail.append(reason) }
        if let cli = words.firstIndex(of: "cli"), words.indices.contains(cli + 1) { detail.append(String(words[cli + 1])) }
        let viaTunnel = tail.contains("via TLS tunnel")
        if viaTunnel { detail.append("inner tunnel") }
        return AuthEvent(id: id, time: now, accepted: accepted, username: user, client: client,
                         detail: detail.joined(separator: " · "), rules: [],
                         request: requestNumber(line)?.0, viaTunnel: viaTunnel)
    }

    /// The rules that fired for this user a moment ago, for the Test pane's verdict. Only
    /// meaningful for a test aimed at this Mac — the debug stream is the only source, and it
    /// belongs to our own radiusd.
    func recentRules(for username: String, within seconds: TimeInterval = 20) -> [String] {
        let cutoff = Date().addingTimeInterval(-seconds)
        guard let event = eventStore.first(where: { $0.username == username && $0.time >= cutoff }) else { return [] }
        return event.rules
    }

    /// True for the one line each virtual server prints when its copy of the rules is about
    /// to run: the inner tunnel's `Sheep-Handled := "yes"` (it sets the flag first thing) and
    /// the outer server's guard coming out TRUE. Exactly one of the two happens per login,
    /// which is the claim the inner/outer design rests on.
    nonisolated static func entersRuleBlock(_ line: String) -> Bool {
        guard let (_, rest) = requestNumber(line) else { return false }
        let text = rest.trimmingCharacters(in: .whitespaces)
        if text.hasSuffix("\(SheepAttribute.handled) := \"yes\"") { return true }
        return text.hasPrefix("if (!(&session-state:\(SheepAttribute.handled)))")
            && text.hasSuffix("-> TRUE")
    }

    /// `(4) eap_peap:   TLS-Session-Cipher-Suite = "ECDHE-RSA-AES256-GCM-SHA384"`.
    nonisolated static func parseCipherSuite(_ line: String) -> String? {
        guard let range = line.range(of: "TLS-Session-Cipher-Suite = \"") else { return nil }
        let rest = line[range.upperBound...]
        guard let close = rest.firstIndex(of: "\"") else { return nil }
        let value = String(rest[rest.startIndex..<close])
        return value.isEmpty ? nil : value
    }

    /// The cipher suite our own radiusd last negotiated, if it was recent enough to belong to
    /// the test that just ran.
    func recentCipherSuite(within seconds: TimeInterval = 20) -> String? {
        guard let (suite, time) = lastCipherSuite, time >= Date().addingTimeInterval(-seconds) else { return nil }
        return suite
    }
}

extension CommandLine {
    /// Launch arguments come in `-flag value` pairs (AppKit swallows an unpaired flag's neighbour).
    nonisolated static func value(after flag: String) -> String? {
        guard let i = arguments.firstIndex(of: flag), arguments.indices.contains(i + 1) else { return nil }
        return arguments[i + 1]
    }
}
