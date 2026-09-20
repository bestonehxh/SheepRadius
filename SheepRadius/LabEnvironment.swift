import Foundation

/// The on-disk lab: everything radiusd/slapd read or write lives under `base`
/// (~/Library/Application Support/SheepRadius). Nothing in /etc or Homebrew's etc is touched.
/// Whatever currently holds a TCP or UDP port, with its pid kept as a number so it can be
/// compared with this process's own.
///
/// **This app can be the holder.** In AD mode the DNS relay is bound by the app itself, and a
/// relay left over from a domain controller that has gone away will fail the next start's port
/// check — as a *stranger*, because a pid rendered into a sentence cannot be recognised. That
/// is the whole reason this type exists.
nonisolated struct PortHolder: Sendable, Equatable {
    var command: String
    var pid: Int32

    var isThisProcess: Bool { pid == ProcessInfo.processInfo.processIdentifier }

    /// What a person reads in the failure sheet.
    var description: String {
        isThisProcess ? "this app (pid \(pid))" : "\(command) (pid \(pid))"
    }
}

nonisolated struct LabEnvironment: Sendable {
    /// `message` is one or two sentences a person can act on. `detail` is the raw output it was
    /// distilled from — shown behind a "Details" disclosure, never as the message itself.
    struct Failure: Error, Sendable {
        let message: String
        var detail: String?
    }

    let base: URL
    let tools: Toolchain

    static var defaultBase: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SheepRadius", isDirectory: true)
    }

    var documentURL: URL { base.appendingPathComponent("lab.json") }
    var raddb: URL { base.appendingPathComponent("raddb") }
    var certs: URL { base.appendingPathComponent("certs") }
    var ldap: URL { base.appendingPathComponent("ldap") }
    var caPEM: URL { certs.appendingPathComponent("ca.pem") }
    var caDER: URL { certs.appendingPathComponent("ca.der") }
    var serverPEM: URL { certs.appendingPathComponent("server.pem") }

    static let privateDirectories = ["raddb", "certs", "log", "run", "ldap", "stage"]
    /// Under `certs/`, so they are inside a 0700 directory already — but 0700 in their own
    /// right, because one of them is the issued-certificate inventory and one is the CA's
    /// revocation database.
    static let certSubdirectories = ["clients", "ca-db", "ca_path"]

    /// Where the supervisor records the *server's* own pid, so an orphan left by an unclean
    /// exit can be recognised and reaped on the next launch.
    func pidFile(_ name: String) -> URL { base.appendingPathComponent("run/\(name).pid") }

    /// FreeRADIUS truncates the configuration directory into a fixed buffer: measured on
    /// 3.2.10, a `-d` path of 200 characters is fine and 201 fails with `Unable to open
    /// file "…/rad/radiusd.conf"` — the directory name itself comes back cut short. `raddb`
    /// is six characters, so that is the lab directory's budget.
    static let maxRaddbPathLength = 200
    static var maxBasePathLength: Int { maxRaddbPathLength - "/raddb".count }

    /// A description of why this lab directory cannot work, or nil.
    static func pathProblem(for base: URL) -> String? {
        let length = base.path.count
        guard length > maxBasePathLength else { return nil }
        return """
        The lab folder path is \(length) characters; FreeRADIUS cannot read a configuration \
        directory longer than \(maxRaddbPathLength), so the limit here is \(maxBasePathLength).

        \(base.path)

        Pass a shorter -labDir, or move the folder closer to the root.
        """
    }

    var pathProblem: String? { Self.pathProblem(for: base) }

    func prepareDirectories() throws {
        let fm = FileManager.default
        // 0700: lab.json and raddb/authorize hold cleartext passwords (PEAP-MSCHAPv2 needs them).
        try fm.createDirectory(at: base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for sub in Self.privateDirectories {
            try fm.createDirectory(at: base.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        enforcePermissions()
    }

    /// Re-applied on every launch and after every write, not just at creation: a directory
    /// that already existed (or a file openssl/slapadd just created) keeps the default 0755
    /// otherwise, and these hold cleartext passwords and private keys.
    func enforcePermissions() {
        chmod(base, 0o700)
        for sub in Self.privateDirectories { chmod(base.appendingPathComponent(sub), 0o700) }
        chmod(ldap.appendingPathComponent("data"), 0o700)
        for sub in Self.certSubdirectories { chmod(certs.appendingPathComponent(sub), 0o700) }
        chmod(caDB.appendingPathComponent("clients.json"), 0o600)
        chmod(documentURL, 0o600)
        chmod(raddb.appendingPathComponent("authorize"), 0o600)
        chmod(stage.appendingPathComponent("authorize"), 0o600)
        chmod(ldap.appendingPathComponent("seed.ldif"), 0o600)
        for key in ["ca.key", "server.key", "ldap.key", "ad.key"] { chmod(certs.appendingPathComponent(key), 0o600) }
    }

    /// **Never through a symbolic link** (build 20, audit N-3).
    ///
    /// `FileManager.setAttributes` follows one, so a link planted at `certs/ca.key` by an
    /// imported archive would have this chmod 0600 whatever it points at — one of the user's
    /// own files, outside the lab folder entirely. `attributesOfItem` does **not** follow
    /// (it is an `lstat`), so asking what the entry is before changing it is the whole fix.
    /// The archive inspection in `previewLab` refuses a link before it is ever written; this
    /// is the second gate, for anything that arrives another way.
    private func chmod(_ url: URL, _ mode: Int) {
        let fm = FileManager.default
        guard let attributes = try? fm.attributesOfItem(atPath: url.path) else { return }
        guard (attributes[.type] as? FileAttributeType) != .typeSymbolicLink else { return }
        try? fm.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }

    // MARK: Document

    /// **Where build 24's identity migrations run** (`LabSettings.migrateBuild24`).
    ///
    /// On load rather than on the first edit, and saved immediately, because everything
    /// downstream — `rootdn`, the seed, the device tables, the base DN the database is renamed
    /// into — has to agree with a file on disk rather than with a value that exists only while
    /// the app is open. The save is best-effort: a lab folder that cannot be written to is a
    /// problem the panes report, not a reason to refuse to open the lab.
    func loadDocument() -> LabDocument {
        guard let data = try? Data(contentsOf: documentURL),
              var doc = try? JSONDecoder().decode(LabDocument.self, from: data) else { return .sample }
        if LabSettings.migrateBuild24(&doc.settings) { try? saveDocument(doc) }
        return doc
    }

    func saveDocument(_ doc: LabDocument) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(doc).write(to: documentURL, options: .atomic)
        enforcePermissions()
    }

    // MARK: RADIUS

    /// The four files radiusd reads, as text. One place, so the staging copy and the live copy
    /// can never be generated differently.
    /// - Parameter authorize: the `users`-format file, which from build 17 is written from the
    ///   directory's snapshot — and that snapshot lives in `AppModel`, not here. Passing nil
    ///   falls back to generating it from the document's **seed** table, which is right in
    ///   exactly two places: a lab whose directory has never been read (there is nothing
    ///   better, and the seed is what slapd was filled from), and the callers that have no
    ///   model at all — the unit tests, most of all.
    func radiusFiles(_ doc: LabDocument, authorize: String? = nil) throws -> [(name: String, text: String)] {
        guard let prefix = tools.radiusPrefix, let libdir = tools.radiusLibDir else {
            throw Failure(message: "FreeRADIUS not found")
        }
        return [
            ("radiusd.conf", ConfigGenerator.radiusdConf(base: base.path, frPrefix: prefix,
                                                         libdir: libdir, doc: doc)),
            ("clients.conf", ConfigGenerator.clientsConf(doc.clients)),
            ("authorize", authorize ?? ConfigGenerator.authorize(doc.users, groups: doc.groups)),
            // Read automatically by radiusd — it needs no $INCLUDE. This is what makes
            // &control:Sheep-Group visible to the rules.
            ("dictionary", SheepAttribute.dictionary),
        ]
    }

    /// Where a candidate configuration is parsed before it is allowed anywhere near `raddb`.
    ///
    /// The name is deliberately five characters, the same length as `raddb`, so it cannot push
    /// a working lab past FreeRADIUS's 200-character configuration-directory limit and make
    /// Apply fail on a path that `raddb` itself fits in (see `maxBasePathLength`).
    /// FreeRADIUS resolves `${confdir}` from the `-d` it is given, so the
    /// staged `radiusd.conf` picks up the staged `authorize` and `dictionary`, while `certs`,
    /// `log` and `run` still point at the real lab.
    var stage: URL { base.appendingPathComponent("stage") }

    /// **A second staging directory, for the check that happens while nothing is being
    /// applied** (build 26, QA M-20).
    ///
    /// `stage/` is Apply's, and Apply writes it, parses it and moves it over `raddb/`. The
    /// pre-save check of a custom unlang block runs while the person is still typing — which
    /// is exactly when an Apply may also be in flight from another pane — so it gets its own
    /// directory rather than racing for that one. Removed after every check; `enforcePermissions`
    /// covers it the same way it covers `stage/`.
    var checkStage: URL { base.appendingPathComponent("check") }

    /// Generate, parse, and only then publish.
    ///
    /// A rule or a block of custom unlang that radiusd will not accept must never reach
    /// `raddb/`: the running server would keep going but the *next* launch would read a broken
    /// file and refuse to start, with the edit that caused it long forgotten. So the candidate
    /// is written to `stage/`, run past `radiusd -CX` there, and copied over the live files
    /// only once it parses — each with an atomic write.
    ///
    /// Throws with the parser's own `file[line]: message`, with the staging path rewritten so
    /// the message names a file the user can actually find.
    func commitRadiusConfig(_ doc: LabDocument, authorize: String? = nil) async throws {
        let files = try radiusFiles(doc, authorize: authorize)
        let fm = FileManager.default
        try fm.createDirectory(at: stage, withIntermediateDirectories: true)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stage.path)
        for file in files { try write(file.text, to: stage, file.name) }
        try? fm.setAttributes([.posixPermissions: 0o600],
                              ofItemAtPath: stage.appendingPathComponent("authorize").path)

        let check = await checkRadiusConfig(in: stage)
        guard check.ok else {
            let readable = { (text: String) in text.replacingOccurrences(of: stage.path, with: raddb.path) }
            throw Failure(message: """
            radiusd rejected the configuration, so nothing was changed — the server is still \
            running the last one that worked.

            \(readable(Self.configErrorSummary(in: check.output)))
            """, detail: readable(Self.configErrors(in: check.output)))
        }
        for file in files { try write(file.text, to: raddb, file.name) }
        try? fm.removeItem(at: stage)
        enforcePermissions()
    }

    /// The staged parse on its own, for Apply to refuse *before* it stops any server.
    /// Returns nil when the configuration is good.
    ///
    /// **The certificates are a precondition of the parse, not of the start.** `radiusd -CX`
    /// instantiates every module, and `rlm_eap_tls` opens `certs/server.key` while it does —
    /// so on a lab where RADIUS has never been started there is nothing to open and the parse
    /// fails for a reason that has nothing to do with what the user just edited. Reported by a
    /// user in build 11: delete a group policy on a fresh install, press Apply, and get
    /// `Instantiation failed for module "eap"`. The certificates are generated here, exactly as
    /// `startRadius` would; a missing openssl is not fatal, because then the parse's complaint
    /// about the certificate *is* the real problem.
    func radiusConfigProblem(_ doc: LabDocument, authorize: String? = nil,
                             in stage: URL? = nil) async -> (summary: String, detail: String)? {
        let stage = stage ?? self.stage
        do {
            try? await ensureCertificates(serverName: doc.settings.serverCertName)
            let files = try radiusFiles(doc, authorize: authorize)
            let fm = FileManager.default
            try fm.createDirectory(at: stage, withIntermediateDirectories: true)
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stage.path)
            for file in files { try write(file.text, to: stage, file.name) }
            let check = await checkRadiusConfig(in: stage)
            try? fm.removeItem(at: stage)
            guard !check.ok else { return nil }
            let readable = { (text: String) in text.replacingOccurrences(of: stage.path, with: raddb.path) }
            return (readable(Self.configErrorSummary(in: check.output)),
                    readable(Self.configErrors(in: check.output)))
        } catch let failure as Failure {
            return (failure.message, failure.detail ?? failure.message)
        } catch {
            return (error.localizedDescription, error.localizedDescription)
        }
    }

    /// `-CX`, not `-C`. Plain `-C` (and `-Cx`) exit non-zero and print **nothing at all**
    /// for whole classes of failure — a duplicate client, for one — which used to surface
    /// in the app as an empty "radiusd rejected the configuration" alert. `-CX` prints the
    /// reason; `configErrors` throws away the config dump that comes with it.
    func checkRadiusConfig(in directory: URL? = nil) async -> Shell.Result {
        guard let radiusd = tools.radiusd else { return .init(status: -1, output: "radiusd not found") }
        return await Shell.run(radiusd, ["-d", (directory ?? raddb).path] + radiusDictionaryArguments + ["-CX"],
                               environment: tools.childEnvironment)
    }

    /// `-D <dictdir>`. Never optional in practice: the stock binaries carry an absolute
    /// Homebrew Cellar path as their compiled-in default, which does not exist on a Mac
    /// that only has the copied .app.
    var radiusDictionaryArguments: [String] {
        tools.dictionaryDir.map { ["-D", $0] } ?? []
    }

    // MARK: Orphans and ports

    /// A server left behind by an unclean exit of an *earlier* run.
    ///
    /// Three conditions, all required, so a radiusd or slapd the user runs for their own
    /// reasons is never touched: the recorded pid is alive, its executable is the binary
    /// this toolchain would launch, and its arguments name **this** lab directory.
    func reapOrphan(_ name: String, executable: String?) async -> String? {
        let file = pidFile(name)
        defer { try? FileManager.default.removeItem(at: file) }
        guard let text = try? String(contentsOf: file, encoding: .utf8),
              let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid > 1, kill(pid, 0) == 0 else { return nil }

        let described = await Shell.run("/bin/ps", ["-o", "args=", "-p", "\(pid)"], environment: [:])
        let arguments = described.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !arguments.isEmpty, arguments.contains(base.path) else { return nil }
        // The recorded executable, or the same binary inside some other copy of the app.
        let binary = (executable as NSString?)?.lastPathComponent ?? name
        guard arguments.hasPrefix(executable ?? "\u{0}") || arguments.contains("/Contents/Helpers/\(binary) ")
                || arguments.hasPrefix("/opt/homebrew") || arguments.hasPrefix("/usr/local") else { return nil }

        kill(pid, SIGTERM)
        for _ in 0..<30 where kill(pid, 0) == 0 { try? await Task.sleep(for: .milliseconds(100)) }
        if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
        return "reclaimed an orphaned \(binary) (pid \(pid)) left by a previous run"
    }

    /// "radiusd (pid 1234)" for whatever holds the port, or nil when it is free.
    ///
    /// See `PortHolder` for why this is not the primitive any more.
    static func portOwner(_ port: Int, protocol proto: String) async -> String? {
        await portHolder(port, protocol: proto)?.description
    }

    /// Who holds a port, with the pid kept as a number.
    ///
    /// The number is the point. Reported as text, "SheepRadius (pid 42565)" reads as a foreign
    /// process — and the app told its own user exactly that on 18 Sep 2026: a DNS relay this
    /// app still had bound to :53, after the DC behind it had gone, was reported back as a
    /// stranger holding the port, so AD mode could not be started and the message blamed
    /// something the person could not find. A pid can be compared with our own; a sentence
    /// cannot.
    static func portHolder(_ port: Int, protocol proto: String) async -> PortHolder? {
        let result = await Shell.run("/usr/sbin/lsof", ["-nP", "-i\(proto):\(port)"], environment: [:])
        guard let line = result.output.split(separator: "\n").dropFirst().first else { return nil }
        let fields = line.split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count >= 2, let pid = Int32(fields[1]) else { return nil }
        return PortHolder(command: String(fields[0]), pid: pid)
    }

    /// Throws naming the port *and* who has it — a generic "failed to start" for a port
    /// clash sends people looking in the wrong place entirely.
    /// Wait until **something is actually listening** on a port a server was just told to
    /// bind, or give up after `timeout` seconds.
    ///
    /// `ServerProcess.start` returns as soon as the child is spawned, so until build 17 the
    /// app reported a server as running a few hundred milliseconds before it could answer
    /// anything. That is invisible to a person — nobody types that fast — and fatal to a
    /// script: the live suite's policy probe applied a configuration and fired a request into
    /// a socket nobody was listening on yet, then reported the custom unlang as ineffective.
    ///
    /// Returns true when the port is held. A false is not made into an error: the server may
    /// legitimately be about to fail, and its own stream says so far better than a timeout
    /// would.
    @discardableResult
    static func waitForPortBound(_ port: Int, protocol proto: String,
                                 timeout: TimeInterval = 8) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await portHolder(port, protocol: proto) != nil { return true }
            // 25 ms, not 200. `lsof` itself costs about 40 ms on this Mac, so the old interval
            // meant the answer could be up to a quarter of a second stale — twice, because
            // Start All waits for radiusd and then for slapd. Measured: that alone accounted
            // for most of the difference between build 12's 249 ms Start All (which did not
            // wait at all, and could report "running" before the server would answer) and the
            // 846 ms this was showing. The check is unchanged; only how often it is asked.
            try? await Task.sleep(for: .milliseconds(25))
        }
        return false
    }

    static func requirePortFree(_ port: Int, protocol proto: String, for server: String) async throws {
        guard let owner = await portOwner(port, protocol: proto) else { return }
        throw Failure(message: """
        \(server) cannot start: \(proto.lowercased())/\(port) is already in use by \(owner).

        Stop that process, or change the port under Settings.
        """)
    }

    /// Lines radiusd prints at column 0 before it has said anything useful.
    ///
    /// Not only the banner: `-CX` narrates what it is doing at column 0 as well, and one of
    /// those lines is a *warning* (`Shared secret … is short`) that a person reading an error
    /// alert will take for the error. `Found debugger attached` is macOS telling radiusd about
    /// this app's own process and means nothing at all here.
    static let bannerPrefixes = [
        "FreeRADIUS Version", "Copyright (C)", "There is NO warranty", "PARTICULAR PURPOSE",
        "You may redistribute", "GNU General Public License", "For more information about",
        "FreeRADIUS is developed", "For commercial support", "https://",
        "Starting - reading configuration", "including dictionary file",
        "including configuration file", "including files in directory",
        "radiusd: ####", "Configuration version:", "Found debugger attached",
        "Shared secret for client", "reading pairlist file", "rlm_mschap (mschap): using",
        "Debugger not attached",
    ]

    /// The words that make a `-CX` line a *reason* rather than narration.
    private static let failureMarkers = [
        "Failed", "failed", "ERROR", "Error", "error:", "Unable", "unable",
        "No such file", "Unknown", "unknown", "Invalid", "invalid", "expected",
        "Cannot", "cannot", "not allowed", "Ignoring", "duplicate", "Duplicate",
    ]

    /// radiusd -CX writes its whole parsed configuration to stdout, indented, and its
    /// diagnostics unindented at column 0. Keep only the diagnostics.
    static func configErrors(in output: String) -> String {
        let interesting = output.split(separator: "\n", omittingEmptySubsequences: true)
            .filter { line in
                guard let first = line.first, first != " ", first != "\t", first != "}" else { return false }
                guard !line.hasSuffix("{"), line != "Configuration appears to be OK" else { return false }
                // The startup banner and the file-by-file progress are also at column 0, and
                // burying a one-line parse error under fifteen lines of copyright is not a
                // diagnostic. Only what is left after these is a real message.
                return !bannerPrefixes.contains { line.hasPrefix($0) }
            }
            .map(String.init)
        // Never return nothing: an unrecognised failure is better shown raw than swallowed.
        return interesting.isEmpty ? String(output.suffix(600)) : interesting.joined(separator: "\n")
    }

    /// **One sentence.** The whole `-CX` dump is never the message.
    ///
    /// radiusd reports a failure from the inside out — the thing that could not be read, then
    /// the item that could not be parsed, then the module that could not be instantiated, then
    /// the virtual server. The *first* of those is the cause and the rest are consequences, so
    /// that is what a person is shown; everything else goes behind "Details".
    ///
    /// This is a build-12 fix. Applying an edit with the servers never started produced an
    /// alert that was seventeen lines of `-CX` narration ending in `Instantiation failed for
    /// module "eap"`, when the actual cause — a certificate that had not been generated yet —
    /// was one line in the middle and is now also impossible (see `radiusConfigProblem`).
    static func configErrorSummary(in output: String) -> String {
        let lines = configErrors(in: output).split(separator: "\n").map(String.init)
        if let cause = lines.first(where: { line in failureMarkers.contains { line.contains($0) } }) {
            return cause
        }
        return lines.first ?? "radiusd rejected the configuration without saying why."
    }

    // MARK: Certificates

    /// Creates the CA once and keeps it (clients trust it); the server cert is reissued when `force` or missing.
    func ensureCertificates(serverName: String, forceCA: Bool = false, forceServer: Bool = false) async throws {
        guard let openssl = tools.openssl else { throw Failure(message: "openssl not found") }
        let fm = FileManager.default
        let dir = certs.path

        if forceCA || !fm.fileExists(atPath: caPEM.path) {
            try write(ConfigGenerator.caExtensions, to: certs, "ca.cnf")
            try await sh(openssl, ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-sha256", "-days", "3650",
                                   "-config", "ca.cnf", "-keyout", "ca.key", "-out", "ca.pem"], cwd: dir)
            try await sh(openssl, ["x509", "-in", "ca.pem", "-outform", "DER", "-out", "ca.der"], cwd: dir)
        }
        if forceCA || forceServer || !fm.fileExists(atPath: serverPEM.path) {
            try write(ConfigGenerator.serverExtensions(name: serverName), to: certs, "server.ext")
            try await sh(openssl, ["req", "-newkey", "rsa:2048", "-nodes", "-keyout", "server.key", "-out", "server.csr",
                                   "-subj", "/O=SheepRadius Lab/CN=\(serverName)"], cwd: dir)
            // 825 days: Apple clients reject longer-lived TLS server certificates.
            try await sh(openssl, ["x509", "-req", "-in", "server.csr", "-CA", "ca.pem", "-CAkey", "ca.key", "-CAcreateserial",
                                   "-days", "825", "-sha256", "-extfile", "server.ext", "-out", "server.pem"], cwd: dir)
        }
        // The generated tls-config has `check_crl = yes`, which fails every EAP-TLS handshake
        // when the CA has no CRL at all — so one exists before radiusd ever reads the config,
        // even on a lab that has issued nothing and revoked nothing. Rewritten here rather
        // than only on a revocation, because a CRL that ages out fails closed.
        try await refreshRevocationList()
        enforcePermissions()
    }

    var ldapPEM: URL { certs.appendingPathComponent("ldap.pem") }
    var ldapKey: URL { certs.appendingPathComponent("ldap.key") }

    /// The LDAP leaf is **separate from the RADIUS one on purpose**. iOS and macOS
    /// supplicants pin the RADIUS certificate when the user taps Trust, so it must not be
    /// reissued just because the Mac picked up a new IP — but the LDAP certificate has to
    /// carry every current IP, because devices point at an address and do validate it.
    ///
    /// Returns a line for the log when it reissued, so the reason is visible.
    @discardableResult
    func ensureLDAPCertificate(serverName: String, addresses: [String], force: Bool = false) async throws -> String? {
        guard let openssl = tools.openssl else { throw Failure(message: "openssl not found") }
        let fm = FileManager.default
        let dir = certs.path
        var reason: String?

        if force {
            reason = "reissued the LDAP certificate on request"
        } else if !fm.fileExists(atPath: ldapPEM.path) || !fm.fileExists(atPath: ldapKey.path) {
            reason = "issued the LDAP certificate"
        } else {
            let san = await Shell.run(openssl, ["x509", "-in", ldapPEM.path, "-noout", "-ext", "subjectAltName"],
                                      environment: tools.childEnvironment)
            if ConfigGenerator.ldapCertificateNeedsReissue(sanDescription: san.output, addresses: addresses) {
                reason = "reissued the LDAP certificate: this Mac's addresses changed (\(addresses.joined(separator: ", ")))"
            }
        }
        guard let reason else { return nil }

        try write(ConfigGenerator.ldapExtensions(name: serverName, hostname: ProcessInfo.processInfo.hostName,
                                                 addresses: addresses),
                  to: certs, "ldap.ext")
        try await sh(openssl, ["req", "-newkey", "rsa:2048", "-nodes", "-keyout", "ldap.key", "-out", "ldap.csr",
                               "-subj", "/O=SheepRadius Lab/CN=\(serverName)"], cwd: dir)
        try await sh(openssl, ["x509", "-req", "-in", "ldap.csr", "-CA", "ca.pem", "-CAkey", "ca.key", "-CAcreateserial",
                               "-days", "825", "-sha256", "-extfile", "ldap.ext", "-out", "ldap.pem"], cwd: dir)
        enforcePermissions()
        return reason
    }

    // MARK: Client certificates (build 20)

    /// The issued leaves, one PEM each. **No private key is ever in here** — see
    /// `ClientCertificate`.
    var clientCerts: URL { certs.appendingPathComponent("clients", isDirectory: true) }
    /// The app's own index, the `openssl ca` scaffolding `-gencrl` needs, and the CRL number.
    var caDB: URL { certs.appendingPathComponent("ca-db", isDirectory: true) }
    /// The hashed directory `check_crl` reads the CRL out of. radiusd is given this as
    /// `ca_path`, and a HUP is enough to make it re-read what is in it.
    var caPath: URL { certs.appendingPathComponent("ca_path", isDirectory: true) }
    var clientIndexURL: URL { caDB.appendingPathComponent("clients.json") }
    var crlPEM: URL { certs.appendingPathComponent("crl.pem") }

    func loadClientIndex() -> ClientCertificateIndex {
        // **`.iso8601` on both sides.** `saveClientIndex` writes ISO dates and a plain
        // `JSONDecoder` expects a `Double`, so the first cut of this wrote a perfectly good
        // index and then read it back as empty — the certificate was issued, the `.p12` was
        // written, and the app reported that nothing had been recorded.
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: clientIndexURL),
              let index = try? decoder.decode(ClientCertificateIndex.self, from: data)
        else { return ClientCertificateIndex() }
        return index
    }

    func saveClientIndex(_ index: ClientCertificateIndex) throws {
        try FileManager.default.createDirectory(at: caDB, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(index).write(to: clientIndexURL, options: .atomic)
        enforcePermissions()
    }

    /// Issue one client certificate and write the `.p12` the person chose in the save panel.
    ///
    /// The private key lives between `openssl req` and `openssl pkcs12` and is then deleted:
    /// the bundle is the only copy, which is the whole security argument for this feature.
    /// The bundle's password arrives in a 0600 file and that file is removed on every path
    /// out, including a failure — never in argv, for the same reason build 19 took the domain
    /// Administrator's password out of `container run`'s.
    func issueClientCertificate(username: String, principal: String, days: Int,
                                bundlePassword: String, to destination: URL) async throws -> ClientCertificate {
        guard let openssl = tools.openssl else { throw Failure(message: "openssl not found") }
        if let problem = ClientCertificateNames.problem(with: username) { throw Failure(message: problem) }
        guard !bundlePassword.isEmpty else {
            throw Failure(message: "A password is required: a .p12 with no password is a private key anybody can read.")
        }
        let fm = FileManager.default
        try fm.createDirectory(at: clientCerts, withIntermediateDirectories: true)
        try fm.createDirectory(at: caDB, withIntermediateDirectories: true)
        let dir = certs.path
        let stem = "client-issue"
        let keyFile = "\(stem).key", csrFile = "\(stem).csr", extFile = "\(stem).ext"
        let leafFile = "\(stem).pem", bundleFile = "\(stem).p12"
        let passwordFile = certs.appendingPathComponent("\(stem).pass")
        // Everything transient goes, on every path out. The key especially: it is the one file
        // here that must not survive this function.
        func scrub() {
            for name in [keyFile, csrFile, extFile, leafFile, bundleFile] {
                try? fm.removeItem(at: certs.appendingPathComponent(name))
            }
            try? fm.removeItem(at: passwordFile)
        }
        scrub()
        defer { scrub() }

        try write(ClientCertificateCommands.extensions(principal: principal), to: certs, extFile)
        // 0600 before it has contents, never after — `Data.write` would create it at the umask
        // default with the secret already in it (build 19, L-1).
        guard fm.createFile(atPath: passwordFile.path, contents: Data(bundlePassword.utf8),
                            attributes: [.posixPermissions: 0o600]) else {
            throw Failure(message: "Could not write the bundle-password file in the lab folder.")
        }
        try await sh(openssl, ClientCertificateCommands.request(commonName: username, keyFile: keyFile,
                                                                csrFile: csrFile), cwd: dir)
        chmod(certs.appendingPathComponent(keyFile), 0o600)
        try await sh(openssl, ClientCertificateCommands.sign(csrFile: csrFile, days: days,
                                                             extensionsFile: extFile, outFile: leafFile,
                                                             serialFile: "ca.srl"), cwd: dir)
        try await sh(openssl, ClientCertificateCommands.bundle(certificateFile: leafFile, keyFile: keyFile,
                                                               outFile: bundleFile,
                                                               friendlyName: "\(username) — SheepRadius Lab",
                                                               passwordFile: passwordFile.path), cwd: dir)

        let described = await Shell.run(openssl,
                                        ClientCertificateCommands.describe(certs.appendingPathComponent(leafFile).path),
                                        environment: tools.childEnvironment)
        guard let serial = ClientCertificateCommands.serial(inOutput: described.output) else {
            throw Failure(message: "The certificate was issued but its serial could not be read back.",
                          detail: described.output)
        }
        let record = ClientCertificate(serial: serial, username: username, principal: principal,
                                       issued: Date(),
                                       expires: Date().addingTimeInterval(TimeInterval(days) * 86_400))
        // The leaf is kept so the pane can list it and a revocation has something to name. The
        // key is not, and is gone with the rest by the `defer`.
        try? fm.removeItem(at: clientCerts.appendingPathComponent(record.fileName))
        try fm.copyItem(at: certs.appendingPathComponent(leafFile),
                        to: clientCerts.appendingPathComponent(record.fileName))
        try? fm.removeItem(at: destination)
        try fm.copyItem(at: certs.appendingPathComponent(bundleFile), to: destination)
        // The bundle holds a private key. The person picked the destination in a save panel,
        // so it usually lands in Downloads — where other accounts on this Mac can read it.
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)

        var index = loadClientIndex()
        index.record(record)
        try saveClientIndex(index)
        try await refreshRevocationList()
        enforcePermissions()
        return record
    }

    /// **Mark every client certificate as signed by a CA that no longer exists** (build 25,
    /// QA H-4), and rewrite the CRL so it carries only what the new CA did sign. Returns how
    /// many were marked.
    ///
    /// Called from `regenerateCertificatesLocked` when the CA itself is replaced, and only
    /// then. The leaves under `certs/clients/` are **kept**: they are the only record of what
    /// was issued to whom, the pane lists them, and deleting a person's certificate because
    /// the lab's CA was rotated is not a thing an app should do quietly.
    @discardableResult
    func supersedeClientCertificates(at date: Date = Date()) async throws -> Int {
        var index = loadClientIndex()
        let marked = index.supersedeAll(at: date)
        guard marked > 0 else { return 0 }
        try saveClientIndex(index)
        try await refreshRevocationList()
        return marked
    }

    /// Mark one certificate revoked and rewrite the CRL. Returns false when there was nothing
    /// to revoke.
    @discardableResult
    func revokeClientCertificate(serial: String) async throws -> Bool {
        var index = loadClientIndex()
        guard index.revoke(serial: serial) else { return false }
        try saveClientIndex(index)
        try await refreshRevocationList()
        return true
    }

    /// Write `certs/crl.pem` from the app's index and put it where `ca_path` will find it.
    ///
    /// **Always, even with nothing revoked.** `check_crl = yes` fails every EAP-TLS handshake
    /// when the CA has no CRL at all (`unable to get certificate CRL`), so an empty one has to
    /// exist from the start — otherwise turning the feature on would break EAP-TLS for every
    /// lab that had never revoked anything, which is all of them.
    ///
    /// 3650 days, and rewritten on every start: a CRL that expires fails **closed**, and a lab
    /// that stops authenticating because a file aged is not a diagnosable fault.
    func refreshRevocationList() async throws {
        guard let openssl = tools.openssl,
              FileManager.default.fileExists(atPath: caPEM.path) else { return }
        let fm = FileManager.default
        try fm.createDirectory(at: caDB, withIntermediateDirectories: true)
        try fm.createDirectory(at: caPath, withIntermediateDirectories: true)
        let index = loadClientIndex()
        try write(ClientCertificateCommands.caConfiguration(directory: caDB.path), to: caDB, "ca.cnf")
        // **Only the certificates the current CA signed** (build 25, QA H-4). A superseded
        // entry's serial belongs to a CA that no longer exists; putting it on the new CA's CRL
        // would claim a serial the new CA has never issued, and `-gencrl` numbers its own.
        try write(ClientCertificateCommands.indexFile(index.live.sorted { $0.issued > $1.issued }),
                  to: caDB, "index.txt")
        if !fm.fileExists(atPath: caDB.appendingPathComponent("crlnumber").path) {
            try write("1000\n", to: caDB, "crlnumber")
        }
        try await sh(openssl, ClientCertificateCommands.generateCRL(
            configFile: caDB.appendingPathComponent("ca.cnf").path, days: 3650, outFile: crlPEM.path))
        try await rehashCAPath()
        enforcePermissions()
    }

    /// `ca_path` the way OpenSSL reads one: `<subject hash>.0` for the CA and
    /// `<issuer hash>.r0` for its CRL. `c_rehash` is a Perl script that is not bundled, and
    /// the two hashes are one `openssl` call each.
    private func rehashCAPath() async throws {
        guard let openssl = tools.openssl else { return }
        let fm = FileManager.default
        try fm.createDirectory(at: caPath, withIntermediateDirectories: true)
        for existing in (try? fm.contentsOfDirectory(atPath: caPath.path)) ?? [] {
            try? fm.removeItem(at: caPath.appendingPathComponent(existing))
        }
        let caHash = await Shell.run(openssl, ClientCertificateCommands.subjectHash(certificate: caPEM.path),
                                     environment: tools.childEnvironment)
        if let hash = ClientCertificateCommands.hash(inOutput: caHash.output) {
            // A copy rather than a symbolic link: the lab folder is moved, zipped and restored,
            // and a link inside it is one more thing that can point at nothing.
            try? fm.copyItem(at: caPEM, to: caPath.appendingPathComponent(
                ClientCertificateCommands.certificateLinkName(hash: hash)))
        }
        guard fm.fileExists(atPath: crlPEM.path) else { return }
        let crlHash = await Shell.run(openssl, ClientCertificateCommands.issuerHash(crl: crlPEM.path),
                                      environment: tools.childEnvironment)
        if let hash = ClientCertificateCommands.hash(inOutput: crlHash.output) {
            try? fm.copyItem(at: crlPEM, to: caPath.appendingPathComponent(
                ClientCertificateCommands.crlLinkName(hash: hash)))
        }
    }

    var adPEM: URL { certs.appendingPathComponent("ad.pem") }
    var adKey: URL { certs.appendingPathComponent("ad.key") }

    /// The leaf Samba serves on 636/3269, from the **same** test CA as everything else, so a
    /// device that already trusts this lab trusts the domain controller too.
    ///
    /// It is a third certificate rather than a reuse of the OpenLDAP one because its SAN has
    /// to carry the DC's FQDN and the realm — names that mean nothing to the OpenLDAP
    /// listener, and that change when the realm does.
    @discardableResult
    func ensureADCertificate(settings: ADSettings, serverName: String, addresses: [String],
                             force: Bool = false) async throws -> String? {
        guard let openssl = tools.openssl else { throw Failure(message: "openssl not found") }
        let fm = FileManager.default
        let dir = certs.path
        var reason: String?
        let wanted = ADCertificate.sanEntries(settings: settings, name: serverName,
                                              hostname: ProcessInfo.processInfo.hostName, addresses: addresses)

        if force {
            reason = "reissued the domain controller certificate on request"
        } else if !fm.fileExists(atPath: adPEM.path) || !fm.fileExists(atPath: adKey.path) {
            reason = "issued the domain controller certificate"
        } else {
            let san = await Shell.run(openssl, ["x509", "-in", adPEM.path, "-noout", "-ext", "subjectAltName"],
                                      environment: tools.childEnvironment)
            let present = ConfigGenerator.sanIPAddresses(in: san.output)
            let names = wanted.filter { $0.hasPrefix("DNS:") }.map { String($0.dropFirst(4)) }
            let missingName = names.first { !san.output.contains($0) }
            if !Set(addresses).isSubset(of: present) {
                reason = "reissued the domain controller certificate: this Mac's addresses changed (\(addresses.joined(separator: ", ")))"
            } else if let missingName {
                reason = "reissued the domain controller certificate: \(missingName) was not in its SAN"
            }
        }
        guard let reason else { return nil }

        try write(ADCertificate.extensions(settings: settings, name: serverName,
                                           hostname: ProcessInfo.processInfo.hostName, addresses: addresses),
                  to: certs, "ad.ext")
        try await sh(openssl, ["req", "-newkey", "rsa:2048", "-nodes", "-keyout", "ad.key", "-out", "ad.csr",
                               "-subj", "/O=SheepRadius Lab/CN=\(settings.dcFQDN)"], cwd: dir)
        try await sh(openssl, ["x509", "-req", "-in", "ad.csr", "-CA", "ca.pem", "-CAkey", "ca.key", "-CAcreateserial",
                               "-days", "825", "-sha256", "-extfile", "ad.ext", "-out", "ad.pem"], cwd: dir)
        chmod(adKey, 0o600)
        enforcePermissions()
        return reason
    }

    /// nil when LDAPS is off or the files are not there yet.
    func tlsFiles(_ settings: LabSettings) -> ConfigGenerator.TLSFiles? {
        guard settings.needsTLS,
              FileManager.default.fileExists(atPath: ldapPEM.path),
              FileManager.default.fileExists(atPath: ldapKey.path) else { return nil }
        return .init(ca: caPEM.path, certificate: ldapPEM.path, key: ldapKey.path)
    }

    /// The SAN line as openssl prints it, for the Certificates pane.
    func describeSAN(_ url: URL) async -> String {
        guard let openssl = tools.openssl, FileManager.default.fileExists(atPath: url.path) else { return "" }
        let r = await Shell.run(openssl, ["x509", "-in", url.path, "-noout", "-ext", "subjectAltName"],
                                environment: tools.childEnvironment)
        return r.output.split(separator: "\n").dropFirst()
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: " ")
    }

    func describeCertificate(_ url: URL) async -> String {
        guard let openssl = tools.openssl, FileManager.default.fileExists(atPath: url.path) else { return "—" }
        let r = await Shell.run(openssl, ["x509", "-in", url.path, "-noout", "-subject", "-issuer", "-enddate", "-fingerprint", "-sha256"],
                                environment: tools.childEnvironment)
        return r.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: LDAP

    /// Records which suffix the data directory was built for, so a changed base DN is the one
    /// thing that still replaces it.
    var ldapSeedMarker: URL { ldap.appendingPathComponent("seeded-suffix") }

    /// Write slapd's configuration, and **seed the database only when there is none**.
    ///
    /// Until build 16 this replaced the directory wholesale from the app's table on every
    /// start and every Apply. From build 17 the directory is the original (PROJECT-STATUS
    /// §13): the Users, Groups and tree panes edit the *running* slapd, and re-seeding on the
    /// next start would throw all of that away — a user created in the morning would be gone
    /// after lunch, with nothing in the app to say why.
    ///
    /// So the seed now happens exactly twice in a lab's life: the first time the server
    /// starts, and again if the **base DN** changes, which makes every DN in the old database
    /// wrong anyway. `seeded-suffix` is what tells the two apart. The configuration files
    /// themselves are rewritten every time — they are generated, and nobody edits them.
    ///
    /// When it does seed, it seeds into `data.staging` and swaps only once slapadd has
    /// succeeded: slapadd aborts on the first entry it cannot parse, and seeding in place
    /// used to leave a half-populated directory that slapd would then happily serve.
    /// - Returns: a line for the LDAP log when something worth saying happened — today that
    ///   is only build 24's base-DN rename, which is not a thing to do silently.
    @discardableResult
    func rebuildLDAP(_ doc: LabDocument, forceReseed: Bool = false) async throws -> String? {
        guard let slapd = tools.slapd, let schemaDir = tools.schemaDir else { throw Failure(message: "slapd not found") }
        let fm = FileManager.default
        let data = ldap.appendingPathComponent("data")
        let staging = ldap.appendingPathComponent("data.staging")
        let adminHash = ConfigGenerator.ssha(doc.settings.ldapAdminPassword)

        let populated = ((try? fm.contentsOfDirectory(atPath: data.path))?.isEmpty == false)
        let seededFor = try? String(contentsOf: ldapSeedMarker, encoding: .utf8)
        let suffixChanged = seededFor.map { $0 != doc.settings.ldapSuffix } ?? true

        // **A populated database whose base DN moved is renamed, not re-seeded** (build 24).
        //
        // Build 24 gives the lab one name for both backends, so a lab that has been running
        // on `dc=lab,dc=local` since build 17 wakes up wanting `dc=lab,dc=sheep` — and the
        // branch below would have answered that by wiping the directory and re-seeding it
        // from `lab.json`'s read-only table, which has not been the source of truth since
        // build 17. Every account created in the Users pane, every group, every OU and every
        // password would have gone, silently, at a start nobody pressed anything for.
        //
        // So the database is exported, rewritten and loaded back under the new suffix, with
        // the old directory kept beside it. If any step fails the old database is still there
        // and untouched, and the start fails with the reason — a lab with its directory is
        // always better than a lab with a new empty one.
        if !forceReseed, populated, suffixChanged, let old = seededFor, !old.isEmpty,
           old != doc.settings.ldapSuffix {
            let note = try await renameLDAPSuffix(doc, from: old, to: doc.settings.ldapSuffix,
                                                  slapd: slapd, schemaDir: schemaDir,
                                                  data: data, staging: staging, adminHash: adminHash)
            try write(ConfigGenerator.slapdConf(base: base.path, schemaDir: schemaDir, dataDir: data.path,
                                                settings: doc.settings, adminHash: adminHash,
                                                tls: tlsFiles(doc.settings)),
                      to: ldap, "slapd.conf")
            enforcePermissions()
            return note
        }

        let shouldSeed = forceReseed || !populated || suffixChanged

        // Apple's slapd has no writable schema directory, so sAMAccountName /
        // userPrincipalName / sheepRadiusAccount live in the lab folder and are included
        // by both generated configs.
        try write(ConfigGenerator.sheepSchema, to: ldap, "sheepradius.schema")

        if shouldSeed {
            try? fm.removeItem(at: staging)
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: staging) }
            // Two configs, identical but for `directory`: slapadd fills the staging copy,
            // slapd serves the live one. slapadd needs no TLS, but keeping the two otherwise
            // identical means the schema and ACLs it validates against are exactly what the
            // server will serve.
            try write(ConfigGenerator.slapdConf(base: base.path, schemaDir: schemaDir, dataDir: staging.path,
                                                settings: doc.settings, adminHash: adminHash),
                      to: ldap, "slapadd.conf")
            try write(ConfigGenerator.seedLDIF(users: doc.users, groups: doc.groups, ous: doc.ouPaths,
                                               settings: doc.settings, hash: { ConfigGenerator.ssha($0) }),
                      to: ldap, "seed.ldif")
            enforcePermissions()
            // `slapadd` is only ever a symlink back to slapd (argv[0] dispatch), so the tool
            // mode is invoked directly — one code path, and only one binary to bundle.
            try await sh(slapd, tools.slapaddArguments + ["-f", ldap.appendingPathComponent("slapadd.conf").path,
                                                         "-l", ldap.appendingPathComponent("seed.ldif").path])
            // **The old database is moved aside, not deleted** (build 20, audit N-11). Until
            // this build the live directory was removed first and the staged one moved in
            // after; if that move threw — a same-parent `rename(2)` is unlikely to, but
            // ENOSPC is enough — the `defer` above then deleted the staging copy as well and
            // the lab's whole OpenLDAP database was gone. Since build 17 that database is the
            // original, not a copy of `lab.json`, so there would have been nothing to rebuild
            // it from.
            try Self.swapInDatabase(staging: staging, live: data,
                                    aside: ldap.appendingPathComponent("data.previous"))
            try Data(doc.settings.ldapSuffix.utf8).write(to: ldapSeedMarker, options: .atomic)
        }

        try write(ConfigGenerator.slapdConf(base: base.path, schemaDir: schemaDir, dataDir: data.path,
                                            settings: doc.settings, adminHash: adminHash,
                                            tls: tlsFiles(doc.settings)),
                  to: ldap, "slapd.conf")
        enforcePermissions()
        return nil
    }

    /// Where the database that was renamed is kept. One copy, overwritten by the next rename:
    /// this is a way back from *this* migration, not an archive.
    var ldapRenameBackup: URL { ldap.appendingPathComponent("data.before-rename") }

    /// **Move a populated OpenLDAP database from one base DN to another** (build 24).
    ///
    /// `slapcat` out, `LDAPSuffixRewrite` over the text, `slapadd` into staging, swap. The
    /// export is taken with a configuration that names the **old** suffix and the live data
    /// directory, and the import with one that names the new suffix and the staging directory,
    /// which is why both are generated here rather than reused from the caller.
    ///
    /// `slapcat` bypasses ACLs — it is a database tool, not a client — so `userPassword` and
    /// `sambaNTPassword` come out with everything else and every account keeps its password
    /// across the rename. That is the whole reason this is not "export the users and re-create
    /// them".
    private func renameLDAPSuffix(_ doc: LabDocument, from old: String, to new: String,
                                  slapd: String, schemaDir: String,
                                  data: URL, staging: URL, adminHash: String) async throws -> String {
        let fm = FileManager.default
        var oldSettings = doc.settings
        oldSettings.ldapSuffixOverride = old
        // The admin DN has to be the old one too: `slapcat` does not care, but a config whose
        // `rootdn` is outside its own `suffix` is one slapd complains about, and this file is
        // parsed before a single entry is read.
        oldSettings.ldapAdminDNOverride = LabSettings.defaultAdminDN(suffix: old)

        try write(ConfigGenerator.slapdConf(base: base.path, schemaDir: schemaDir, dataDir: data.path,
                                            settings: oldSettings, adminHash: adminHash),
                  to: ldap, "slapcat.conf")
        let exported = ldap.appendingPathComponent("rename-export.ldif")
        try? fm.removeItem(at: exported)
        // `slapd -T cat`, the same argv[0] dispatch `slapadd` goes through.
        let dump = await Shell.run(slapd, ["-T", "cat",
                                           "-f", ldap.appendingPathComponent("slapcat.conf").path,
                                           "-l", exported.path],
                                   environment: tools.childEnvironment)
        guard dump.ok, let text = try? String(contentsOf: exported, encoding: .utf8), !text.isEmpty else {
            throw Failure(message: "The LDAP directory could not be exported for the move from "
                          + "\(old) to \(new), so it was left exactly as it is:\n\(dump.output)")
        }
        let entries = LDAPSuffixRewrite.countsEntries(in: text)
        let moved = LDAPSuffixRewrite.rewrite(ldif: text, from: old, to: new)
        try Data(moved.utf8).write(to: exported, options: .atomic)
        enforcePermissions()

        try? fm.removeItem(at: staging)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        var keepStaging = false
        defer { if !keepStaging { try? fm.removeItem(at: staging) } }
        try write(ConfigGenerator.slapdConf(base: base.path, schemaDir: schemaDir, dataDir: staging.path,
                                            settings: doc.settings, adminHash: adminHash),
                  to: ldap, "slapadd.conf")
        let load = await Shell.run(slapd, tools.slapaddArguments
                                   + ["-f", ldap.appendingPathComponent("slapadd.conf").path,
                                      "-l", exported.path],
                                   environment: tools.childEnvironment)
        guard load.ok else {
            throw Failure(message: "The LDAP directory could not be rebuilt under \(new), so it "
                          + "was left under \(old):\n\(load.output)")
        }
        // The old one is kept where a person can find it, not moved aside and deleted the way
        // an ordinary re-seed does it: this is the only copy of the directory as it was before
        // the lab changed its name.
        try? fm.removeItem(at: ldapRenameBackup)
        try? fm.copyItem(at: data, to: ldapRenameBackup)
        try Self.swapInDatabase(staging: staging, live: data,
                                aside: ldap.appendingPathComponent("data.previous"))
        keepStaging = true          // it is the live directory now
        try Data(new.utf8).write(to: ldapSeedMarker, options: .atomic)
        try? fm.removeItem(at: exported)
        return "moved the LDAP directory from \(old) to \(new) (\(entries) entries); "
            + "the previous database is in ldap/\(ldapRenameBackup.lastPathComponent)"
    }

    /// Put `staging` where `live` is, keeping the old one until the new one is in place.
    ///
    /// Old aside → new in → old away, and on a failure the old one comes back. The three file
    /// operations are injected so the failing-move case can be driven in a unit test: it is
    /// the only interesting thing about this function, and it is the one that cannot be
    /// provoked with a real `rename(2)` on a healthy disk.
    static func swapInDatabase(staging: URL, live: URL, aside: URL,
                               fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) },
                               move: (URL, URL) throws -> Void = { try FileManager.default.moveItem(at: $0, to: $1) },
                               remove: (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }) throws {
        try? remove(aside)
        let hadOne = fileExists(live)
        if hadOne { try move(live, aside) }
        do {
            try move(staging, live)
        } catch {
            // The new one did not land. Put the old one back exactly where it was and let the
            // caller report the failure — a lab with its previous directory is a lab that
            // still works.
            if hadOne { try? move(aside, live) }
            throw error
        }
        if hadOne { try? remove(aside) }
    }

    // MARK: Helpers

    private func write(_ text: String, to dir: URL, _ name: String) throws {
        try Data(text.utf8).write(to: dir.appendingPathComponent(name), options: .atomic)
    }

    private func sh(_ exe: String, _ args: [String], cwd: String? = nil) async throws {
        let r = await Shell.run(exe, args, cwd: cwd, environment: tools.childEnvironment)
        if !r.ok {
            throw Failure(message: "\((exe as NSString).lastPathComponent) failed (\(r.status)):\n\(r.output)")
        }
    }
}
