import Combine
import Foundation

// MARK: - The small pure pieces

/// How a burst of directory edits becomes **one** `authorize` rebuild and one HUP.
///
/// Ticking a checkbox in Users ▸ Member of is one edit; ticking six is six, and each one would
/// otherwise mean a snapshot, an NT-hash pull per user, a `radiusd -CX` and a signal. So a
/// request only *schedules* work when nothing is already scheduled, and the flush that
/// eventually runs covers everything that arrived in between.
///
/// Pure and separate so the collapsing can be proved without a server: `request()` returning
/// true exactly once per quiet period is the whole contract.
nonisolated struct DirectoryReloadCoalescer: Sendable, Equatable {
    private(set) var pending = 0
    private(set) var scheduled = false
    /// How many flushes have actually run — the number the tests compare against.
    private(set) var flushes = 0

    /// True when the caller should schedule a flush. False means one is already coming.
    mutating func request() -> Bool {
        pending += 1
        guard !scheduled else { return false }
        scheduled = true
        return true
    }

    /// Returns how many requests this flush is standing in for; zero means nothing to do.
    @discardableResult
    mutating func flush() -> Int {
        let covered = pending
        pending = 0
        scheduled = false
        if covered > 0 { flushes += 1 }
        return covered
    }
}

/// The inline result beside a row: "saved · 0.3 s", or what went wrong.
///
/// One value rather than two (`savedAt` + `error`) because they are mutually exclusive and
/// a pane showing both at once is a pane that lied about one of them.
nonisolated struct DirectoryStatus: Identifiable, Sendable, Equatable {
    let id = UUID()
    var label: String
    var seconds: Double
    var failure: String?
    /// **What a successful edit did, when "saved" is not enough** (build 26, decision D).
    ///
    /// Every ordinary edit is one thing and "saved · 0.3 s" says all there is to say about it.
    /// The one-time import is not one thing — it creates, lifts and skips, in any combination,
    /// and the first thing the owner asked about it was *what did it actually do*. `label` was
    /// never rendered, so until this build the only way an import could say anything was to
    /// put it in `failure`, which is what produced "Imported with 1 problem(s)" for an import
    /// that had worked.
    var note: String?

    var isError: Bool { failure != nil }

    /// "saved · 0.3 s" / "Imported — 1 moved up · 1 already there · 0.4 s" /
    /// "could not save · “Guests” is a built-in directory object…"
    var text: String {
        if let failure { return failure }
        if let note, !note.isEmpty { return String(format: "%@ · %.1f s", note, seconds) }
        return String(format: "saved · %.1f s", seconds)
    }
}

/// One step of undo, for the two edits that lose information: **move** and **delete**.
///
/// Not a general undo stack: a rename can be typed back, a password cannot be undone at all
/// (the old one is gone from the directory the moment the new one lands), and a stack deeper
/// than one invites someone to walk it backwards past a change another pane has already acted
/// on. One step, named out loud, is what a person actually reaches for.
struct DirectoryUndoStep: Identifiable {
    let id = UUID()
    /// "Moved alice to Staff/IT" — what just happened, in the past tense.
    let done: String
    /// What the button says: "Undo move".
    let button: String
    let perform: (any DirectoryProvider) async throws -> Void
}

/// **An offer, not an undo** (build 25, QA M-2).
///
/// An undo puts back what an edit took away and is always safe to press. This is the opposite
/// shape: the edit succeeded, it left a container with nothing in it, and deleting that
/// container is a *second* edit the person may or may not want. It is offered once, beside the
/// move's own Undo, and vanishes with the next edit if it is not taken.
struct DirectoryFollowUp: Identifiable {
    let id = UUID()
    /// "Staff/Old is empty now."
    let note: String
    /// What the button says: "Delete this OU".
    let button: String
    let perform: @MainActor () -> Void
}

/// What the one-time import sheet shows, and what it will run.
struct DirectoryImportProposal: Identifiable {
    let id = UUID()
    var report: DirectoryImport
    /// Only in AD mode, and only when there is something under `OU=SheepRadius` to lift.
    var migration: DirectoryMigration
    var backendLabel: String
}

// MARK: - AppModel's directory half

extension AppModel {

    // MARK: Which backend is answering

    /// The provider the panes and the RADIUS module talk to **right now**.
    ///
    /// Built fresh per call rather than cached: the three inputs it closes over (which backend
    /// is selected, whether it is running, and the settings it binds with) all change under the
    /// UI, and a cached provider is a provider that goes on talking to a slapd that was
    /// restarted on another port. They are value holders — no connection, no state — so there
    /// is nothing to keep.
    ///
    /// `OfflineDirectory` is what answers when LDAP is off (build 21): every call refuses with
    /// the same sentence the panes put on their empty state. There is no second user table to
    /// fall back to any more — that was the whole point of removing Local users.
    func makeDirectoryProvider() -> any DirectoryProvider {
        switch doc.settings.directoryBackend {
        case .activeDirectory where ad.isRunning:
            return ADDirectory(containerTool: tools.containerTool, containerName: ad.containerName,
                               baseDN: applied.settings.ad.baseDN,
                               netbiosDomain: applied.settings.ad.netbiosDomain, running: true)
        case .openLDAP where ldap.isRunning:
            return OpenLDAPDirectory(tools: tools, settings: applied.settings,
                                     workDirectory: env.base.appendingPathComponent("run", isDirectory: true),
                                     running: true)
        default:
            return OfflineDirectory()
        }
    }

    /// True when the LDAP directory — either backend — is up and answering.
    ///
    /// **Backend-scoped on purpose**: it answers "can the panes read a directory right now",
    /// and with the chooser on Samba AD a running slapd is not one they would read. For "is
    /// any server of this lab up", which is the question the pin has to ask, see
    /// `anyDirectoryIsLive`.
    var directoryIsLive: Bool {
        (doc.settings.directoryBackend == .activeDirectory && ad.isRunning)
            || (doc.settings.directoryBackend == .openLDAP && ldap.isRunning)
    }

