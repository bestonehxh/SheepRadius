import Foundation

/// **Client certificates for EAP-TLS** (build 20, the owner's request).
///
/// EAP-TLS is the one method in this app with no password at all: the supplicant proves who it
/// is with a certificate, and RADIUS decides from the name on it. Until this build the lab
/// could serve EAP-TLS and had no way to issue a certificate for it — the `live` suite made
/// one with three `openssl` commands, and the owner had to do the same by hand.
///
/// This is the pure half: what an issued certificate is, the `openssl` argument vectors, the
/// index the app keeps beside the CA, and the hashed names `ca_path` needs. The I/O is in
/// `LabEnvironment`, the panes are in `UsersView` and `CertificatesView`.
///
/// Three decisions that are not obvious and should not be undone:
///
/// - **The private key is never kept.** It exists between `openssl req` and `openssl pkcs12`
///   and is deleted; the `.p12` the person saves is the only copy. A lab that stored every
///   client's key would be a lab where one stolen folder is every identity in it, and there
///   is nothing the app could do with the key afterwards anyway.
/// - **The password for the `.p12` never reaches argv.** `openssl pkcs12 -passout file:…`
///   reads it from a 0600 file that is removed on every path out, for the same reason build
///   19 took the domain Administrator's password out of `container run`'s arguments.
/// - **The `.p12` is written with the legacy algorithms.** OpenSSL 3 defaults to AES-256-CBC
///   with PBKDF2, which Windows 10's certificate import and iOS profile installation both
///   refuse. `-keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1` is what those two
///   read, and a lab certificate nobody can install is not a certificate.
nonisolated struct ClientCertificate: Identifiable, Sendable, Equatable, Codable {
    /// The serial, lower-case hex — the CA's own identifier for it, and what a revocation
    /// names. Also the file name, so the index and the folder cannot disagree.
    var serial: String
    var username: String
    /// `alice@lab.local`, in the SAN as both a UPN and an email address.
    var principal: String
    var issued: Date
    var expires: Date
    var revoked: Date?
    /// **When a new CA made this certificate meaningless** (build 25, QA H-4).
    ///
    /// `regenerateCertificatesLocked(includingCA: true)` rewrites `ca.pem`, `ca.key`,
    /// `server.pem` and `ldap.pem` and leaves `certs/clients/` and `ca-db/` exactly as they
    /// were — so every `.p12` a person had saved stopped authenticating while the Certificates
    /// pane went on calling it **Valid**, because the table read its status out of the dates
    /// alone. The certificate itself is not revoked: the CA that signed it no longer exists, so
    /// there is nothing to revoke it *with*, and it cannot be put on the new CA's CRL either.
    /// It is superseded, which is its own thing and says so.
    ///
    /// Optional, and absent from an older index, so a lab from build 24 decodes unchanged.
    var supersededAt: Date?

    var id: String { serial }

    /// `<serial>-<username>.pem`, the name under `certs/clients/`.
    var fileName: String { "\(serial)-\(ClientCertificateNames.fileSafe(username)).pem" }

    enum Status: String, Sendable, Equatable {
        case valid, expired, revoked, superseded

        /// What the Certificates pane's Status column reads.
        var label: String {
            switch self {
            case .valid: "Valid"
            case .expired: "Expired"
            case .revoked: "Revoked"
            case .superseded: "Superseded by a new CA"
            }
        }

        /// Revoked and superseded are both "this will not authenticate"; only one of them can
        /// still be acted on.
        var isDead: Bool { self != .valid }
    }

    /// **Revoked first, then superseded, then expired.** Revoked is the strongest because it
    /// is the one a person chose; superseded beats expired because a certificate that outlived
    /// its CA is not going to start working again on its own.
    func status(on date: Date = Date()) -> Status {
        if revoked != nil { return .revoked }
        if supersededAt != nil { return .superseded }
        return expires < date ? .expired : .valid
    }
}

