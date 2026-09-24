<p align="center">
  <img src=".github/icon.png?v=4" width="128" alt="SheepRadius app icon">
</p>

# 🐑 SheepRadius

**A native macOS RADIUS + LDAP lab built for network engineers — 802.1X (wired and wireless), device logins and NAC, on your Mac.**

SheepRadius is written in SwiftUI + AppKit (Swift 6) and designed around the daily workflow of
bringing up and troubleshooting authentication: add a switch or access point as a NAS client,
create test users in OUs and groups, flip the servers on, and point the device at your Mac.
The same accounts work for 802.1X, for a device that authenticates its admins over LDAP, and
for a NAC doing PEAP-MSCHAPv2 against a generic LDAP source — or against a real Samba Active
Directory domain that a Windows PC can join.

**Everything is inside the app.** SheepRadius carries its own FreeRADIUS 3.2.10, OpenLDAP
2.7.1 and OpenSSL 3.6.4 and runs them as child processes under your own account — no `sudo`,
no Homebrew, no LaunchDaemon, and nothing written outside
`~/Library/Application Support/SheepRadius/`. Quitting the app stops every server.

## ⬇️ Download

[![Download SheepRadius for macOS](https://img.shields.io/badge/Download-SheepRadius_2.0_%283%29_for_macOS-2ea44f?style=for-the-badge&logo=apple&logoColor=white)](https://github.com/bestonehxh/SheepRadius/releases/latest)

**[Get the latest release →](https://github.com/bestonehxh/SheepRadius/releases/latest)** — download `SheepRadius-2.0-3.zip`, unzip, and drag **SheepRadius.app** into `Applications`.

> The build is unsigned (not notarized), so macOS will warn on first launch —
> right-click the app and choose **Open**, or run
> `xattr -dr com.apple.quarantine /Applications/SheepRadius.app`
>
> Requires macOS 26.4 (Tahoe) or later, Apple Silicon. Samba AD mode also needs Apple's
> `container` tool — the app installs it for you from the Environment page.

## The Sheep family 🐑

SheepRadius is one of eight small native macOS apps that share the same sheep icon set:

|  | App | What it does |
|---|---|---|
| <img src="https://raw.githubusercontent.com/bestonehxh/SheepDrop/main/.github/icon.png?v=3" width="44" alt=""> | [SheepDrop](https://github.com/bestonehxh/SheepDrop) | SFTP / SCP / FTP / TFTP file transfer — client and built-in server |
| <img src="https://raw.githubusercontent.com/bestonehxh/SheepTerm/main/.github/icon.png?v=3" width="44" alt=""> | [SheepTerm](https://github.com/bestonehxh/SheepTerm) | SSH / Serial / local-shell terminal for network engineers |
| <img src="https://raw.githubusercontent.com/bestonehxh/SheepTap/main/.github/icon.png?v=3" width="44" alt=""> | [SheepTap](https://github.com/bestonehxh/SheepTap) | Menu-bar viewer for your Mac's network interfaces with click-to-copy |
| <img src="https://raw.githubusercontent.com/bestonehxh/SheepPing/main/.github/icon.png?v=3" width="44" alt=""> | [SheepPing](https://github.com/bestonehxh/SheepPing) | Continuous multi-host ping monitor with per-host logs and CSV export |
| <img src="https://raw.githubusercontent.com/bestonehxh/SheepText/main/.github/icon.png?v=3" width="44" alt=""> | [SheepText](https://github.com/bestonehxh/SheepText) | Fast text editor with tree-sitter highlighting and a JavaScript plugin system |
| <img src="https://raw.githubusercontent.com/bestonehxh/SheepArt/main/.github/icon.png?v=3" width="44" alt=""> | [SheepArt](https://github.com/bestonehxh/SheepArt) | Screenshot annotation — draw, crop, layers, one-key background removal |
| <img src="https://raw.githubusercontent.com/bestonehxh/SheepRadius/main/.github/icon.png?v=4" width="44" alt=""> | [SheepRadius](https://github.com/bestonehxh/SheepRadius) | RADIUS + LDAP lab for 802.1X, device logins and NAC — with a joinable Samba AD |
| <img src="https://raw.githubusercontent.com/bestonehxh/SheepKey/main/.github/icon.png?v=1" width="44" alt=""> | [SheepKey](https://github.com/bestonehxh/SheepKey) | Mac shortcuts (⌘ as Ctrl) inside AnyDesk, TeamViewer and RustDesk |

## Features

### RADIUS
- **PAP, CHAP, MS-CHAP, EAP-MD5, PEAP, EAP-TTLS and EAP-TLS** on udp/1812 and udp/1813,
  against a test CA the app creates for you (825-day server certificate, exportable CA)
- **VLANs and vendor attributes** — `Tunnel-Private-Group-Id` plus anything from the stock
  dictionaries (`Filter-Id`, `Class`, `Fortinet-Group-Name`, `Aruba-User-Role`, `Cisco-AVPair`, …)
- **Conditional policy** — *if* the user is in a group or OU, on an SSID or AP group, on a
  given switch, on Ethernet or Wi-Fi, from a MAC, inside a time window, *then* set a VLAN,
  add reply attributes, set a Session-Timeout, or reject. Ordered first-match-wins like an
  ACL, and shown as the real unlang it becomes. See [Conditional policy](#policy)
- **Client certificates for EAP-TLS** — issue, export as `.p12`, and revoke from the Users pane

### Directory — OpenLDAP or a real Active Directory
- **OpenLDAP** on tcp/389 and LDAPS on 636, AD-shaped: nested OUs, `groupOfNames` groups,
  `sAMAccountName`, `userPrincipalName`, `memberOf`, and NT hashes for NAC servers
- **Samba AD** — a Samba 4 domain controller in a Linux container that a Windows PC can
  genuinely join, with DNS served from your Mac. See [AD Domain mode](#ad-domain-mode)
- **Users and Groups like ADUC** — an OU tree, real tables and an inspector with the General,
  Address, Telephones and Organization fields; every edit applies at once, and RADIUS picks
  it up without a restart
- **Per-product settings tables** — what to type into iMaster NCE-Campus, ClearPass, Windows,
  FortiGate or a generic LDAP form, every value live and copyable

### Seeing what happened
- **Recent authentications** — every attempt, whichever server it reached: RADIUS accepts and
  rejects with the reason, LDAP binds, domain logins, and the requests RADIUS never answers
  (a device that is not a client, a wrong shared secret)
- **A readable log** — times on every line, results highlighted, noise faded, and *Auth only*
  for RADIUS, LDAP and the domain controller
- **A RADIUS / LDAP / 802.1X test client** — aim it at this Mac *or at somebody else's
  server*: verdict, round-trip time, reply attributes in plain words, TLS version and the
  server's certificate chain. See [Testing someone else's server](#testing-someone-elses-server)
- **Address-change notice** — Status tells you when this Mac's address changed, because every
  device you pointed here was pointed by hand

### The lab itself
- **Environment page** — every component and every install in one place, with a percentage
  and the current step while it runs; starting anything that is missing takes you there
- **One file per lab** — move a whole lab, domain included, to another Mac, with automatic
  backups before anything destructive

## Requirements

- Apple Silicon Mac, **macOS 26.4 or later**
- Nothing else to install — the servers ship inside the app
- *Only* for AD Domain mode: Apple's `container` tool (`brew install container`)
- To *build*: Xcode 26+ and Homebrew `freeradius-server`, `openldap`, `openssl@3`

```bash
brew install freeradius-server openldap openssl@3
xcodebuild -project SheepRadius.xcodeproj -scheme SheepRadius -configuration Release build
```

`Vendor/eapol_test` is committed, so nothing above needs the wpa_supplicant source. Rebuild it
only to move to a newer release: `./Tools/build-eapol-test.sh`.

## Install on a second Mac

1. Copy **SheepRadius.app** over. That is the whole install — no Homebrew needed.
2. The build is ad-hoc signed, so macOS blocks it on first launch: right-click the app and
   choose **Open**, or run
   `xattr -dr com.apple.quarantine /Applications/SheepRadius.app`.
3. The first time you start the servers, macOS asks whether to allow incoming connections —
   **Allow**, or the switch/AP will never reach them.

The servers are children of the app and never outlive it: quitting, force-quitting or even
killing SheepRadius stops radiusd and slapd too, so nothing is left holding a port.

## Quick start

1. **Clients (NAS)** → **Add Client**. Give it a name, the switch/AP's IP (or a CIDR like
   `10.0.0.0/24`), and a shared secret you invent.
2. **LDAP** on (the sidebar switch), then **Users** → **New OU** to make an organisational
   unit (they nest, like `Staff/IT`), then **New user**; drag a user onto another OU to move
   them. **Groups** → who is a member. Directory edits are live: there is no Apply here, each
   one says "saved · 0.3 s", and deleting an OU asks first, says how many accounts it will
   move to the top level rather than take with it, and can be undone. A container one of the
   directory's own — `CN=Users`, `OU=Domain Controllers` — can be looked in but is never
   somewhere new objects are made, and the tree says so.
   **Policy** → the VLAN and reply attributes each group grants, in priority order, and any
   [conditional rules](#conditional-policy). Users and Groups say who exists; Policy says what
   they get, and both show the resolved reply.
3. **Start All** (⌘R) on the Status pane, or the two sidebar switches. Status lists this Mac's
   IPv4 addresses — use the one on the same segment as the device.
4. On the switch/AP, point RADIUS at that IP with the same shared secret, then authenticate.
5. Watch the accepts and rejects on **Status**, and the raw exchange on **Log**. **Apply**
   (⌘S) is RADIUS's: clients, policy and the RADIUS server's own settings are inert until you
   press it. Nothing under DIRECTORY ever raises it. **Stop All Servers is ⌘⇧.** — it used to
   be ⌘., which is also how a person dismisses a sheet, and a sheet passed the key straight
   through to it.

**RADIUS ▸ Server** says whether radiusd is running and starts or stops it, the same way the
sidebar switch does — the pane named after the server used to show only the directory's state.

The Log pane has **Copy** and **Save…** for whatever it is showing — the filter applied, the
clock localised, the passwords masked unless **Show passwords** is on, so what you send someone
is what you were looking at. It shows the verdicts, the modules and which rules fired. Its
**Debug (-xx)** switch
adds the per-condition trace and the TLS session details — and roughly halves what the server
can answer per second, so it is off unless you are chasing something. Turning it on or off
restarts the RADIUS server.

**The panes are the controls; the explanations are behind the small “?” beside a card's
title.** Nothing was thrown away when they moved there — click one and the whole paragraph is
in the popover, selectable.

**The Log pane follows what you are doing.** It switches to RADIUS when you start RADIUS, to
LDAP or AD DC when you start a directory or change backend, and stays where you put it if you
pick a feed by hand — until the mode changes again. It opens on the newest line and keeps up;
scrolling up pauses that and a **Jump to latest** pill starts it again. Every timestamp in the
app — the three servers' own lines, Recent authentications, the sync log — is this Mac's local
clock as `HH:mm:ss`, whatever the server wrote (Samba stamps UTC, slapd hex seconds).

## Policy

**Policy is one ordered list.** It is evaluated top to bottom; a matching rule normally stops
the walk, so the first match wins. Group membership, a specific username, an OU, an SSID or
any request attribute are conditions in that same list. Users and Groups contain identity only;
every VLAN and reply attribute is edited here.

Put specific rules above general group rules. If no rule matches, authentication is still
accepted but RADIUS sends no VLAN, so the switch or AP keeps the port/SSID's own VLAN.

**A rule you have just added is a draft.** So is a client you have just added under Clients.
Until it is finished its complaints are drawn beside it and nothing else in the app is held up:
Apply still works, every other pane still saves, and what gets written is everything except the
unfinished row. **Revert** asks first and says what it is about to throw away.

**A rule names its group and its OU**, and it names them the way the directory does — the same
names RADIUS publishes as `Sheep-Group` and `Sheep-OU`. So a group you make in Users ▸ Groups
can be used in a rule straight away, and a rule that names a group the directory does not have
yet is kept and flagged rather than refused: it simply never matches until the group exists.

A rule is *IF all of / any of* these conditions *THEN* these actions:

| Conditions | |
|---|---|
| Group is / is not | matched against the user's group list |
| OU is / is under | `Staff/IT`, or everything below `Staff` |
| User-Name is / ends with / matches | an exact user, a suffix such as `@example.com`, or a regular expression |
| NAS-IP-Address is / in | a single address, or a CIDR like `10.20.0.0/24` |
| NAS client is | picked from your Clients table |
| NAS-Identifier is / matches | the name the switch or AP calls itself |
| NAS-Port-Type is | Ethernet, Wireless-802.11, or Virtual |
| SSID is | compares the part after the last colon in `Called-Station-Id` |
| Called-Station-Id is | the whole value, exactly as the AP sends it — `SIAM-BUILDING:test2` |
| Called-Station-Id begins with | a prefix; `SIAM-BUILDING:` is every SSID in that AP group |
| Station MAC is / matches | `aa:bb:…`, `AA-BB-…`, `aabb.ccdd.eeff` and `aabbccddeeff` all match |
| Time is within | a time-of-day window and a set of weekdays, in this Mac's local time |
| Identity is a computer account | a domain-joined machine rather than a person |
| Raw condition | unlang, written by hand |
| Anyone | always matches; useful as a final default |

Every one of those is in the dropdown, in four sections — *the account*, *where the request
came from*, *what it came over*, *anything else*. Turning **Also send attributes** off stops the
lines being sent and **keeps the text**: the rule says so, and Apply is what finally discards
it, so changing your mind before then costs nothing.

| Actions | |
|---|---|
| VLAN | the Tunnel trio, written with `:=` |
| Reply attributes | `Name = value`, `:=` or `+=`, one per line |
| Session-Timeout | seconds |
| Reject | with an optional Reply-Message |
| *(none)* | a rule with no action just stops the walk, shielding the rules below it |

**Preview** takes the request attributes a rule might test — NAS IP, SSID, port type, MAC, the
time — and shows exactly which rules fire and what the final reply is. It is worked out by the
same code the test suite compares against the real server, request for request.

**Advanced** shows the generated unlang read-only, with a copy button, and takes a block of
**custom unlang** that runs after every rule. Apply asks radiusd to parse the whole
configuration on a staged copy first and refuses — naming the file and line — rather than
leave a broken one behind, so the server you are already running keeps serving.

Status ▸ Recent authentications names the rules that fired for each request, and the Test pane
says so under the verdict when you aim it at this Mac.

The rules are written into the inner tunnel as well as the outer server, and since build 11
that arrangement is **measured rather than assumed**: a PEAP or EAP-TTLS login evaluates the
rules exactly once, the NAS attributes from the outer request are visible to it, the VLAN it
decides arrives in the outer Access-Accept, and a Reject decided inside the tunnel rejects the
outer session. See **Testing PEAP, EAP-TTLS and EAP-TLS** below.

> One thing a tunnel does not carry: a Reject rule's **Reply-Message**. FreeRADIUS answers the
> outer request with a bare EAP-Failure, so the message only reaches a PAP, CHAP or MS-CHAP
> client. The Log pane still has the reason.

## What the NAS and the supplicant need

> **Directory ▸ Device settings has this per product.** Pick your box — iMaster NCE-Campus,
> ClearPass, Windows, FortiGate or a generic LDAP form — and you get a two-column table of
> *the label on that product's own form* and *the value to paste into it*, every value copyable
> and every value live: it follows this Mac's current address and your applied settings, so it
> is never a stale example. The tables below are the same values without the product wording.

**For RADIUS (802.1X, wired or wireless, or admin login):**

| | |
|---|---|
| Server | your Mac's IP |
| Auth port | `1812` (accounting `1813`) |
| Shared secret | whatever you typed in **Clients (NAS)** |
| VLAN | returned as `Tunnel-Private-Group-Id` by the first matching Policy rule |

The device's IP must match a client entry, or the request is silently dropped. For PEAP/TTLS
on clients that validate the server (Windows, recent Android, managed Apple devices), export
the CA from **Certificates**, install and trust it, and set the expected server name to the
certificate name from **Settings** (default `radius.lab.local`).

**For LDAP (device admin login, or a directory lookup):**

| | |
|---|---|
| Server / port | your Mac's IP — `389` plain/StartTLS and `636` LDAPS, whichever you left on |
| Base DN | `dc=lab,dc=sheep` — the lab domain, see below |
| User filter | `(sAMAccountName=%s)` — or `(uid=%s)` |
| User bind DN | `uid=<user>,ou=<OU path, leaf first>,dc=lab,dc=sheep` |
| Group attribute | `memberOf` |
| Group DN | `cn=<group>,ou=groups,dc=lab,dc=sheep` |
| Admin bind DN | `cn=Administrator,cn=Users,dc=lab,dc=sheep` + the admin password |

### One lab, one name

**The lab has a single domain name and both backends answer for it.** Directory ▸ Server ▸
**Lab domain** (`lab.sheep` by default) is the Samba AD realm *and*, with a `dc=` per label,
the OpenLDAP base DN — so a device pointed at OpenLDAP and the same device pointed at the
domain controller are given the same base DN, the same user DN pattern and the same bind
account. Until build 24 they were two different directories with two different names, and
switching backend meant reconfiguring every device in the lab.

It can only be changed while the directory is stopped. Changing it **renames the existing
OpenLDAP database** at the next start rather than rebuilding it: the directory is exported,
every DN is rewritten and it is loaded back, so the accounts, groups, OUs and passwords are
the ones that were there before. The database as it was is kept in `ldap/data.before-rename`.
A base DN you set by hand is left exactly as it is, and the pane says that it differs from the
lab domain.

**The administrator is `cn=Administrator,cn=Users,<base DN>`**, with the password from the
same pane (`p@ssw0rd` by default) — the shape Active Directory uses, so the value a NAC wants
is the same string whichever backend it is talking to. Both the `cn=Users` container and the
account are real entries, so the DN resolves in a search; the password itself is slapd's
`rootpw`, which is what lets that one account read the NT hash.

A lab that was still on build 23's defaults (`cn=admin,<base>` and `admin123`) moves to the
new pair when it is opened. A lab with a password you chose keeps the bind DN its devices were
configured with.

**Plain LDAP and LDAPS are separate switches** (Settings → LDAP), so you can run either or
both — including LDAPS only, with nothing listening in the clear. StartTLS comes with the
plain port whenever LDAPS is also on; it cannot be turned off on its own, because slapd's TLS
configuration is global.

**Both listeners are on by default.** The certificate is issued to this Mac by the same
test CA as RADIUS and lists every address the Mac currently has, so pointing a device at the
IP works — import the CA from the **Certificates** pane on the device, or switch its
certificate validation off for a quick test. If the Mac changes network, the LDAP certificate
is reissued automatically; the RADIUS one deliberately is not, so supplicants that already
trust it keep working.

Settings → LDAP shows all of these with a copy button next to each. Every enabled user is
also a member of `cn=netusers,ou=groups,<base>` — a single group to match on when the device
just needs "is this account allowed in".

## Testing someone else's server

The **Test** pane doubles as a general client, in the spirit of NTRadPing — useful when the
question is "is it my server or my device?" and the server is not this Mac.

Switch **Target** to *Another server…* and **Credentials** to *Enter manually*:

- **RADIUS** — host, auth and accounting ports, shared secret, PAP / MS-CHAP / EAP-MD5,
  timeout and retries, and the request attributes a real NAS would send
  (`NAS-IP-Address`, `NAS-Identifier`, `NAS-Port-Type`, `Called-Station-Id`,
  `Calling-Station-Id`, plus free `Name = value` lines). You also get an **Accounting
  Start/Stop** and a **Status-Server** ping. The result shows the verdict, the round-trip
  time, and the reply attributes as a list — with the three tunnel attributes summarised as
  "VLAN 10", because apart they mean nothing.
- **LDAP** — a URL or host + port + transport (plain / StartTLS / LDAPS), a search bind DN or
  `user@domain` (or anonymous search), base DN, filter, attributes, and certificate verification
  against system trust, this lab's CA, a CA file of your choosing, or not at all. The test first
  resolves the username to exactly one DN, then binds as that user with the password above;
  success of the search account itself is never reported as success for the user.

**Run says why it is off.** Every reason is a sentence under the button — an empty username,
a missing server address, a private key chosen without its certificate, a tool this build does
not carry. Two more are warnings rather than refusals, said before you spend a timeout finding
out: the server you are aiming at is stopped, or there are changes you have not applied yet.
And a check runs the thing it is named after: **LDAPS bind** either binds over LDAPS or refuses
with "LDAPS is off under Directory ▸ Server." It will not quietly fall back to plain LDAP and
report success. The shared secret follows the server you point at, so retargeting the pane
cannot send the previous server's secret.

**"No response" is a verdict, not an error.** A RADIUS server answers a request it dislikes
by discarding it, so silence almost always means the shared secret is wrong or this Mac's IP
is not registered as a client on that server — and the pane says so instead of leaving you to
guess. LDAP failures get the same treatment: a bare `49` becomes "the password is wrong", and
Active Directory's `data 533` becomes "the account is disabled".

> **Secrets.** A shared secret is kept in your login Keychain, per server and port, and only
> when you press *Remember*. A manually typed password is never written anywhere at all. And
> neither is ever passed on a command line — `ps` is readable by anyone logged in, so the
> secret goes to radclient through `-S <file>` and the bind password to the OpenLDAP tools
> through `-y <file>`, both 0600 and both deleted as soon as the tool exits.

## Testing 802.1X — PEAP, EAP-TTLS and EAP-TLS

`radclient` speaks PAP, CHAP, MS-CHAP and EAP-MD5 and nothing else, so for a long time the
tunnelled methods — the ones people actually use for Wi-Fi — could only be tested by joining
the SSID from a real laptop. The Test pane now drives **`eapol_test`**, a supplicant
*simulator* from the wpa_supplicant project, bundled inside the app.

Pick **802.1X (PEAP-MSCHAPv2)**, **802.1X (EAP-TTLS)** or **802.1X (EAP-TLS)** from the
**Check** list — they are named for the protocol rather than the medium, because it is the same
exchange on a switch port as on an access point — and you get the fields a supplicant has and a
radclient request does not:

- an **outer identity** (`anonymous@lab`), so the real username exists only inside the tunnel —
  which is also where a Policy rule's group and OU conditions are evaluated;
- **server-certificate validation**: this Mac's test CA, a CA file of your own, or *don't
  verify* with a warning attached, because not verifying means anything on the network can
  answer as your server, collect the inner MSCHAPv2 exchange and crack it offline;
- an optional **expected server name**;
- a **client certificate** for EAP-TLS: a `.p12` and its password, or a certificate and a key.
  EAP-TLS has no password of its own, so the Password row is replaced by these — see **Client
  certificates for EAP-TLS** below;
- an **Offer TLS 1.3** switch — wpa_supplicant keeps TLS 1.3 off for EAP unless asked, since
  PEAP over 1.3 is not standardised, so without this the handshake lands on 1.2 however high
  you set RADIUS ▸ Server's *TLS max version*.

The result names the EAP method and TLS version that were negotiated (and the cipher suite,
when the target is this Mac), the server's certificate chain with issuer, expiry and SANs,
whether validation passed, and whether **MPPE keys** came back — a reply without them means
RADIUS said yes and a real access point would still have nothing to install. Failures are
translated: unknown CA, name mismatch, TLS alert, a wrong password inside a tunnel that came up
perfectly, or silence with the same three causes as a PAP timeout. The raw log is there,
collapsed, when you want it.

**What it does not test.** `eapol_test` speaks EAP straight to RADIUS over UDP and never sends
an EAPOL frame, so it proves the *server* and says nothing about the Wi-Fi or the switch port:
an access point that mangles EAP, a switch in the wrong port mode, or a device profile with the
wrong CA are all still invisible from here. For those, join with a real device and watch Status
and Log.

**Building it.** There is no Homebrew formula for `eapol_test`, so it is built from source once
by `Tools/build-eapol-test.sh` (BSD licence) and the ~900 KB result is committed to `Vendor/`.
The committed build has PKCS#12 support compiled out, so the Test pane opens a `.p12` with the
bundled openssl and hands the supplicant the two PEM files it gets — written 0600 beside the
configuration and deleted with it.

## Client certificates for EAP-TLS

EAP-TLS is the one method with no password: the certificate *is* the credential. **Users ▸
Properties ▸ Issue client certificate…** issues one from this lab's own CA — the common name is
the account's user name and the subject alternative name is its principal (`alice@lab.sheep`),
both shown rather than offered, because the server checks the common name against the user name
being claimed and only one value can work.

You choose how long it lasts and a password for the `.p12`, and the file goes wherever the save
panel points. **The private key is not kept here.** It exists for the moment between the
request and the bundle and is then deleted, so the `.p12` is the only copy — written 0600,
carrying this lab's CA as well as the certificate, and encoded the way Windows and iOS can
actually import (OpenSSL 3's defaults are not).

**Every ordinary account can be issued one**, wherever it lives in the directory — including
`CN=Users`, which is where a real domain keeps its users. Only a built-in account
(Administrator, Guest, krbtgt, anything under `CN=Builtin`) and a machine or service account
(`NAME$`) are left out, because there is no person behind either to carry the certificate.

**Certificates ▸ Client certificates** lists every one this lab has issued, with its serial,
dates and status, and revokes one — and so does **Users ▸ Properties**, beside the button that
issued it, which is where you are when you want it. When Revoke is unavailable it says which of
the three reasons it is. Revoking rewrites `certs/crl.pem` and **restarts the RADIUS
server**: FreeRADIUS reads the revocation list when it starts a module and not on a reload —
measured, not assumed — so a revocation that waited for the next restart would be a revocation
the pane claimed and the server ignored. An export, an import and a backup carry the issued
certificates, the revocation list and the CA database with the rest of `certs/`.

**A new CA invalidates every one of them.** Certificates ▸ **New CA…** says how many will stop
authenticating before you press it, and afterwards each one reads **Superseded by a new CA**
rather than "Valid" — they were signed by a CA that no longer exists, which is also why they
cannot be revoked: there is nothing left to revoke them with. Issue new ones. The other two
**Reissue…** buttons confirm as well now, and each says what it will restart; the RADIUS one
also says what it breaks, because Apple supplicants pin that certificate when their user taps
Trust.
An ordinary build of the app needs neither the source nor the script.

## Machine authentication (Samba AD)

A domain-joined Windows PC authenticates **as the computer** when nobody has logged in yet —
at the switch port before the sign-in screen, and on Wi-Fi profiles set to "Computer
authentication". It sends the machine account's password inside PEAP-MSCHAPv2 under an
identity like `host/pc.lab.sheep`, and until build 24 SheepRadius rejected it: the directory
snapshot kept users and dropped every computer account.

In AD mode the computers are now in the RADIUS user list. Nothing has to be configured — the
machine accounts the domain already has are picked up with everything else, and their NT
hashes come from the domain the same way a user's does. Windows sends one of five different
identities depending on its version and the profile, so all five are written:
`host/pc.lab.sheep`, `host/pc`, `LABSHEEP\PC$`, `PC$` and `pc$@lab.sheep`.

Each one is tagged with the group **`Domain Computers`**, and Policy has a condition
**"Identity is a computer account"** so a rule can give machines a VLAN of their own. Recent
authentications shows the identity the supplicant sent.

Computers stay out of Users and Groups, as they always have — they are listed under
**Status ▸ Joined computers**. OpenLDAP cannot be joined at all, so none of this applies to it.

## NAC servers without a domain join

Aruba ClearPass and Huawei iMaster NCE can do PEAP-MSCHAPv2 against SheepRadius without any
Active Directory, using a **generic LDAP authentication source**:

1. Leave **Publish NT hashes for NAC servers** on (Settings → LDAP; it is on by default).
2. On the NAC, add a generic LDAP authentication source pointing at your Mac's IP, port 389.
3. Bind as `cn=Administrator,cn=Users,dc=lab,dc=sheep` with the admin password.
4. Set the password attribute to **`sambaNTPassword`** and the password type to **NT hash**.

Each user then carries the NT hash of their password, which is what MSCHAPv2 needs. The
attribute is password-equivalent and only the admin bind DN can read it.

> This route needs no domain at all. If you want a **real** one — a PC that joins, a
> Kerberos ticket, `Join AD Domain` on a NAC — switch the LDAP directory to **Samba AD**
> (below). OpenLDAP itself cannot do any of that: no Kerberos, no SMB, no Netlogon.

## AD Domain mode

The **OpenLDAP / Samba AD** choice under the sidebar's LDAP switch — the same setting as
Directory ▸ Server ▸ **LDAP directory** — picks between:

- **OpenLDAP** — the built-in directory. 16 MB, starts instantly, cannot be joined.
- **Samba AD** — a **Samba 4 Active Directory domain controller** in a Linux container,
  which a Windows PC can genuinely join. Verified: a Windows 11 Pro notebook joined
  `lab.sheep` over the LAN and a domain user logged in.

Either one is greyed while a directory — or RADIUS — is running: stop it before switching.
Note that the **RADIUS switch always brings up OpenLDAP**, so the way to run RADIUS against
the domain is to start Samba AD first and turn RADIUS on afterwards.

The two are mutually exclusive — both want 389 and 636.

### What it costs

| | |
|---|---|
| RAM while running | ~600–700 MB for the DC (plus ~150 MB of `container` daemons) |
| Disk, image | ~100 MB as a `.tar`; the state volume is 4 GB sparse and a fresh domain uses ~36 MB |
| Cold start (empty volume → LDAP answering) | ~30 s, including provisioning |
| Warm restart | 2–5 s |
| Prerequisite | Apple's `container` 1.4.1+ (`brew install container`) — the one thing the app cannot bundle |

### Setting it up

1. Directory ▸ Server ▸ **Build image** (a couple of minutes; it pulls Debian's arm64 base
   image and Samba's packages).
2. Set the **realm** — something like `lab.sheep`. **Not a `.local` realm**: macOS resolves
   `.local` through Bonjour and a domain there can never be found. The app refuses one.
3. Press **Generate** for the Administrator password, then start the domain controller.

The app binds **DNS on port 53** itself, before any container starts, and forwards it to the
DC. That ordering is not optional: macOS hands port 53 to mDNSResponder the moment the first
container comes up and does not give it back.

Users, groups and OUs come from the same table as everything else and are synced into
`OU=SheepRadius` on every Apply. **Nothing outside that OU is ever modified or deleted** —
not the built-in containers, not the machine account of a PC that joined, not an account you
made by hand. A name that collides with one of those is reported, never overwritten.

> **Group names are domain-wide.** A group's `sAMAccountName` is unique across the whole
> domain, so a group called `Guests` in this app is not a new group — it is AD's built-in
> `CN=Guests,CN=Builtin`, and syncing one would add your users to *that*. The app refuses
> every name Windows already uses (`Guests`, `Users`, `Administrators`, `Domain Admins`,
> `Domain Users`, `Backup Operators`, `Protected Users`, `DnsAdmins` and the rest) and tells
> you to rename — `Visitors` instead of `Guests`. The sample lab ships `Visitors` for exactly
> this reason. *(Found on a live domain on 18 Sep 2026, when a real user ended up a member of
> `BUILTIN\Guests` and of nothing else, and her Wi-Fi authorisation broke on the NAC after
> the domain controller had already accepted her password.)*

### Watching authentication

The domain controller's own log is in the app, and so are its verdicts:

- **Status ▸ Recent authentications** shows AD logons tagged **AD**, next to the RADIUS ones —
  who, from which computer, how (MSCHAPv2, NT hash, Kerberos, a plaintext LDAP bind) and, on a
  failure, why in English: *wrong password*, *no such user in this domain (came as
  `OTHERDOMAIN\name`)*, *account locked out*, *NTLM/MSCHAPv2 blocked by DC policy*. A computer
  setting up its secure channel shows as *computer NAME joined/authenticated* and refreshes the
  Joined-computers card. Identical events in a row — iMaster re-binds every thirty seconds — are
  folded into one row with a count.
- **Log ▸ AD DC** is the raw `container logs` stream, with an **Auth only** filter.
  `NT_STATUS_OK` is green and every other `NT_STATUS_` is red.
- The **client** column is the workstation the request named, never the remote address: every
  device reaches the DC across the same vmnet bridge, so the address is `192.168.64.1` for all
  of them. A joined iMaster NCE-Campus node is labelled *iMaster (OMP)*.

This needs Samba's authentication audit, which the image turns on
(`log level = 1 auth_audit:3`) — **at Samba's stock `log level = 1` a domain controller
records no authentication at all**. If Directory ▸ Server says the image is a build behind,
press **Rebuild image**, then stop and start AD mode; the app also pushes the level into a
running older DC with `smbcontrol` so events appear before the rebuild, but that is lost on
the next restart.

The image also sets `ntlm auth = mschapv2-and-ntlmv2-only`. Samba's default `ntlmv2-only`
refuses a bare MSCHAPv2 Netlogon request, which is what a NAC doing PEAP-MSCHAPv2 sends.

### Joining a device

Directory ▸ **Device settings** has the whole thing, copyable. Two things sink most first
attempts, so they are the first two things on that screen:

- **The domain is `lab.sheep`. The domain controller is `dc1.lab.sheep`.** Windows wants the
  *domain* in its Domain field; typing the controller's name there fails with a message that
  never mentions why. ClearPass's join form asks for the controller.
- **Set the device's DNS to this Mac's IP first**, manually, and remove the alternates — a
  router-supplied IPv6 DNS server will quietly bypass it.

Directory ▸ **Device settings** ▸ *What to type into each product* has the **iMaster
NCE-Campus** form filled in field by field (Server type, Data source name, Primary server
address, Authentication port, AD domain name, AD short domain name, Base DN, Synchronization
account and password), plus ClearPass, Windows and a generic LDAP form. The Synchronization
account is `CN=Administrator,CN=Users,<base DN>`; `Administrator@<realm>` works too, and
`DN=administrator,DC=…` does **not** — iMaster reports that as "username/password incorrect",
which sends you looking at the password instead of the account.

**PEAP-MSCHAPv2 against this domain works** (verified 18 Sep 2026). The domain controller
evaluates MSCHAPv2 over Netlogon, so a `WRONG_PASSWORD` in Status ▸ Recent authentications
means the Wi-Fi client typed a different password — or a different username form — from the
account, not that the directory is wrong. iMaster NCE-Campus joins as several machine
accounts (`OMP`, `SERVICE1`, `DATABACKUP` on the lab it was verified against); all of them
appear under Joined computers.

**If the domain was already there** (the app adopted an existing state volume), the
Administrator password is the one that domain was created with. Typing a new one in Settings
does not change it — and the sync will not complain, because a sync runs inside the controller
and never authenticates. The self-test will: its `kinit`, LDAP bind, SMB and DNS-zone checks
say "password rejected by the domain", and offer a button to set the domain's Administrator
password to the one in Settings.

Directory ▸ Server ▸ **Run AD self-test** checks the lot from the Mac's own LAN address: the
ten DNS names a join looks up, DNS over TCP, a CLDAP netlogon ping on udp/389 (which is how
Windows *chooses* a controller — TCP 389 being open proves nothing about it), every port a
join opens, a Kerberos ticket, an LDAP simple bind and the SMB share list.

### On a second Mac

See **Move this lab to another Mac** below — one file, one button, and the domain keeps its
SID so every machine that joined stays joined.

> RADIUS authenticates from the directory in both backends — it has no accounts of its own.
> `raddb/authorize` is rewritten from the domain after every change (a `HUP`, not a restart).
> An account whose password this app set is written with its cleartext password; one changed in
> ADUC or on a joined PC is written as the `NT-Password` hash pulled out of the domain, which
> covers PAP, MS-CHAP and PEAP but not CHAP.

## Move this lab to another Mac

Everything a lab is — the users, the certificates, the RADIUS configuration and, in AD mode,
the domain itself — goes into one file.

1. **Settings ▸ Move this lab ▸ Export lab…** on the Mac that has the lab. The servers stop
   for as long as it takes to write the file and start again afterwards. You get
   `SheepRadius-lab-<date>.sheeplab`: `lab.json`, `raddb/`, `certs/`, the directory, and in AD
   mode the container image (~99 MB) plus the domain's state volume.
2. Copy `SheepRadius.app` and that file to the other Mac. In AD mode, `brew install container`
   there first — the image travels in the file, so nothing is downloaded.
3. **Settings ▸ Move this lab ▸ Import lab…** there. A sheet shows the realm, the counts, the
   computers that joined and the size before anything is unpacked, and says what will be
   replaced. Whatever was on that Mac is backed up first, automatically.
4. Press **Start**. The Status pane shows the new address — every device, switch and NAC in the
   lab is still pointed at the old Mac and has to be re-pointed by hand.

**Only one Mac may run the domain controller at a time.** Stop it on the old Mac before you
start it on the new one: two controllers with the same domain SID on one network is a fault
that is invisible from either of them, because a joined computer talks to whichever one DNS
answered with first. The app refuses to start a controller when another one on the network is
already answering for the realm — but it cannot stop the other Mac for you.

**Backups** use the same file. *Backup now* writes one into
`~/Library/Application Support/SheepRadius/backups/`, *Restore…* puts one back, and the last
five are kept. One is taken automatically before an import, before removing the AD components,
and before switching the directory backend.

## ⚠️ Lab use only

- **Passwords are stored in cleartext on disk** (`lab.json` and `raddb/authorize`, in a 0700
  directory). This is not laziness: PEAP-MSCHAPv2 cannot authenticate from a hash. The LDAP
  copy is `{SSHA}`-hashed and the NT hash is MD4 — both password-equivalent, both readable
  only by the admin DN.
- The RADIUS server and LDAP directory listen on **all interfaces**. Run this on a lab
  segment. **Do not expose it to an untrusted network**, and do not point production gear at
  it.
- The CA and server certificate are throwaway test credentials. Do not install the CA on a
  machine you care about beyond the lab.
- **The download bundles third-party servers under their own licences** — see
  [Third-party software](#third-party-software). Their source is linked there.
- Keep the lab folder path short. FreeRADIUS cannot read a configuration directory longer
  than 200 characters, so SheepRadius refuses a lab folder over 194 and says so — the
  default location is nowhere near that.
- Not a directory server, not a production AAA. It is a test rig you can delete by throwing
  away `~/Library/Application Support/SheepRadius/`.

## Third-party software

The app bundle carries these programs and libraries, unmodified except that their load paths are
rewritten to point inside the bundle. Each remains under its own licence. The licence texts are
inside the app at `SheepRadius.app/Contents/Resources/Licenses/` (Environment ▸ Open-source
licences ▸ Show), and the **complete corresponding source** for every one — the upstream
tarballs, the patches Homebrew applied and the scripts that bundle them — is published in the
[sources-2.0 release](https://github.com/bestonehxh/SheepRadius/releases/tag/sources-2.0).

| Component | Version | Licence |
|---|---|---|
| FreeRADIUS server | 3.2.10 | GPL-2.0-or-later (libfreeradius-radius: LGPL-2.1-or-later) |
| OpenLDAP | 2.7.1 | OpenLDAP Public License 2.8 |
| OpenSSL | 3.6.4 | Apache-2.0 |
| talloc | 2.5.0 | LGPL-3.0-or-later |
| GNU Readline | 8.3 + patches 001–006 | GPL-3.0-or-later |
| wpa_supplicant (`eapol_test`) | 2.11 | BSD-3-Clause |

`radiusd`, `radclient` and `radeapclient` link GNU Readline and are therefore distributed under
the GNU GPL version 3, which FreeRADIUS's "or later" licence allows. SheepRadius's own code runs
these servers as separate programs and is MIT-licensed.

## Acknowledgements

- [FreeRADIUS](https://freeradius.org) 3.2.10 (GPLv2) — the RADIUS server
- [OpenLDAP](https://www.openldap.org) 2.7.1 (OpenLDAP Public License) — slapd and the
  client tools
- [OpenSSL](https://www.openssl.org) 3.6.4 (Apache-2.0) — TLS and certificate generation
- [wpa_supplicant](https://w1.fi/wpa_supplicant/) 2.11 (BSD) — `eapol_test`, the supplicant
  simulator that makes PEAP / EAP-TTLS / EAP-TLS testable

## License

The SheepRadius source is available under the [MIT License](LICENSE). Bundled third-party
components remain under their respective licenses listed above.
