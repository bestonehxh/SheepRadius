import Foundation

/// A `/`-separated OU path like `Staff/IT`, the way Active Directory users think of it.
///
/// Comparison is case-insensitive throughout — LDAP treats `ou=IT` and `ou=it` as the same
/// container, so the app must not let two paths exist that differ only in case.
nonisolated enum OUPath {
    /// The deepest path the app will accept. Nothing technical forces this; it keeps the
    /// Users pane's indented tree readable and a runaway path out of a DN.
    static let maxDepth = 5

    static func segments(_ path: String) -> [String] {
        path.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// " Staff / IT / " → "Staff/IT". Empty when there is nothing left.
    static func normalized(_ path: String) -> String { segments(path).joined(separator: "/") }

    static func depth(_ path: String) -> Int { segments(path).count }

    static func leaf(_ path: String) -> String { segments(path).last ?? path }

    /// "Staff/IT" → "Staff"; a top-level path has none.
    static func parent(_ path: String) -> String? {
        let parts = segments(path)
        return parts.count > 1 ? parts.dropLast().joined(separator: "/") : nil
    }

    /// "Staff/IT" → ["Staff", "Staff/IT"] — every container that has to exist for this one to.
    static func selfAndAncestors(of path: String) -> [String] {
        var out: [String] = []
        var accumulated: [String] = []
        for segment in segments(path) {
            accumulated.append(segment)
            out.append(accumulated.joined(separator: "/"))
        }
        return out
    }

    static func isSame(_ a: String, _ b: String) -> Bool {
        normalized(a).caseInsensitiveCompare(normalized(b)) == .orderedSame
    }

    /// True for "Staff/IT" under "Staff", false for "Stafford" under "Staff".
    static func isDescendant(_ path: String, of ancestor: String) -> Bool {
        let parent = normalized(ancestor), child = normalized(path)
        guard !parent.isEmpty, child.count > parent.count else { return false }
        return child.lowercased().hasPrefix(parent.lowercased() + "/")
    }

    /// Renaming `Staff` to `Employees` has to carry `Staff/IT` with it — and must not touch
    /// `Stafford`, which is why this compares whole segments rather than raw prefixes.
    static func rewritingPrefix(_ path: String, from old: String, to new: String) -> String {
        if isSame(path, old) { return normalized(new) }
        guard isDescendant(path, of: old) else { return normalized(path) }
        let remainder = normalized(path).dropFirst(normalized(old).count + 1)
        return normalized(new) + "/" + remainder
    }

    /// Parents before children, then alphabetically — the order the LDIF needs and the order
    /// the Users pane draws its tree in.
    static func orderedBefore(_ a: String, _ b: String) -> Bool {
        let left = segments(a), right = segments(b)
        for (l, r) in zip(left, right) {
            let comparison = l.localizedStandardCompare(r)
            if comparison != .orderedSame { return comparison == .orderedAscending }
        }
        return left.count < right.count
    }
}

nonisolated struct LabUser: Codable, Identifiable, Hashable, Sendable {
    /// Where a user sits when no OU path is given. One flat `ou=people`, as before groups existed.
    static let defaultOU = "people"

    var id = UUID()
    var username = ""
    /// Optional friendly name → LDAP `displayName`. Falls back to the username.
    var displayName = ""
    var password = ""
    /// AD-style OU path, `/`-separated from the top down: "Staff/IT" →
    /// `uid=<user>,ou=IT,ou=Staff,<base>`.
    var ou = LabUser.defaultOU
    /// LabGroup ids this user belongs to.
    var groups: [UUID] = []
    var enabled = true

    /// "Staff/IT" → ["Staff", "IT"] (top down), empty segments and stray spaces dropped.
    var ouSegments: [String] { OUPath.segments(ou) }

    /// Where this user actually lives: the typed path, or the default OU when it is blank.
    var effectiveOU: String {
        let path = OUPath.normalized(ou)
        return path.isEmpty ? LabUser.defaultOU : path
    }

    /// The container DN, leaf first: ["Staff", "IT"] → `ou=IT,ou=Staff,<base>`.
    func containerDN(base: String) -> String {
        (OUPath.segments(effectiveOU).reversed().map { "ou=\($0)" } + [base]).joined(separator: ",")
    }

    func dn(base: String) -> String { "uid=\(username),\(containerDN(base: base))" }

    // `ou` / `groups` / `displayName` post-date the first lab.json, so every key is optional on
    // the way in. A pre-Groups file's single `group` string is migrated by LabDocument.
    //
    // **`vlan` and `replyAttributes` are deliberately absent** (build 13): a user's reply is a
    // rule now. A build-12 file still has both keys, and `LabDocument.init(from:)` reads them
    // one last time through `PolicyMigration.Legacy` before turning them into rules. They are
    // never written again.
    enum CodingKeys: String, CodingKey {
        case id, username, displayName, password, ou, groups, enabled
    }

    init(id: UUID = UUID(), username: String = "", displayName: String = "", password: String = "",
         ou: String = LabUser.defaultOU, groups: [UUID] = [], enabled: Bool = true) {
        self.id = id
        self.username = username
        self.displayName = displayName
        self.password = password
        self.ou = ou
        self.groups = groups
        self.enabled = enabled
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        username = try c.decodeIfPresent(String.self, forKey: .username) ?? ""
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName) ?? ""
        password = try c.decodeIfPresent(String.self, forKey: .password) ?? ""
        // **An `ou` that is present but empty is `people`, not a validation failure** (build
        // 21). The owner hit this on 2026-09-19: build 17's OU delete wrote `"ou": ""` onto
        // every user that had been in the deleted container, and the file then reopened with
        // "The OU for \"alice\" is empty" across the ApplyBar, with no pane offering a way to
        // fix it. Blank and absent now mean the same thing, which is what `effectiveOU` has
        // always said they mean.
        let storedOU = try c.decodeIfPresent(String.self, forKey: .ou) ?? LabUser.defaultOU
        ou = OUPath.normalized(storedOU).isEmpty ? LabUser.defaultOU : storedOU
        groups = try c.decodeIfPresent([UUID].self, forKey: .groups) ?? []
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }
}

/// A first-class group: an LDAP `groupOfNames`, and a name a policy rule can point at.
///
/// It carries **nothing about the RADIUS reply** (build 13). "Members of NetAdmins get VLAN 10"
/// is a rule in the Policy pane, in one ordered list with everything else that decides a reply.
nonisolated struct LabGroup: Codable, Identifiable, Hashable, Sendable {
    /// The implicit group every enabled user belongs to. Not stored — generated.
    static let everyoneName = "netusers"

    var id = UUID()
    var name = ""
    var description = ""

    // `vlan` / `replyAttributes` are gone; see LabUser's note. A build-12 file's copies are
    // read once by LabDocument's migration and never written again.
    enum CodingKeys: String, CodingKey { case id, name, description }

    init(id: UUID = UUID(), name: String = "", description: String = "") {
        self.id = id
        self.name = name
        self.description = description
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
    }
}

nonisolated struct NASClient: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var name = ""
    /// Single IP or CIDR, e.g. 192.168.1.2 or 10.0.0.0/24
    var address = ""
    var secret = ""
    /// **Reject an Access-Request that carries no Message-Authenticator** — the BlastRADIUS
    /// (CVE-2024-3596) mitigation, per client (build 20, audit N-6).
    ///
    /// Off by default and off for the global setting, which stays at 3.2.10's `auto`. It has
    /// to be per client because real switches in this owner's lab do not send one on a PAP
    /// Access-Request, and turning it on globally would lock them out of the lab they are
    /// being tested against. EAP always carries one, so a Wi-Fi client is unaffected either
    /// way.
    var requireMessageAuthenticator = false

    init(id: UUID = UUID(), name: String = "", address: String = "", secret: String = "",
         requireMessageAuthenticator: Bool = false) {
        self.id = id
        self.name = name
        self.address = address
        self.secret = secret
        self.requireMessageAuthenticator = requireMessageAuthenticator
    }

    /// **Written by hand, like `LabUser`'s and `LabGroup`'s, and for the same reason.**
    ///
    /// Swift's synthesized decoder does **not** fall back to a property's default value for a
    /// key that is absent — it throws `keyNotFound`. So the moment build 20 added the field
    /// above, every `lab.json` written by build 19 would have failed to decode, `loadDocument`
    /// would have returned `.sample`, and the owner's lab would have appeared to be gone.
    /// Verified by decoding a build-19 client, which is the test beside this.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        address = try c.decodeIfPresent(String.self, forKey: .address) ?? ""
        secret = try c.decodeIfPresent(String.self, forKey: .secret) ?? ""
        requireMessageAuthenticator =
            try c.decodeIfPresent(Bool.self, forKey: .requireMessageAuthenticator) ?? false
    }
}

nonisolated enum EAPType: String, Codable, CaseIterable, Sendable {
    case peap, ttls, tls
    var label: String {
        switch self {
        case .peap: "PEAP"
        case .ttls: "EAP-TTLS"
        case .tls: "EAP-TLS"
        }
    }
}