/// Names that are safe as a file name, a `-subj` component and an OpenSSL configuration value.
nonisolated enum ClientCertificateNames {
    /// The characters a username may contribute to a file name. `DirectoryNames` already
    /// refuses `, = + \` and the control characters at the edit; this is the second gate, for
    /// a name that came out of a directory this app did not write to.
    static let safe = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")

    static func fileSafe(_ name: String) -> String {
        let mapped = String(name.map { safe.contains($0) ? $0 : "_" })
        return mapped.isEmpty ? "user" : String(mapped.prefix(64))
    }

    /// Why a certificate cannot be issued for this name, or nil.
    ///
    /// A CN reaches `openssl req -subj "/O=…/CN=<name>"`, where a `/` starts the next
    /// component and a `=` starts the next value — so a name carrying either would issue a
    /// certificate with a subject nobody asked for.
    static func problem(with username: String) -> String? {
        let trimmed = username.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return "There is no user name to put on the certificate." }
        if trimmed.count > 64 {
            return "“\(trimmed.prefix(24))…” is \(trimmed.count) characters; a certificate's common name is limited to 64."
        }
        if let bad = trimmed.first(where: { $0 == "/" || $0 == "=" || $0 == "\\" || $0 == "," }) {
            return "A certificate's common name cannot contain “\(bad)” — it separates the parts of a subject."
        }
        if let problem = DirectoryNames.controlCharacterProblem(trimmed, what: "A user name") { return problem }
        if trimmed.unicodeScalars.contains(where: { $0.value > 127 }) {
            return "A certificate's common name has to be ASCII here: “\(trimmed)” is not, and a supplicant matching it against the user name would not agree with the server."
        }
        return nil
    }

    /// `alice@lab.local` — the UPN a Windows supplicant looks for, from the realm in AD mode
    /// and the DNS domain in OpenLDAP mode.
    static func principal(username: String, domain: String) -> String {
        let domain = domain.trimmingCharacters(in: .whitespaces).lowercased()
        return domain.isEmpty ? username : "\(username)@\(domain)"
    }
}

// MARK: - What openssl is asked to do

