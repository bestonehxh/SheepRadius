import Foundation

// MARK: - The image, the container and the volume

/// Names and command lines for the `container` side of AD mode. Everything here is pure, so
/// the argument lists are unit-tested without a container anywhere near.
///
/// **The tag matters.** It is the app's only way of telling which Containerfile an image on
/// this Mac was built from, so every change to `ADImage/` that the running DC would not pick
/// up by itself bumps it:
///
/// * `:1` — the spike. What the live `sheepad-state` volume was provisioned by.
/// * `:2` — TLS material from the lab's own CA, and the wider DNS hygiene.
/// * `:3` — `log level = 1 auth_audit:3`, so the DC records authentication at all, and
///   `ntlm auth = mschapv2-and-ntlmv2-only` for NAC boxes that speak MSCHAPv2.
///
/// The app prefers the newest tag it can find and **still runs an older one**, saying in the
/// log and in Directory ▸ Server what a rebuild would add — a lab Mac must never be stuck
/// because an image is a version behind, and neither must a domain that is serving devices.
nonisolated enum ADImage {
    static let repository = "sheep-ad-dc"
    static let tag = "3"
    /// Newest first. `findImage` walks this, so adding a tag is a one-line change.
    static let knownTags = ["3", "2", "1"]
    static let legacyTag = "1"
    static var reference: String { "\(repository):\(tag)" }
    static var legacyReference: String { "\(repository):\(legacyTag)" }

    /// What a rebuild would add, for an image that is not the current one. nil for the current
    /// tag and for anything unrecognised — a sentence is only worth printing when it is true.
    ///
    /// **Plain prose, no markup.** `Text` parses Markdown in a string *literal* only; this
    /// comes back as a `String`, so a backtick or a `**` would be drawn as a backtick or a
    /// `**`. Caught in a screenshot, which is the only place it shows.
    static func rebuildReason(for reference: String?) -> String? {
        guard let reference, reference != Self.reference else { return nil }
        let tag = reference.split(separator: ":").last.map(String.init) ?? ""
        switch tag {
        case "1":
            return "This is the prototype's image. It predates both the domain controller's own certificate from this lab's CA and the authentication log the Status pane reads. Rebuilding adds them. The domain is untouched: its users and every machine account live in the state volume, which a rebuild does not open."
        case "2":
            return "This image records no authentication at all — Samba's stock log level is 1, which logs none of it. Rebuilding sets log level = 1 auth_audit:3 and ntlm auth = mschapv2-and-ntlmv2-only, so AD logons appear in Status ▸ Recent authentications and in the AD DC log, and a NAC's MSCHAPv2 is accepted over Netlogon. The domain is untouched; the new log level applies once the domain controller has been rebuilt and restarted."
        default:
            return nil
        }
    }
    /// The DC container. One name, so a stale one can always be found and reaped.
    static let containerName = "sheepad-dc"
    /// ext4, case-sensitive. A virtiofs bind mount of a macOS folder is case-insensitive and
    /// Samba's ldb/sysvol layout does not survive that — measured in the spike.
    static let volumeName = "sheepad-state"
    static let volumeSize = "4G"
    /// The `ad` suite provisions from scratch, so it must never touch the real volume.
    static let throwawayVolumeName = "sheepad-test"
    static let throwawayContainerName = "sheepad-test-dc"

    /// The build context shipped inside the .app by the "Bundle servers" phase: the
    /// Containerfile, the entrypoint and fix-dns.sh. A release build can therefore build the
    /// image on a second Mac with nothing but Homebrew's `container` installed.
    static var bundledContext: URL {
        Toolchain.bundledRoot.appendingPathComponent("Resources/ad-image", isDirectory: true)
    }

    /// `container build`. **`--platform linux/arm64` is not cosmetic**: without it the base
    /// image is pulled for every platform in the index (riscv64, s390x, ppc64le…) — 19.9 GB
    /// in the spike, against ~100 MB for arm64 alone.
    static func buildArguments(context: String, reference: String) -> [String] {
        ["build", "--platform", "linux/arm64", "-t", reference, "-f", context + "/Containerfile", context]
    }

    /// The buildkit helper container the build needs; it has no DNS of its own.
    static let builderStartArguments = ["builder", "start", "--dns", "1.1.1.1"]
    /// Left running after a build until it is told otherwise — ~2 CPU / 2 GB of nothing.
    static let builderStopArguments = ["builder", "stop"]

    static func saveArguments(reference: String, to path: String) -> [String] {
        ["image", "save", "--platform", "linux/arm64", "-o", path, reference]
    }

    static func loadArguments(from path: String) -> [String] {
        ["image", "load", "-i", path]
    }

    /// Read a state volume out as a tar on **stdout**, through a one-shot container that
    /// mounts it (build 17, "Move lab to another Mac").
    ///
    /// There is no `container volume export`, and the volume is not a directory on the host,
    /// so the only way to its contents is from inside. The image used is the DC's own — it is
    /// already local, it has `tar`, and using anything else would mean pulling something.
    ///
    /// `--rm` and no `--name`: this container exists for the length of one tar and must never
    /// be mistaken for the DC. **The DC has to be stopped first** — the caller does that —
    /// because a tar of a Samba that is writing `sam.ldb` is a tar of half a transaction.
    ///
    /// `-C /state .` rather than `/state`, so the archive's members are `./private/...` and
    /// untar into the *contents* of the new volume rather than a `state/` inside it.
    static func volumeDumpArguments(volume: String, image: String) -> [String] {
        ["run", "--rm", "-v", "\(volume):/state", "--entrypoint", "/bin/tar", image,
         "-cf", "-", "-C", "/state", "."]
    }

    /// And back in: the tar arrives on **stdin**, so `-i`.
    static func volumeRestoreArguments(volume: String, image: String) -> [String] {
        ["run", "--rm", "-i", "-v", "\(volume):/state", "--entrypoint", "/bin/tar", image,
         "-xf", "-", "-C", "/state"]
    }

    /// Only ever OUR three objects, and only behind a confirmation in the UI.
    static func removeArguments(volume: String = volumeName, reference: String = reference) -> [[String]] {
        [["rm", "-f", containerName],
         ["volume", "delete", volume],
         ["image", "delete", reference]]
    }
}

/// One row of `container ls --all --format json`.
nonisolated struct ADContainerStatus: Sendable, Equatable {
    var id: String
    var state: String
    var ipv4: String?
    var isRunning: Bool { state.lowercased() == "running" }
}

nonisolated enum ADContainerList {
    /// Tolerant on purpose: the shape of this JSON is the `container` CLI's business, not
    /// ours, and a field moving must degrade to "cannot see an address" rather than to a
    /// crash or a second container with the same name.
    static func parse(_ json: String) -> [ADContainerStatus] {
        guard let data = json.data(using: .utf8),
              let array = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [] }
        return array.compactMap { row in
            let configuration = row["configuration"] as? [String: Any]
            guard let id = (configuration?["id"] as? String) ?? (row["id"] as? String) else { return nil }
            let statusObject = row["status"] as? [String: Any]
            let state = (row["status"] as? String)
                ?? (statusObject?["state"] as? String)
                ?? (row["state"] as? String) ?? "unknown"
            let networks = (statusObject?["networks"] as? [[String: Any]])
                ?? (row["networks"] as? [[String: Any]]) ?? []
            let address = (networks.first?["ipv4Address"] as? String)?
                .split(separator: "/").first.map(String.init)
            return ADContainerStatus(id: id, state: state, ipv4: address)
        }
    }
}

