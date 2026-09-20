import Foundation

/// "What to type into *this* device's form", one profile per product.
///
/// The existing copy rows on DIRECTORY ▸ Device settings answer "what is the base DN"; they do
/// not answer "which of these nine boxes on the iMaster page wants which of them". This does,
/// and it exists because the owner spent an afternoon on exactly that gap: iMaster NCE-Campus
/// answered "username/password incorrect" for a synchronisation account typed as
/// `DN=administrator,DC=…`, which is not a DN at all. The row for that field therefore carries
/// the wrong value as well as the right one — a table that only shows the right answer cannot
/// stop someone typing the wrong one twice.
///
/// Everything here is **pure**: settings and an address in, rows out. No `AppModel`, no
/// `LocalNetwork`, no formatting of the current time — so `Tests/unit.swift` can pin every row
/// against a made-up address and prove no value was ever hard-coded.
nonisolated struct DeviceField: Sendable, Equatable {
    /// The label as the device's own UI spells it.
    var field: String
    /// What to paste there. Copied verbatim, so it is never decorated.
    var value: String
    /// Why, or what goes wrong when it is something else. Shown under the row, not copied.
    var note: String?

    init(_ field: String, _ value: String, note: String? = nil) {
        self.field = field
        self.value = value
        self.note = note
    }
}

nonisolated struct DeviceProfile: Identifiable, Sendable, Equatable {
    var id: String { name }
    /// The product, spelled the way its own documentation does. Used as the identity and as
    /// the heading over the table.
    var name: String
    /// What the segmented picker shows, when the full name is too long to read at 980 pt.
    /// Build 22: there are two iMaster forms now — the join page and the synchronisation page
    /// are different pages wanting different things — and "iMaster NCE-Campus — join (AD
    /// Domain Configuration)" as a segment title would squeeze the other four products into
    /// nothing. nil means the name is short enough already.
    var short: String? = nil
    /// Where in that product's UI the form is.
    var location: String
    var fields: [DeviceField]
    /// Shown under the table when this path has not been walked end to end against real
    /// hardware. nil means it has.
    var caveat: String?

    /// Every value in the table, for the "Copy all" affordance and for the tests.
    var values: [String] { fields.map(\.value) }
}

// MARK: - Builders