/// Every `openssl` invocation this feature makes, as pure argv.
///
/// Separate from the calls in `LabEnvironment` for the reason every other builder in this app
/// is: an argument vector carrying a password or a wrong extension is a thing to unit-test,
/// not a thing to read.
nonisolated enum ClientCertificateCommands {
    /// 365 days by default: long enough for a lab that stays up for a term, short enough that
    /// a forgotten certificate stops working rather than lasting as long as the CA.
    static let defaultDays = 365
    static let maxDays = 3650

    /// The `openssl x509 -extfile` contents.
    ///
    /// `extendedKeyUsage = clientAuth` is what makes it a client certificate rather than
    /// another server one, and the `otherName` OID is Microsoft's `userPrincipalName` — a
    /// Windows supplicant reads the UPN out of that and nowhere else.
    static func extensions(principal: String) -> String {
        """
        basicConstraints = CA:FALSE
        keyUsage = critical, digitalSignature, keyEncipherment
        extendedKeyUsage = clientAuth
        subjectKeyIdentifier = hash
        authorityKeyIdentifier = keyid,issuer
        subjectAltName = otherName:1.3.6.1.4.1.311.20.2.3;UTF8:\(principal), email:\(principal)

        """
    }

    /// `openssl req` — a 2048-bit key and a CSR, both in the working directory.
    static func request(commonName: String, keyFile: String, csrFile: String) -> [String] {
        ["req", "-new", "-newkey", "rsa:2048", "-nodes", "-sha256",
         "-keyout", keyFile, "-out", csrFile,
         "-subj", "/O=SheepRadius Lab/CN=\(commonName)"]
    }

    /// `openssl x509 -req` — signed by the lab CA, with the serial taken from the CA's own
    /// serial file so the index, the file name and the CRL all name the same number.
    static func sign(csrFile: String, days: Int, extensionsFile: String, outFile: String,
                     serialFile: String) -> [String] {
        ["x509", "-req", "-in", csrFile, "-CA", "ca.pem", "-CAkey", "ca.key",
         "-CAserial", serialFile, "-CAcreateserial",
         "-days", String(min(max(days, 1), maxDays)), "-sha256",
         "-extfile", extensionsFile, "-out", outFile]
    }

    /// `openssl pkcs12 -export` — **the password comes from a file, never from argv.**
    ///
    /// `-certfile ca.pem` puts the lab CA in the bundle, so importing the one file on a
    /// Windows PC or an iPhone installs the chain as well as the identity.
    static func bundle(certificateFile: String, keyFile: String, outFile: String,
                       friendlyName: String, passwordFile: String) -> [String] {
        ["pkcs12", "-export", "-in", certificateFile, "-inkey", keyFile,
         "-certfile", "ca.pem", "-name", friendlyName, "-out", outFile,
         // OpenSSL 3 defaults to AES-256-CBC + PBKDF2, which Windows 10's import and iOS
         // profile installation both refuse. These three are what they read.
         "-keypbe", "PBE-SHA1-3DES", "-certpbe", "PBE-SHA1-3DES", "-macalg", "sha1",
         "-passout", "file:\(passwordFile)"]
    }

    /// `openssl x509 -noout -serial -enddate` over an issued leaf.
    static func describe(_ file: String) -> [String] {
        ["x509", "-in", file, "-noout", "-serial", "-enddate", "-subject"]
    }

    /// The CRL, regenerated from the app's own index rather than from an `openssl ca`
    /// database: `openssl ca` wants a whole `openssl.cnf` section, a `serial`, an `index.txt`
    /// in its exact format and a `newcerts` directory, and every one of those is a second
    /// place for this app's state to live. The index here is `ClientCertificate` values in
    /// one JSON file, and the CRL is written from it.
    static func generateCRL(configFile: String, days: Int, outFile: String) -> [String] {
        ["ca", "-config", configFile, "-gencrl", "-crldays", String(days), "-out", outFile]
    }

    /// The minimal `openssl ca` section `-gencrl` needs, and nothing else.
    ///
    /// `default_md`, `database` and `crlnumber` are the only keys it reads for this one
    /// operation; everything else in a normal `[ ca ]` section is for signing, which this app
    /// does with `x509 -req` instead.
    static func caConfiguration(directory: String) -> String {
        """
        # Generated by SheepRadius — edits are overwritten.
        [ ca ]
        default_ca = sheep_ca

        [ sheep_ca ]
        dir               = \(directory)
        database          = $dir/index.txt
        crlnumber         = $dir/crlnumber
        certificate       = \(directory)/../ca.pem
        private_key       = \(directory)/../ca.key
        default_md        = sha256
        default_crl_days  = 3650
        policy            = sheep_policy

        [ sheep_policy ]
        commonName = supplied

        """
    }

    /// One line of `openssl ca`'s `index.txt`, which `-gencrl` reads and nothing else writes.
    ///
    /// Six tab-separated fields: the status flag, the expiry, the revocation time (only when
    /// revoked), the serial in **upper-case** hex, the file (unused, `unknown`) and the
    /// subject. Getting the case of the serial wrong is the mistake that produces an empty
    /// CRL without an error.
    static func indexLine(_ certificate: ClientCertificate) -> String {
        let serial = certificate.serial.uppercased()
        let subject = "/O=SheepRadius Lab/CN=\(certificate.username)"
        if let revoked = certificate.revoked {
            return "R\t\(stamp(certificate.expires))\t\(stamp(revoked))\t\(serial)\tunknown\t\(subject)"
        }
        return "V\t\(stamp(certificate.expires))\t\t\(serial)\tunknown\t\(subject)"
    }

    static func indexFile(_ certificates: [ClientCertificate]) -> String {
        certificates.map(indexLine).joined(separator: "\n") + (certificates.isEmpty ? "" : "\n")
    }

    /// `YYMMDDHHMMSSZ`, OpenSSL's UTCTime. Built by hand — **no `DateFormatter` anywhere in
    /// this app** (build 16's rule, after a Buddhist-calendar year leaked into the Log pane),
    /// and this one would render Thai digits on this Mac if it were allowed to.
    static func stamp(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let p = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(format: "%02d%02d%02d%02d%02d%02dZ", (p.year ?? 0) % 100, p.month ?? 0,
                      p.day ?? 0, p.hour ?? 0, p.minute ?? 0, p.second ?? 0)
    }

    /// `openssl x509 -hash` / `openssl crl -hash` — the subject hash `ca_path` looks a file up
    /// by. OpenSSL reads `<hash>.0` for a certificate and `<hash>.r0` for a CRL, which is what
    /// `c_rehash` writes and what this app writes without needing `c_rehash` at all.
    static func subjectHash(certificate file: String) -> [String] { ["x509", "-in", file, "-noout", "-hash"] }
    static func issuerHash(crl file: String) -> [String] { ["crl", "-in", file, "-noout", "-hash"] }

    static func certificateLinkName(hash: String) -> String { "\(hash).0" }
    static func crlLinkName(hash: String) -> String { "\(hash).r0" }

    /// `openssl` prints the hash on a line of its own, sometimes after a warning.
    static func hash(inOutput output: String) -> String? {
        output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.count == 8 && $0.allSatisfy(\.isHexDigit) }
    }

    /// `serial=0A2B…` out of `openssl x509 -noout -serial`, lower-cased.
    static func serial(inOutput output: String) -> String? {
        for line in output.split(separator: "\n") where line.hasPrefix("serial=") {
            let value = line.dropFirst("serial=".count).trimmingCharacters(in: .whitespaces)
            if !value.isEmpty, value.allSatisfy(\.isHexDigit) { return value.lowercased() }
        }
        return nil
    }
}