/// The leaf Samba serves on 636/3269, issued by the app's own test CA — the same CA a device
/// already imported for RADIUS and OpenLDAP, so AD mode adds no second file to trust.
nonisolated enum ADCertificate {
    /// The OpenLDAP leaf's SAN plus the two names an AD client actually connects to: the DC's
    /// FQDN, and the realm itself (a GC lookup uses it).
    static func sanEntries(settings: ADSettings, name: String, hostname: String, addresses: [String]) -> [String] {
        var out = ["DNS:\(settings.dcFQDN)", "DNS:\(settings.realm)"]
        for entry in ConfigGenerator.ldapSANEntries(name: name, hostname: hostname, addresses: addresses)
        where !out.contains(entry) { out.append(entry) }
        return out
    }

    static func extensions(settings: ADSettings, name: String, hostname: String, addresses: [String]) -> String {
        """
        basicConstraints = CA:FALSE
        keyUsage = critical,digitalSignature,keyEncipherment
        extendedKeyUsage = serverAuth
        subjectAltName = \(sanEntries(settings: settings, name: name, hostname: hostname, addresses: addresses).joined(separator: ","))

        """
    }
}

// MARK: - LDIF

/// A minimal LDIF reader for what `ldbsearch` prints.
///
/// Two things make this more than `split(separator: ":")`: continuation lines (LDIF folds at
/// ~78 columns and continues with a single leading space) and `attr:: <base64>`, which is how
/// every value that is not plain ASCII comes back. Both appear in real output from a DC that
/// a Windows box has joined, so both are tested.
nonisolated enum ADLDIF {
    /// One record per `dn:`; keys are lower-cased so lookups do not depend on the case the
    /// query asked for.
    static func parse(_ text: String) -> [[String: [String]]] {
        var records: [[String: [String]]] = []
        var current: [String: [String]] = [:]
        var pending: String?

        func flush() {
            defer { pending = nil }
            guard let line = pending, let colon = line.firstIndex(of: ":") else { return }
            let key = String(line[line.startIndex..<colon]).lowercased()
            var rest = line[line.index(after: colon)...]
            var value: String
            if rest.first == ":" {
                rest = rest.dropFirst()
                let encoded = rest.trimmingCharacters(in: .whitespaces)
                value = Data(base64Encoded: encoded).map { String(decoding: $0, as: UTF8.self) } ?? ""
            } else if rest.first == "<" {
                return          // a URL-valued attribute; nothing here ever uses one
            } else {
                value = String(rest)
                if value.hasPrefix(" ") { value.removeFirst() }
            }
            current[key, default: []].append(value)
        }

        for raw in text.components(separatedBy: "\n") {
            if raw.hasPrefix(" ") {                       // folded continuation
                pending? += raw.dropFirst()
                continue
            }
            flush()
            if raw.isEmpty {
                if !current.isEmpty { records.append(current); current = [:] }
                continue
            }
            if raw.hasPrefix("#") { continue }            // ldbsearch's own comments
            pending = raw
        }
        flush()
        if !current.isEmpty { records.append(current) }
        return records
    }

    static func first(_ record: [String: [String]], _ key: String) -> String? {
        record[key.lowercased()]?.first
    }

    static func all(_ record: [String: [String]], _ key: String) -> [String] {
        record[key.lowercased()] ?? []
    }
}

/// `userAccountControl` bit 0x2. Everything else in the flag word is left alone — the app
/// only ever asks whether an account is usable.
nonisolated enum ADAccountControl {
    static let disabled = 0x0002
    static func isEnabled(_ raw: String?) -> Bool? {
        guard let raw, let value = Int(raw.trimmingCharacters(in: .whitespaces)) else { return nil }
        return value & disabled == 0
    }
}

extension ADObject {
    /// nil for anything the planner must not consider — a **computer** above all. A machine
    /// account carries `objectClass: user`, so without this check a joined PC (`BEST$`) would
    /// arrive in the planner as a user.
    static func from(ldif record: [String: [String]]) -> ADObject? {
        guard let dn = ADLDIF.first(record, "dn") else { return nil }
        let classes = Set(ADLDIF.all(record, "objectClass").map { $0.lowercased() })
        let kind: Kind
        if classes.contains("computer") {
            return nil
        } else if classes.contains("group") {
            kind = .group
        } else if classes.contains("organizationalunit") {
            kind = .organizationalUnit
        } else if classes.contains("user") || classes.contains("person") {
            kind = .user
        } else {
            return nil
        }
        return ADObject(kind: kind, dn: dn,
                        sAMAccountName: ADLDIF.first(record, "sAMAccountName"),
                        displayName: ADLDIF.first(record, "displayName"),
                        description: ADLDIF.first(record, "description"),
                        enabled: kind == .user ? ADAccountControl.isEnabled(ADLDIF.first(record, "userAccountControl")) : nil,
                        memberOf: ADLDIF.all(record, "memberOf"))
    }
}

/// A machine account, for the Status card. This is the proof that a real join happened, so it
/// shows exactly what the DC recorded and nothing inferred.
nonisolated struct ADComputer: Identifiable, Sendable, Equatable {
    var id: String { dn }
    var dn: String
    var name: String
    var dnsHostName: String
    var operatingSystem: String
    var whenCreated: String

    static func from(ldif record: [String: [String]]) -> ADComputer? {
        guard let dn = ADLDIF.first(record, "dn"),
              Set(ADLDIF.all(record, "objectClass").map { $0.lowercased() }).contains("computer") else { return nil }
        return ADComputer(dn: dn,
                          name: ADLDIF.first(record, "sAMAccountName") ?? ADLDIF.first(record, "cn") ?? ADPlan.cn(of: dn),
                          dnsHostName: ADLDIF.first(record, "dNSHostName") ?? "—",
                          operatingSystem: ADLDIF.first(record, "operatingSystem") ?? "—",
                          whenCreated: Self.readableTime(ADLDIF.first(record, "whenCreated") ?? ""))
    }

    /// `20260917161552.0Z` → `2026-09-17 16:15 UTC`. Left as-is when it is not that shape.
    static func readableTime(_ raw: String) -> String {
        let digits = raw.prefix { $0.isNumber }
        guard digits.count >= 12 else { return raw }
        let d = Array(digits)
        return "\(String(d[0..<4]))-\(String(d[4..<6]))-\(String(d[6..<8])) \(String(d[8..<10])):\(String(d[10..<12])) UTC"
    }
}

/// What the Users inspector shows in AD mode — figures only the DC knows.
nonisolated struct ADUserFacts: Sendable, Equatable {
    var lastLogon = "never"
    var logonCount = "0"
    var badPasswordCount = "0"

    static func from(ldif record: [String: [String]]) -> ADUserFacts {
        ADUserFacts(lastLogon: Self.readableFileTime(ADLDIF.first(record, "lastLogon") ?? "0"),
                    logonCount: ADLDIF.first(record, "logonCount") ?? "0",
                    badPasswordCount: ADLDIF.first(record, "badPwdCount") ?? "0")
    }

    /// AD stores these as 100-nanosecond ticks since 1601-01-01 UTC. 0 means "never", which is
    /// what a freshly created account has and what the UI must not print as 1601.
    static func readableFileTime(_ raw: String) -> String {
        guard let ticks = Int64(raw.trimmingCharacters(in: .whitespaces)), ticks > 0 else { return "never" }
        // 11644473600 = seconds between 1601-01-01 and 1970-01-01.
        let seconds = Double(ticks) / 10_000_000 - 11_644_473_600
        guard seconds > 0 else { return "never" }
        let formatter = DateFormatter()
        // en_US_POSIX and an explicit Gregorian calendar, or this Mac's Thai locale renders
        // 2026 as 2569 (the Buddhist era) — caught by the unit test, not by a person.
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: Date(timeIntervalSince1970: seconds)) + " UTC"
    }
}

// MARK: - Samba's authentication audit

