import Foundation

// MARK: - What a directory is, to the rest of the app

/// One account, as the **backend** has it.
///
/// Build 16's architecture decision (PROJECT-STATUS §13) is that the backend is the original
/// and the app keeps no user table of its own. So this type is not `LabUser`: it carries a DN,
/// it knows whether the object may be edited at all, and it has **no password field** — a
/// directory will not tell anyone what a password is, and a struct with a `password` on it is
/// an invitation to believe otherwise.
nonisolated struct DirectoryUser: Sendable, Equatable, Identifiable {
    var id: String { dn }
    var username: String
    var displayName: String = ""
    /// `Staff/IT`, the app's own OU notation. Empty means the top of the directory.
    var ou: String = ""
    var groups: [String] = []
    var enabled = true
    var dn: String = ""
    /// An object the app must not edit. This is decided per object, not per container: ordinary
    /// accounts in `CN=Users` are editable, while Administrator, Guest and krbtgt are not.
    var isReadOnly = false
}

nonisolated struct DirectoryGroup: Sendable, Equatable, Identifiable {
    var id: String { dn }
    var name: String
    var description: String = ""
    var members: [String] = []
    var dn: String = ""
    var isReadOnly = false
}

nonisolated struct DirectoryOU: Sendable, Equatable, Identifiable {
    var id: String { dn }
    /// `Staff/IT`.
    var path: String
    var dn: String = ""
    var isReadOnly = false
}

/// **A machine account** (build 24) — a domain-joined computer, as the DC has it.
///
/// It is deliberately **not** a `DirectoryUser`, although Active Directory gives it
/// `objectClass: user`. Build 27 gives computers their own node and table in the Users pane;
/// that separation keeps person-only fields and actions away from machine accounts while
/// still making joined PCs visible where AD administrators expect to find them.
nonisolated struct DirectoryComputer: Sendable, Equatable, Identifiable {
    var id: String { dn }
    /// `sAMAccountName`, `$` and all: `DC1$`.
    var account: String
    /// The host name without the `$`, lower-cased: `dc1`. This is the half Windows puts in
    /// `host/dc1.lab.sheep`.
    var host: String
    var dn: String = ""
    var enabled = true
    /// The domain controller's own account is shown with the joined machines but cannot be
    /// deleted. Ordinary accounts in `CN=Computers` are not read-only merely because of their
    /// container.
    var isReadOnly = false

    init(account: String, dn: String = "", enabled: Bool = true, isReadOnly: Bool = false) {
        self.account = account
        self.host = account.hasSuffix("$") ? String(account.dropLast()).lowercased() : account.lowercased()
        self.dn = dn
        self.enabled = enabled
        self.isReadOnly = isReadOnly
    }
}

/// **The names a Windows supplicant offers for a machine, and the one tag they all carry**
/// (build 24).
///
/// A domain-joined PC doing 802.1X before anybody logs in authenticates *as the computer*,
/// with the machine account's password inside PEAP-MSCHAPv2. Which string it puts in
/// `User-Name` is not one thing: it depends on the Windows version, on whether the profile
/// says "computer authentication" or "user or computer", and on whether the supplicant was
/// told to use the UPN form. So every form it can send is written into the `users` file
/// against the same NT hash, rather than the app guessing at one and the join failing for a
/// reason nobody can see from the switch.
///
/// **Nothing in the generated configuration rewrites `User-Name` on the way in.** There is no
/// `realm` module and no `suffix` module in the generated `authorize` section, `proxy_requests`
/// is `no`, and `preprocess` is not loaded — so `dc1$@lab.sheep` is *not* split at the `@` and
/// `LABSHEEP\DC1$` is *not* split at the backslash. `rlm_files` therefore sees exactly what the
/// supplicant sent, which is why these are five separate entries and not one with a regex.
/// The `ad` suite drives each one through the real server and prints what reached the file.
nonisolated enum MachineIdentity {
    /// The group every machine account is tagged with, so a Policy rule can name them. It is
    /// Active Directory's own name for the group every computer is in, which is what somebody
    /// writing the rule will look for.
    static let groupTag = "Domain Computers"

    /// Every identity form, in the order they go into the file. De-duplicated and never empty
    /// strings — a lab with no NetBIOS name simply has one form fewer.
    static func forms(host: String, realm: String, netbiosDomain: String) -> [String] {
        let host = host.lowercased()
        guard !host.isEmpty else { return [] }
        let realm = realm.lowercased()
        let account = host.uppercased() + "$"
        var out: [String] = []
        if !realm.isEmpty { out.append("host/\(host).\(realm)") }
        out.append("host/\(host)")
        if !netbiosDomain.isEmpty { out.append("\(netbiosDomain.uppercased())\\\(account)") }
        out.append(account)
        if !realm.isEmpty { out.append("\(host)$@\(realm)") }
        var seen = Set<String>()
        return out.filter { seen.insert($0).inserted }
    }

    /// True for a `User-Name` that is one of the forms above — what the Status pane uses to
    /// label a row, and what `PolicyEvaluator` uses for "Identity is a computer account".
    static func looksLikeMachine(_ userName: String) -> Bool {
        let name = userName.lowercased()
        if name.hasPrefix("host/") { return true }
        let account = name.contains("\\") ? String(name.split(separator: "\\").last ?? "") : name
        let bare = account.split(separator: "@").first.map(String.init) ?? account
        return bare.hasSuffix("$")
    }
}

/// **A joined machine's activity state** (build 26).
///
/// Build 25 listed the computers as four unlabelled `Text`s in a `PlainRow` — name, DNS name,
/// OS, creation time — which is a table drawn by hand and nothing else. The mock makes it a
/// real one: **Computer · Joined · Last seen · Status**, with the same Trusted / Idle pill the
/// rest of the app uses.
///
/// "Last seen" and the pill are the two the domain controller does not hand over. `ADComputer`
/// carries `whenCreated` and nothing about use, and asking the DC for `lastLogonTimestamp`
/// would be a new query per refresh for a figure Active Directory only updates every fortnight
/// anyway. So it is read out of **this app's own** authentication list, which is the number
/// that matters here — the last time the machine authenticated *against this RADIUS server* —
/// and it is honest about never having seen one.
///
/// Pure, so the five identity forms, the recency threshold and the wording are unit tests
/// rather than a read of a view.
nonisolated enum JoinedComputer {
    /// Past this, a machine is Idle rather than Trusted. A week: a lab PC that has not
    /// 802.1X'd in seven days is one to look at, and a machine that authenticated this morning
    /// is one that works.
    static let idleAfter: TimeInterval = 7 * 24 * 60 * 60

    /// Whether an authentication event belongs to this machine. Any of the five forms counts,
    /// because which one Windows sends depends on its version and the profile —
    /// `MachineIdentity.forms` is the same list `ConfigGenerator` writes.
    static func isSameMachine(event userName: String, computer: String,
                              realm: String, netbiosDomain: String) -> Bool {
        let host = computer.hasSuffix("$") ? String(computer.dropLast()) : computer
        let forms = Set(MachineIdentity.forms(host: host, realm: realm,
                                              netbiosDomain: netbiosDomain).map { $0.lowercased() })
        return forms.contains(userName.lowercased())
    }

    /// Trusted while it has been seen inside `idleAfter`; Idle otherwise, including never.
    static func isTrusted(lastSeen: Date?, now: Date) -> Bool {
        guard let lastSeen else { return false }
        return now.timeIntervalSince(lastSeen) <= idleAfter
    }

    static func statusWord(lastSeen: Date?, now: Date) -> String {
        isTrusted(lastSeen: lastSeen, now: now) ? "Trusted" : "Idle"
    }

    /// "today 09:12", "2 days ago", "not yet". Integer arithmetic and no `DateFormatter` — the
    /// same rule `LogTime` follows, and for the same reason: a Thai-locale Mac is free to print
    /// Thai digits and a Buddhist year out of a system format.
    static func lastSeenLabel(_ lastSeen: Date?, now: Date, clock: (Date) -> String) -> String {
        guard let lastSeen else { return "not yet" }
        let days = Int(now.timeIntervalSince(lastSeen) / (24 * 60 * 60))
        switch days {
        case ..<0: return clock(lastSeen)
        case 0: return "today \(clock(lastSeen))"
        case 1: return "yesterday"
        default: return "\(days) days ago"
        }
    }
}

/// Everything the panes draw, read in one go.
///
/// The panes render a snapshot rather than querying per row: a directory read is a subprocess,
/// and a list of forty users must not be forty of them. It is refreshed after every edit and
/// every thirty seconds.
nonisolated struct DirectorySnapshot: Sendable, Equatable {
    var users: [DirectoryUser] = []
    var groups: [DirectoryGroup] = []
    var ous: [DirectoryOU] = []
    /// **Machine accounts** (build 24). Only Samba AD has any: OpenLDAP cannot be joined, so
    /// the OpenLDAP parser leaves this empty and nothing downstream changes for that backend.
    /// No pane draws them — see `DirectoryComputer`.
    var computers: [DirectoryComputer] = []
    /// The domain the machine identities are built from. Empty for OpenLDAP.
    var realm = ""
    var netbiosDomain = ""
    var takenAt = Date(timeIntervalSince1970: 0)

    static let empty = DirectorySnapshot()
}

/// What went wrong, in terms a pane can show beside the row that failed.
///
/// Every backend's tool says it differently — samba-tool prints a Python traceback, the
/// OpenLDAP tools print `ldap_add: Already exists (68)` — so the mapping into these cases is
/// `DirectoryErrorMap`, and it is the part that gets the unit tests. The associated string is
/// always something a person can act on.
nonisolated enum DirectoryError: Error, Equatable, Sendable {
    /// The backend is not running at all.
    case notRunning(String)
    /// The name is already taken — by another object, or by the directory itself.
    case nameTaken(String)
    /// A name the directory owns: `Guests`, `Domain Admins`, `CN=Builtin`. Never adoptable.
    case builtIn(String)
    /// The password was refused by the domain's policy.
    case passwordRefused(String)
    case notFound(String)
    case refused(String)
    /// Anything the mapping did not recognise, with the tool's own last line.
    case tool(String)

    var message: String {
        switch self {
        case .notRunning(let s), .nameTaken(let s), .builtIn(let s), .passwordRefused(let s),
             .notFound(let s), .refused(let s), .tool(let s):
            return s
        }
    }
}

/// **The one interface between the Directory module and everything else** (PROJECT-STATUS §13).
///
/// Three implementations — `ADDirectory` (Samba in a container), `OpenLDAPDirectory` (the
/// bundled slapd, edited online) and `OfflineDirectory` (LDAP is off, everything refuses) —
/// and two consumers: the Directory panes, which use all of it, and the RADIUS module, which
/// uses `snapshot()` and `ntHash(of:)` and knows nothing else about identity.
///
/// Every edit applies **immediately**. There is no Apply in a directory pane, and none of these
/// calls restarts anything: that is the whole point of build 16, and it is why `setPassword` is
/// a method here rather than a field on `DirectoryUser`.
protocol DirectoryProvider: Sendable {
    /// What the backend is called in the UI: "Samba AD (lab.sheep)", "OpenLDAP".
    var label: String { get }
    /// False when the backend is not up. Every other call then fails with `.notRunning`.
    var isAvailable: Bool { get }

    func snapshot() async throws -> DirectorySnapshot

    func createUser(_ username: String, displayName: String, ou: String, password: String) async throws
    func setPassword(_ username: String, to password: String) async throws
    func setDisplayName(_ username: String, to displayName: String) async throws
    func setEnabled(_ username: String, to enabled: Bool) async throws
    func moveUser(_ username: String, toOU ou: String) async throws
    func renameUser(_ username: String, to newName: String) async throws
    func deleteUser(_ username: String) async throws

    func createGroup(_ name: String, description: String) async throws
    func deleteGroup(_ name: String) async throws
    func setMembership(of username: String, groups: [String]) async throws

