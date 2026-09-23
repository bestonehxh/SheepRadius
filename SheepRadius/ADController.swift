import Combine
import Foundation

/// One line of a sync or self-test run.
struct ADResultLine: Identifiable, Sendable {
    enum Outcome: Sendable { case ok, failed, skipped, info }
    let id: Int
    let outcome: Outcome
    let title: String
    let detail: String
    /// When it happened, rendered by `LogTime.clock` like every other clock in the app — a
    /// sync line that says nothing about *when* cannot be lined up against the Log pane, which
    /// is the first thing anybody does when a sync did not do what they expected.
    var time = Date()
}

/// A name the app wants that is already taken by an object it does not own. Surfaced with an
/// "Adopt" button instead of being resolved — `alice` and `bob` live in `CN=Users` on the real
/// volume, and silently moving or overwriting someone's hand-made account is not a thing a
/// lab tool gets to do on its own.
struct ADCollision: Identifiable, Sendable {
    var id: String { username }
    let username: String
    let existingDN: String
    /// A built-in account or something under CN=Builtin. Reported, never adoptable — moving
    /// one of those out of its container would be worse than the collision.
    var isProtected: Bool { ADProtectedObject.isProtected(dn: existingDN, name: username) }
}

/// The Samba AD DC, driven exactly like `ServerProcess` drives radiusd and slapd — same
/// running/stopped/failed vocabulary, same log, same switch in the sidebar — even though the
/// thing on the other end is a Linux VM this app does not own.
///
/// **The DC is not our child.** `container run -d` returns immediately and the container is
/// owned by the `container` user agent, so none of `ServerProcess`'s three layers apply
/// as-is. They are rebuilt here:
///
/// 1. `stop()` on a normal quit, from `AppModel.shutdownForQuit`.
/// 2. A **lifeline** `sh` holding a pipe this app has the only write end of. When the app dies
///    — Quit, crash, SIGKILL, Xcode's stop button — the kernel closes it, the `read` hits EOF
///    and the shell stops the container. `FD_CLOEXEC` on the write end is as load-bearing here
///    as it is in `ServerProcess`: without it radiusd's or slapd's wrapper inherits this one
///    and the DC outlives the app anyway.
/// 3. **Reaping** a `sheepad-dc` a previous unclean exit left behind, at launch and before
///    every start. Unlike the radiusd case there is no ambiguity about ownership: the name is
///    ours, and nothing else creates a container called that.
final class ADController: ObservableObject {
    enum State: Equatable {
        case stopped
        /// The step in progress, for the sidebar and the Status card.
        case starting(String)
        case running
        case failed(String)

        var isRunning: Bool { self == .running }
        var isBusy: Bool { if case .starting = self { return true }; return false }
    }

    @Published private(set) var state = State.stopped
    @Published private(set) var log: [LogLine] = []
    /// The DC container's address on the vmnet bridge — where the DNS relay forwards.
    @Published private(set) var containerIP: String?
    /// The Mac's address the DC advertises. Everything a device is told to type uses this.
    @Published private(set) var hostIP = "127.0.0.1"
    @Published private(set) var syncLines: [ADResultLine] = []
    @Published private(set) var collisions: [ADCollision] = []
    @Published private(set) var syncing = false
    @Published private(set) var checks: [ADResultLine] = []
    @Published private(set) var testing = false
    @Published private(set) var computers: [ADComputer] = []
    @Published private(set) var userFacts: [String: ADUserFacts] = [:]
    /// True when the last start found a state volume that already held a domain. The
    /// Administrator password is then the **domain's**, not whatever is typed in Settings, and
    /// the pane has to say so — `ADSettings.administratorPassword` is only ever *used* to
    /// provision, so editing it afterwards changes nothing in the domain.
    @Published private(set) var adoptedDomain = false
    /// The last bind-requiring step the domain refused the password for, if any. Cleared by a
    /// successful run of that step and by setting the domain's password from here.
    @Published private(set) var passwordRejected: ADBindStep?
    /// Set while `setDomainAdministratorPassword` is in flight, so the button can say so.
    @Published private(set) var settingPassword = false
    /// Ports **this process** is holding that a start needs — its own DNS relay, left over
    /// from a domain controller that has gone. Non-empty means "Release and retry" is the fix.
    @Published private(set) var selfHeldPorts: [String] = []

    // Prerequisites, refreshed by `refreshPrerequisites()`.
    @Published private(set) var systemRunning = false
    @Published private(set) var imageReference: String?
    @Published private(set) var volumeExists = false
    @Published private(set) var diskUsage = ""
    @Published private(set) var prerequisitesChecked = false
    /// **Known** to be missing — asked of a running container system and not listed. While the
    /// system is stopped (its resting state after every Stop) `imageReference` is nil because
    /// nobody could ask, which is not the same answer (build 32).
    var imageKnownMissing: Bool { prerequisitesChecked && systemRunning && imageReference == nil }

    /// The streamed installer/builder, reusing the card the Homebrew installer uses.
    let builder = ServerProcess(title: "container")
    /// Surfaces a failure in the app's single alert. A closure rather than a reference to
    /// `AppModel.shared`, because this object is created *inside* `AppModel.init`.
    var onError: ((String) -> Void)?
    /// The DC's own authentication events, one batch per read of the log stream. A closure for
    /// the same reason as `onError`, and because this controller deliberately knows nothing
    /// about `AppModel` — the Status pane's event list is the model's business, not the
    /// domain controller's. Shaped exactly like `ServerProcess.onLines`.
    var onAuth: (([ADAuthRecord]) -> Void)?

    private let relay = DNSRelay()
    private var lifeline: Pipe?
    private var lifelineProcess: Process?
    private var logFollower: Process?
    /// The drain that moves whole lines from the follower's buffer onto the main actor, and a
    /// counter that says which follower is the current one — see `followLog`.
    private var logDrain: Task<Void, Never>?
    private var followerGeneration = 0
    /// Notices a DC that went away without this app stopping it — see `startHealthWatch`.
    private var healthWatch: Task<Void, Never>?
    private var nextLineID = 0
    private var nextResultID = 0
    /// Twice `ServerProcess`'s ring, and for a reason rather than a taste: provisioning a
    /// domain prints well over a thousand lines in one burst, so at 4000 a first start left
    /// almost no room for the authentications the pane is opened to look at. The DC is not
    /// flood-prone the way radiusd is — nothing here answers ten thousand requests a second —
    /// so the memory is affordable where it would not be there.
    private let maxLines = 8000
    /// The unpublished side of `log`, exactly as in `ServerProcess` and for the same reason:
    /// `@Published` fires per mutation, and the container log follower delivers provisioning
    /// output in bursts of hundreds of lines.
    private var logBuffer: [LogLine] = []
    private var logFlushPending = false
    /// A `container logs -f` read can end mid-line; without this the tail of one line and the
    /// head of the next were logged as two separate lines.
    private var logPartial = ""
    /// Set when this start provisioned a brand-new domain, so the password policy is relaxed
    /// exactly once — never on an adopted volume, where it would be an unasked-for change.
    private var provisionedThisStart = false
    /// Whether this start got as far as `container run`. Only then does an unwind have a
    /// container of its own to remove.
    private var ranContainerThisStart = false
    /// **How many times this process has actually run `container run`** (build 23). Never
    /// reset, so it is a count and not a flag, and it is the probe's proof that the RADIUS
    /// switch did not boot a domain controller: a number that has not moved is a container
    /// that was never launched, provable without asking the `container` tool anything — which
    /// is what lets the live suite check it beside the owner's real DC.
    private(set) var containerRuns = 0
    /// When the per-user counters and the machine accounts were last re-read off the DC, so an
    /// authentication burst cannot turn into a burst of `container exec`. See
    /// `refreshFactsAfterAuth`.
    private var lastFactsRefresh: Date?

    private var tools: Toolchain
    private var env: LabEnvironment
    /// The `ad` suite points these at a throwaway container and volume.
    let containerName: String
    let volumeName: String

    init(tools: Toolchain, env: LabEnvironment,
         containerName: String = ADImage.containerName, volumeName: String = ADImage.volumeName) {
        self.tools = tools
        self.env = env
        self.containerName = containerName
        self.volumeName = volumeName
        relay.onLog = { [weak self] line in
            Task { @MainActor in self?.note(line) }
        }
    }

    func adopt(tools: Toolchain, env: LabEnvironment) {
        self.tools = tools
        self.env = env
    }