/// One `Auth:` line out of the domain controller's own log, parsed.
///
/// Samba writes these only at `log level = … auth_audit:3`, which is why the entrypoint sets
/// it (build 15) — at the stock `log level = 1` the DC records **no authentication at all**,
/// which is what "I don't see the log in the app" turned out to mean on 18 Sep 2026.
///
/// Everything here is raw: the translation into something a person reads is
/// `ADAuthAudit.summary(of:computers:)`, and the mapping into the Status pane's event list is
/// `AppModel.ingestADAuth`. Keeping the two apart is what lets every real line captured that
/// day sit in `Tests/unit.swift` as a fixture.
nonisolated struct ADAuthRecord: Sendable, Equatable {
    /// The DC's own timestamp, already converted from the UTC it logs in. `Date` is absolute,
    /// so the Status pane renders it in this Mac's time zone with no further work.
    var time: Date
    /// `NT_STATUS_OK` and nothing else is an accept.
    var accepted: Bool
    /// What the DC decided the account is: the `became` / `mapped to` name when there is one,
    /// otherwise the name as it arrived.
    var user: String
    /// The domain that name belongs to, same rule.
    var domain: String
    /// The `user [DOMAIN]\[name]` pair exactly as the client sent it. `NO_SUCH_USER` is only
    /// comprehensible with this: `EXAMPLE\external.user` is a *different domain's* account.
    var rawUser: String
    var rawDomain: String
    /// The client's own name for itself. `(null)` and the `\\`-prefixed spelling are cleaned up
    /// here; nil means the line did not carry one.
    var workstation: String?
    /// `MSCHAPv2`, `Plaintext`, `Supplied-NT-Hash`, `NTLMv2`, `HMAC-SHA256`, `aes-…`.
    var method: String
    /// The whole `NT_STATUS_*`.
    var status: String
    /// What the DC was doing: `SamLogon,network`, `LDAP,simple bind`,
    /// `NETLOGON,ServerAuthenticate`, `Kerberos KDC,ENC-TS Pre-authentication`, `winbind,…`.
    var service: String
    /// From the `NETLOGON computer [X] trust account [X$]` tail Samba appends to a SamLogon.
    /// This is the **authoritative** client name when it is there — a `ServerAuthenticate`
    /// carries `workstation [(null)]` and nothing else names the machine.
    var netlogonComputer: String?
    /// The account ends in `$`.
    var isMachineAccount: Bool

    /// A machine setting up its secure channel — the thing that happens when a computer joins
    /// and every time it re-establishes trust afterwards. Worth a row of its own, and worth a
    /// Joined-computers refresh.
    var isComputerAuthentication: Bool {
        isMachineAccount && service.lowercased().hasPrefix("netlogon")
    }

    /// The client to show. **Never the remote host**: every packet reaches the DC across the
    /// vmnet bridge, so `remote host` is always `192.168.64.1` whichever device it came from,
    /// and printing that as the client would be worse than printing nothing.
    var clientName: String {
        if let netlogonComputer, !netlogonComputer.isEmpty { return netlogonComputer }
        if let workstation, !workstation.isEmpty { return workstation }
        if isMachineAccount { return String(user.dropLast()) }
        return "—"
    }
}