/// **There is one set of users, and the LDAP directory owns it** (build 21, PROJECT-STATUS §18).
///
/// Builds 17 to 20 had a second one: `AuthenticationSource` chose between the directory and a
/// small `radctl`-shaped table in `lab.json`, and the panes fell back to that table whenever no
/// directory was running. The owner's verdict on 2026-09-19 was to cut it — "ตัดออกเลย จะได้ไม่
/// สับสน" — so the enum and the setting are gone. A `lab.json` still carrying `authSource`
/// decodes fine: the key is simply not in `CodingKeys` any more and `Decodable` ignores it.
nonisolated struct LabSettings: Codable, Hashable, Sendable {
    var authPort = 1812
    var acctPort = 1813
    var defaultEAP = EAPType.peap
    var tlsMaxVersion = "1.2"
    var serverCertName = "radius.lab.local"

    var ldapEnabled = true
    var ldapPort = 389
    /// **A base DN somebody pinned**, empty for the normal case — see `ldapSuffix`.
    var ldapSuffixOverride = ""
    /// **The directory's own administrator, named the way Active Directory names it**
    /// (build 24, the owner: "cn=admin,dc=lab,dc=local … มันควรเป็น administrator p@ssw0rd นะ").
    ///
    /// The password of the account `ldapAdminDN` names. It is slapd's `rootpw`, so it bypasses
    /// every ACL — which is how a NAC bound as this DN reads `sambaNTPassword`.
    var ldapAdminPassword = LabSettings.defaultAdminPassword
    /// **A bind DN somebody pinned**, empty for the normal case.
    ///
    /// Empty means `defaultAdminDN(suffix:)`, which **follows the base DN**: changing
    /// `dc=lab,dc=local` to `dc=corp,dc=example` moves the administrator with it, and every
    /// device table, the seed LDIF and `rootdn` agree without anybody retyping anything. It is
    /// non-empty only on a lab `adminIdentityMigration` left where it was — see that function
    /// for the one case that happens in.
    var ldapAdminDNOverride = ""
    /// Which directory runs. The two backends are mutually exclusive — both want 389/636.
    var directoryBackend = DirectoryBackend.openLDAP
    var ad = ADSettings()
    /// Publish `sambaNTPassword` (the NT hash) on every user, so a NAC can run
    /// PEAP-MSCHAPv2 from a generic-LDAP source without joining a domain.
    var publishNTHashes = true
    /// The two listeners are independent: plain only, LDAPS only, or both.
    var ldapPlainEnabled = true
    /// The `ldaps://` listener — and, because slapd's TLS context is global, the thing that
    /// makes StartTLS available on the plain listener too. See `offersStartTLS`.
    var ldapsEnabled = true
    var ldapsPort = 636

    /// `-xx` rather than `-x` on radiusd. **Off by default, because it is not free**: measured
    /// on 3.2.10 in build 12, one PAP request is 410 lines of `-xx` against 75 of `-x`, and the
    /// server does 2649 requests/s instead of 4978 — `-xx` costs 47% of the throughput. `-x`
    /// still prints everything the app reads out of the stream (`Login OK:`, `Login incorrect`,
    /// and the `Sheep-Rule +=` tags that drive "rules fired"); `-xx` adds the per-condition
    /// `-> TRUE` trace and the TLS session details. See `LogView`'s toggle.
    var radiusDebug = false

    /// **Which spellings of a login RADIUS accepts** (2.0 (3), owner: a device set to UPN still
    /// let a bare username in, where Windows would not). One `authorize` entry per enabled form,
    /// each carrying the same password and the same identity items. All three on by default —
    /// what Windows NPS accepts; turning **Username** off makes the lab UPN-only.
    var radiusLoginNames = RadiusLoginNames()

    // `publishNTHashes` post-dates the first lab.json, so decode every key optionally.
    enum CodingKeys: String, CodingKey {
        case authPort, acctPort, defaultEAP, tlsMaxVersion, serverCertName
        case ldapEnabled, ldapPort, ldapSuffix, ldapAdminPassword, publishNTHashes
        case ldapsEnabled, ldapsPort, ldapPlainEnabled, directoryBackend, ad, radiusDebug
        case radiusLoginNames
        case ldapAdminDNOverride, ldapSuffixFollowsLabDomain
    }

    init() {}

    /// **Written by hand for one key** (build 24).
    ///
    /// `ldapSuffix` is derived from the lab domain now, so the app's own state is "does it
    /// follow, or is it pinned?" — but `ldapSuffix` is also the key every earlier build reads,
    /// and writing an empty string there would give a rolled-back build 23 a lab with no base
    /// DN and an ApplyBar full of validation failures. So the **effective** base DN goes out
    /// under the old key, exactly as before, and a separate boolean carries the one bit this
    /// build adds. A build ≤23 ignores the boolean and reads a base DN that is correct.
    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(authPort, forKey: .authPort)
        try c.encode(acctPort, forKey: .acctPort)
        try c.encode(defaultEAP, forKey: .defaultEAP)
        try c.encode(tlsMaxVersion, forKey: .tlsMaxVersion)
        try c.encode(serverCertName, forKey: .serverCertName)
        try c.encode(ldapEnabled, forKey: .ldapEnabled)
        try c.encode(ldapPort, forKey: .ldapPort)
        try c.encode(ldapSuffix, forKey: .ldapSuffix)
        try c.encode(ldapSuffixFollowsLabDomain, forKey: .ldapSuffixFollowsLabDomain)
        try c.encode(ldapAdminPassword, forKey: .ldapAdminPassword)
        try c.encode(ldapAdminDNOverride, forKey: .ldapAdminDNOverride)
        try c.encode(publishNTHashes, forKey: .publishNTHashes)
        try c.encode(ldapPlainEnabled, forKey: .ldapPlainEnabled)
        try c.encode(ldapsEnabled, forKey: .ldapsEnabled)
        try c.encode(ldapsPort, forKey: .ldapsPort)
        try c.encode(directoryBackend, forKey: .directoryBackend)
        try c.encode(ad, forKey: .ad)
        try c.encode(radiusDebug, forKey: .radiusDebug)
        try c.encode(radiusLoginNames, forKey: .radiusLoginNames)
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = LabSettings()
        authPort = try c.decodeIfPresent(Int.self, forKey: .authPort) ?? d.authPort
        acctPort = try c.decodeIfPresent(Int.self, forKey: .acctPort) ?? d.acctPort
        defaultEAP = try c.decodeIfPresent(EAPType.self, forKey: .defaultEAP) ?? d.defaultEAP
        tlsMaxVersion = try c.decodeIfPresent(String.self, forKey: .tlsMaxVersion) ?? d.tlsMaxVersion
        serverCertName = try c.decodeIfPresent(String.self, forKey: .serverCertName) ?? d.serverCertName
        ldapEnabled = try c.decodeIfPresent(Bool.self, forKey: .ldapEnabled) ?? d.ldapEnabled
        ldapPort = try c.decodeIfPresent(Int.self, forKey: .ldapPort) ?? d.ldapPort
        // **The base DN, pinned or following** (build 24). A file this build wrote says which
        // it is; a file from build ≤23 always carries a literal base DN and no flag, so it
        // arrives pinned and `labDomainMigration` decides whether it stays that way.
        let storedSuffix = try c.decodeIfPresent(String.self, forKey: .ldapSuffix) ?? ""
        let follows = try c.decodeIfPresent(Bool.self, forKey: .ldapSuffixFollowsLabDomain) ?? false
        ldapSuffixOverride = follows ? "" : storedSuffix
        ldapAdminPassword = try c.decodeIfPresent(String.self, forKey: .ldapAdminPassword) ?? d.ldapAdminPassword
        // A lab.json from before build 24 has no override, which is the normal state — the
        // admin DN was computed from the base DN then and is computed from it now.
        // `adminIdentityMigration` is what decides whether such a lab keeps the old spelling.
        ldapAdminDNOverride = try c.decodeIfPresent(String.self, forKey: .ldapAdminDNOverride) ?? d.ldapAdminDNOverride
        publishNTHashes = try c.decodeIfPresent(Bool.self, forKey: .publishNTHashes) ?? d.publishNTHashes
        // A lab.json from before the listeners split has no ldapPlainEnabled: plain was
        // always on then, so the default (true) is exactly the old behaviour.
        ldapPlainEnabled = try c.decodeIfPresent(Bool.self, forKey: .ldapPlainEnabled) ?? d.ldapPlainEnabled
        ldapsEnabled = try c.decodeIfPresent(Bool.self, forKey: .ldapsEnabled) ?? d.ldapsEnabled
        ldapsPort = try c.decodeIfPresent(Int.self, forKey: .ldapsPort) ?? d.ldapsPort
        directoryBackend = try c.decodeIfPresent(DirectoryBackend.self, forKey: .directoryBackend) ?? d.directoryBackend
        ad = try c.decodeIfPresent(ADSettings.self, forKey: .ad) ?? d.ad
        // A lab.json from before build 12 has no radiusDebug. Those builds always ran `-xx`,
        // but the quiet level is the better default and nothing a person can see changes, so
        // an old lab opens quiet rather than inheriting the old behaviour.
        radiusDebug = try c.decodeIfPresent(Bool.self, forKey: .radiusDebug) ?? d.radiusDebug
        radiusLoginNames = try c.decodeIfPresent(RadiusLoginNames.self, forKey: .radiusLoginNames) ?? d.radiusLoginNames
    }

    /// What radiusd is launched with. `-f` foreground and `-l stdout` are what makes the debug
    /// stream the app's Log pane; the level is the only part that is a choice.
    var radiusLogArguments: [String] { ["-f", "-l", "stdout", radiusDebug ? "-xx" : "-x"] }

    // MARK: One lab, one name

    /// **The lab's domain name, and the only place it is written** (build 24, the owner's
    /// decision that OpenLDAP and Samba AD must not be two different labs).
    ///
    /// Until build 23 the two backends were named independently: OpenLDAP answered for
    /// `dc=lab,dc=local` and the domain controller for `lab.sheep`, so switching backend
    /// changed every base DN, every user DN and every bind account on every device in the
    /// lab — and a device configured against one simply stopped working against the other.
    /// There is one name now. It is the AD realm, because that is the half a Windows PC and a
    /// Kerberos KDC both have to agree with and the half with the real constraints on it
    /// (two labels, lower case, never `.local` — see `ADSettings.problems`); the OpenLDAP base
    /// DN is `dc=`-per-label of it.
    var labDomain: String {
        get { ad.realm }
        set { ad.realm = newValue }
    }

    /// The old default, kept so `labDomainMigration` can recognise a lab that never left it.
    static let legacyLDAPSuffix = "dc=lab,dc=local"

    /// `lab.sheep` → `dc=lab,dc=sheep`.
    static func suffix(forLabDomain domain: String) -> String {
        domain.split(separator: ".").map { "dc=\($0)" }.joined(separator: ",")
    }

    /// True when the base DN is the lab domain's rather than one somebody typed.
    var ldapSuffixFollowsLabDomain: Bool {
        ldapSuffixOverride.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// The OpenLDAP base DN: the lab domain's, unless this lab pinned one.
    ///
    /// **Assigning to it pins it**, which is what "somebody set the base DN by hand" means.
    /// No control in the app writes here any more — Directory ▸ Server edits the lab domain
    /// and shows this — so the setter exists for a `.sheeplab` being imported, for `radctl`
    /// and for the suites, all of which are exactly that case.
    var ldapSuffix: String {
        get {
            let pinned = ldapSuffixOverride.trimmingCharacters(in: .whitespaces)
            return pinned.isEmpty ? Self.suffix(forLabDomain: labDomain) : pinned
        }
        set { ldapSuffixOverride = newValue }
    }

    /// What the lab domain *would* make the base DN — for the one line the pane shows beside
    /// a pinned base DN that does not match it.
    var labDomainSuffix: String { Self.suffix(forLabDomain: labDomain) }

    /// A pinned base DN that is not the lab domain's. Not an error — somebody may have a
    /// reason — but the pane says so, because two names for one lab is what build 24 exists
    /// to end.
    var ldapSuffixDiffersFromLabDomain: Bool {
        !ldapSuffixFollowsLabDomain && ldapSuffix.caseInsensitiveCompare(labDomainSuffix) != .orderedSame
    }

    /// **Put a lab that never left the old OpenLDAP default onto the lab domain** (build 24).
    ///
    /// The condition is the one the owner gave: the base DN is still `dc=lab,dc=local` — the
    /// literal default of builds ≤23, which nobody chose — and the lab has a realm, which
    /// every lab does. Such a base DN is not a decision, it is a leftover, so it follows the
    /// lab domain from now on and the OpenLDAP database is renamed into it at the next start
    /// (`LabEnvironment.rebuildLDAP` → `LDAPSuffixRewrite`). Any other base DN is somebody's
    /// own and is pinned exactly as it is; Directory ▸ Server says it differs from the lab
    /// domain rather than moving it.
    ///
    /// - Returns: true when something changed and the document should be saved.
    @discardableResult
    static func labDomainMigration(_ settings: inout LabSettings) -> Bool {
        guard !settings.ldapSuffixFollowsLabDomain else { return false }
        guard settings.ldapSuffixOverride.caseInsensitiveCompare(legacyLDAPSuffix) == .orderedSame,
              !settings.labDomain.isEmpty
        else { return false }
        settings.ldapSuffixOverride = ""
        return true
    }

    /// **Build 24's two identity migrations, in the order they have to run.**
    ///
    /// The admin one goes first and the order is load-bearing: it pins `cn=admin,<base>` for a
    /// lab with a password somebody chose, and that has to be the base DN the lab *had*. Then
    /// the base DN may move onto the lab domain, and a DN pinned under the old one is carried
    /// with it — a `rootdn` outside its own suffix is not a thing slapd should be given, and
    /// the spelling the person cared about (`cn=admin`) is what is preserved.
    @discardableResult
    static func migrateBuild24(_ settings: inout LabSettings) -> Bool {
        let before = settings
        adminIdentityMigration(&settings)
        let oldSuffix = settings.ldapSuffix
        labDomainMigration(&settings)
        let newSuffix = settings.ldapSuffix
        if oldSuffix.caseInsensitiveCompare(newSuffix) != .orderedSame,
           !settings.ldapAdminDNOverride.isEmpty,
           settings.ldapAdminDNOverride.lowercased().hasSuffix("," + oldSuffix.lowercased()) {
            settings.ldapAdminDNOverride =
                String(settings.ldapAdminDNOverride.dropLast(oldSuffix.count)) + newSuffix
        }
        return settings != before
    }

    // MARK: The administrator this directory answers to

    /// The RDN of the administrator, as Microsoft spells it.
    static let adminRDN = "cn=Administrator"
    /// The container it sits in. **`CN=Users` is deliberate** — it is where Active Directory
    /// keeps its own Administrator, and the owner confirmed the mirror is what he wants
    /// ("CN=Users ผมว่าก็ได้นะ เพราะ Microsoft ก็มี"). It means the DN a device is given here
    /// and the DN the same device is given against the Samba DC are the same shape, which is
    /// the whole point: `CN=Administrator,CN=Users,<base>` is the string iMaster's
    /// synchronisation page, ClearPass and FortiGate all already expect.
    static let adminContainerRDN = "cn=Users"
    /// The password a fresh lab is created with, and the one the owner's domain uses.
    static let defaultAdminPassword = "p@ssw0rd"
    /// What builds ≤23 used for both. Kept only so `adminIdentityMigration` can recognise a
    /// lab that never moved off them.
    static let legacyAdminRDN = "cn=admin"
    static let legacyAdminPassword = "admin123"

    /// `cn=Administrator,cn=Users,dc=lab,dc=local` — the default, derived from the base DN.
    static func defaultAdminDN(suffix: String) -> String {
        "\(adminRDN),\(adminContainerRDN),\(suffix)"
    }

    /// `cn=admin,dc=lab,dc=local` — what builds ≤23 computed.
    static func legacyAdminDN(suffix: String) -> String { "\(legacyAdminRDN),\(suffix)" }

    /// The DN slapd's `rootdn` carries, every device table prints and every bundled client
    /// binds with. Derived from the base DN unless a lab pinned one.
    var ldapAdminDN: String {
        let pinned = ldapAdminDNOverride.trimmingCharacters(in: .whitespaces)
        return pinned.isEmpty ? Self.defaultAdminDN(suffix: ldapSuffix) : pinned
    }

    /// The container entry the seed writes, so the admin DN resolves in a search.
    var ldapAdminContainerDN: String { "\(Self.adminContainerRDN),\(ldapSuffix)" }

    /// **Move a lab that never left the old defaults onto the new ones** (build 24).
    ///
    /// The rule is one sentence: a lab still on **both** of build 23's defaults —
    /// `cn=admin,<base>` and `admin123` — becomes `cn=Administrator,cn=Users,<base>` with
    /// `p@ssw0rd`; a lab carrying anything else is left exactly as it is.
    ///
    /// The DN half needs no test of its own, because builds ≤23 never stored one: an absent
    /// override *is* `cn=admin,<base>`. So the password is what tells the two labs apart, and
    /// a lab with a password somebody chose gets its old DN **written down** rather than
    /// silently re-pointed — every device in that lab was configured against `cn=admin,…` and
    /// this app must not move the account out from under them.
    ///
    /// Idempotent both ways: after the first case the password is no longer `admin123`, and
    /// after the second the override is no longer empty. Pure, so `loadDocument` can decide
    /// whether it owes `lab.json` a write, and so the two branches are unit tests.
    ///
    /// - Returns: true when something changed and the document should be saved.
    @discardableResult
    static func adminIdentityMigration(_ settings: inout LabSettings) -> Bool {
        guard settings.ldapAdminDNOverride.trimmingCharacters(in: .whitespaces).isEmpty else {
            return false            // already pinned, by a previous run or by a lab we imported
        }
        if settings.ldapAdminPassword == legacyAdminPassword {
            settings.ldapAdminPassword = defaultAdminPassword
            return true             // → cn=Administrator,cn=Users,<base> + p@ssw0rd
        }
        guard settings.ldapAdminPassword != defaultAdminPassword else { return false }
        settings.ldapAdminDNOverride = legacyAdminDN(suffix: settings.ldapSuffix)
        return true                 // a password somebody chose: keep the DN they configured
    }

    /// `dc=lab,dc=local` → `lab.local`, the domain half of `userPrincipalName`.
    var dnsDomain: String {
        ldapSuffix.split(separator: ",")
            .compactMap { $0.hasPrefix("dc=") ? String($0.dropFirst(3)) : nil }
            .joined(separator: ".")
    }

    /// Where the Groups pane and every generated group DN live.
    var groupsDN: String { "ou=groups,\(ldapSuffix)" }

    /// Exactly the enabled listeners, in the order slapd is given them.
    func listenURLs(host: String = "0.0.0.0") -> [String] {
        var out: [String] = []
        if ldapPlainEnabled { out.append("ldap://\(host):\(ldapPort)") }
        if ldapsEnabled { out.append("ldaps://\(host):\(ldapsPort)") }
        return out
    }

    /// slapd 2.7.1 has **no way to refuse StartTLS** while keeping TLS for `ldaps://` —
    /// `disallow starttls` is rejected outright (`<disallow> unknown feature`) and the TLS
    /// context is global. So StartTLS is simply available whenever the plain listener is up
    /// and TLS is configured at all, which here means LDAPS is on.
    var offersStartTLS: Bool { ldapPlainEnabled && ldapsEnabled }

    /// "tcp 389 · ldaps 636", or whichever of those is actually running.
    var listenerSummary: String {
        var parts: [String] = []
        if ldapPlainEnabled { parts.append("tcp \(ldapPort)") }
        if ldapsEnabled { parts.append("ldaps \(ldapsPort)") }
        return parts.isEmpty ? "no listener" : parts.joined(separator: " · ")
    }

    /// TLS directives and the LDAP leaf are generated exactly when something needs them.
    var needsTLS: Bool { ldapsEnabled }

    /// The transports a device (or the Test pane) can actually use right now.
    var availableTransports: [LDAPTransport] {
        var out: [LDAPTransport] = []
        if ldapPlainEnabled { out.append(.plain) }
        if offersStartTLS { out.append(.startTLS) }
        if ldapsEnabled { out.append(.ldaps) }
        return out
    }
}