    var isRunning: Bool { state.isRunning }
    var relayIsRunning: Bool { relay.isRunning }

    // MARK: Prerequisites

    /// Cheap enough to run whenever the Directory pane appears: three `container` calls that
    /// touch nothing.
    func refreshPrerequisites() async {
        defer { prerequisitesChecked = true }
        guard let tool = tools.containerTool else {
            systemRunning = false
            imageReference = nil
            volumeExists = false
            return
        }
        let status = await Shell.run(tool, ["system", "status"], environment: [:])
        systemRunning = status.ok
        guard systemRunning else {
            // Every other query needs the API server, and asking would only print an error.
            imageReference = nil
            volumeExists = false
            return
        }
        let images = await Shell.run(tool, ["image", "list"], environment: [:])
        imageReference = Self.findImage(in: images.output)
        let volumes = await Shell.run(tool, ["volume", "list"], environment: [:])
        volumeExists = volumes.output.split(separator: "\n").dropFirst()
            .contains { $0.split(separator: " ").first.map(String.init) == volumeName }
    }

    /// Bring the **shared** container system up, if it is not already.
    ///
    /// `stop()` takes the system down when nothing else on the Mac is using it, which is the
    /// right thing for a lab tool that should leave no daemon behind. It also means that an
    /// export — which stops the domain controller first so the state volume is at rest — then
    /// finds `container image save` talking to a socket that is gone. The `ad` suite reported
    /// it as `XPC connection error: Connection invalid`.
    ///
    /// Returns false when `container` is not installed or refused to start, which the caller
    /// turns into a sentence rather than a stack trace.
    @discardableResult
    func ensureSystemRunning() async -> Bool {
        guard let tool = tools.containerTool else { return false }
        if await Shell.run(tool, ["system", "status"], environment: [:]).ok { return true }
        let started = await Shell.run(tool, ["system", "start", "--enable-kernel-install"],
                                      environment: [:])
        systemRunning = started.ok
        return started.ok
    }

    /// The newest `sheep-ad-dc` tag on this Mac, or nil. Running a build behind costs features
    /// — the TLS leaf, the DNS clean-up, the authentication log — never the domain, so it is a
    /// note and a "Rebuild image" button, not a refusal.
    nonisolated static func findImage(in listing: String) -> String? {
        var found: Set<String> = []
        for line in listing.split(separator: "\n").dropFirst() {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 2, fields[0] == ADImage.repository else { continue }
            found.insert(String(fields[1]))
        }
        guard let newest = ADImage.knownTags.first(where: { found.contains($0) }) else { return nil }
        return "\(ADImage.repository):\(newest)"
    }

    /// An image built from a Containerfile older than the one in this build. True is not a
    /// problem, it is an offer: `imageRebuildReason` says what it would buy.
    var imageIsOutdated: Bool {
        imageReference != nil && imageReference != ADImage.reference
    }

    var imageRebuildReason: String? { ADImage.rebuildReason(for: imageReference) }

    // MARK: Start