/// The parser, the vocabulary and the plain-English half.
nonisolated enum ADAuthAudit {
    /// Where a line's payload starts. It is **not** at column 0: `winbindd` prefixes its own
    /// lines with `/usr/sbin/winbindd: `, so an anchored match misses every ntlm_auth event.
    static let marker = "Auth: ["

    /// `Successful AuthZ:` lines are authorisation, not authentication, and Samba prints one
    /// for the same event it has just printed an `Auth:` line for. Taking both would double
    /// every successful logon in the feed.
    static func isIgnoredAuthLine(_ line: String) -> Bool {
        line.contains("AuthZ:")
    }

    /// True for a line the "Auth only" filter keeps.
    static func isAuthLine(_ line: String) -> Bool {
        line.contains(marker) && !isIgnoredAuthLine(line)
    }

    /// - Parameter now: used only when the DC's own timestamp cannot be read, so a line whose
    ///   clock shape changes in some future Samba still lands in the feed at roughly the right
    ///   place instead of being dropped.
    static func parse(_ line: String, now: Date = Date()) -> ADAuthRecord? {
        guard let start = line.range(of: marker), !isIgnoredAuthLine(line) else { return nil }
        let body = line[start.lowerBound...]
        guard let service = value(in: body, after: marker),
              let status = value(in: body, after: " status ["),
              let (rawDomain, rawUser) = pair(in: body, after: " user [") else { return nil }

        let mapped = pair(in: body, after: " became [") ?? pair(in: body, after: " mapped to [")
        // `(null)` is Samba's way of saying "there was nothing to map to" — a failed winbind
        // PAM attempt maps to `[(null)]\[(null)]`. Falling for it prints "(null)" as the user.
        let user = clean(mapped?.1) ?? rawUser
        let domain = clean(mapped?.0) ?? rawDomain

        let time = value(in: body, after: " at [").flatMap(parseTimestamp) ?? now
        return ADAuthRecord(
            time: time,
            accepted: status == "NT_STATUS_OK",
            user: user,
            domain: domain,
            rawUser: rawUser,
            rawDomain: rawDomain,
            workstation: clean(value(in: body, after: " workstation [")),
            method: value(in: body, after: " with [") ?? "",
            status: status,
            service: service,
            netlogonComputer: clean(value(in: body, after: "NETLOGON computer [")),
            isMachineAccount: user.hasSuffix("$"))
    }

    /// `key[value]` where `key` ends in `[`. Cheap on purpose: this runs once per log line,
    /// and the build-12 lesson is that per-line work on this path is the whole app's budget.
    static func value(in text: Substring, after key: String) -> String? {
        guard let k = text.range(of: key),
              let close = text[k.upperBound...].firstIndex(of: "]") else { return nil }
        return String(text[k.upperBound..<close])
    }

    /// `key[DOMAIN]\[name]`, the shape Samba writes every account in.
    static func pair(in text: Substring, after key: String) -> (String, String)? {
        guard let k = text.range(of: key),
              let close = text[k.upperBound...].firstIndex(of: "]") else { return nil }
        let domain = String(text[k.upperBound..<close])
        let rest = text[text.index(after: close)...]
        guard rest.hasPrefix("\\[") else { return (domain, "") }
        let inner = rest.dropFirst(2)
        guard let innerClose = inner.firstIndex(of: "]") else { return (domain, "") }
        return (domain, String(inner[inner.startIndex..<innerClose]))
    }

    /// Samba's `(null)`, an empty field and the `\\\\OMP` spelling of a NetBIOS name all mean
    /// something the UI must not print verbatim.
    static func clean(_ raw: String?) -> String? {
        guard var value = raw else { return nil }
        value = value.replacingOccurrences(of: "\\", with: "")
        value = value.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty, value != "(null)" else { return nil }
        return value
    }

    /// `Fri, 18 Sep 2026 08:34:53.486099 UTC` → an absolute `Date`.
    ///
    /// Integer arithmetic rather than a `DateFormatter`, for two reasons that are both on
    /// record here. A `DateFormatter` on this Mac reads 2026 as 2569 unless it is pinned to
    /// `en_US_POSIX` **and** a Gregorian calendar — the trap `ADUserFacts.readableFileTime`
    /// already fell into — and building one per log line would put locale machinery on the
    /// hottest path the app has.
    static func parseTimestamp(_ raw: String) -> Date? {
        let parts = raw.split(separator: " ", omittingEmptySubsequences: true)
        // "Fri," "18" "Sep" "2026" "08:34:53.486099" "UTC"
        guard parts.count >= 6 else { return nil }
        // Samba logs in the container's time zone, and the container has none but UTC. If that
        // ever changes the line is better left to the reader's clock than silently shifted.
        let zone = parts[5].uppercased()
        guard zone == "UTC" || zone == "GMT" else { return nil }
        guard let day = Int(parts[1]), let year = Int(parts[3]),
              let month = months.firstIndex(of: String(parts[2]).lowercased()).map({ $0 + 1 }) else { return nil }
        let clock = parts[4].split(separator: ":")
        guard clock.count == 3, let hour = Int(clock[0]), let minute = Int(clock[1]) else { return nil }
        let secondParts = clock[2].split(separator: ".")
        // **`split` drops empty subsequences**, so a clock field of "." yields an EMPTY array
        // and `secondParts[0]` traps. This function is offered every `… at [ … ]` on every log
        // line of every feed, and radiusd echoes `User-Name` into its own stream — so a
        // supplicant that authenticates as `x at [Fri, 1 Jan 2000 0:0:. UTC]` crashed the app
        // as soon as that line scrolled into view.
        guard let secondText = secondParts.first, let second = Int(secondText) else { return nil }
        // Every field is attacker-supplied text, and the arithmetic below is unchecked: a year
        // or an hour of 10^17 overflows Int64 and traps just as hard as the subscript did.
        guard year > 1970, year < 10_000, day >= 1, day <= 31,
              hour >= 0, hour < 24, minute >= 0, minute < 60, second >= 0, second < 62 else { return nil }
        var fraction = 0.0
        if secondParts.count > 1, let micro = Double(secondParts[1]) {
            fraction = micro / pow(10, Double(secondParts[1].count))
        }
        let epochDay = daysFromCivil(year: year, month: month, day: day)
        let seconds = Double(epochDay * 86_400 + hour * 3600 + minute * 60 + second) + fraction
        return Date(timeIntervalSince1970: seconds)
    }

    private static let months = ["jan", "feb", "mar", "apr", "may", "jun",
                                 "jul", "aug", "sep", "oct", "nov", "dec"]

    /// Days since 1970-01-01 for a proleptic Gregorian date — Howard Hinnant's `days_from_civil`,
    /// which is exact for every year this will ever see and is twelve lines of integer maths.
    static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let y = year - (month <= 2 ? 1 : 0)
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400                                        // [0, 399]
        let doy = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1  // [0, 365]
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy                // [0, 146096]
        return era * 146_097 + doe - 719_468
    }

    // MARK: The plain-English half

    /// How the credential reached the DC, in the words the device's own form uses.
    static func methodLabel(_ record: ADAuthRecord) -> String {
        let service = record.service.lowercased()
        switch record.method {
        case "MSCHAPv2": return "MSCHAPv2"
        case "Supplied-NT-Hash": return "NT hash"
        case "NTLMv2", "NTLMv1": return record.method
        case "Plaintext": return service.hasPrefix("ldap") ? "Plaintext bind" : "plaintext password"
        default:
            if service.contains("kerberos") || record.method.hasPrefix("aes-") || record.method.hasPrefix("arcfour") {
                return "Kerberos"
            }
            if service.hasPrefix("netlogon") { return "secure channel" }
            return record.method.isEmpty ? "unknown method" : record.method
        }
    }

    /// Why it failed, in a sentence rather than an `NT_STATUS_`.
    ///
    /// The four that matter here are the four a Wi-Fi or NAC problem actually produces; the
    /// rest fall through to the constant with its prefix taken off, which is still better than
    /// nothing and never claims to know more than it does.
    static func reason(_ record: ADAuthRecord) -> String? {
        guard !record.accepted else { return nil }
        switch record.status {
        case "NT_STATUS_WRONG_PASSWORD", "NT_STATUS_LOGON_FAILURE":
            return "wrong password"
        case "NT_STATUS_NO_SUCH_USER":
            return "no such user in this domain (came as \(record.rawDomain)\\\(record.rawUser))"
        case "NT_STATUS_ACCOUNT_LOCKED_OUT":
            return "account locked out"
        case "NT_STATUS_ACCOUNT_DISABLED":
            return "account disabled"
        case "NT_STATUS_NTLM_BLOCKED":
            return "NTLM/MSCHAPv2 blocked by DC policy"
        case "NT_STATUS_PASSWORD_EXPIRED", "NT_STATUS_PASSWORD_MUST_CHANGE":
            return "password expired"
        default:
            return record.status.replacingOccurrences(of: "NT_STATUS_", with: "")
                .replacingOccurrences(of: "_", with: " ").lowercased()
        }
    }

    /// The `detail` column: how, then why.
    static func detail(_ record: ADAuthRecord) -> String {
        if record.isComputerAuthentication {
            return "computer \(record.clientName) joined/authenticated"
        }
        var parts = [methodLabel(record)]
        if let reason = reason(record) { parts.append(reason) }
        return parts.joined(separator: " · ")
    }

    /// The client column. iMaster NCE-Campus joins the domain as **several** machine accounts —
    /// `OMP`, `SERVICE1`, `DATABACKUP` on the owner's box — and none of those names says
    /// "iMaster" to anyone reading the feed, so a joined computer that is one of its nodes is
    /// labelled as such. Everything else shows the name the client gave.
    static func clientLabel(_ record: ADAuthRecord, computers: [ADComputer]) -> String {
        let name = record.clientName
        guard let computer = computers.first(where: {
            $0.name.replacingOccurrences(of: "$", with: "").caseInsensitiveCompare(name) == .orderedSame
        }) else { return name }
        return looksLikeNCE(computer) ? "iMaster (\(name))" : name
    }

    /// Whether a machine account is an iMaster NCE-Campus node.
    ///
    /// Two signals, and the order matters. A computer that reports an `operatingSystem` naming
    /// the product settles it; so does one that reports **Windows**, in the other direction —
    /// a notebook is never an iMaster node whatever it is called. Only then does the node-name
    /// heuristic apply, and it is a heuristic: those are the fixed role names iMaster's own
    /// nodes join with (verified against an NCE-Campus lab deployment on
    /// 18 Sep 2026, where all three joined with **no** `operatingSystem` attribute at all,
    /// which is the one thing that distinguishes them from a Windows PC).
    static func looksLikeNCE(_ computer: ADComputer) -> Bool {
        let os = computer.operatingSystem.lowercased()
        if os.contains("nce") || os.contains("imaster") || os.contains("huawei") { return true }
        if os.contains("windows") || os.contains("samba") { return false }
        let name = computer.name.replacingOccurrences(of: "$", with: "").lowercased()
        let role = name.drop(while: { !$0.isNumber }).isEmpty ? name : String(name.prefix(while: { !$0.isNumber }))
        return nceNodeRoles.contains(role)
    }

    /// The node roles an iMaster NCE-Campus deployment joins with, trailing instance number
    /// stripped (`SERVICE1` → `service`).
    static let nceNodeRoles: Set<String> = ["omp", "service", "database", "databackup", "manager"]

    /// What `-demoADEvents 1` replays. Sanitised lines from a lab domain controller, with
    /// the SIDs shortened.
    ///
    /// They exist so that Status ▸ Recent authentications can be seen — and screenshotted —
    /// without a domain controller running, which on the day this was written was the only way
    /// to show what the card would look like without rebuilding the image. The hook
    /// feeds them through `ADController.ingestFollowedLog`, so it exercises the real path
    /// (follow → parse → coalesce → publish) rather than pretending to.
    ///
    /// `Tests/unit.swift` keeps its **own** verbatim copies. A test whose fixtures come from
    /// the code it is testing cannot notice the fixture being wrong.
    static let demoLines = [
        #"Auth: [LDAP,simple bind] user [LABSHEEP]\[CN=Administrator,CN=Users,DC=lab,DC=sheep] at [Fri, 18 Sep 2026 08:34:53.486099 UTC] with [Plaintext] status [NT_STATUS_OK] workstation [DC1] remote host [ipv4:192.168.64.1:60676] became [LABSHEEP]\[Administrator] [S-1-5-21-1-2-3-500]. local host [ipv4:192.168.64.2:389]"#,
        #"Auth: [SamLogon,interactive] user [LAB.SHEEP]\[Administrator] at [Fri, 18 Sep 2026 08:38:04.026803 UTC] with [Supplied-NT-Hash] status [NT_STATUS_OK] workstation [\\\\FILESERVER] remote host [ipv4:192.168.64.1:60306] became [LABSHEEP]\[Administrator] [S-1-5-21-1-2-3-500]"#,
        // Three in a row from the same node — what coalescing is for.
        #"Auth: [SamLogon,network] user [lab.sheep]\[alice] at [Fri, 18 Sep 2026 09:01:46.975428 UTC] with [MSCHAPv2] status [NT_STATUS_WRONG_PASSWORD] workstation [\\\\OMP] remote host [ipv4:192.168.64.1:60300] mapped to [LABSHEEP]\[alice]. local host [ipv4:192.168.64.2:49153]"#,
        #"Auth: [SamLogon,network] user [lab.sheep]\[alice] at [Fri, 18 Sep 2026 09:01:51.100000 UTC] with [MSCHAPv2] status [NT_STATUS_WRONG_PASSWORD] workstation [\\\\OMP] remote host [ipv4:192.168.64.1:60300] mapped to [LABSHEEP]\[alice]. local host [ipv4:192.168.64.2:49153]"#,
        #"Auth: [SamLogon,network] user [lab.sheep]\[alice] at [Fri, 18 Sep 2026 09:01:58.400000 UTC] with [MSCHAPv2] status [NT_STATUS_WRONG_PASSWORD] workstation [\\\\OMP] remote host [ipv4:192.168.64.1:60300] mapped to [LABSHEEP]\[alice]. local host [ipv4:192.168.64.2:49153]"#,
        #"Auth: [SamLogon,network] user [lab.sheep]\[alice] at [Fri, 18 Sep 2026 09:02:10.550000 UTC] with [MSCHAPv2] status [NT_STATUS_OK] workstation [\\\\OMP] remote host [ipv4:192.168.64.1:60300] became [LABSHEEP]\[alice]. local host [ipv4:192.168.64.2:49153]"#,
        #"Auth: [NETLOGON,ServerAuthenticate] user [LABSHEEP]\[CLIENT-T14$] at [Fri, 18 Sep 2026 09:03:20.010000 UTC] with [HMAC-SHA256] status [NT_STATUS_OK] workstation [(null)] remote host [ipv4:192.168.64.1:61001]"#,
        #"Auth: [SamLogon,interactive] user [EXAMPLE]\[external.user] at [Fri, 18 Sep 2026 09:03:27.100000 UTC] with [Supplied-NT-Hash] status [NT_STATUS_NO_SUCH_USER] workstation [CLIENT-T14] remote host [ipv4:192.168.64.1:61000]"#,
    ]
}

