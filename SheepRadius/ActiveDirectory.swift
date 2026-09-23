import Foundation

/// Which directory the app runs. The two are mutually exclusive because both want 389 and
/// 636 on the wildcard address.
nonisolated enum DirectoryBackend: String, Codable, CaseIterable, Sendable {
    case openLDAP, activeDirectory

    /// What the two choices are called everywhere a person sees them — the sidebar's LDAP row
    /// and Directory ▸ Server (build 21). Two words each, and the same two words in both
    /// places: the sidebar control and the pane's radio group bind to the same setting, and a
    /// control that names its value differently from the one beside it is a control that
    /// invites the question "are these the same thing?".
    var label: String {
        switch self {
        case .openLDAP: "OpenLDAP"
        case .activeDirectory: "Samba AD"
        }
    }

    var short: String { label }
}

/// Everything the Samba DC needs. Kept separate from `LabSettings` so a lab.json written
/// before AD mode existed decodes with the defaults.
nonisolated struct ADSettings: Codable, Hashable, Sendable {
    /// Lower-case DNS realm, e.g. `lab.sheep`. **Never** a `.local` realm — see `problems`.
    var realm = "lab.sheep"
    /// The short NetBIOS domain, upper-case.
    var netbiosDomain = "LABSHEEP"
    /// Host part of the DC's name; the FQDN is `<dcHostname>.<realm>`.
    var dcHostname = "dc1"
    /// Where to set it, in the words of the menu (build 32).
    static let missingPasswordMessage = "Samba AD needs an Administrator password before it can start. "
        + "Set it under Directory \u{25B8} Server \u{25B8} Domain \u{25B8} Administrator password (Change…). "
        + "Devices use it to join the domain."
    var administratorPassword = ""
    /// `ldap server require strong auth = no`, so lab NAC boxes can do a simple bind.
    var allowSimpleBind = true
    /// Where unknown names are forwarded, so a joined device keeps working internet.
    var dnsForwarder = "1.1.1.1"
    var memoryMB = 768
    var cpus = 2

    /// The DC's fully-qualified name. This is **not** what goes in Windows' "Domain" field —
    /// that wants `realm`. Getting those two the wrong way round is the single most common
    /// join failure, so the UI labels them apart.
    var dcFQDN: String { "\(dcHostname).\(realm)" }

    /// `dc=lab,dc=sheep`
    var baseDN: String {
        realm.split(separator: ".").map { "dc=\($0)" }.joined(separator: ",")
    }

    /// Everything the app manages lives under here. Objects outside it — the built-in
    /// containers, machine accounts created by a join, anything the user made by hand — are
    /// never touched by a sync.
    var managedRootRDN = "SheepRadius"
    var managedRootDN: String { "OU=\(managedRootRDN),\(baseDN)" }

    /// The ports the container publishes. 53 is deliberately absent: macOS's vmnet DNS proxy
    /// takes it the moment the first container starts, so the app binds it itself, first.
    static let tcpPorts = [88, 135, 389, 445, 464, 636, 3268, 3269]
    static let udpPorts = [88, 123, 389, 464]
    /// Keep Samba's dynamic RPC endpoints below macOS's ephemeral range (49152–65535).
    /// `rapportd` commonly listens on 49152 for Continuity/AirPlay, which made an otherwise
    /// clean start fail inside `container run` with only "Address already in use".
    static let rpcPorts = Array(40000...40020)
    static let rpcPortRange = "\(rpcPorts.first!)-\(rpcPorts.last!)"
    /// Checked for a conflict before starting, and listed in the failure message.
    static var allPorts: [(port: Int, proto: String)] {
        tcpPorts.map { ($0, "TCP") }
            + rpcPorts.map { ($0, "TCP") }
            + udpPorts.map { ($0, "UDP") }
            + [(53, "UDP"), (53, "TCP")]
    }

    enum CodingKeys: String, CodingKey {
        case realm, netbiosDomain, dcHostname, administratorPassword, allowSimpleBind
        case dnsForwarder, memoryMB, cpus, managedRootRDN
    }

    init() {}

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ADSettings()
        realm = try c.decodeIfPresent(String.self, forKey: .realm) ?? d.realm
        netbiosDomain = try c.decodeIfPresent(String.self, forKey: .netbiosDomain) ?? d.netbiosDomain
        dcHostname = try c.decodeIfPresent(String.self, forKey: .dcHostname) ?? d.dcHostname
        administratorPassword = try c.decodeIfPresent(String.self, forKey: .administratorPassword) ?? d.administratorPassword
        allowSimpleBind = try c.decodeIfPresent(Bool.self, forKey: .allowSimpleBind) ?? d.allowSimpleBind
        dnsForwarder = try c.decodeIfPresent(String.self, forKey: .dnsForwarder) ?? d.dnsForwarder
        memoryMB = try c.decodeIfPresent(Int.self, forKey: .memoryMB) ?? d.memoryMB
        cpus = try c.decodeIfPresent(Int.self, forKey: .cpus) ?? d.cpus
        managedRootRDN = try c.decodeIfPresent(String.self, forKey: .managedRootRDN) ?? d.managedRootRDN
    }

    /// An AD-complexity password that also survives being pasted into a Windows dialog.
    static func generatedPassword() -> String {
        let words = ["Sheep", "Lab", "Radius", "Meadow", "Fleece", "Pasture"]
        let symbols = "!@#$%&*"
        let word = words.randomElement() ?? "Sheep"
        let other = words.filter { $0 != word }.randomElement() ?? "Lab"
        let number = Int.random(in: 1000...9999)
        let symbol = symbols.randomElement() ?? "!"
        return "\(word)-\(other)-\(number)\(symbol)"
    }

    /// **The shape of the lab domain, checked in both backends** (build 24).
    ///
    /// It was only ever the AD realm's rule, and AD mode was the only place it was checked.
    /// From build 24 the same name is the OpenLDAP base DN as well (`LabSettings.labDomain`),
    /// so a lab on OpenLDAP that types `LAB` or `lab.local` has to hear about it there too —
    /// otherwise the fault appears the day somebody switches backend, which is the one day
    /// nobody is looking for a typing mistake.
    ///
    /// `who` names the field in the sentence, because the two panes label it differently.
    static func domainProblems(_ domain: String, who: String = "The lab domain") -> [String] {
        let labels = domain.split(separator: ".").map(String.init)
        if domain.isEmpty {
            return ["\(who) cannot be empty."]
        } else if labels.count < 2 {
            return ["\(who) must have at least two labels, like lab.sheep — a single-label name breaks Kerberos discovery."]
        } else if labels.last?.lowercased() == "local" {
            // Bonjour owns .local; a DC there is never found reliably on macOS.
            return ["\(who) cannot end in .local: macOS resolves .local through mDNS (Bonjour), so a domain there is unreachable. Use something like lab.sheep."]
        } else if domain != domain.lowercased() {
            return ["\(who) must be lower-case."]
        } else if labels.contains(where: { !Validation.isDNSLabel($0) }) {
            return ["Each part of \(who.lowercased()) may only contain letters, digits and hyphens, and may not start or end with one."]
        }
        return []
    }

    var problems: [String] {
        var out = Self.domainProblems(realm, who: "The realm")

        if netbiosDomain.isEmpty {
            out.append("The NetBIOS domain cannot be empty.")
        } else if netbiosDomain.count > 15 {
            out.append("The NetBIOS domain must be 15 characters or fewer.")
        } else if netbiosDomain != netbiosDomain.uppercased()
                    || netbiosDomain.contains(where: { !$0.isLetter && !$0.isNumber && $0 != "-" }) {
            out.append("The NetBIOS domain must be upper-case letters, digits and hyphens.")
        }

        if !Validation.isDNSLabel(dcHostname) {
            out.append("The DC hostname may only contain letters, digits and hyphens.")
        }
        if administratorPassword.isEmpty {
            out.append(Self.missingPasswordMessage)
        }
        if !Validation.isValidName(managedRootRDN) {
            out.append("The managed OU name \(Validation.nameRule)")
        }
        return out
    }

    /// The variables that must never reach `argv`: the domain Administrator password, and the
    /// domain controller's TLS **private key**.
    ///
    /// `-e KEY=VALUE` is an argument to the host-side `container` CLI, so every one of these
    /// used to be readable by any local account for the whole of `container run` — a `ps` away
    /// from the credential that joins machines to the domain, and from the private key that
    /// `certs/ad.key` is kept at 0600 to protect. They go through `--env-file` instead, which
    /// is an ordinary file this app writes at 0600 inside the lab folder.
    static func isSecretEnvironmentKey(_ key: String) -> Bool {
        key == "ADMIN_PASSWORD" || key.hasSuffix("_B64")
    }

    /// The `--env-file` body: `KEY=VALUE`, one per line, sorted so it is reproducible.
    /// Values are a password and base64 PEM — neither can contain a newline, which is the only
    /// character this format cannot carry.
    func environmentFile(extraEnvironment: [String: String] = [:]) -> String {
        var pairs = ["ADMIN_PASSWORD": administratorPassword]
        for (key, value) in extraEnvironment where Self.isSecretEnvironmentKey(key) { pairs[key] = value }
        return pairs.keys.sorted().map { "\($0)=\(pairs[$0] ?? "")" }.joined(separator: "\n") + "\n"
    }

    /// `container run` arguments, in the order the prototype proved. Pure, so the publish
    /// list is unit-testable without a container anywhere near.
    ///
    /// `extraEnvironment` carries the TLS material (base64 PEM) when LDAPS is on. It travels
    /// as an environment variable rather than a mount because a virtiofs bind mount of a
    /// macOS folder is case-insensitive, and the whole reason this DC lives on a named ext4
    /// volume is that Samba cannot survive that.
    ///
    /// `envFile` is where `environmentFile(extraEnvironment:)` was written. Everything secret
    /// goes there; what stays on the command line is the realm, the NetBIOS name, the host
    /// address and the port range — all of them things `container ls` would show anyway.
    func containerArguments(image: String, name: String, volume: String, hostIP: String,
                            extraEnvironment: [String: String] = [:],
                            envFile: String? = nil) -> [String] {
        var out = ["run", "-d", "--name", name,
                   "--memory", "\(memoryMB)M", "--cpus", "\(cpus)",
                   // Provisioning writes security.* xattrs; the default cap set cannot.
                   "--cap-add", "CAP_SYS_ADMIN",
                   "-v", "\(volume):/var/lib/samba",
                   "-e", "REALM=\(realm.uppercased())",
                   "-e", "DOMAIN=\(netbiosDomain)",
                   "-e", "DCNAME=\(dcHostname)",
                   "-e", "HOST_IP=\(hostIP)",
                   "-e", "DNS_FORWARDER=\(dnsForwarder)",
                   "-e", "RPC_PORT_RANGE=\(Self.rpcPortRange)",
                   "-e", "REQUIRE_STRONG_AUTH=\(allowSimpleBind ? "no" : "yes")"]
        if let envFile {
            out += ["--env-file", envFile]
        } else {
            // No file to put them in (the unit tests' pure form) — the image still has to be
            // given what it needs, so this is the old shape, secrets and all.
            out += ["-e", "ADMIN_PASSWORD=\(administratorPassword)"]
        }
        for key in extraEnvironment.keys.sorted() where envFile == nil || !Self.isSecretEnvironmentKey(key) {
            out += ["-e", "\(key)=\(extraEnvironment[key] ?? "")"]
        }
        for port in Self.tcpPorts { out += ["-p", "\(port):\(port)"] }
        for port in Self.udpPorts { out += ["-p", "\(port):\(port)/udp"] }
        out += ["-p", "\(Self.rpcPortRange):\(Self.rpcPortRange)"]
        out.append(image)
        return out
    }
}