nonisolated struct LabDocument: Codable, Sendable {
    /// **The seed, read-only — never the directory** (build 21, PROJECT-STATUS §18).
    ///
    /// Until build 16 these three lists *were* the directory: Apply copied them into slapd or
    /// into `OU=SheepRadius`. From build 17 the running backend became the original, and these
    /// stayed on as a second, editable user table ("Local users"). Build 21 removed that idea
    /// entirely — there is one set of users and the LDAP directory owns it — so nothing in the
    /// app writes here and no pane shows it.
    ///
    /// They are **kept, not deleted**, for exactly two reasons:
    ///
    /// * `LabEnvironment.rebuildLDAP` seeds a brand-new OpenLDAP database from them (first
    ///   seed only), which is what puts alice, bob and guest in a fresh lab.
    /// * reversibility: a lab upgraded from build ≤20 still holds whatever it held, so this
    ///   build can be backed out without anybody's accounts having been thrown away.
    ///
    /// `directoryImported` records that the one-time import of this table into a live backend
    /// has already happened.
    var users: [LabUser] = []
    var groups: [LabGroup] = []
    /// OUs that exist in their own right, so one can be created before it has any users and
    /// survive the last user leaving. Derived OUs (a path typed into a user row) are *not*
    /// listed here — `ouPaths` unions the two.
    var ous: [String] = []
    var clients: [NASClient] = []
    /// Conditional policy, in order — the order **is** the priority, and a rule with
    /// `stopAfterMatch` ends the walk like an ACL. Evaluated after the static reply.
    var rules: [PolicyRule] = []
    /// unlang pasted in by hand under Policy ▸ Advanced, written verbatim into post-auth
    /// after the rules. Validated by `radiusd -CX` on a staged copy before Apply commits it.
    var customUnlang = ""
    var settings = LabSettings()

    /// True once the one-time `DirectoryImport` of the pre-build-17 table into the live
    /// backend has run. It is a flag rather than a comparison because the honest answer after
    /// the import is "the table and the directory now differ, on purpose": a user deleted in
    /// the directory must not come back at the next launch.
    var directoryImported = false

    /// Passwords **this app set** on a directory account, keyed by lower-cased username.
    ///
    /// A directory never gives a password back, so this is the only way `authorize` can carry
    /// `Cleartext-Password` — which is what CHAP and EAP-MD5 need. Every other account is
    /// known by its NT hash alone (`RadiusAuthorize.chapNeedsCleartext`). Cleartext in
    /// `lab.json`, like every other password this app holds, and for the same stated reason:
    /// PEAP-MSCHAPv2 cannot be done without it.
    var directoryPasswords: [String: String] = [:]

    /// **Which lab this is**, for export and import (build 17).
    ///
    /// Per lab, not per export: two `.sheeplab` files written from the same Mac carry the same
    /// id on purpose, because the question Import has to answer is "do I already have this
    /// lab?" — and if the answer is yes, the domain controller on the other Mac has to be
    /// stopped before this one starts. Generated once and then kept.
    var labID = UUID()

    enum CodingKeys: String, CodingKey {
        case users, groups, ous, clients, rules, customUnlang, settings
        case directoryImported, directoryPasswords, labID
    }

    init(users: [LabUser] = [], groups: [LabGroup] = [], ous: [String] = [],
         clients: [NASClient] = [], rules: [PolicyRule] = [], customUnlang: String = "",
         settings: LabSettings = LabSettings(), directoryImported: Bool = false,
         directoryPasswords: [String: String] = [:], labID: UUID = UUID()) {
        self.labID = labID
        self.users = users
        self.groups = groups
        self.ous = ous
        self.clients = clients
        self.rules = rules
        self.customUnlang = customUnlang
        self.settings = settings
        self.directoryImported = directoryImported
        self.directoryPasswords = directoryPasswords
    }

    /// Only ever decoded from a pre-Groups lab.json, where membership was one string per user.
    private struct LegacyUser: Decodable {
        var username: String?
        var group: String?
    }

    /// The build-12 static-reply keys, as they still sit in an older lab.json. Read **once**,
    /// turned into rules by `PolicyMigration`, and never written back — `LabUser` and
    /// `LabGroup` no longer have anywhere to put them.
    private struct LegacyReply: Decodable {
        var id: UUID?
        var vlan: String?
        var replyAttributes: String?
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        users = try c.decodeIfPresent([LabUser].self, forKey: .users) ?? []
        groups = try c.decodeIfPresent([LabGroup].self, forKey: .groups) ?? []
        // A lab.json from before OUs were first-class has no `ous`; every OU it uses is
        // still derived from the users, so nothing is lost by starting empty.
        ous = try c.decodeIfPresent([String].self, forKey: .ous) ?? []
        clients = try c.decodeIfPresent([NASClient].self, forKey: .clients) ?? []
        // A lab.json from before build 10 has no rules and no custom unlang: an empty list
        // and an empty string reproduce exactly the old behaviour.
        rules = try c.decodeIfPresent([PolicyRule].self, forKey: .rules) ?? []
        customUnlang = try c.decodeIfPresent(String.self, forKey: .customUnlang) ?? ""
        settings = try c.decodeIfPresent(LabSettings.self, forKey: .settings) ?? LabSettings()
        // A lab.json from before build 17 has neither key. `false` is what triggers the
        // one-time import of this file's table into whichever backend is running.
        directoryImported = try c.decodeIfPresent(Bool.self, forKey: .directoryImported) ?? false
        directoryPasswords = try c.decodeIfPresent([String: String].self, forKey: .directoryPasswords) ?? [:]
        // A lab.json from before build 17 has no id; it gets one the first time it is saved,
        // which is what makes an export from an upgraded lab identifiable at all.
        labID = try c.decodeIfPresent(UUID.self, forKey: .labID) ?? UUID()
        if groups.isEmpty, let legacy = try? c.decode([LegacyUser].self, forKey: .users) {
            adoptLegacyGroups(legacy)
        }
        // Build 12 and earlier kept the reply on the user and the group. Build 13 keeps it in
        // one ordered rule list, so the old keys are converted here — the only place that ever
        // sees them — and are gone the next time the document is written.
        rules = PolicyMigration.migrate(
            users: users, groups: groups,
            legacyUsers: Self.legacyReplies(in: c, forKey: .users),
            legacyGroups: Self.legacyReplies(in: c, forKey: .groups),
            existing: rules)
        // Last, so it also catches the rules the build-12 migration just wrote.
        rules = Self.migrateGroupConditions(in: rules, using: groups)
    }

    /// **A group condition names its group from build 21 on** (PROJECT-STATUS §18).
    ///
    /// Builds 10–20 pointed at a `LabGroup` by `UUID`, from when that table *was* the
    /// directory. It is the read-only seed now, so a rule tied to an id in it could not name a
    /// group somebody made in OpenLDAP or in the domain — and the generated unlang has always
    /// compared `&control:Sheep-Group` by **name** anyway. So the id is resolved through the
    /// old table exactly once, here, and the name is what gets written back.
    ///
    /// An id the table no longer has is **not** dropped: the rule keeps it in `reference` with
    /// an empty `value`, `isDanglingGroup` becomes true, and the Policy list says "group no
    /// longer exists" beside it. Deleting somebody's rule silently because its group went is
    /// how a lab loses a VLAN assignment nobody can then explain.
    static func migrateGroupConditions(in rules: [PolicyRule], using groups: [LabGroup]) -> [PolicyRule] {
        guard rules.contains(where: { $0.conditions.contains { $0.kind.picksGroup && $0.reference != nil } })
        else { return rules }
        let nameByID = Dictionary(groups.filter { !$0.name.isEmpty }.map { ($0.id, $0.name) },
                                  uniquingKeysWith: { first, _ in first })
        return rules.map { rule in
            var rule = rule
            rule.conditions = rule.conditions.map { condition in
                var condition = condition
                guard condition.kind.picksGroup, let id = condition.reference else { return condition }
                // A value that is already there wins: the file was written by build 21 or
                // later and the id is a leftover nobody should be resolving again.
                if !condition.value.trimmingCharacters(in: .whitespaces).isEmpty {
                    condition.reference = nil
                } else if let name = nameByID[id] {
                    condition.value = name
                    condition.reference = nil
                }
                return condition
            }
            return rule
        }
    }

    /// `[id: Legacy]` for whichever list is asked for, empty when the file is already build 13.
    private static func legacyReplies(in container: KeyedDecodingContainer<CodingKeys>,
                                      forKey key: CodingKeys) -> [UUID: PolicyMigration.Legacy] {
        guard let rows = try? container.decode([LegacyReply].self, forKey: key) else { return [:] }
        var out: [UUID: PolicyMigration.Legacy] = [:]
        for row in rows {
            guard let id = row.id else { continue }
            let legacy = PolicyMigration.Legacy(vlan: row.vlan ?? "",
                                                replyAttributes: row.replyAttributes ?? "")
            if !legacy.isEmpty { out[id] = legacy }
        }
        return out
    }

    /// A non-empty old `group` string becomes a real LabGroup, and its user joins it.
    private mutating func adoptLegacyGroups(_ legacy: [LegacyUser]) {
        var idByName: [String: UUID] = [:]
        for entry in legacy {
            guard let username = entry.username,
                  let raw = entry.group?.trimmingCharacters(in: .whitespaces), !raw.isEmpty,
                  raw != LabGroup.everyoneName else { continue }
            let key = raw.lowercased()
            if idByName[key] == nil {
                let group = LabGroup(name: raw)
                groups.append(group)
                idByName[key] = group.id
            }
            guard let id = idByName[key],
                  let i = users.firstIndex(where: { $0.username == username }),
                  !users[i].groups.contains(id) else { continue }
            users[i].groups.append(id)
        }
    }

    func group(_ id: UUID) -> LabGroup? { groups.first { $0.id == id } }

    /// A user's groups in their stored order, skipping ids whose group has been deleted.
    func groups(of user: LabUser) -> [LabGroup] { user.groups.compactMap(group) }

    /// Every OU that has to exist: the ones created explicitly, the ones users sit in, and
    /// every ancestor of both (`Staff/IT` implies `Staff`). Parents before children.
    ///
    /// This is what the Users pane draws and what the LDIF emits, so an OU with no users is
    /// a real `organizationalUnit` a device can browse into.
    var ouPaths: [String] {
        var byKey: [String: String] = [:]
        func remember(_ path: String) {
            for step in OUPath.selfAndAncestors(of: path) where byKey[step.lowercased()] == nil {
                byKey[step.lowercased()] = step
            }
        }
        for ou in ous { remember(ou) }
        for user in users { remember(user.effectiveOU) }
        if byKey.isEmpty { remember(LabUser.defaultOU) }
        return byKey.values.sorted(by: OUPath.orderedBefore)
    }

    /// The users directly in this OU (not its descendants).
    func users(in path: String) -> [LabUser] {
        users.filter { OUPath.isSame($0.effectiveOU, path) }
    }

    /// The users in this OU *and* everything under it — what Delete has to care about.
    func usersInSubtree(_ path: String) -> [LabUser] {
        users.filter { OUPath.isSame($0.effectiveOU, path) || OUPath.isDescendant($0.effectiveOU, of: path) }
    }

    func ouExists(_ path: String) -> Bool {
        ouPaths.contains { OUPath.isSame($0, path) }
    }

    /// Create an OU, and every ancestor it needs, if they are not there already.
    mutating func addOU(_ path: String) {
        let normalized = OUPath.normalized(path)
        guard !normalized.isEmpty, !ous.contains(where: { OUPath.isSame($0, normalized) }) else { return }
        ous.append(normalized)
    }

    /// Rename an OU in place: the OU itself, every descendant OU, and the path of every user
    /// in either. One document edit, so Apply and Revert see it as a single change.
    mutating func renameOU(_ path: String, to newName: String) {
        let from = OUPath.normalized(path)
        let to = OUPath.normalized(newName)
        guard !from.isEmpty, !to.isEmpty, !OUPath.isSame(from, to) else { return }
        ous = ous.map { OUPath.rewritingPrefix($0, from: from, to: to) }
        for i in users.indices {
            users[i].ou = OUPath.rewritingPrefix(users[i].effectiveOU, from: from, to: to)
        }
        // A rule's OU condition holds the path as text (so the generated unlang reads like
        // something a person wrote), which means a rename has to carry it too or the rule
        // silently stops matching. Group conditions hold an id and need nothing.
        for r in rules.indices {
            for c in rules[r].conditions.indices where rules[r].conditions[c].kind.picksOU {
                rules[r].conditions[c].value =
                    OUPath.rewritingPrefix(rules[r].conditions[c].value, from: from, to: to)
            }
        }
        // The OU may have existed only because users were in it; make the new name explicit
        // so it cannot vanish if those users move away.
        addOU(to)
        ous = deduplicated(ous)
    }

    /// Remove an OU and its descendants. Only ever called once the subtree has no users —
    /// `usersInSubtree` is the guard the UI enforces.
    mutating func deleteOU(_ path: String) {
        ous.removeAll { OUPath.isSame($0, path) || OUPath.isDescendant($0, of: path) }
    }

    /// Move every user in an OU subtree to another OU, keeping their position under it.
    mutating func moveUsers(from source: String, to destination: String) {
        for i in users.indices where OUPath.isSame(users[i].effectiveOU, source)
            || OUPath.isDescendant(users[i].effectiveOU, of: source) {
            users[i].ou = OUPath.rewritingPrefix(users[i].effectiveOU, from: source, to: destination)
        }
    }

    private func deduplicated(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        return paths.filter { seen.insert(OUPath.normalized($0).lowercased()).inserted }
    }

    static let sample: LabDocument = {
        let netadmins = LabGroup(name: "NetAdmins", description: "Network administrators")
        let staff = LabGroup(name: "Staff", description: "All employees")
        // **Not "Guests".** Active Directory has a built-in group of that name, `sAMAccountName`
        // is unique domain-wide, and on 18 Sep 2026 syncing this sample lab put a real user into
        // `CN=Guests,CN=Builtin` instead of creating anything. `Validation.groupProblems` now
        // refuses the name outright; the sample must not ship one it would refuse.
        let visitors = LabGroup(name: "Visitors", description: "Visitor access")
        return LabDocument(
            users: [
                LabUser(username: "alice", displayName: "Alice Anderson", password: "alice123",
                        ou: "Staff/IT", groups: [netadmins.id, staff.id]),
                LabUser(username: "bob", displayName: "Bob Brown", password: "bob123",
                        ou: "Staff/Sales", groups: [staff.id]),
                LabUser(username: "guest", displayName: "Guest Account", password: "guest123",
                        ou: "Guests", groups: [visitors.id]),
            ],
            groups: [netadmins, staff, visitors],
            // An OU with nobody in it, so the "OUs exist in their own right" behaviour is
            // visible the first time the app runs (and the live suite has something to find).
            ous: ["Staff/IT", "Staff/Sales", "Guests", "Lab/Empty"],
            clients: [],
            // ONE ordered list, first match wins. The three group rules are the whole policy of
            // a fresh lab — they say exactly what build 12's "Replies by group" said, and they
            // are unnamed on purpose so the auto-generated name ("Group NetAdmins → VLAN 10")
            // is the first thing anyone sees. Alice is in NetAdmins *and* Staff and the first
            // rule wins, which is the same VLAN 10 she used to inherit.
            //
            // Then two worked examples, **switched off**: they show the shape of a rule with a
            // second AND condition without changing what a fresh lab replies with. Being below
            // the group rules, switching one on is not enough — it has to be dragged above the
            // group rule it competes with, which is the one thing about this list worth
            // learning, and the Policy pane says so.
            rules: [
                PolicyRule(conditions: [RuleCondition(kind: .groupIs, value: netadmins.name)],
                           vlan: "10", replyAttributes: "Filter-Id = \"netadmins\""),
                PolicyRule(conditions: [RuleCondition(kind: .groupIs, value: staff.name)],
                           vlan: "20"),
                PolicyRule(conditions: [RuleCondition(kind: .groupIs, value: visitors.name)],
                           vlan: "99"),
                PolicyRule(name: "Visitors on SSID Lab-Guest → VLAN 99", enabled: false,
                           conditions: [
                               RuleCondition(kind: .groupIs, value: visitors.name),
                               RuleCondition(kind: .ssid, value: "Lab-Guest"),
                           ],
                           vlan: "99"),
                PolicyRule(name: "NetAdmins on Wi-Fi → VLAN 10 + Session-Timeout", enabled: false,
                           conditions: [
                               RuleCondition(kind: .groupIs, value: netadmins.name),
                               RuleCondition(kind: .portType, value: RulePortType.wireless.rawValue),
                           ],
                           vlan: "10", replyAttributes: "Session-Timeout := 3600"),
            ]
        )
    }()
}