    /// **Is a directory of this lab running at all, whichever one the chooser names?**
    /// (build 24.)
    ///
    /// `directoryIsLive` is not the question the pin should be asking and using it there was a
    /// real bug: it is false the moment `doc.settings.directoryBackend` and the running server
    /// disagree — which is exactly the state the pin itself creates, and the state a lab is in
    /// for the moment between a chooser flip and a start. In the `ad` suite it meant the pin
    /// fired **with the domain controller up**, started a slapd beside it and moved the
    /// chooser off the backend that was actually serving.
    ///
    /// The rule the owner gave is the simple one and this is it: if a server of this lab is
    /// running, nothing is pinned, nothing else is started and the chooser is not moved. It
    /// reads the two `ServerProcess`/`ADController` flags directly, so it does not depend on a
    /// snapshot having been loaded yet.
    var anyDirectoryIsLive: Bool { ad.isRunning || ldap.isRunning }

    /// **Which LDAP directory this lab runs**, whether or not it is up right now: "OpenLDAP
    /// (dc=lab,dc=local)" or "Samba AD (lab.sheep)". It names the *choice*, not the state,
    /// because the Users and Groups panes put it under their title where a person reads it as
    /// "these are the accounts in…", and the dot in the sidebar is what says running or not.
    var directoryLabel: String {
        doc.settings.directoryBackend == .activeDirectory
            ? "Samba AD (\(applied.settings.ad.realm))"
            : "OpenLDAP (\(applied.settings.ldapSuffix))"
    }

    /// The one line Status shows when radiusd is up and its directory is not — the state
    /// build 21 allows on purpose: stopping LDAP does **not** stop RADIUS (a NAS pointed at a
    /// server that has vanished is worse than one that answers Access-Reject), so the pane
    /// says what is about to happen to every login instead.
    var radiusHasNoDirectory: Bool { radius.isRunning && !directoryIsLive }

    // MARK: Reading

    /// Re-read the whole directory. Called after every edit, every thirty seconds while a
    /// backend runs, and by the Refresh button.
    func refreshDirectory() async {
        // With LDAP off there is nothing to read and nothing has gone wrong: the panes draw
        // "LDAP is off." with a Start button, and an error strip over the top of it would be
        // the app reporting its own switch position as a fault.
        guard directoryIsLive else {
            directory = .empty
            directoryError = nil
            return
        }
        let provider = makeDirectoryProvider()
        var lastError: (any Error)?
        // A directory that has just been restarted is not a directory that is empty. `slapd`
        // is spawned and `startLDAPLocked` returns before it has bound its port, so the first
        // read after an Apply can arrive a few hundred milliseconds early.
        for attempt in 0..<(directoryIsLive ? Self.directoryReadAttempts : 1) {
            do {
                let fresh = try await provider.snapshot()
                let changed = fresh.users != directory.users || fresh.groups != directory.groups
                    || fresh.ous != directory.ous || fresh.computers != directory.computers
                // Published only when something other than the read's own timestamp moved: the
                // 30 s poll used to redraw Users, Groups, Policy and Test every tick of an idle
                // directory, because `takenAt` alone made every snapshot unequal.
                var unchanged = fresh
                unchanged.takenAt = directory.takenAt
                if unchanged != directory { directory = fresh }
                directoryError = nil
                directoryCanDisable = provider.supportsDisable
                // A password changed in ADUC, a user added by somebody else's samba-tool: the
                // poll is the only thing that will ever notice, so a changed snapshot is a
                // reason to rewrite `authorize` even though this app did nothing.
                if changed { scheduleAuthorizeReload() }
                await offerDirectoryImportIfNeeded()
                return
            } catch {
                lastError = error
                if attempt + 1 < Self.directoryReadAttempts {
                    try? await Task.sleep(for: .milliseconds(400))
                }
            }
        }
        // **The last good snapshot is kept.**
        //
        // Emptying it was a silent outage, and the live suite caught it: `applyLocked`
        // restarted radiusd and slapd and then re-read the directory, the read lost the race
        // with slapd's listener, the snapshot became empty — and the *next* Apply wrote an
        // `authorize` with no users in it at all. Every login failed from then on, and nothing
        // on screen said why. A directory that did not answer is a directory whose state is
        // unknown, which is not the same as one that is empty; the error is shown and the rows
        // stay until something better is known.
        directoryError = (lastError as? DirectoryError)?.message
            ?? lastError?.localizedDescription ?? "The directory did not answer."
    }

    /// How many times a read is tried before the error is believed, while the backend is up.
    static let directoryReadAttempts = 3

    /// Poll while a backend is up, stop when it is not. Thirty seconds is the figure in the
    /// build-17 brief and it is the right order of magnitude: a lab directory changes when a
    /// person changes it, and the panes refresh after each of those already.
    func startWatchingDirectory() {
        directoryWatch?.cancel()
        directoryWatch = Timer.publish(every: 30, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self, self.directoryIsLive else { return }
                Task { await self.refreshDirectory() }
            }
        Task { await self.refreshDirectory() }
    }

    // MARK: Writing

    /// **Every directory edit in the app goes through here.**
    ///
    /// It is one function so that the four things an edit owes the person cannot be forgotten
    /// in one pane and remembered in another: it applies immediately, it says "saved · 0.3 s"
    /// or why not, it re-reads the snapshot, and it tells RADIUS. The panes pass a closure over
    /// the provider rather than a command, so both backends — and `OfflineDirectory`, which
    /// refuses — run exactly the same code path, which is what `-directoryProbe` exercises.
    @discardableResult
    func directoryEdit(_ label: String, undo: DirectoryUndoStep? = nil,
                       _ body: @escaping (any DirectoryProvider) async throws -> Void) async -> Bool {
        let provider = makeDirectoryProvider()
        let started = Date()
        directoryBusy = true
        defer { directoryBusy = false }
        do {
            try await body(provider)
        } catch {
            let message = (error as? DirectoryError)?.message ?? error.localizedDescription
            directoryStatus = DirectoryStatus(label: label, seconds: Date().timeIntervalSince(started),
                                              failure: message)
            return false
        }
        directoryStatus = DirectoryStatus(label: label, seconds: Date().timeIntervalSince(started))
        directoryUndo = undo
        // An offer belongs to the edit that raised it and to no other.
        directoryFollowUp = nil
        await refreshDirectory()
        scheduleAuthorizeReload()
        return true
    }