    func createOU(_ path: String) async throws
    func renameOU(_ path: String, to newLeaf: String) async throws
    func moveOU(_ path: String, under parent: String) async throws
    func deleteOU(_ path: String) async throws

    /// The MD4 "NT hash" of a user's current password, uppercase hex, or nil when the backend
    /// cannot produce one. **This is how a password changed outside the app reaches RADIUS**:
    /// ADUC or `samba-tool` sets it in the domain, the app pulls the hash and writes
    /// `NT-Password := 0x…` into radiusd's `authorize`. See `RadiusAuthorize`.
    func ntHash(of username: String) async throws -> String?

    /// Whether `setEnabled` means anything here. **OpenLDAP says no**: "account disabled" is
    /// an Active Directory idea (`userAccountControl` bit 0x2) and inetOrgPerson has no
    /// equivalent, so the Users pane hides the switch rather than offering one that throws.
    var supportsDisable: Bool { get }
}

extension DirectoryProvider {
    /// Active Directory has the flag; only OpenLDAP overrides this.
    var supportsDisable: Bool { true }
}

// MARK: - Writing an LDIF value that means what it says

/// **The one encoder every LDIF this app writes goes through** (build 20, audit N-5).
///
/// RFC 2849 does not let an attribute value be written `attr: <value>` unconditionally. A
/// value that begins with a space, a `:` or a `<`, one that ends with a space, one that holds
/// a NUL, LF or CR, or one carrying **any** byte above 127 has to be written
/// `attr:: <base64>` — otherwise the reader gets something other than what was meant, or the
/// record ends in the middle.
///
/// Build 19 closed the reachable half of this by refusing control characters at the edit, so
/// nothing typed into this app can produce a broken record. What it did not close is a value
/// that arrives from a directory this app did **not** write to — an account created in ADUC
/// with a Thai display name, a description somebody pasted with a leading space — which is
/// then copied into a seed, a modify or a group entry. Six generators each wrote `attr: value`
/// their own way; this is the one that decides, and all six call it.
///
/// Non-ASCII is the common case, not the hostile one: `displayName: ผู้ใช้` is perfectly
/// ordinary in this owner's lab and is exactly what the RFC says must be base64.
nonisolated enum LDIFValue {
    /// Would `attr: <value>` be a lie?
    static func needsBase64(_ value: String) -> Bool {
        let scalars = value.unicodeScalars
        guard let first = scalars.first else { return false }
        if first == " " || first == ":" || first == "<" { return true }
        if scalars.last == " " { return true }
        for scalar in scalars {
            // NUL, LF and CR end the value or the record; anything above 127 is not a
            // SAFE-CHAR, and this app's files are UTF-8, not ASCII.
            if scalar.value == 0 || scalar.value == 0x0A || scalar.value == 0x0D { return true }
            if scalar.value > 127 { return true }
        }
        return false
    }

    /// One LDIF line, without its newline: `cn: alice`, or `cn:: 4Lig4Li54LmJ…`.
    static func line(_ attribute: String, _ value: String) -> String {
        needsBase64(value)
            ? "\(attribute):: \(Data(value.utf8).base64EncodedString())"
            : "\(attribute): \(value)"
    }

    /// The same, with the newline — what a generator building a record actually appends.
    static func row(_ attribute: String, _ value: String) -> String { line(attribute, value) + "\n" }

    /// Several values of one attribute, in order.
    static func rows(_ attribute: String, _ values: [String]) -> String {
        values.map { row(attribute, $0) }.joined()
    }
}

// MARK: - Moving a whole database to another base DN

/// **Rewriting an LDIF from one base DN to another** (build 24).
///
/// Build 24 gives the lab one name for both backends, so an OpenLDAP database that was built
/// for `dc=lab,dc=local` has to become one for `dc=lab,dc=sheep` — and the users, groups, OUs
/// and, above all, the **password hashes** in it have to survive, because since build 17 that
/// database *is* the directory and `lab.json`'s seed table is a year out of date.
///
/// `rebuildLDAP`'s answer until now was to throw the database away and re-seed from that seed
/// table, which is right for a base DN somebody typed on a fresh lab and catastrophic here. So
/// the database is exported with `slapcat`, put through this, and loaded back with `slapadd`.
///
/// Three things it has to get right, and each of them broke a first draft:
///
/// - **Unfold first.** `slapcat` wraps at 78 columns with a leading space on the continuation,
///   so `member: uid=someone,ou=A/Longer/Path,dc=lab,dc=local` arrives split across two lines
///   and a naive per-line replace finds nothing. Records are unfolded, rewritten, and written
///   back out long — `slapadd` has no line-length limit.
/// - **`::` is base64.** A value that needed base64 on the way out (a Thai display name, a
///   description with a leading space) is still base64 here, and a DN-valued attribute *can*
///   be one. Both forms are decoded, tested and re-encoded through `LDIFValue`.
/// - **Only a DN tail is rewritten.** The replacement is anchored at the end of the value, so
///   a description that happens to mention `dc=lab,dc=local` is left as prose while
///   `creatorsName`, `member`, `memberOf`, `entryDN` and the `dn:` itself all move.
nonisolated enum LDAPSuffixRewrite {
    /// Split an LDIF into records of unfolded lines.
    static func records(_ ldif: String) -> [[String]] {
        var out: [[String]] = []
        var current: [String] = []
        for raw in ldif.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.isEmpty {
                if !current.isEmpty { out.append(current) }
                current = []
                continue
            }
            // A continuation is a leading space; `slapcat` also writes comments, which are not
            // part of any record.
            if line.hasPrefix("#") { continue }
            if line.hasPrefix(" "), !current.isEmpty {
                current[current.count - 1] += line.dropFirst()
            } else {
                current.append(line)
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    /// `attr`, its value and whether that value arrived base64. nil for a line with no colon.
    static func split(_ line: String) -> (attribute: String, value: String, wasBase64: Bool)? {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let attribute = String(line[line.startIndex..<colon])
        var rest = line[line.index(after: colon)...]
        var wasBase64 = false
        if rest.first == ":" {
            wasBase64 = true
            rest = rest.dropFirst()
        }
        let text = rest.trimmingCharacters(in: .whitespaces)
        if wasBase64 {
            guard let data = Data(base64Encoded: text), let decoded = String(data: data, encoding: .utf8)
            else { return nil }             // not text: leave the line exactly as it is
            return (attribute, decoded, true)
        }
        return (attribute, text, false)
    }

    /// `uid=alice,ou=IT,dc=lab,dc=local` → `uid=alice,ou=IT,dc=lab,dc=sheep`, or nil when the
    /// value is not under `from` at all.
    static func rewritten(value: String, from old: String, to new: String) -> String? {
        if value.caseInsensitiveCompare(old) == .orderedSame { return new }
        let tail = "," + old
        guard value.count > tail.count,
              value.lowercased().hasSuffix(tail.lowercased()) else { return nil }
        return String(value.dropLast(old.count)) + new
    }

    /// `dc=lab,dc=sheep` → (`dc`, `lab`). The first RDN, split.
    static func firstRDN(of dn: String) -> (attribute: String, value: String)? {
        let head = dn.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        guard let equals = head.firstIndex(of: "=") else { return nil }
        return (String(head[head.startIndex..<equals]).trimmingCharacters(in: .whitespaces),
                String(head[head.index(after: equals)...]).trimmingCharacters(in: .whitespaces))
    }

    /// The whole file, ready for `slapadd`.
    ///
    /// **An entry's naming attribute has to follow its RDN**, and this is the line that caught
    /// it: the root entry of `dc=lab,dc=sheep` carries `dc: lab` as an ordinary attribute, and
    /// moving it to `dc=old,dc=sheep` without touching that left `dc: lab` under an RDN of
    /// `dc=old`. slapadd refuses the entry — "value of naming attribute 'dc' is not present" —
    /// and the whole rename fails at the last step with the database already exported. Only the
    /// **top** entry can be affected, because every other RDN (`uid=alice`, `ou=IT`,
    /// `cn=NetAdmins`) is below the suffix and does not move; but a lab domain whose first
    /// label changes (`lab.sheep` → `site2.sheep`) is an ordinary thing to do.
    static func rewrite(ldif: String, from old: String, to new: String) -> String {
        guard !old.isEmpty, !new.isEmpty, old.caseInsensitiveCompare(new) != .orderedSame else { return ldif }
        var out = ""
        for record in records(ldif) {
            // What this record's own RDN becomes, if anything.
            var renamedRDN: (attribute: String, from: String, to: String)?
            if let dnLine = record.first(where: { split($0)?.attribute.lowercased() == "dn" }),
               let parts = split(dnLine),
               let movedDN = rewritten(value: parts.value, from: old, to: new),
               let before = firstRDN(of: parts.value), let after = firstRDN(of: movedDN),
               before.attribute.caseInsensitiveCompare(after.attribute) == .orderedSame,
               before.value != after.value {
                renamedRDN = (before.attribute, before.value, after.value)
            }
            for line in record {
                guard let parts = split(line) else {
                    out += line + "\n"
                    continue
                }
                if let moved = rewritten(value: parts.value, from: old, to: new) {
                    out += LDIFValue.row(parts.attribute, moved)
                    continue
                }
                if let renamedRDN,
                   parts.attribute.caseInsensitiveCompare(renamedRDN.attribute) == .orderedSame,
                   parts.value == renamedRDN.from {
                    out += LDIFValue.row(parts.attribute, renamedRDN.to)
                    continue
                }
                out += line + "\n"
            }
            out += "\n"
        }
        return out
    }

    /// Does this export need moving at all? Used by the suites and by the log line.
    static func countsEntries(in ldif: String) -> Int {
        records(ldif).count
    }
}

// MARK: - Names no directory will give up

/// Names that belong to the directory itself, refused **at typing time** in every backend.
///
/// The case for refusing them in OpenLDAP too, where they are harmless, is the build-15
/// incident: `sAMAccountName` is unique domain-wide *including groups*, a lab group called
/// `Guests` resolved to `CN=Guests,CN=Builtin`, and `samba-tool group addmembers Guests alice`
/// quietly put a real user into the built-in guest group — where her Wi-Fi authorisation broke
/// *after* the DC had already accepted her password. The backend is switchable at any moment,
/// so a name that is safe in one and fatal in the other is a trap that has to be closed in both.
nonisolated enum DirectoryNames {
    /// The containers AD keeps its own objects in. The containers themselves are shown,
    /// greyed and never edited. Their contents are classified separately: `CN=Users` contains
    /// both protected built-ins and ordinary accounts that must remain editable.
    static let readOnlyContainers = ["CN=Users", "CN=Computers", "CN=Builtin", "CN=System",
                                     "CN=Managed Service Accounts", "CN=ForeignSecurityPrincipals",
                                     "CN=Program Data", "CN=NTDS Quotas", "CN=Infrastructure",
                                     "CN=LostAndFound", "OU=Domain Controllers"]

    /// Is this DN inside one of them?
    static func isReadOnly(dn: String) -> Bool {
        let lower = dn.lowercased()
        return readOnlyContainers.contains { lower.contains($0.lowercased() + ",") || lower.hasPrefix($0.lowercased() + ",") }
    }

    static func isInsideDomain(dn: String, baseDN: String) -> Bool {
        let lower = dn.lowercased()
        let base = baseDN.lowercased()
        return lower == base || lower.hasSuffix("," + base)
    }

    static func isEditableUser(dn: String, name: String, baseDN: String) -> Bool {
        isInsideDomain(dn: dn, baseDN: baseDN)
            && !ADProtectedObject.isProtected(dn: dn, name: name)
            && !name.hasSuffix("$")
    }

    static func isEditableGroup(dn: String, name: String, baseDN: String) -> Bool {
        isInsideDomain(dn: dn, baseDN: baseDN)
            && !ADProtectedObject.isProtectedGroup(name: name, dn: dn)
    }

    static func isEditableComputer(dn: String, baseDN: String) -> Bool {
        guard isInsideDomain(dn: dn, baseDN: baseDN) else { return false }
        let lower = dn.lowercased()
        return !lower.contains(",ou=domain controllers,")
            && !lower.hasPrefix("ou=domain controllers,")
    }

    /// Why this name cannot be used, or nil when it can.
    ///
    /// Reuses `ADProtectedObject.groupNames` rather than keeping a second list: two lists of
    /// built-in names in one app is one list that will be updated.
    ///
    /// **`backend` decides only the built-in half** (build 21). The shape rules — no `,` `=`
    /// `+` `\`, no control characters, no `%{`, a length a directory will take — are the same
    /// in both backends, because the files this app generates are the same in both. The list
    /// of names Active Directory gives itself is not: `Guests`, `Domain Admins` and
    /// `Administrator` mean nothing to slapd, and refusing them there was this app inventing a
    /// rule its own directory does not have. It is still refused in AD for the build-15
    /// reason — `sAMAccountName` is unique domain-wide including groups, and a lab group
    /// called `Guests` silently resolved to `CN=Guests,CN=Builtin`.
    static func problem(with name: String, kind: Kind,
                        backend: DirectoryBackend = .activeDirectory) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "The name cannot be empty." }
        if trimmed.contains(",") || trimmed.contains("=") || trimmed.contains("\\") || trimmed.contains("+") {
            return "A name cannot contain , = + or \\ — they separate the parts of a DN."
        }
        if let problem = controlCharacterProblem(trimmed, what: "A name") { return problem }
        // `%{…}` is an xlat expansion that `rlm_files` performs, and measured on 3.2.10 there
        // is no escape for it — neither `%%{` nor `\%{` gives a literal. `ConfigGenerator`
        // leaves such an account out of the users file rather than write a line that means
        // something else; this is the same refusal, said where the person can act on it.
        if trimmed.contains("%{") {
            return "A name cannot contain “%{” — FreeRADIUS reads that as a variable to expand and there is no way to escape it."
        }
        if trimmed.count > Validation.maxNameLength {
            return "“\(trimmed.prefix(24))…” is \(trimmed.count) characters. The limit is \(Validation.maxNameLength) — \(Validation.lengthReason)"
        }
        guard backend == .activeDirectory else { return nil }
        switch kind {
        case .user, .group:
            if ADProtectedObject.groupNames.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
                return "“\(trimmed)” is a name Active Directory gives itself. Use something else — “Visitors”, for instance."
            }
            if ["administrator", "guest", "krbtgt"].contains(trimmed.lowercased()) {
                return "“\(trimmed)” is a built-in account name."
            }
        case .ou:
            // An OU is not a security principal, so it cannot collide with a built-in group —
            // only with AD's own containers, which are `CN=`, not `OU=`.
            break
        }
        return nil
    }

    /// A newline, carriage return, tab or NUL anywhere in a value the app writes out.
    ///
    /// **This is the refusal that matters most on the directory path.** LDAP and Active
    /// Directory both accept a newline inside an attribute value; the files this app generates
    /// from them do not. In the FreeRADIUS `users` file every entry is one line, so a value
    /// carrying a newline ends the string in the middle and radiusd rejects the **whole file**
    /// — measured on 3.2.10, `Parse error (check) for entry …: Expected end of line or comma`
    /// — which means nobody authenticates until it is removed. In LDIF a newline starts a new
    /// line of the record, so it can add a second attribute, or a second record, to a
    /// modification the person did not make.
    ///
    /// `ConfigGenerator.quoted` escapes it on the way out, so a value that arrives from a
    /// directory somebody else wrote to cannot break the file. This refuses it at the edit, so
    /// the app never *creates* one — and says why, rather than the person finding out from a
    /// user who silently stopped being in the file.
    static func controlCharacterProblem(_ value: String, what: String) -> String? {
        guard let bad = value.unicodeScalars.first(where: { $0.value < 0x20 || $0.value == 0x7F }) else { return nil }
        let name: String
        switch bad.value {
        case 0x0A: name = "a line break"
        case 0x0D: name = "a carriage return"
        case 0x09: name = "a tab"
        default: name = String(format: "a control character (0x%02X)", bad.value)
        }
        return "\(what) cannot contain \(name). It would end the line in the files this app "
            + "generates — FreeRADIUS would refuse its whole user file, and nobody could sign in."
    }

    /// Free text the app stores on an object: a display name, a group description. Not a name,
    /// so `,` `=` `+` `\` are all fine — but the control characters are not, and neither is a
    /// value longer than the directory will take.
    static func valueProblem(_ value: String, what: String, limit: Int) -> String? {
        if let problem = controlCharacterProblem(value, what: what) { return problem }
        if value.count > limit {
            return "\(what) is \(value.count) characters. The limit is \(limit)."
        }
        return nil
    }

    /// **May this account be issued an EAP-TLS client certificate?** (build 24, the owner
    /// could not find the button.)
    ///
    /// The Users inspector gated the field on `isReadOnly`, which means "this app must not
    /// edit the object" — a container rule, and `CN=Users` is on the list. On the owner's
    /// domain *every* user lives in `CN=Users`, so the button existed for nobody.
    ///
    /// Issuing a certificate is not a directory edit. It signs a `.p12` with the lab CA and
    /// writes it into `certs/clients/`; the directory is not read, not written and not even
    /// running for it. So the container is the wrong question entirely. What is genuinely not
    /// a candidate is an account that is not a person: the three built-ins, anything under
    /// `CN=Builtin`, and a machine or service account (`NAME$`).
    ///
    /// `ADProtectedObject` is reused rather than copied — two lists of built-in names in one
    /// app is one list that will be updated.
    static func mayIssueClientCertificate(username: String, dn: String) -> Bool {
        let name = username.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return false }
        // A machine account, a managed service account, a trust: the `$` is AD's own marker
        // and there is no supplicant behind any of them that a person configures by hand.
        guard !name.hasSuffix("$") else { return false }
        return !ADProtectedObject.isProtected(dn: dn, name: name)
    }

    enum Kind: Sendable { case user, group, ou }
}

