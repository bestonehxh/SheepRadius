import Foundation

/// The two things the Test pane actually does, with no SwiftUI anywhere near them.
///
/// They live here rather than in the view for one reason: the *external-target* code path —
/// an explicit host, port, shared secret and hand-typed credentials — is the part that cannot
/// be proved by a unit test, and a view cannot be driven from a shell script. `./Tests/run.sh
/// live` launches the app with `-clientProbe 1`, which runs this against the app's own
/// servers **through the external path**, and checks what comes back. A second machine is
/// never needed to know that pointing at one would work.
final class TestRunner {
    struct RadiusResult: Sendable {
        var outcome = RadiusOutcome()
        var output = ""
        var command = ""
        var milliseconds = 0
    }

    struct LDAPResult: Sendable {
        var bound = false
        var entries = 0
        var resolvedDN = ""
        var output = ""
        var command = ""
        var diagnosis = ""
        var milliseconds = 0
    }

    private let tools: Toolchain
    private let env: LabEnvironment

    init(tools: Toolchain, env: LabEnvironment) {
        self.tools = tools
        self.env = env
    }

    private var secretDirectory: URL { env.base.appendingPathComponent("run", isDirectory: true) }

    // MARK: RADIUS

    func radius(_ request: RadiusRequest, host: String, port: Int, secret: String,
                timeout: Int, retries: Int) async -> RadiusResult {
        var result = RadiusResult()
        let tool = request.method.needsEAPClient ? tools.radeapclient : tools.radclient
        guard let tool else {
            result.output = "radclient was not found."
            return result
        }
        let target = "\(host):\(port)"
        let name = (tool as NSString).lastPathComponent
        do {
            // `-S <file>`, never the secret as an argument: `ps` shows every argument of every
            // process on this Mac, and this one belongs to somebody else's server.
            let file = try SecretFile(secret, in: secretDirectory, name: "radius-secret", trailingNewline: true)
            defer { file.remove() }
            let arguments = env.radiusDictionaryArguments
                + ["-x", "-t", "\(max(1, timeout))", "-r", "\(max(0, retries))",
                   "-S", file.url.path, target, request.exchange.command]
            result.command = "$ \(name) -x -t \(timeout) -r \(retries) -S <secret file> \(target) \(request.exchange.command)"
            let started = Date()
            let run = await Shell.run(tool, arguments, input: request.attributeLines(),
                                      environment: tools.childEnvironment)
            result.milliseconds = Int(Date().timeIntervalSince(started) * 1000)
            result.output = run.output
            result.outcome = RadiusReplyParser.parse(run.output)
        } catch {
            result.output = "Could not write the shared-secret file: \(error.localizedDescription)"
        }
        return result
    }

    // MARK: Tunnelled EAP

    struct EAPResult: Sendable {
        var outcome = EAPOutcome()
        var output = ""
        var command = ""
        var milliseconds = 0
    }