// MARK: - The index the app keeps

/// `certs/ca-db/clients.json` — every certificate this lab has issued, and which of them are
/// revoked.
///
/// It is the app's own record rather than `openssl ca`'s `index.txt` because that file is a
/// second place for the same state to live, in a format with no room for anything this app
/// wants to show. `index.txt` is **written from** this, immediately before `-gencrl`, and is
/// never read back.
nonisolated struct ClientCertificateIndex: Codable, Sendable, Equatable {
    var certificates: [ClientCertificate] = []

    /// Newest first, which is the order the Certificates pane shows.
    var ordered: [ClientCertificate] { certificates.sorted { $0.issued > $1.issued } }

    var revoked: [ClientCertificate] { certificates.filter { $0.revoked != nil } }

    mutating func record(_ certificate: ClientCertificate) {
        certificates.removeAll { $0.serial == certificate.serial }
        certificates.append(certificate)
    }

    /// Certificates the current CA signed, i.e. the ones a revocation can still name.
    var live: [ClientCertificate] { certificates.filter { $0.supersededAt == nil } }

    /// Returns false when there was nothing of that serial to revoke, or it was revoked
    /// already — the caller says so rather than writing a CRL for nothing.
    mutating func revoke(serial: String, at date: Date = Date()) -> Bool {
        guard let index = certificates.firstIndex(where: {
            $0.serial.caseInsensitiveCompare(serial) == .orderedSame
        }), certificates[index].revoked == nil else { return false }
        certificates[index].revoked = date
        return true
    }

    /// **A new CA has been created: every certificate the old one signed is now useless**
    /// (build 25, QA H-4). Returns how many were marked, so the pane can say so and a caller
    /// with nothing to mark can skip the write.
    ///
    /// Already-superseded entries are left at their original date — a second new CA does not
    /// make them any more superseded — and a revoked one keeps its revocation, because
    /// "somebody revoked this" is the more informative of the two.
    @discardableResult
    mutating func supersedeAll(at date: Date = Date()) -> Int {
        var marked = 0
        for index in certificates.indices where certificates[index].supersededAt == nil {
            certificates[index].supersededAt = date
            marked += 1
        }
        return marked
    }

    /// **What the New CA confirmation has to say before the button is pressed** (H-4: "the
    /// sheet before New CA must say how many client certificates it will invalidate").
    func newCAWarning(on date: Date = Date()) -> String {
        let doomed = certificates.filter { $0.status(on: date) == .valid }.count
        guard doomed > 0 else {
            return "Every client that trusted the old CA will have to install the new one."
        }
        return "Every client that trusted the old CA will have to install the new one, and "
            + "\(doomed) client certificate\(doomed == 1 ? "" : "s") this lab has issued "
            + "\(doomed == 1 ? "stops" : "stop") authenticating — \(doomed == 1 ? "it was" : "they were") "
            + "signed by the CA that is about to be replaced. Issue "
            + "\(doomed == 1 ? "a new one" : "new ones") afterwards."
    }

    /// What the Users pane says under the button: "2 issued, 1 revoked".
    func summary(for username: String, on date: Date = Date()) -> String? {
        let mine = certificates.filter { $0.username.caseInsensitiveCompare(username) == .orderedSame }
        guard !mine.isEmpty else { return nil }
        let live = mine.filter { $0.status(on: date) == .valid }.count
        let gone = mine.count - live
        if gone == 0 { return live == 1 ? "1 certificate" : "\(live) certificates" }
        return "\(live) valid, \(gone) revoked, superseded or expired"
    }

    /// The newest certificate for this account that Revoke could still act on — what the
    /// Users inspector's Revoke button aims at (build 25, QA M-7).
    func revocable(for username: String) -> ClientCertificate? {
        ordered.first {
            $0.username.caseInsensitiveCompare(username) == .orderedSame
                && $0.revoked == nil && $0.supersededAt == nil
        }
    }
}