/// How the Test pane (and a device) reaches slapd.
nonisolated enum LDAPTransport: String, Codable, CaseIterable, Sendable {
    case plain, startTLS, ldaps

    var label: String {
        switch self {
        case .plain: "Plain LDAP"
        case .startTLS: "StartTLS on the LDAP port"
        case .ldaps: "LDAPS"
        }
    }

    /// `LDAPNOINIT=1` — which the app sets so libldap ignores ldap.conf — **also makes
    /// libldap ignore `LDAPTLS_CACERT`**. Verified on OpenLDAP 2.7.1: with LDAPNOINIT the
    /// environment variable is dropped and verification fails against our own CA, while
    /// `-o TLS_CACERT=` works either way. So the CA is always passed as an option.
    static func tlsArguments(mode: LDAPTransport, caPath: String) -> [String] {
        switch mode {
        case .plain: []
        case .ldaps: ["-o", "TLS_CACERT=\(caPath)"]
        // -ZZ, not -Z: -Z would silently continue in the clear if StartTLS failed.
        case .startTLS: ["-ZZ", "-o", "TLS_CACERT=\(caPath)"]
        }
    }
}

/// Secret of the built-in 127.0.0.1 client, used by the in-app test tools.
nonisolated let localTestSecret = "testing123"

/// One reply line from a group's `replyAttributes`, e.g. `Filter-Id = "staff"`.
///
/// Parsed rather than pattern-matched because the value may itself contain the operator
/// character — `Cisco-AVPair = "shell:priv-lvl=15"` is the canonical example.
nonisolated struct ReplyAttribute: Hashable, Sendable {
    /// The operators the FreeRADIUS `users` file accepts on a reply item.
    static let operators = [":=", "+=", "="]
    /// What may appear in an attribute name: RADIUS dictionaries use letters, digits and `-`.
    static let nameAllowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-")

    let name: String
    let op: String
    let value: String

    /// Canonical single-spaced form, which is what goes into the `authorize` file.
    var line: String { "\(name) \(op) \(value)" }

    init?(line raw: String) {
        let text = raw.trimmingCharacters(in: .whitespaces)
        let name = String(text.prefix { char in
            char.unicodeScalars.allSatisfy { Self.nameAllowed.contains($0) }
        })
        guard !name.isEmpty else { return nil }
        let afterName = text.dropFirst(name.count).drop { $0 == " " || $0 == "\t" }
        guard let op = Self.operators.first(where: { afterName.hasPrefix($0) }) else { return nil }
        let value = afterName.dropFirst(op.count).trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return nil }
        self.name = name
        self.op = op
        self.value = value
    }

    /// Every valid line of a free-text block, in order. Blank and `#` lines are skipped;
    /// invalid ones are dropped here and reported by `Validation.replyAttributeProblems`.
    static func parse(_ text: String) -> [ReplyAttribute] {
        text.split(separator: "\n", omittingEmptySubsequences: false).compactMap { ReplyAttribute(line: String($0)) }
    }
}