/// Samba AD is configured as one root domain in SheepRadius. Forest child-domain
/// provisioning is intentionally not exposed because upstream Samba does not provide
/// a working `SUBDOMAIN` join flow.


// MARK: - Why a sync did not start

/// `Sync now` used to return silently when the DC was not running or a sync was already in
/// flight, which is indistinguishable from "it ran and did nothing". Every refusal now has a
/// sentence, and the sentence is built here so the test suite can pin it without a container.
nonisolated enum ADSyncGate {
    /// nil when the sync may run; otherwise the line to put in the sync log, and the tooltip.
    ///
    /// **The third refusal went in build 21.** `hasUnappliedChanges` compared `doc.users`,
    /// `doc.groups` and `doc.ous` against `applied`, from when those were the directory and a
    /// sync copied them into it. They are the read-only seed now and nothing writes them, so
    /// the comparison could only ever be false — a refusal that can never fire is a sentence
    /// in the code that lies about what the app does.
    static func refusal(isRunning: Bool, syncing: Bool) -> String? {
        if !isRunning {
            return "Nothing to sync: the domain controller is not running. Start it under Directory ▸ Server first."
        }
        if syncing {
            return "A sync is already running. This one was not started — the log below is still filling in."
        }
        return nil
    }
}

// MARK: - Reconciling the app's table into AD