    /// Drives `eapol_test`, the supplicant simulator, through a whole PEAP / TTLS / TLS
    /// exchange against a RADIUS server.
    ///
    /// Two files are written and removed in a `defer`, both 0600 in the lab folder:
    ///
    /// * the network block, because it holds the password — which must never be an argument,
    ///   and in this format cannot be piped on stdin either;
    /// * the shared secret, because upstream's `-s<secret>` puts it straight into `argv` where
    ///   `ps` shows it to every process on the Mac. `Tools/build-eapol-test.sh` patches
    ///   `-s @<file>` in for exactly this, the same shape as `radclient -S`.
    func eap(_ request: EAPTestRequest, host: String, port: Int, secret: String,
             caPath: String?) async -> EAPResult {
        var result = EAPResult()
        guard let tool = tools.eapolTest else {
            result.output = tools.eapolTestHint ?? "eapol_test was not found."
            return result
        }
        let chain = secretDirectory.appendingPathComponent("eap-server-chain.pem")
        // **A PKCS#12 is unpacked here, not handed to the supplicant** (build 20). The bundled
        // eapol_test says `TLS: PKCS12 support disabled - cannot read p12/pfx files` — it is
        // built without `PKCS12_FUNCS`, and rebuilding it needs the wpa_supplicant source,
        // which this Mac does not have and must not fetch. The bundled openssl reads the
        // bundle perfectly well, so the certificate and the key are written beside the
        // configuration as 0600 PEM files and removed with it. The bundle's password goes to
        // openssl through `-passin file:`, never in argv.
        var request = request
        var unpacked: [URL] = []
        defer { for file in unpacked { try? FileManager.default.removeItem(at: file) } }
        if request.clientKey.hasSuffix(".p12") || request.clientKey.hasSuffix(".pfx") {
            let unpackedBundle = await unpackBundle(request.clientKey,
                                                    password: request.clientKeyPassword)
            guard let pair = unpackedBundle.pair else {
                result.output = unpackedBundle.problem ?? "That .p12 could not be opened."
                return result
            }
            unpacked = [pair.certificate, pair.key]
            request.clientCertificate = pair.certificate.path
            request.clientKey = pair.key.path
            request.clientKeyPassword = ""
        }
        do {
            let config = try SecretFile(request.configuration(caPath: caPath),
                                        in: secretDirectory, name: "eapol-test.conf",
                                        trailingNewline: false)
            // Its own `defer`, taken before the second file can throw: `eapol-test.conf`
            // carries the user's cleartext password on its `password=` line, and a throw here
            // used to leave it on disk with nothing arranged to remove it.
            defer { config.remove() }
            let secretFile = try SecretFile(secret, in: secretDirectory, name: "eap-secret",
                                            trailingNewline: true)
            defer {
                secretFile.remove()
                try? FileManager.default.removeItem(at: chain)
            }
            let arguments = ["-c", config.url.path, "-a", host, "-p", "\(port)",
                             "-s", "@" + secretFile.url.path, "-t", "\(max(1, request.timeout))",
                             "-o", chain.path]
                + request.attributeArguments()
            result.command = "$ eapol_test -c <config file> -a \(host) -p \(port) "
                + "-s @<secret file> -t \(request.timeout) -o <chain file> "
                + request.attributeArguments().joined(separator: " ")
            let started = Date()
            let run = await Shell.run(tool, arguments, environment: tools.childEnvironment)
            result.milliseconds = Int(Date().timeIntervalSince(started) * 1000)
            result.output = run.output
            result.outcome = EAPLogParser.parse(run.output, exitStatus: run.status,
                                                verifiedAgainstCA: !(caPath ?? "").isEmpty)
            result.outcome.certificates = await describe(certificates: result.outcome.certificates,
                                                         chain: chain)
        } catch {
            result.output = "Could not write the eapol_test configuration: \(error.localizedDescription)"
        }
        return result
    }