// MARK: - Turning tool output into something a person can act on

nonisolated enum DirectoryErrorMap {
    /// Both backends' failures, mapped onto `DirectoryError`.
    ///
    /// Ordered from the most specific text to the least: every LDAP tool prints a numbered
    /// result code *and* a sentence, and the sentences are what change between versions.
    /// samba-tool prints a Python traceback and the LDAP tools print two or three lines; the
    /// useful one is the last that is neither blank nor traceback scaffolding. (The same rule
    /// as `ADController.firstError`, which lives on the main actor and cannot be called from
    /// a pure type — the six lines are cheaper than making that one nonisolated and having to
    /// re-verify everything that calls it.)
    static func lastMeaningfulLine(of output: String) -> String {
        let lines = output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("File \"") && !$0.hasPrefix("Traceback") }
        return lines.last.map { String($0.prefix(240)) } ?? "failed"
    }

    static func map(_ output: String, subject: String = "") -> DirectoryError {
        let lower = output.lowercased()
        let tail = lastMeaningfulLine(of: output)

        if lower.contains("can't contact ldap server") || lower.contains("connection refused")
            || lower.contains("ldap_bind: can't contact") || lower.contains("is not running")
            || lower.contains("no such container") || lower.contains("cannot connect to the container") {
            return .notRunning("The directory is not running.")
        }
        if lower.contains("already exists") || lower.contains("entry_already_exists")
            || lower.contains("(68)") || lower.contains("object exists") {
            return .nameTaken(subject.isEmpty ? "That name is already taken." : "“\(subject)” already exists.")
        }
        if lower.contains("cn=builtin") || lower.contains("built-in") {
            return .builtIn("“\(subject)” is a built-in directory object and cannot be changed here.")
        }
        if lower.contains("password does not meet") || lower.contains("check_password_restrictions")
            || lower.contains("constraint violation") || lower.contains("(19)")
            || lower.contains("password_restriction") {
            return .passwordRefused("The domain refused that password.")
        }
        if lower.contains("no such object") || lower.contains("(32)")
            || lower.contains("unable to find user") || lower.contains("unable to find group") {
            return .notFound(subject.isEmpty ? "It is not in the directory." : "“\(subject)” is not in the directory.")
        }
        if lower.contains("insufficient access") || lower.contains("(50)")
            || lower.contains("invalid credentials") || lower.contains("(49)") {
            return .refused("The directory refused the change: the bind account is not allowed to make it.")
        }
        return .tool(tail)
    }
}

// MARK: - Active Directory, edited live