nonisolated enum Validation {
    static let usernameAllowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-@")
    /// Everything a group / OU name may contain. Deliberately excludes the RFC 4514
    /// DN metacharacters `, = + " \ < > ; #` — those end up inside a DN unescaped and
    /// make slapadd abort halfway through seeding ("str2entry: entry has invalid DN").
    static let nameAllowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._- ")
    /// One DNS label, i.e. what may follow `dc=` in the base DN.
    static let dnsLabelAllowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-")

    /// **Where a problem belongs** (build 25, QA M-19: "validation never appears next to the
    /// control that caused it").
    ///
    /// Until build 24 every check returned a bare sentence and the only reader was
    /// `problems.first` on one truncated line of the ApplyBar. The sentences are unchanged —
    /// they are the same words, in the same order — but each one now says which row it came
    /// out of, so the Clients inspector and the Policy editor can draw their own.
    ///
    /// It is also what makes the **draft rule** possible (`ApplyScope`): "this problem belongs
    /// to a client nobody has applied yet" is not a question a `[String]` can answer.
    nonisolated enum Site: Sendable, Equatable, Hashable {
        case client(UUID)
        case rule(UUID)
        case condition(rule: UUID, condition: UUID)
        case settings
        /// A user, group or OU in `lab.json`'s read-only seed, or the document as a whole.
        case seed

        /// The rule a problem is about, whether it came from the rule or from one of its
        /// conditions.
        var ruleID: UUID? {
            switch self {
            case .rule(let id), .condition(let id, _): id
            default: nil
            }
        }

        var clientID: UUID? {
            if case .client(let id) = self { return id }
            return nil
        }
    }

    nonisolated struct Problem: Sendable, Equatable, Identifiable {
        var site: Site
        var text: String

        var id: String { "\(site)|\(text)" }
    }

    /// Every problem, in the order they have always been reported, with nothing else changed.
    static func problems(in doc: LabDocument) -> [String] { detailed(in: doc).map(\.text) }

    /// The same list, each sentence carrying the row it belongs to.
    static func detailed(in doc: LabDocument) -> [Problem] {
        var out = seedProblems(doc).map { Problem(site: .seed, text: $0) }
        out += clientProblemsDetailed(doc.clients)
        out += ruleProblemsDetailed(doc)
        out += settingsProblems(doc.settings).map { Problem(site: .settings, text: $0) }
        return out
    }

    /// The users, groups and OUs of `lab.json`'s read-only seed. Nothing in the app edits
    /// them any more, so they have no control to sit beside.
    static func seedProblems(_ doc: LabDocument) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        for u in doc.users {
            if u.username.isEmpty {
                out.append("A user has no username.")
            } else if u.username.unicodeScalars.contains(where: { !usernameAllowed.contains($0) }) {
                out.append("Username \"\(u.username)\" may only contain a-z 0-9 . _ - @")
            } else if u.username.count > maxNameLength {
                out.append("Username \"\(u.username.prefix(24))…\" is \(u.username.count) characters — the limit is \(maxNameLength). \(lengthReason)")
            }
            if u.displayName.count > maxDisplayNameLength {
                out.append("The display name for \"\(u.username)\" is \(u.displayName.count) characters — the limit is \(maxDisplayNameLength).")
            }
            if !u.username.isEmpty, !seen.insert(u.username.lowercased()).inserted {
                out.append("Username \"\(u.username)\" is used twice.")
            }
            if u.enabled, u.password.isEmpty { out.append("User \"\(u.username)\" has no password.") }
            out += ouProblems(u)
        }
        out += ouListProblems(doc)
        out += groupProblems(doc.groups)
        return out
    }

    /// `${…}` is expanded by FreeRADIUS's **configuration** parser, before unlang ever sees
    /// the line, and there is no escape for it — so anything the app interpolates into a
    /// generated string has to be free of it. (`%` is escapable and is escaped;
    /// `RuleUnlang.quoted` handles quotes, backslashes and newlines.)
    static let configVariableRule = "may not contain ${…} — that is a FreeRADIUS configuration variable and cannot be escaped."

    /// Every rule and every condition, checked hard enough that a saved document always
    /// produces a configuration `radiusd -CX` will accept. Apply re-checks against the real
    /// parser anyway; this is what gives a useful message before it gets that far.
    static func ruleProblems(_ doc: LabDocument) -> [String] {
        ruleProblemsDetailed(doc).map(\.text)
    }

    static func ruleProblemsDetailed(_ doc: LabDocument) -> [Problem] {
        var out: [Problem] = []
        let context = PolicyContext(doc)
        for (index, rule) in doc.rules.enumerated() {
            let site = Site.rule(rule.id)
            func say(_ text: String) { out.append(Problem(site: site, text: text)) }
            let who = "Rule \"\(rule.displayName(index: index, context: context))\""
            if rule.name.contains("${") { say("\(who) \(configVariableRule)") }
            if !rule.vlan.isEmpty, Int(rule.vlan).map({ !(1...4094).contains($0) }) ?? true {
                say("\(who): VLAN must be 1–4094.")
            }
            // Reject and VLAN are mutually exclusive in the editor; a document that has both
            // would generate an Access-Reject carrying a VLAN, which is nonsense on the wire.
            if rule.rejects, !rule.vlan.trimmingCharacters(in: .whitespaces).isEmpty {
                say("\(who): a rule either sets a VLAN or rejects — not both.")
            }
            let timeout = rule.sessionTimeout.trimmingCharacters(in: .whitespaces)
            if !timeout.isEmpty, Int(timeout).map({ $0 < 1 }) ?? true {
                say("\(who): Session-Timeout must be a whole number of seconds.")
            }
            if rule.rejectMessage.contains("${") { say("\(who): the Reply-Message \(configVariableRule)") }
            // Only the lines that will be generated: text kept behind a switched-off
            // "Also send attributes" is not on its way to radiusd (build 25, QA M-21).
            if rule.sendsAttributes {
                for text in replyAttributeProblems(rule.replyAttributes, in: who) { say(text) }
            }
            for condition in rule.conditions {
                out += conditionProblems(condition, in: who, doc: doc).map {
                    Problem(site: .condition(rule: rule.id, condition: condition.id), text: $0)
                }
            }
        }
        if doc.customUnlang.count > 20_000 {
            out.append(Problem(site: .settings,
                               text: "The custom unlang block is very large (\(doc.customUnlang.count) characters) — keep it under 20000."))
        }
        return out
    }

    static func conditionProblems(_ c: RuleCondition, in who: String, doc: LabDocument) -> [String] {
        let label = c.kind.label
        let value = c.value.trimmingCharacters(in: .whitespaces)
        func bad(_ why: String) -> [String] { ["\(who), \"\(label)\": \(why)"] }

        switch c.kind {
        case .groupIs, .groupIsNot:
            // **The group is a name, and it is the directory's** (build 21). Whether that name
            // exists right now is not a validation question: the directory can be off, or the
            // group can be created a minute from now, and the generated unlang is a string
            // comparison that simply does not match until then. The Policy list marks a name
            // the running directory does not have; this refuses only what cannot be generated.
            guard !value.isEmpty else {
                return bad(c.isDanglingGroup
                           ? "pick a group. (The group this rule pointed at is not in this lab any more.)"
                           : "pick a group.")
            }
            guard !value.contains("${") else { return bad("the group name \(configVariableRule)") }
        case .ouIs, .ouIsUnder:
            guard !OUPath.normalized(value).isEmpty else { return bad("pick an OU.") }
        case .usernameIs:
            guard !value.isEmpty else { return bad("enter a username.") }
            guard !value.contains("${") else { return bad("a username \(configVariableRule)") }
        case .usernameEndsWith:
            guard !value.isEmpty else { return bad("enter the end of a username, for example @lab.local.") }
            guard !value.contains("${") else { return bad("a username \(configVariableRule)") }
        case .anyone, .isComputerAccount:
            return []
        case .usernameMatches, .nasIdentifierMatches, .callingMACMatches:
            guard !value.isEmpty else { return bad("enter a regular expression.") }
            guard (try? NSRegularExpression(pattern: value)) != nil else {
                return bad("\"\(value)\" is not a valid regular expression.")
            }
        case .nasIPIs:
            guard isValidAddress(value), !value.contains("/") else {
                return bad("\"\(value)\" is not an IPv4 address. Use \"NAS-IP-Address in\" for a range.")
            }
        case .nasIPInCIDR:
            guard isValidAddress(value) else { return bad("\"\(value)\" is not an IPv4 address or CIDR.") }
        case .nasClient:
            guard let id = c.reference,
                  let client = doc.clients.first(where: { $0.id == id }) else {
                return bad("pick a client from the Clients table. (The one it pointed at was deleted.)")
            }
            guard isValidAddress(client.address) else {
                return bad("that client's address (\"\(client.address)\") is not an IPv4 address or CIDR.")
            }
        case .nasIdentifierIs:
            guard !value.isEmpty else { return bad("enter a NAS-Identifier.") }
            guard !value.contains("${") else { return bad("a NAS-Identifier \(configVariableRule)") }
        case .portType:
            guard RulePortType(rawValue: value) != nil else { return bad("pick a port type.") }
        case .ssid:
            guard !value.isEmpty else { return bad("enter an SSID.") }
            guard !value.contains("${") else { return bad("an SSID \(configVariableRule)") }
        case .calledStationIs, .calledStationBeginsWith:
            guard !value.isEmpty else {
                return bad(c.kind == .calledStationIs
                           ? "enter a Called-Station-Id, for example SIAM-BUILDING:test2."
                           : "enter a prefix, for example SIAM-BUILDING: (with the colon).")
            }
            guard !value.contains("${") else { return bad("a Called-Station-Id \(configVariableRule)") }
        case .callingMACIs:
            guard RuleUnlang.macDigits(value) != nil else {
                return bad("\"\(value)\" is not a MAC address — 12 hex digits, optionally separated by : - or .")
            }
        case .timeWindow:
            guard !c.normalizedWeekdays.isEmpty else { return bad("pick at least one day.") }
        case .raw:
            guard !value.isEmpty else { return bad("enter a condition, or remove this row.") }
        }
        return []
    }

    /// **Checked against `effectiveOU`, not the raw string** (build 21). A blank OU is the
    /// default OU — that is what `effectiveOU`, `containerDN` and every generator already do
    /// with it — so refusing the document over one was the app disagreeing with itself.
    static func ouProblems(_ u: LabUser) -> [String] {
        let segments = OUPath.segments(u.effectiveOU)
        let who = u.username.isEmpty ? "a user" : "\"\(u.username)\""
        var out = segments.filter { !isValidName($0) }.map { "OU \"\($0)\" for \(who) \(nameRule)" }
        out += segments.filter { $0.count > maxNameLength }
            .map { "OU \"\($0.prefix(24))…\" for \(who) is \($0.count) characters — the limit is \(maxNameLength). \(lengthReason)" }
        if segments.count > OUPath.maxDepth {
            out.append("The OU for \(who) is \(segments.count) levels deep; the limit is \(OUPath.maxDepth).")
        }
        return out
    }

    /// The explicitly-created OUs. A path a user typed is checked by `ouProblems`.
    static func ouListProblems(_ doc: LabDocument) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        for raw in doc.ous {
            let path = OUPath.normalized(raw)
            if path.isEmpty {
                out.append("An OU has no name.")
                continue
            }
            out += OUPath.segments(path).filter { !isValidName($0) }.map { "OU \"\($0)\" \(nameRule)" }
            out += OUPath.segments(path).filter { $0.count > maxNameLength }
                .map { "OU \"\($0.prefix(24))…\" is \($0.count) characters — the limit is \(maxNameLength). \(lengthReason)" }
            if OUPath.depth(path) > OUPath.maxDepth {
                out.append("OU \"\(path)\" is \(OUPath.depth(path)) levels deep; the limit is \(OUPath.maxDepth).")
            }
            // LDAP cannot tell Staff/IT from staff/it, so neither may the app.
            if !seen.insert(path.lowercased()).inserted {
                out.append("OU \"\(path)\" is defined twice.")
            }
        }
        return out
    }

    static func groupProblems(_ groups: [LabGroup]) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        for g in groups {
            if g.name.isEmpty {
                out.append("A group has no name.")
            } else if !isValidName(g.name) {
                out.append("Group \"\(g.name)\" \(nameRule)")
            } else if g.name.count > maxNameLength {
                out.append("Group \"\(g.name.prefix(24))…\" is \(g.name.count) characters — the limit is \(maxNameLength). \(lengthReason)")
            }
            if g.description.count > maxDescriptionLength {
                out.append("The description for group \"\(g.name)\" is \(g.description.count) characters — the limit is \(maxDescriptionLength).")
            }
            if g.name.caseInsensitiveCompare(LabGroup.everyoneName) == .orderedSame {
                out.append("\"\(LabGroup.everyoneName)\" is generated automatically — give this group another name.")
            } else if ADProtectedObject.isProtectedGroup(name: g.name) {
                // Refused in **both** backends, deliberately. The directory backend is a
                // setting somebody can flip at any moment, and a group name that is harmless in
                // OpenLDAP and destructive in AD is exactly the trap this exists to close: on
                // 18 Sep 2026 the sample lab's "Guests" resolved to AD's built-in
                // CN=Guests,CN=Builtin and a real user was added to it.
                out.append("Group \"\(g.name)\" is a name Active Directory already uses for a built-in group. "
                           + "A group name is unique across a whole domain, so syncing this one would add your users to that built-in group instead of creating yours. Rename it — \"Visitors\" rather than \"Guests\", for example.")
            } else if !seen.insert(g.name.lowercased()).inserted {
                out.append("Group \"\(g.name)\" is defined twice.")
            }
        }
        return out
    }

    static let nameRule = "may only contain letters, digits, space, . _ - and may not start or end with a space."

    /// **64, because that is AD's limit on a CN** — and OpenLDAP's `slapadd` refuses a long
    /// RDN too. Without this, a 300-character username got as far as `ldap/seed.ldif` and then
    /// failed inside slapadd, leaving a half-built `ldap/` directory and an error from a tool
    /// the person never ran. A RADIUS `User-Name` also has to fit in a 253-octet attribute.
    static let maxNameLength = 64
    static let maxDisplayNameLength = 256
    static let maxDescriptionLength = 1024
    static let lengthReason = "Active Directory caps a CN at 64 characters and slapadd refuses a longer RDN."

    /// One reply line: an attribute name, an operator and a value. Anything else would be
    /// pasted straight into the `authorize` file and taken down by radiusd's own parser.
    /// `owner` names whatever holds the lines ("Group \"Staff\"", "Rule \"Guests\""), because
    /// three different editors now share this syntax.
    static func replyAttributeProblems(_ text: String, in owner: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false).compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { return nil }
            guard ReplyAttribute(line: line) == nil else { return nil }
            return "\(owner): \"\(line)\" is not `Attribute = value` (operator = := or +=)."
        }
    }

    /// A NAS address must be a valid IPv4/CIDR, unique, and must not collide with the
    /// built-in 127.0.0.1 client that clients.conf always emits — FreeRADIUS refuses a
    /// duplicate client and then exits without printing anything on a plain `-C`.
    static func clientProblems(_ clients: [NASClient]) -> [String] {
        clientProblemsDetailed(clients).map(\.text)
    }

    static func clientProblemsDetailed(_ clients: [NASClient]) -> [Problem] {
        var out: [Problem] = []
        var seenAddresses = Set<String>()
        for c in clients {
            let label = c.name.isEmpty ? c.address : c.name
            var mine: [String] = []
            if !isValidAddress(c.address) {
                mine.append("Client \"\(label)\": \"\(c.address)\" is not an IPv4 address or CIDR.")
            } else if isLoopback(c.address) {
                mine.append("Client \"\(label)\": 127.0.0.0/8 is reserved — the built-in localhost client already covers it.")
            } else if let width = prefixLength(c.address), width < 8 {
                // `0.0.0.0/0` passed every check above and became `ipaddr = 0.0.0.0/0` in
                // clients.conf: every host that can reach udp/1812 is then a NAS holding this
                // secret. Nothing in a lab needs a prefix wider than a /8.
                mine.append("Client \"\(label)\": /\(width) would accept requests from every address on the network — give the switch's own address, or a network no wider than /8.")
            } else if hasHostBits(c.address) {
                mine.append("Client \"\(label)\": \"\(c.address)\" has host bits set below the /\(prefixLength(c.address) ?? 32) — write the network address, because FreeRADIUS masks them off without saying so.")
            } else if !seenAddresses.insert(c.address).inserted {
                mine.append("Two clients share the address \(c.address).")
            }
            if c.secret.isEmpty { mine.append("Client \"\(label)\" has no shared secret.") }
            out += mine.map { Problem(site: .client(c.id), text: $0) }
        }
        return out
    }

    static func settingsProblems(_ s: LabSettings) -> [String] {
        var out: [String] = []
        // Only the listeners that are actually going to be opened are checked.
        let plainOn = s.ldapEnabled && s.ldapPlainEnabled
        let ldapsOn = s.ldapEnabled && s.ldapsEnabled
        var ports = [("RADIUS auth", s.authPort), ("RADIUS accounting", s.acctPort)]
        if plainOn { ports.append(("LDAP", s.ldapPort)) }
        if ldapsOn { ports.append(("LDAPS", s.ldapsPort)) }
        for (label, port) in ports where !(1...65535).contains(port) {
            out.append("The \(label) port must be between 1 and 65535.")
        }
        if s.authPort == s.acctPort {
            out.append("The RADIUS auth and accounting ports must differ.")
        }
        if plainOn, ldapsOn, s.ldapsPort == s.ldapPort {
            out.append("The LDAP and LDAPS ports must differ.")
        }
        // **The lab domain is checked in both backends** (build 24): it is the AD realm *and*
        // the OpenLDAP base DN now, so a name that only Samba would have refused would have
        // produced an unusable `dc=` suffix here and said nothing about it.
        // AD mode says it in the realm's own words (and checks the NetBIOS name and the
        // Administrator password besides), so the two are an either/or rather than both.
        if s.directoryBackend == .activeDirectory {
            out += s.ad.problems
        } else {
            out += ADSettings.domainProblems(s.labDomain)
        }
        if s.ldapEnabled, s.directoryBackend == .openLDAP, !plainOn, !ldapsOn {
            out.append("The LDAP server needs at least one listener — switch on LDAP, LDAPS, or both.")
        }
        if !isValidSuffix(s.ldapSuffix) {
            out.append("The LDAP base DN must look like dc=lab,dc=local.")
        }
        return out
    }

    static func isValidAddress(_ s: String) -> Bool {
        let parts = s.split(separator: "/", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count) else { return false }
        let octets = parts[0].split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4, octets.allSatisfy({ UInt8($0) != nil }) else { return false }
        if parts.count == 2 { guard let p = Int(parts[1]), (0...32).contains(p) else { return false } }
        return true
    }

    /// The `/n` of a CIDR, or nil when the address carries no prefix (a single host).
    static func prefixLength(_ s: String) -> Int? {
        let parts = s.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        return Int(parts[1])
    }

    /// True when a CIDR has bits set below its prefix — `10.0.0.5/24`, which FreeRADIUS
    /// accepts and silently treats as `10.0.0.0/24`, so the line in the pane and the client
    /// the server actually has are two different things.
    static func hasHostBits(_ s: String) -> Bool {
        guard let width = prefixLength(s), width < 32 else { return false }
        let octets = s.split(separator: "/")[0].split(separator: ".").compactMap { UInt32($0) }
        guard octets.count == 4 else { return false }
        let value = octets.reduce(UInt32(0)) { ($0 << 8) | $1 }
        let mask: UInt32 = width == 0 ? 0 : ~UInt32(0) << (32 - UInt32(width))
        return value & ~mask != 0
    }

    /// True for anything inside 127.0.0.0/8 — including a CIDR that overlaps it.
    static func isLoopback(_ s: String) -> Bool {
        s.split(separator: "/", omittingEmptySubsequences: false).first?.hasPrefix("127.") ?? false
    }

    /// One DNS label: letters, digits and hyphens, not starting or ending with one.
    static func isDNSLabel(_ s: String) -> Bool {
        guard !s.isEmpty, s.first != "-", s.last != "-" else { return false }
        return !s.unicodeScalars.contains { !dnsLabelAllowed.contains($0) }
    }

    /// One path segment of an OU, or a group name.
    static func isValidName(_ s: String) -> Bool {
        guard !s.isEmpty, s.first != " ", s.last != " " else { return false }
        return !s.unicodeScalars.contains { !nameAllowed.contains($0) }
    }

    /// `dc=lab,dc=local` — any number of dc= components, nothing else. Keeping the base DN
    /// to dc-components is what lets seedLDIF derive a DNS domain for userPrincipalName.
    static func isValidSuffix(_ s: String) -> Bool {
        let parts = s.split(separator: ",", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return false }
        return parts.allSatisfy { part in
            guard part.hasPrefix("dc=") else { return false }
            let value = part.dropFirst(3)
            guard !value.isEmpty, value.first != "-", value.last != "-" else { return false }
            return !value.unicodeScalars.contains { !dnsLabelAllowed.contains($0) }
        }
    }
}