    /// Split a `.p12` into the certificate and the (unencrypted) key eapol_test can read.
    ///
    /// Both land in the lab folder at 0600 and are removed by the caller's `defer` on every
    /// path out, including a failure — the key is the whole identity, and this is the one
    /// moment in the app's life when a copy of it exists on disk.
    private func unpackBundle(_ path: String, password: String)
        async -> (pair: (certificate: URL, key: URL)?, problem: String?) {
        guard let openssl = tools.openssl else {
            return (nil, "openssl was not found, so the .p12 cannot be read.")
        }
        let certificate = secretDirectory.appendingPathComponent("eap-client.pem")
        let key = secretDirectory.appendingPathComponent("eap-client.key")
        let passwordFile: SecretFile
        do {
            passwordFile = try SecretFile(password, in: secretDirectory, name: "eap-p12-pass",
                                          trailingNewline: false)
        } catch {
            return (nil, "Could not write the bundle-password file: \(error.localizedDescription)")
        }
        defer { passwordFile.remove() }
        let fm = FileManager.default
        try? fm.removeItem(at: certificate)
        try? fm.removeItem(at: key)
        let leaf = await Shell.run(openssl, ["pkcs12", "-in", path, "-clcerts", "-nokeys",
                                             "-out", certificate.path,
                                             "-passin", "file:" + passwordFile.url.path],
                                   environment: tools.childEnvironment)
        guard leaf.ok else {
            return (nil, "That .p12 could not be opened — check the password.\n\n" + leaf.output)
        }
        let secret = await Shell.run(openssl, ["pkcs12", "-in", path, "-nocerts", "-nodes",
                                               "-out", key.path,
                                               "-passin", "file:" + passwordFile.url.path],
                                     environment: tools.childEnvironment)
        guard secret.ok else {
            try? fm.removeItem(at: certificate)
            return (nil, "The private key could not be read out of that .p12.\n\n" + secret.output)
        }
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: certificate.path)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: key.path)
        return ((certificate, key), nil)
    }

    /// Fills in issuer, expiry and SANs from the chain `eapol_test -o` wrote.
    ///
    /// The `CTRL-EVENT-EAP-PEER-CERT` lines carry only a subject, and "when does this expire"
    /// is half of what anyone wants to know about a RADIUS server's certificate.
    ///
    /// **The blocks are NOT in `depth=` order.** eapol_test writes the chain in the order it
    /// verified it — the CA first, then the leaf — with each block preceded by a plain-text
    /// subject line. Indexing by position put the CA's details on the leaf, and it very nearly
    /// went unnoticed because our CA is self-signed, so its issuer *and* the leaf's issuer are
    /// the same string; only the missing SAN gave it away. So each block is matched by its own
    /// subject, read back with `-nameopt compat`, which is the spelling eapol_test uses
    /// (`/O=…/CN=…`) rather than OpenSSL 3's default (`O=…, CN=…`).
    private func describe(certificates: [EAPServerCertificate], chain: URL) async -> [EAPServerCertificate] {
        guard let openssl = tools.openssl,
              let text = try? String(contentsOf: chain, encoding: .utf8) else { return certificates }
        var blocks: [String] = []
        var current: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("-----BEGIN CERTIFICATE-----") { current = [String(line)]; continue }
            if current.isEmpty { continue }
            current.append(String(line))
            if line.hasPrefix("-----END CERTIFICATE-----") {
                blocks.append(current.joined(separator: "\n") + "\n")
                current = []
            }
        }
        var out = certificates
        for block in blocks {
            let facts = await Shell.run(openssl,
                                        ["x509", "-noout", "-subject", "-issuer", "-enddate",
                                         "-ext", "subjectAltName", "-nameopt", "compat"],
                                        input: block, environment: tools.childEnvironment)
            guard facts.ok else { continue }
            var subject = "", issuer = "", notAfter = "", sans: [String] = []
            var sanNext = false
            for raw in facts.output.split(separator: "\n") {
                let line = String(raw).trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("subject=") {
                    subject = String(line.dropFirst("subject=".count)).trimmingCharacters(in: .whitespaces)
                } else if line.hasPrefix("issuer=") {
                    issuer = String(line.dropFirst("issuer=".count)).trimmingCharacters(in: .whitespaces)
                } else if line.hasPrefix("notAfter=") {
                    notAfter = String(line.dropFirst("notAfter=".count)).trimmingCharacters(in: .whitespaces)
                } else if line.contains("Subject Alternative Name") {
                    sanNext = true
                } else if sanNext, !line.isEmpty {
                    sans = line.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                    sanNext = false
                }
            }
            guard let slot = out.firstIndex(where: { $0.subject == subject }) else { continue }
            out[slot].issuer = issuer
            out[slot].notAfter = notAfter
            out[slot].subjectAlternativeNames = sans
        }
        return out
    }

    // MARK: LDAP

    /// Authenticate a username the same way an LDAP-backed application normally does:
    /// search for exactly one entry, take that entry's DN, then bind as that DN with the
    /// user's password. The search account only resolves the DN; its successful bind is not
    /// the verdict. An empty `searchBindDN` performs the search anonymously.
    func ldap(uri: String, searchBindDN: String, searchPassword: String, userPassword: String,
              base: String, filter: String, attributes: [String], tls: [String],
              timeout: Int) async -> LDAPResult {
        var result = LDAPResult()
        guard let whoami = tools.ldapwhoami, let ldapsearch = tools.ldapsearch else {
            result.output = "The OpenLDAP client tools were not found."
            return result
        }
        do {
            // `-y <file>`, never `-w <password>` — same reason as the shared secret. Search
            // and user credentials get separate files because they are separate identities.
            let userFile = try SecretFile(userPassword, in: secretDirectory,
                                          name: "ldap-user-bind", trailingNewline: false)
            defer { userFile.remove() }
            let searchFile = searchBindDN.isEmpty ? nil
                : try SecretFile(searchPassword, in: secretDirectory,
                                 name: "ldap-search-bind", trailingNewline: false)
            defer { searchFile?.remove() }

            var searchCredentials = ["-x"]
            if let searchFile {
                searchCredentials += ["-D", searchBindDN, "-y", searchFile.url.path]
            }
            let shownSearch = searchBindDN.isEmpty
                ? "(anonymous search)"
                : "-D \"\(searchBindDN)\" -y <search-password file>"
            let network = ["-o", "nettimeout=\(max(1, timeout))"]

            let started = Date()
            let search = await Shell.run(ldapsearch,
                                         searchCredentials + ["-LLL", "-H", uri] + network + tls
                                         + ["-b", base, filter] + attributes,
                                         environment: tools.childEnvironment)
            result.command = "$ ldapsearch -x -LLL -H \(uri) \(shownSearch) -b \"\(base)\" \"\(filter)\" \(attributes.joined(separator: " "))"
            result.output = search.output
            guard search.ok else {
                result.milliseconds = Int(Date().timeIntervalSince(started) * 1000)
                result.diagnosis = LDAPDiagnosis.explain(search.output)
                    ?? "The user search failed before a bind could be attempted."
                return result
            }

            let records = ADLDIF.parse(search.output)
            result.entries = records.count
            guard records.count == 1 else {
                result.milliseconds = Int(Date().timeIntervalSince(started) * 1000)
                result.diagnosis = records.isEmpty
                    ? "No user matched \(filter) under \(base), so there is no DN to bind."
                    : "The filter matched \(records.count) entries. Narrow it to exactly one user before binding."
                return result
            }
            guard let userDN = ADLDIF.first(records[0], "dn"), !userDN.isEmpty else {
                result.milliseconds = Int(Date().timeIntervalSince(started) * 1000)
                result.diagnosis = "The search returned one entry but no DN, so it cannot be used for a bind."
                return result
            }
            result.resolvedDN = userDN

            let shownUser = "-D \"\(userDN)\" -y <user-password file>"
            result.command += "\n$ ldapwhoami -x -H \(uri) \(tls.joined(separator: " ")) \(shownUser)"
            let bind = await Shell.run(whoami,
                                       ["-x", "-D", userDN, "-y", userFile.url.path,
                                        "-H", uri] + network + tls,
                                       environment: tools.childEnvironment)
            result.milliseconds = Int(Date().timeIntervalSince(started) * 1000)
            result.output += "\n\n" + bind.output
            result.bound = bind.ok
            result.diagnosis = LDAPDiagnosis.explain(bind.output)
                ?? (bind.ok ? "Found \(userDN), and the user bind succeeded."
                            : "The user was found as \(userDN), but the bind failed.")
        } catch {
            result.output = "Could not write the bind-password file: \(error.localizedDescription)"
        }
        return result
    }

    // MARK: The live suite's probe

    /// Runs the **external-target** path against this Mac's own servers and prints one line
    /// per scenario, so `./Tests/run.sh live` can check the thing a second machine would
    /// otherwise be needed for. Driven by `-clientProbe 1`; prints nothing otherwise.
    static func runProbe(tools: Toolchain, env: LabEnvironment, settings: LabSettings) async {
        setvbuf(stdout, nil, _IONBF, 0)     // stdout is fully buffered when it is not a tty
        let runner = TestRunner(tools: tools, env: env)
        func say(_ name: String, _ verdict: String, _ detail: String = "") {
            print("[client] \(name) = \(verdict)\(detail.isEmpty ? "" : "  — \(detail)")")
        }

        var request = RadiusRequest()
        request.username = "alice"
        request.password = "alice123"
        request.nasIPAddress = "127.0.0.1"

        let accept = await runner.radius(request, host: "127.0.0.1", port: settings.authPort,
                                         secret: localTestSecret, timeout: 3, retries: 1)
        say("radius-accept", accept.outcome.verdict.rawValue, accept.outcome.vlan ?? "")

        var wrong = request
        wrong.password = "definitely-not-the-password"
        let rejected = await runner.radius(wrong, host: "127.0.0.1", port: settings.authPort,
                                           secret: localTestSecret, timeout: 3, retries: 1)
        say("radius-reject", rejected.outcome.verdict.rawValue)

        // A wrong shared secret is *silence*, not an error — the whole reason the pane
        // explains "no response" at length.
        let silent = await runner.radius(request, host: "127.0.0.1", port: settings.authPort,
                                         secret: "not-the-secret", timeout: 2, retries: 0)
        say("radius-wrongsecret", silent.outcome.verdict.rawValue, "\(silent.milliseconds) ms")

        // An `<AP-GROUP>:<SSID>` Called-Station-Id, which is what this user's APs send. It has
        // a hyphen and a colon in it, so it also proves the value survives the quoting on the
        // way into radclient's stdin rather than arriving mangled or split across two lines.
        var called = request
        called.calledStationID = PolicyMatrix.apGroupCalledStationID
        let calledResult = await runner.radius(called, host: "127.0.0.1", port: settings.authPort,
                                               secret: localTestSecret, timeout: 3, retries: 1)
        say("radius-called-station-apgroup", calledResult.outcome.verdict.rawValue,
            PolicyMatrix.apGroupCalledStationID)

        var accounting = request
        accounting.exchange = .accountingStart
        let accounted = await runner.radius(accounting, host: "127.0.0.1", port: settings.acctPort,
                                            secret: localTestSecret, timeout: 3, retries: 1)
        say("radius-accounting", accounted.outcome.verdict.rawValue)

        let plain = await runner.ldap(uri: "ldap://127.0.0.1:\(settings.ldapPort)",
                                      searchBindDN: settings.ldapAdminDN,
                                      searchPassword: settings.ldapAdminPassword,
                                      userPassword: "alice123", base: settings.ldapSuffix,
                                      filter: LDAPDiagnosis.filter("(sAMAccountName=<user>)", user: "alice"),
                                      attributes: ["dn", "cn", "memberOf"], tls: [], timeout: 5)
        say("ldap-bind", plain.bound ? "ok" : "failed", "\(plain.entries) entries")

        let badPassword = await runner.ldap(uri: "ldap://127.0.0.1:\(settings.ldapPort)",
                                            searchBindDN: settings.ldapAdminDN,
                                            searchPassword: settings.ldapAdminPassword,
                                            userPassword: "wrong", base: settings.ldapSuffix,
                                            filter: "(sAMAccountName=alice)", attributes: ["dn"],
                                            tls: [], timeout: 5)
        say("ldap-badpassword", badPassword.bound ? "ok" : "failed", badPassword.diagnosis)

        let withCA = await runner.ldap(uri: "ldaps://127.0.0.1:\(settings.ldapsPort)",
                                       searchBindDN: settings.ldapAdminDN,
                                       searchPassword: settings.ldapAdminPassword,
                                       userPassword: "alice123", base: settings.ldapSuffix,
                                       filter: "(sAMAccountName=alice)", attributes: ["dn"],
                                       tls: ["-o", "TLS_CACERT=\(env.caPEM.path)"], timeout: 5)
        say("ldaps-labca", withCA.bound ? "ok" : "failed")

        // The same connection with system trust must fail: our CA is a test CA and nothing in
        // the system store has ever heard of it. If this one passed, the previous one would
        // be proving nothing.
        let systemTrust = await runner.ldap(uri: "ldaps://127.0.0.1:\(settings.ldapsPort)",
                                            searchBindDN: settings.ldapAdminDN,
                                            searchPassword: settings.ldapAdminPassword,
                                            userPassword: "alice123", base: settings.ldapSuffix,
                                            filter: "(sAMAccountName=alice)", attributes: ["dn"],
                                            tls: [], timeout: 5)
        say("ldaps-systemtrust", systemTrust.bound ? "ok" : "failed", systemTrust.diagnosis)

        print("[client] done")
    }

    /// The tunnelled-EAP equivalent of `runProbe`, driven by `-eapProbe 1`.
    ///
    /// This is the only way the live suite can reach the half of the configuration that
    /// `radclient` cannot speak — PEAP, TTLS and EAP-TLS, the inner/outer rule arrangement,
    /// and the reply that comes back out of a tunnel. Each line names one scenario, and the
    /// suite pins the expected verdict *and* the values, so agreeing on the wrong answer is
    /// still a failure.
    /// `setTLSMaxVersion` re-applies the configuration with a different `tls_max_version`, so
    /// the probe can prove the setting in RADIUS ▸ Server actually binds — a claim that needs
    /// the server changed underneath it and cannot be made from one run.
    /// `addUser` creates an account in whichever directory is running and tells the app its
    /// password, exactly as the Users pane does — the probe needs one account this lab does
    /// not ship with, for the non-ASCII password case (build 20, audit N-16).
    static func runEAPProbe(tools: Toolchain, env: LabEnvironment, settings: LabSettings,
                            setTLSMaxVersion: ((String) async -> Bool)? = nil,
                            addUser: ((String, String) async -> Bool)? = nil) async {
        setvbuf(stdout, nil, _IONBF, 0)
        let runner = TestRunner(tools: tools, env: env)
        guard tools.eapolTest != nil else {
            print("[eap] unavailable — \(tools.eapolTestHint ?? "eapol_test is not bundled")")
            print("[eap] done")
            return
        }
        let ca = env.caPEM.path

        func say(_ name: String, _ result: EAPResult) {
            let o = result.outcome
            var parts = ["verdict=\(o.verdict.rawValue)"]
            parts.append("method=\(o.negotiatedMethod ?? "-")")
            parts.append("tls=\(o.tlsVersion ?? "-")")
            parts.append("vlan=\(o.vlan ?? "-")")
            parts.append("mppe=\(o.mppeKeysPresent ? "yes" : "no")")
            parts.append("verified=\(o.validationPassed.map { $0 ? "yes" : "no" } ?? "-")")
            let rules = o.attributes.first { $0.name == "Session-Timeout" }?.value
            parts.append("sessiontimeout=\(rules ?? "-")")
            let leaf = o.certificates.first { $0.isLeaf }
            parts.append("leaf=\(leaf?.subject ?? "-")")
            // Read back out of the chain eapol_test wrote with -o and described with
            // `openssl x509`: the log lines alone carry only a subject, and "when does this
            // certificate expire" is half of what anyone wants to know about it.
            parts.append("issuer=\(leaf?.issuer ?? "-")")
            parts.append("expires=\((leaf?.notAfter.isEmpty == false) ? "yes" : "-")")
            parts.append("san=\(leaf?.subjectAlternativeNames.joined(separator: "|") ?? "-")")
            print("[eap] \(name) \(parts.joined(separator: " "))")
        }

        func base(_ method: EAPMethod, user: String, password: String) -> EAPTestRequest {
            var r = EAPTestRequest()
            r.method = method
            r.identity = user
            r.password = password
            r.anonymousIdentity = "anonymous@lab"
            r.validation = .labCA
            r.nasIdentifier = "sheep-probe"
            r.nasPortType = "Wireless-802.11"
            r.calledStationID = "00-11-22-33-44-55:Lab-Guest"
            r.timeout = 20
            return r
        }

        func run(_ name: String, _ request: EAPTestRequest, ca caPath: String?) async {
            let result = await runner.eap(request, host: "127.0.0.1", port: settings.authPort,
                                          secret: localTestSecret, caPath: caPath)
            say(name, result)
        }

        // **The non-ASCII account is created first and authenticated last** (build 20, audit
        // N-16). `authorize` is rewritten on a coalescing timer and radiusd re-reads it on a
        // signal, so an account created and authenticated in the same breath can be asked for
        // before the server has it — which is exactly what the first cut of this scenario
        // measured, and it looked like the bug rather than like the wait.
        let thaiPassword = "รหัสผ่าน123"
        let thaiAccount = await addUser?("thaipw", thaiPassword) ?? false

        for (name, method) in [("peap-mschapv2", EAPMethod.peapMSCHAPv2),
                               ("ttls-pap", .ttlsPAP),
                               ("ttls-mschapv2", .ttlsMSCHAPv2)] {
            await run(name, base(method, user: "alice", password: "alice123"), ca: ca)
            var wrong = base(method, user: "alice", password: "definitely-not-the-password")
            await run(name + "-wrongpassword", wrong, ca: ca)
            wrong = base(method, user: "alice", password: "alice123")
            // The LDAP leaf is a perfectly good certificate that is simply not a CA for this
            // chain — a wrong-CA negative that needs no extra file.
            await run(name + "-wrongca", wrong, ca: env.base.appendingPathComponent("certs/ldap.pem").path)
        }

        // No verification at all: it must still authenticate, which is what makes the
        // wrong-CA failures above mean "the CA was wrong" rather than "TLS is broken".
        var open = base(.peapMSCHAPv2, user: "alice", password: "alice123")
        open.validation = .none
        await run("peap-noverify", open, ca: nil)

        // A name the certificate does not have.
        var named = base(.peapMSCHAPv2, user: "alice", password: "alice123")
        named.expectedServerName = "not-the-server.invalid"
        await run("peap-wrongname", named, ca: ca)

        // The static group VLAN, reached with an anonymous outer identity: bob is in Staff
        // and no rule touches him.
        await run("peap-static-vlan", base(.peapMSCHAPv2, user: "bob", password: "bob123"), ca: ca)

        // TLS 1.3 takes BOTH sides: wpa_supplicant will not offer it for EAP unless the
        // network block asks, and the server will not accept it above its own
        // `tls_max_version`. Offering it against the default 1.2 server must still land on
        // 1.2 — that is the half that proves the setting is doing something.
        var thirteen = base(.peapMSCHAPv2, user: "alice", password: "alice123")
        thirteen.allowTLS13 = true
        await run("peap-tls13-offered-server-capped", thirteen, ca: ca)

        if let setTLSMaxVersion {
            if await setTLSMaxVersion("1.3") {
                await run("peap-tls13-both", thirteen, ca: ca)
                // …and with the client back to its default, the same server still gives 1.2,
                // so neither side alone can be credited with the result above.
                await run("peap-tls13-server-only", base(.peapMSCHAPv2, user: "alice", password: "alice123"), ca: ca)
                _ = await setTLSMaxVersion("1.2")
            } else {
                print("[eap] peap-tls13-both skipped — could not re-apply with tls_max_version 1.3")
            }
        }

        // **A password that is not ASCII, through the real supplicant** (build 20, audit
        // N-16). `EAPTestRequest.escaped` walks the value's UTF-8 bytes and appended each one
        // as its own Unicode scalar; writing that String back out as UTF-8 re-encoded every
        // byte above 127 into two, so the supplicant sent mojibake and the login failed with
        // the right password typed. One reviewer read the code as doing that and another read
        // it as correct, and the audit could not settle it without running it — this is the
        // scenario that runs it. The username stays ASCII so the only variable is the
        // password.
        if thaiAccount {
            await run("peap-thai-password", base(.peapMSCHAPv2, user: "thaipw",
                                                 password: thaiPassword), ca: ca)
            // The negative that makes the row above mean "this password", not "any password":
            // the same account, a different non-ASCII string.
            await run("peap-thai-password-wrong",
                      base(.peapMSCHAPv2, user: "thaipw", password: "รหัสผ่าน456"), ca: ca)
        } else if addUser != nil {
            print("[eap] peap-thai-password skipped — the account could not be created")
        }

        print("[eap] done")
    }
}
