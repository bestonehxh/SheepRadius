import Foundation

// MARK: - LDIF → DirectorySnapshot

/// Turning what a backend printed into what the panes draw.
///
/// Pure and separate from the two executors on purpose: reading a directory is where the
/// mistakes are (a machine account that looks like a user, a group whose `member` values are
/// DNs and not names, an OU that is really AD's own container), and none of them need a
/// process to reproduce. The executors below are then only "run this argv and hand the output
/// to this function", which is the part that cannot be unit-tested and should therefore be as
/// close to empty as it can be made.
nonisolated enum DirectorySnapshotParser {

    /// `CN=alice,OU=Staff,DC=lab,DC=sheep` → `alice`. The value of the first RDN, unescaped
    /// enough for the names this app allows (`DirectoryNames.problem` refuses `,` `=` `+` `\`).
    static func rdnValue(of dn: String) -> String {
        let first = dn.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        guard let equals = first.firstIndex(of: "=") else { return String(first) }
        return String(first[first.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
    }

    private static func classes(_ record: [String: [String]]) -> Set<String> {
        Set(ADLDIF.all(record, "objectClass").map { $0.lowercased() })
    }

    /// A Samba domain, as `ADDirectoryCommands.readAll` prints it.
    ///
    /// **Machine accounts are not people.** Every joined PC has `objectClass: user` and a
    /// `sAMAccountName` ending in `$`; keeping it out of `users` prevents person-only fields
    /// and actions from being applied to it. Build 27 presents `computers` in its own table.
    ///
    /// **Build 24 keeps them, in `computers`.** They were dropped on the floor until now; a
    /// Windows PC doing machine authentication (`host/best.lab.sheep` inside PEAP-MSCHAPv2)
    /// was therefore rejected by a RADIUS server whose directory had the account all along.
    /// `ConfigGenerator` consumes them for machine authentication and the Users pane consumes
    /// them for its Computers node.
    static func activeDirectory(_ records: [[String: [String]]], baseDN: String,
                                netbiosDomain: String = "") -> DirectorySnapshot {
        var snapshot = DirectorySnapshot()
        snapshot.realm = baseDN.split(separator: ",")
            .compactMap { part -> String? in
                let piece = part.trimmingCharacters(in: .whitespaces)
                return piece.lowercased().hasPrefix("dc=") ? String(piece.dropFirst(3)) : nil
            }
            .joined(separator: ".")
        snapshot.netbiosDomain = netbiosDomain
        for record in records {
            guard let dn = ADLDIF.first(record, "dn"), !dn.isEmpty else { continue }
            let kinds = classes(record)
            if kinds.contains("organizationalunit") {
                let path = ADDirectoryCommands.ouPath(fromDN: dn, baseDN: baseDN)
                guard !path.isEmpty else { continue }
                snapshot.ous.append(DirectoryOU(
                    path: path, dn: dn,
                    isReadOnly: !ADDirectoryCommands.isEditable(dn: dn, baseDN: baseDN)))
                continue
            }
            if kinds.contains("group") {
                let name = ADLDIF.first(record, "sAMAccountName") ?? rdnValue(of: dn)
                guard !name.isEmpty else { continue }
                snapshot.groups.append(DirectoryGroup(
                    name: name,
                    description: ADLDIF.first(record, "description") ?? "",
                    members: ADLDIF.all(record, "member").map(rdnValue(of:)),
                    dn: dn,
                    isReadOnly: !DirectoryNames.isEditableGroup(
                        dn: dn, name: name, baseDN: baseDN)))
                continue
            }
            // A machine account, wherever it sits — `CN=Computers`, an OU somebody made, or
            // `OU=Domain Controllers` for the DC's own. The container is not part of the test:
            // `objectClass: computer` is.
            if kinds.contains("computer") {
                let name = ADLDIF.first(record, "sAMAccountName") ?? rdnValue(of: dn)
                guard !name.isEmpty else { continue }
                snapshot.computers.append(DirectoryComputer(
                    account: name, dn: dn,
                    enabled: ADAccountControl.isEnabled(ADLDIF.first(record, "userAccountControl")) ?? true,
                    isReadOnly: !DirectoryNames.isEditableComputer(dn: dn, baseDN: baseDN)))
                continue
            }
            if kinds.contains("user") {
                let name = ADLDIF.first(record, "sAMAccountName") ?? rdnValue(of: dn)
                // A `$` with no `objectClass: computer` is still not a person — a trust
                // account, or an object somebody made by hand. Neither belongs in Users.
                guard !name.isEmpty, !name.hasSuffix("$") else { continue }
                snapshot.users.append(DirectoryUser(
                    username: name,
                    displayName: ADLDIF.first(record, "displayName") ?? "",
                    ou: ADDirectoryCommands.userOU(fromDN: dn, baseDN: baseDN),
                    groups: ADLDIF.all(record, "memberOf").map(rdnValue(of:)).sorted(),
                    enabled: ADAccountControl.isEnabled(ADLDIF.first(record, "userAccountControl")) ?? true,
                    dn: dn,
                    isReadOnly: !DirectoryNames.isEditableUser(
                        dn: dn, name: name, baseDN: baseDN)))
            }
        }
        return sorted(snapshot)
    }

    /// The bundled slapd, as `OpenLDAPDirectoryCommands.readAll` prints it.
    ///
    /// `ou=groups` is the container the app puts groups in, not an OU a person made; it is
    /// dropped so the tree shows the same shape both backends do.
    static func openLDAP(_ records: [[String: [String]]], suffix: String,
                         groupsDN: String) -> DirectorySnapshot {
        var snapshot = DirectorySnapshot()
        let groupsContainer = groupsDN.lowercased()
        for record in records {
            guard let dn = ADLDIF.first(record, "dn"), !dn.isEmpty else { continue }
            let kinds = classes(record)

            if kinds.contains("organizationalunit") {
                guard dn.lowercased() != groupsContainer else { continue }
                let path = ADDirectoryCommands.ouPath(fromDN: dn, baseDN: suffix)
                guard !path.isEmpty else { continue }
                snapshot.ous.append(DirectoryOU(path: path, dn: dn))
                continue
            }
            if kinds.contains("groupofnames") {
                let name = ADLDIF.first(record, "cn") ?? rdnValue(of: dn)
                guard !name.isEmpty else { continue }
                // The admin DN is the placeholder `seedLDIF` puts in an otherwise empty group
                // (groupOfNames requires one `member`), so it is not a membership.
                let members = ADLDIF.all(record, "member")
                    .filter { $0.lowercased().hasPrefix("uid=") }
                    .map(rdnValue(of:))
                snapshot.groups.append(DirectoryGroup(
                    name: name,
                    description: ADLDIF.first(record, "description") ?? "",
                    members: members, dn: dn))
                continue
            }
            if kinds.contains("inetorgperson") {
                let name = ADLDIF.first(record, "uid") ?? rdnValue(of: dn)
                guard !name.isEmpty else { continue }
                snapshot.users.append(DirectoryUser(
                    username: name,
                    displayName: ADLDIF.first(record, "displayName") ?? "",
                    ou: ADDirectoryCommands.userOU(fromDN: dn, baseDN: suffix),
                    // `netusers` is generated, not a group anybody joined — it is every
                    // enabled user by definition, and listing it beside the real ones would
                    // make every user look like a member of something they cannot leave.
                    groups: ADLDIF.all(record, "memberOf").map(rdnValue(of:))
                        .filter { $0 != LabGroup.everyoneName }.sorted(),
                    dn: dn))
            }
        }
        return sorted(snapshot)
    }

    /// One order for both backends, so switching does not reshuffle the panes.
    static func sorted(_ snapshot: DirectorySnapshot) -> DirectorySnapshot {
        var out = snapshot
        out.users.sort { $0.username.localizedStandardCompare($1.username) == .orderedAscending }
        out.groups.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        out.ous.sort(by: { OUPath.orderedBefore($0.path, $1.path) })
        // Machine accounts are ordered too, so `authorize` is byte-identical between two reads
        // of an unchanged domain and a HUP is not scheduled for a reshuffle.
        out.computers.sort { $0.account.localizedStandardCompare($1.account) == .orderedAscending }
        out.takenAt = Date()
        return out
    }
}

// MARK: - A password that never reaches an argument vector

/// A 0600 file holding one password, deleted when the work is done.
///
/// `ldapadd`, `ldapmodify`, `ldapdelete`, `ldapmodrdn` and `ldappasswd` all take `-y` (bind)
/// and `-T` (new password) as *files* precisely so that nothing sensitive is in `argv`, where
/// `ps` would show it to every process on the Mac for as long as the call lasts.
nonisolated struct DirectoryPasswordFile: Sendable {
    let url: URL

    /// Nil when the lab folder cannot be written to — which the caller reports rather than
    /// falling back to putting the password in `argv`.
    init?(_ password: String, in directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(".dirpw-" + UUID().uuidString)
        guard FileManager.default.createFile(atPath: url.path, contents: Data(password.utf8),
                                             attributes: [.posixPermissions: 0o600])
        else { return nil }
        self.url = url
    }

    /// Always from a `defer`, so a thrown error takes the file with it.
    func remove() { try? FileManager.default.removeItem(at: url) }
}

// MARK: - Active Directory, live

/// `DirectoryProvider` over `container exec <dc> …`, running exactly the argv
/// `ADDirectoryCommands` builds.
///
/// It is an actor rather than a part of `ADController` so that a directory read does not go
/// through the main actor: a snapshot of a forty-user domain is one `ldbsearch` and several
/// hundred milliseconds, and the panes ask for it every thirty seconds.
actor ADDirectory: DirectoryProvider {
    private let containerTool: String?
    private let containerName: String
    private let baseDN: String
    /// The short domain name, for the `LABSHEEP\\DC1$` form of a machine identity. It is not
    /// derivable from the base DN — AD stores it in the domain object, and this app has it in
    /// the settings already.
    private let netbiosDomain: String
    private let running: Bool

    init(containerTool: String?, containerName: String, baseDN: String,
         netbiosDomain: String = "", running: Bool) {
        self.containerTool = containerTool
        self.containerName = containerName
        self.baseDN = baseDN
        self.netbiosDomain = netbiosDomain
        self.running = running
    }

    nonisolated let label = "Samba AD"
    nonisolated var isAvailable: Bool { running && containerTool != nil }
    nonisolated var supportsDisable: Bool { true }

    /// `-i` **before** the container id when there is stdin to send, exactly as
    /// `ADDirectoryCommands.setPasswordArguments` does: without it `container exec` gives the
    /// child /dev/null and the payload silently becomes empty.
    private func exec(_ argv: [String], input: String? = nil) async throws -> String {
        guard let containerTool, running else {
            throw DirectoryError.notRunning("The domain controller is not running.")
        }
        let head = input == nil ? ["exec", containerName] : ["exec", "-i", containerName]
        let result = await Shell.run(containerTool, head + argv, input: input, environment: [:])
        guard result.ok else { throw DirectoryErrorMap.map(result.output) }
        return result.output
    }

    private func run(_ argv: [String], subject: String) async throws {
        guard let containerTool, running else {
            throw DirectoryError.notRunning("The domain controller is not running.")
        }
        let result = await Shell.run(containerTool, ["exec", containerName] + argv, environment: [:])
        guard result.ok else { throw DirectoryErrorMap.map(result.output, subject: subject) }
    }

    func snapshot() async throws -> DirectorySnapshot {
        let output = try await exec(ADDirectoryCommands.readAll(baseDN: baseDN))
        return DirectorySnapshotParser.activeDirectory(ADLDIF.parse(output), baseDN: baseDN,
                                                       netbiosDomain: netbiosDomain)
    }

    func createUser(_ username: String, displayName: String, ou: String, password: String) async throws {
        if let problem = DirectoryNames.problem(with: username, kind: .user) {
            throw DirectoryError.builtIn(problem)
        }
        // `--userou` will not make the container, so the chain has to exist first.
        if !OUPath.normalized(ou).isEmpty { try? await createOU(ou) }
        try await run(ADDirectoryCommands.createUser(username, ou: ou, baseDN: baseDN), subject: username)
        // samba-tool had no container to put it in, so it used its own default. Move it to
        // where the person asked for it — the top level under the domain.
        if ADDirectoryCommands.userNeedsMoveUp(ou: ou, baseDN: baseDN) {
            try await run(ADDirectoryCommands.moveUser(username, toOU: ou, baseDN: baseDN),
                          subject: username)
        }
        // `--random-password` at create, the real one straight after and through stdin: it is
        // never in argv, and a create that fails leaves nothing half-made behind.
        try await setPassword(username, to: password)
        if !displayName.isEmpty { try await setDisplayName(username, to: displayName) }
    }

    func setPassword(_ username: String, to password: String) async throws {
        guard let containerTool, running else {
            throw DirectoryError.notRunning("The domain controller is not running.")
        }
        let result = await Shell.run(
            containerTool,
            ADDirectoryCommands.setPasswordArguments(container: containerName, username: username),
            input: password + "\n", environment: [:])
        guard result.ok else { throw DirectoryErrorMap.map(result.output, subject: username) }
    }

    func setDisplayName(_ username: String, to displayName: String) async throws {
        if let problem = DirectoryNames.valueProblem(displayName, what: "A display name",
                                                     limit: Validation.maxDisplayNameLength) {
            throw DirectoryError.refused(problem)
        }
        // samba-tool has no `user setdisplayname`, so this is the one AD edit that goes in as
        // LDIF through ldbmodify — the same modify the tool would do, with the DN resolved
        // from the snapshot rather than guessed.
        let dn = try await dn(ofUser: username)
        let ldif = displayName.isEmpty
            ? LDIFValue.row("dn", dn) + "changetype: modify\ndelete: displayName\n"
            : LDIFValue.row("dn", dn) + "changetype: modify\nreplace: displayName\n"
                + LDIFValue.row("displayName", displayName)
        _ = try await exec(["ldbmodify", "-H", ADCommands.sambaDatabase], input: ldif)
    }

    func setEnabled(_ username: String, to enabled: Bool) async throws {
        try await run(ADDirectoryCommands.setEnabled(username, enabled), subject: username)
    }

    func moveUser(_ username: String, toOU ou: String) async throws {
        if !OUPath.normalized(ou).isEmpty { try? await createOU(ou) }
        try await run(ADDirectoryCommands.moveUser(username, toOU: ou, baseDN: baseDN), subject: username)
    }

    func renameUser(_ username: String, to newName: String) async throws {
        if let problem = DirectoryNames.problem(with: newName, kind: .user) {
            throw DirectoryError.builtIn(problem)
        }
        // Asked before the rename rather than left to the tool (build 20, audit N-12), so the
        // message is `createUser`'s and not a samba-tool traceback — and so the two places a
        // name can be taken, this app's own panes and the domain, give the same sentence.
        try await refuseIfTaken(newName, other: username)
        try await run(ADDirectoryCommands.renameUser(username, to: newName), subject: newName)
    }

    /// Is some **other** account already called this?
    private func refuseIfTaken(_ newName: String, other username: String) async throws {
        let taken = try await snapshot().users.contains {
            $0.username.caseInsensitiveCompare(newName) == .orderedSame
                && $0.username.caseInsensitiveCompare(username) != .orderedSame
        }
        if taken { throw DirectoryError.nameTaken("“\(newName)” already exists.") }
    }

    func deleteUser(_ username: String) async throws {
        try await run(ADDirectoryCommands.deleteUser(username), subject: username)
    }

    func createGroup(_ name: String, description: String) async throws {
        if let problem = DirectoryNames.problem(with: name, kind: .group) {
            throw DirectoryError.builtIn(problem)
        }
        if let problem = DirectoryNames.valueProblem(description, what: "A description",
                                                     limit: Validation.maxDescriptionLength) {
            throw DirectoryError.refused(problem)
        }
        // At the top level under the domain there is no container for `--groupou` to name, so
        // the entry goes in as LDIF. See `ADDirectoryCommands.createGroup`.
        if ADDirectoryCommands.groupNeedsLDIF(ou: "", baseDN: baseDN) {
            _ = try await exec(["ldbadd", "-H", ADCommands.sambaDatabase],
                               input: ADDirectoryCommands.createGroupLDIF(name, baseDN: baseDN,
                                                                          description: description))
        } else {
            try await run(ADDirectoryCommands.createGroup(name, ou: "", baseDN: baseDN,
                                                          description: description), subject: name)
        }
    }

    func deleteGroup(_ name: String) async throws {
        if let problem = DirectoryNames.problem(with: name, kind: .group) {
            throw DirectoryError.builtIn(problem)
        }
        // The memberships go with the entry: `member` lives **on the group**, and every
        // member's `memberOf` is computed from it by the DC. So a delete drops the membership
        // by construction — there is nothing to retract first, and the snapshot taken straight
        // afterwards is what proves it (`run_ad_directory_probe_checks`).
        try await run(ADDirectoryCommands.deleteGroup(name), subject: name)
    }

    func setMembership(of username: String, groups: [String]) async throws {
        let current = Set(try await snapshot().users
            .first { $0.username.caseInsensitiveCompare(username) == .orderedSame }?
            .groups.map { $0.lowercased() } ?? [])
        let wanted = Set(groups.map { $0.lowercased() })
        for name in groups where !current.contains(name.lowercased()) {
            if let problem = DirectoryNames.problem(with: name, kind: .group) {
                throw DirectoryError.builtIn(problem)
            }
            try await run(ADDirectoryCommands.addMember(username, to: name), subject: name)
        }
        for name in current.subtracting(wanted) {
            // Only groups this app may own: a membership AD gave the account itself
            // (`Domain Users`) is not ours to take away.
            guard DirectoryNames.problem(with: name, kind: .group) == nil else { continue }
            try await run(ADDirectoryCommands.removeMember(username, from: name), subject: name)
        }
    }

    /// `samba-tool ou create` makes **one** container, so the chain above it is made here —
    /// the same rule as the OpenLDAP side: an ancestor that is already there is success, the
    /// leaf that is already there is not.
    func createOU(_ path: String) async throws {
        let steps = OUPath.selfAndAncestors(of: OUPath.normalized(path))
        guard let leaf = steps.last else { return }
        for step in steps.dropLast() { try? await run(ADDirectoryCommands.createOU(step, baseDN: baseDN), subject: step) }
        try await run(ADDirectoryCommands.createOU(leaf, baseDN: baseDN), subject: leaf)
    }

    func renameOU(_ path: String, to newLeaf: String) async throws {
        try await run(ADDirectoryCommands.renameOU(path, to: newLeaf, baseDN: baseDN), subject: path)
    }

    func moveOU(_ path: String, under parent: String) async throws {
        try await run(ADDirectoryCommands.moveOU(path, under: parent, baseDN: baseDN), subject: path)
    }

    /// **The accounts move out, then the container goes** (build 21 — see `DirectoryDeletion`).
    ///
    /// `samba-tool ou delete` refuses a container that still has anything in it, so before this
    /// an OU with users in it simply could not be deleted and the menu item answered with a
    /// traceback. Moving them to `people` first is what ADUC's own delete leaves a person with
    /// and what the OpenLDAP side now does, so "delete this OU" means the same thing in both.
    func deleteOU(_ path: String) async throws {
        let refuge = DirectoryDeletion.refuge(fromOU: path)
        for username in DirectoryDeletion.usersToRelocate(in: try await snapshot(), deletingOU: path) {
            try await moveUser(username, toOU: refuge)
        }
        try await run(ADDirectoryCommands.deleteOU(path, baseDN: baseDN), subject: path)
    }

    func ntHash(of username: String) async throws -> String? {
        let output = try await exec(ADDirectoryCommands.getPassword(username))
        return ADDirectoryCommands.ntHash(inLDIF: output)
    }

    private func dn(ofUser username: String) async throws -> String {
        guard let match = try await snapshot().users
            .first(where: { $0.username.caseInsensitiveCompare(username) == .orderedSame })
        else { throw DirectoryError.notFound("“\(username)” is not in the directory.") }
        return match.dn
    }
}

// MARK: - OpenLDAP, live

/// `DirectoryProvider` over the bundled `ldapadd` / `ldapmodify` / `ldapdelete` /
/// `ldapmodrdn` / `ldappasswd`, against the **running** slapd.
///
/// Nothing here restarts the server: until build 16 every Apply wiped `ldap/data` and re-ran
/// `slapadd`, so a display-name change emptied the directory for a moment. Only the three
/// startup-time settings still restart it, and `OpenLDAPRestart.reason` names them.
actor OpenLDAPDirectory: DirectoryProvider {
    private let tools: Toolchain
    private let settings: LabSettings
    private let workDirectory: URL
    private let running: Bool

    init(tools: Toolchain, settings: LabSettings, workDirectory: URL, running: Bool) {
        self.tools = tools
        self.settings = settings
        self.workDirectory = workDirectory
        self.running = running
    }

    nonisolated var label: String { "OpenLDAP (\(settings.ldapSuffix))" }
    nonisolated var isAvailable: Bool { running && tools.ldapWriteReady && tools.ldapsearch != nil }
    nonisolated var supportsDisable: Bool { false }

    private var uri: String { OpenLDAPDirectoryCommands.preferredURI(settings: settings) }
    private var suffix: String { settings.ldapSuffix }
    private var groupsDN: String { settings.groupsDN }

    /// `-x -H … -D … -y <file>` plus whatever the operation adds, with the bind password in a
    /// 0600 file that is gone by the time this returns.
    private func bound(_ tool: String?, _ arguments: [String], input: String? = nil,
                       subject: String) async throws {
        guard running, let tool else {
            throw DirectoryError.notRunning("The LDAP server is not running.")
        }
        guard let file = DirectoryPasswordFile(settings.ldapAdminPassword, in: workDirectory) else {
            throw DirectoryError.refused("Could not write the bind-password file in the lab folder.")
        }
        defer { file.remove() }
        let prefix = OpenLDAPDirectoryCommands.bind(uri: uri, adminDN: settings.ldapAdminDN,
                                                    passwordFile: file.url.path)
        let result = await Shell.run(tool, prefix + arguments, input: input,
                                     environment: tools.childEnvironment)
        guard result.ok else { throw DirectoryErrorMap.map(result.output, subject: subject) }
    }

    func snapshot() async throws -> DirectorySnapshot {
        guard running, let ldapsearch = tools.ldapsearch else {
            throw DirectoryError.notRunning("The LDAP server is not running.")
        }
        guard let file = DirectoryPasswordFile(settings.ldapAdminPassword, in: workDirectory) else {
            throw DirectoryError.refused("Could not write the bind-password file in the lab folder.")
        }
        defer { file.remove() }
        let argv = OpenLDAPDirectoryCommands.bind(uri: uri, adminDN: settings.ldapAdminDN,
                                                  passwordFile: file.url.path)
            + OpenLDAPDirectoryCommands.readAll(suffix: suffix)
        let result = await Shell.run(ldapsearch, argv, environment: tools.childEnvironment)
        guard result.ok else { throw DirectoryErrorMap.map(result.output) }
        return DirectorySnapshotParser.openLDAP(ADLDIF.parse(result.output),
                                                suffix: suffix, groupsDN: groupsDN)
    }

    func createUser(_ username: String, displayName: String, ou: String, password: String) async throws {
        if let problem = DirectoryNames.problem(with: username, kind: .user, backend: .openLDAP) {
            throw DirectoryError.builtIn(problem)
        }
        // Every container on the way down has to exist before the account can be put in it,
        // and its failure is **not** swallowed: an account added under a parent that could not
        // be created fails with `No such object (32)`, which is a far worse message than the
        // one that actually explains it.
        try await ensureOU(ou)
        let ldif = OpenLDAPDirectoryCommands.addUserLDIF(
            username: username, displayName: displayName, ou: ou, suffix: suffix,
            domain: settings.dnsDomain, uidNumber: Self.uidNumber(for: username),
            sshaPassword: ConfigGenerator.ssha(password),
            ntPassword: settings.publishNTHashes ? MD4.ntPasswordHash(password) : nil)
        try await bound(tools.ldapadd, [], input: ldif, subject: username)
        // `netusers` is every enabled user, and the seed writes it — so an account created
        // online joins it too, or the two ways of building a directory would disagree.
        try? await bound(tools.ldapmodify, [], input: OpenLDAPDirectoryCommands.memberLDIF(
            groupDN: OpenLDAPDirectoryCommands.groupDN(LabGroup.everyoneName, groupsDN: groupsDN),
            userDN: OpenLDAPDirectoryCommands.userDN(username, ou: ou, suffix: suffix),
            add: true), subject: LabGroup.everyoneName)
    }

    /// A stable, collision-free `uidNumber` without asking the directory for the highest one:
    /// nothing in this app reads it, POSIX login is not what a lab directory is for, and a
    /// read-then-write would be a race between two panes.
    nonisolated static func uidNumber(for username: String) -> Int {
        var hash = 5381
        for byte in Array(username.lowercased().utf8) { hash = (hash &* 33 &+ Int(byte)) & 0x7FFF }
        return 20000 + hash
    }

    func setPassword(_ username: String, to password: String) async throws {
        let dn = try await dn(ofUser: username)
        guard let file = DirectoryPasswordFile(password, in: workDirectory) else {
            throw DirectoryError.refused("Could not write the new-password file in the lab folder.")
        }
        defer { file.remove() }
        try await bound(tools.ldappasswd,
                        OpenLDAPDirectoryCommands.passwordArguments(dn: dn, newPasswordFile: file.url.path),
                        subject: username)
        // slapd hashes to {SSHA} itself and cannot compute an MD4, so the NT hash a NAC reads
        // is a second call — otherwise PEAP-MSCHAPv2 would go on working with the old password.
        if settings.publishNTHashes {
            try await bound(tools.ldapmodify, [], input: OpenLDAPDirectoryCommands.replaceLDIF(
                dn: dn, attribute: "sambaNTPassword", value: MD4.ntPasswordHash(password)),
                            subject: username)
        }
    }

    func setDisplayName(_ username: String, to displayName: String) async throws {
        if let problem = DirectoryNames.valueProblem(displayName, what: "A display name",
                                                     limit: Validation.maxDisplayNameLength) {
            throw DirectoryError.refused(problem)
        }
        let dn = try await dn(ofUser: username)
        try await bound(tools.ldapmodify, [], input: OpenLDAPDirectoryCommands.replaceLDIF(
            dn: dn, attribute: "displayName", value: displayName.isEmpty ? username : displayName),
                        subject: username)
    }

    func setEnabled(_ username: String, to enabled: Bool) async throws {
        throw DirectoryError.refused("""
        OpenLDAP has no “account disabled” flag — that is an Active Directory idea \
        (userAccountControl). Change the password or delete the account instead.
        """)
    }

    func moveUser(_ username: String, toOU ou: String) async throws {
        let dn = try await dn(ofUser: username)
        try await ensureOU(ou)
        try await bound(tools.ldapmodrdn, OpenLDAPDirectoryCommands.moveArguments(
            dn: dn, newRDN: "uid=\(username)",
            newSuperior: OpenLDAPDirectoryCommands.dn(forOU: ou, suffix: suffix)), subject: username)
        try await reseatMemberships(of: username, from: dn,
                                    to: OpenLDAPDirectoryCommands.userDN(username, ou: ou, suffix: suffix))
    }

    func renameUser(_ username: String, to newName: String) async throws {
        if let problem = DirectoryNames.problem(with: newName, kind: .user, backend: .openLDAP) {
            throw DirectoryError.builtIn(problem)
        }
        // Build 20, audit N-12: `ldapmodrdn` would fail with `Already exists (68)` anyway, but
        // only after the rename had been attempted, and the sentence it gives is not the one
        // `createUser` gives for the same mistake.
        let existing = try await snapshot().users
        if existing.contains(where: {
            $0.username.caseInsensitiveCompare(newName) == .orderedSame
                && $0.username.caseInsensitiveCompare(username) != .orderedSame
        }) {
            throw DirectoryError.nameTaken("“\(newName)” already exists.")
        }
        let user = try await entry(ofUser: username)
        try await bound(tools.ldapmodrdn,
                        OpenLDAPDirectoryCommands.moveArguments(
                            dn: user.dn, newRDN: "uid=\(newName)",
                            newSuperior: OpenLDAPDirectoryCommands.dn(forOU: user.ou, suffix: suffix)),
                        subject: newName)
        let newDN = OpenLDAPDirectoryCommands.userDN(newName, ou: user.ou, suffix: suffix)
        // `uid` is the RDN and follows; `cn`, `sn` and `sAMAccountName` do not, and a NAC
        // matches on `sAMAccountName`.
        for (attribute, value) in [("cn", newName), ("sn", newName), ("sAMAccountName", newName)] {
            try? await bound(tools.ldapmodify, [],
                             input: OpenLDAPDirectoryCommands.replaceLDIF(dn: newDN, attribute: attribute,
                                                                          value: value),
                             subject: newName)
        }
        try await reseatMemberships(of: newName, from: user.dn, to: newDN)
    }

    func deleteUser(_ username: String) async throws {
        let dn = try await dn(ofUser: username)
        try await bound(tools.ldapdelete,
                        OpenLDAPDirectoryCommands.deleteArguments(dn: dn, recursive: false),
                        subject: username)
        for group in try await snapshot().groups where group.members.contains(where: {
            $0.caseInsensitiveCompare(username) == .orderedSame
        }) {
            try? await bound(tools.ldapmodify, [], input: OpenLDAPDirectoryCommands.memberLDIF(
                groupDN: group.dn, userDN: dn, add: false), subject: group.name)
        }
    }

    func createGroup(_ name: String, description: String) async throws {
        if let problem = DirectoryNames.problem(with: name, kind: .group, backend: .openLDAP) {
            throw DirectoryError.builtIn(problem)
        }
        if let problem = DirectoryNames.valueProblem(description, what: "A description",
                                                     limit: Validation.maxDescriptionLength) {
            throw DirectoryError.refused(problem)
        }
        // `groupOfNames` requires at least one `member` and slapd rejects the whole entry
        // without one, so a group created empty gets the admin DN as a placeholder — exactly
        // what `seedLDIF` does, and a DN every device already knows to ignore. Appended before
        // the record terminator rather than spliced into the text, because splicing on "\n\n"
        // is a bug waiting for the day this LDIF grows a second blank line.
        var ldif = OpenLDAPDirectoryCommands.addGroupLDIF(name: name, description: description,
                                                          groupsDN: groupsDN)
        if ldif.hasSuffix("\n\n") { ldif.removeLast() }
        ldif += "member: \(settings.ldapAdminDN)\n\n"
        try await bound(tools.ldapadd, [], input: ldif, subject: name)
    }

    func deleteGroup(_ name: String) async throws {
        if let problem = DirectoryNames.problem(with: name, kind: .group, backend: .openLDAP) {
            throw DirectoryError.builtIn(problem)
        }
        // `member` lives on the group entry and slapd's memberof overlay derives every
        // member's `memberOf` from it, so removing the entry drops the membership with it.
        // **Emptying it first would fail**: `groupOfNames` requires at least one `member`, and
        // slapd rejects the modify that would take the last one away (which is why
        // `createGroup` seeds the admin DN as a placeholder).
        try await bound(tools.ldapdelete, OpenLDAPDirectoryCommands.deleteArguments(
            dn: OpenLDAPDirectoryCommands.groupDN(name, groupsDN: groupsDN), recursive: true),
                        subject: name)
    }

    func setMembership(of username: String, groups: [String]) async throws {
        let snapshot = try await snapshot()
        guard let user = snapshot.users.first(where: {
            $0.username.caseInsensitiveCompare(username) == .orderedSame
        }) else { throw DirectoryError.notFound("“\(username)” is not in the directory.") }
        let wanted = Set(groups.map { $0.lowercased() })
        for group in snapshot.groups where group.name != LabGroup.everyoneName {
            let isMember = group.members.contains { $0.caseInsensitiveCompare(username) == .orderedSame }
            let shouldBe = wanted.contains(group.name.lowercased())
            guard isMember != shouldBe else { continue }
            try await bound(tools.ldapmodify, [], input: OpenLDAPDirectoryCommands.memberLDIF(
                groupDN: group.dn, userDN: user.dn, add: shouldBe), subject: group.name)
        }
    }

    /// Create an OU **and every container above it**.
    ///
    /// Two behaviours, and the difference is the whole function. An **ancestor** that already
    /// exists is success — `Staff` being there is the normal case when someone asks for
    /// `Staff/IT`. The **leaf** that already exists is a failure, because that is the one the
    /// person actually asked for and they have to be told the name is taken.
    ///
    /// Build 17 threw on the first ancestor instead, so `createOU("Probe/Deep")` died on
    /// `Probe` and never made `Deep`; `createUser` called it with `try?`, added the account
    /// under a parent that did not exist, and got `No such object (32)` back. That one line
    /// failed every write in the live suite's directory phase.
    func createOU(_ path: String) async throws {
        let steps = OUPath.selfAndAncestors(of: OUPath.normalized(path))
        guard let leaf = steps.last else { return }
        for step in steps.dropLast() { try await add(ou: step, tolerateExisting: true) }
        try await add(ou: leaf, tolerateExisting: false)
    }

    /// The path has to be there; whether it already was is not interesting. What `createUser`
    /// and `moveUser` need.
    private func ensureOU(_ path: String) async throws {
        for step in OUPath.selfAndAncestors(of: OUPath.normalized(path)) {
            try await add(ou: step, tolerateExisting: true)
        }
    }

    private func add(ou step: String, tolerateExisting: Bool) async throws {
        do {
            try await bound(tools.ldapadd, [],
                            input: OpenLDAPDirectoryCommands.addOULDIF(path: step, suffix: suffix),
                            subject: step)
        } catch let error as DirectoryError {
            if case .nameTaken = error, tolerateExisting { return }
            throw error
        }
    }

    func renameOU(_ path: String, to newLeaf: String) async throws {
        let parent = OUPath.parent(path) ?? ""
        try await bound(tools.ldapmodrdn, OpenLDAPDirectoryCommands.moveArguments(
            dn: OpenLDAPDirectoryCommands.dn(forOU: path, suffix: suffix),
            newRDN: "ou=\(newLeaf)",
            newSuperior: OpenLDAPDirectoryCommands.dn(forOU: parent, suffix: suffix)), subject: path)
    }

    func moveOU(_ path: String, under parent: String) async throws {
        let leaf = OUPath.segments(path).last ?? path
        try await bound(tools.ldapmodrdn, OpenLDAPDirectoryCommands.moveArguments(
            dn: OpenLDAPDirectoryCommands.dn(forOU: path, suffix: suffix),
            newRDN: "ou=\(leaf)",
            newSuperior: OpenLDAPDirectoryCommands.dn(forOU: parent, suffix: suffix)), subject: path)
    }

    /// **The accounts move out, then the container goes** (build 21 — see `DirectoryDeletion`).
    ///
    /// The users live *under* the container here (`uid=alice,ou=IT,ou=Staff,…`), so the
    /// recursive delete below used to take them with it: "Delete OU" was an unannounced,
    /// un-undoable "delete these four people", and the accounts were gone from radiusd at the
    /// next HUP. They are moved to `people` first now — `moveUser` also reseats their group
    /// memberships, which a raw delete could not have done at all.
    func deleteOU(_ path: String) async throws {
        let refuge = DirectoryDeletion.refuge(fromOU: path)
        for username in DirectoryDeletion.usersToRelocate(in: try await snapshot(), deletingOU: path) {
            try await moveUser(username, toOU: refuge)
        }
        try await bound(tools.ldapdelete, OpenLDAPDirectoryCommands.deleteArguments(
            dn: OpenLDAPDirectoryCommands.dn(forOU: path, suffix: suffix), recursive: true),
                        subject: path)
    }

    /// **Give every group the placeholder member a seeded lab was written without** (build 21).
    ///
    /// `groupOfNames` requires at least one `member`, so slapd refuses the modify that would
    /// take the last one away: unticking alice out of `NetAdmins` on a lab seeded by build ≤20
    /// failed with "Object class violation" and no way forward. Build 21's `seedLDIF` writes
    /// the admin DN into every group, and this is the same thing for the labs that already
    /// exist — one `ldapmodify` per group, at the first start after the upgrade.
    ///
    /// Idempotent by construction: a group that already has it answers `Type or value exists
    /// (20)` and the failure is dropped. Returns how many groups it actually had to touch, for
    /// the log line and for the live suite.
    func ensureGroupPlaceholders() async -> Int {
        guard running, let snapshot = try? await snapshot() else { return 0 }
        var added = 0
        for group in snapshot.groups where !group.isReadOnly && !group.dn.isEmpty {
            do {
                try await bound(tools.ldapmodify, [], input: OpenLDAPDirectoryCommands.memberLDIF(
                    groupDN: group.dn, userDN: settings.ldapAdminDN, add: true), subject: group.name)
                added += 1
            } catch {
                // Already there, which is the normal answer after the first run.
            }
        }
        return added
    }

    /// **Give a database seeded before build 24 the two entries the admin DN needs** — the
    /// same shape, and the same reasoning, as `ensureGroupPlaceholders` above.
    ///
    /// `rebuildLDAP` seeds twice in a lab's life (the first start, and a changed base DN), so
    /// a lab that has been running since build 23 will never see the new `seedLDIF`. Without
    /// this, the migration would move `rootdn` to `cn=Administrator,cn=Users,<base>` — which
    /// binds, because `rootpw` is checked in the frontend — while a search for that DN went on
    /// answering nothing, which is the confusing half of the two.
    ///
    /// Idempotent by construction: an entry that is already there comes back
    /// `Already exists (68)` and is counted as nothing to do. The admin DN is also added to
    /// every group, so a backfilled database and a freshly seeded one hold the same
    /// `groupOfNames` placeholder (see `ensureGroupPlaceholders` for why the placeholder
    /// exists at all).
    ///
    /// - Returns: how many entries it actually had to write, for the log line and the suites.
    func ensureAdminIdentity() async -> Int {
        guard running else { return 0 }
        let ldif = ConfigGenerator.adminIdentityLDIF(settings: settings)
        guard !ldif.isEmpty else { return 0 }   // a pinned DN is somebody else's to maintain
        var added = 0
        // One record per call: `ldapadd` stops at the first record it cannot add, so sending
        // both together would mean a lab that already has `cn=Users` never gets the account.
        for record in Self.ldifRecords(ldif) {
            do {
                try await bound(tools.ldapadd, [], input: record, subject: "the admin account")
                added += 1
            } catch {
                // Already there, which is the normal answer after the first run.
            }
        }
        _ = await ensureGroupPlaceholders()
        return added
    }

    /// Split an LDIF into its records, each still terminated by a blank line.
    nonisolated static func ldifRecords(_ ldif: String) -> [String] {
        var out: [String] = []
        var current: [String] = []
        for line in ldif.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.isEmpty {
                if !current.isEmpty { out.append(current.joined(separator: "\n") + "\n\n") }
                current = []
            } else {
                current.append(String(line))
            }
        }
        if !current.isEmpty { out.append(current.joined(separator: "\n") + "\n\n") }
        return out
    }

    /// slapd holds the hash, not the password, so this is the hash the app wrote at the last
    /// `setPassword` — which is exactly what `NT-Password` needs.
    func ntHash(of username: String) async throws -> String? {
        guard running, let ldapsearch = tools.ldapsearch else { return nil }
        guard let file = DirectoryPasswordFile(settings.ldapAdminPassword, in: workDirectory) else {
            return nil
        }
        defer { file.remove() }
        let argv = OpenLDAPDirectoryCommands.bind(uri: uri, adminDN: settings.ldapAdminDN,
                                                  passwordFile: file.url.path)
            // RFC 4515. The name comes from the directory snapshot, not from this app's own
            // table, so it is whatever slapd holds: an account created elsewhere as `uid=*`
            // turned this into `(uid=*)`, and `.first` below then returned somebody else's NT
            // hash to be written into `authorize` under this name.
            + ["-LLL", "-b", suffix, "-s", "sub",
               "(uid=\(LDAPDiagnosis.escape(username)))", "sambaNTPassword"]
        let result = await Shell.run(ldapsearch, argv, environment: tools.childEnvironment)
        guard result.ok else { return nil }
        let hash = ADLDIF.parse(result.output).compactMap { ADLDIF.first($0, "sambaNTPassword") }.first
        guard let hash, hash.count == 32, hash.allSatisfy(\.isHexDigit) else { return nil }
        return hash.uppercased()
    }

    /// A DN in a `member` value does not follow the entry it points at — slapd's memberof
    /// overlay maintains `memberOf`, not the other direction — so a move or a rename has to
    /// rewrite the groups the account was in. Doing nothing here is how a renamed user
    /// silently loses every VLAN their group rule would have given them.
    private func reseatMemberships(of username: String, from oldDN: String, to newDN: String) async throws {
        guard oldDN != newDN else { return }
        for group in try await snapshot().groups {
            guard group.members.contains(where: { $0.caseInsensitiveCompare(username) == .orderedSame })
                    || group.name == LabGroup.everyoneName else { continue }
            try? await bound(tools.ldapmodify, [], input: OpenLDAPDirectoryCommands.memberLDIF(
                groupDN: group.dn, userDN: oldDN, add: false), subject: group.name)
            try? await bound(tools.ldapmodify, [], input: OpenLDAPDirectoryCommands.memberLDIF(
                groupDN: group.dn, userDN: newDN, add: true), subject: group.name)
        }
    }

    private func entry(ofUser username: String) async throws -> DirectoryUser {
        guard let match = try await snapshot().users
            .first(where: { $0.username.caseInsensitiveCompare(username) == .orderedSame })
        else { throw DirectoryError.notFound("“\(username)” is not in the directory.") }
        return match
    }

    private func dn(ofUser username: String) async throws -> String {
        try await entry(ofUser: username).dn
    }
}