/// One object as it exists in the directory right now.
nonisolated struct ADObject: Sendable, Equatable {
    enum Kind: String, Sendable { case user, group, organizationalUnit }
    var kind: Kind
    var dn: String
    var sAMAccountName: String?
    var displayName: String?
    var description: String?
    /// nil when unknown (an OU has none).
    var enabled: Bool?
    var memberOf: [String] = []
}

/// A single change the sync will make. Deliberately descriptive rather than a command
/// string: the planner is pure and unit-tested, and the runner turns these into
/// `samba-tool` invocations.
nonisolated enum ADOperation: Sendable, Equatable {
    case createOU(path: String)
    case createUser(username: String, ou: String, displayName: String, password: String)
    case moveUser(username: String, toOU: String)
    case setDisplayName(username: String, to: String)
    case setEnabled(username: String, to: Bool)
    case setPassword(username: String)
    case createGroup(name: String, description: String)
    case setGroupDescription(name: String, to: String)
    case addMember(group: String, user: String)
    case removeMember(group: String, user: String)
    case deleteUser(username: String)
    case deleteGroup(name: String)
    case deleteOU(path: String)
    /// A name the app wants is already taken by an object **outside** the managed root.
    /// Never resolved automatically — the sync log offers to adopt it.
    case collision(username: String, existingDN: String)
    /// The same for a **group**, and it is a separate case because the consequence is
    /// different in kind. A colliding user is a name the app cannot have; a colliding group is
    /// a group the app would otherwise put real users into — `sAMAccountName` is unique
    /// domain-wide, so `samba-tool group addmembers Guests alice` silently resolves AD's
    /// built-in `CN=Guests,CN=Builtin` and succeeds. Never adoptable: the fix is to rename the
    /// group in this app. See `ADProtectedObject.groupNames`.
    case groupCollision(name: String, existingDN: String)

    /// One line for the sync log.
    var summary: String {
        switch self {
        case .createOU(let path): "create OU \(path)"
        case .createUser(let u, let ou, _, _): "create user \(u) in \(ou)"
        case .moveUser(let u, let ou): "move \(u) to \(ou)"
        case .setDisplayName(let u, let v): "set displayName of \(u) to \(v)"
        case .setEnabled(let u, let v): "\(v ? "enable" : "disable") \(u)"
        case .setPassword(let u): "set password of \(u)"
        case .createGroup(let g, _): "create group \(g)"
        case .setGroupDescription(let g, _): "set description of \(g)"
        case .addMember(let g, let u): "add \(u) to \(g)"
        case .removeMember(let g, let u): "remove \(u) from \(g)"
        case .deleteUser(let u): "delete user \(u)"
        case .deleteGroup(let g): "delete group \(g)"
        case .deleteOU(let path): "delete OU \(path)"
        case .collision(let u, let dn): "\(u) already exists outside the managed OU at \(dn)"
        case .groupCollision(let g, let dn): "group \(g) already exists outside the managed OU at \(dn)"
        }
    }

    var isDestructive: Bool {
        switch self {
        case .deleteUser, .deleteGroup, .deleteOU, .removeMember: true
        default: false
        }
    }
}

