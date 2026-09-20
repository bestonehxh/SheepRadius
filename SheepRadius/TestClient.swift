import Foundation
import Security

// MARK: - Where a test is aimed

nonisolated enum TestTarget: String, Codable, CaseIterable, Sendable {
    case thisMac, other

    var label: String {
        switch self {
        case .thisMac: "This Mac (SheepRadius)"
        case .other: "Another server…"
        }
    }
}

nonisolated enum CredentialSource: String, Codable, CaseIterable, Sendable {
    case table, manual

    var label: String {
        switch self {
        case .table: "User from table"
        case .manual: "Enter manually"
        }
    }
}

// MARK: - RADIUS

nonisolated enum RadiusMethod: String, Codable, CaseIterable, Sendable {
    case pap, chap, mschap, eapMD5

    var label: String {
        switch self {
        case .pap: "PAP"
        case .chap: "CHAP"
        case .mschap: "MS-CHAP"
        case .eapMD5: "EAP-MD5"
        }
    }

    /// The attribute the cleartext password is carried in. radclient does the
    /// challenge-response encoding itself at send time, so all four take it in the clear.
    var passwordAttribute: String {
        switch self {
        case .chap: "CHAP-Password"
        case .mschap: "MS-CHAP-Password"
        case .eapMD5: "Cleartext-Password"
        case .pap: "User-Password"
        }
    }

    /// EAP-MD5 is radeapclient's job; the rest are radclient's.
    var needsEAPClient: Bool { self == .eapMD5 }
}

nonisolated enum RadiusExchange: String, Codable, CaseIterable, Sendable {
    case authentication, accountingStart, accountingStop, statusServer

    var label: String {
        switch self {
        case .authentication: "Authentication"
        case .accountingStart: "Accounting Start"
        case .accountingStop: "Accounting Stop"
        case .statusServer: "Status-Server ping"
        }
    }

    /// radclient's own command word.
    var command: String {
        switch self {
        case .authentication: "auth"
        case .accountingStart, .accountingStop: "acct"
        case .statusServer: "status"
        }
    }

    var usesAccountingPort: Bool { self == .accountingStart || self == .accountingStop }
    var needsCredentials: Bool { self == .authentication }
}