/// Every `container exec <dc> …` the live AD directory needs, as pure argv.
///
/// Separate from `ADCommands` on purpose, and not a rename of it: that one serves the build-8
/// **sync** model, where the app's table is copied into `OU=SheepRadius` in one planned batch.
/// This one serves build 16's model — the domain *is* the table, edits go in one at a time,
/// and the app's OUs sit at the **top level under the domain** where a NAC that scopes to an
/// OU can see them (the iMaster problem of 18 Sep: `alice` and `bob` in `CN=Users` were
/// invisible to it, and `OU=SheepRadius` was one level deeper than anything it offered).
nonisolated enum ADDirectoryCommands {
    /// `Staff/IT` → `OU=IT,OU=Staff,DC=lab,DC=sheep`. **No managed root**: that is the change.
    static func dn(forOU path: String, baseDN: String) -> String {
        let segments = OUPath.segments(path)
        guard !segments.isEmpty else { return baseDN }
        return segments.reversed().map { "OU=\($0)" }.joined(separator: ",") + "," + baseDN
    }

    /// The inverse, for reading a snapshot back: `OU=IT,OU=Staff,DC=lab,DC=sheep` → `Staff/IT`.
    /// A DN outside the domain, or one with a `CN=` container in it, has no OU path.
    static func ouPath(fromDN dn: String, baseDN: String) -> String {
        let suffix = "," + baseDN
        guard dn.lowercased().hasSuffix(suffix.lowercased()) else { return "" }
        let head = String(dn.dropLast(suffix.count))
        guard !head.isEmpty else { return "" }
        let parts = head.components(separatedBy: ",")
        var segments: [String] = []
        for part in parts.reversed() {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            guard trimmed.lowercased().hasPrefix("ou=") else { continue }
            segments.append(String(trimmed.dropFirst(3)))
        }
        return segments.joined(separator: "/")
    }

    /// The OU a *user's* DN puts them in — their own `CN=` is dropped first.
    static func userOU(fromDN dn: String, baseDN: String) -> String {
        guard let comma = dn.firstIndex(of: ",") else { return "" }
        return ouPath(fromDN: String(dn[dn.index(after: comma)...]), baseDN: baseDN)
    }

    /// `samba-tool user create`.
    ///
    /// `--use-username-as-cn` keeps CN == sAMAccountName, so every DN the app builds later is
    /// the DN the directory really has. The password is NOT here — see `passwordScript`.
    ///
    /// `--userou` is **omitted** when the account belongs at the top level under the domain,
    /// because its value is a DN relative to the domain and that is the empty string. Sending
    /// the base DN instead made samba-tool append the base twice. samba-tool then puts the
    /// account in its own default container and `ADDirectory.createUser` moves it up — two
    /// documented calls rather than one flag used in a way it does not support.
    static func createUser(_ username: String, ou: String, baseDN: String) -> [String] {
        var out = ["samba-tool", "user", "create", username, "--random-password"]
        let relative = relativeDN(dn(forOU: ou, baseDN: baseDN), baseDN: baseDN)
        if !relative.isEmpty { out.append("--userou=" + relative) }
        out.append("--use-username-as-cn")
        return out
    }

    /// True when `createUser` could not name a container and the account has to be moved up.
    static func userNeedsMoveUp(ou: String, baseDN: String) -> Bool {
        relativeDN(dn(forOU: ou, baseDN: baseDN), baseDN: baseDN).isEmpty
    }

    /// `--userou` / `--groupou` want the DN with the domain part taken off. The domain itself
    /// has **nothing** left once that is done, and saying so is the whole point: the empty
    /// string is what tells the caller there is no container to name.
    static func relativeDN(_ dn: String, baseDN: String) -> String {
        if dn.caseInsensitiveCompare(baseDN) == .orderedSame { return "" }
        let suffix = "," + baseDN
        guard dn.lowercased().hasSuffix(suffix.lowercased()) else { return dn }
        return String(dn.dropLast(suffix.count))
    }

    static func moveUser(_ username: String, toOU ou: String, baseDN: String) -> [String] {
        ["samba-tool", "user", "move", username, dn(forOU: ou, baseDN: baseDN)]
    }

    static func renameUser(_ username: String, to newName: String) -> [String] {
        // Both, or the account answers to one name and is displayed under another.
        // Samba 4.22 calls these `--samaccountname` and `--force-new-cn`.  The older-looking
        // `--new-username` / `--new-cn` pair is not accepted and left the pane reporting a
        // failed rename even though every other edit on the same account worked.
        ["samba-tool", "user", "rename", username,
         "--samaccountname=" + newName, "--force-new-cn=" + newName]
    }

    /// **By name, never by DN.** The build-15 rule, kept: a delete that carries a DN can be
    /// pointed at `CN=Guests,CN=Builtin`; one that carries a name is refused by the protected
    /// name list before it is ever built.
    static func deleteUser(_ username: String) -> [String] { ["samba-tool", "user", "delete", username] }
    static func setEnabled(_ username: String, _ enabled: Bool) -> [String] {
        ["samba-tool", "user", enabled ? "enable" : "disable", username]
    }
    /// `samba-tool group add`, **only when there is a container to name**.
    ///
    /// `--groupou` wants a DN *relative* to the domain, and the domain root's relative DN is
    /// the empty string. Passing it anyway sent the whole base DN, which samba-tool then
    /// appended the base to again: the `ad` suite got
    /// `Cannot add CN=ProbeGroup,dc=test,dc=sheep,DC=test,DC=sheep, parent does not exist`.
    /// So a group at the top level goes in as LDIF instead — see `createGroupLDIF`.
    static func createGroup(_ name: String, ou: String, baseDN: String, description: String) -> [String] {
        var out = ["samba-tool", "group", "add", name,
                   "--groupou=" + relativeDN(dn(forOU: ou, baseDN: baseDN), baseDN: baseDN)]
        if !description.isEmpty { out.append("--description=" + description) }
        return out
    }

    /// True when `createGroup` has a container to name; false means use `createGroupLDIF`.
    static func groupNeedsLDIF(ou: String, baseDN: String) -> Bool {
        relativeDN(dn(forOU: ou, baseDN: baseDN), baseDN: baseDN).isEmpty
    }

    /// A group directly under the domain, as `ldbadd` takes it.
    ///
    /// `groupType` is stated rather than left to a default: `-2147483646` is a **global
    /// security** group, which is what every other group this app makes is and what a NAC
    /// expects to find. `sAMAccountName` is what makes the group resolvable by bare name, so
    /// `samba-tool group addmembers <name>` and `group delete <name>` keep working.
    static func createGroupLDIF(_ name: String, baseDN: String, description: String) -> String {
        var out = LDIFValue.row("dn", "CN=\(name),\(baseDN)")
        out += "objectClass: top\nobjectClass: group\n"
        out += LDIFValue.row("cn", name)
        out += LDIFValue.row("sAMAccountName", name)
        out += "groupType: -2147483646\n"
        if !description.isEmpty { out += LDIFValue.row("description", description) }
        out += "\n"
        return out
    }
    static func deleteGroup(_ name: String) -> [String] { ["samba-tool", "group", "delete", name] }
    static func addMember(_ username: String, to group: String) -> [String] {
        ["samba-tool", "group", "addmembers", group, username]
    }
    static func removeMember(_ username: String, from group: String) -> [String] {
        ["samba-tool", "group", "removemembers", group, username]
    }
    static func createOU(_ path: String, baseDN: String) -> [String] {
        ["samba-tool", "ou", "create", dn(forOU: path, baseDN: baseDN)]
    }
    static func deleteOU(_ path: String, baseDN: String) -> [String] {
        ["samba-tool", "ou", "delete", dn(forOU: path, baseDN: baseDN)]
    }
    /// `samba-tool ou move` is also the rename, because an OU's name **is** the last part of
    /// its DN: moving `OU=IT,OU=Staff` to the same parent with a new name is what renaming is.
    static func renameOU(_ path: String, to newLeaf: String, baseDN: String) -> [String] {
        let parent = OUPath.parent(path) ?? ""
        return ["samba-tool", "ou", "move", dn(forOU: path, baseDN: baseDN),
                dn(forOU: parent, baseDN: baseDN), "--new-name=" + newLeaf]
    }
    static func moveOU(_ path: String, under parent: String, baseDN: String) -> [String] {
        ["samba-tool", "ou", "move", dn(forOU: path, baseDN: baseDN), dn(forOU: parent, baseDN: baseDN)]
    }

    /// Everything the panes show, in one search.
    static func readAll(baseDN: String) -> [String] {
        ["ldbsearch", "-H", ADCommands.sambaDatabase, "-b", baseDN, "-s", "sub",
         "(|(objectClass=user)(objectClass=group)(objectClass=organizationalUnit))",
         "dn", "objectClass", "sAMAccountName", "displayName", "description",
         "userAccountControl", "member", "memberOf"]
    }

    // MARK: Passwords, which never appear in an argument vector

    /// Set a password from **stdin**, exactly as `ADCommands.setAdministratorPasswordScript`
    /// does for the domain's own Administrator, and for the same reason: an argument vector is
    /// world-readable in `ps` for as long as the call lasts. `Tests/run.sh live` checks for
    /// that elsewhere, and build 15 left `--newpassword=` on the sync path as a known debt —
    /// this is where that debt is paid.
    ///
    /// `IFS= read -r`: a password may begin or end with a space, and the default IFS eats it.
    static func passwordScript(for username: String) -> String {
        """
        IFS= read -r password
        umask 077
        file=$(mktemp /tmp/.sheepdir-pw.XXXXXX) || exit 70
        printf '%s' "$password" > "$file"
        samba-tool user setpassword \(shellQuoted(username)) --newpassword="$(cat "$file")"
        status=$?
        rm -f "$file"
        exit $status
        """
    }

    /// The whole `container exec` argv for it. `-i` **before** the container id, or the
    /// script's `read` sees EOF at once and the password becomes empty.
    static func setPasswordArguments(container: String, username: String) -> [String] {
        ["exec", "-i", container, "bash", "-c", passwordScript(for: username)]
    }

    /// Single-quote for `bash -c`, the only place this module interpolates a name into a shell.
    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: The NT hash, pulled back out of the domain

    /// `samba-tool user getpassword <name> --attributes=unicodePwd`, run as root inside the DC.
    ///
    /// This is the half of "RADIUS authenticates against the directory" that nothing else can
    /// do. A password changed in ADUC, or by `samba-tool` on the DC, or by the user pressing
    /// ctrl-alt-del on a joined PC, never passes through this app — but `unicodePwd` **is** the
    /// MD4 NT hash, and FreeRADIUS's `NT-Password` check item takes exactly that. See
    /// `RadiusAuthorize.ntPasswordLine`.
    static func getPassword(_ username: String) -> [String] {
        ["samba-tool", "user", "getpassword", username, "--attributes=unicodePwd"]
    }

    /// The hash out of that command's LDIF, as 32 uppercase hex characters.
    ///
    /// LDIF writes a binary attribute base64-encoded after a **double** colon, and folds long
    /// lines by starting the continuation with a space. Both are handled here: a 16-byte hash
    /// is 24 base64 characters and does not fold today, but the rule is the format's, not the
    /// value's, and `samba-tool` prints other attributes in the same block.
    static func ntHash(inLDIF ldif: String) -> String? {
        var collecting = false
        var base64 = ""
        for rawLine in ldif.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if collecting {
                if line.hasPrefix(" ") { base64 += line.dropFirst(); continue }
                break
            }
            guard let range = line.range(of: "unicodePwd::") else {
                // `samba-tool` can also print it as plain text in a hex form on some builds;
                // accept that rather than failing, but only when it is exactly a hash.
                if let plain = line.range(of: "unicodePwd:"), !line.contains("unicodePwd::") {
                    let value = line[plain.upperBound...].trimmingCharacters(in: .whitespaces)
                    if isHashHex(value) { return value.uppercased() }
                }
                continue
            }
            base64 = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            collecting = true
        }
        guard collecting, let data = Data(base64Encoded: base64), data.count == 16 else { return nil }
        return data.map { String(format: "%02X", $0) }.joined()
    }

    private static func isHashHex(_ value: String) -> Bool {
        value.count == 32 && value.allSatisfy { $0.isHexDigit }
    }

    /// Whether an OU/container at this DN is one the app may edit. Users, groups and computers
    /// use the per-object rules in `DirectoryNames` instead; a whole `CN=Users` container is
    /// never a useful proxy for whether the object inside it is protected.
    static func isEditable(dn: String, baseDN: String) -> Bool {
        guard dn.lowercased().hasSuffix(baseDN.lowercased()) else { return false }
        return !DirectoryNames.isReadOnly(dn: dn)
    }
}

// MARK: - OpenLDAP, edited online