// MARK: - What a reissue costs

/// **What each of the three reissue buttons touches, and what it restarts** (build 25 — QA
/// M-25 and H-9).
///
/// Both **Reissue…** buttons carried an ellipsis and asked nothing, while the far more
/// alarming-sounding **New CA…** was the only one with a confirmation. The RADIUS one restarts
/// radiusd and, by the group's own help text, breaks every Apple device that pinned the old
/// leaf when its user tapped Trust; the directory one restarts slapd. Saying so is most of the
/// fix, and saying it in one place is what keeps the three sentences from drifting.
nonisolated enum CertificateReissue {
    enum Leaf: String, Sendable, Equatable, CaseIterable {
        case ca, radius, directory, domainController
    }

    /// **Which leaves a New CA invalidates, and therefore reissues** (H-9).
    ///
    /// Build 24 reissued `server.pem` and, when the directory was set up for TLS, `ldap.pem` —
    /// and never `ad.pem`, because `ensureADCertificate` was reachable only from
    /// `ADController.tlsEnvironment` at DC start, where `force` is false and its SAN and name
    /// checks pass. So after a New CA a domain controller went on serving a leaf signed by a
    /// CA that no longer existed, while `TLS_CA_B64` handed the container the new one.
    static func leavesOfNewCA(backend: DirectoryBackend, directoryNeedsTLS: Bool) -> [Leaf] {
        var out: [Leaf] = [.ca, .radius]
        switch backend {
        case .activeDirectory: out.append(.domainController)
        case .openLDAP: if directoryNeedsTLS { out.append(.directory) }
        }
        return out
    }

    /// What the confirmation says will restart, for one leaf.
    static func restartNote(_ leaf: Leaf) -> String {
        switch leaf {
        case .ca:
            "The RADIUS server restarts, and so does whichever directory is running."
        case .radius:
            "The RADIUS server restarts. Apple devices pin this certificate when their user "
                + "taps Trust, so every one of them has to trust the new leaf before it will "
                + "connect again."
        case .directory:
            "The LDAP server restarts. A device that already trusts this lab's CA needs "
                + "nothing new."
        case .domainController:
            "The domain controller restarts, which takes about a minute. A device that "
                + "already trusts this lab's CA needs nothing new."
        }
    }

    static func title(_ leaf: Leaf) -> String {
        switch leaf {
        case .ca: "Create a new CA?"
        case .radius: "Reissue the RADIUS server certificate?"
        case .directory: "Reissue the LDAP server certificate?"
        case .domainController: "Reissue the domain controller certificate?"
        }
    }
}