// MARK: - Turning a plan into commands

/// One `container exec <dc> …` invocation.
nonisolated struct ADCommand: Equatable, Sendable {
    /// Everything after the container name.
    var argv: [String]
    /// The sync log line.
    var summary: String
    /// Fed to the command on stdin instead of being written into `argv`.
    ///
    /// **This is how a password travels.** `container exec` puts every argument in the argv of
    /// the host-side `container` process, where `ps` shows it to every account on this Mac —
    /// so `samba-tool user setpassword … --newpassword=<secret>` used to publish the password
    /// of every synced user, once per user, on every sync. Setting this makes the runner use
    /// `container exec -i` and write the value in.
    var stdin: String?
}

nonisolated enum ADCommands {
    static let sambaDatabase = "/var/lib/samba/private/sam.ldb"

    /// What `ADImage/entrypoint.sh` writes into `smb.conf` as the DC's `log level`.
    ///
    /// `auth_audit:3` is the class that produces the `Auth:` lines; `ldap_server:10` was tried
    /// alongside it on 18 Sep 2026 and is deliberately **not** here — it prints every search a
    /// NAC makes, which at iMaster's thirty-second poll buries the authentication it was
    /// turned on to show.
    static let authAuditLogLevel = "1 auth_audit:3"

    /// The same level pushed into a **running** DC, for an image built before build 15.
    ///
    /// This is a stopgap by construction: `smbcontrol` changes the level in the running
    /// process and nothing else, so it is lost on the next restart. It exists so that the
    /// events appear straight away on the owner's live domain, which is running `:2` and which
    /// this app will not restart on its own.
    static let enableAuthAudit = ["smbcontrol", "all", "debug", authAuditLogLevel]

    /// Relax the policy exactly as the spike recorded, immediately after a provision: a lab
    /// tool whose test users are `alice123` cannot live with the default complexity rules,
    /// and finding that out through a `samba-tool user create` failure is no fun at all.
    static let relaxPasswordPolicy = ["domain", "passwordsettings", "set", "--complexity=off",
                                      "--min-pwd-length=1", "--min-pwd-age=0", "--max-pwd-age=0",
                                      "--history-length=0"]

    /// A `samba-tool` call.
    static func tool(_ arguments: [String], _ summary: String) -> ADCommand {
        ADCommand(argv: ["samba-tool"] + arguments, summary: summary)
    }

    /// What a user account is created with before its real password is set on stdin. It never
    /// authenticates anybody: the very next command replaces it. It still has to satisfy the
    /// domain's complexity policy or `samba-tool user create` refuses.
    static let placeholderPassword = "Sheep-Placeholder-0!x"

    /// `samba-tool user setpassword` with the password on **stdin**.
    ///
    /// Same script as `setAdministratorPasswordScript` and for the same reason — the sync path
    /// had been left behind when the Users pane was fixed, so every synced user's password was
    /// still going through the host's `ps` in `--newpassword=`.
    static func setPassword(_ username: String, _ password: String, _ summary: String) -> ADCommand {
        ADCommand(argv: ["bash", "-c", setUserPasswordScript(username)],
                  summary: summary, stdin: password + "\n")
    }

    /// `IFS= read -r` and not `read`: a password may legitimately begin or end with a space.
    /// The username is single-quoted into the script, so a name carrying a quote cannot end it.
    static func setUserPasswordScript(_ username: String) -> String {
        """
        IFS= read -r password
        umask 077
        file=$(mktemp /tmp/.sheepad-pw.XXXXXX) || exit 70
        trap 'rm -f "$file"' EXIT INT TERM
        printf '%s' "$password" > "$file"
        samba-tool user setpassword \(shellQuoted(username)) --newpassword="$(cat "$file")"
        """
    }

    /// A single-quoted shell word: `'` is closed, escaped and reopened. The only correct way.
    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// An `ldbmodify` call whose LDIF is carried base64-encoded.
    ///
    /// The encoding is not politeness, it is the injection boundary: the payload reaches a
    /// `bash -c` inside the container, and base64 is `[A-Za-z0-9+/=]` — a display name of
    /// `"; rm -rf /` cannot become anything but text.
    static func modify(ldif: String, _ summary: String) -> ADCommand {
        let payload = Data(ldif.utf8).base64EncodedString()
        return ADCommand(argv: ["bash", "-c", "echo '\(payload)' | base64 --decode | ldbmodify -H \(sambaDatabase)"],
                         summary: summary)
    }

    /// `OU=IT,OU=Staff,OU=SheepRadius` — what `--userou` / `--groupou` want, i.e. the DN with
    /// the domain part taken off.
    static func relativeDN(_ dn: String, settings: ADSettings) -> String {
        let suffix = "," + settings.baseDN
        guard dn.lowercased().hasSuffix(suffix.lowercased()) else { return dn }
        return String(dn.dropLast(suffix.count))
    }

    /// The commands one planned operation turns into, in order.
    ///
    /// - `passwords`: the app's table, keyed by lower-cased username. AD will not tell us what
    ///   a password currently is, so the table is authoritative and it is written every sync.
    /// - `knownDNs`: the DN an object already has, keyed by lower-cased name. For an object
    ///   this run creates the DN is predictable (`--use-username-as-cn`); for one that is
    ///   already there it is whatever the directory says, which is not always predictable.
    static func commands(for operation: ADOperation, settings: ADSettings,
                         passwords: [String: String], knownDNs: [String: String]) -> [ADCommand] {
        func dn(ofOU path: String) -> String { ADPlan.dn(forOU: path, settings: settings) }
        func userDN(_ name: String, ou: String) -> String {
            knownDNs[name.lowercased()] ?? "CN=\(name),\(dn(ofOU: ou))"
        }

        switch operation {
        case .createOU(let path):
            return [tool(["ou", "create", dn(ofOU: path)], operation.summary)]

        case .createUser(let username, let ou, let displayName, let password):
            // --use-username-as-cn keeps CN == sAMAccountName, so every DN the app builds
            // afterwards is the DN the directory actually has.
            //
            // The password is NOT an argument: `samba-tool user create <name> <password>`
            // would put it in the host `container` process's argv. `--must-change-at-next-login`
            // is not wanted either, so the account is created with a throwaway and the real
            // password is set immediately afterwards, through stdin.
            var out = [tool(["user", "create", username, ADCommands.placeholderPassword,
                             "--userou=" + relativeDN(dn(ofOU: ou), settings: settings),
                             "--use-username-as-cn"], operation.summary)]
            if !password.isEmpty {
                out.append(setPassword(username, password, "set the password of \(username)"))
            }
            out.append(modify(ldif: """
                dn: CN=\(username),\(dn(ofOU: ou))
                changetype: modify
                replace: displayName
                displayName: \(displayName)
                """, "set displayName of \(username) to \(displayName)"))
            return out

        case .moveUser(let username, let toOU):
            return [tool(["user", "move", username, dn(ofOU: toOU)], operation.summary)]

        case .setDisplayName(let username, let value):
            return [modify(ldif: """
                dn: \(userDN(username, ou: ""))
                changetype: modify
                replace: displayName
                displayName: \(value)
                """, operation.summary)]

        case .setEnabled(let username, let value):
            return [tool(["user", value ? "enable" : "disable", username], operation.summary)]

        case .setPassword(let username):
            guard let password = passwords[username.lowercased()], !password.isEmpty else { return [] }
            return [setPassword(username, password, operation.summary)]

        case .createGroup(let name, let description):
            var arguments = ["group", "add", name, "--groupou=" + relativeDN(settings.managedRootDN, settings: settings)]
            if !description.isEmpty { arguments.append("--description=" + description) }
            return [tool(arguments, operation.summary)]

        case .setGroupDescription(let name, let value):
            return [modify(ldif: """
                dn: \(knownDNs[name.lowercased()] ?? "CN=\(name),\(settings.managedRootDN)")
                changetype: modify
                replace: description
                description: \(value)
                """, operation.summary)]

        case .addMember(let group, let user):
            return [tool(["group", "addmembers", group, user], operation.summary)]

        case .removeMember(let group, let user):
            return [tool(["group", "removemembers", group, user], operation.summary)]

        case .deleteUser(let username):
            return [tool(["user", "delete", username], operation.summary)]

        case .deleteGroup(let name):
            return [tool(["group", "delete", name], operation.summary)]

        case .deleteOU(let path):
            return [tool(["ou", "delete", dn(ofOU: path)], operation.summary)]

        case .collision:
            // Never resolved automatically. The sync log offers "Adopt" instead.
            return []

        case .groupCollision:
            // Never resolved at all. There is no safe automatic move for a group AD owns, and
            // the app cannot have the name — the only fix is to rename the group here.
            return []
        }
    }

    /// "Adopt": move an object that already exists outside the managed root into it, so the
    /// app can own it from now on. This is the one operation that reaches outside
    /// `OU=SheepRadius`, it only ever *moves*, and it only runs when a person presses the
    /// button — `alice` and `bob` in `CN=Users` on the live volume are exactly the case it
    /// was written for.
    static func adopt(username: String, into ou: String, settings: ADSettings) -> ADCommand {
        tool(["user", "move", username, ADPlan.dn(forOU: ou, settings: settings)],
             "adopt \(username) into \(settings.managedRootDN)")
    }

    /// Everything the app needs to know about the objects it may touch, in one search.
    static func readDirectory(settings: ADSettings) -> [String] {
        ["ldbsearch", "-H", sambaDatabase, "-b", settings.baseDN, "-s", "sub",
         "(|(objectClass=user)(objectClass=group)(objectClass=organizationalUnit))",
         "dn", "objectClass", "sAMAccountName", "displayName", "description",
         "userAccountControl", "memberOf"]
    }

    static func readComputers(settings: ADSettings) -> [String] {
        ["ldbsearch", "-H", sambaDatabase, "-b", settings.baseDN, "-s", "sub",
         "(objectClass=computer)", "dn", "objectClass", "sAMAccountName", "cn",
         "dNSHostName", "operatingSystem", "whenCreated"]
    }

    static func readUserFacts(settings: ADSettings) -> [String] {
        ["ldbsearch", "-H", sambaDatabase, "-b", settings.baseDN, "-s", "sub",
         "(objectClass=user)", "dn", "sAMAccountName", "lastLogon", "logonCount", "badPwdCount"]
    }

    /// Set the **domain's** Administrator password to the one in Settings.
    ///
    /// The only operation in this app that changes a credential inside an adopted domain, and
    /// it only ever runs on an explicit button press, because the domain — not this app — is
    /// the authority on what that password is.
    ///
    /// **The password never appears in an argument vector on this Mac.** `container exec -i`
    /// keeps stdin open, the script reads one line from it, writes it to a file created under
    /// `umask 077` (0600, owned by root inside the container's own tmpfs) and hands
    /// `samba-tool` the file's contents; the file is removed whether or not the tool succeeded.
    /// Without that, the password would sit in the host's `ps` output for the length of the
    /// call — which is exactly what `Tests/run.sh live` checks for elsewhere.
    ///
    /// `IFS= read -r` and not `read`: a password may legitimately begin or end with a space,
    /// and the default IFS would eat it.
    static let setAdministratorPasswordScript = """
    IFS= read -r password
    umask 077
    file=$(mktemp /tmp/.sheepad-pw.XXXXXX) || exit 70
    printf '%s' "$password" > "$file"
    samba-tool user setpassword Administrator --newpassword="$(cat "$file")"
    status=$?
    rm -f "$file"
    exit $status
    """

    /// The whole `container` argv. `-i` is load-bearing and has to come before the container
    /// id: without it the script's `read` sees EOF at once and the password becomes empty.
    static func setAdministratorPasswordArguments(container: String) -> [String] {
        ["exec", "-i", container, "bash", "-c", setAdministratorPasswordScript]
    }

    /// Every record on one node of the zone, for the DNS hygiene check.
    ///
    /// Per node rather than one sweep because `samba-tool dns query <zone> @ ALL` lists the
    /// top level only — it names its children but does not descend into them, and
    /// `gc._msdcs` (the record that actually broke the first real join) is a child.
    static func zoneQuery(name: String, settings: ADSettings) -> ADCommand {
        authenticated("samba-tool dns query 127.0.0.1 \(shellQuoted(settings.realm)) \(shellQuoted(name)) ALL",
                      password: settings.administratorPassword,
                      summary: "query the \(name) node of the \(settings.realm) zone")
    }

    /// `smbclient -L`, authenticated, with nothing in anyone's `argv`.
    static func shareList(settings: ADSettings) -> ADCommand {
        authenticated("smbclient -L 127.0.0.1",
                      password: settings.administratorPassword, summary: "list the DC's SMB shares")
    }

    /// A Samba tool run as Administrator with the password arriving on **stdin**.
    ///
    /// `-U Administrator%<password>` is the obvious spelling and it puts the domain's
    /// Administrator password in the argv of the host-side `container` process, where `ps`
    /// shows it to every account on this Mac — once per name walked, for the zone check. Samba
    /// reads an `--authentication-file` instead; this writes one at `umask 077` inside the
    /// container, uses it, and removes it on every path out including a signal.
    static func authenticated(_ command: String, password: String, summary: String) -> ADCommand {
        let script = """
        IFS= read -r password
        umask 077
        file=$(mktemp /tmp/.sheepad-auth.XXXXXX) || exit 70
        trap 'rm -f "$file"' EXIT INT TERM
        printf 'username = Administrator\\npassword = %s\\n' "$password" > "$file"
        \(command) --authentication-file="$file"
        """
        return ADCommand(argv: ["bash", "-c", script], summary: summary, stdin: password + "\n")
    }
}