/// Turns "what the app's table says" plus "what AD currently holds" into an ordered list of
/// changes, **restricted to the managed root**.
///
/// The restriction is the whole safety story: the DC may also hold built-in containers,
/// machine accounts created by real domain joins, and objects the user made by hand. None of
/// them are under `OU=SheepRadius`, so none of them can be deleted by a sync, however wrong
/// the app's table is.
nonisolated enum ADPlan {
    /// `existing` is every object the sync is allowed to consider — typically the managed
    /// subtree plus a shallow read of the rest, so collisions can be spotted.
    static func make(doc: LabDocument, existing: [ADObject], settings: ADSettings) -> [ADOperation] {
        let root = settings.managedRootDN.lowercased()
        func isManaged(_ dn: String) -> Bool {
            dn.lowercased().hasSuffix(root.lowercased()) && dn.lowercased() != root
        }

        var out: [ADOperation] = []
        let active = doc.users.filter { !$0.username.isEmpty }
        let wantedGroups = doc.groups.filter { !$0.name.isEmpty }

        // 1. OUs, parents first, so a user can be created straight into one.
        let managedOUs = existing.filter { $0.kind == .organizationalUnit && isManaged($0.dn) }
        let existingOUPaths = Set(managedOUs.compactMap { ouPath(of: $0.dn, under: settings.managedRootDN)?.lowercased() })
        for path in doc.ouPaths where !existingOUPaths.contains(path.lowercased()) {
            out.append(.createOU(path: path))
        }

        // 2. Groups.
        //
        // **A group the app does not own is not merely skipped — it is taken out of the plan
        // entirely** (build 15). `sAMAccountName` is unique across the whole domain, so every
        // group operation the runner performs resolves by name: if the app wants `Guests` and
        // AD's built-in `CN=Guests,CN=Builtin` exists, skipping the create and going on to the
        // membership step means writing real users into the built-in group. That happened on
        // the owner's live domain on 18 Sep 2026 and left `alice` a member of BUILTIN\Guests
        // and of nothing else.
        //
        // `ownedGroups` is therefore the *only* set step 4 and step 5 may look at.
        let existingGroups = existing.filter { $0.kind == .group }
        var ownedGroups: [LabGroup] = []
        for group in wantedGroups {
            let match = existingGroups.first { sameName($0.sAMAccountName ?? cn(of: $0.dn), group.name) }
            // The name test comes first and does not need `match`: a well-known group may sit
            // in a part of the directory this read never covered, and finding out by writing to
            // it is exactly the failure mode being fixed.
            if ADProtectedObject.isProtectedGroup(name: group.name, dn: match?.dn ?? "") {
                out.append(.groupCollision(name: group.name,
                                           existingDN: match?.dn ?? wellKnownDN(group.name, settings: settings)))
                continue
            }
            guard let match else {
                out.append(.createGroup(name: group.name, description: group.description))
                ownedGroups.append(group)
                continue
            }
            guard isManaged(match.dn) else {
                // Somebody's own group, under a name the app wants. Reported, never written to.
                out.append(.groupCollision(name: group.name, existingDN: match.dn))
                continue
            }
            if (match.description ?? "") != group.description {
                out.append(.setGroupDescription(name: group.name, to: group.description))
            }
            ownedGroups.append(group)
        }

        // 3. Users.
        let existingUsers = existing.filter { $0.kind == .user }
        for user in active {
            let match = existingUsers.first { sameName($0.sAMAccountName, user.username) }
            guard let match else {
                out.append(.createUser(username: user.username, ou: user.effectiveOU,
                                       displayName: user.displayName.isEmpty ? user.username : user.displayName,
                                       password: user.password))
                continue
            }
            guard isManaged(match.dn) else {
                // Taken by something the app does not own — report, never overwrite.
                out.append(.collision(username: user.username, existingDN: match.dn))
                continue
            }
            let wantedOU = user.effectiveOU
            if let currentOU = ouPath(of: parentDN(of: match.dn), under: settings.managedRootDN),
               !OUPath.isSame(currentOU, wantedOU) {
                out.append(.moveUser(username: user.username, toOU: wantedOU))
            }
            let wantedDisplay = user.displayName.isEmpty ? user.username : user.displayName
            if (match.displayName ?? "") != wantedDisplay {
                out.append(.setDisplayName(username: user.username, to: wantedDisplay))
            }
            if match.enabled != user.enabled {
                out.append(.setEnabled(username: user.username, to: user.enabled))
            }
            // The app's table is the source of truth for passwords and AD will not tell us
            // what the current one is, so it is written on every sync.
            out.append(.setPassword(username: user.username))
        }

        // 4. Membership — **`ownedGroups` only**, never `wantedGroups`.
        //
        // This loop is where the 18 Sep 2026 damage was done. A group the planner refused to
        // create is not a group whose membership can be reconciled: the runner's
        // `samba-tool group addmembers <name> <user>` has no DN in it, so it lands wherever
        // that name resolves. No owned group, no membership operation, in either direction.
        for group in ownedGroups {
            let wanted = Set(active.filter { $0.groups.contains(group.id) }.map { $0.username.lowercased() })
            let current = Set(existingUsers
                .filter { user in user.memberOf.contains { sameName(cn(of: $0), group.name) } }
                .compactMap { $0.sAMAccountName?.lowercased() })
            for username in wanted.subtracting(current).sorted() {
                out.append(.addMember(group: group.name, user: username))
            }
            for username in current.subtracting(wanted).sorted() {
                out.append(.removeMember(group: group.name, user: username))
            }
        }

        // 5. Remove what the app used to own and no longer lists — managed root only.
        // Every delete the runner performs names an object rather than a DN — `samba-tool user
        // delete <name>` — so a protected name is never emitted here either, even for an object
        // that really is sitting inside the managed root. Being *in* our OU does not make the
        // command that removes it unambiguous.
        let wantedUsernames = Set(active.map { $0.username.lowercased() })
        for object in existingUsers where isManaged(object.dn) {
            guard let name = object.sAMAccountName?.lowercased(), !wantedUsernames.contains(name) else { continue }
            guard !ADProtectedObject.names.contains(name) else { continue }
            out.append(.deleteUser(username: name))
        }
        let wantedGroupNames = Set(wantedGroups.map { $0.name.lowercased() })
        for object in existingGroups where isManaged(object.dn) {
            let name = (object.sAMAccountName ?? cn(of: object.dn)).lowercased()
            guard !wantedGroupNames.contains(name) else { continue }
            guard !ADProtectedObject.isProtectedGroup(name: name) else { continue }
            out.append(.deleteGroup(name: name))
        }
        // Deepest first, so a parent is only removed once its children are gone.
        let wantedOUPaths = Set(doc.ouPaths.map { $0.lowercased() })
        let removableOUs = managedOUs
            .compactMap { ouPath(of: $0.dn, under: settings.managedRootDN) }
            .filter { !wantedOUPaths.contains($0.lowercased()) }
            .sorted { OUPath.depth($0) > OUPath.depth($1) }
        for path in removableOUs { out.append(.deleteOU(path: path)) }

        return out
    }

    // MARK: DN helpers

    /// Where a well-known group of that name lives when the directory read did not cover it.
    /// Only ever used to make the collision message name a place a person can go and look.
    static func wellKnownDN(_ name: String, settings: ADSettings) -> String {
        "CN=\(name),CN=Builtin,\(settings.baseDN)"
    }

    static func cn(of dn: String) -> String {
        guard let first = dn.split(separator: ",").first else { return dn }
        let pieces = first.split(separator: "=", maxSplits: 1)
        return pieces.count == 2 ? String(pieces[1]) : String(first)
    }

    static func parentDN(of dn: String) -> String {
        dn.split(separator: ",").dropFirst().joined(separator: ",")
    }

    /// `OU=IT,OU=Staff,OU=SheepRadius,dc=lab,dc=sheep` → `Staff/IT`, i.e. back to the app's
    /// own path form. nil when the DN is not under the managed root.
    static func ouPath(of dn: String, under root: String) -> String? {
        let lower = dn.lowercased(), rootLower = root.lowercased()
        if lower == rootLower { return "" }
        guard lower.hasSuffix("," + rootLower) else { return nil }
        let head = String(dn.dropLast(root.count + 1))
        let segments = head.split(separator: ",").compactMap { piece -> String? in
            let parts = piece.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, parts[0].lowercased() == "ou" else { return nil }
            return String(parts[1])
        }
        guard !segments.isEmpty else { return nil }
        // DNs run leaf-first; the app's paths run root-first.
        return segments.reversed().joined(separator: "/")
    }

    /// `Staff/IT` → `OU=IT,OU=Staff,OU=SheepRadius,dc=lab,dc=sheep`
    static func dn(forOU path: String, settings: ADSettings) -> String {
        let segments = OUPath.segments(path)
        guard !segments.isEmpty else { return settings.managedRootDN }
        return segments.reversed().map { "OU=\($0)" }.joined(separator: ",") + "," + settings.managedRootDN
    }

    private static func sameName(_ a: String?, _ b: String) -> Bool {
        guard let a else { return false }
        return a.caseInsensitiveCompare(b) == .orderedSame
    }
}