// MARK: - The app's side of it

import Combine

extension AppModel {

    /// Every certificate this lab has issued, newest first. Read from disk each time: it is a
    /// small file, it changes only when this app changes it, and a published mirror would be
    /// a second copy of the truth.
    var clientCertificates: [ClientCertificate] { env.loadClientIndex().ordered }

    /// Issue one, write the `.p12`, and tell radiusd nothing — an issued certificate changes
    /// no configuration. Returns nil on success or the sentence that went wrong.
    func issueClientCertificate(username: String, days: Int, password: String,
                                to destination: URL) async -> String? {
        let principal = ClientCertificateNames.principal(
            username: username,
            domain: doc.settings.directoryBackend == .activeDirectory
                ? doc.settings.ad.realm : doc.settings.dnsDomain)
        do {
            let issued = try await env.issueClientCertificate(
                username: username, principal: principal, days: days,
                bundlePassword: password, to: destination)
            radius.note("—— issued a client certificate for \(username) (serial \(issued.serial))")
            objectWillChange.send()
            return nil
        } catch let failure as LabEnvironment.Failure {
            transferDetail = failure.detail
            return failure.message
        } catch {
            return error.localizedDescription
        }
    }

    /// Revoke one, rewrite the CRL, and **restart radiusd** — which is not what a directory
    /// edit does, and is not what this was written to do.
    ///
    /// **Measured on 3.2.10, because the answer was not the expected one.** A revocation was
    /// meant to be a coalesced `SIGHUP`, exactly like a user being renamed: `check_crl` and
    /// `ca_path` are already in the configuration radiusd parsed, so only the *contents* of a
    /// file change. They are not re-read. `rlm_eap` builds its `SSL_CTX` — and loads the CRL
    /// into that context's X509 store — at instantiation, and a HUP does not re-instantiate
    /// it. The sequence, on a throwaway lab, with the pid watched throughout:
    ///
    ///     issue, EAP-TLS as alice        SUCCESS
    ///     revoke, CRL carries the serial, HUP, pid unchanged
    ///     EAP-TLS as alice               SUCCESS   ← the revocation had no effect
    ///     restart radiusd
    ///     EAP-TLS as alice               FAILURE   "(TLS) OpenSSL says error 23 : certificate revoked"
    ///
    /// A revocation that does not take effect until somebody happens to restart the server is
    /// worse than no revocation at all, because the pane would say the certificate was dead.
    /// So this restarts, and the pane says so before the button is pressed. Issuing still
    /// needs nothing: a new certificate is signed by a CA radiusd already trusts.
    func revokeClientCertificate(serial: String) async -> String? {
        do {
            guard try await env.revokeClientCertificate(serial: serial) else {
                return "That certificate is already revoked."
            }
            radius.note("—— revoked the client certificate \(serial)")
            if radius.isRunning {
                // rlm_eap loads the CRL when it is instantiated and a signal does not
                // re-instantiate it — see the measurement above.
                radius.note("—— restarting RADIUS so it reads the new revocation list")
                await radius.stop()
                // `.lab`, not the switch's pin (build 25, QA M-29): a revocation puts back
                // what was running and must not move an AD lab onto OpenLDAP.
                await startRadiusForLab()
            }
            objectWillChange.send()
            return nil
        } catch let failure as LabEnvironment.Failure {
            return failure.message
        } catch {
            return error.localizedDescription
        }
    }