// MARK: - Which operations actually authenticate

/// The operations that present the Administrator password to the domain — and therefore the
/// only ones that can fail because the password in Settings is not the domain's.
///
/// This distinction is not cosmetic. Almost everything AD mode does runs **inside** the DC as
/// root through `samba-tool` and `ldbsearch`, straight against `sam.ldb`: a sync creates users,
/// moves them and sets their passwords **without ever binding**, so it succeeds perfectly well
/// on an adopted domain whose Administrator password nobody knows. Only these four ask the
/// domain to prove the password, which is why the "that password is not this domain's" story
/// is attached to them and to nothing else.
nonisolated enum ADBindStep: String, Sendable, Equatable, CaseIterable {
    /// `kinit Administrator@REALM`, over the published KDC port.
    case kerberos
    /// `ldapwhoami -D Administrator@realm -w …` — a real LDAP simple bind.
    case ldapBind
    /// `smbclient -L … -U Administrator%…`, inside the DC but still authenticated.
    case smb
    /// `samba-tool dns query … -U Administrator%…` — the zone-hygiene walk.
    case dnsZone

    /// How the self-test names it.
    var label: String {
        switch self {
        case .kerberos: "kinit as Administrator"
        case .ldapBind: "LDAP simple bind as Administrator"
        case .smb: "SMB share list"
        case .dnsZone: "DNS zone check"
        }
    }
}