    func start(_ settings: ADSettings, sync doc: LabDocument? = nil) async {
        guard !isRunning, !state.isBusy else { return }
        guard let tool = tools.containerTool else {
            fail("Apple's `container` tool was not found. AD Domain mode needs it — install it with Homebrew from App ▸ Environment.")
            return
        }
        let problems = settings.problems
        guard problems.isEmpty else { fail(problems.joined(separator: "\n")); return }

        provisionedThisStart = false
        // **Must be reset here too.** It is the flag that authorises `container rm -f` in
        // `abandonStart`, and if a previous start left it set (the health watch used to stop
        // the DC without clearing it) an unwind would remove a container this start never
        // created — which is exactly how a dev instance destroyed the owner's live DC on
        // 18 Sep 2026. See PROJECT-STATUS §9.
        ranContainerThisStart = false
        hostIP = LocalNetwork.primaryIPv4() ?? "127.0.0.1"
        note("—— start AD domain \(settings.realm) · DC \(settings.dcFQDN) · host \(hostIP)")

        do {
            // 0. A relay bound to :53 with no container behind it would otherwise fail the
            //    port check below as if it were a stranger. This is the common case after a
            //    DC has been stopped or removed outside the app.
            if !(await containerIsRunning()) {
                releaseStaleRelay(reason: "there is no domain controller behind it")
            }

            // 1. Anything a previous unclean exit left behind, before a port is looked at.
            state = .starting("reclaiming a stale container")
            await reapStaleContainer(tool: tool)

            // 2. Ports, named owners and all.
            state = .starting("checking ports")
            try await preflightPorts()

            // 3. The relay, FIRST. After the first container starts, mDNSResponder owns :53.
            state = .starting("binding DNS on 0.0.0.0:53")
            try relay.start()

            // 4. The container system (a launchd user agent that does not restart by itself).
            state = .starting("starting the container system")
            let system = await Shell.run(tool, ["system", "start", "--enable-kernel-install"], environment: [:])
            guard system.ok else {
                throw LabEnvironment.Failure(message: "`container system start` failed:\n\(system.output.suffix(600))")
            }
            systemRunning = true

            // 5. The image and the volume. The volume is ADOPTED when it is already there —
            //    it holds the live domain, its machine accounts and its hand-made users.
            await refreshPrerequisites()
            guard let image = imageReference else {
                throw LabEnvironment.Failure(message: """
                The domain-controller image is not built yet.

                Open App ▸ Environment and press “Build image”. It takes a couple of minutes \
                and downloads Debian's arm64 base image and Samba's packages.
                """)
            }
            if let reason = ADImage.rebuildReason(for: image) {
                note("—— using \(image), which is a build behind \(ADImage.reference): \(reason)")
            }
            if !volumeExists {
                state = .starting("creating the state volume")
                let created = await Shell.run(tool, ["volume", "create", "-s", ADImage.volumeSize, volumeName], environment: [:])
                guard created.ok else {
                    throw LabEnvironment.Failure(message: "Could not create the state volume:\n\(created.output.suffix(400))")
                }
                note("—— created volume \(volumeName) (\(ADImage.volumeSize)); the domain will be provisioned on first start")
                provisionedThisStart = true
                adoptedDomain = false
                volumeExists = true
            } else {
                adoptedDomain = true
                note("—— adopting the existing volume \(volumeName); nothing in it is reprovisioned")
                note("—— this domain already exists: its Administrator password is whatever it was provisioned with, not what Settings says")
            }

            // 6. TLS material for Samba, from this lab's own CA.
            var extraEnvironment: [String: String] = [:]
            if image != ADImage.legacyReference {
                state = .starting("issuing the domain controller certificate")
                extraEnvironment = try await tlsEnvironment(settings)
            }

            // 7. The DC.
            //
            // The Administrator password and the DC's TLS private key go in through
            // `--env-file`, never `-e`: `-e KEY=VALUE` is an argument to the host-side
            // `container` process and `ps` shows it to every account on this Mac. The file is
            // created 0600 inside `run/` (itself 0700) and removed on every path out.
            state = .starting("starting the domain controller")
            let envFile = env.base.appendingPathComponent("run", isDirectory: true)
                .appendingPathComponent(".dc-env-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: envFile) }
            guard FileManager.default.createFile(
                atPath: envFile.path,
                contents: Data(settings.environmentFile(extraEnvironment: extraEnvironment).utf8),
                attributes: [.posixPermissions: 0o600]) else {
                throw LabEnvironment.Failure(message: "Could not write the domain controller's environment file.")
            }
            let arguments = settings.containerArguments(image: image, name: containerName,
                                                        volume: volumeName, hostIP: hostIP,
                                                        extraEnvironment: extraEnvironment,
                                                        envFile: envFile.path)
            let run = await Shell.run(tool, arguments, environment: [:])
            guard run.ok else {
                throw LabEnvironment.Failure(message: "`container run` failed:\n\(run.output.suffix(800))")
            }
            ranContainerThisStart = true
            containerRuns += 1
            startLifeline(tool: tool)
            followLog(tool: tool)

            // 8. Point the relay at it. A target file in the prototype; a property here.
            state = .starting("locating the container")
            guard let address = await waitForContainerIP(tool: tool) else {
                throw LabEnvironment.Failure(message: "The DC container started but never reported an address.")
            }
            containerIP = address
            relay.target = address
            note("—— DC container at \(address); DNS relay retargeted")

            // 9. Wait for LDAP. A first provision takes ~8 s from an empty volume.
            state = .starting("waiting for LDAP")
            guard await waitForLDAP(tool: tool) else {
                let tail = await Shell.run(tool, ["logs", "-n", "25", containerName], environment: [:])
                throw LabEnvironment.Failure(message: "The DC did not start answering on \(hostIP):389.\n\n\(tail.output.suffix(800))")
            }

            if provisionedThisStart {
                state = .starting("relaxing the password policy")
                let relaxed = await exec(["samba-tool"] + ADCommands.relaxPasswordPolicy)
                note(relaxed.ok ? "—— password policy relaxed for lab use (no complexity, no expiry)"
                                : "—— could not relax the password policy: \(relaxed.output.prefix(200))")
            }

            state = .running
            startHealthWatch()
            await enableAuthAuditIfNeeded(image: image)
            note("—— AD domain \(settings.realm) is up")
            await refreshDirectoryFacts(settings)
            if let doc { await self.sync(doc: doc, settings: settings) }
        } catch let failure as LabEnvironment.Failure {
            await abandonStart()
            fail(failure.message)
        } catch let failure as DNSRelay.Failure {
            await abandonStart()
            fail(failure.message)
        } catch {
            await abandonStart()
            fail(error.localizedDescription)
        }
    }

    /// Unwind a start that did not finish, touching **only** what this start created.
    ///
    /// Emphatically **not** `stop()`. `stop()` ends with `container system stop`, and a start
    /// that fails on its very first check — a port already held — has not created anything at
    /// all. Doing the full stop there took the shared container system down on 18 Sep 2026,
    /// turning a failed start into "the whole container runtime is off", which is a far harder
    /// thing to understand from the outside.
    private func abandonStart() async {
        healthWatch?.cancel()
        healthWatch = nil
        stopLogFollower()
        closeLifeline()
        relay.stop()
        containerIP = nil
        // Only what THIS start ran. A start that failed before `container run` has nothing to
        // remove, and whatever is under that name belongs to somebody else.
        if ranContainerThisStart, let tool = tools.containerTool {
            _ = await Shell.run(tool, ["rm", "-f", containerName], environment: [:])
            ranContainerThisStart = false
        }
        state = .stopped
    }

    /// DC → relay → `container system stop`, and the last step only when no container that is
    /// not ours is running: the system agent is shared, and stopping it under someone else's
    /// container would be rude in a way that is hard to debug.
    func stop(quiet: Bool = false) async {
        healthWatch?.cancel()
        healthWatch = nil
        guard let tool = tools.containerTool else { state = .stopped; return }
        if !quiet { note("—— stopping the AD domain") }
        stopLogFollower()
        let removed = await Shell.run(tool, ["rm", "-f", containerName], environment: [:])
        if removed.ok, !quiet { note("—— removed container \(containerName)") }
        ranContainerThisStart = false
        closeLifeline()
        relay.stop()
        containerIP = nil

        // The container system is **shared**. Stopping it is only ever right when nothing else
        // is using it — not another container, and not another copy of this app, which may be
        // between two of its own `container` calls at this exact moment.
        let listing = await Shell.run(tool, ["ls", "--format", "json"], environment: [:])
        let foreign = ADContainerList.parse(listing.output).filter { $0.isRunning && $0.id != containerName }
        let others = await Self.otherInstances()
        if foreign.isEmpty, others.isEmpty {
            let stopped = await Shell.run(tool, ["system", "stop"], environment: [:])
            if stopped.ok {
                systemRunning = false
                if !quiet { note("—— container system stopped; nothing of ours is left running") }
            }
        } else if !others.isEmpty {
            note("—— leaving the container system running: another SheepRadius is open (pid \(others.map(String.init).joined(separator: ", ")))")
        } else {
            note("—— leaving the container system running: \(foreign.map(\.id).joined(separator: ", ")) \(foreign.count == 1 ? "is" : "are") not ours")
        }
        state = .stopped
    }

    /// Synchronous best-effort, for `applicationWillTerminate`. The lifeline does the real
    /// work; closing it here only makes the shutdown prompt.
    func terminateNow() {
        healthWatch?.cancel()
        healthWatch = nil
        stopLogFollower()
        closeLifeline()
        relay.stop()
    }

    /// The Mac moved network. The machine account and the keytab are address-independent — the
    /// spike proved a join survives this — so only DNS has to be corrected, and the DC can do
    /// that itself without a restart.
    func hostAddressChanged(to address: String, settings: ADSettings) async {
        guard isRunning, address != hostIP else { return }
        note("—— this Mac's address changed \(hostIP) → \(address); re-pointing the domain's DNS")
        hostIP = address
        let result = await exec(["bash", "-c", "HOST_IP=\(address) /usr/local/sbin/fix-dns.sh 2>&1 | tail -20"])
        for line in result.output.split(separator: "\n") { note("   \(line)") }
        if !result.ok {
            note("—— fix-dns failed; restart AD mode to re-point DNS")
        }
    }

    // MARK: Ports

    /// Ports, named owners and all.
    ///
    /// Two special cases, both learned the hard way. 445 gets its own message because the
    /// answer is "switch File Sharing off", which nothing about a port number suggests. And a
    /// port held by **this process** is never a foreign obstacle: it is our own DNS relay, and
    /// saying "udp/53 is in use by SheepRadius (pid 42565)" to the person running SheepRadius
    /// is a dead end. That case is released and retried once, silently, before anything is
    /// reported.
    private func preflightPorts(mayReleaseOwnPorts: Bool = true) async throws {
        var busy: [String] = []
        var ours: [String] = []
        for (port, proto) in ADSettings.allPorts {
            guard let holder = await LabEnvironment.portHolder(port, protocol: proto) else { continue }
            if holder.isThisProcess {
                ours.append("\(proto.lowercased())/\(port)")
                continue
            }
            if port == 445, holder.command.contains("smbd") || holder.command.contains("launchd") {
                throw LabEnvironment.Failure(message: """
                AD mode cannot start: tcp/445 is held by macOS File Sharing (\(holder.description)).

                A domain controller has to own SMB on this Mac. Switch File Sharing off in \
                System Settings ▸ General ▸ Sharing, then start AD mode again.
                """)
            }
            busy.append("\(proto.lowercased())/\(port) — \(holder.description)")
        }

        if !ours.isEmpty {
            guard mayReleaseOwnPorts else {
                selfHeldPorts = ours
                throw LabEnvironment.Failure(message: """
                AD mode cannot start: \(ours.joined(separator: ", ")) \(ours.count == 1 ? "is" : "are") still held by **this app**.

                That is this app's own DNS relay, left bound after a domain controller went \
                away. Nothing outside SheepRadius is in the way. Press “Release and retry”, or \
                quit and reopen the app.
                """)
            }
            // The only thing in this process that binds one of these is the relay.
            releaseStaleRelay(reason: "it was still holding \(ours.joined(separator: ", ")) with no domain controller behind it")
            try await Task.sleep(for: .milliseconds(300))
            try await preflightPorts(mayReleaseOwnPorts: false)
            return
        }
        selfHeldPorts = []

        guard busy.isEmpty else {
            throw LabEnvironment.Failure(message: """
            AD mode cannot start: \(busy.count == 1 ? "a port it needs is" : "ports it needs are") already in use.

            \(busy.joined(separator: "\n"))

            The built-in OpenLDAP server uses 389 and 636 — switch the directory backend rather \
            than running both.
            """)
        }
    }

    /// Let go of every port this process holds for AD mode, so a start can be tried again.
    /// Wired to the "Release and retry" button on the failure.
    func releaseOwnPorts() {
        releaseStaleRelay(reason: "asked to release them")
        selfHeldPorts = []
    }

    // MARK: Lifeline, reaping, log

    /// `sh` that blocks on a pipe and stops the container when it reaches EOF. Three lines,
    /// no new binary, nothing to codesign — the same trade `ServerProcess` made.
    /// The third line is not decoration. `container logs -f <name>` is a child of the app, and
    /// macOS has no equivalent of `PR_SET_PDEATHSIG` — when the app is SIGKILLed that follower
    /// is reparented and stays, one per killed run, holding a pipe to nothing. It came out of
    /// the `ad` suite's own leftover check. The pattern names *our* container, so nothing else
    /// can match it.
    static let lifelineScript = """
    while IFS= read -r _; do :; done
    "$0" stop "$1" >/dev/null 2>&1
    "$0" rm -f "$1" >/dev/null 2>&1
    pkill -f "container logs -f $1" >/dev/null 2>&1
    exit 0
    """

    private func startLifeline(tool: String) {
        closeLifeline()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", Self.lifelineScript, tool, containerName]
        let pipe = Pipe()
        // Without FD_CLOEXEC the *other* servers' wrappers inherit this write end and hold it
        // open after the app is gone, which is precisely the bug this exists to prevent.
        _ = fcntl(pipe.fileHandleForWriting.fileDescriptor, F_SETFD, FD_CLOEXEC)
        process.standardInput = pipe.fileHandleForReading
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.environment = Shell.childEnvironment(adding: [:])
        do {
            try process.run()
            lifeline = pipe
            lifelineProcess = process
        } catch {
            note("—— could not start the lifeline: \(error.localizedDescription); the DC would survive a crash")
        }
    }

    private func closeLifeline() {
        try? lifeline?.fileHandleForWriting.close()
        lifeline = nil
        lifelineProcess = nil
    }

    /// At launch, before anything tries to bind a port. The lifeline covers a crash, but not
    /// the case where the *whole login session* went away with the container system still
    /// holding the DC — so this runs unconditionally, and is a no-op when the system is down.
    ///
    /// **Not when another copy of this app is open.** See `otherInstances()`.
    func reapAtLaunch() async {
        guard let tool = tools.containerTool else { return }
        let others = await Self.otherInstances()
        guard others.isEmpty else {
            note("—— another SheepRadius is running (pid \(others.map(String.init).joined(separator: ", "))); leaving \(containerName) and its log follower alone")
            return
        }
        // A log follower an earlier SIGKILL left behind holds no port, but "nothing of ours is
        // left running" is a promise this app makes, so it goes too.
        _ = await Shell.run("/usr/bin/pkill", ["-f", "container logs -f \(containerName)"], environment: [:])
        let status = await Shell.run(tool, ["system", "status"], environment: [:])
        guard status.ok else { return }
        await reapStaleContainer(tool: tool)
    }

    /// Every **other** SheepRadius process on this Mac.
    ///
    /// This exists because of a real incident on 18 Sep 2026. A development copy was launched
    /// with `-demoBackend ad` and no `-adTest 1`, so it used the production container name; its
    /// launch-time reap found the *owner's live domain controller* under that name and removed
    /// it, out from under the installed app that was serving it, while a NAC was being
    /// configured against it. The container name alone does **not** establish ownership — it
    /// establishes only that some copy of this app made it, and "some copy" may be running.
    ///
    /// `pgrep -x` matches the executable name, which is `SheepRadius` for the installed .app
    /// and for a Debug build alike, so a development instance sees the installed one and stays
    /// its hands.
    static func otherInstances() async -> [Int32] {
        let found = await Shell.run("/usr/bin/pgrep", ["-x", "SheepRadius"], environment: [:])
        let mine = ProcessInfo.processInfo.processIdentifier
        return found.output.split(whereSeparator: \.isNewline)
            .compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
            .filter { $0 != mine }
    }

    /// Remove a leftover container of ours — **only** one that is not running.
    ///
    /// A *running* `sheepad-dc` is somebody's live domain: this app's own from a previous run
    /// that leaked (in which case its ports are held and the preflight will say so), or another
    /// instance's. Neither is a thing to delete on the way past. A stopped one holds nothing
    /// and cannot be anybody's working DC, so that is the only case reclaimed automatically.
    private func reapStaleContainer(tool: String) async {
        let listing = await Shell.run(tool, ["ls", "--all", "--format", "json"], environment: [:])
        guard let existing = ADContainerList.parse(listing.output).first(where: { $0.id == containerName }) else { return }
        guard !existing.isRunning else {
            note("—— \(containerName) is already running; leaving it alone (this app never removes a running domain controller it did not just start)")
            return
        }
        let removed = await Shell.run(tool, ["rm", "-f", containerName], environment: [:])
        if removed.ok { note("—— reclaimed a stopped \(containerName) left by a previous run") }
    }

    /// The DNS relay outlives its domain controller, and that is a bug when the DC has gone.
    ///
    /// The relay binds 0.0.0.0:53 **before** the first container starts, because macOS's vmnet
    /// DNS proxy takes the port otherwise and will not give it back. Nothing released it when
    /// the container disappeared without the app stopping it — so the app sat holding :53 with
    /// no DC behind it, and the next start's port check reported *itself* as the obstacle.
    private func releaseStaleRelay(reason: String) {
        guard relay.isRunning else { return }
        relay.stop()
        containerIP = nil
        note("—— released this app's DNS relay on :53 (\(reason))")
    }

    /// Has the container gone out from under us? Called before a start and on a timer while
    /// running, so an externally removed or crashed DC cannot leave the app claiming to run one
    /// — and, more to the point, cannot leave :53 bound with nothing behind it.
    func containerIsRunning() async -> Bool {
        guard let tool = tools.containerTool else { return false }
        let listing = await Shell.run(tool, ["ls", "--format", "json"], environment: [:])
        // **A failed `container ls` is not an answer.** The system agent restarting, or an XPC
        // error while it does, used to read as "the domain controller is gone" — so the health
        // watch tore down a DC that was serving perfectly well. Only a listing that actually
        // came back may say no.
        guard listing.ok else { return true }
        return ADContainerList.parse(listing.output).contains { $0.id == containerName && $0.isRunning }
    }

    private func startHealthWatch() {
        healthWatch?.cancel()
        healthWatch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard let self, self.isRunning else { return }
                guard await self.containerIsRunning() == false else { continue }
                self.note("—— the domain controller \(self.containerName) is no longer running; it was stopped or removed outside this app")
                self.releaseStaleRelay(reason: "its domain controller is gone")
                self.closeLifeline()
                self.stopLogFollower()
                self.containerIP = nil
                // The container this start ran is gone — so a later unwind must not claim it.
                // Leaving this set is what let `abandonStart` run `container rm -f` against a
                // DC it had not created.
                self.ranContainerThisStart = false
                self.state = .stopped
                return
            }
        }
    }

    /// Attach to `container logs -f <dc>` and keep the app's copy of the DC's output current.
    ///
    /// **Built like `ServerProcess`, and for the same two reasons** — build 16 found this the
    /// hard way after the owner reported that lines "don't reach the window":
    ///
    /// 1. `readabilityHandler` runs on a dispatch queue, and the first version hopped to the
    ///    main actor with a `Task { @MainActor … }` **per read**. Those tasks are not ordered
    ///    with respect to each other, so two reads in quick succession — which is exactly what
    ///    a provisioning burst is — could be appended in the wrong order, and the partial-line
    ///    carry-over between them was then spliced across the wrong halves. A `ServerLineBuffer`
    ///    takes a lock on the reader's own queue and hands over **whole lines in order**; the
    ///    main actor collects them ten times a second, as it does for radiusd and slapd.
    /// 2. The old handler cleared itself on EOF and nothing ever attached again. `container
    ///    logs -f` ends on its own — the container CLI drops the stream when the container
    ///    system is restarted, and any `container logs` the user runs in a terminal can end it
    ///    too — and from that moment the pane was silently frozen for the rest of the app's
    ///    life while the DC went on serving. Now the end of the stream is noticed and, while
    ///    the container is still running, followed by a fresh attach.
    ///
    /// And one that is not like `ServerProcess` at all. **The follower runs on a pseudo-terminal.**
    /// Apple's `container` is a Swift program, and Swift's `print` writes through a `FILE*`
    /// that is *block*-buffered whenever stdout is a pipe: measured on this Mac while build 16
    /// was written, five lines printed 0.4 s apart came out of a pipe together, at exit. That
    /// is the whole of the owner's "the lines don't reach the window" — radiusd and slapd flush
    /// per line, so their panes were live, and the DC's was a stream nobody was flushing. With
    /// `/usr/bin/script` between us and the CLI its stdout is a terminal, the same `print`
    /// becomes line-buffered, and the lines arrive as they are written (measured the same way:
    /// 0.4 s apart). `TerminalText.clean` takes the `\r` and the CLI's cursor escapes back off.
    private func followLog(tool: String, reattachedAfter note: String? = nil) {
        stopLogFollower()
        followerGeneration += 1
        let generation = followerGeneration
        let process = Process()
        let follow = [tool, "logs", "-f", containerName]
        if FileManager.default.isExecutableFile(atPath: Self.ptyTool) {
            process.executableURL = URL(fileURLWithPath: Self.ptyTool)
            // `script -q /dev/null <command>`: quiet, no typescript file, run this.
            process.arguments = ["-q", "/dev/null"] + follow
        } else {
            // No pty available. The stream then arrives in whatever chunks the CLI decides to
            // flush, which is late but never wrong — better than no log at all.
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = Array(follow.dropFirst())
        }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        // **`/dev/null`, never the app's own stdin.** `script` copies the terminal settings of
        // *its* stdin before it allocates the pty for the child, and an inherited descriptor
        // it cannot `tcgetattr` is fatal: measured on this Mac, stdin = a socket makes
        // `/usr/bin/script -q /dev/null …` exit 1 with `tcgetattr/ioctl: Operation not
        // supported on socket` and run nothing at all, while stdin = /dev/null works and the
        // child gets a real tty. An app launched from a terminal inherits a tty and an app
        // launched from Finder inherits /dev/null, so both were fine — but launched by any
        // automation that hands it a socketpair, the domain controller's log pane stayed
        // empty for the whole session, with no error anywhere a person would look. And
        // without the pty the CLI's Swift `print` goes back to block-buffering, which is the
        // entire reason `script` is here.
        process.standardInput = FileHandle.nullDevice
        process.environment = Shell.childEnvironment(adding: [:])
        let buffer = ServerLineBuffer()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                buffer.finish()
            } else {
                buffer.ingest(data)
            }
        }
        do {
            try process.run()
        } catch {
            self.note("—— could not follow the container log: \(error.localizedDescription)")
            return
        }
        logFollower = process
        if let note { self.note("—— \(note)") }
        logDrain = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(1000 / ServerProcess.publishesPerSecond))
                guard let self, self.followerGeneration == generation else { return }
                let lines = buffer.drain()
                if !lines.isEmpty { self.ingest(lines: lines) }
                if lines.isEmpty, buffer.isFinished { break }
            }
            guard let self, self.followerGeneration == generation else { return }
            await self.followerEnded(generation: generation)
        }
    }

    /// The follower's stream ended. If the domain controller is still up, that is a dropped
    /// connection to a live log, not the end of anything — attach again.
    private func followerEnded(generation: Int) async {
        guard followerGeneration == generation, isRunning else { return }
        guard let tool = tools.containerTool, await containerIsRunning() else { return }
        guard followerGeneration == generation else { return }
        followLog(tool: tool, reattachedAfter: "the log stream from \(containerName) ended while it is still running; following it again")
    }

    /// Whole lines, in order, from whichever follower is current.
    ///
    /// This is also where the DC's authentication events enter the app: the `container logs -f`
    /// stream is the only place they exist, and the whole of it already passes through here.
    /// The records go out through `onAuth` in **one batch per read**, never one per line —
    /// build 12's lesson about `@Published` and a log stream applies here exactly as it does to
    /// radiusd's.
    private func ingest(lines: [String]) {
        var records: [ADAuthRecord] = []
        for raw in lines {
            let line = TerminalText.clean(raw)
            // A line that was nothing but the terminal's own escapes is not a line.
            guard !line.isEmpty || raw.isEmpty else { continue }
            note(line)
            if let record = ADAuthAudit.parse(line) { records.append(record) }
        }
        if !records.isEmpty { onAuth?(records) }
    }

    /// macOS's own pty wrapper. Present on every Mac; checked for anyway, because a missing
    /// one must degrade to a late log rather than to no log.
    static let ptyTool = "/usr/bin/script"

    /// The same, from a blob of text that may end mid-line — `-demoADEvents 1` and the unit
    /// tests come in here, and so did the old follower.
    func ingestFollowedLog(_ text: String) {
        logPartial += text
        guard let lastNewline = logPartial.lastIndex(of: "\n") else { return }
        let whole = logPartial[logPartial.startIndex..<lastNewline]
        logPartial = String(logPartial[logPartial.index(after: lastNewline)...])
        ingest(lines: whole.split(separator: "\n", omittingEmptySubsequences: false).map(String.init))
    }

    /// Samba's auth audit, pushed into a DC whose image was built before build 15 put it in
    /// `smb.conf`. Best effort and said out loud: the level is lost on the next restart, so
    /// the sentence names the rebuild as the real fix.
    private func enableAuthAuditIfNeeded(image: String) async {
        guard image != ADImage.reference else { return }
        let result = await exec(ADCommands.enableAuthAudit)
        if result.ok {
            note("—— turned Samba's authentication audit on in the running domain controller (log level \(ADCommands.authAuditLogLevel)); this is lost when it restarts — rebuild the image to \(ADImage.reference) to keep it")
        } else {
            note("—— could not turn the authentication audit on in this \(image) domain controller: \(result.output.prefix(200))")
        }
    }

    /// Re-read the counters the Users inspector shows, and the machine accounts, after an
    /// authentication the app has just seen.
    ///
    /// **Throttled.** Each call is two `container exec` round trips into the DC, and iMaster
    /// binds every thirty seconds while a Wi-Fi test can produce a burst; at one refresh per
    /// event this would be a steady drip of subprocesses for numbers nobody is watching change
    /// second by second.
    func refreshFactsAfterAuth(_ settings: ADSettings, force: Bool = false) async {
        guard isRunning else { return }
        let now = Date()
        if !force, let last = lastFactsRefresh, now.timeIntervalSince(last) < Self.factsRefreshInterval { return }
        lastFactsRefresh = now
        await refreshDirectoryFacts(settings)
    }

    /// Ten seconds, which is the figure in the build-15 brief and about as often as a person
    /// can read a changing number anyway.
    static let factsRefreshInterval: TimeInterval = 10

    private func stopLogFollower() {
        // The generation is what tells an in-flight drain that it is no longer the follower;
        // without it a cancelled task's last drain could re-enter `followerEnded` and attach a
        // second follower beside the new one.
        followerGeneration += 1
        logDrain?.cancel()
        logDrain = nil
        logFollower?.terminate()
        logFollower = nil
        logPartial = ""
    }

    // MARK: Waiting

    private func waitForContainerIP(tool: String) async -> String? {
        for _ in 0..<60 {
            let listing = await Shell.run(tool, ["ls", "--format", "json"], environment: [:])
            if let row = ADContainerList.parse(listing.output).first(where: { $0.id == containerName }),
               let ip = row.ipv4, !ip.isEmpty {
                return ip
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return nil
    }

    /// Anonymous rootDSE from inside the DC. The container runtime's host port proxy can accept
    /// TCP while its bridge forwarding is still unavailable; probing through that socket made
    /// the UI spin forever even though Samba was already serving LDAP inside the container.
    ///
    /// The published host/LAN reachability remains covered by the AD self-test's port checks;
    /// readiness only decides whether the DC itself has finished starting.
    ///
    /// **Both timeouts are load-bearing.** `container` publishes a port by proxying it, so the
    /// host socket accepts long before anything inside the container listens — a plain
    /// `ldapsearch` against it does not fail, it **blocks forever**, and the first run of this
    /// code sat in exactly that state through a whole provision. `NetProbe.canConnect` keeps
    /// the common case fast and `-o nettimeout` is the belt to its braces.
    private func waitForLDAP(tool: String) async -> Bool {
        for attempt in 0..<300 {
            let listing = await Shell.run(tool, ["ls", "--format", "json"], environment: [:])
            guard ADContainerList.parse(listing.output).contains(where: { $0.id == containerName && $0.isRunning }) else {
                return false                       // the container exited; the caller prints its log
            }
            let probe = await Shell.run(tool,
                                        ["exec", containerName, "ldapsearch", "-x",
                                         "-o", "nettimeout=5", "-o", "timeout=5",
                                         "-H", "ldap://127.0.0.1:389", "-s", "base", "-b", "",
                                         "defaultNamingContext"], environment: [:])
            if probe.output.lowercased().contains("defaultnamingcontext:") { return true }
            if attempt == 20 { note("—— still waiting for the DC (a first provision takes about a minute)") }
            try? await Task.sleep(for: .seconds(1))
        }
        return false
    }

    // MARK: TLS

    private func tlsEnvironment(_ settings: ADSettings) async throws -> [String: String] {
        try await env.ensureCertificates(serverName: settings.dcFQDN)
        if let reason = try await env.ensureADCertificate(settings: settings, serverName: settings.dcFQDN,
                                                          addresses: LocalNetwork.allIPv4().map(\.ip)) {
            note("—— \(reason)")
        }
        func encoded(_ url: URL) throws -> String {
            guard let data = try? Data(contentsOf: url) else {
                throw LabEnvironment.Failure(message: "Could not read \(url.lastPathComponent) for the DC's TLS configuration.")
            }
            return data.base64EncodedString()
        }
        return ["TLS_CERT_B64": try encoded(env.adPEM),
                "TLS_KEY_B64": try encoded(env.adKey),
                "TLS_CA_B64": try encoded(env.caPEM)]
    }

    // MARK: Executing inside the DC

    @discardableResult
    func exec(_ argv: [String]) async -> Shell.Result {
        guard let tool = tools.containerTool else { return .init(status: -1, output: "container not found") }
        return await Shell.run(tool, ["exec", containerName] + argv, environment: [:])
    }

    /// The same, for a command that takes its secret on stdin.
    ///
    /// `-i` is load-bearing and has to come before the container id: without it the script's
    /// `read` sees EOF at once and the password becomes empty.
    func exec(_ command: ADCommand) async -> Shell.Result {
        guard let stdin = command.stdin else { return await exec(command.argv) }
        guard let tool = tools.containerTool else { return .init(status: -1, output: "container not found") }
        return await Shell.run(tool, ["exec", "-i", containerName] + command.argv,
                               input: stdin, environment: [:])
    }

    // MARK: Sync

    /// Reconcile the app's table into the directory, one planned operation at a time, with a
    /// line in the log for each. Nothing outside `OU=SheepRadius` can be deleted — that is
    /// `ADPlan`'s guarantee, not this runner's, and it is the reason the runner may be this
    /// simple.
    func sync(doc: LabDocument, settings: ADSettings) async {
        // Pressing a button and getting nothing at all is the one outcome this pane may never
        // produce. Every refusal says why, in the same log the successful runs write to.
        if let refusal = ADSyncGate.refusal(isRunning: isRunning, syncing: syncing) {
            // Appended, not replacing: when a sync is already running its lines are what the
            // person is watching, and wiping them to say "already running" would be perverse.
            if !syncing { syncLines.removeAll(); collisions.removeAll() }
            result(.skipped, "Sync did not run", refusal)
            return
        }
        syncing = true
        defer { syncing = false }
        syncLines.removeAll()
        collisions.removeAll()
        if adoptedDomain {
            result(.info, "This domain was adopted, not created here",
                   "The volume \(volumeName) already held \(settings.realm). Users, groups and OUs are reconciled as usual — none of that authenticates — but anything that binds (the self-test's kinit, LDAP bind, SMB and DNS zone checks) needs the Administrator password the domain already has.")
        }

        let existing = await readDirectory(settings)
        // The managed root is a *precondition*, not part of the reconcile: every operation the
        // planner emits lives under it, so on a domain this app has never touched — including
        // one it just provisioned — the whole plan fails with "parent does not exist".
        if !existing.contains(where: { $0.kind == .organizationalUnit
                                       && $0.dn.caseInsensitiveCompare(settings.managedRootDN) == .orderedSame }) {
            let created = await exec(["samba-tool", "ou", "create", settings.managedRootDN])
            result(created.ok ? .ok : .failed, "create the managed OU \(settings.managedRootDN)",
                   created.ok ? "everything this app owns lives under it" : Self.firstError(in: created.output))
            guard created.ok else { return }
        }
        let plan = ADPlan.make(doc: doc, existing: existing, settings: settings)
        guard !plan.isEmpty else {
            result(.info, "Nothing to do — the domain already matches the app's table.", "")
            return
        }

        var passwords: [String: String] = [:]
        for user in doc.users { passwords[user.username.lowercased()] = user.password }
        var knownDNs: [String: String] = [:]
        for object in existing {
            let name = (object.sAMAccountName ?? ADPlan.cn(of: object.dn)).lowercased()
            knownDNs[name] = object.dn
        }

        for operation in plan {
            // A group AD already owns. Reported and nothing else — not adoptable, because
            // moving `CN=Guests,CN=Builtin` would be far worse than the collision, and not
            // writable, because `samba-tool group addmembers` resolves a bare name across the
            // whole domain. See ADProtectedObject.groupNames for what this cost on 18 Sep 2026.
            if case .groupCollision(_, let dn) = operation {
                result(.failed, operation.summary,
                       "That is a built-in AD group — rename the group in this app (\"Visitors\" instead of \"Guests\", for instance). Nothing was written to it. A group name is unique across the whole domain, so adding members to a group of this name would put real users into \(dn).")
                continue
            }
            if case .collision(let username, let dn) = operation {
                let collision = ADCollision(username: username, existingDN: dn)
                collisions.append(collision)
                result(.skipped, operation.summary,
                       collision.isProtected
                       ? "That is a built-in account. It cannot be adopted and will not be touched — rename the user in this app instead."
                       : "The app will not create a second \(username) and will not overwrite this one. Adopt it to manage it from here.")
                continue
            }
            var failed = false
            for command in ADCommands.commands(for: operation, settings: settings,
                                               passwords: passwords, knownDNs: knownDNs) {
                let run = await exec(command)
                if !run.ok {
                    failed = true
                    result(.failed, command.summary, Self.firstError(in: run.output))
                    break
                }
            }
            if !failed { result(.ok, operation.summary, "") }
        }
        await refreshDirectoryFacts(settings)
    }

    /// Move a colliding object into the managed root, on an explicit button press.
    func adopt(_ collision: ADCollision, into ou: String, settings: ADSettings) async {
        guard isRunning, !collision.isProtected else { return }
        let command = ADCommands.adopt(username: collision.username, into: ou, settings: settings)
        let run = await exec(command.argv)
        if run.ok {
            result(.ok, command.summary, "It is now under \(settings.managedRootDN) and the next sync will manage it.")
            collisions.removeAll { $0.username == collision.username }
        } else {
            result(.failed, command.summary, Self.firstError(in: run.output))
        }
    }

    func readDirectory(_ settings: ADSettings) async -> [ADObject] {
        let listing = await exec(ADCommands.readDirectory(settings: settings))
        guard listing.ok else {
            note("—— could not read the directory: \(listing.output.prefix(300))")
            return []
        }
        return ADLDIF.parse(listing.output).compactMap { ADObject.from(ldif: $0) }
    }

    /// The joined computers and the per-user counters, both read straight off the DC.
    func refreshDirectoryFacts(_ settings: ADSettings) async {
        guard isRunning else { return }
        let machines = await exec(ADCommands.readComputers(settings: settings))
        if machines.ok {
            computers = ADLDIF.parse(machines.output).compactMap { ADComputer.from(ldif: $0) }
                .sorted { $0.name < $1.name }
        }
        let facts = await exec(ADCommands.readUserFacts(settings: settings))
        if facts.ok {
            var out: [String: ADUserFacts] = [:]
            for record in ADLDIF.parse(facts.output) {
                guard let name = ADLDIF.first(record, "sAMAccountName") else { continue }
                out[name.lowercased()] = ADUserFacts.from(ldif: record)
            }
            userFacts = out
        }
    }

    // MARK: Self-test

    /// The same checks that were run by hand against the Windows notebook, in the same order,
    /// because that order is diagnostic: DNS first (it is nearly always DNS), then discovery,
    /// then the ports, then the three protocols a join actually uses.
    func runSelfTest(_ settings: ADSettings) async {
        guard !testing else { return }
        testing = true
        defer { testing = false }
        checks.removeAll()
        let address = hostIP
        let realm = settings.realm

        // 1. DNS, over UDP, from the LAN address a device would use.
        for record in ADDNSHygiene.joinCriticalRecords(realm: realm, dcHostname: settings.dcHostname) {
            let answer = await dig(["@\(address)", "-t", record.type, record.name, "+short", "+time=2", "+tries=1"])
            let lines = answer.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
            if lines.isEmpty {
                result(.failed, "DNS \(record.type) \(record.name)", "no answer from \(address)")
                continue
            }
            if record.type == "A" {
                let stale = ADDNSHygiene.staleAddresses(in: lines, hostIP: address)
                if stale.isEmpty {
                    result(.ok, "DNS A \(record.name)", address)
                } else {
                    result(.failed, "DNS A \(record.name)",
                           "answers \(stale.joined(separator: ", ")) — a LAN device cannot reach \(ADDNSHygiene.isUnreachableFromLAN(stale[0]) ? "that address" : "it")")
                }
            } else {
                result(lines.contains { $0.lowercased().contains(settings.dcHostname.lowercased()) } ? .ok : .failed,
                       "DNS \(record.type) \(record.name)", lines.joined(separator: " · "))
            }
        }

        // 2. DNS over TCP — a large SRV answer falls back to it and a broken relay shows here.
        let overTCP = await dig(["@\(address)", "+tcp", "+short", "-t", "SRV", "_kerberos._tcp.\(realm)", "+time=2"])
        result(overTCP.contains(settings.dcHostname) ? .ok : .failed, "DNS over TCP", overTCP.split(separator: "\n").first.map(String.init) ?? "no answer")

        // 3. CLDAP netlogon on udp/389 — what Windows uses to *choose* a DC. TCP 389 being
        //    open says nothing about this, and this is what fails when discovery fails.
        let query = CLDAP.netlogonQuery(realm: realm)
        if let reply = NetProbe.exchange(address, 389, payload: query, timeout: 3) {
            result(CLDAP.isNetlogonReply(reply) ? .ok : .failed, "CLDAP netlogon ping (udp/389)",
                   "\(reply.count)-byte reply")
        } else {
            result(.failed, "CLDAP netlogon ping (udp/389)", "no reply within 3s")
        }

        // 4. The ports a join opens, including the first RPC port.
        for port in ADSettings.tcpPorts.filter({ $0 != 3269 }) + [53, ADSettings.rpcPorts[0]] {
            let open = NetProbe.canConnect(address, port, timeout: 2)
            result(open ? .ok : .failed, "tcp/\(port) reachable at \(address)", open ? "" : "connect refused or timed out")
        }

        // 5–8 are the only steps that present the Administrator password to the domain. On an
        //      adopted domain they are the ones that fail when the password in Settings is not
        //      the one the domain has, and they say so in those words — see `ADBindStep`.
        passwordRejected = nil
        await checkKerberos(settings, address: address)
        await checkLDAPBind(settings, address: address)
        await checkSMB(settings)
        await checkZoneHygiene(settings, address: address)
        if passwordRejected != nil, adoptedDomain {
            result(.info, "This domain was adopted from \(volumeName)",
                   "The checks above that failed are the ones that authenticate. The Administrator password in Settings is not the one this domain has — either type the domain's password, or use the button in the Directory pane to set the domain's password to the one in Settings.")
        }
    }

    /// Re-run one bind-requiring step on its own — what the "set the password" button does
    /// after it has changed the password, so the person sees the step that failed succeed
    /// rather than having to find the button that runs it again.
    func rerun(_ step: ADBindStep, settings: ADSettings) async {
        guard isRunning, !testing else { return }
        testing = true
        defer { testing = false }
        checks.removeAll()
        let address = hostIP
        switch step {
        case .kerberos: await checkKerberos(settings, address: address)
        case .ldapBind: await checkLDAPBind(settings, address: address)
        case .smb: await checkSMB(settings)
        case .dnsZone: await checkZoneHygiene(settings, address: address)
        }
    }

    /// Records a failure as "the domain rejected the password" when that is what it was, and
    /// returns the detail line to print. The two things are one function because forgetting
    /// the first half while writing the second is exactly how this feature would rot.
    private func bindOutcome(_ step: ADBindStep, ok: Bool, output: String,
                             realm: String, success: String) -> (ADResultLine.Outcome, String) {
        if ok {
            if passwordRejected == step { passwordRejected = nil }
            return (.ok, success)
        }
        if ADCredentialCheck.isCredentialFailure(output) { passwordRejected = step }
        return (.failed, ADCredentialCheck.detail(step: step, output: output, realm: realm))
    }

    /// LDAP simple bind as a domain user, with the bundled client.
    private func checkLDAPBind(_ settings: ADSettings, address: String) async {
        guard let ldapwhoami = tools.ldapwhoami else { return }
        // `-y <file>`, not `-w <password>`: this one runs on the **host**, so `-w` put the
        // domain Administrator password straight into this Mac's process list. The OpenLDAP
        // tools have taken a password file for exactly this reason since forever, and the
        // Directory panes already used it — the self-test did not.
        guard let passwordFile = DirectoryPasswordFile(settings.administratorPassword,
                                                       in: env.base.appendingPathComponent("run", isDirectory: true)) else {
            result(.skipped, "LDAP simple bind as Administrator@\(settings.realm)",
                   "could not write the password file in the lab folder")
            return
        }
        defer { passwordFile.remove() }
        let bind = await Shell.run(ldapwhoami,
                                   ["-x", "-o", "nettimeout=5", "-o", "timeout=5",
                                    "-H", "ldap://\(address):389",
                                    "-D", "Administrator@\(settings.realm)", "-y", passwordFile.url.path],
                                   environment: tools.childEnvironment)
        let (outcome, detail) = bindOutcome(.ldapBind, ok: bind.ok, output: bind.output,
                                            realm: settings.realm,
                                            success: bind.output.trimmingCharacters(in: .whitespacesAndNewlines)
                                                .prefix(160).description)
        result(outcome, "LDAP simple bind as Administrator@\(settings.realm)", detail)
    }

    /// SMB, from inside the DC — a share list is the cheapest proof 445 serves.
    private func checkSMB(_ settings: ADSettings) async {
        let shares = await exec(ADCommands.shareList(settings: settings))
        let ok = shares.output.contains("sysvol")
        let (outcome, detail) = bindOutcome(.smb, ok: ok, output: shares.output,
                                            realm: settings.realm,
                                            success: "sysvol and netlogon are shared")
        result(outcome, "SMB share list", outcome == .failed && !ADCredentialCheck.isCredentialFailure(shares.output)
               ? Self.firstError(in: shares.output) : detail)
    }

    private func checkKerberos(_ settings: ADSettings, address: String) async {
        let directory = env.base.appendingPathComponent("run/krb", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let configuration = directory.appendingPathComponent("krb5.conf")
        let cache = directory.appendingPathComponent("ccache")
        try? FileManager.default.removeItem(at: cache)
        do {
            try Data(ADKerberos.configuration(realm: settings.realm, address: address).utf8)
                .write(to: configuration, options: .atomic)
        } catch {
            result(.failed, "kinit Administrator@\(settings.realm.uppercased())", error.localizedDescription)
            return
        }
        let environment = ["KRB5_CONFIG": configuration.path, "KRB5CCNAME": "FILE:\(cache.path)"]
        let kinit = await Shell.run("/usr/bin/kinit", ["--password-file=STDIN", "Administrator@\(settings.realm.uppercased())"],
                                    input: settings.administratorPassword + "\n", environment: environment)
        let (outcome, detail) = bindOutcome(.kerberos, ok: kinit.ok, output: kinit.output,
                                            realm: settings.realm,
                                            success: "TGT issued (kdc = tcp/\(address):88)")
        result(outcome, "kinit Administrator@\(settings.realm.uppercased())", detail)
    }

    /// Every DC-owned name, one query each. A LAN client handed the vmnet bridge address or
    /// an IPv6 ULA cannot reach the DC at all, and the error it reports never mentions DNS —
    /// `gc._msdcs` pointing at 192.168.64.1 is exactly how the first real join was broken.
    private func checkZoneHygiene(_ settings: ADSettings, address: String) async {
        var stale: [String] = []
        var read = 0
        var rejected = ""
        for name in ADDNSHygiene.repointedNames(dcHostname: settings.dcHostname) {
            let dump = await exec(ADCommands.zoneQuery(name: name, settings: settings))
            guard dump.ok else {
                // `samba-tool dns query` is the one zone read that authenticates, so a bad
                // password looks like "could not read the zone" unless it is named here.
                if ADCredentialCheck.isCredentialFailure(dump.output) { rejected = dump.output }
                continue
            }
            read += 1
            for record in ADDNSHygiene.addresses(inZoneDump: dump.output)
            where record.type == "AAAA" || record.value != address {
                stale.append("\(name) \(record.type) \(record.value)")
            }
        }
        guard read > 0 else {
            if !rejected.isEmpty {
                passwordRejected = .dnsZone
                result(.failed, "DNS zone has no stale addresses",
                       ADCredentialCheck.detail(step: .dnsZone, output: rejected, realm: settings.realm))
            } else {
                result(.skipped, "DNS zone has no stale addresses", "could not read the zone")
            }
            return
        }
        if passwordRejected == .dnsZone { passwordRejected = nil }
        result(stale.isEmpty ? .ok : .failed, "DNS zone has no stale addresses",
               stale.isEmpty ? "all \(read) domain-controller names answer \(address), and nothing answers AAAA"
                             : "still advertising \(stale.joined(separator: ", "))")
    }

    private func dig(_ arguments: [String]) async -> String {
        let result = await Shell.run("/usr/bin/dig", arguments, environment: [:])
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: The adopted domain's Administrator password

    /// Overwrite the **domain's** Administrator password with the one in Settings, then re-run
    /// whichever bind-requiring step was refused.
    ///
    /// Only ever from an explicit button press. On an adopted domain the password belongs to
    /// the domain — the notebook that joined it, the NAC that binds to it and anyone who knows
    /// the old one are all affected — so this app proposes it and never does it quietly.
    ///
    /// The password reaches `samba-tool` down this process's stdin; see
    /// `ADCommands.setAdministratorPasswordScript` for why that matters.
    func setDomainAdministratorPassword(_ settings: ADSettings) async {
        guard !settings.administratorPassword.isEmpty else {
            result(.failed, "set the domain's Administrator password",
                   "There is no password in the domain settings to set it to.")
            return
        }
        _ = await changeAdministratorPassword(to: settings.administratorPassword, settings: settings)
    }

    /// Set the domain's Administrator password to `password`. Returns nil on success, or the
    /// sentence that went wrong.
    ///
    /// The password goes in through **stdin** and a 0600 file inside the container
    /// (`ADCommands.setAdministratorPasswordScript`); it is never an argument, where `ps` would
    /// show it to every process on the Mac for as long as the call lasts.
    ///
    /// Used by both routes: **Change…** beside the field, which sets the domain and the
    /// setting together, and the repair button on an adopted domain, which sets the domain to
    /// the password already in the settings.
    @discardableResult
    func changeAdministratorPassword(to password: String, settings: ADSettings) async -> String? {
        guard isRunning else { return "The domain controller is not running." }
        guard !settingPassword else { return "A password change is already in progress." }
        guard let tool = tools.containerTool else { return "Apple's `container` tool is not installed." }
        guard !password.isEmpty else { return "The password cannot be empty." }
        let step = passwordRejected
        settingPassword = true
        defer { settingPassword = false }
        let run = await Shell.run(tool,
                                  ADCommands.setAdministratorPasswordArguments(container: containerName),
                                  input: password + "\n", environment: [:])
        guard run.ok else {
            let why = Self.firstError(in: run.output)
            result(.failed, "set the domain's Administrator password", why)
            note("—— could not set the domain's Administrator password: \(run.output.prefix(200))")
            return why
        }
        passwordRejected = nil
        note("—— the domain's Administrator password was changed")
        result(.ok, "set the domain's Administrator password",
               "\(settings.realm) now accepts the new password. Anything that held the old one — a joined computer's cached credentials, a NAC's bind account — has to be updated.")
        if let step { await rerun(step, settings: settings) }
        return nil
    }

    // MARK: Prerequisite actions

    /// Builds the image with the streamed card the Homebrew installer uses. The build context
    /// is the bundled copy of the Containerfile and its two scripts.
    func buildImage(context: URL) {
        guard let tool = tools.containerTool, !builder.isRunning else { return }
        builder.clearLog()
        let arguments = ADImage.buildArguments(context: context.path, reference: ADImage.reference)
        builder.onExit = { [weak self] _ in
            guard let self, let tool = self.tools.containerTool else { return }
            Task {
                // The buildkit helper stays up after a build — 2 CPU and 2 GB of nothing.
                _ = await Shell.run(tool, ADImage.builderStopArguments, environment: [:])
                await self.refreshPrerequisites()
            }
        }
        builder.start(executable: tool, arguments: arguments)
    }

    func startBuilder() async {
        guard let tool = tools.containerTool else { return }
        _ = await Shell.run(tool, ["system", "start", "--enable-kernel-install"], environment: [:])
        _ = await Shell.run(tool, ADImage.builderStartArguments, environment: [:])
    }

    func exportImage(to url: URL) async {
        guard let tool = tools.containerTool, let reference = imageReference else { return }
        let run = await Shell.run(tool, ADImage.saveArguments(reference: reference, to: url.path), environment: [:])
        if run.ok {
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attributes?[.size] as? Int) ?? 0
            note("—— exported \(reference) to \(url.path) (\(Self.megabytes(size)))")
        } else {
            onError?("Export failed:\n\(run.output.suffix(500))")
        }
    }

    func importImage(from url: URL) async {
        guard let tool = tools.containerTool else { return }
        let run = await Shell.run(tool, ADImage.loadArguments(from: url.path), environment: [:])
        if run.ok {
            note("—— imported \(url.lastPathComponent)")
            await refreshPrerequisites()
        } else {
            onError?("Import failed:\n\(run.output.suffix(500))")
        }
    }

    /// Removes **only** our container, our volume and our image, and only after a confirmation
    /// in the UI. Nothing else in `container` is touched.
    func removeComponents() async {
        guard let tool = tools.containerTool else { return }
        await stop(quiet: true)
        _ = await Shell.run(tool, ["system", "start", "--enable-kernel-install"], environment: [:])
        for arguments in ADImage.removeArguments(volume: volumeName, reference: imageReference ?? ADImage.reference) {
            let run = await Shell.run(tool, arguments, environment: [:])
            note(run.ok ? "—— \(arguments.joined(separator: " "))" : "—— \(arguments.joined(separator: " ")) failed: \(run.output.prefix(160))")
        }
        await refreshPrerequisites()
    }

    /// What the image and the volume cost on disk, for the prerequisites card.
    func refreshDiskUsage() async {
        guard let tool = tools.containerTool, systemRunning else { diskUsage = ""; return }
        let images = await Shell.run(tool, ["image", "list"], environment: [:])
        let count = images.output.split(separator: "\n").dropFirst().count
        diskUsage = "\(count) image\(count == 1 ? "" : "s") · state volume \(ADImage.volumeSize) sparse (a fresh domain uses about 36 MB) · the DC holds about 600–700 MB of RAM while it runs"
    }

    static func megabytes(_ bytes: Int) -> String {
        String(format: "%.0f MB", Double(bytes) / 1_048_576)
    }

    // MARK: Log plumbing

    /// `-adTrace 1` mirrors this controller's log and every sync/self-test line to stdout.
    /// `./Tests/run.sh ad` runs with it: the DC's log lives in the app, and a suite that can
    /// only see side effects cannot tell "the sync did nothing" from "the sync failed".
    /// Unbuffered, or nothing reaches the file until the app exits — stdout is fully buffered
    /// when it is not a terminal, and the suite reads this while the app is still running.
    private static let tracing: Bool = {
        let on = CommandLine.value(after: "-adTrace") == "1"
        if on { setvbuf(stdout, nil, _IONBF, 0) }
        return on
    }()

    func note(_ text: String) {
        logBuffer.append(LogLine(id: nextLineID, text: text, time: Date()))
        nextLineID += 1
        if logBuffer.count > maxLines { logBuffer.removeFirst(logBuffer.count - maxLines) }
        if Self.tracing { print("[ad] \(text)") }
        scheduleLogFlush()
    }

    private func scheduleLogFlush() {
        guard !logFlushPending else { return }
        logFlushPending = true
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1000 / ServerProcess.publishesPerSecond))
            self?.flushLog()
        }
    }

    private func flushLog() {
        logFlushPending = false
        guard log.count != logBuffer.count || log.last?.id != logBuffer.last?.id else { return }
        log = logBuffer
    }

    func clearLog() {
        logBuffer.removeAll()
        logPartial = ""
        log.removeAll()
    }

    private func result(_ outcome: ADResultLine.Outcome, _ title: String, _ detail: String) {
        let line = ADResultLine(id: nextResultID, outcome: outcome, title: title, detail: detail)
        nextResultID += 1
        if testing { checks.append(line) } else { syncLines.append(line) }
        if Self.tracing {
            let mark = switch outcome {
            case .ok: "OK"
            case .failed: "FAIL"
            case .skipped: "SKIP"
            case .info: "INFO"
            }
            print("[\(testing ? "check" : "sync")] \(mark)  \(title)\(detail.isEmpty ? "" : "  — \(detail)")")
        }
    }

    private func fail(_ message: String) {
        state = .failed(message.split(separator: "\n").first.map(String.init) ?? message)
        note("—— \(message)")
        onError?(message)
    }

    /// samba-tool prints a Python traceback on failure; the useful line is the last one.
    static func firstError(in output: String) -> String {
        let lines = output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("File \"") && !$0.hasPrefix("Traceback") }
        return lines.last.map { String($0.prefix(240)) } ?? "failed"
    }
}