/// The bundled client tools' argv and LDIF, for editing a **running** slapd.
///
/// Until build 16 every Apply wiped the database directory and re-ran `slapadd`, which meant
/// slapd was stopped, the directory was empty for a moment and every bind in flight failed —
/// for a display-name change. These commands go through ldapi:// to the live server instead;
/// `slapd` is restarted only for the three things that really are startup-time
/// (`OpenLDAPRestart.reason`).
///
/// **No password is ever an argument.** `-y` (bind password) and `-T` (new password) both take
/// a file, and the caller writes those 0600 inside the app's own lab directory.
nonisolated enum OpenLDAPDirectoryCommands {
    /// Where the tools connect. `ldapi://` — a unix socket in the lab directory — cannot be
    /// reached from another machine and needs no TLS to be honest about a cleartext bind.
    ///
    /// The socket's path goes in the **authority** part of the URI, so every `/` in it has to
    /// be `%2F`; `ldapi:///var/run/…` (unescaped) is a host called `var` and OpenLDAP's own
    /// tools say only "Bad parameter to an ldap routine".
    static func uri(socketPath: String) -> String {
        "ldapi://" + socketPath.replacingOccurrences(of: "%", with: "%25")
            .replacingOccurrences(of: "/", with: "%2F")
    }

    /// Where to send an edit, given what this lab's slapd is actually listening on.
    ///
    /// **`ldapi://` is not there yet.** `LabSettings.listenURLs` offers `ldap://` and `ldaps://`
    /// and nothing else, so today an edit goes to `127.0.0.1` on whichever of the two is up —
    /// a bind on the loopback, which never leaves the Mac. Adding a unix-socket listener is one
    /// line in `ConfigGenerator.slapdConf` plus a restart reason, and it is the better home for
    /// an admin bind (no port, no TLS question, filesystem permissions instead of a password);
    /// build 17 should do it, and this function is where that choice is made exactly once.
    static func preferredURI(settings: LabSettings, socketPath: String? = nil) -> String {
        if let socketPath, !socketPath.isEmpty { return uri(socketPath: socketPath) }
        if settings.ldapPlainEnabled { return "ldap://127.0.0.1:\(settings.ldapPort)" }
        return "ldaps://127.0.0.1:\(settings.ldapsPort)"
    }

    /// The common `-x -H <uri> -D <adminDN> -y <file>` prefix.
    static func bind(uri: String, adminDN: String, passwordFile: String) -> [String] {
        ["-x", "-H", uri, "-D", adminDN, "-y", passwordFile]
    }

    /// Everything the panes show, in one search — the OpenLDAP half of
    /// `ADDirectoryCommands.readAll`. Goes after the `bind(…)` prefix.
    ///
    /// `-LLL` drops the comments and the version line; `memberOf` is the memberof overlay's
    /// output and is **operational**, so it has to be asked for by name or slapd will not
    /// return it even though it is there.
    static func readAll(suffix: String) -> [String] {
        ["-LLL", "-b", suffix, "-s", "sub",
         "(|(objectClass=inetOrgPerson)(objectClass=groupOfNames)(objectClass=organizationalUnit))",
         "dn", "objectClass", "uid", "cn", "displayName", "description", "member", "memberOf"]
    }

    static func dn(forOU path: String, suffix: String) -> String {
        let segments = OUPath.segments(path)
        guard !segments.isEmpty else { return suffix }
        return segments.reversed().map { "ou=\($0)" }.joined(separator: ",") + "," + suffix
    }

    static func userDN(_ username: String, ou: String, suffix: String) -> String {
        "uid=\(username)," + dn(forOU: ou, suffix: suffix)
    }

    static func groupDN(_ name: String, groupsDN: String) -> String { "cn=\(name),\(groupsDN)" }

    /// The LDIF `ldapadd` reads on stdin for a new account.
    ///
    /// `userPassword` is `{SSHA}` and, when the setting is on, `sambaNTPassword` is the MD4 —
    /// the same two attributes the old `slapadd` seed wrote, so a directory edited online and
    /// one built from scratch are byte-for-byte the same account.
    static func addUserLDIF(username: String, displayName: String, ou: String, suffix: String,
                            domain: String, uidNumber: Int, sshaPassword: String,
                            ntPassword: String?) -> String {
        let display = displayName.isEmpty ? username : displayName
        let upn = domain.isEmpty ? username : "\(username)@\(domain)"
        // **The blank line ends the record.** An attribute appended after it is a second entry
        // with no `dn:`, and `ldapadd` refuses the whole file — which is why build 16's version
        // of this function could not create a single user even though its unit test (which only
        // asked whether the attribute was present) passed. The attribute order is `seedLDIF`'s,
        // to the line: an account created online and one built from scratch must be the same
        // account, `sambaNTPassword` included.
        // Every value goes through `LDIFValue` — see the note on it. The attribute order is
        // unchanged, so an account created online and one built from scratch are still the
        // same account line for line.
        var out = LDIFValue.row("dn", userDN(username, ou: ou, suffix: suffix))
        out += "objectClass: inetOrgPerson\nobjectClass: posixAccount\nobjectClass: sheepRadiusAccount\n"
        out += LDIFValue.row("uid", username)
        out += LDIFValue.row("cn", username)
        out += LDIFValue.row("sn", username)
        out += LDIFValue.row("displayName", display)
        out += LDIFValue.row("sAMAccountName", username)
        out += LDIFValue.row("userPrincipalName", upn)
        out += LDIFValue.row("mail", upn)
        out += "uidNumber: \(uidNumber)\ngidNumber: 10000\n"
        out += LDIFValue.row("homeDirectory", "/home/" + username)
        out += LDIFValue.row("userPassword", sshaPassword)
        if let ntPassword { out += LDIFValue.row("sambaNTPassword", ntPassword) }
        // The record terminator, exactly once and last — see the note above.
        out += "\n"
        return out
    }

    static func addOULDIF(path: String, suffix: String) -> String {
        let leaf = OUPath.segments(path).last ?? path
        return LDIFValue.row("dn", dn(forOU: path, suffix: suffix))
            + "objectClass: organizationalUnit\n"
            + LDIFValue.row("ou", leaf)
            + "\n"
    }

    /// **`groupOfNames` and nothing else.**
    ///
    /// Build 16 also wrote `objectClass: sheepRadiusGroup`, which the generated schema does not
    /// define — `ConfigGenerator.sheepSchema` declares `sheepRadiusAccount` and no group class
    /// at all — so slapd refused every group this app tried to create. `seedLDIF` has always
    /// written `groupOfNames` alone, which is the shape a device already sees.
    ///
    /// An empty `description` is **left out**, not written empty: LDIF has no empty value and
    /// slapd rejects the entry rather than ignoring the line.
    static func addGroupLDIF(name: String, description: String, groupsDN: String) -> String {
        var out = LDIFValue.row("dn", groupDN(name, groupsDN: groupsDN))
        out += "objectClass: groupOfNames\n"
        out += LDIFValue.row("cn", name)
        if !description.isEmpty { out += LDIFValue.row("description", description) }
        out += "\n"
        return out
    }

    /// `ldapmodify` payload for replacing one attribute.
    static func replaceLDIF(dn: String, attribute: String, value: String) -> String {
        LDIFValue.row("dn", dn)
            + "changetype: modify\nreplace: \(attribute)\n"
            + LDIFValue.row(attribute, value)
            + "\n"
    }

    /// Adding or removing one member of a group.
    static func memberLDIF(groupDN: String, userDN: String, add: Bool) -> String {
        LDIFValue.row("dn", groupDN)
            + "changetype: modify\n\(add ? "add" : "delete"): member\n"
            + LDIFValue.row("member", userDN)
            + "\n"
    }

    /// **Moving a user between OUs is a modrdn, not a delete and an add.**
    ///
    /// The difference is not style: a delete-and-add gives the account a new entryUUID, drops
    /// every group membership that referenced the old DN and, in this app, would have to
    /// re-hash a password it does not know. `ldapmodrdn -r <dn> <newrdn> -s <newsuperior>`
    /// keeps the object and lets slapd fix the references.
    static func moveArguments(dn: String, newRDN: String, newSuperior: String) -> [String] {
        ["-r", "-s", newSuperior, dn, newRDN]
    }

    static func deleteArguments(dn: String, recursive: Bool) -> [String] {
        recursive ? ["-r", dn] : [dn]
    }

    /// `ldappasswd -T <file> <dn>`: the new password comes from a 0600 file, slapd hashes it
    /// to `{SSHA}` itself. `sambaNTPassword` is a second call — slapd cannot compute an MD4.
    static func passwordArguments(dn: String, newPasswordFile: String) -> [String] {
        ["-T", newPasswordFile, dn]
    }
}

/// When an OpenLDAP change really does need the server restarted.
///
/// Three things and no more: what it listens on, its TLS material, and the base DN — all of
/// them read once at startup. Everything else about a directory is data, and data is edited
/// online. Pure, so the Apply button can say which one it is about to do.
nonisolated enum OpenLDAPRestart {
    static func reason(from old: LabSettings, to new: LabSettings) -> String? {
        if old.ldapSuffix != new.ldapSuffix { return "the base DN" }
        // `rootdn` and `rootpw` are read once, at startup, like the three below (build 24).
        if old.ldapAdminDN != new.ldapAdminDN { return "the admin account" }
        if old.ldapPort != new.ldapPort || old.ldapsPort != new.ldapsPort
            || old.ldapPlainEnabled != new.ldapPlainEnabled || old.ldapsEnabled != new.ldapsEnabled {
            return "what it listens on"
        }
        if old.needsTLS != new.needsTLS || old.serverCertName != new.serverCertName { return "its TLS certificate" }
        return nil
    }
}

// MARK: - RADIUS's side of the interface

/// What goes into radiusd's `authorize` when the authentication source is **Directory**.
///
/// The app can only write a cleartext password for a user whose password it set itself. For
/// everyone else — and that is every account changed in ADUC, on a joined PC, or by someone
/// else's `samba-tool` — the NT hash pulled from the domain is what there is, and FreeRADIUS
/// takes it as `NT-Password`.
///
/// **What works from an NT hash**: PAP (mschap computes it), MS-CHAPv1/v2, PEAP-MSCHAPv2,
/// EAP-TTLS with MSCHAPv2 or PAP inner. **What does not**: CHAP, which needs the cleartext
/// password itself — measured, not assumed, and the pane says so beside the setting rather
/// than letting someone find out from a switch that will not authenticate.
nonisolated enum RadiusAuthorize {
    static func cleartextLine(username: String, password: String) -> String {
        "\"\(ConfigGenerator.quoted(username))\"\tCleartext-Password := \"\(ConfigGenerator.quoted(password))\""
    }

    /// `"alice"  NT-Password := 0x89c1…` — the hash as FreeRADIUS wants it.
    ///
    /// The name goes through `quotedEntryName`, **not** `quoted` — see that function for what
    /// `radiusd -X` says about a backslash in an entry name. nil means the name cannot be
    /// written into a `users` file at all, and the caller writes a comment saying so.
    static func ntPasswordLine(username: String, hashHex: String) -> String? {
        guard let name = ConfigGenerator.quotedEntryName(username) else { return nil }
        return "\"\(name)\"\tNT-Password := 0x\(hashHex.uppercased())"
    }

    /// **May radiusd's user list be rewritten from this snapshot?**
    ///
    /// No, when the source is the directory, the backend is up, and the snapshot is empty —
    /// because those three together do not mean "the directory has no users", they mean "the
    /// directory did not answer". The live suite found the difference the hard way: a read
    /// that arrived a few hundred milliseconds before slapd had bound its port emptied the
    /// snapshot, the next Apply wrote a `users` file with nobody in it, and every login failed
    /// from then on with nothing on screen to say why.
    ///
    /// A backend that is genuinely **stopped** is a different case: from build 21 RADIUS is
    /// never started without it (`AppModel.startRadiusLocked` starts LDAP first), so the only
    /// way to be here with it down is that somebody stopped LDAP under a running radiusd — and
    /// then the file radiusd is already serving is the best thing there is.
    static func mayWrite(snapshot: DirectorySnapshot, backendIsLive: Bool) -> Bool {
        guard backendIsLive else { return true }
        return !snapshot.users.isEmpty
    }

    /// True when only the NT hash is known, so CHAP cannot work for this user.
    static let chapNeedsCleartext = "CHAP needs the cleartext password. A user whose password was changed outside this app is known only by its NT hash, so PAP, MS-CHAP and PEAP work for them and CHAP does not."
}

// MARK: - What the ApplyBar is allowed to notice

/// **RADIUS's side of the document, and nothing else** (build 21, PROJECT-STATUS §18 — "the
/// Revert/Apply bar must never appear from an edit in the DIRECTORY section").
///
/// `users`, `groups` and `ous` used to be compared too, from when they *were* the directory and
/// Apply copied them into it. Nothing writes them now — they are the read-only seed — so a
/// comparison could only ever raise the bar over something nobody did and nobody could revert.
/// What is left is exactly what Apply regenerates and restarts radiusd for.
///
/// Pure and out here so the rule can be checked without building an `AppModel`, which would
/// want a lab directory on disk.
///
/// **Build 22 splits the settings** (owner, build 21: switching the sidebar's OpenLDAP / Samba
/// AD choice raised the RADIUS bar every time). `doc.settings != applied.settings` compared the
/// *whole* struct, and most of it is the directory's: the backend, the listeners, the base DN,
/// the domain. radiusd is not generated from any of them — it has no `rlm_ldap`, its user list
/// comes from the directory's snapshot through the HUP path — so a directory-side edit raised a
/// bar that offered to restart RADIUS for a change RADIUS could not see.
nonisolated enum RadiusApplyGate {
    /// Exactly the settings `ConfigGenerator` writes radiusd's files from.
    ///
    /// `serverCertName` is in both halves on purpose: it names the leaf certificate `rlm_eap`
    /// loads **and** the one slapd serves on 636, so whichever server is running has a reason
    /// to be restarted for it.
    nonisolated struct RadiusSettings: Hashable, Sendable {
        var authPort: Int
        var acctPort: Int
        var defaultEAP: EAPType
        var tlsMaxVersion: String
        var serverCertName: String
    }

    static func radiusSide(of settings: LabSettings) -> RadiusSettings {
        RadiusSettings(authPort: settings.authPort, acctPort: settings.acctPort,
                       defaultEAP: settings.defaultEAP, tlsMaxVersion: settings.tlsMaxVersion,
                       serverCertName: settings.serverCertName)
    }

    static func differs(doc: LabDocument, from applied: LabDocument) -> Bool {
        doc.clients != applied.clients
            || radiusSide(of: doc.settings) != radiusSide(of: applied.settings)
            || doc.rules != applied.rules || doc.customUnlang != applied.customUnlang
    }

    /// Move **only this half** across, for an `applied` with no radiusd behind it. What it
    /// leaves alone is as much the point as what it copies: the directory's half of a document
    /// can be mid-edit under a running slapd while this one is adopted.
    static func adopt(from doc: LabDocument, into applied: inout LabDocument) {
        applied.clients = doc.clients
        applied.rules = doc.rules
        applied.customUnlang = doc.customUnlang
        applied.settings.authPort = doc.settings.authPort
        applied.settings.acctPort = doc.settings.acctPort
        applied.settings.defaultEAP = doc.settings.defaultEAP
        applied.settings.tlsMaxVersion = doc.settings.tlsMaxVersion
        applied.settings.serverCertName = doc.settings.serverCertName
    }
}