// MARK: - A row nobody has applied yet is a draft

/// **Adding a row must not stop the app saving** (build 25 — QA M-18, M-27 and M-28, which are
/// one bug read from three sides).
///
/// Build 24's rule was that `Validation.problems(in: doc)` is the whole document's, and that a
/// non-empty list disables Apply everywhere, reddens the bar on every pane and makes
/// `adoptStoppedHalves` refuse to save *anything*. **Add client** creates a row with no address
/// and no secret, and **Add rule** a rule whose group may not be picked yet, so the ordinary act
/// of starting a row put the app into a blocking-invalid state until it was finished — and while
/// it was, an unrelated edit on another pane could not reach `lab.json` at all.
///
/// The one rule that answers all three:
///
/// > **A client or a rule the servers have never seen is a draft.** Its problems are shown on
/// > its own row (`Validation.Site`) and listed in the bar, but they block nothing: Apply and
/// > every save commit `committable` — the document *minus* the drafts that are not valid yet —
/// > so the valid rest is saved. A draft becomes an ordinary row the moment it is valid, and
/// > from then on its problems block like any other.
///
/// "The servers have never seen it" is `applied`, by id — so a row that has been applied once
/// and then broken is **not** a draft, and breaking it does stop Apply, which is right: radiusd
/// is serving the old copy of exactly that row.
///
/// And **Revert** falls out of it rather than needing a rule of its own (M-27): `doc = applied`
/// drops the drafts along with the unapplied edits, which is precisely "revert what has not been
/// adopted". What it could never do is undo an *adopted* edit, so the bar says how many changes
/// it will discard and asks first.
nonisolated enum ApplyScope {
    /// Clients in `doc` that are not in `applied` — by id, so a renamed client is the same row.
    static func draftClients(doc: LabDocument, applied: LabDocument) -> Set<UUID> {
        let known = Set(applied.clients.map(\.id))
        return Set(doc.clients.map(\.id).filter { !known.contains($0) })
    }

    static func draftRules(doc: LabDocument, applied: LabDocument) -> Set<UUID> {
        let known = Set(applied.rules.map(\.id))
        return Set(doc.rules.map(\.id).filter { !known.contains($0) })
    }

    /// **What Apply commits, what a stopped half adopts, and what reaches `lab.json`.**
    ///
    /// `doc` with the draft rows that still carry a problem of their own taken out. Repeated
    /// until it settles, because dropping a draft client can invalidate a rule that pointed at
    /// it — and if that rule is a draft too, it goes with it. Three passes is far more than any
    /// real document needs and is a bound rather than a `while true`.
    static func committable(doc: LabDocument, applied: LabDocument) -> LabDocument {
        let draftClientIDs = draftClients(doc: doc, applied: applied)
        let draftRuleIDs = draftRules(doc: doc, applied: applied)
        guard !draftClientIDs.isEmpty || !draftRuleIDs.isEmpty else { return doc }
        var out = doc
        for _ in 0..<3 {
            let problems = Validation.detailed(in: out)
            guard !problems.isEmpty else { break }
            let badClients = Set(problems.compactMap(\.site.clientID)).intersection(draftClientIDs)
            let badRules = Set(problems.compactMap(\.site.ruleID)).intersection(draftRuleIDs)
            guard !badClients.isEmpty || !badRules.isEmpty else { break }
            out.clients.removeAll { badClients.contains($0.id) }
            out.rules.removeAll { badRules.contains($0.id) }
        }
        return out
    }

    /// The problems that block Apply and block saving — the problems of the document that
    /// would actually be committed, which is the only list a person can act on by pressing
    /// Apply.
    static func blocking(doc: LabDocument, applied: LabDocument) -> [Validation.Problem] {
        Validation.detailed(in: committable(doc: doc, applied: applied))
    }

    /// Every problem, blocking or not — what the bar lists and what a row draws beside itself.
    static func all(doc: LabDocument) -> [Validation.Problem] { Validation.detailed(in: doc) }

    /// True when this problem is a draft row's, so the pane can say "not applied yet" rather
    /// than "this is stopping everything".
    static func isDraft(_ problem: Validation.Problem, doc: LabDocument, applied: LabDocument) -> Bool {
        if let id = problem.site.clientID { return draftClients(doc: doc, applied: applied).contains(id) }
        if let id = problem.site.ruleID { return draftRules(doc: doc, applied: applied).contains(id) }
        return false
    }

    /// **What Revert will throw away**, counted so the confirmation can name it (M-27). nil
    /// when there is nothing to revert.
    static func revertSummary(doc: LabDocument, applied: LabDocument) -> String? {
        var parts: [String] = []
        let newClients = draftClients(doc: doc, applied: applied).count
        let newRules = draftRules(doc: doc, applied: applied).count
        if newClients > 0 { parts.append(count(newClients, "new client", "new clients")) }
        if newRules > 0 { parts.append(count(newRules, "new rule", "new rules")) }
        let changedClients = doc.clients.filter { client in
            guard let was = applied.clients.first(where: { $0.id == client.id }) else { return false }
            return was != client
        }.count
        let changedRules = doc.rules.filter { rule in
            guard let was = applied.rules.first(where: { $0.id == rule.id }) else { return false }
            return was != rule
        }.count
        let removedClients = applied.clients.filter { was in !doc.clients.contains { $0.id == was.id } }.count
        let removedRules = applied.rules.filter { was in !doc.rules.contains { $0.id == was.id } }.count
        if changedClients > 0 { parts.append(count(changedClients, "edited client", "edited clients")) }
        if changedRules > 0 { parts.append(count(changedRules, "edited rule", "edited rules")) }
        if removedClients > 0 { parts.append(count(removedClients, "deleted client", "deleted clients")) }
        if removedRules > 0 { parts.append(count(removedRules, "deleted rule", "deleted rules")) }
        if doc.customUnlang != applied.customUnlang { parts.append("the custom unlang block") }
        if doc.settings != applied.settings { parts.append("the settings on this pane") }
        guard !parts.isEmpty else { return nil }
        return "Revert discards " + list(parts) + "."
    }

    private static func count(_ n: Int, _ one: String, _ many: String) -> String {
        "\(n) \(n == 1 ? one : many)"
    }

    private static func list(_ parts: [String]) -> String {
        guard parts.count > 1 else { return parts.first ?? "" }
        return parts.dropLast().joined(separator: ", ") + " and " + (parts.last ?? "")
    }
}