    /// Attach the one follow-up offer to the edit that has just landed (M-2). Called *after*
    /// `directoryEdit` returns, because that is what clears the previous one.
    func offerDirectoryFollowUp(_ note: String, button: String,
                                perform: @escaping @MainActor () -> Void) {
        directoryFollowUp = DirectoryFollowUp(note: note, button: button, perform: perform)
    }

    /// Run the one outstanding undo step, then forget it.
    func undoLastDirectoryEdit() async {
        guard let step = directoryUndo else { return }
        directoryUndo = nil
        await directoryEdit(step.button) { provider in try await step.perform(provider) }
    }

    func clearDirectoryStatus() {
        directoryStatus = nil
        directoryFollowUp = nil
    }

    /// Save `lab.json` without moving `applied` away from `doc` in a way the ApplyBar would
    /// notice. None of the directory keys is part of `hasUnappliedChanges` (build 21 took the
    /// user, group and OU lists out of it as well, since nothing edits them any more), so this
    /// is belt and braces — and it is what keeps `applied` a faithful copy for the generators.
    func saveDirectoryState() {
        adoptDirectoryState()
        // `applied`, not `doc` (build 25, QA M-28): a directory edit must not carry a *running*
        // server's unapplied settings to disk on its way past. Whatever belongs to a stopped
        // half is adopted into `applied` by `adoptStoppedHalves` and saved from there.
        try? env.saveDocument(applied)
    }

    /// Remember a password this app set, so `authorize` can carry cleartext for it.
    func rememberDirectoryPassword(_ password: String, for username: String) {
        doc.directoryPasswords[username.lowercased()] = password
        saveDirectoryState()
    }

    func forgetDirectoryPassword(for username: String) {
        doc.directoryPasswords.removeValue(forKey: username.lowercased())
        saveDirectoryState()
    }

    func renameDirectoryPassword(from old: String, to new: String) {
        guard let password = doc.directoryPasswords.removeValue(forKey: old.lowercased()) else { return }
        doc.directoryPasswords[new.lowercased()] = password
        saveDirectoryState()
    }

    // MARK: RADIUS's side

    /// **radiusd's user list, written from the directory snapshot and from nothing else**
    /// (build 21). There is no second source any more, so this no longer returns nil to mean
    /// "generate it from `lab.json`" — nil now means only "there is nothing better than the
    /// file already in place".
    func currentAuthorize() async -> String? {
        // A live backend that answered with nothing is a backend that did not answer — see
        // `canWriteAuthorizeFromDirectory`. Hand back the last file this app generated rather
        // than lock everybody out.
        guard canWriteAuthorizeFromDirectory else { return lastDirectoryAuthorize }
        let passwords = knownDirectoryPasswords
        var hashes: [String: String] = [:]
        let provider = makeDirectoryProvider()
        for user in directory.users where user.enabled {
            let key = user.username.lowercased()
            // A password the app knows beats a hash: it is the same password, and cleartext is
            // the only form CHAP and EAP-MD5 can use.
            guard passwords[key] == nil else { continue }
            if let hash = try? await provider.ntHash(of: user.username) { hashes[key] = hash }
        }
        // **Machine accounts** (build 24). The same call, with the `$` on: `samba-tool user
        // getpassword BEST$ --attributes=unicodePwd`. This app never sets a machine password —
        // the join does — so there is no cleartext for one and the hash is the whole of it,
        // which is exactly what PEAP-MSCHAPv2 needs and is why CHAP cannot work for a machine.
        for computer in directory.computers where computer.enabled {
            let key = computer.account.lowercased()
            if let hash = try? await provider.ntHash(of: computer.account) { hashes[key] = hash }
        }
        let text = ConfigGenerator.authorize(snapshot: directory, passwords: passwords, hashes: hashes)
        lastDirectoryAuthorize = text
        return text
    }

    /// Every cleartext password this app holds for a directory account. The rule, and why
    /// both sources count, is in `ConfigGenerator.knownPasswords`.
    var knownDirectoryPasswords: [String: String] {
        ConfigGenerator.knownPasswords(localUsers: doc.users, directoryPasswords: doc.directoryPasswords)
    }

    /// **The passwords the running server is actually serving** (build 25, QA M-9).
    ///
    /// The Test pane's "fill in an account" menu read `knownDirectoryPasswords`, which is
    /// `doc`'s — so a password typed into the Users inspector and not yet written into
    /// `authorize` was pre-filled into a login against a server that had never heard of it,
    /// and the resulting Access-Reject was reported as the server's answer. `authorize` is
    /// generated from `applied`, so this is the list radiusd has.
    var appliedDirectoryPasswords: [String: String] {
        ConfigGenerator.knownPasswords(localUsers: applied.users,
                                       directoryPasswords: applied.directoryPasswords)
    }

    /// The `users` file must never be written empty from a snapshot that is only *unknown*.
    ///
    /// The same incident as `refreshDirectory`, one layer up: with no snapshot to write from,
    /// the honest answer is "do not touch the file radiusd is already serving", not "serve
    /// nobody".
    var canWriteAuthorizeFromDirectory: Bool {
        RadiusAuthorize.mayWrite(snapshot: directory, backendIsLive: directoryIsLive)
    }