/// The other half: what **slapd or the domain controller** is generated from.
///
/// It exists so that taking the directory's settings out of `RadiusApplyGate` does not drop
/// them on the floor. `startLDAPLocked` reads `applied`, so a base DN or a port that never
/// reached `applied` would be a setting the person typed, saw no bar for, and that never took
/// effect. Nothing here is a *directory edit* — a user, a group, an OU — which is applied the
/// moment it is made and must never raise a bar (PROJECT-STATUS §18).
nonisolated enum DirectoryApplyGate {
    nonisolated struct DirectorySettings: Hashable, Sendable {
        var directoryBackend: DirectoryBackend
        var ldapEnabled: Bool
        var ldapPlainEnabled: Bool
        var ldapPort: Int
        var ldapsEnabled: Bool
        var ldapsPort: Int
        var ldapSuffix: String
        var ldapAdminPassword: String
        var ldapAdminDN: String
        var publishNTHashes: Bool
        var serverCertName: String
        var ad: ADSettings
    }

    static func directorySide(of settings: LabSettings) -> DirectorySettings {
        DirectorySettings(directoryBackend: settings.directoryBackend,
                          ldapEnabled: settings.ldapEnabled,
                          ldapPlainEnabled: settings.ldapPlainEnabled,
                          ldapPort: settings.ldapPort,
                          ldapsEnabled: settings.ldapsEnabled,
                          ldapsPort: settings.ldapsPort,
                          ldapSuffix: settings.ldapSuffix,
                          ldapAdminPassword: settings.ldapAdminPassword,
                          ldapAdminDN: settings.ldapAdminDN,
                          publishNTHashes: settings.publishNTHashes,
                          serverCertName: settings.serverCertName,
                          ad: settings.ad)
    }

    static func differs(doc: LabDocument, from applied: LabDocument) -> Bool {
        directorySide(of: doc.settings) != directorySide(of: applied.settings)
    }

    /// The directory's half, for an `applied` with no directory behind it — which is the only
    /// state the backend switch is reachable in at all.
    static func adopt(from doc: LabDocument, into applied: inout LabDocument) {
        applied.settings.directoryBackend = doc.settings.directoryBackend
        applied.settings.ldapEnabled = doc.settings.ldapEnabled
        applied.settings.ldapPlainEnabled = doc.settings.ldapPlainEnabled
        applied.settings.ldapPort = doc.settings.ldapPort
        applied.settings.ldapsEnabled = doc.settings.ldapsEnabled
        applied.settings.ldapsPort = doc.settings.ldapsPort
        applied.settings.ldapSuffixOverride = doc.settings.ldapSuffixOverride
        applied.settings.ldapAdminPassword = doc.settings.ldapAdminPassword
        applied.settings.ldapAdminDNOverride = doc.settings.ldapAdminDNOverride
        applied.settings.publishNTHashes = doc.settings.publishNTHashes
        applied.settings.serverCertName = doc.settings.serverCertName
        applied.settings.ad = doc.settings.ad
    }
}

/// **When the bar is shown at all** (build 22, owner's build-21 report).
///
/// The bar's sentence is "the servers still use the previous configuration", and with nothing
/// running that sentence is simply false: no server has read anything, the edit is saved and
/// whatever starts next is generated from it. So a running server is a precondition, and each
/// half of the document is gated on *its own* server — a RADIUS edit with only slapd up is not
/// something a person can apply to anything.
///
/// `AppModel` closes the other side of it: with everything stopped an edit is committed and
/// saved as it is made, so there is nothing left to apply and nothing to lose on quit.
nonisolated enum ApplyBarGate {
    static func raised(doc: LabDocument, applied: LabDocument,
                       radiusRunning: Bool, directoryRunning: Bool) -> Bool {
        (radiusRunning && RadiusApplyGate.differs(doc: doc, from: applied))
            || (directoryRunning && DirectoryApplyGate.differs(doc: doc, from: applied))
    }

    /// **The button's own label, with the domain controller counted** (build 25, QA H-3).
    ///
    /// Build 23 read `model.radius.isRunning || model.ldap.isRunning` inside `ApplyBar`, out of
    /// an `@ObservedObject` that was only `AppModel.shared` — which does not republish its
    /// children, the staleness `SidebarView` documents at length — and it left `ad.isRunning`
    /// out although `applyLocked`'s AD branch does stop and start radiusd. So an Apply on a
    /// lab whose domain controller was up said "Apply" and then restarted a server. The view
    /// observes the three processes directly now; the wording is here so the rule has a test.
    static func applyButtonTitle(radiusRunning: Bool, directoryRunning: Bool,
                                 adRunning: Bool) -> String {
        radiusRunning || directoryRunning || adRunning ? "Apply & Restart" : "Apply"
    }
}

// MARK: - The two switches are a pair

/// **There is no state where RADIUS is on and LDAP is off** (build 22, owner's decision).
///
/// Build 21 allowed it on purpose — a NAS pointed at a server that has vanished is worse than
/// one that answers — and Status carried a line saying every login was being rejected. The
/// owner's answer is that a RADIUS server rejecting everybody is not a state worth offering:
/// the pair either runs or it does not. So starting RADIUS starts LDAP first (that half is
/// build 21's and unchanged), and while radiusd is running the LDAP switch is simply
/// **disabled** — "Stop RADIUS first." — which is the owner's correction to an earlier
/// "stop both?" sheet: a question with only one sensible answer is a click, not a decision.
///
/// Pure, and every transition is a test — this is the kind of rule that grows an exception in
/// one pane and not another.
nonisolated enum ServerPair {
    enum Action: String, Sendable, Equatable {
        /// LDAP first, then radiusd — and if LDAP will not come up, radiusd does not either.
        case startBoth
        case startDirectory
        case stopRadius
        case stopDirectory
        case nothing
    }

    /// The RADIUS switch. On brings the pair up; off stops radiusd only — LDAP on its own is
    /// a perfectly good state (the Users pane needs nothing else).
    static func radiusSwitch(on: Bool, radiusRunning: Bool, directoryRunning: Bool) -> Action {
        if on { return radiusRunning ? .nothing : .startBoth }
        return radiusRunning ? .stopRadius : .nothing
    }

    /// The LDAP switch. Off while radiusd runs is **nothing at all** — the switch is
    /// disabled, and this is the belt to that braces: a stop that arrived anyway (a stale
    /// binding, a future caller) must still not take the directory out from under RADIUS.
    static func directorySwitch(on: Bool, radiusRunning: Bool, directoryRunning: Bool) -> Action {
        if on { return directoryRunning ? .nothing : .startDirectory }
        guard directoryRunning, !radiusRunning else { return .nothing }
        return .stopDirectory
    }

    /// Can the LDAP switch be flipped at all? Not while RADIUS is up.
    static func directorySwitchEnabled(radiusRunning: Bool) -> Bool { !radiusRunning }

    /// The one line under the row while it cannot be flipped.
    static func directorySwitchLockedHint(radiusRunning: Bool) -> String? {
        radiusRunning ? "Stop RADIUS first." : nil
    }

    /// **The RADIUS switch always pairs with OpenLDAP** (build 23, the owner's correction).
    ///
    /// Build 21 made the RADIUS switch start "the directory", meaning whichever backend
    /// `settings.directoryBackend` happened to name — so a lab left on Samba AD answered a
    /// flick of a switch labelled RADIUS by provisioning a domain controller: a container, a
    /// volume and the best part of a gigabyte of RAM. The owner's words: *"ที่เราคุยกันคือ
    /// Radius จะคู่กับ OpenLDAP เพื่อให้ไม่ใช้ RAM เยอะ"*.
    ///
    /// So the pair is RADIUS + **OpenLDAP**, by name, and the sidebar chooser moves with it —
    /// a chooser that says Samba AD over a running slapd is worse than no chooser. Two things
    /// this is deliberately not:
    ///
    /// - It never *replaces* a directory. A Samba AD that is already up is simply what RADIUS
    ///   reads from: nothing is stopped, nothing is restarted, the chooser stays where it is.
    ///   `directoryRunning` is the whole of that rule.
    /// - It is not **Start all**'s rule. That is the whole-lab button, and a lab whose chooser
    ///   says Samba AD means it. Overruling it would make the chooser a decoration, and the
    ///   first version of build 23 did overrule it: the `ad` suite's "provisions from an empty
    ///   volume" phase launches with `-autoStart 1`, got slapd where it had asked for a domain
    ///   controller, and printed no `[ad]` lines at all. Hence `StartOrigin`.
    ///   **Build 24 adds `.usersPane` to the pinning side** — see that case.
    ///
    /// `ldapEnabled` is switched **on** rather than refused. Build 21 answered "LDAP is
    /// switched off under Directory ▸ Server" and stopped, which made sense while Local users
    /// existed and makes none now: there is nowhere else a RADIUS server could get an account
    /// from, so that switch is a leftover to turn on, not a decision to respect.
    struct DirectoryPin: Sendable, Equatable {
        var backend: DirectoryBackend
        var ldapEnabled: Bool
    }

    /// Which control asked for a directory. Only the two light ones pin.
    enum StartOrigin: String, Sendable, Equatable {
        /// The sidebar's RADIUS switch: "I want RADIUS", and the directory is arranged for it.
        case radiusSwitch
        /// **Opening Users or Groups** (build 24, the owner's correction to build 23).
        ///
        /// Build 23 deliberately left this one unpinned — "choosing a backend and opening
        /// Users is how a person says they want that one". In use it is not: the chooser is a
        /// two-segment control in the sidebar that a lab can be left on for days, and clicking
        /// Users to look at a list of accounts then provisioned a domain controller. The
        /// owner's rule is now the same one as the RADIUS switch's, for the same reason —
        /// nothing that is merely *looking at* the lab may boot a DC. Samba AD is started by
        /// its own switch, by Start all and by `-autoStart 1`, and by nothing else.
        case usersPane
        /// Every other start: Start all, ⌘R, `-autoStart 1`, the restart at the end of an
        /// Apply, a certificate reissue, a change of log level. None of them is a person
        /// reaching for a switch — they mean "this lab", or "put back what was running" — so
        /// the backend the chooser names is what comes up, and an Apply on a stopped Samba AD
        /// cannot quietly move the lab to OpenLDAP. Build 22's behaviour.
        case lab
    }

    /// Which origins arrange the directory rather than take it as they find it.
    static func pins(_ origin: StartOrigin) -> Bool {
        origin == .radiusSwitch || origin == .usersPane
    }

    /// What the directory settings have to say before a light start brings one up. `nil` is
    /// "leave them alone": the start did not come from one of the two pinning controls, or a
    /// directory is already up, or they already say OpenLDAP and there is nothing to move.
    ///
    /// Named for what it does rather than for its first caller — build 23 had only the RADIUS
    /// switch and called this `directoryForRadius`.
    static func directoryPin(origin: StartOrigin, backend: DirectoryBackend,
                             ldapEnabled: Bool, directoryRunning: Bool) -> DirectoryPin? {
        guard pins(origin) else { return nil }
        guard !directoryRunning else { return nil }
        guard backend != .openLDAP || !ldapEnabled else { return nil }
        return DirectoryPin(backend: .openLDAP, ldapEnabled: true)
    }

    /// The backend chooser under the two rows. Locked while either directory runs — both want
    /// 389 and 636 — and locked while RADIUS runs, which from build 23 is the case that needs
    /// saying: the directory under a running radiusd cannot be stopped from here either, so
    /// the chooser and the LDAP switch grey out together and give the same reason.
    static func backendChooserEnabled(radiusRunning: Bool, directoryRunning: Bool) -> Bool {
        !radiusRunning && !directoryRunning
    }

    /// The one line under the chooser while it cannot be changed. RADIUS first, because
    /// stopping the directory is exactly what RADIUS is preventing.
    static func backendChooserLockedHint(radiusRunning: Bool, directoryRunning: Bool) -> String? {
        if radiusRunning { return "Stop RADIUS first." }
        return directoryRunning ? "Stop the running directory before switching." : nil
    }

    /// The switch's own position while the pair is moving: LDAP reads as **on** from the
    /// moment RADIUS asked for it, not from the moment slapd bound its port.
    static func directorySwitchIsOn(directoryRunning: Bool, directoryStarting: Bool) -> Bool {
        directoryRunning || directoryStarting
    }

    /// **Why RADIUS did not start, said as the thing that is actually true** (build 25, QA
    /// H-8).
    ///
    /// Directory ▸ Server's "Run the LDAP server" toggle had no lock on it — the sidebar's
    /// switch has had one since build 22 — so it could be turned off under a running radiusd
    /// and pressed **Apply & Restart**. `applyLocked` passes `origin: .lab`, which does not
    /// pin, `startDirectoryLocked` then has nothing to start, and the person was told
    /// *"RADIUS was not started because OpenLDAP (dc=…) could not start"* about a server that
    /// was never asked to. Reproduced live on port set A — `/tmp/sheepradius-qa/ldapoff.log`.
    ///
    /// The toggle is locked now, the same way and with the same sentence as the sidebar's. This
    /// is the other half: if the setting is off anyway — a hand-written `lab.json`, an import,
    /// a lab restored from a backup — the refusal names the setting rather than inventing a
    /// failure. `nil` means the directory is expected to come up and there is nothing to say
    /// in advance.
    static func radiusRefusalBeforeStart(backend: DirectoryBackend, ldapEnabled: Bool) -> String? {
        guard backend == .openLDAP, !ldapEnabled else { return nil }
        return "RADIUS was not started because the LDAP server is switched off under "
            + "Directory ▸ Server — radiusd reads its accounts from the directory and has "
            + "none without it."
    }

    /// The refusal for a directory that was asked to start and would not, which is a different
    /// sentence and always has been.
    static func radiusRefusalAfterStart(directoryLabel: String) -> String {
        "RADIUS was not started because \(directoryLabel) could not start — radiusd "
            + "reads its accounts from the directory and has none without it."
    }
}