/// Reading "the password was wrong" out of four tools that each say it differently.
///
/// Every one of these is what the tool prints for a bad password and nothing else; a wrong
/// *host* or a DC that is down produces a different message and must not be mistaken for this,
/// because the offered fix — overwrite the domain's Administrator password — is not something
/// to suggest when the real problem is a closed port.
nonisolated enum ADCredentialCheck {
    static let signatures = [
        "invalid credentials",                  // ldapwhoami / ldapsearch, LDAP result 49
        "ldap_bind: invalid credentials",
        "preauthentication failed",             // kinit
        "password incorrect",                   // kinit, older wording
        "pre-authentication failed",
        "nt_status_logon_failure",              // smbclient, samba-tool over RPC
        "nt_status_wrong_password",
        "logon failure",
        "wrong_password",
    ]

    /// True only when the output names a rejected credential.
    static func isCredentialFailure(_ output: String) -> Bool {
        let lower = output.lowercased()
        return signatures.contains { lower.contains($0) }
    }

    /// What the self-test shows instead of the raw protocol error. The raw line is kept after
    /// the em dash — diagnosing is still possible — but the sentence in front of it is the one
    /// that says what to do.
    static func detail(step: ADBindStep, output: String, realm: String) -> String {
        let raw = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isCredentialFailure(raw) else { return String(raw.prefix(200)) }
        return "password rejected by the domain — the Administrator password in Settings is not the one \(realm) currently has"
            + (raw.isEmpty ? "" : " · \(raw.split(separator: "\n").last.map(String.init)?.prefix(120) ?? "")")
    }
}

/// Objects that must never be adopted, however convenient it would be.
///
/// Discovered by running the real thing: the sample lab has a user called `guest`, and AD has
/// a built-in `Guest`. The collision was reported correctly — the app refused to overwrite it —
/// but the "Adopt" button next to it would have *moved a built-in account out of CN=Users*,
/// which is a far worse outcome than the problem it solves. A collision with one of these is
/// reported and left alone; renaming the user in the app is the fix.
nonisolated enum ADProtectedObject {
    static let names: Set<String> = ["administrator", "guest", "krbtgt"]

    static func isProtected(dn: String, name: String) -> Bool {
        if names.contains(name.lowercased()) { return true }
        return isUnderBuiltin(dn)
    }

    static func isUnderBuiltin(_ dn: String) -> Bool {
        let lower = dn.lowercased()
        return lower.contains(",cn=builtin,") || lower.hasPrefix("cn=builtin,")
    }

    /// The group names Active Directory already owns.
    ///
    /// **This list is the fix for the worst bug this app has had** (18 Sep 2026, build 15). The
    /// sample lab shipped a group called `Guests`. AD has a built-in `Guests` in `CN=Builtin`,
    /// and **`sAMAccountName` is unique across the whole domain** — so `samba-tool group
    /// addmembers Guests alice` did not fail, and did not create anything: it resolved the
    /// built-in group and put a real user in it. `alice` ended up with
    /// `memberOf: CN=Guests,CN=Builtin,DC=lab,DC=sheep` **and nothing else**, which is a
    /// guest-restricted account, and her Wi-Fi authorisation broke on the NAC *after* the
    /// domain controller had accepted her MSCHAPv2 — a failure that looks like anything but a
    /// group name.
    ///
    /// The planner's "leave an unmanaged object alone" rule was not enough, because it left the
    /// group alone and then wrote **members** into it anyway. Membership is the dangerous half.
    ///
    /// The names are matched case-insensitively and cover Windows Server's own defaults, not
    /// only the ones this lab hit. A group in this list is refused by `Validation` before it
    /// can reach a directory at all, and reported as a collision if one is somehow already
    /// there.
    static let groupNames: Set<String> = [
        // The one that actually caused the damage.
        "guests",
        // CN=Users — domain-wide principals.
        "domain admins", "domain users", "domain guests", "domain computers",
        "domain controllers", "enterprise admins", "schema admins",
        "group policy creator owners", "read-only domain controllers",
        "enterprise read-only domain controllers", "cert publishers", "dnsadmins",
        "dnsupdateproxy", "ras and ias servers", "protected users",
        "key admins", "enterprise key admins",
        "allowed rodc password replication group", "denied rodc password replication group",
        // CN=Builtin — the local groups every DC has.
        "administrators", "users", "account operators", "backup operators",
        "print operators", "server operators", "replicator",
        "remote desktop users", "remote management users", "network configuration operators",
        "performance monitor users", "performance log users", "event log readers",
        "distributed com users", "cryptographic operators", "iis_iusrs",
        "pre-windows 2000 compatible access", "incoming forest trust builders",
        "windows authorization access group", "terminal server license servers",
        "certificate service dcom access", "access control assistance operators",
        "storage replica administrators",
    ]

    /// A group this app must never create, rename into, delete, or add a member to.
    ///
    /// Two independent tests, and both are needed. The **name** test works before anything has
    /// been read from a directory — which is where `Validation` uses it, and the only place a
    /// person can be warned in time. The **DN** test catches a group in `CN=Builtin` whatever
    /// it is called, because a domain may be localised or may have had one renamed.
    static func isProtectedGroup(name: String, dn: String = "") -> Bool {
        if groupNames.contains(name.trimmingCharacters(in: .whitespaces).lowercased()) { return true }
        return !dn.isEmpty && isUnderBuiltin(dn)
    }
}

// MARK: - CLDAP

/// The netlogon "ping" a Windows client sends to udp/389 before it will even consider a DC.
///
/// It is a plain LDAP searchRequest, but nothing in the OpenLDAP client tools will send one
/// over UDP, so the bytes are built by hand. The reply (~135 bytes) is a searchResEntry
/// carrying the `Netlogon` attribute; getting one back proves the DC answers the *discovery*
/// path and not merely TCP 389, which is the distinction that decides whether a join works.
nonisolated enum CLDAP {
    static func netlogonQuery(realm: String, messageID: Int = 1) -> [UInt8] {
        let filter = tlv(0xA0, equality("DnsDomain", Array(realm.lowercased().utf8))
                              + equality("NtVer", [0x06, 0x00, 0x00, 0x00]))
        let request = tlv(0x63,
                          tlv(0x04, [])                    // baseObject: the rootDSE
                          + tlv(0x0A, [0x00])              // scope: baseObject
                          + tlv(0x0A, [0x00])              // derefAliases: never
                          + tlv(0x02, [0x00])              // sizeLimit
                          + tlv(0x02, [0x00])              // timeLimit
                          + tlv(0x01, [0x00])              // typesOnly: FALSE
                          + filter
                          + tlv(0x30, tlv(0x04, Array("Netlogon".utf8))))
        return tlv(0x30, tlv(0x02, integer(messageID)) + request)
    }

    /// A reply that is an LDAP message and names the attribute back. Anything shorter than a
    /// header is noise from something else on the port.
    static func isNetlogonReply(_ bytes: [UInt8]) -> Bool {
        guard bytes.count >= 20, bytes[0] == 0x30 else { return false }
        return contains(bytes, Array("Netlogon".utf8)) || contains(bytes, Array("netlogon".utf8))
    }

    private static func contains(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
        guard needle.count <= haystack.count else { return false }
        for start in 0...(haystack.count - needle.count)
        where Array(haystack[start..<start + needle.count]) == needle { return true }
        return false
    }

    private static func equality(_ attribute: String, _ value: [UInt8]) -> [UInt8] {
        tlv(0xA3, tlv(0x04, Array(attribute.utf8)) + tlv(0x04, value))
    }

    private static func integer(_ value: Int) -> [UInt8] {
        guard value > 0 else { return [0] }
        var out: [UInt8] = []
        var rest = value
        while rest > 0 { out.insert(UInt8(rest & 0xFF), at: 0); rest >>= 8 }
        if out[0] & 0x80 != 0 { out.insert(0, at: 0) }   // keep it positive
        return out
    }

    /// Tag, definite length (short form under 128, long form above), content.
    private static func tlv(_ tag: UInt8, _ content: [UInt8]) -> [UInt8] {
        var out: [UInt8] = [tag]
        if content.count < 128 {
            out.append(UInt8(content.count))
        } else {
            var length: [UInt8] = []
            var rest = content.count
            while rest > 0 { length.insert(UInt8(rest & 0xFF), at: 0); rest >>= 8 }
            out.append(0x80 | UInt8(length.count))
            out += length
        }
        return out + content
    }
}