/// The spellings of an account RADIUS answers to (2.0 (3)). Measured on the Samba AD test
/// domain before this existed: `alice` was accepted and `alice@test.sheep` / `TEST\alice` were
/// rejected with "No Auth-Type found" — `authorize` had one entry per account and nothing in
/// the configuration rewrites `User-Name` (see `MachineIdentity`), so the only name that worked
/// was the one Windows' own LDAP bind refuses.
nonisolated struct RadiusLoginNames: Codable, Hashable, Sendable {
    /// `alice`
    var username = true
    /// `alice@lab.sheep` — the account's userPrincipalName.
    var userPrincipalName = true
    /// `LABSHEEP\alice` — Samba AD only; OpenLDAP has no NetBIOS domain.
    var downLevel = true

    init() {}

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        username = try c.decodeIfPresent(Bool.self, forKey: .username) ?? true
        userPrincipalName = try c.decodeIfPresent(Bool.self, forKey: .userPrincipalName) ?? true
        downLevel = try c.decodeIfPresent(Bool.self, forKey: .downLevel) ?? true
    }

    /// Every name one account is written under, in this order, without repeats (a UPN of
    /// `alice@` nothing is not written; neither is a down-level name with no NetBIOS domain).
    func names(username user: String, userPrincipalName upn: String, netbiosDomain: String) -> [String] {
        var out: [String] = []
        func add(_ name: String) {
            guard !name.isEmpty, !out.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) else { return }
            out.append(name)
        }
        if username { add(user) }
        if userPrincipalName, upn.contains("@"), !upn.hasSuffix("@") { add(upn) }
        if downLevel, !netbiosDomain.isEmpty { add(netbiosDomain.uppercased() + "\\" + user) }
        return out
    }
}