// MARK: - Opening Users or Groups starts the directory

/// **A directory pane starts the directory by being opened** (build 22, owner's decision —
/// it replaces build 21's "LDAP is off." empty state with a Start button on it).
///
/// The reasoning is the owner's: Users and Groups have nothing to show without the directory,
/// and a pane whose only content is a button that says "press me to see this pane" is a step
/// nobody wants to take twice a day. So opening one starts LDAP — **through the same
/// `startDirectory()` the sidebar switch calls**, so the port preflight, the duplicate-DC
/// probe and every refusal still apply and none of them is bypassed by this shortcut.
///
/// What it must never do is the other half: **leaving the pane does not stop anything**. A
/// directory that went down because somebody clicked Status would take every device's
/// authentication with it. Only the switch, Stop all and quitting stop a server, which is why
/// `onLeavingPane` exists at all — a rule with no decision in it is still a rule, and this way
/// it has a test.
///
/// Pure so the four states can be pinned without a lab directory or a container.
nonisolated enum DirectoryPaneStart {
    enum Decision: String, Sendable, Equatable {
        case start
        case doNothing
    }

    /// - Parameters:
    ///   - isLive: the backend is up and answering.
    ///   - isStarting: a start from this pane is already in flight.
    ///   - hasFailed: the last start failed and the person has not pressed Retry. A failure
    ///     that re-tried itself on every redraw would be a loop with a spinner on it.
    ///   - isAvailable: the tools exist and the backend is switched on. Without that there is
    ///     nothing to start and the pane says which is missing.
    static func onOpeningPane(isLive: Bool, isStarting: Bool, hasFailed: Bool,
                              isAvailable: Bool) -> Decision {
        guard isAvailable, !isLive, !isStarting, !hasFailed else { return .doNothing }
        return .start
    }

    /// Retry clears the failure and is the **only** thing that does.
    static func onRetry(isLive: Bool, isStarting: Bool, isAvailable: Bool) -> Decision {
        guard isAvailable, !isLive, !isStarting else { return .doNothing }
        return .start
    }

    /// Leaving Users or Groups. Always nothing — see above.
    static func onLeavingPane() -> Decision { .doNothing }
}

// MARK: - Deleting a container without deleting the people in it

/// **What has to happen to the accounts before an OU can go** (build 21).
///
/// Deleting an OU used to do one of two wrong things, depending on the backend. In OpenLDAP
/// the accounts live *under* the container (`uid=alice,ou=IT,ou=Staff,…`), and `ldapdelete -r`
/// took them with it — an OU delete was an undo-less "delete these four people". In Active
/// Directory `samba-tool ou delete` refused a non-empty container outright, so the same menu
/// item did nothing at all and said so in a traceback. Neither is what "delete this OU" means
/// in ADUC, where the objects are the point and the container is filing.
///
/// So both backends now move every account out first, to the same place a user with no OU has
/// always gone — `people` — and only then remove the container. Pure, because the two backends
/// have to agree about *which* accounts and *where to*, and that agreement is worth a test that
/// needs no server.
///
/// A **group** needs none of this: `member` lives on the group entry in both backends and each
/// member's `memberOf` is derived from it, so deleting the group drops the membership with it.
/// The live and `ad` suites check exactly that, by re-reading the snapshot afterwards.
nonisolated enum DirectoryDeletion {
    /// Where the accounts in `path` go. `people` normally — and the top of the directory when
    /// `people` is itself the container being deleted, which is the one case where the usual
    /// answer would be "move them into the thing you are removing".
    static func refuge(fromOU path: String) -> String {
        OUPath.isSame(path, LabUser.defaultOU) ? "" : LabUser.defaultOU
    }

    /// Every account in `path` **or anything under it**, in snapshot order.
    ///
    /// Descendants count because removing `Staff` removes `Staff/IT` with it; an account left
    /// in `Staff/IT` would be deleted by the recursive removal or would block the non-recursive
    /// one, which is precisely the pair of bugs this closes. Read-only objects — AD's own
    /// `CN=Users` and friends — are never touched.
    static func usersToRelocate(in snapshot: DirectorySnapshot, deletingOU path: String) -> [String] {
        snapshot.users
            .filter { !$0.isReadOnly }
            .filter { OUPath.isSame($0.ou, path) || OUPath.isDescendant($0.ou, of: path) }
            .map(\.username)
    }
}

// MARK: - Moving off OU=SheepRadius, once

/// The one-time migration build 16 asks for: everything the app owns comes **up** from
/// `OU=SheepRadius` to the top level under the domain.
///
/// Why it is worth a migration rather than a new default for new domains only: the owner's
/// iMaster NCE-Campus can be pointed at one OU, and on 18 Sep it could not see `alice` and
/// `bob` (in `CN=Users`) at all, nor anything under an extra level it was not told about. The
/// app's OUs have to be where a NAC looks by default.
///
/// Previewed before anything runs — `lines` is what the sheet shows — and it refuses rather
/// than merges when a name is already taken at the top level.
nonisolated struct DirectoryMigration: Sendable, Equatable {
    struct Move: Sendable, Equatable {
        var from: String
        var to: String
        var kind: DirectoryNames.Kind
    }

    var moves: [Move] = []
    var conflicts: [String] = []
    var isEmpty: Bool { moves.isEmpty && conflicts.isEmpty }

    /// `lines` for the preview sheet, one per move.
    var lines: [String] { moves.map { "\($0.from)  →  \($0.to)" } }

    /// Plan the move-up out of a snapshot read with the **old** layout.
    ///
    /// `managedRootRDN` is `SheepRadius` unless somebody changed it. An OU whose name already
    /// exists at the top level is a conflict, not a merge: two OUs called `Staff` with
    /// different users in them is exactly the mess a lab tool must not create silently.
    static func moveUp(snapshot: DirectorySnapshot, managedRootRDN: String) -> DirectoryMigration {
        var plan = DirectoryMigration()
        let root = managedRootRDN
        let inRoot = { (path: String) in
            let segments = OUPath.segments(path)
            return segments.first?.caseInsensitiveCompare(root) == .orderedSame && segments.count >= 1
        }
        let topLevel = Set(snapshot.ous.filter { !inRoot($0.path) }
            .compactMap { OUPath.segments($0.path).first?.lowercased() })

        for ou in snapshot.ous where inRoot(ou.path) {
            let segments = Array(OUPath.segments(ou.path).dropFirst())
            guard !segments.isEmpty else { continue }   // OU=SheepRadius itself just goes away
            let target = segments.joined(separator: "/")
            if segments.count == 1, topLevel.contains(segments[0].lowercased()) {
                plan.conflicts.append("An OU called “\(segments[0])” already exists at the top level.")
                continue
            }
            plan.moves.append(Move(from: ou.path, to: target, kind: .ou))
        }
        for user in snapshot.users where inRoot(user.ou) {
            let segments = Array(OUPath.segments(user.ou).dropFirst())
            plan.moves.append(Move(from: user.ou.isEmpty ? user.username : "\(user.ou)/\(user.username)",
                                   to: segments.isEmpty ? user.username : segments.joined(separator: "/") + "/" + user.username,
                                   kind: .user))
        }
        for group in snapshot.groups where !group.isReadOnly
            && group.dn.lowercased().contains("ou=\(root.lowercased()),") {
            plan.moves.append(Move(from: group.name, to: group.name, kind: .group))
        }
        return plan
    }
}