// MARK: - Kerberos

nonisolated enum ADKerberos {
    /// A krb5.conf of our own, so the self-test never reads or writes `/etc/krb5.conf`.
    ///
    /// **`kdc = tcp/<ip>:88` is load-bearing.** The KDC is reached through a published port on
    /// the Mac, and the AS-REP for a real principal is larger than a UDP datagram survives
    /// through vmnet; over UDP `kinit` retries and times out with nothing useful to say.
    static func configuration(realm: String, address: String) -> String {
        """
        [libdefaults]
            default_realm = \(realm.uppercased())
            dns_lookup_realm = false
            dns_lookup_kdc = false
            rdns = false
            udp_preference_limit = 1

        [realms]
            \(realm.uppercased()) = {
                kdc = tcp/\(address):88
                admin_server = \(address)
            }

        [domain_realm]
            .\(realm.lowercased()) = \(realm.uppercased())
            \(realm.lowercased()) = \(realm.uppercased())
        """
    }
}

// MARK: - What to type on the device

/// Short, per-device instructions. Deliberately only the steps that were actually carried out
/// against this DC: a cheat-sheet that guesses is worse than none, because it is believed.
nonisolated enum ADDeviceGuide {
    struct Sheet: Identifiable, Sendable {
        var id: String { title }
        var title: String
        var steps: [String]
        /// nil when the path has been done for real.
        var caveat: String?
    }

    static func sheets(settings: ADSettings, hostIP: String) -> [Sheet] {
        let realm = settings.realm
        return [
            // **First, because it is the product this lab exists for** (build 22, owner: the
            // pane listed Windows, ClearPass and Linux and no iMaster at all). The steps are
            // the owner's own procedure, walked on a real three-node cluster on 18 Sep 2026.
            Sheet(title: "iMaster NCE-Campus",
                  steps: [
                    "Management Plane, port 18102 ▸ Product ▸ System Monitoring ▸ Service: find RadiusServerService and note the management IP of every node running it — on the owner's cluster that is three (OMP, SERVICE1, DATABACKUP), and every one of them has to be done.",
                    "On each node: ssh sopuser@<node management IP>, su - root, back up /etc/resolv.conf, and leave it containing only \u{201C}options timeout:1 attempts:1 rotate\u{201D} and \u{201C}nameserver \(hostIP)\u{201D} — a second resolver that cannot answer for \(realm) breaks the join rather than making it more reliable.",
                    "Check on each node: nslookup \(settings.dcFQDN) must answer \(hostIP), and nslookup -type=srv _ldap._tcp.dc._msdcs.\(realm) must name the domain controller with port 389.",
                    "Also on each node: date and hostname -f — the clock must be within five minutes of the domain controller, and each host name must be unique and must not be \(realm) or \(settings.netbiosDomain).",
                    "Service Plane ▸ System ▸ System Management ▸ Third-Party Service ▸ AD Domain Configuration ▸ Add: AD domain name \(realm) (not \(settings.dcFQDN)), NetBIOS \(settings.netbiosDomain), Domain account Administrator — a user name, never CN=Administrator,\u{2026} — and its password.",
                    "Domain Name Resolution Verification, then Add to Domain, then open the Node List: every node must show Trust Status Normal.",
                    "Admission Management ▸ Admission Resource ▸ External Data Source ▸ AD/LDAP Synchronization: Server type Active Directory, Primary server address \(hostIP), AD domain name \(realm), Base DN \(settings.baseDN), Authentication port 389 with TLS disabled (636 with TLS enabled, once this lab's CA is imported under Certificate Management).",
                    "Synchronization account CN=Administrator,CN=Users,\(settings.baseDN) — this form wants the DN, unlike the join form above — then Test Connection.",
                    "Synchronization mode Mode 1 (OU-based): CN=Users is a container and not an OU, so accounts in it are invisible to Mode 1; put them in an OU — this app creates its OUs at the top level, e.g. OU=Staff,\(settings.baseDN) — and choose it as the Source OU.",
                    "Synchronize, then check the result under Admission Management ▸ Admission Resource ▸ Admission User Management ▸ User.",
                  ],
                  caveat: "Steps 1–8 were done against a real iMaster NCE-Campus cluster on 18 Sep 2026 and its connection test passed; the user list after an OU-based synchronisation has not been watched through."),
            Sheet(title: "Windows 10 / 11 Pro",
                  steps: [
                    "Settings ▸ Network ▸ adapter ▸ Edit DNS ▸ Manual: IPv4 DNS = \(hostIP). Remove the alternate, and switch IPv6 DNS off or set it manually too.",
                    "Command Prompt: nslookup -type=SRV _ldap._tcp.dc._msdcs.\(realm) — it must answer \(settings.dcFQDN).",
                    "Settings ▸ System ▸ About ▸ Domain or workgroup ▸ Change ▸ Member of Domain: type \(realm). Not \(settings.dcFQDN) — that is the controller's name, and Windows will look for a domain of that name and fail.",
                    "Credentials: Administrator and the password below.",
                    "Restart, then sign in as \(realm.uppercased())\\alice (or .\\ for a local account).",
                  ],
                  caveat: nil),
            Sheet(title: "Aruba ClearPass",
                  steps: [
                    "Configuration ▸ Authentication ▸ Sources ▸ Add, type Active Directory.",
                    "Hostname: \(hostIP) — ClearPass's form asks for the *controller*, not the domain.",
                    "Base DN: \(settings.baseDN). Bind DN: Administrator@\(realm).",
                    "Join AD Domain: domain controller \(settings.dcFQDN), domain \(realm). ClearPass must resolve that name, so point its DNS at \(hostIP) first.",
                  ],
                  caveat: "Not tested against a real ClearPass — the LDAP side of it is proven, the Join AD Domain button is not."),
            Sheet(title: "Linux / generic (Samba)",
                  steps: [
                    "echo 'nameserver \(hostIP)' > /etc/resolv.conf (and remove the others).",
                    "Set realm = \(realm.uppercased()), workgroup = \(settings.netbiosDomain), security = ADS in smb.conf.",
                    "kinit Administrator@\(realm.uppercased())",
                    "net ads join -U Administrator",
                    "net ads testjoin — it must say \u{201C}Join is OK\u{201D}.",
                  ],
                  caveat: nil),
        ]
    }

    /// The two commands that tell you whether DNS is the problem, which it usually is.
    static func verificationCommands(realm: String) -> [(label: String, command: String)] {
        [("Windows: check the DC records", "nslookup -type=SRV _ldap._tcp.dc._msdcs.\(realm)"),
         ("Windows: force DC discovery", "nltest /dsgetdc:\(realm) /force")]
    }
}