    /// `-clientCertProbe <path>` — issue a certificate for alice into that `.p12`, print the
    /// serial, and then wait for `<path>.revoke` to appear before revoking it.
    ///
    /// Two halves rather than one because the claim being tested needs the server asked in
    /// between: EAP-TLS with this certificate is accepted, it is revoked, and EAP-TLS with the
    /// **same** certificate is refused — without radiusd restarting, which the suite checks by
    /// watching the pid.
    func runClientCertificateProbe(_ path: String) async {
        setvbuf(stdout, nil, _IONBF, 0)
        func say(_ text: String) { print("[cert] \(text)") }
        let destination = URL(fileURLWithPath: path)
        let password = "sheep-p12-2026"
        // **Build 24, item 7**: which account is issued to is a parameter now, so the `ad`
        // suite can point it at a real `CN=Users` account — the container the owner's whole
        // domain lives in, and the one the Users pane used to hide the button for.
        let who = CommandLine.value(after: "-clientCertUser") ?? "alice"
        say("subject \(who)")
        say("may-issue \(DirectoryNames.mayIssueClientCertificate(username: who, dn: directory.users.first { $0.username.caseInsensitiveCompare(who) == .orderedSame }?.dn ?? "") ? "yes" : "NO")")

        if let problem = await issueClientCertificate(username: who, days: 365,
                                                      password: password, to: destination) {
            say("issue FAILED \(problem.replacingOccurrences(of: "\n", with: " · "))")
            say("done")
            return
        }
        guard let issued = clientCertificates.first else {
            say("issue FAILED nothing was recorded in the index")
            say("done")
            return
        }
        say("issued serial=\(issued.serial) user=\(issued.username) principal=\(issued.principal)")
        say("bundle-bytes \(AppModel.bytes(at: destination))")
        say("index \(clientCertificates.count)")
        say("radiusd-pid \(radiusPIDForProbe())")
        say("ready")

        // **`-clientCertNewCA 1`** (build 25, QA H-4): instead of waiting for a revocation,
        // replace the CA and report what that did to the certificate just issued. Build 24
        // left `certs/clients/` and `ca-db/clients.json` untouched here, so the pane went on
        // calling a certificate that could no longer authenticate "Valid".
        if CommandLine.value(after: "-clientCertNewCA") == "1" {
            say("new-ca-warning \(env.loadClientIndex().newCAWarning())")
            await regenerateCertificates(includingCA: true)
            let after = env.loadClientIndex()
            let mine = after.certificates.first { $0.serial == issued.serial }
            say("after-new-ca status \(mine?.status().rawValue ?? "MISSING")")
            say("after-new-ca label \(mine?.status().label ?? "-")")
            say("after-new-ca superseded-at \(mine?.supersededAt == nil ? "NONE" : "set")")
            say("after-new-ca live-count \(after.live.count)")
            say("after-new-ca revocable \(after.revocable(for: who) == nil ? "none" : "SOME")")
            say("after-new-ca summary \(after.summary(for: who) ?? "-")")
            say("after-new-ca radius-running \(radius.isRunning ? "yes" : "no")")
            say("done")
            return
        }

        let flag = URL(fileURLWithPath: path + ".revoke")
        for _ in 0..<600 {
            if FileManager.default.fileExists(atPath: flag.path) { break }
            try? await Task.sleep(for: .milliseconds(200))
        }
        guard FileManager.default.fileExists(atPath: flag.path) else {
            say("revoke SKIPPED nothing asked for it")
            say("done")
            return
        }
        if let problem = await revokeClientCertificate(serial: issued.serial) {
            say("revoke FAILED \(problem)")
        } else {
            say("revoked \(issued.serial)")
        }
        say("radiusd-pid-after \(radiusPIDForProbe())")
        say("radius-running \(radius.isRunning ? "yes" : "no")")
        say("revoked-count \(env.loadClientIndex().revoked.count)")
        say("done")
    }

    /// The server's own pid, as the supervisor recorded it — what a restart would change.
    private func radiusPIDForProbe() -> String {
        (try? String(contentsOf: env.pidFile("radius"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "-"
    }
}