/// What importing an old `lab.json` into the live backend would do, before it does it.
///
/// `lab.json` still carries the `users`, `groups` and `ous` it was seeded from (build 21 keeps
/// them read-only, for the first OpenLDAP seed and for reversibility). This is what putting
/// them into a live backend would do — **once**, with a report first, and only while LDAP is
/// running. It is the `radctl`-shaped import the owner asked for in §18: straight through the
/// provider, never into a table of the app's own.
nonisolated struct DirectoryImport: Sendable, Equatable {
    var createUsers: [String] = []
    var createGroups: [String] = []
    var createOUs: [String] = []
    /// Already in the directory under that name; left exactly as they are.
    var skipped: [String] = []
    /// Refused outright, with the reason — a built-in name, mostly.
    var refused: [String] = []

    var isEmpty: Bool {
        createUsers.isEmpty && createGroups.isEmpty && createOUs.isEmpty && skipped.isEmpty && refused.isEmpty
    }

    var summary: String {
        var parts: [String] = []
        if !createUsers.isEmpty { parts.append("\(createUsers.count) user(s)") }
        if !createGroups.isEmpty { parts.append("\(createGroups.count) group(s)") }
        if !createOUs.isEmpty { parts.append("\(createOUs.count) OU(s)") }
        if parts.isEmpty { return "Nothing to import." }
        var text = "Create " + parts.joined(separator: ", ") + "."
        if !skipped.isEmpty { text += " \(skipped.count) already there." }
        if !refused.isEmpty { text += " \(refused.count) refused." }
        return text
    }

    static func plan(document: LabDocument, into snapshot: DirectorySnapshot,
                     backend: DirectoryBackend = .activeDirectory) -> DirectoryImport {
        var report = DirectoryImport()
        let haveUsers = Set(snapshot.users.map { $0.username.lowercased() })
        let haveGroups = Set(snapshot.groups.map { $0.name.lowercased() })
        let haveOUs = Set(snapshot.ous.map { $0.path.lowercased() })

        // Every ancestor too, and the OUs the users carry: `Staff/IT` cannot be created in a
        // directory that has no `Staff`, and a document may name an OU on a user without
        // listing it. Sorted by depth so the parent is always planned before the child.
        var wanted: [String] = []
        var seen = Set<String>()
        for path in (document.ous + document.users.map(\.effectiveOU)) where !path.isEmpty {
            for step in OUPath.selfAndAncestors(of: path) where seen.insert(step.lowercased()).inserted {
                wanted.append(step)
            }
        }
        for ou in wanted.sorted(by: { OUPath.segments($0).count == OUPath.segments($1).count
                                      ? $0 < $1 : OUPath.segments($0).count < OUPath.segments($1).count }) {
            if haveOUs.contains(ou.lowercased()) { report.skipped.append("OU \(ou)") }
            else { report.createOUs.append(ou) }
        }
        for group in document.groups where !group.name.isEmpty {
            if let problem = DirectoryNames.problem(with: group.name, kind: .group, backend: backend) {
                report.refused.append("group \(group.name) — \(problem)")
            } else if haveGroups.contains(group.name.lowercased()) {
                report.skipped.append("group \(group.name)")
            } else {
                report.createGroups.append(group.name)
            }
        }
        for user in document.users where !user.username.isEmpty {
            if let problem = DirectoryNames.problem(with: user.username, kind: .user, backend: backend) {
                report.refused.append("user \(user.username) — \(problem)")
            } else if haveUsers.contains(user.username.lowercased()) {
                report.skipped.append("user \(user.username)")
            } else {
                report.createUsers.append(user.username)
            }
        }
        return report
    }
}

// MARK: - Running the import twice must do nothing the second time (build 26, decision D)

/// **"Imported with 1 problem(s): move OU SheepRadius/Staff already exists"** (build 26, the
/// owner's own screenshot).
///
/// Two halves of one import fighting each other. `DirectoryImport.plan` lists the OUs in
/// `lab.json` that the directory does not have — including `Staff` — and creates them;
/// `DirectoryMigration.moveUp` separately lifts `SheepRadius/Staff` **to** `Staff`. The plan
/// is taken before either runs, so `moveUp` sees no top-level `Staff`, files no conflict, and
/// the lift then lands on the container the create made forty milliseconds earlier. The person
/// is shown a failure for an import that did exactly what it was supposed to.
///
/// Three rules, all of them here so they can be tested without a directory:
///
/// 1. **The lift wins over the create.** An OU the migration is going to bring up must not also
///    be created from the seed — the lift carries the accounts with it and the create does not.
/// 2. **A step whose result is already true is not a problem.** `DirectoryError.nameTaken` from
///    a create or a move means the directory already has what was asked for, which is success
///    for an operation that is supposed to be idempotent. It is counted and said in the summary;
///    it is never a failure.
/// 3. **Nothing failed, nothing to warn about.** Build 25 wrote a `failure:` line whenever the
///    list was non-empty, and the list counted rule 2's non-problems.
///
/// Rerunnable by construction, which matters because "Not now" means it is offered again at the
/// next launch, and because a lab restored from a `.sheeplab` has been through it before.
nonisolated enum DirectoryImportRun {
    /// The plan actually run, once the two halves have been reconciled (rule 1).
    nonisolated struct Plan: Sendable, Equatable {
        var report: DirectoryImport
        var migration: DirectoryMigration
        /// OUs dropped from `createOUs` because the lift is bringing the real one up.
        var deferredToLift: [String] = []
    }

    static func reconcile(report: DirectoryImport, migration: DirectoryMigration) -> Plan {
        let lifted = Set(migration.moves.filter { $0.kind == .ou }.map { $0.to.lowercased() })
        guard !lifted.isEmpty else { return Plan(report: report, migration: migration) }
        var reconciled = report
        let deferred = report.createOUs.filter { lifted.contains(OUPath.normalized($0).lowercased()) }
        reconciled.createOUs = report.createOUs.filter {
            !lifted.contains(OUPath.normalized($0).lowercased())
        }
        return Plan(report: reconciled, migration: migration, deferredToLift: deferred)
    }

    /// Whether a failure means "the directory already had it", which is this import's success.
    ///
    /// Typed rather than a substring match on the tool's wording: both executors map
    /// `Already exists (68)` and samba-tool's equivalent onto `.nameTaken` through
    /// `DirectoryErrorMap`, so this asks the enum and cannot drift with an OpenLDAP release.
    static func isAlreadyThere(_ error: any Error) -> Bool {
        guard let directory = error as? DirectoryError else { return false }
        if case .nameTaken = directory { return true }
        return false
    }

    /// What the strip says when it is over. `nil` for the failure line when nothing failed —
    /// rule 3, and the whole of the owner's complaint.
    nonisolated struct Outcome: Sendable, Equatable {
        var created = 0
        var alreadyThere = 0
        var lifted = 0
        var failures: [String] = []

        /// The confirmation. Always said, because an import that ran and changed nothing is a
        /// fact worth one line.
        var summary: String {
            var parts: [String] = []
            if created > 0 { parts.append("\(created) created") }
            if lifted > 0 { parts.append("\(lifted) moved up") }
            if alreadyThere > 0 { parts.append("\(alreadyThere) already there") }
            return parts.isEmpty ? "Nothing to import." : parts.joined(separator: " · ")
        }

        /// The failure line, or nil. Only *real* problems reach it.
        var failure: String? {
            guard !failures.isEmpty else { return nil }
            let head = failures.prefix(3).joined(separator: " · ")
            return failures.count > 3
                ? "\(failures.count) problem(s): \(head) …"
                : "\(failures.count) problem(s): \(head)"
        }
    }
}

// MARK: - Nothing is answering

/// **What the app talks to when LDAP is off** (build 21, PROJECT-STATUS §18).
///
/// Until build 20 this was `LocalDirectory`, a full provider over the small user table in
/// `lab.json`: with no directory running the Users pane quietly showed that table instead, with
/// a banner explaining which of the two sets of users was on screen. The owner's verdict was
/// that two sets of users is one too many, so there is no table to fall back to and no pane
/// that shows one. What is left is the honest answer: the directory is not running, every call
/// says so in the same sentence, and the panes draw an empty state with a Start button.
///
/// It is a provider rather than an optional so that `makeDirectoryProvider()` has no nil case
/// and every caller keeps exactly one code path.
nonisolated struct OfflineDirectory: DirectoryProvider {
    /// Named for the switch that turns it on, because that is the thing to do about it.
    static let message = "LDAP is off."

    var label: String { Self.message }
    var isAvailable: Bool { false }

    private var stopped: DirectoryError { .notRunning(Self.message) }

    func snapshot() async throws -> DirectorySnapshot { throw stopped }
    func createUser(_ username: String, displayName: String, ou: String, password: String) async throws { throw stopped }
    func setPassword(_ username: String, to password: String) async throws { throw stopped }
    func setDisplayName(_ username: String, to displayName: String) async throws { throw stopped }
    func setEnabled(_ username: String, to enabled: Bool) async throws { throw stopped }
    func moveUser(_ username: String, toOU ou: String) async throws { throw stopped }
    func renameUser(_ username: String, to newName: String) async throws { throw stopped }
    func deleteUser(_ username: String) async throws { throw stopped }
    func createGroup(_ name: String, description: String) async throws { throw stopped }
    func deleteGroup(_ name: String) async throws { throw stopped }
    func setMembership(of username: String, groups: [String]) async throws { throw stopped }
    func createOU(_ path: String) async throws { throw stopped }
    func renameOU(_ path: String, to newLeaf: String) async throws { throw stopped }
    func moveOU(_ path: String, under parent: String) async throws { throw stopped }
    func deleteOU(_ path: String) async throws { throw stopped }
    func ntHash(of username: String) async throws -> String? { throw stopped }
}

// MARK: - What the tree's selection may be used for

/// **A read-only OU is somewhere to look, never somewhere to create** (build 25, QA H-5).
///
/// The tree's tap handler had no `isReadOnly` guard — the *drop* target has had one since build
/// 22 — while `New OU` and `New user` passed `selectedOU` straight through and the sheets' own
/// pickers filter read-only OUs out. So clicking `OU=Domain Controllers` on a real domain and
/// pressing **New user** gave a sheet whose OU picker showed nothing at all while the state
/// still held the path, and **Create** then made the account wherever the backend felt like it.
///
/// Browsing one is a perfectly ordinary thing to want — `CN=Users` is where a real domain keeps
/// every account — so the selection stays. What goes is the pretence that it is a target: the
/// two New buttons are disabled while one is selected, the tree says why in its own column, and
/// `target` is the single answer both the buttons and the sheets ask for.
nonisolated enum OUCreationTarget {
    /// The OU a New user / New OU sheet should open on. `nil` means "there is no target" — the
    /// selection is one of the directory's own containers and nothing may be created in it.
    /// A `nil` selection is the "All users" row, which means the top level.
    static func target(selected: String?, isReadOnly: Bool) -> String? {
        guard let selected, !OUPath.normalized(selected).isEmpty else { return "" }
        return isReadOnly ? nil : OUPath.normalized(selected)
    }

    /// The line the tree shows under a read-only selection, in the pane's own words.
    static func refusal(path: String) -> String {
        "\(OUPath.leaf(path)) belongs to the directory itself — new objects cannot be created "
            + "in it. Pick another OU, or All users for the top level."
    }
}

// MARK: - Moving accounts about

/// **What a move and a delete do to the OU they empty** (build 25, QA M-1, M-2 and M-12).
///
/// Three findings with one shape: the tree accumulates containers nobody can see a use for,
/// and the one action that moves *other people's* objects does it without asking.
///
/// - `moveUser` creates its destination implicitly and prunes nothing, so an OU emptied by a
///   move stays in the tree forever (M-2). Pruning it silently is wrong — an OU made on purpose
///   and emptied for an afternoon is not litter — so the banner offers it, once, beside the
///   Undo the move already has.
/// - Deleting an OU relocates every account inside it to the top level and had neither a
///   confirmation nor an undo (M-12). It is the only directory action in the app that changes
///   objects the person did not select.
nonisolated enum OUHousekeeping {
    /// The OUs a user may be moved into: writable, and not the one they are already in. The
    /// Users pane's row menu and the OU menu share it (M-1).
    static func destinations(for ous: [DirectoryOU], excluding current: String) -> [String] {
        ous.filter { !$0.isReadOnly && !OUPath.isSame($0.path, current) }.map(\.path)
    }

    /// True when `path` has just been emptied by moving `moved` accounts out of it, and is a
    /// container the person could delete. Read-only containers and the top level are neither.
    static func isNowEmpty(path: String, remaining: Int, isReadOnly: Bool) -> Bool {
        guard !isReadOnly, !OUPath.normalized(path).isEmpty else { return false }
        return remaining == 0
    }

    static func emptyOffer(path: String) -> String {
        "\(OUPath.leaf(path)) is empty now."
    }

    /// **What deleting this OU will do**, counted, for the confirmation (M-12). The accounts
    /// do not go — they are moved to the top level, which is what the backend's own executor
    /// does — and saying the number is the whole point of asking.
    static func deleteWarning(path: String, accounts: Int, descendants: Int) -> String {
        var out = "\(OUPath.leaf(path)) will be deleted."
        if accounts > 0 {
            out += " \(accounts) account\(accounts == 1 ? "" : "s") in it "
                + "\(accounts == 1 ? "moves" : "move") to the top level."
        }
        if descendants > 0 {
            out += " \(descendants) OU\(descendants == 1 ? "" : "s") inside it "
                + "\(descendants == 1 ? "goes" : "go") with it."
        }
        if accounts == 0, descendants == 0 { out += " It is empty." }
        return out
    }
}