// MARK: - DNS hygiene

/// After the Mac changes network the DC must advertise the **new** LAN address and nothing
/// else. A leftover bridge address (192.168.64.x) or an IPv6 ULA is worse than useless: a
/// LAN client that gets one cannot reach the DC and the join fails with a message that does
/// not mention DNS at all. This is exactly what happened to `gc._msdcs` during the live test.
nonisolated enum ADDNSHygiene {
    /// Every DC-owned name whose address must equal the Mac's LAN IP.
    static func repointedNames(dcHostname: String) -> [String] {
        ["@", dcHostname.lowercased(), "gc._msdcs", "DomainDnsZones", "ForestDnsZones"]
    }

    /// The names a join actually looks up, for the self-test.
    static func joinCriticalRecords(realm: String, dcHostname: String) -> [(name: String, type: String)] {
        let r = realm.lowercased()
        return [
            ("\(r)", "A"),
            ("\(dcHostname.lowercased()).\(r)", "A"),
            ("gc._msdcs.\(r)", "A"),
            ("_ldap._tcp.\(r)", "SRV"),
            ("_ldap._tcp.dc._msdcs.\(r)", "SRV"),
            ("_kerberos._tcp.\(r)", "SRV"),
            ("_kerberos._udp.\(r)", "SRV"),
            ("_kpasswd._tcp.\(r)", "SRV"),
            ("_gc._tcp.\(r)", "SRV"),
            ("_ldap._tcp.pdc._msdcs.\(r)", "SRV"),
        ]
    }

    /// An address that must never be handed to a LAN client: the container bridge, any other
    /// private container range, or an IPv6 ULA / link-local.
    static func isUnreachableFromLAN(_ address: String) -> Bool {
        let a = address.trimmingCharacters(in: .whitespaces).lowercased()
        if a.hasPrefix("192.168.64.") { return true }        // the vmnet bridge
        if a.hasPrefix("fd") || a.hasPrefix("fe80:") { return true }  // ULA / link-local
        if a.hasPrefix("::") { return true }
        return false
    }

    /// One address record out of a `samba-tool dns query … ALL` dump.
    nonisolated struct ZoneRecord: Equatable, Sendable {
        var type: String
        var value: String
    }

    /// The A and AAAA values in such a dump.
    ///
    /// Anchored on the start of the trimmed line, and that is the whole point: the SOA line
    /// reads `SOA: serial=2, refresh=900, …`, which **contains the substring `A: `**. A naive
    /// search reported `serial=2,` as a stale address — a failing check pointing at a DNS
    /// record that does not exist, which is worse than no check at all.
    static func addresses(inZoneDump dump: String) -> [ZoneRecord] {
        var out: [ZoneRecord] = []
        for raw in dump.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let type: String
            if line.hasPrefix("AAAA: ") { type = "AAAA" }
            else if line.hasPrefix("A: ") { type = "A" }
            else { continue }
            let value = line.dropFirst(type.count + 2).split(separator: " ").first.map(String.init) ?? ""
            if !value.isEmpty { out.append(ZoneRecord(type: type, value: value)) }
        }
        return out
    }

    /// Addresses that are wrong for this Mac: unreachable ones, plus anything that is not the
    /// current LAN address. Used by the self-test and by the `ad` suite's zone walk.
    static func staleAddresses(in found: [String], hostIP: String) -> [String] {
        found.map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .filter { $0 != hostIP }
    }
}