/// Everything that goes into one RADIUS request. Pure, so the attribute list it produces is
/// unit-tested without a server anywhere near.
nonisolated struct RadiusRequest: Sendable, Equatable {
    var username = ""
    var password = ""
    var method = RadiusMethod.pap
    var exchange = RadiusExchange.authentication
    var nasIPAddress = ""
    var nasIdentifier = ""
    var nasPortType = ""
    var calledStationID = ""
    var callingStationID = ""
    /// Free `Name = value` lines, same syntax and validation as a group's reply attributes.
    var extra = ""

    /// The attribute list radclient reads on stdin.
    ///
    /// **Everything typed by a person is quoted and escaped here**, and nothing is ever
    /// interpolated into a shell command: `Shell.run` takes an argv, and this text goes down
    /// the child's stdin. A username of `"; rm -rf /` is a username.
    func attributeLines() -> String {
        var lines: [String] = []
        if exchange.needsCredentials || exchange.usesAccountingPort {
            lines.append("User-Name = \(Self.quoted(username))")
        }
        if exchange.needsCredentials {
            lines.append("\(method.passwordAttribute) = \(Self.quoted(password))")
        }
        switch exchange {
        case .accountingStart: lines.append("Acct-Status-Type = Start")
        case .accountingStop:
            lines.append("Acct-Status-Type = Stop")
            lines.append("Acct-Session-Time = 60")
        default: break
        }
        if exchange.usesAccountingPort {
            lines.append("Acct-Session-Id = \(Self.quoted("sheepradius-test"))")
        }
        if !nasIPAddress.isEmpty { lines.append("NAS-IP-Address = \(nasIPAddress)") }
        if !nasIdentifier.isEmpty { lines.append("NAS-Identifier = \(Self.quoted(nasIdentifier))") }
        if !nasPortType.isEmpty { lines.append("NAS-Port-Type = \(nasPortType)") }
        if !calledStationID.isEmpty { lines.append("Called-Station-Id = \(Self.quoted(calledStationID))") }
        if !callingStationID.isEmpty { lines.append("Calling-Station-Id = \(Self.quoted(callingStationID))") }
        if exchange != .statusServer { lines.append("NAS-Port = 0") }
        // A zero placeholder: radclient computes the real HMAC. Status-Server is *required*
        // to carry one, and a server that gets one without it simply does not answer.
        lines.append("Message-Authenticator = 0x00")
        for attribute in ReplyAttribute.parse(extra) {
            lines.append("\(attribute.name) \(attribute.op) \(attribute.value)")
        }
        if method.needsEAPClient, exchange.needsCredentials {
            lines += ["EAP-Code = Response", "EAP-Type-Identity = \(Self.quoted(username))"]
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// A double-quoted attribute value, safe to put in the list.
    ///
    /// `\` and `"` are escaped because either would end the value early and let the rest be
    /// read as more attributes — but **the newline matters just as much**, and is easy to
    /// forget: radclient reads one attribute per line, so a username containing a line break
    /// smuggles in a whole extra attribute. A unit test pins that case; it was a real hole in
    /// the first version of this function.
    static func quoted(_ value: String) -> String {
        var out = ""
        for character in value {
            switch character {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default: out.append(character)
            }
        }
        return "\"\(out)\""
    }

    var problems: [String] {
        var out: [String] = []
        if exchange.needsCredentials, username.isEmpty { out.append("Enter a username.") }
        if !nasIPAddress.isEmpty, !Validation.isValidAddress(nasIPAddress) {
            out.append("NAS-IP-Address must be an IPv4 address.")
        }
        out += Validation.replyAttributeProblems(extra, in: "Extra attributes")
        return out
    }
}

/// One attribute out of a reply.
nonisolated struct RadiusReplyItem: Sendable, Equatable, Identifiable {
    var id: String { name + value }
    var name: String
    var value: String
}

nonisolated struct RadiusOutcome: Sendable, Equatable {
    enum Verdict: String, Sendable {
        case accept, reject, challenge, accountingResponse, other, noResponse

        var label: String {
            switch self {
            case .accept: "Access-Accept"
            case .reject: "Access-Reject"
            case .challenge: "Access-Challenge"
            case .accountingResponse: "Accounting-Response"
            case .other: "answered"
            case .noResponse: "No response"
            }
        }

        var isGood: Bool { self == .accept || self == .accountingResponse }
    }

    var verdict = Verdict.noResponse
    var attributes: [RadiusReplyItem] = []
    /// "VLAN 10", when the three tunnel attributes are all there.
    var vlan: String?
}

nonisolated enum RadiusReplyParser {
    /// radclient `-x` prints `Received <Code> Id <n> from …` and then the reply's attributes,
    /// one per indented line, until the next unindented line.
    static func parse(_ output: String) -> RadiusOutcome {
        var outcome = RadiusOutcome()
        var collecting = false
        for raw in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            let indented = line.hasPrefix("\t") || line.hasPrefix("  ")
            if !indented {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("Received ") {
                    collecting = true
                    outcome.verdict = verdict(in: trimmed)
                    outcome.attributes.removeAll()
                } else if collecting {
                    collecting = false
                }
                continue
            }
            guard collecting else { continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let equals = trimmed.firstIndex(of: "=") else { continue }
            let name = untagged(String(trimmed[trimmed.startIndex..<equals]).trimmingCharacters(in: .whitespaces))
            var value = String(trimmed[trimmed.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            guard !name.isEmpty else { continue }
            outcome.attributes.append(RadiusReplyItem(name: name, value: value))
        }
        outcome.vlan = vlanSummary(outcome.attributes)
        return outcome
    }

    /// `Tunnel-Type:0` → `Tunnel-Type`.
    ///
    /// RFC 2868 attributes carry a **tag** — a small integer that groups a set of tunnel
    /// attributes together when a server sends several. radclient prints it as part of the
    /// name, which is how the VLAN summary first came back empty: the reply really does say
    /// `Tunnel-Private-Group-Id:0`, not `Tunnel-Private-Group-Id`. For one reply the tag is
    /// noise, so it is dropped from the name shown and matched on.
    static func untagged(_ name: String) -> String {
        guard let colon = name.lastIndex(of: ":") else { return name }
        let tag = name[name.index(after: colon)...]
        guard !tag.isEmpty, tag.allSatisfy(\.isNumber) else { return name }
        return String(name[name.startIndex..<colon])
    }

    private static func verdict(in line: String) -> RadiusOutcome.Verdict {
        if line.contains("Access-Accept") { return .accept }
        if line.contains("Access-Reject") { return .reject }
        if line.contains("Access-Challenge") { return .challenge }
        if line.contains("Accounting-Response") { return .accountingResponse }
        return .other
    }

    /// The three tunnel attributes that mean "put this port in VLAN n" are meaningless apart
    /// and obvious together, so they are shown as one line and left in the list as well.
    static func vlanSummary(_ attributes: [RadiusReplyItem]) -> String? {
        func value(_ name: String) -> String? {
            attributes.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
        }
        guard let id = value("Tunnel-Private-Group-Id"), !id.isEmpty else { return nil }
        let type = value("Tunnel-Type") ?? ""
        guard type.isEmpty || type.uppercased().contains("VLAN") else { return nil }
        return "VLAN \(id)"
    }

    /// A RADIUS server that dislikes a request usually says nothing at all, which is the least
    /// helpful failure in the protocol — so the app says what it normally means.
    static let noResponseExplanation = """
    Nothing came back before the timeout. A RADIUS server answers a request it does not like \
    by discarding it, so “no response” nearly always means one of:

    • the shared secret is wrong — the server drops the packet silently
    • this Mac's IP is not registered as a client / NAS on that server, for the same reason
    • a firewall between here and there, or the wrong port

    Raising the timeout or the retry count only helps when the network is slow, which is the \
    least likely of the three.
    """
}

// MARK: - Tunnelled EAP (eapol_test)

/// The EAP methods that need a real supplicant, which `eapol_test` simulates.
///
/// `radclient` and `radeapclient` stop at PAP / CHAP / MS-CHAP / EAP-MD5, so before
/// `eapol_test` was bundled nothing on this Mac had ever executed the tunnelled half of the
/// generated configuration — including the whole inner/outer rule arrangement.
nonisolated enum EAPMethod: String, Codable, CaseIterable, Sendable {
    case peapMSCHAPv2, ttlsPAP, ttlsMSCHAPv2, eapTLS

    var label: String {
        switch self {
        case .peapMSCHAPv2: "PEAP-MSCHAPv2"
        case .ttlsPAP: "EAP-TTLS (PAP)"
        case .ttlsMSCHAPv2: "EAP-TTLS (MSCHAPv2)"
        case .eapTLS: "EAP-TLS"
        }
    }

    /// What goes in the network block's `eap=` line.
    var outerMethod: String {
        switch self {
        case .peapMSCHAPv2: "PEAP"
        case .ttlsPAP, .ttlsMSCHAPv2: "TTLS"
        case .eapTLS: "TLS"
        }
    }

    /// The `phase2=` value, or nil for the one method that has no inner exchange.
    var phase2: String? {
        switch self {
        case .peapMSCHAPv2: "auth=MSCHAPV2"
        case .ttlsPAP: "auth=PAP"
        case .ttlsMSCHAPv2: "auth=MSCHAPV2"
        case .eapTLS: nil
        }
    }

    /// EAP-TLS proves the client with a certificate and never sends a password.
    var usesPassword: Bool { self != .eapTLS }
    var usesClientCertificate: Bool { self == .eapTLS }
    /// PEAP and TTLS have a real inner tunnel; EAP-TLS does not, which is why its rules run
    /// in `server default` rather than in `inner-tunnel`. Measured, not assumed.
    var hasInnerTunnel: Bool { self != .eapTLS }
    /// Only a tunnel can hide the real identity, so the outer identity field is pointless for
    /// EAP-TLS — the certificate is in the clear either way.
    var supportsAnonymousOuter: Bool { hasInnerTunnel }
}

/// How the supplicant should check the certificate the server presents.
nonisolated enum EAPServerValidation: String, Codable, CaseIterable, Sendable {
    case labCA, caFile, none

    var label: String {
        switch self {
        case .labCA: "This Mac's test CA"
        case .caFile: "A CA file…"
        case .none: "Don't verify (insecure)"
        }
    }

    var isInsecure: Bool { self == .none }
}

/// Everything that goes into one `eapol_test` run. Pure: the configuration text and the
/// argument list are unit-tested with no server and no child process anywhere near them.
nonisolated struct EAPTestRequest: Sendable, Equatable {
    var method = EAPMethod.peapMSCHAPv2
    var identity = ""
    var password = ""
    /// The identity the *outer* exchange shows — `anonymous@lab` and friends. Empty means
    /// send the real one outside too, which is what most kit does by default.
    var anonymousIdentity = ""
    var validation = EAPServerValidation.labCA
    /// Used when `validation == .caFile`.
    var caFile = ""
    /// `domain_suffix_match`: the supplicant refuses a certificate whose name does not end
    /// with this. Empty means "any name signed by that CA", which is what most test kit does.
    var expectedServerName = ""
    var clientCertificate = ""
    var clientKey = ""
    var clientKeyPassword = ""
    /// wpa_supplicant disables TLS 1.3 for EAP unless the network block asks for it, so the
    /// pane offers it explicitly rather than silently always landing on 1.2.
    var allowTLS13 = false

    // The outer request's own attributes, mapped onto eapol_test's `-N` options.
    var nasIPAddress = ""
    var nasIdentifier = ""
    var nasPortType = ""
    var calledStationID = ""
    var callingStationID = ""
    var timeout = 15

    /// The `network={…}` block written to a 0600 temporary file.
    ///
    /// `caPath` is the resolved CA: the lab's own `ca.pem` for `.labCA`, the chosen file for
    /// `.caFile`, nil for `.none`. Resolving it here rather than inside keeps this pure.
    func configuration(caPath: String?) -> String {
        var lines = ["network={", "\tkey_mgmt=IEEE8021X", "\teap=\(method.outerMethod)"]
        lines.append("\tidentity=\(Self.escaped(identity))")
        if method.supportsAnonymousOuter, !anonymousIdentity.isEmpty {
            lines.append("\tanonymous_identity=\(Self.escaped(anonymousIdentity))")
        }
        if method.usesPassword {
            lines.append("\tpassword=\(Self.escaped(password))")
        }
        if let caPath, !caPath.isEmpty {
            lines.append("\tca_cert=\(Self.escaped(caPath))")
        }
        if !expectedServerName.isEmpty {
            lines.append("\tdomain_suffix_match=\(Self.escaped(expectedServerName))")
        }
        if method.usesClientCertificate {
            if !clientCertificate.isEmpty { lines.append("\tclient_cert=\(Self.escaped(clientCertificate))") }
            if !clientKey.isEmpty { lines.append("\tprivate_key=\(Self.escaped(clientKey))") }
            if !clientKeyPassword.isEmpty {
                lines.append("\tprivate_key_passwd=\(Self.escaped(clientKeyPassword))")
            }
        }
        // Measured against our own radiusd: with tls_max_version = "1.3" the handshake still
        // lands on TLS 1.2 unless the *client* asks, because wpa_supplicant disables 1.3 for
        // EAP by default (PEAP over TLS 1.3 is not a standard). This is the switch.
        if allowTLS13 { lines.append("\tphase1=\(Self.escaped("tls_disable_tlsv1_3=0"))") }
        if let phase2 = method.phase2 { lines.append("\tphase2=\(Self.escaped(phase2))") }
        lines.append("}")
        return lines.joined(separator: "\n") + "\n"
    }

    /// A wpa_supplicant configuration value that cannot break out of its own line.
    ///
    /// **A plain `"…"` value in this format has no escape mechanism at all.** The parser
    /// (`wpa_config_parse_string`) takes everything between the first quote and the *last*
    /// quote on the line and demands that the last quote end the line, so a value holding a
    /// newline does not produce a broken string — it produces **another configuration line**,
    /// which is how a password could set `ca_cert` or turn verification off.
    ///
    /// The `P"…"` form is the one that is safe: it is decoded by `printf_decode`, which
    /// understands `\\`, `\"`, `\n`, `\r`, `\t` and `\xNN`. Everything a person types goes out
    /// in that form.
    ///
    /// **Every byte above 127 goes out as `\xNN`** (build 20, audit N-16), and that is the
    /// whole of the finding. This walks the value's UTF-8 **bytes**; the line it builds is a
    /// Swift `String`, which is written to the file as UTF-8 again. So appending a byte of
    /// 0xE0 as `Character(UnicodeScalar(0xE0))` — U+00E0 — put **two** bytes, 0xC3 0xA0, into
    /// the file. A Thai password came out of here as mojibake and PEAP-MSCHAPv2 rejected the
    /// right password; measured against the bundled eapol_test and our own radiusd before the
    /// fix (`verdict=reject`) and after it (`verdict=accept`), which is the row the live
    /// suite now pins. Hex is not a nicety here: this format has no way to say "these bytes"
    /// other than `\xNN`, and ASCII is left readable so a configuration a person looks at is
    /// still legible.
    static func escaped(_ value: String) -> String {
        var out = ""
        for byte in Array(value.utf8) {
            switch byte {
            case UInt8(ascii: "\\"): out += "\\\\"
            case UInt8(ascii: "\""): out += "\\\""
            case 0x0A: out += "\\n"
            case 0x0D: out += "\\r"
            case 0x09: out += "\\t"
            case 0x00..<0x20, 0x7F, 0x80...0xFF: out += String(format: "\\x%02x", byte)
            default: out.append(Character(UnicodeScalar(byte)))
            }
        }
        return "P\"\(out)\""
    }

    /// eapol_test's `-N attr_id:syntax:value` options, one per attribute the outer request
    /// should carry.
    ///
    /// It has no dictionary: attributes are numeric and the syntax letter is `s` (text), `d`
    /// (a 32-bit integer, written big-endian) or `x` (raw hex). There is no letter for an IP
    /// address — but a RADIUS `ipaddr` *is* four bytes in network order, so NAS-IP-Address
    /// goes out as `4:x:<8 hex digits>` rather than through `d`, whose `atoi` would overflow
    /// on anything above 127.255.255.255.
    ///
    /// eapol_test sends NAS-IP-Address, Calling-Station-Id, Framed-MTU, NAS-Port-Type,
    /// Service-Type and Connect-Info of its own accord and skips its default whenever `-N`
    /// names the same attribute, so these override rather than duplicate.
    func attributeArguments() -> [String] {
        var out: [String] = []
        if !nasIPAddress.isEmpty, let hex = Self.ipv4Hex(nasIPAddress) {
            out += ["-N", "4:x:\(hex)"]
        }
        if !nasIdentifier.isEmpty { out += ["-N", "32:s:\(nasIdentifier)"] }
        if !calledStationID.isEmpty { out += ["-N", "30:s:\(calledStationID)"] }
        if !callingStationID.isEmpty { out += ["-N", "31:s:\(callingStationID)"] }
        if !nasPortType.isEmpty, let code = Self.portTypeCodes[nasPortType] {
            out += ["-N", "61:d:\(code)"]
        }
        return out
    }

    /// The NAS-Port-Type names the Test pane offers, and their RFC 2865 values. eapol_test
    /// cannot look a name up, so the mapping lives here — and is the same list the Policy
    /// rules use, so a rule written against "Wireless-802.11" is testable from this pane.
    static let portTypeCodes: [String: Int] = [
        "Async": 0, "Sync": 1, "ISDN": 2, "ISDN-V120": 3, "ISDN-V110": 4,
        "Virtual": 5, "PIAFS": 6, "HDLC-Clear-Channel": 7, "X.25": 8, "X.75": 9,
        "G.3-Fax": 10, "SDSL": 11, "ADSL-CAP": 12, "ADSL-DMT": 13, "IDSL": 14,
        "Ethernet": 15, "xDSL": 16, "Cable": 17, "Wireless-Other": 18,
        "Wireless-802.11": 19,
    ]

    /// What eapol_test puts in the request when we do not.
    ///
    /// It is a supplicant simulator, so it fills in what a supplicant would: NAS-Port-Type 19
    /// (Wireless-802.11), a Calling-Station-Id from its own MAC, Framed-MTU 1400, Service-Type
    /// Framed and a Connect-Info string. Only the first two are visible to a Policy rule, and
    /// **a prediction that ignores them is a prediction about a different request** — which is
    /// exactly how the first run of the tunnelled equivalence matrix "failed": a rule keyed on
    /// Wireless-802.11 fired for rows that had asked for no port type at all.
    static let impliedPortType = RulePortType.wireless.rawValue
    static let impliedCallingStationID = "02-00-00-00-00-01"

    /// `127.0.0.1` → `7f000001`, or nil when it is not four octets.
    static func ipv4Hex(_ address: String) -> String? {
        let parts = address.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var out = ""
        for part in parts {
            guard let byte = UInt8(part) else { return nil }
            out += String(format: "%02x", byte)
        }
        return out
    }

    var problems: [String] {
        var out: [String] = []
        if identity.isEmpty { out.append("Enter a username.") }
        if method.usesPassword, password.isEmpty { out.append("Enter a password.") }
        if method.usesClientCertificate {
            if clientCertificate.isEmpty { out.append("Choose a client certificate (EAP-TLS).") }
            if clientKey.isEmpty { out.append("Choose the client certificate's private key (EAP-TLS).") }
        }
        if validation == .caFile, caFile.isEmpty { out.append("Choose a CA file, or pick another verification mode.") }
        if !nasIPAddress.isEmpty, Self.ipv4Hex(nasIPAddress) == nil {
            out.append("NAS-IP-Address must be an IPv4 address.")
        }
        if !nasPortType.isEmpty, Self.portTypeCodes[nasPortType] == nil {
            out.append("eapol_test has no dictionary, so NAS-Port-Type must be one of the listed names.")
        }
        if timeout < 1 { out.append("The timeout must be at least one second.") }
        return out
    }
}

/// One certificate out of the chain the server presented.
nonisolated struct EAPServerCertificate: Sendable, Equatable, Identifiable {
    var id: String { "\(depth)-\(subject)" }
    var depth: Int
    var subject: String
    /// Filled in from `openssl x509` on the chain eapol_test wrote out with `-o`; the log
    /// line alone only carries the subject.
    var issuer: String = ""
    var notAfter: String = ""
    var subjectAlternativeNames: [String] = []

    var isLeaf: Bool { depth == 0 }
}

nonisolated struct EAPOutcome: Sendable, Equatable {
    enum Verdict: String, Sendable {
        case accept, reject, timeout, failedBeforeRADIUS

        var label: String {
            switch self {
            case .accept: "Access-Accept"
            case .reject: "Access-Reject"
            case .timeout: "Timed out"
            case .failedBeforeRADIUS: "Failed"
            }
        }

        var isGood: Bool { self == .accept }
    }

    var verdict = Verdict.timeout
    var attributes: [RadiusReplyItem] = []
    var vlan: String?
    /// `PEAP`, `TTLS`, `TLS` — what the server and the supplicant actually agreed on, which
    /// is not necessarily what was asked for.
    var negotiatedMethod: String?
    var tlsVersion: String?
    /// eapol_test never prints the cipher suite. For a test aimed at This Mac it is read out
    /// of our own radiusd debug stream instead (`TLS-Session-Cipher-Suite`), the same way
    /// "Rules fired" is; against another server it stays nil and the pane says so.
    var cipherSuite: String?
    var certificates: [EAPServerCertificate] = []
    var validationPassed: Bool?
    /// MS-MPPE-Send-Key / MS-MPPE-Recv-Key. Their absence from an Accept means the NAS has no
    /// keys to install and 802.1X on a real link would fail even though RADIUS said yes.
    var mppeKeysPresent = false
    /// A plain-words diagnosis, or nil when it worked.
    var explanation: String?
}

nonisolated enum EAPLogParser {
    /// Reads one `eapol_test` run.
    ///
    /// Everything here is anchored on output from real runs against our own radiusd — the
    /// fixtures in `Tests/unit.swift` are captured logs, not invented ones.
    /// `verifiedAgainstCA` says whether a CA was actually configured. It matters: eapol_test
    /// logs `remote certificate verification (param=success)` even when there was **no**
    /// `ca_cert` at all — with nothing to check against, "success" only means the handshake
    /// finished. Reporting that as "validated" would be the single most misleading thing this
    /// pane could say.
    static func parse(_ output: String, exitStatus: Int32, verifiedAgainstCA: Bool) -> EAPOutcome {
        var outcome = EAPOutcome()
        var lines: [String] = []
        for raw in output.split(separator: "\n", omittingEmptySubsequences: false) {
            lines.append(String(raw))
        }

        outcome.negotiatedMethod = negotiatedMethod(lines)
        outcome.tlsVersion = negotiatedTLSVersion(lines)
        outcome.certificates = certificates(lines)
        outcome.validationPassed = verifiedAgainstCA ? validationPassed(lines) : nil
        outcome.mppeKeysPresent = lines.contains { $0.hasPrefix("MS-MPPE-Send-Key") }
        outcome.attributes = replyAttributes(lines)
        outcome.vlan = RadiusReplyParser.vlanSummary(outcome.attributes)
        outcome.verdict = verdict(lines, exitStatus: exitStatus)
        outcome.explanation = explain(lines, outcome: outcome)
        return outcome
    }

    /// `EAP: Status notification: accept proposed method (param=PEAP)`.
    static func negotiatedMethod(_ lines: [String]) -> String? {
        let marker = "accept proposed method (param="
        for line in lines.reversed() where line.contains(marker) {
            guard let start = line.range(of: marker) else { continue }
            let rest = line[start.upperBound...]
            guard let close = rest.firstIndex(of: ")") else { continue }
            let value = String(rest[rest.startIndex..<close])
            if !value.isEmpty { return value }
        }
        return nil
    }

    /// The **last** `SSL: Using TLS version …`, never the first.
    ///
    /// The first one is printed while the ClientHello is being built and reports the highest
    /// version the *client* is willing to offer; only the one after `Handshake finished` is
    /// what was negotiated. A run against a server pinned to 1.2 by a client that offers 1.3
    /// prints both, in that order — which is exactly how a first-match parser would report
    /// TLS 1.3 for a TLS 1.2 session.
    static func negotiatedTLSVersion(_ lines: [String]) -> String? {
        let marker = "SSL: Using TLS version "
        for line in lines.reversed() where line.hasPrefix(marker) {
            return String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    /// `CTRL-EVENT-EAP-PEER-CERT depth=1 subject='/O=…/CN=…' hash=…`
    static func certificates(_ lines: [String]) -> [EAPServerCertificate] {
        var out: [EAPServerCertificate] = []
        for line in lines where line.hasPrefix("CTRL-EVENT-EAP-PEER-CERT ") {
            guard let depth = intField(line, "depth="), let subject = quotedField(line, "subject=") else { continue }
            if out.contains(where: { $0.depth == depth && $0.subject == subject }) { continue }
            out.append(EAPServerCertificate(depth: depth, subject: subject))
        }
        return out.sorted { $0.depth < $1.depth }
    }

    /// nil when TLS never got far enough to have an opinion.
    static func validationPassed(_ lines: [String]) -> Bool? {
        if lines.contains(where: { $0.hasPrefix("CTRL-EVENT-EAP-TLS-CERT-ERROR") }) { return false }
        if lines.contains(where: {
            $0.contains("remote certificate verification (param=success)")
        }) { return true }
        return nil
    }

    /// The certificate error, as eapol_test reported it: `(reason, subject, message)`.
    static func certificateError(_ lines: [String]) -> (reason: Int, subject: String, message: String)? {
        for line in lines where line.hasPrefix("CTRL-EVENT-EAP-TLS-CERT-ERROR") {
            let reason = intField(line, "reason=") ?? 0
            let subject = quotedField(line, "subject=") ?? ""
            let message = quotedField(line, "err=") ?? ""
            return (reason, subject, message)
        }
        return nil
    }

    /// The attributes of the **last** RADIUS reply, decoded out of eapol_test's own dump.
    ///
    /// The dump prints `   Attribute <n> (<name>) length=<n>` and then `      Value: …` —
    /// `'text'` for the attributes it knows are strings, a dotted quad for addresses, a
    /// decimal for integers, and bare hex for everything else, *including* the tunnel
    /// attributes. `length` counts the two-byte attribute header as well.
    static func replyAttributes(_ lines: [String]) -> [RadiusReplyItem] {
        var out: [RadiusReplyItem] = []
        var pendingName: String?
        var receiving = false
        for line in lines {
            if line.hasPrefix("RADIUS message: code=") {
                // eapol_test dumps the requests it **sends** in the same shape as the replies
                // it receives, so a parser that collects every `Attribute` block reports the
                // password it just sent as a reply attribute — the same trap radclient set.
                // Only a reply code is collected from, and a later reply supersedes an
                // earlier challenge.
                receiving = !line.hasPrefix("RADIUS message: code=1 ")
                if receiving { out.removeAll() }
                pendingName = nil
                continue
            }
            guard receiving else { continue }
            if line.hasPrefix("   Attribute ") {
                pendingName = attributeName(line)
                continue
            }
            if line.hasPrefix("      Value: "), let name = pendingName {
                let raw = String(line.dropFirst("      Value: ".count))
                out.append(RadiusReplyItem(name: name, value: decodedValue(name: name, raw: raw)))
                pendingName = nil
                continue
            }
            if !line.hasPrefix("      ") { pendingName = nil }
        }
        return out
    }

    /// `   Attribute 81 (Tunnel-Private-Group-Id) length=4` → `Tunnel-Private-Group-Id`.
    static func attributeName(_ line: String) -> String? {
        guard let open = line.firstIndex(of: "("), let close = line.range(of: ") length=")?.lowerBound,
              open < close else { return nil }
        let name = String(line[line.index(after: open)..<close])
        return name == "?Unknown?" ? nil : name
    }

    /// Turns one `Value:` line into something a person can read.
    ///
    /// The tunnel attributes arrive as hex because eapol_test types them as opaque, and RFC
    /// 2868 lets them carry a **tag** in the first byte: `Tunnel-Type` comes out as
    /// `0000000d` (tag 0, then a three-byte 13 = VLAN) and `Tunnel-Private-Group-Id` as
    /// `3130`, which is simply the text `10` with no tag at all — a tag is only present on a
    /// string attribute when the first byte is below 0x20.
    static func decodedValue(name: String, raw: String) -> String {
        let value = raw.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("'"), value.hasSuffix("'"), value.count >= 2 {
            return String(value.dropFirst().dropLast())
        }
        guard let bytes = hexBytes(value) else { return value }
        switch name {
        case "Tunnel-Type", "Tunnel-Medium-Type":
            guard bytes.count == 4 else { return value }
            let code = (Int(bytes[1]) << 16) | (Int(bytes[2]) << 8) | Int(bytes[3])
            if name == "Tunnel-Type" { return code == 13 ? "VLAN" : String(code) }
            return code == 6 ? "IEEE-802" : String(code)
        case "Tunnel-Private-Group-Id", "Tunnel-Client-Endpoint", "Tunnel-Server-Endpoint",
             "Tunnel-Assignment-Id", "Tunnel-Password":
            var body = bytes
            if body.count >= 2, body[0] < 0x20 { body.removeFirst() }
            return text(body) ?? value
        default:
            return text(bytes) ?? value
        }
    }

    private static func text(_ bytes: [UInt8]) -> String? {
        guard !bytes.isEmpty, bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) else { return nil }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func hexBytes(_ value: String) -> [UInt8]? {
        guard !value.isEmpty, value.count % 2 == 0,
              value.allSatisfy({ $0.isHexDigit }) else { return nil }
        var out: [UInt8] = []
        var index = value.startIndex
        while index < value.endIndex {
            let next = value.index(index, offsetBy: 2)
            guard let byte = UInt8(value[index..<next], radix: 16) else { return nil }
            out.append(byte)
            index = next
        }
        return out
    }

    /// eapol_test exits 0 on success and non-zero otherwise, but the exit status alone cannot
    /// tell a rejection from a TLS failure from never having been answered — so the log has
    /// the last word and the status is only a tie-breaker.
    static func verdict(_ lines: [String], exitStatus: Int32) -> EAPOutcome.Verdict {
        let sawAccept = lines.contains { $0.contains("(Access-Accept)") }
        if sawAccept, lines.contains(where: { $0.contains("CTRL-EVENT-EAP-SUCCESS") }) { return .accept }
        if lines.contains(where: { $0.contains("(Access-Reject)") }) { return .reject }
        if sawAccept { return .accept }
        // A handshake the client itself abandoned never reaches the server's verdict.
        if lines.contains(where: { $0.hasPrefix("CTRL-EVENT-EAP-TLS-CERT-ERROR") }) { return .failedBeforeRADIUS }
        if lines.contains(where: { $0.contains("EAPOL test timed out") }) { return .timeout }
        if lines.contains(where: { $0.contains("(Access-Challenge)") }) { return .timeout }
        return exitStatus == 0 ? .accept : .timeout
    }

    /// The whole point of the pane: a sentence instead of six hundred lines of hexdump.
    static func explain(_ lines: [String], outcome: EAPOutcome) -> String? {
        if let error = certificateError(lines) {
            switch error.reason {
            case 1:
                return """
                The server's certificate was not signed by the CA you chose. Its issuer is \
                \(error.subject.isEmpty ? "not one this CA knows" : error.subject) and OpenSSL said \
                “\(error.message)”. Pick “This Mac's test CA” when testing this Mac, or export the \
                right CA from the server you are aiming at.
                """
            case 9:
                return """
                The certificate is trusted but its name does not match: the server presented \
                \(error.subject) and the expected server name does not cover it. Clear the expected \
                name, or set it to a suffix of the certificate's own name.
                """
            default:
                return """
                The server's certificate was refused: “\(error.message)” \
                (\(error.subject)). Nothing was sent to the server after that.
                """
            }
        }
        if outcome.verdict == .reject {
            if let code = mschapErrorCode(lines) {
                return code == 691
                    ? "The tunnel came up and the server said the password is wrong (MSCHAPv2 E=691)."
                    : "The tunnel came up and the inner MSCHAPv2 exchange failed with E=\(code)."
            }
            if outcome.validationPassed == true || outcome.tlsVersion != nil {
                return """
                The TLS tunnel came up and the server verified its own certificate fine, so this is \
                a credentials or policy decision, not a certificate problem: wrong username or \
                password, the account disabled, or a Policy rule with a Reject action. \
                A supplicant only ever sees EAP-Failure here — the rule's own Reply-Message does \
                not survive a tunnel, so check Log for the reason.
                """
            }
            return "The server rejected the request."
        }
        if outcome.verdict == .timeout {
            return RadiusReplyParser.noResponseExplanation
        }
        if outcome.verdict == .failedBeforeRADIUS {
            return "The EAP exchange failed before the server reached a verdict."
        }
        if outcome.verdict == .accept, !outcome.mppeKeysPresent {
            return """
            Accepted, but the reply carries no MS-MPPE keys. RADIUS is happy and real 802.1X \
            would still fail, because the access point has no key material to install.
            """
        }
        return nil
    }

    /// FreeRADIUS answers a bad inner password with an EAP-TLV failure rather than an
    /// MSCHAPv2 Failure-Request, so this is nil against our own server — it is here for the
    /// Windows NPS / ClearPass kind of server that does send `E=691`.
    static func mschapErrorCode(_ lines: [String]) -> Int? {
        for line in lines {
            guard let range = line.range(of: "E=") else { continue }
            let digits = line[range.upperBound...].prefix { $0.isNumber }
            if !digits.isEmpty, let value = Int(digits) { return value }
        }
        return nil
    }

    private static func intField(_ line: String, _ key: String) -> Int? {
        guard let range = line.range(of: key) else { return nil }
        let digits = line[range.upperBound...].prefix { $0.isNumber }
        return Int(digits)
    }

    private static func quotedField(_ line: String, _ key: String) -> String? {
        guard let range = line.range(of: key + "'") else { return nil }
        let rest = line[range.upperBound...]
        guard let close = rest.firstIndex(of: "'") else { return nil }
        return String(rest[rest.startIndex..<close])
    }
}

// MARK: - LDAP

nonisolated enum LDAPVerification: String, Codable, CaseIterable, Sendable {
    case system, labCA, file, none

    var label: String {
        switch self {
        case .system: "System trust"
        case .labCA: "This lab's test CA"
        case .file: "A CA file…"
        case .none: "Do not verify"
        }
    }
}

/// Plain words for what an LDAP client actually prints. Pure and unit-tested, because these
/// strings are the difference between "it says 49" and "the password is wrong".
nonisolated enum LDAPDiagnosis {
    /// AD packs the real reason into `data <code>` inside the error text of a 49.
    static let activeDirectoryCodes: [(code: String, meaning: String)] = [
        ("525", "there is no such user"),
        ("52e", "the password is wrong"),
        ("530", "that account may not sign in at this time of day"),
        ("531", "that account may not sign in from this workstation"),
        ("532", "the password has expired"),
        ("533", "the account is disabled"),
        ("701", "the account has expired"),
        ("773", "the password must be changed before the account can be used"),
        ("775", "the account is locked out"),
    ]

    static func explain(_ output: String) -> String? {
        let text = output.lowercased()
        if text.contains("invalid credentials") {
            for entry in activeDirectoryCodes where text.contains("data \(entry.code)") {
                return "Invalid credentials (49) — \(entry.meaning)."
            }
            return "Invalid credentials (49) — the bind DN or the password is wrong. Active Directory reports every one of those as 49; the detail is in the `data` code, which this server did not send."
        }
        if text.contains("can't contact ldap server") || text.contains("(-1)") {
            return "Cannot reach the server (-1) — nothing answered on that host and port. Check the address, the port, and whether the transport is right (LDAPS is a different port from plain LDAP)."
        }
        if text.contains("certificate verify failed") || text.contains("unable to get local issuer") {
            return "The server's certificate was not trusted. Choose the CA that signed it under Certificate verification, or switch verification off for a quick test — but then the connection proves nothing about who answered."
        }
        if text.contains("hostname does not match") || text.contains("common name") {
            return "The server's certificate does not carry the name you connected to. Use the name in its certificate, or its IP if the certificate lists one."
        }
        if text.contains("stronger authentication required") || text.contains("strong(er) auth") || text.contains("(8)") {
            return "The server requires a protected connection (8) — use LDAPS or StartTLS, or it wants signing, which a simple bind cannot provide."
        }
        if text.contains("no such object") {
            return "No such object (32) — the base DN does not exist on that server. It is usually the domain, like dc=lab,dc=sheep."
        }
        if text.contains("inappropriate authentication") {
            return "Inappropriate authentication (48) — that entry has no password to bind with, or the server refuses an anonymous bind here."
        }
        if text.contains("operations error") {
            return "Operations error (1) — on Active Directory this most often means an anonymous search, which it does not allow. Bind as a user first."
        }
        if text.contains("size limit exceeded") {
            return "Size limit exceeded (4) — the server returned as much as it is willing to; narrow the filter."
        }
        return nil
    }

    /// `(sAMAccountName=alice)`. The value is escaped per RFC 4515, so a user called `a*b`
    /// searches for that name rather than becoming a wildcard.
    static func filter(_ template: String, user: String) -> String {
        template.replacingOccurrences(of: "<user>", with: escape(user))
    }

    static func escape(_ value: String) -> String {
        var out = ""
        for character in value.unicodeScalars {
            switch character {
            case "*": out += "\\2a"
            case "(": out += "\\28"
            case ")": out += "\\29"
            case "\\": out += "\\5c"
            case "\0": out += "\\00"
            default: out.unicodeScalars.append(character)
            }
        }
        return out
    }
}

// MARK: - One row of the recent-tests list

nonisolated struct TestRun: Identifiable, Sendable {
    let id: Int
    let time: Date
    let target: String
    let user: String
    let method: String
    let verdict: String
    let good: Bool
    let milliseconds: Int
}

// MARK: - The form, minus anything secret

/// Persisted in UserDefaults so the pane comes back the way it was left. **No password is in
/// here**: a manually typed one is never stored at all, and a shared secret lives in the
/// Keychain.
nonisolated struct TestForm: Codable, Sendable, Equatable {
    var target = TestTarget.thisMac
    var credentials = CredentialSource.table
    var manualUsername = ""
    var radiusHost = ""
    var radiusPort = 1812
    var radiusAcctPort = 1813
    var method = RadiusMethod.pap
    var exchange = RadiusExchange.authentication
    var timeout = 3
    var retries = 1
    var nasIPAddress = ""
    var nasIdentifier = ""
    var nasPortType = ""
    var calledStationID = ""
    var callingStationID = ""
    var extraAttributes = ""
    /// The tunnelled-EAP half. Kept separate from `method` because the two are driven by two
    /// different clients (radclient and eapol_test) and share nothing but the NAS attributes.
    var useEAP = false
    var eapMethod = EAPMethod.peapMSCHAPv2
    var eapAnonymousIdentity = "anonymous@lab"
    var eapValidation = EAPServerValidation.labCA
    var eapCAPath = ""
    var eapExpectedServerName = ""
    var eapClientCertificate = ""
    var eapClientKey = ""
    var eapAllowTLS13 = false
    var eapTimeout = 15
    var ldapHost = ""
    var ldapPort = 389
    var ldapTransport = LDAPTransport.plain
    var ldapAnonymous = false
    var ldapBindDN = ""
    var ldapBaseDN = ""
    var ldapFilter = "(sAMAccountName=<user>)"
    var ldapAttributes = "dn cn mail memberOf"
    var ldapVerification = LDAPVerification.system
    var ldapCAPath = ""

    static let defaultsKey = "TestPaneForm"

    /// Every key optional, so a stored form from an older build still loads.
    enum CodingKeys: String, CodingKey {
        case target, credentials, manualUsername, radiusHost, radiusPort, radiusAcctPort
        case method, exchange, timeout, retries, nasIPAddress, nasIdentifier, nasPortType
        case calledStationID, callingStationID, extraAttributes
        case useEAP, eapMethod, eapAnonymousIdentity, eapValidation, eapCAPath
        case eapExpectedServerName, eapClientCertificate, eapClientKey, eapAllowTLS13, eapTimeout
        case ldapHost, ldapPort, ldapTransport, ldapAnonymous, ldapBindDN, ldapBaseDN
        case ldapFilter, ldapAttributes, ldapVerification, ldapCAPath
    }

    init() {}

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = TestForm()
        target = try c.decodeIfPresent(TestTarget.self, forKey: .target) ?? d.target
        credentials = try c.decodeIfPresent(CredentialSource.self, forKey: .credentials) ?? d.credentials
        manualUsername = try c.decodeIfPresent(String.self, forKey: .manualUsername) ?? d.manualUsername
        radiusHost = try c.decodeIfPresent(String.self, forKey: .radiusHost) ?? d.radiusHost
        radiusPort = try c.decodeIfPresent(Int.self, forKey: .radiusPort) ?? d.radiusPort
        radiusAcctPort = try c.decodeIfPresent(Int.self, forKey: .radiusAcctPort) ?? d.radiusAcctPort
        method = try c.decodeIfPresent(RadiusMethod.self, forKey: .method) ?? d.method
        exchange = try c.decodeIfPresent(RadiusExchange.self, forKey: .exchange) ?? d.exchange
        timeout = try c.decodeIfPresent(Int.self, forKey: .timeout) ?? d.timeout
        retries = try c.decodeIfPresent(Int.self, forKey: .retries) ?? d.retries
        nasIPAddress = try c.decodeIfPresent(String.self, forKey: .nasIPAddress) ?? d.nasIPAddress
        nasIdentifier = try c.decodeIfPresent(String.self, forKey: .nasIdentifier) ?? d.nasIdentifier
        nasPortType = try c.decodeIfPresent(String.self, forKey: .nasPortType) ?? d.nasPortType
        calledStationID = try c.decodeIfPresent(String.self, forKey: .calledStationID) ?? d.calledStationID
        callingStationID = try c.decodeIfPresent(String.self, forKey: .callingStationID) ?? d.callingStationID
        extraAttributes = try c.decodeIfPresent(String.self, forKey: .extraAttributes) ?? d.extraAttributes
        useEAP = try c.decodeIfPresent(Bool.self, forKey: .useEAP) ?? d.useEAP
        eapMethod = try c.decodeIfPresent(EAPMethod.self, forKey: .eapMethod) ?? d.eapMethod
        eapAnonymousIdentity = try c.decodeIfPresent(String.self, forKey: .eapAnonymousIdentity) ?? d.eapAnonymousIdentity
        eapValidation = try c.decodeIfPresent(EAPServerValidation.self, forKey: .eapValidation) ?? d.eapValidation
        eapCAPath = try c.decodeIfPresent(String.self, forKey: .eapCAPath) ?? d.eapCAPath
        eapExpectedServerName = try c.decodeIfPresent(String.self, forKey: .eapExpectedServerName) ?? d.eapExpectedServerName
        eapClientCertificate = try c.decodeIfPresent(String.self, forKey: .eapClientCertificate) ?? d.eapClientCertificate
        eapClientKey = try c.decodeIfPresent(String.self, forKey: .eapClientKey) ?? d.eapClientKey
        eapAllowTLS13 = try c.decodeIfPresent(Bool.self, forKey: .eapAllowTLS13) ?? d.eapAllowTLS13
        eapTimeout = try c.decodeIfPresent(Int.self, forKey: .eapTimeout) ?? d.eapTimeout
        ldapHost = try c.decodeIfPresent(String.self, forKey: .ldapHost) ?? d.ldapHost
        ldapPort = try c.decodeIfPresent(Int.self, forKey: .ldapPort) ?? d.ldapPort
        ldapTransport = try c.decodeIfPresent(LDAPTransport.self, forKey: .ldapTransport) ?? d.ldapTransport
        ldapAnonymous = try c.decodeIfPresent(Bool.self, forKey: .ldapAnonymous) ?? d.ldapAnonymous
        ldapBindDN = try c.decodeIfPresent(String.self, forKey: .ldapBindDN) ?? d.ldapBindDN
        ldapBaseDN = try c.decodeIfPresent(String.self, forKey: .ldapBaseDN) ?? d.ldapBaseDN
        ldapFilter = try c.decodeIfPresent(String.self, forKey: .ldapFilter) ?? d.ldapFilter
        ldapAttributes = try c.decodeIfPresent(String.self, forKey: .ldapAttributes) ?? d.ldapAttributes
        ldapVerification = try c.decodeIfPresent(LDAPVerification.self, forKey: .ldapVerification) ?? d.ldapVerification
        ldapCAPath = try c.decodeIfPresent(String.self, forKey: .ldapCAPath) ?? d.ldapCAPath
    }

    static func load(from defaults: UserDefaults = .standard) -> TestForm {
        guard let data = defaults.data(forKey: defaultsKey),
              let form = try? JSONDecoder().decode(TestForm.self, from: data) else { return TestForm() }
        return form
    }

    func save(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    /// `ldap://host:389`, built from the parts. A host that already looks like a URL is used
    /// as typed, so pasting one from a colleague works.
    var ldapURI: String {
        let host = ldapHost.trimmingCharacters(in: .whitespaces)
        if host.lowercased().hasPrefix("ldap://") || host.lowercased().hasPrefix("ldaps://") { return host }
        return "\(ldapTransport == .ldaps ? "ldaps" : "ldap")://\(host):\(ldapPort)"
    }
}

// MARK: - Secrets

/// The shared secret of an external RADIUS server, and nothing else.
///
/// It goes in the login Keychain rather than `lab.json` or UserDefaults because it is a
/// credential for a machine that is not this one: the lab's own passwords are the user's to
/// lose, someone else's RADIUS secret is not.
nonisolated enum SecretStore {
    static let service = "Bestchaan.SheepRadius"

    static func save(_ value: String, account: String) {
        delete(account: account)
        guard !value.isEmpty else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    static func load(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

/// A 0600 file holding one secret, for the whole life of one child process.
///
/// **`ps` shows every argument of every process on this Mac**, so a password or a shared
/// secret on a command line is readable by anyone logged in — including while it is being
/// sent to a server that is not ours. `radclient -S <file>` and the OpenLDAP tools'
/// `-y <file>` exist for exactly this, and this writes the file they read.
nonisolated struct SecretFile: Sendable {
    let url: URL

    /// `trailingNewline`: radclient reads a line, the OpenLDAP tools read the whole file — a
    /// newline there would become part of the password.
    init(_ value: String, in directory: URL, name: String, trailingNewline: Bool) throws {
        url = directory.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: url)
        let text = trailingNewline ? value + "\n" : value
        // **0600 at creation, not afterwards.** `Data.write(options: .atomic)` creates the file
        // at the process umask — 0644 — with the secret already in it, and only then was it
        // narrowed. `DirectoryPasswordFile` has always done it this way; this one had not.
        guard FileManager.default.createFile(atPath: url.path, contents: Data(text.utf8),
                                             attributes: [.posixPermissions: 0o600]) else {
            throw LabEnvironment.Failure(message: "Could not write \(name) for the test client.")
        }
    }

    /// Always in a `defer`. The file is 0600 in the lab folder (itself 0700), so the window is
    /// small either way, but "small" is not "closed".
    func remove() { try? FileManager.default.removeItem(at: url) }
}

// MARK: - The Test pane's one-check-at-a-time menu


/// **One check at a time** (PROJECT-STATUS §15).
///
/// This pane is still the general RADIUS and LDAP *client* it has been since build 12 — the
/// same `TestRunner`, the same radclient, eapol_test and ldapsearch, the same parsing — but the
/// question it asks first is now "which check?" instead of "which of these three cards applies
/// to you?". Build 17 showed the target card, the RADIUS card and the LDAP card all at once,
/// about forty controls, with two Run buttons in different places; a person who wanted to know
/// whether Wi-Fi would work had to know that PEAP lives under Method inside the RADIUS card.
///
/// Six checks cover what a lab actually tests. Everything the old cards had that is not one of
/// the four questions at the top is behind **Options** — the NAS attributes, the certificate
/// rules, the timeouts, the LDAP search — and nothing was dropped.
///
/// **No password ever reaches a command line.** `ps` shows every argument of every process on
/// this Mac, so the shared secret goes to radclient through `-S <file>` and the bind password
/// to the OpenLDAP tools through `-y <file>`, both 0600 and both deleted the moment the child
/// exits.

/// The six things this pane can check, and how each one drives the form underneath.
nonisolated enum TestCheck: String, CaseIterable, Identifiable {
    // **The raw values are the persisted ones and do not follow the case names.** They are
    // what `@AppStorage("TestPaneCheck")` holds, so renaming `wifiPEAP` to `dot1xPEAP` in
    // build 20 had to leave `"wifiPEAP"` on disk or everyone's pane would have reset to PAP.
    case radiusPAP, radiusMSCHAP
    /// **Build 25, QA L-7.** `radeapclient` has been in the bundle since build 12 and nothing
    /// could reach it: `RadiusMethod.eapMD5` exists, `RadiusRequest.attributes` writes the
    /// `EAP-Code` / `EAP-Type-Identity` pair for it, `radiusTool` picks the binary for it — and
    /// no `TestCheck` selected the method, so the whole path was dead. The choice was between
    /// offering the check and dropping the binary; EAP-MD5 is the one method that proves the
    /// server holds a **cleartext** password rather than an NT hash, which is exactly the
    /// distinction `RadiusAuthorize.chapNeedsCleartext` exists to explain, so it is offered.
    case radiusEAPMD5
    case dot1xPEAP = "wifiPEAP"
    case dot1xTTLS = "wifiTTLS"
    case dot1xTLS = "eapTLS"
    case ldapBind, ldapsBind

    var id: String { rawValue }

    /// The owner tests wired 802.1X as much as Wi-Fi, and the exchange is the same one on a
    /// switch port as on an access point. The names say the protocol, not the medium.
    var label: String {
        switch self {
        case .radiusPAP: "RADIUS login (PAP)"
        case .radiusMSCHAP: "RADIUS login (MS-CHAP)"
        case .radiusEAPMD5: "RADIUS login (EAP-MD5)"
        case .dot1xPEAP: "802.1X (PEAP-MSCHAPv2)"
        case .dot1xTTLS: "802.1X (EAP-TTLS)"
        case .dot1xTLS: "802.1X (EAP-TLS)"
        case .ldapBind: "LDAP bind"
        case .ldapsBind: "LDAPS bind"
        }
    }

    /// **What the pane's own heading says, once the Exchange picker has had its say**
    /// (build 26, QA M-10).
    ///
    /// The Exchange popup is four rows down inside **Options**, which is folded by default,
    /// and the group's heading went on saying "What to test" while the request on the wire was
    /// an Accounting-Stop or a Status-Server ping. Anything that is not a plain authentication
    /// is named in the header, so the one control that changes what the test *is* cannot do it
    /// silently. nil for a plain authentication and for the two LDAP checks, which have no
    /// exchange of their own.
    func headerNote(exchange: RadiusExchange) -> String? {
        guard !isLDAP, exchange != .authentication else { return nil }
        return exchange.label
    }

    /// What lands in the Recent table's Check column.
    var shortLabel: String {
        switch self {
        case .radiusPAP: "PAP"
        case .radiusMSCHAP: "MS-CHAP"
        case .radiusEAPMD5: "EAP-MD5"
        case .dot1xPEAP: "PEAP-MSCHAPv2"
        case .dot1xTTLS: "EAP-TTLS"
        case .dot1xTLS: "EAP-TLS"
        case .ldapBind: "LDAP bind"
        case .ldapsBind: "LDAPS bind"
        }
    }

    var isLDAP: Bool { self == .ldapBind || self == .ldapsBind }
    /// **A tunnelled EAP check, i.e. one eapol_test drives.** EAP-MD5 is EAP too, but it is
    /// bare — no tunnel, no server certificate — and radeapclient is what speaks it, so it
    /// belongs with the two radclient checks everywhere this asks.
    var isEAP: Bool { self == .dot1xPEAP || self == .dot1xTTLS || self == .dot1xTLS }

    /// The binary this check needs, for `TestBlocker`'s sentence.
    var needsEAPClient: Bool { self == .radiusEAPMD5 }

    /// **The transport an LDAP check *is*, and which is never substituted** (build 25, QA
    /// H-6). nil for everything that is not an LDAP check.
    var transport: LDAPTransport? {
        switch self {
        case .ldapBind: .plain
        case .ldapsBind: .ldaps
        default: nil
        }
    }

    /// EAP-TLS proves who you are with a certificate and has no password at all, so the
    /// Password row is replaced by the two file pickers rather than shown and ignored.
    var usesPassword: Bool { self != .dot1xTLS }

    /// Point the persisted form at this check. The form is unchanged from build 17 — this is
    /// the only place the seven choices turn back into its fields.
    func apply(to form: inout TestForm) {
        switch self {
        case .radiusPAP:
            form.useEAP = false; form.method = .pap; form.exchange = .authentication
        case .radiusMSCHAP:
            form.useEAP = false; form.method = .mschap; form.exchange = .authentication
        case .radiusEAPMD5:
            form.useEAP = false; form.method = .eapMD5; form.exchange = .authentication
        case .dot1xPEAP:
            form.useEAP = true; form.eapMethod = .peapMSCHAPv2; form.exchange = .authentication
        case .dot1xTTLS:
            form.useEAP = true; form.eapMethod = .ttlsPAP; form.exchange = .authentication
        case .dot1xTLS:
            form.useEAP = true; form.eapMethod = .eapTLS; form.exchange = .authentication
        case .ldapBind:
            form.ldapTransport = .plain
        case .ldapsBind:
            form.ldapTransport = .ldaps
        }
    }
}

// MARK: - Why Run will not work

/// **Every reason the Run button is off, said before the button is pressed** (build 25 — QA
/// H-6, M-5, M-11 and L-7, which are the Test pane's whole list).
///
/// Build 24 had `canRun` — nine conditions — and `blocker`, which explained five of them; the
/// other four disabled the button in silence. Worse, one of the nine was not a refusal at all:
/// `runLDAP` took the transport the check had pinned and replaced it with
/// `available.contains(…) ? … : (available.first ?? .plain)`, so with LDAPS switched off the
/// check labelled **LDAPS bind** bound over `ldap://`, reported "Bind succeeded", and filed
/// "LDAPS bind" in the Recent table (**H-6**). A test that quietly runs a different test is
/// worse than one that refuses.
///
/// So the two questions are one function with one answer: `reason(…)` is nil when Run will
/// work and is the sentence otherwise, and `canRun` is `reason == nil`. The transport a check
/// names is never substituted — `runLDAP` asks for exactly `TestCheck.transport` and this
/// refuses first if the directory is not offering it.
///
/// **M-11** is in the same list on purpose: "the RADIUS server is stopped" and "there are
/// unapplied changes" were things the app already knew and the person still paid a full
/// timeout to be told. They are warnings rather than refusals — testing a stopped server to
/// see the timeout is a legitimate thing to do — so they come back through `warning(…)` and
/// the button stays live.
nonisolated enum TestBlocker {

    /// Everything the pane knows about itself, so the rule can be checked without a view.
    nonisolated struct Inputs: Sendable, Equatable {
        var check: TestCheck
        var targetIsThisMac: Bool
        /// **Which packet this actually sends** (build 26, QA M-10). The Exchange picker can
        /// turn a check called "RADIUS login (PAP)" into an Accounting-Request or a
        /// Status-Server ping, and until this build the refusal did not know: Run stayed
        /// disabled demanding "the username to authenticate as" for a Status-Server ping,
        /// which carries no username at all and never has.
        var exchange = RadiusExchange.authentication
        var username = ""
        var radiusHost = ""
        var ldapHost = ""
        var clientCertificate = ""
        var clientKey = ""
        /// The listeners Directory ▸ Server has switched on, for a check against This Mac.
        var availableTransports: [LDAPTransport] = []
        var hasRadiusTool = true
        var hasEAPTool = true
        var eapToolHint: String?
        var hasLDAPTools = true
        var radiusRunning = true
        var directoryRunning = true
        var hasUnappliedChanges = false
    }

    /// The one sentence that says why Run is disabled, or nil.
    static func reason(_ i: Inputs) -> String? {
        if i.check.isLDAP { return ldapReason(i) }
        return radiusReason(i)
    }

    static func canRun(_ i: Inputs) -> Bool { reason(i) == nil }

    private static func ldapReason(_ i: Inputs) -> String? {
        if !i.hasLDAPTools { return "The OpenLDAP client tools are not in this build." }
        guard i.targetIsThisMac else {
            return i.ldapHost.trimmingCharacters(in: .whitespaces).isEmpty
                ? "Enter the server or URL to bind against."
                : nil
        }
        if i.availableTransports.isEmpty {
            return "No directory listener is configured — turn one on under Directory ▸ Server."
        }
        // **No substitution** (H-6). The check names its transport and that is the test.
        if let wanted = i.check.transport, !i.availableTransports.contains(wanted) {
            return offlineTransport(wanted)
        }
        return i.username.trimmingCharacters(in: .whitespaces).isEmpty
            ? "Enter the username to bind as." : nil
    }

    /// The sentence H-6 asks for, named after the listener rather than after the check.
    static func offlineTransport(_ transport: LDAPTransport) -> String {
        switch transport {
        case .ldaps: "LDAPS is off under Directory ▸ Server."
        case .startTLS: "StartTLS is off under Directory ▸ Server — it comes with LDAPS."
        case .plain: "Plain LDAP is off under Directory ▸ Server."
        }
    }

    private static func radiusReason(_ i: Inputs) -> String? {
        if i.check.isEAP, !i.hasEAPTool {
            return i.eapToolHint ?? "eapol_test is not in this build."
        }
        if !i.check.isEAP, !i.hasRadiusTool {
            return i.check.needsEAPClient
                ? "radeapclient is not in this build."
                : "radclient is not in this build."
        }
        if !i.targetIsThisMac, i.radiusHost.trimmingCharacters(in: .whitespaces).isEmpty {
            return "Enter the address of the server to test."
        }
        if i.check == .dot1xTLS {
            // A .p12 carries the certificate as well as the key, so it is the only file needed.
            let bundle = i.clientKey.hasSuffix(".p12") || i.clientKey.hasSuffix(".pfx")
            if i.clientKey.isEmpty {
                return "EAP-TLS needs a client certificate — a .p12, or a certificate and its "
                    + "key. Issue one from the user's Properties in Users."
            }
            if !bundle, i.clientCertificate.isEmpty {
                return "A private key was chosen without its certificate. Pick the certificate "
                    + "too, or choose a .p12, which carries both."
            }
        }
        // A Status-Server ping and an Accounting-Request carry no credentials, so demanding
        // a username for them was a refusal with no way past it (M-10).
        guard i.exchange.needsCredentials else { return nil }
        return i.username.trimmingCharacters(in: .whitespaces).isEmpty
            ? "Enter the username to authenticate as." : nil
    }

    /// **What the app already knows and the person would otherwise wait for** (M-11). Run
    /// still works — a timeout against a stopped server is a legitimate thing to look at — so
    /// this is said beside the button rather than instead of it.
    static func warning(_ i: Inputs) -> String? {
        guard i.targetIsThisMac else { return nil }
        if i.check.isLDAP, !i.directoryRunning {
            return "The directory server is stopped — this will time out. Start it in the sidebar."
        }
        if !i.check.isLDAP, !i.radiusRunning {
            return "The RADIUS server is stopped — this will time out. Start it in the sidebar."
        }
        if i.hasUnappliedChanges {
            return "Unapplied changes are not active yet — press Apply to test them."
        }
        return nil
    }
}

// MARK: - The Keychain account a shared secret is filed under

/// **One account per server, re-read when the server changes** (build 25, QA H-7).
///
/// `secretAccount` already tracked the host and port; `sharedSecret` was loaded from the
/// Keychain in `.onAppear` and nowhere else. Retarget the pane at a second server and the
/// *first* server's secret was sent — "no response", and the pane's own diagnosis then blamed
/// a firewall — and pressing **Remember** filed the wrong secret under the new host.
nonisolated enum TestSecretAccount {
    static func name(host: String, port: Int) -> String {
        "radius-secret@\(host.trimmingCharacters(in: .whitespaces)):\(port)"
    }

    /// What the field should hold for `account`. Pure so "the secret follows the target" is a
    /// test rather than an `onChange` nobody can assert on.
    static func secret(for account: String, loading load: (String) -> String?) -> String {
        load(account) ?? ""
    }
}