    /// Ask for an `authorize` rebuild + HUP; a burst collapses into one.
    func scheduleAuthorizeReload() {
        guard radius.isRunning else { return }
        guard directoryReload.request() else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Self.directoryReloadDelayMilliseconds))
            await self?.flushAuthorizeReload()
        }
    }

    /// Rewrite `authorize` and send radiusd a HUP — **never a restart**.
    ///
    /// A restart drops every session in flight and takes about a second; a HUP re-reads the
    /// `users` file, which is the only file a directory change touches. Restarting is for
    /// rules and clients, which change the configuration radiusd parsed at startup.
    func flushAuthorizeReload() async {
        guard directoryReload.flush() > 0 else { return }
        guard radius.isRunning else { return }
        let text = await currentAuthorize()
        do {
            try await env.commitRadiusConfig(applied, authorize: text)
        } catch let failure as LabEnvironment.Failure {
            directoryError = failure.message
            return
        } catch {
            directoryError = error.localizedDescription
            return
        }
        await hupRadius()
    }

    /// `kill -HUP` on the server's own pid — the one the supervisor wrote, not the wrapper's.
    func hupRadius() async {
        guard let text = try? String(contentsOf: env.pidFile("radius"), encoding: .utf8),
              let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0
        else { return }
        kill(pid, SIGHUP)
        radius.note("—— reloaded the user list (HUP) after a directory change")
    }

    static let directoryReloadDelayMilliseconds = 400

    // MARK: The one-time import

    /// Offer to put the pre-build-17 table into the live backend, **once**.
    ///
    /// Build 17 moved ownership of identity to the backend. A lab.json written by build 16 or
    /// earlier still carries the users, groups and OUs the old Apply used to copy over, and
    /// doing nothing with them would look, to the person upgrading, exactly like the app had
    /// lost them. So they are imported — with a report first, because an import into a domain
    /// that already has some of those names is not a thing to do silently.
    func offerDirectoryImportIfNeeded() async {
        guard !doc.directoryImported, directoryIsLive, directoryImportProposal == nil else { return }
        guard !doc.users.isEmpty || !doc.groups.isEmpty || !doc.ous.isEmpty else {
            doc.directoryImported = true
            saveDirectoryState()
            return
        }
        let report = DirectoryImport.plan(document: doc, into: directory,
                                          backend: doc.settings.directoryBackend)
        let migration = doc.settings.directoryBackend == .activeDirectory
            ? DirectoryMigration.moveUp(snapshot: directory,
                                        managedRootRDN: applied.settings.ad.managedRootRDN)
            : DirectoryMigration()
        // Something to *create* or to lift. A report that is nothing but "all four are
        // already there" is the normal state of a lab that has been running for a while, and
        // putting a sheet in front of it every launch would be noise with a button on it.
        let creates = !report.createUsers.isEmpty || !report.createGroups.isEmpty
            || !report.createOUs.isEmpty
        guard creates || !migration.moves.isEmpty else {
            doc.directoryImported = true
            saveDirectoryState()
            return
        }
        directoryImportProposal = DirectoryImportProposal(report: report, migration: migration,
                                                          backendLabel: directoryLabel)
    }

    /// The sheet's "Import" button: create what the report listed, then lift anything still
    /// under `OU=SheepRadius` to the top level.
    /// **The sheet's "Import" button, and it may be pressed any number of times**
    /// (build 26, decision D — `DirectoryImportRun` has the three rules and the bug).
    ///
    /// Build 25 reported *"Imported with 1 problem(s): move OU SheepRadius/Staff already
    /// exists"* on an import that had done exactly what it set out to do: the create half made
    /// `Staff` from `lab.json`'s seed and the lift half then tried to move `SheepRadius/Staff`
    /// onto it. The two halves are reconciled before either runs, an "already exists" is a
    /// skip rather than a failure, and the strip says what happened instead of counting
    /// non-problems.
    func runDirectoryImport(_ proposal: DirectoryImportProposal) async {
        // It writes through the live provider, one `createOU` / `createGroup` / `createUser` /
        // `setPassword` at a time — so with LDAP off there is nowhere for it to go and it says
        // so, rather than filling the report with fifteen copies of the same refusal.
        guard directoryIsLive else {
            directoryImportProposal = nil
            directoryStatus = DirectoryStatus(label: "Import", seconds: 0,
                                              failure: OfflineDirectory.message
                                              + " Start it and the import is offered again.")
            return
        }
        let plan = DirectoryImportRun.reconcile(report: proposal.report,
                                                migration: proposal.migration)
        let provider = makeDirectoryProvider()
        var outcome = DirectoryImportRun.Outcome()
        directoryBusy = true

        /// One step, with "the directory already has it" counted as done rather than as a
        /// problem — which is the whole of decision D.
        func step(_ describe: @autoclosure () -> String, count: Bool = true,
                  _ body: () async throws -> Void) async {
            do {
                try await body()
                if count { outcome.created += 1 }
            } catch {
                if DirectoryImportRun.isAlreadyThere(error) { outcome.alreadyThere += 1 }
                else { outcome.failures.append("\(describe()): \(message(of: error))") }
            }
        }

        for path in plan.report.createOUs {
            await step("OU \(path)") { try await provider.createOU(path) }
        }
        for name in plan.report.createGroups {
            let description = doc.groups.first { $0.name == name }?.description ?? ""
            await step("group \(name)") { try await provider.createGroup(name, description: description) }
        }
        for name in plan.report.createUsers {
            guard let user = doc.users.first(where: { $0.username == name }) else { continue }
            await step("user \(name)") {
                try await provider.createUser(user.username, displayName: user.displayName,
                                              ou: user.effectiveOU, password: user.password)
                doc.directoryPasswords[user.username.lowercased()] = user.password
                let names = doc.groups(of: user).map(\.name)
                if !names.isEmpty { try await provider.setMembership(of: user.username, groups: names) }
            }
        }
        // Everything the app owns comes up out of `OU=SheepRadius`. Users first: moving the
        // OU out from under them and then moving them would be two moves for one account.
        for move in plan.migration.moves where move.kind == .user {
            let username = OUPath.segments(move.from).last ?? move.from
            let target = OUPath.parent(move.to) ?? ""
            await step("move \(username)", count: false) {
                try await provider.moveUser(username, toOU: target)
                outcome.lifted += 1
            }
        }
        for move in plan.migration.moves where move.kind == .ou {
            await step("move OU \(move.from)", count: false) {
                try await provider.moveOU(move.from, under: OUPath.parent(move.to) ?? "")
                outcome.lifted += 1
            }
        }
        doc.directoryImported = true
        saveDirectoryState()
        directoryBusy = false
        directoryImportProposal = nil
        // **No warning when nothing failed** (decision D). What is left is the ordinary
        // confirmation every directory edit gets, saying what it did.
        directoryStatus = DirectoryStatus(label: "Import", seconds: 0,
                                          failure: outcome.failure,
                                          note: "Imported — \(outcome.summary)")
        await refreshDirectory()
        scheduleAuthorizeReload()
    }

    /// "Not now" — asked again at the next launch, because the alternative is losing the table
    /// to a mis-click.
    func dismissDirectoryImport() { directoryImportProposal = nil }

    /// "Never" — the table stays in `lab.json`, unseen, and is not offered again.
    func refuseDirectoryImport() {
        doc.directoryImported = true
        saveDirectoryState()
        directoryImportProposal = nil
    }

    private func message(of error: any Error) -> String {
        (error as? DirectoryError)?.message ?? error.localizedDescription
    }

    // MARK: The live suite's hook

    /// `-directoryProbe 1` — drives **the panes' own code path**, not the command builders.
    ///
    /// Everything below goes through `directoryEdit`, which is the function every context menu
    /// and every text field in Users / Groups / the tree calls. That is the difference between
    /// this and the build-16 phases in `Tests/run.sh`, which fired the bundled LDAP tools at
    /// slapd directly: those proved the directory would accept the payloads, this proves the
    /// app sends them, reads the result back and tells RADIUS.
    func runDirectoryProbe() async {
        setvbuf(stdout, nil, _IONBF, 0)
        func say(_ text: String) { print("[dir] \(text)") }

        await refreshDirectory()
        say("backend \(doc.settings.directoryBackend.rawValue)")
        say("label \(directoryLabel)")
        say("live \(directoryIsLive ? "yes" : "no")")
        if let directoryError { say("error \(directoryError.replacingOccurrences(of: "\n", with: " · "))") }
        say("snapshot users=\(directory.users.count) groups=\(directory.groups.count) ous=\(directory.ous.count)")

        let name = "probe1"
        let ou = "Probe/Deep"
        var ok = await directoryEdit("New user") { provider in
            try await provider.createUser(name, displayName: "Probe One", ou: ou, password: "Probe-1-pass!")
        }
        rememberDirectoryPassword("Probe-1-pass!", for: name)
        say("create \(ok ? "ok" : "FAILED") \(statusText)")
        say("create-visible \(directory.users.contains { $0.username == name } ? "yes" : "no")")
        say("create-ou \(directory.users.first { $0.username == name }?.ou ?? "-")")

        ok = await directoryEdit("New group") { provider in
            try await provider.createGroup("ProbeGroup", description: "made by -directoryProbe")
        }
        say("create-group \(ok ? "ok" : "FAILED") \(statusText)")

        // Build 27: an ordinary account in AD's default CN=Users container is not a built-in.
        // The suite creates `cnedit` directly on the DC before this hook starts; drive every
        // operation the pane previously hid, then remove the fixture.
        if doc.settings.directoryBackend == .activeDirectory,
           let cnUser = directory.users.first(where: { $0.username == "cnedit" }) {
            say("cn-users-editable \(cnUser.isReadOnly ? "NO" : "yes")")
            ok = await directoryEdit("Display name") {
                try await $0.setDisplayName("cnedit", to: "Edited in CN Users")
            }
            say("cn-users-display \(ok ? "ok" : "FAILED")")
            ok = await directoryEdit("Move") { try await $0.moveUser("cnedit", toOU: "Probe") }
            say("cn-users-move \(ok ? "ok" : "FAILED") ou=\(directory.users.first { $0.username == "cnedit" }?.ou ?? "-")")
            ok = await directoryEdit("Member of") {
                try await $0.setMembership(of: "cnedit", groups: ["ProbeGroup"])
            }
            say("cn-users-group \(ok ? "ok" : "FAILED") groups=\(directory.users.first { $0.username == "cnedit" }?.groups.joined(separator: ",") ?? "-")")
            ok = await directoryEdit("Rename") { try await $0.renameUser("cnedit", to: "cnedit2") }
            say("cn-users-rename \(ok ? "ok" : "FAILED")")
            ok = await directoryEdit("Delete") { try await $0.deleteUser("cnedit2") }
            say("cn-users-delete \(ok ? "ok" : "FAILED") still-there=\(directory.users.contains { $0.username == "cnedit2" } ? "yes" : "no")")
        } else if doc.settings.directoryBackend == .activeDirectory {
            say("cn-users-editable NO — fixture missing")
        }

        ok = await directoryEdit("Member of") { provider in
            try await provider.setMembership(of: name, groups: ["ProbeGroup"])
        }
        say("membership \(ok ? "ok" : "FAILED") groups=\(directory.users.first { $0.username == name }?.groups.joined(separator: ",") ?? "-")")

        // Build 32: every catalogued attribute through the inspector's own call, read back
        // from a fresh snapshot — the first cut saved these and read them back empty, because
        // neither backend's search asked for them.
        let manager = directory.users.first { $0.username != name && !$0.isReadOnly }?.dn
        var setMissing: [String] = []
        for attribute in UserAttribute.catalog {
            let value: String
            switch attribute.kind {
            case .countryCode: value = "TH"
            case .distinguishedName:
                guard let manager else { continue }
                value = manager
            case .telephone: value = "+66 2 123 4567"
            case .ascii: value = "probe1@lab.sheep"
            // Thai on purpose: every free-text attribute must carry UTF-8 intact.
            case .text: value = String("ทดสอบ \(attribute.name)".prefix(attribute.maxLength))
            }
            _ = await directoryEdit(attribute.label) {
                try await $0.setUserAttribute(name, attribute: attribute.name, value: value)
            }
            let back = directory.users.first { $0.username == name }?.value(attribute) ?? ""
            let same = attribute.kind == .distinguishedName
                ? back.caseInsensitiveCompare(value) == .orderedSame : back == value
            if !same { setMissing.append(attribute.name) }
        }
        say("attrs-set \(setMissing.isEmpty ? "ok" : "MISSING " + setMissing.joined(separator: ","))")
        var clearLeft: [String] = []
        for attribute in UserAttribute.catalog {
            _ = await directoryEdit(attribute.label) {
                try await $0.setUserAttribute(name, attribute: attribute.name, value: "")
            }
            let back = directory.users.first { $0.username == name }?.value(attribute) ?? ""
            // OpenLDAP's sn is MUST, so a cleared one holds the username.
            let expected = attribute.requiredInOpenLDAP && doc.settings.directoryBackend == .openLDAP ? name : ""
            if back != expected { clearLeft.append("\(attribute.name)=\(back)") }
        }
        say("attrs-clear \(clearLeft.isEmpty ? "ok" : "LEFT " + clearLeft.joined(separator: ","))")

        ok = await directoryEdit("Password") { provider in
            try await provider.setPassword(name, to: "Probe-2-pass!")
        }
        rememberDirectoryPassword("Probe-2-pass!", for: name)
        say("password \(ok ? "ok" : "FAILED") \(statusText)")

        ok = await directoryEdit("Move", undo: DirectoryUndoStep(done: "Moved", button: "Undo move") {
            try await $0.moveUser(name, toOU: ou)
        }) { provider in try await provider.moveUser(name, toOU: "Probe") }
        say("move \(ok ? "ok" : "FAILED") ou=\(directory.users.first { $0.username == name }?.ou ?? "-")")
        await undoLastDirectoryEdit()
        say("move-undone ou=\(directory.users.first { $0.username == name }?.ou ?? "-")")

        // **The name Active Directory owns — and only Active Directory** (build 21).
        // The build-15 incident stands: `sAMAccountName` is unique domain-wide including
        // groups, so `Guests` resolves to `CN=Guests,CN=Builtin` and members put there lose
        // their authorisation. slapd has no such object and no such rule, and the owner asked
        // for the refusal to stop pretending otherwise.
        ok = await directoryEdit("New group") { provider in
            try await provider.createGroup("Guests", description: "")
        }
        let expectRefusal = doc.settings.directoryBackend == .activeDirectory
        say("builtin-refused \(ok ? "no" : "yes") expected=\(expectRefusal ? "yes" : "no")")
        say("builtin-matches-backend \(ok != expectRefusal ? "yes" : "NO") \(statusText)")
        if ok { _ = await directoryEdit("Delete group") { try await $0.deleteGroup("Guests") } }

        // **Deleting an OU must not delete the people in it** (build 21). In OpenLDAP the
        // accounts live under the container and `ldapdelete -r` used to take them with it; in
        // AD `samba-tool ou delete` refused the whole thing. Both move them to `people` now.
        let resident = "probe2"
        _ = await directoryEdit("New user") { provider in
            try await provider.createUser(resident, displayName: "Probe Two", ou: "Probe/Deep",
                                          password: "Probe-3-pass!")
        }
        rememberDirectoryPassword("Probe-3-pass!", for: resident)
        say("ou-delete-before ou=\(directory.users.first { $0.username == resident }?.ou ?? "-")")
        ok = await directoryEdit("Delete OU") { provider in try await provider.deleteOU("Probe/Deep") }
        say("ou-delete \(ok ? "ok" : "FAILED") \(statusText)")
        let survivor = directory.users.first { $0.username == resident }
        say("ou-delete-survived \(survivor == nil ? "NO — the account went with the OU" : "yes")")
        say("ou-delete-moved-to \(survivor.map { $0.ou.isEmpty ? "(top)" : $0.ou } ?? "-")")
        say("ou-delete-gone \(directory.ous.contains { OUPath.isSame($0.path, "Probe/Deep") } ? "NO" : "yes")")
        _ = await directoryEdit("Delete") { provider in try await provider.deleteUser(resident) }
        forgetDirectoryPassword(for: resident)

        // What RADIUS would be given for this directory, right now.
        let authorize = await currentAuthorize() ?? "(nothing new to write)"
        say("authorize-lines \(authorize.split(separator: "\n").filter { $0.hasPrefix("\"") }.count)")
        say("authorize-has-probe1 \(authorize.contains("\"probe1\"") ? "yes" : "no")")
        say("authorize-cleartext-probe1 \(authorize.contains("\"probe1\"\tCleartext-Password") ? "yes" : "no")")

        func groups(of who: String) -> [String] { directory.users.first { $0.username == who }?.groups ?? [] }

        // **The last member of a group the lab was seeded with can be removed** (build 21).
        // `groupOfNames` requires one `member`, so slapd refuses the modify that would empty
        // it; builds ≤20 seeded no placeholder, and unticking alice's last group came back as
        // an object-class violation. Only meaningful where the seed ran — a throwaway domain
        // has no alice — so it says `skipped` rather than failing in the `ad` suite.
        if !groups(of: "alice").isEmpty {
            let held = groups(of: "alice")
            ok = await directoryEdit("Member of") { provider in
                try await provider.setMembership(of: "alice", groups: [])
            }
            say("empty-group \(ok ? "ok" : "FAILED") left=\(groups(of: "alice").joined(separator: ",")) \(statusText)")
            _ = await directoryEdit("Member of") { provider in
                try await provider.setMembership(of: "alice", groups: held)
            }
            say("empty-group-restored \(groups(of: "alice").sorted() == held.sorted() ? "yes" : "NO")")
        } else {
            say("empty-group skipped no-alice")
        }

        // **Deleting a group takes every membership of it with it** (build 21). Checked on the
        // account this probe made, so it reads the same in a fresh throwaway domain as in the
        // seeded OpenLDAP lab — the `ad` suite's realm has no alice to borrow.
        say("group-delete-before in=\(groups(of: name).contains("ProbeGroup") ? "yes" : "no")")
        _ = await directoryEdit("Delete group") { provider in try await provider.deleteGroup("ProbeGroup") }
        say("group-delete-membership-gone \(groups(of: name).contains("ProbeGroup") ? "NO" : "yes")")

        ok = await directoryEdit("Delete") { provider in try await provider.deleteUser(name) }
        forgetDirectoryPassword(for: name)
        say("delete \(ok ? "ok" : "FAILED") still-there=\(directory.users.contains { $0.username == name } ? "yes" : "no")")
        _ = await directoryEdit("Delete OU") { provider in try await provider.deleteOU("Probe") }
        say("done")
    }

    /// `-radiusStartProbe 1` — **the sidebar's RADIUS switch, with LDAP off** (build 21, §18).
    ///
    /// Three states, in the order a person reaches them. Launched without `-autoStart`, so the
    /// first line is a lab where nothing has ever run.
    func runRadiusStartProbe() async {
        setvbuf(stdout, nil, _IONBF, 0)
        func say(_ text: String) { print("[radstart] \(text)") }
        func state(_ label: String) {
            say("\(label) radius=\(radius.isRunning ? "yes" : "no") ldap=\(directoryIsLive ? "yes" : "no")")
        }

        await stopAll()
        state("before")

        // 1. RADIUS on, LDAP off → the app brings LDAP up first, same path as Start all.
        await startRadius()
        state("after-start-radius")
        if let error = lastError { say("start-error \(error.replacingOccurrences(of: "\n", with: " · "))"); clearError() }
        say("users-in-authorize \((try? String(contentsOf: env.raddb.appendingPathComponent("authorize"), encoding: .utf8))?.split(separator: "\n").filter { $0.hasPrefix("\"") }.count ?? -1)")

        // 2. Stopping LDAP leaves RADIUS up — on purpose — and Status says so in one line.
        await ldap.stop()
        await stopAD()
        state("after-stop-ldap")
        say("notice \(radiusHasNoDirectory ? "yes" : "NO")")

        // 3. LDAP switched off in Server: **build 23 turns it on** rather than refusing.
        // Build 21 answered "LDAP is switched off under Directory ▸ Server" and stopped,
        // which was right while Local users existed; with the directory the only source of
        // accounts there is nothing else the person could have meant by RADIUS on.
        await stopAll()
        doc.settings.ldapEnabled = false
        await startRadius()
        state("after-start-with-ldap-disabled")
        say("ldap-enabled-after \(doc.settings.ldapEnabled ? "yes" : "no")")
        say("refusal \((lastError ?? "-").replacingOccurrences(of: "\n", with: " · "))")
        clearError()

        // 4. **The other origin** (build 25, QA H-8). Everything that is not a person reaching
        // for the switch — Start all, ⌘R, `-autoStart 1`, the restart at the end of an Apply —
        // passes `.lab` and does **not** pin, so a directory switched off under Directory ▸
        // Server stays off. Build 24 then reported that OpenLDAP "could not start", about a
        // server nothing had asked to start, and took radiusd down with it. Reproduced live on
        // port set A: /tmp/sheepradius-qa/ldapoff.log.
        await stopAll()
        doc.settings.ldapEnabled = false
        await startAll()
        state("after-start-all-with-ldap-disabled")
        say("lab-origin-ldap-enabled-after \(doc.settings.ldapEnabled ? "yes" : "no")")
        say("lab-origin-refusal \((lastError ?? "-").replacingOccurrences(of: "\n", with: " · "))")
        say("lab-origin-names-the-setting \(lastError?.contains("switched off under Directory ▸ Server") ?? false ? "yes" : "NO")")
        say("lab-origin-invents-a-failure \(lastError?.contains("could not start") ?? false ? "YES" : "no")")
        clearError()

        doc.settings.ldapEnabled = true
        await stopAll()
        say("done")
    }

    /// `-directoryPaneProbe 1` — **opening Users starts the directory, and the two switches
    /// are a pair** (build 22, owner's two decisions).
    ///
    /// Launched without `-autoStart`, so it begins on a lab where nothing has ever run. It
    /// drives the model's own functions — `startDirectoryFromPane`, `stopDirectoryFromSwitch`
    /// — rather than the servers, because what is being tested is the decision each of them
    /// makes, and the shell can see the consequence either way.
    func runDirectoryPaneProbe() async {
        setvbuf(stdout, nil, _IONBF, 0)
        func say(_ text: String) { print("[dirpane] \(text)") }
        func state(_ label: String) {
            say("\(label) radius=\(radius.isRunning ? "yes" : "no") ldap=\(directoryIsLive ? "yes" : "no")")
        }
        func ldapPID() -> String {
            ((try? String(contentsOf: env.pidFile("ldap"), encoding: .utf8)) ?? "-")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        await stopAll()
        state("before")

        // 1. Opening Users starts it, with no button pressed.
        mainPane = .users
        await startDirectoryFromPane()
        state("after-opening-users")
        say("start-problem \((directoryStartProblem ?? "-").replacingOccurrences(of: "\n", with: " · "))")
        let first = ldapPID()
        say("ldap-pid \(first)")
        // **Which backend that was** (build 24, item 6). Opening Users starts OpenLDAP, by
        // name, even on a lab whose chooser says Samba AD — and `ad.containerRuns` counts the
        // app's own `container run` calls, so "no domain controller was started" is a fact
        // this line carries without the suite going near the container tool.
        say("open-backend \(doc.settings.directoryBackend.rawValue) adruns=\(ad.containerRuns)")

        // 2. The pane appearing again must not start a second one.
        await startDirectoryFromPane()
        say("second-open-same-pid \(first != "-" && !first.isEmpty && ldapPID() == first ? "yes" : "NO")")

        // 3. Leaving the pane stops nothing, ever.
        mainPane = .status
        try? await Task.sleep(for: .milliseconds(500))
        state("after-leaving-to-status")

        // 4. RADIUS on: the pair comes up together and the LDAP switch locks.
        await startRadius()
        state("after-start-radius")
        say("ldap-switch-enabled \(ServerPair.directorySwitchEnabled(radiusRunning: radius.isRunning) ? "yes" : "NO")")
        say("ldap-switch-hint \(ServerPair.directorySwitchLockedHint(radiusRunning: radius.isRunning) ?? "-")")

        // 5. The LDAP switch while RADIUS is up: a no-op, both still running.
        await stopDirectoryFromSwitch()
        state("after-ldap-switch-under-radius")

        // 6. RADIUS off, and the switch works again.
        await radius.stop()
        say("ldap-switch-enabled-after \(ServerPair.directorySwitchEnabled(radiusRunning: radius.isRunning) ? "yes" : "NO")")
        await stopDirectoryFromSwitch()
        state("after-ldap-switch-with-radius-down")
        await stopAll()

        // 7. **Build 23 — the RADIUS switch always pairs with OpenLDAP.** The two halves of
        // that rule need opposite fixtures, so the suite that has a domain controller checks
        // the half that needs one and the suite that must not touch a container checks the
        // other. `-adTest 1` is the same hook that names the throwaway container, so there is
        // no way for the live branch to reach a real domain by mistake.
        if CommandLine.value(after: "-adTest") == "1" {
            // Samba AD already up: RADIUS uses it. Nothing stopped, nothing restarted, no
            // slapd beside it, and the chooser stays where the person put it.
            //
            // **The chooser has to be put back on Samba AD first** (build 24): step 1 above
            // opened Users, which pins to OpenLDAP by design now, so without this the whole
            // branch would run against a slapd and "a DC that is already up" would never be
            // the fixture it is testing. Nothing is running at this point, which is exactly
            // when a person may move the chooser.
            doc.settings.directoryBackend = .activeDirectory
            try? await Task.sleep(for: .milliseconds(200))
            await startDirectory()
            state("ad-up-before-radius")
            let nameBefore = ad.containerName
            let runsBefore = ad.containerRuns
            say("ad-container-before \(nameBefore) runs=\(runsBefore)")
            await startRadius()
            state("after-radius-with-ad-up")
            let same = ad.isRunning && ad.containerName == nameBefore && ad.containerRuns == runsBefore
            say("ad-container-same \(same ? "yes" : "NO") name=\(ad.containerName) runs=\(runsBefore)->\(ad.containerRuns)")
            say("ad-backend-after \(doc.settings.directoryBackend.rawValue)")
            say("ad-slapd \(ldap.isRunning ? "yes" : "no")")
            // **Build 24, item 6**: the Users pane takes the same pin — and a Samba AD that
            // is already up is what it uses, so nothing moves here either.
            await radius.stop()
            mainPane = .users
            await startDirectoryFromPane()
            state("ad-up-after-opening-users")
            say("ad-pane-container-same \(ad.isRunning && ad.containerRuns == runsBefore ? "yes" : "NO")")
            say("ad-pane-backend \(doc.settings.directoryBackend.rawValue)")
            say("ad-pane-slapd \(ldap.isRunning ? "yes" : "no")")
            await stopAll()
        } else {
            // Backend set to Samba AD, nothing running: the RADIUS switch must start **slapd**
            // and move the chooser, and must not so much as run `container`. Proved without
            // the container tool on either side — `containerRuns` counts the app's own
            // `container run` calls, so the assertion holds on a Mac whose real domain
            // controller happens to be up at the time.
            doc.settings.directoryBackend = .activeDirectory
            try? await Task.sleep(for: .milliseconds(200))
            let runsBefore = ad.containerRuns
            say("pin-backend-before \(doc.settings.directoryBackend.rawValue) runs=\(runsBefore)")
            await startRadius()
            state("after-radius-on-ad-backend")
            say("pin-backend-after \(doc.settings.directoryBackend.rawValue)")
            say("pin-applied-backend \(applied.settings.directoryBackend.rawValue)")
            say("pin-slapd \(ldap.isRunning ? "yes" : "no")")
            say("pin-ad-untouched \(!ad.isRunning && ad.containerRuns == runsBefore ? "yes" : "NO") runs=\(runsBefore)->\(ad.containerRuns)")
            if let error = lastError { say("pin-error \(error.replacingOccurrences(of: "\n", with: " · "))"); clearError() }
            await stopAll()

            // **Build 24, item 6 — opening Users pins exactly like the RADIUS switch.**
            //
            // Build 23 left this one unpinned on purpose. In use that meant clicking Users to
            // look at a list of accounts provisioned a domain controller, because the chooser
            // had been left on Samba AD days earlier. Same fixture as the pin check above, and
            // the same proof: `containerRuns` counts the app's own `container run` calls, so
            // "no DC was started" is checked without going near the container tool.
            doc.settings.directoryBackend = .activeDirectory
            doc.settings.ldapEnabled = false
            try? await Task.sleep(for: .milliseconds(200))
            let paneRunsBefore = ad.containerRuns
            say("pane-pin-backend-before \(doc.settings.directoryBackend.rawValue) ldapEnabled=no runs=\(paneRunsBefore)")
            mainPane = .users
            await startDirectoryFromPane()
            state("after-opening-users-on-ad-backend")
            say("pane-pin-backend-after \(doc.settings.directoryBackend.rawValue)")
            say("pane-pin-applied-backend \(applied.settings.directoryBackend.rawValue)")
            say("pane-pin-ldap-enabled \(doc.settings.ldapEnabled ? "yes" : "NO")")
            say("pane-pin-slapd \(ldap.isRunning ? "yes" : "no")")
            say("pane-pin-ad-untouched \(!ad.isRunning && ad.containerRuns == paneRunsBefore ? "yes" : "NO") runs=\(paneRunsBefore)->\(ad.containerRuns)")
            if let error = lastError { say("pane-pin-error \(error.replacingOccurrences(of: "\n", with: " · "))"); clearError() }
            await stopAll()
        }
        say("done")
    }

    private var statusText: String {
        (directoryStatus?.text ?? "-").replacingOccurrences(of: "\n", with: " · ")
    }
}