nonisolated enum DeviceProfiles {
    /// The placeholder the tables use when a value is not set yet, so a row is never blank and
    /// never silently copies an empty string.
    static let unset = "— not set —"

    private static func password(_ raw: String) -> String { raw.isEmpty ? unset : raw }

    // MARK: AD mode

    /// - Parameters:
    ///   - settings: the **applied** AD settings — what the DC was actually started from.
    ///   - address: this Mac's current primary IPv4, or the address the DC advertises when it
    ///     is running. Never defaulted: a table with a stale address is the failure this whole
    ///     feature exists to prevent.
    ///   - caPath: the lab CA on disk, for the profiles that can upload one. nil when openssl
    ///     is missing and no CA was ever written.
    static func activeDirectory(settings: ADSettings, address: String, caPath: String?) -> [DeviceProfile] {
        [imasterJoin(settings: settings, address: address),
         imaster(settings: settings, address: address, caPath: caPath),
         clearPassAD(settings: settings, address: address),
         windows(settings: settings, address: address),
         genericLDAPForAD(settings: settings, address: address, caPath: caPath)]
    }

    /// **iMaster's other iMaster page** (build 22, owner's report: "there is no iMaster entry").
    ///
    /// There was one, and it was the *synchronisation* form — the page you reach after the
    /// cluster has already joined the domain. Joining is a different page wanting different
    /// things, and the difference is the trap the owner hit on 18 Sep 2026: **AD Domain
    /// Configuration wants a user name and the synchronisation form wants a DN**, so the
    /// account that works on one is refused by the other with a message about the password.
    ///
    /// The DNS and clock rows come first because on a cluster they are per node and are done
    /// over SSH, not in the web UI — and because a node whose `/etc/resolv.conf` still points
    /// at the site resolver fails the join with an error that never mentions DNS.
    static func imasterJoin(settings: ADSettings, address: String) -> DeviceProfile {
        DeviceProfile(
            name: "iMaster NCE-Campus — join (AD Domain Configuration)",
            short: "iMaster — join",
            location: "System ▸ System Management ▸ Third-Party Service ▸ AD Domain Configuration",
            fields: [
                DeviceField("The nodes to do this on (Management Plane :18102)",
                            "Product ▸ System Monitoring ▸ Service ▸ RadiusServerService",
                            note: "Every node listed there runs the service that has to resolve this domain; the owner's cluster is three of them (OMP, SERVICE1, DATABACKUP), and one node left behind is one node whose Trust Status never goes green."),
                DeviceField("On each node (SSH)", "ssh sopuser@<node management IP>",
                            note: "Then su - root. Back up /etc/resolv.conf before editing it."),
                DeviceField("/etc/resolv.conf (each node)",
                            "options timeout:1 attempts:1 rotate\nnameserver \(address)",
                            note: "Those two lines and nothing else. Every resolver left in that file must be able to answer for \(settings.realm), so a second nameserver pointing at the site DNS breaks the join rather than making it more reliable."),
                DeviceField("Verify on each node", "nslookup \(settings.dcFQDN)",
                            note: "It must answer \(address)."),
                DeviceField("Verify the SRV record too",
                            "nslookup -type=srv _ldap._tcp.dc._msdcs.\(settings.realm)",
                            note: "The answer must name the domain controller and port 389. If it does not, nothing on the AD Domain Configuration page will work."),
                DeviceField("Clock and host name (each node)", "date · hostname -f",
                            note: "The clock must be within five minutes of the domain controller, and each node's host name must be unique and must not be \(settings.realm) or \(settings.netbiosDomain)."),
                DeviceField("AD domain name", settings.realm,
                            note: "The domain, NOT \(settings.dcFQDN). The controller's name here makes iMaster look for a domain of that name and report that the domain cannot be found."),
                DeviceField("NetBIOS", settings.netbiosDomain,
                            note: "This lab's NetBIOS name in full — not the first label of the realm, which is what the box looks as though it wants."),
                DeviceField("Domain account", "Administrator",
                            note: "A user name. CN=Administrator,CN=Users,\(settings.baseDN) is refused here — the DN belongs in the AD/LDAP Synchronization form, which is the next profile along."),
                DeviceField("Domain account password", password(settings.administratorPassword),
                            note: "The Administrator password this domain was provisioned with — the applied one, not an edit that has not been applied yet."),
                DeviceField("Then, in order",
                            "Domain Name Resolution Verification → Add to Domain → Node List",
                            note: "Every node in the list must end with Trust Status Normal."),
            ],
            caveat: nil)
    }

    /// iMaster NCE-Campus ▸ Admission ▸ External Data Source ▸ AD/LDAP Synchronization.
    ///
    /// Filled in by hand against the real product on 18 Sep 2026; every label below is the
    /// label on that page.
    static func imaster(settings: ADSettings, address: String, caPath: String?) -> DeviceProfile {
        var fields: [DeviceField] = [
            DeviceField("Server type", "Active Directory"),
            DeviceField("Data source name", settings.realm,
                        note: "A free-text name. The realm keeps it obvious which directory it is."),
            DeviceField("Primary server address", address,
                        note: "This Mac. It changes when this Mac moves network — the Status pane says so when it does, and this row follows it."),
            DeviceField("Authentication port", "389",
                        note: "636 instead, if you switch TLS on below and upload this lab's CA."),
            DeviceField("AD domain name", settings.realm),
            DeviceField("AD short domain name", settings.netbiosDomain),
            DeviceField("Base DN", settings.baseDN),
            DeviceField("Synchronization account", "CN=Administrator,CN=Users,\(settings.baseDN)",
                        note: "Administrator@\(settings.realm) works here too. "
                            + "DN=administrator,\(settings.baseDN.uppercased()) does NOT — there is no DN= attribute, so the bind fails and iMaster reports it as “username/password incorrect”, which sends you looking at the password instead of the account."),
            DeviceField("Synchronization password", password(settings.administratorPassword),
                        note: "The Administrator password this domain was provisioned with — the applied one, not an edit that has not been applied yet."),
            DeviceField("TLS", "Off",
                        note: "Off is the default and what port 389 above assumes."),
            DeviceField("AD Server Administrator Settings", "(leave blank)",
                        note: "Only for password changes pushed from iMaster. Nothing in this lab needs it."),
            DeviceField("Synchronization mode", "Mode 1 — OU-based synchronization",
                        note: "CN=Users is a container and not an OU, so an account sitting in it is invisible to Mode 1 and the synchronisation finishes with an empty user list. Put the accounts to be synchronised in an OU — this app creates its OUs at the top level, e.g. OU=Staff,\(settings.baseDN) — and choose that one as the Source OU under Synchronization Scope."),
            // Not a field on that form — the answer to the question the form leads to. It
            // belongs in this table because this is the page someone is on when they hit it.
            DeviceField("RADIUS authentication against this AD",
                        "PEAP-MSCHAPv2 works (verified 18 Sep)",
                        note: "The domain controller evaluates MSCHAPv2 over Netlogon, so a WRONG_PASSWORD here means the Wi-Fi client typed a different password — or a different username form — from the account, not that the directory is misconfigured. Status ▸ Recent authentications shows the DC's own verdict next to the RADIUS one. "
                            + "The domain controller is started with `ntlm auth = mschapv2-and-ntlmv2-only`: Samba's default `ntlmv2-only` refuses a bare MSCHAPv2 Netlogon request, which some NAC boxes send. That was not the cause of the failure chased on 18 Sep 2026, but it is the correct setting for a DC a NAC authenticates against."),
        ]
        if let caPath {
            fields.append(DeviceField("CA certificate (only with TLS on)", caPath,
                                      note: "Upload this file, then set the port to 636. The domain controller's certificate is issued by this lab's own CA."))
        }
        return DeviceProfile(name: "iMaster NCE-Campus — synchronization (AD/LDAP)",
                             short: "iMaster — sync",
                             location: "Admission Management ▸ Admission Resource ▸ External Data Source ▸ AD/LDAP Synchronization",
                             fields: fields,
                             caveat: "This form's Test Connection passed against a real iMaster NCE-Campus cluster on 18 Sep 2026; what has not been watched through is the user list after an OU-based synchronisation.")
    }

    /// Aruba ClearPass: the join form and the authentication source are two different pages
    /// that want two different things, and the join form wanting the *controller* while the
    /// Domain box wants the *domain* is the trap.
    static func clearPassAD(settings: ADSettings, address: String) -> DeviceProfile {
        DeviceProfile(
            name: "ClearPass",
            location: "Server Configuration ▸ Join AD Domain · and Authentication ▸ Sources ▸ Add (Active Directory)",
            fields: [
                DeviceField("DNS server (Server Configuration ▸ Network)", address,
                            note: "First. ClearPass has to resolve \(settings.dcFQDN) before the join button can work at all."),
                DeviceField("Join AD Domain ▸ Domain Controller", settings.dcFQDN,
                            note: "The controller's name here — not the domain."),
                DeviceField("Join AD Domain ▸ NetBIOS Name", settings.netbiosDomain),
                DeviceField("Join AD Domain ▸ Username", "Administrator"),
                DeviceField("Join AD Domain ▸ Password", password(settings.administratorPassword)),
                DeviceField("Source ▸ Hostname", address),
                DeviceField("Source ▸ Connection Security", "None",
                            note: "AD over SSL instead, on port 636, once this lab's CA is imported into ClearPass."),
                DeviceField("Source ▸ Port", "389"),
                DeviceField("Source ▸ Bind DN", "Administrator@\(settings.realm)"),
                DeviceField("Source ▸ Bind Password", password(settings.administratorPassword)),
                DeviceField("Source ▸ NetBIOS Domain Name", settings.netbiosDomain),
                DeviceField("Source ▸ Base DN", settings.baseDN),
                DeviceField("Source ▸ Search Scope", "SubTree"),
                DeviceField("Source ▸ user filter", "(sAMAccountName=%s)",
                            note: "ClearPass writes its own filters with %{Authentication:Username} in place of %s; the attribute is the part that matters."),
                DeviceField("Source ▸ group attribute", "memberOf"),
            ],
            caveat: "Not tested against a real ClearPass. The LDAP side of this domain is proven by the self-test; the Join AD Domain button is not.")
    }

    /// Windows 10 / 11 Pro. Two fields and one of them is DNS, which is where it goes wrong.
    static func windows(settings: ADSettings, address: String) -> DeviceProfile {
        DeviceProfile(
            name: "Windows",
            location: "Network adapter ▸ Edit DNS · then System ▸ About ▸ Domain or workgroup",
            fields: [
                DeviceField("IPv4 DNS server (manual)", address,
                            note: "Before anything else. A device still using the router's DNS cannot resolve \(settings.realm), and the error never mentions DNS."),
                DeviceField("Alternate DNS server", "(leave empty)",
                            note: "One lookup going to the router is enough to break discovery. Switch the adapter's IPv6 DNS off too — a router-supplied IPv6 resolver silently wins over IPv4."),
                DeviceField("Member of ▸ Domain", settings.realm,
                            note: "NOT \(settings.dcFQDN). Typing the controller's name here makes Windows look for a domain of that name and report that no domain controller could be contacted."),
                DeviceField("Credentials ▸ User name", "Administrator",
                            note: "Administrator@\(settings.realm) is accepted as well."),
                DeviceField("Credentials ▸ Password", password(settings.administratorPassword)),
                DeviceField("Sign in after the restart as", "\(settings.netbiosDomain)\\alice",
                            note: "Any enabled user from the Users pane, with its password from there. Prefix a local account with .\\ instead."),
                DeviceField("Check DNS first (Command Prompt)", "nslookup -type=SRV _ldap._tcp.dc._msdcs.\(settings.realm)",
                            note: "It must answer \(settings.dcFQDN). If it does not, no amount of retrying the join will help."),
            ],
            caveat: nil)
    }

    /// Anything with a plain "LDAP server" form — a switch, a firewall, a NAS, a NAC whose
    /// AD source you would rather not use.
    static func genericLDAPForAD(settings: ADSettings, address: String, caPath: String?) -> DeviceProfile {
        var fields: [DeviceField] = [
            DeviceField("Server URL", "ldap://\(address):389"),
            DeviceField("Server URL (TLS)", "ldaps://\(address):636"),
            DeviceField("Bind DN", "Administrator@\(settings.realm)",
                        note: "CN=Administrator,CN=Users,\(settings.baseDN) is the same account written as a DN, for forms that insist on one."),
            DeviceField("Bind password", password(settings.administratorPassword)),
            DeviceField("Base DN", settings.baseDN),
            DeviceField("User filter", "(sAMAccountName=%s)"),
            DeviceField("Group attribute", "memberOf"),
            DeviceField("Group DN pattern", "CN=<group>,\(settings.managedRootDN)",
                        note: "Groups this app manages live under \(settings.managedRootDN); built-in groups stay in CN=Users."),
            DeviceField("Global catalog", "ldap://\(address):3268"),
        ]
        if let caPath {
            fields.append(DeviceField("CA to import on the device", caPath))
        }
        return DeviceProfile(name: "Generic LDAP",
                             location: "any “LDAP server” form",
                             fields: fields,
                             caveat: nil)
    }

    // MARK: OpenLDAP mode

    static func openLDAP(settings: LabSettings, address: String, caPath: String?) -> [DeviceProfile] {
        [genericLDAP(settings: settings, address: address, caPath: caPath),
         fortiGate(settings: settings, address: address, caPath: caPath),
         imasterLDAP(settings: settings, address: address),
         clearPassLDAP(settings: settings, address: address)]
    }

    /// The URL rows only ever list a listener that is actually enabled — a table offering
    /// `ldaps://…:636` while LDAPS is switched off is a support call waiting to happen.
    private static func urlFields(_ settings: LabSettings, address: String) -> [DeviceField] {
        var out: [DeviceField] = []
        if settings.ldapPlainEnabled {
            out.append(DeviceField(settings.offersStartTLS ? "Server URL (plain / StartTLS)" : "Server URL",
                                   "ldap://\(address):\(settings.ldapPort)"))
        }
        if settings.ldapsEnabled {
            out.append(DeviceField("Server URL (LDAPS)", "ldaps://\(address):\(settings.ldapsPort)"))
        }
        return out
    }

    static func genericLDAP(settings: LabSettings, address: String, caPath: String?) -> DeviceProfile {
        var fields = urlFields(settings, address: address)
        fields += [
            DeviceField("Bind DN", settings.ldapAdminDN,
                        note: "The one account that may read every attribute, including the NT hash."),
            DeviceField("Bind password", password(settings.ldapAdminPassword)),
            DeviceField("Base DN / search base", settings.ldapSuffix),
            DeviceField("User filter (POSIX style)", "(uid=%s)"),
            DeviceField("User filter (AD style)", "(sAMAccountName=%s)",
                        note: "Both attributes carry the username, so use whichever one the device's form expects."),
            DeviceField("Group attribute", "memberOf"),
            DeviceField("Group DN pattern", "cn=<group>,\(settings.groupsDN)"),
            DeviceField("User DN pattern", "uid=<user>,ou=<OU path, leaf first>,\(settings.ldapSuffix)"),
        ]
        if settings.publishNTHashes {
            fields.append(DeviceField("Password attribute (NT hash)", "sambaNTPassword",
                                      note: "For a NAC doing PEAP-MSCHAPv2 from a generic LDAP source without joining a domain. Only the bind DN above can read it."))
        }
        if settings.needsTLS, let caPath {
            fields.append(DeviceField("CA to import on the device", caPath))
        }
        return DeviceProfile(name: "Generic LDAP",
                             location: "any “LDAP server” form",
                             fields: fields,
                             caveat: nil)
    }

    /// FortiGate ▸ User & Authentication ▸ LDAP Servers. The one product whose field names
    /// match nothing anybody else calls them, which is why it gets its own table.
    static func fortiGate(settings: LabSettings, address: String, caPath: String?) -> DeviceProfile {
        var fields: [DeviceField] = [
            DeviceField("Name", "SheepRadius", note: "Free text — whatever the rules will refer to."),
            DeviceField("Server IP/Name", address),
            DeviceField("Server Port", settings.ldapsEnabled && !settings.ldapPlainEnabled
                        ? "\(settings.ldapsPort)" : "\(settings.ldapPort)",
                        note: settings.ldapsEnabled
                              ? "\(settings.ldapsPort) when Secure Connection is LDAPS."
                              : "LDAPS is switched off, so only the plain port answers."),
            DeviceField("Common Name Identifier", "uid",
                        note: "sAMAccountName works as well — every user carries both."),
            DeviceField("Distinguished Name", settings.ldapSuffix),
            DeviceField("Bind Type", "Regular",
                        note: "Simple binds anonymously as the user; Regular binds as the account below first, which is what lets group lookups work."),
            DeviceField("Username", settings.ldapAdminDN),
            DeviceField("Password", password(settings.ldapAdminPassword)),
            DeviceField("Secure Connection", settings.ldapsEnabled ? "LDAPS (optional)" : "Off",
                        note: settings.ldapsEnabled
                              ? "With it on, set the port to \(settings.ldapsPort) and load this lab's CA as the Certificate."
                              : nil),
        ]
        if settings.needsTLS, let caPath {
            fields.append(DeviceField("Certificate (only with Secure Connection on)", caPath))
        }
        return DeviceProfile(name: "FortiGate",
                             location: "User & Authentication ▸ LDAP Servers",
                             fields: fields,
                             caveat: "Field names taken from FortiOS 7.x. Not tested against a real FortiGate.")
    }

    /// iMaster NCE-Campus against OpenLDAP rather than the domain. Marked "check" where the
    /// form's own wording is not known for certain — a cheat-sheet that guesses is worse than
    /// none, because it is believed.
    static func imasterLDAP(settings: LabSettings, address: String) -> DeviceProfile {
        var fields: [DeviceField] = [
            DeviceField("Server type", "LDAP (check: the AD/LDAP Synchronization page offers “Active Directory”; the LDAP wording differs by version)"),
            DeviceField("Data source name", settings.dnsDomain.isEmpty ? "sheepradius" : settings.dnsDomain),
            DeviceField("Primary server address", address),
            DeviceField("Authentication port", "\(settings.ldapPlainEnabled ? settings.ldapPort : settings.ldapsPort)"),
            DeviceField("Base DN", settings.ldapSuffix),
            DeviceField("Bind / synchronization account", settings.ldapAdminDN,
                        note: "A full DN. This is the field where DN=admin,… would fail as “username/password incorrect” — there is no DN= attribute."),
            DeviceField("Bind / synchronization password", password(settings.ldapAdminPassword)),
            DeviceField("User name attribute", "uid (check: some versions call it the user identity attribute)"),
            DeviceField("TLS", "Off"),
        ]
        if settings.publishNTHashes {
            fields.append(DeviceField("Password attribute (NT hash)", "sambaNTPassword"))
        }
        return DeviceProfile(name: "iMaster (LDAP)",
                             location: "Admission ▸ External Data Source ▸ AD/LDAP Synchronization",
                             fields: fields,
                             caveat: "Only the Active Directory half of this page has been filled in for real. Rows marked “check” are the ones whose LDAP-mode wording has not been seen.")
    }

    static func clearPassLDAP(settings: LabSettings, address: String) -> DeviceProfile {
        var fields: [DeviceField] = [
            DeviceField("Type", "Generic LDAP"),
            DeviceField("Hostname", address),
            DeviceField("Connection Security", settings.ldapsEnabled ? "None (or AD over SSL)" : "None"),
            DeviceField("Port", "\(settings.ldapPlainEnabled ? settings.ldapPort : settings.ldapsPort)"),
            DeviceField("Bind DN", settings.ldapAdminDN),
            DeviceField("Bind Password", password(settings.ldapAdminPassword)),
            DeviceField("Base DN", settings.ldapSuffix),
            DeviceField("Search Scope", "SubTree"),
            DeviceField("user filter", "(uid=%s)",
                        note: "ClearPass writes it as (uid=%{Authentication:Username}); the attribute is the part that matters."),
            DeviceField("group attribute", "memberOf"),
        ]
        if settings.publishNTHashes {
            fields.append(DeviceField("Password attribute", "sambaNTPassword",
                                      note: "With the password type set to NT hash, this is what makes PEAP-MSCHAPv2 work without a domain join."))
        }
        return DeviceProfile(name: "ClearPass (generic LDAP)",
                             location: "Configuration ▸ Authentication ▸ Sources ▸ Add",
                             fields: fields,
                             caveat: "Not tested against a real ClearPass.")
    }
}
