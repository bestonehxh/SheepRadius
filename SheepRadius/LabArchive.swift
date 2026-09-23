import CryptoKit
import Foundation

// MARK: - What is in a .sheeplab

/// The manifest at the root of a `.sheeplab` file: everything the Import sheet has to show
/// **before** anything is unpacked.
///
/// A person importing a lab on a second Mac is about to overwrite a directory, load a 99 MB
/// image and create a volume. The one thing they need first is "is this the lab I think it
/// is, and is it the one already running on the Mac I am standing at?" — which is why the
/// realm, the counts and `labID` are here and not only inside the payload.
///
/// `labID` is per **lab**, not per export: exporting twice gives two files with the same id,
/// and that is the point — importing either one onto a Mac that already has that lab is the
/// clash the sheet warns about (`LabImportPreview.clash`).
nonisolated struct LabManifest: Codable, Sendable, Equatable {
    /// Bumped when the layout inside the zip changes. An importer that does not know a
    /// version refuses rather than guessing.
    static let currentFormat = 1

    var format = LabManifest.currentFormat
    var labID: UUID
    var created: Date
    var appVersion: String
    /// `lab.sheep` in AD mode, `dc=lab,dc=local` in OpenLDAP mode — whichever one a person
    /// would recognise the lab by.
    var realm: String
    var backend: DirectoryBackend
    var userCount: Int
    var groupCount: Int
    /// `BEST$`, `NATCHANON-T14$` — the machine accounts that will keep working, which is the
    /// whole reason for moving a volume rather than re-provisioning.
    var joinedComputers: [String] = []
    /// Bytes per component, for the sheet's "this will take 112 MB" line.
    var sizes: [String: Int] = [:]
    /// The image the DC was running, e.g. `sheep-ad-dc:3`. Empty in OpenLDAP mode.
    var imageReference = ""
    /// The volume the state came out of — recorded, not imposed: the import may put it under
    /// a different name, and the `ad` suite does exactly that.
    var volumeName = ""
    /// SHA-256, lower-case hex, of the payloads that are **executed** rather than read:
    /// `ad-image.tar` and `ad-state.tar`, keyed by the same entry names.
    ///
    /// Build 20, audit finding N-1. `LabTransfer.importDomain` runs `container image load` on
    /// the image in the archive and `ADController.start` then runs it with
    /// `--cap-add CAP_SYS_ADMIN` and thirteen published host ports — so until this existed, a
    /// `.sheeplab` a person was handed was an executable somebody else had written. The
    /// digest does not make the author trustworthy; it makes the file the author actually
    /// exported the only one that will run, which is what a checksum can honestly do.
    var digests: [String: String] = [:]

    /// Does the archive contain a container image at all? The import sheet says so out loud.
    var carriesContainerImage: Bool { digests[LabArchiveEntry.image] != nil || sizes[LabArchiveEntry.image] != nil }

    /// `a1b2c3d4…` — the first twelve characters, the length a person can actually compare.
    static func shortDigest(_ hex: String) -> String {
        hex.isEmpty ? "—" : String(hex.prefix(12))
    }

    var totalBytes: Int { sizes.values.reduce(0, +) }

    /// "112.4 MB" — the same rounding `ADController.megabytes` uses.
    static func bytes(_ count: Int) -> String {
        let mb = Double(count) / 1_048_576
        if mb < 1 { return String(format: "%.0f KB", Double(count) / 1024) }
        if mb < 1024 { return String(format: "%.1f MB", mb) }
        return String(format: "%.2f GB", mb / 1024)
    }

    /// `SheepRadius-lab-2026-09-18.sheeplab`. Date only: two exports on one day overwrite
    /// each other in a Save panel, where the person can see it happening and rename.
    static func suggestedFilename(on date: Date = Date()) -> String {
        "SheepRadius-lab-\(dayStamp(date)).sheeplab"
    }

    /// `2026-09-18`, built by hand — **no `DateFormatter` anywhere in this app** (build 16's
    /// rule, after a Buddhist-calendar year leaked into the Log pane).
    static func dayStamp(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// `2026-09-18 21:04` for the Restore list.
    static func stamp(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return String(format: "%04d-%02d-%02d %02d:%02d", parts.year ?? 0, parts.month ?? 0,
                      parts.day ?? 0, parts.hour ?? 0, parts.minute ?? 0)
    }

    /// The lines the preview and the export confirmation both show, in one place so they
    /// cannot describe the same file differently.
    var lines: [String] {
        var out = ["Realm · \(realm)",
                   "Backend · \(backend == .activeDirectory ? "Active Directory" : "OpenLDAP")",
                   "Users · \(userCount)   Groups · \(groupCount)",
                   "Created · \(Self.stamp(created)) by build \(appVersion)"]
        if !joinedComputers.isEmpty {
            out.append("Joined computers · " + joinedComputers.joined(separator: ", "))
        }
        if !imageReference.isEmpty { out.append("Image · \(imageReference)") }
        if let digest = digests[LabArchiveEntry.image] {
            out.append("Image SHA-256 · \(digest)")
        }
        if !volumeName.isEmpty { out.append("State volume · \(volumeName)") }
        out.append("Size · \(Self.bytes(totalBytes))")
        return out
    }
}

/// The names inside the zip. One list, so the writer and the reader cannot drift.
nonisolated enum LabArchiveEntry {
    static let manifest = "manifest.json"
    static let document = "lab.json"
    static let raddb = "raddb"
    static let certs = "certs"
    static let ldap = "ldap"
    static let image = "ad-image.tar"
    static let volume = "ad-state.tar"

    /// What the export copies wholesale, as (directory name) pairs.
    static let directories = [raddb, certs, ldap]
}

// MARK: - Is the file what it says it is? (build 20, audit N-1 / N-2 / N-3)

/// SHA-256 over a file, without reading it into memory.
///
/// `ad-image.tar` is about 99 MB and `ad-state.tar` can be larger; `Data(contentsOf:)` would
/// hold the whole of it while the app is mid-import. 1 MB at a time is enough to keep the
/// hashing cost invisible next to the `container image load` that follows.
nonisolated enum LabDigest {
    static let chunk = 1 << 20

    static func sha256(ofFileAt url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            guard let data = try? handle.read(upToCount: chunk), !data.isEmpty else { break }
            hasher.update(data: data)
        }
        return hex(hasher.finalize())
    }

    static func sha256(of data: Data) -> String { hex(SHA256.hash(data: data)) }

    /// Lower-case hex. `Digest` is a `Sequence` of bytes, and its own `description` carries a
    /// `SHA256 digest: ` prefix that must never reach a manifest.
    static func hex(_ digest: some Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Constant-time-ish comparison of two hex strings. They are public values, not secrets,
    /// so this is about being case- and whitespace-insensitive rather than about timing.
    static func matches(_ a: String, _ b: String) -> Bool {
        a.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            == b.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func isWellFormed(_ hex: String) -> Bool {
        hex.count == 64 && hex.allSatisfy { $0.isHexDigit }
    }
}

/// Every string in an imported manifest that becomes a `container` argument or a file name,
/// checked against a strict charset **before anything is executed** (audit N-2).
///
/// No shell is involved anywhere in `LabTransfer`, so this is not command injection — it is
/// **argument** injection: `container volume create -s 4G <name>` with a name of `--help`
/// changes what the command does, and `container image load -i <ref>` with a leading `-` does
/// the same. A manifest also names a file (`imageReference` reaches `ADImage`'s argument
/// builders), so `../../` has to go too.
///
/// The rule is an allow-list, not a deny-list: a lab realm, a NetBIOS name, an image reference
/// and a volume name are all drawn from a small alphabet, and anything outside it is a file
/// this app did not write.
nonisolated enum LabManifestCheck {
    /// Letters, digits, and the punctuation these four kinds of name legitimately use.
    /// Deliberately **not** including `/` for a volume name, and never `..` anywhere.
    static let volumeCharacters = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
    static let imageCharacters = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_./:@")
    static let realmCharacters = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.,= ")

    static let maxLength = 128

    /// Why this manifest cannot be acted on, or nil. One sentence, in this app's voice.
    static func problem(with manifest: LabManifest) -> String? {
        if let problem = problem(with: manifest.volumeName, what: "The state volume name",
                                 allowed: volumeCharacters) { return problem }
        if let problem = problem(with: manifest.imageReference, what: "The image reference",
                                 allowed: imageCharacters) { return problem }
        if let problem = problem(with: manifest.realm, what: "The realm", allowed: realmCharacters) {
            return problem
        }
        if let problem = problem(with: manifest.appVersion, what: "The build number",
                                 allowed: volumeCharacters) { return problem }
        for name in manifest.joinedComputers {
            if let problem = problem(with: name, what: "A joined-computer name",
                                     allowed: volumeCharacters.union(["$"])) { return problem }
        }
        // `sizes` and `digests` are keyed by entry name, and an entry name becomes a path
        // inside the staging folder.
        for key in manifest.sizes.keys.sorted() + manifest.digests.keys.sorted() {
            if let problem = problem(with: key, what: "An entry name", allowed: volumeCharacters) {
                return problem
            }
        }
        for (entry, digest) in manifest.digests where !LabDigest.isWellFormed(digest) {
            return "The digest recorded for \(entry) in that archive is not a SHA-256."
        }
        return nil
    }

    /// An empty value is allowed — an OpenLDAP lab has no volume and no image — but a value
    /// that is present has to be one this app could have written.
    static func problem(with value: String, what: String, allowed: Set<Character>) -> String? {
        guard !value.isEmpty else { return nil }
        if value.count > maxLength {
            return "\(what) in that archive is \(value.count) characters. The limit is \(maxLength)."
        }
        if value.hasPrefix("-") {
            return "\(what) in that archive begins with “-”, which Apple's container tool would read as an option rather than a name."
        }
        if value.contains("..") {
            return "\(what) in that archive contains “..”, which would point outside the lab folder."
        }
        if let bad = value.first(where: { !allowed.contains($0) }) {
            let shown = bad.isWhitespace ? "a space" : "“\(bad)”"
            return "\(what) in that archive contains \(shown), which is not a character this app writes into a lab archive."
        }
        return nil
    }

    /// The volume name a person may type into the Import sheet goes through the same gate —
    /// it reaches exactly the same `container volume create` argument.
    static func problem(withVolumeName name: String) -> String? {
        problem(with: name, what: "A state volume name", allowed: volumeCharacters)
    }
}

/// What `zipinfo` says is inside a `.sheeplab`, **before** `ditto -x -k` is allowed near it
/// (audit N-3).
///
/// `ditto -x -k` is trusted completely: it will happily write an absolute path, walk out of
/// the destination with `..`, restore a symlink that points anywhere on this Mac, and expand
/// a few kilobytes into whatever the archive says. The manifest declares its own sizes, so
/// this is the one place where "the file says 112 MB" can be turned into a rule rather than a
/// caption.
nonisolated enum ZipListing {
    nonisolated struct Entry: Sendable, Equatable {
        var name: String
        var uncompressedBytes: Int
        /// The first character of `zipinfo`'s mode column: `-` a file, `d` a directory, `l` a
        /// symbolic link, **`?` an entry whose type this Mac's unzip cannot name** — which is
        /// what Python's `zipfile` writes by default, and therefore what anything crafted is
        /// most likely to be. Kept as it came rather than reduced to two flags, because "not
        /// one of the two we accept" is the check that matters.
        var kind: Character

        var isSymbolicLink: Bool { kind == "l" }
        var isDirectory: Bool { kind == "d" }
        var isRegularFile: Bool { kind == "-" }

        init(name: String, uncompressedBytes: Int, kind: Character) {
            self.name = name
            self.uncompressedBytes = uncompressedBytes
            self.kind = kind
        }
    }

    /// `zipinfo`'s medium listing, one entry per line:
    ///
    /// ```
    /// -rw-r--r--  2.1 unx      163 bX defN 26-Sep-19 06:53 manifest.json
    /// lrwxr-xr-x  2.1 unx       11 b- stor 26-Sep-19 06:53 sub/evil
    /// ?rw-------  2.0 unx        1 b- defN 26-Sep-19 07:06 ../../escape.txt
    /// ```
    ///
    /// Eight fields before the name, and the name is everything after the time — it may well
    /// contain spaces, so it is joined back rather than taken as one field.
    ///
    /// **A line is an entry because of its shape, not because of its mode string.** The first
    /// cut of this required the mode to begin `-`, `d` or `l`, which is what `ditto` writes —
    /// and Python's `zipfile` writes `?rw-------`, so every crafted entry was skipped by the
    /// very check that was meant to catch it. The version and size columns are what identify
    /// a row; `problem` then refuses anything that is not plainly a file or a folder.
    static func parse(_ output: String) -> [Entry] {
        var out: [Entry] = []
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 9 else { continue }
            let mode = String(fields[0])
            guard mode.count >= 7, let kind = mode.first else { continue }
            // `2.0` / `2.1`: the zip version needed to extract. It is what tells an entry row
            // from `Zip file size: …` and from the `10 files, …` trailer.
            guard Double(fields[1]) != nil else { continue }
            guard let size = Int(fields[3]) else { continue }
            let name = fields[8...].joined(separator: " ")
            guard !name.isEmpty else { continue }
            out.append(Entry(name: name, uncompressedBytes: size, kind: kind))
        }
        return out
    }

    /// macOS's own metadata sidecars, which `ditto -c -k --sequesterRsrc` writes and
    /// `ditto -x -k` reads back. They are ours, they are tiny, and they are not payload.
    static func isAppleDouble(_ name: String) -> Bool {
        name == "__MACOSX" || name.hasPrefix("__MACOSX/")
    }

    static func totalUncompressed(_ entries: [Entry]) -> Int {
        entries.reduce(0) { $0 + $1.uncompressedBytes }
    }

    /// The margin over the manifest's declared total. `ditto` stores directory entries, the
    /// AppleDouble sidecars and `lab.json`'s own growth between the size being measured and
    /// the zip being written, so an exact equality would refuse the app's own exports.
    static let sizeMargin = 16 << 20
    static let sizeFactor = 1.25

    /// An archive with no manifest at all, or with two of them, is not a lab archive — and
    /// `unzip -p` on a duplicated name prints both, concatenated.
    static func problem(entries: [Entry], declaredBytes: Int?) -> String? {
        guard !entries.isEmpty else {
            return "That file has nothing in it, so it is not a SheepRadius lab archive."
        }
        for entry in entries {
            let name = entry.name
            if entry.isSymbolicLink {
                return "That archive contains a symbolic link (\(name)). A lab archive is files and folders only, and a link could point anywhere on this Mac."
            }
            if !entry.isRegularFile, !entry.isDirectory {
                return "That archive contains an entry (\(name)) that is neither a file nor a folder. A lab archive is files and folders only."
            }
            if name.hasPrefix("/") {
                return "That archive contains an absolute path (\(name)), which would be written outside the lab folder."
            }
            if name.hasPrefix("~") {
                return "That archive contains a path beginning with “~” (\(name)), which would be written outside the lab folder."
            }
            let parts = name.split(separator: "/", omittingEmptySubsequences: false)
            if parts.contains("..") {
                return "That archive contains a path that climbs out of its own folder (\(name))."
            }
            if name.contains("\u{0}") {
                return "That archive contains an entry name with a control character in it."
            }
        }
        let manifests = entries.filter { $0.name == LabArchiveEntry.manifest }
        guard manifests.count == 1 else {
            return manifests.isEmpty
                ? "There is no manifest in that file, so it is not a SheepRadius lab archive."
                : "That archive has \(manifests.count) manifests in it, so what it would install cannot be determined."
        }
        if let declaredBytes {
            let payload = entries.filter { !isAppleDouble($0.name) }
            let total = totalUncompressed(payload)
            let allowed = Int(Double(declaredBytes) * sizeFactor) + sizeMargin
            if total > allowed {
                return """
                That archive says it holds \(LabManifest.bytes(declaredBytes)) but would unpack to \
                \(LabManifest.bytes(total)). It is refused rather than filling the disk.
                """
            }
        }
        return nil
    }
}

// MARK: - What an import would do, before it does it

/// The Import sheet's contents: the manifest, whether this Mac already has the lab, and what
/// would be overwritten.
nonisolated struct LabImportPreview: Sendable, Equatable, Identifiable {
    /// Derived rather than stored, so two previews of the same file compare equal — a `UUID`
    /// here would make `Equatable` useless for the tests that are the point of this type.
    var id: String { "\(manifest.labID)-\(manifest.created.timeIntervalSince1970)" }

    enum Clash: Sendable, Equatable {
        /// A different lab entirely. The safe case, and still an overwrite.
        case none
        /// **The same lab-id.** Either this is a restore of a backup taken here, or the lab is
        /// running on the Mac it came from and is about to run in two places at once.
        case sameLab
        /// A volume of that name already exists here and holds something.
        case volumeInUse(String)
    }

    var manifest: LabManifest
    var clash: Clash = .none
    /// True when the lab folder about to be replaced is not empty.
    var replacesExistingLab = false
    /// A format from a newer build. Refused rather than half-read.
    var unsupportedFormat = false

    /// **The refusals the sheet's own prose already claimed** (build 25, QA L-17).
    ///
    /// Build 24 refused only an unsupported format, so the sheet said "A state volume called
    /// X already exists here and is not empty. Import under a different name, or remove it
    /// first." above a live **Import** button — and `restoreDomain`'s own comment
    /// ("the preview refused a volume that has content") described something that was not
    /// happening. A volume clash is refused unless the person renames it, which is exactly
    /// what the sheet's volume-name field is for.
    ///
    /// **`.sameLab` is deliberately not a refusal.** Restoring a backup taken on this Mac is
    /// `.sameLab` by definition, and it is the most ordinary thing this feature does. The
    /// warning about a second domain controller stands; it is a thing to be told, not a thing
    /// to be stopped from doing.
    func canImport(volumeName: String? = nil) -> Bool {
        guard !unsupportedFormat else { return false }
        if case .volumeInUse(let taken) = clash {
            let chosen = (volumeName ?? "").trimmingCharacters(in: .whitespaces)
            return !chosen.isEmpty && chosen != taken
        }
        return true
    }

    /// The manifest's own volume name — what an import does with nothing renamed.
    var canImport: Bool { canImport(volumeName: nil) }

    /// The one sentence above the buttons.
    var warning: String? {
        if unsupportedFormat {
            return "This file was written by a newer build of SheepRadius (format \(manifest.format)). Update the app first."
        }
        switch clash {
        case .sameLab:
            return "This Mac already has this lab. **Stop the domain controller on the other Mac first** — two controllers answering the same realm on one network is the one thing this cannot fix for you."
        case .volumeInUse(let name):
            return "A state volume called \(name) already exists here and is not empty. Import under a different name, or remove it first."
        case .none:
            return replacesExistingLab
                ? "The lab directory on this host will be replaced. A backup of it is taken first."
                : nil
        }
    }

    static func make(manifest: LabManifest, localLabID: UUID?, existingVolumes: [String],
                     labFolderHasContent: Bool) -> LabImportPreview {
        var preview = LabImportPreview(manifest: manifest)
        preview.unsupportedFormat = manifest.format > LabManifest.currentFormat
        preview.replacesExistingLab = labFolderHasContent
        if let localLabID, localLabID == manifest.labID {
            preview.clash = .sameLab
        } else if !manifest.volumeName.isEmpty,
                  existingVolumes.contains(where: { $0 == manifest.volumeName }) {
            preview.clash = .volumeInUse(manifest.volumeName)
        }
        return preview
    }
}

// MARK: - Backups

/// One file in `~/Library/Application Support/SheepRadius/backups/`.
nonisolated struct LabBackup: Identifiable, Sendable, Equatable {
    var id: String { url.path }
    var url: URL
    var created: Date
    var bytes: Int

    var label: String { "\(LabManifest.stamp(created)) · \(LabManifest.bytes(bytes))" }
}

/// Keeping the last five, and no more.
///
/// Pure, because the only interesting thing about it is *which* five — an automatic backup is
/// taken before a migration, a rebuild and a backend switch, so a bad afternoon produces
/// several and the oldest has to be the one that goes.
nonisolated enum BackupRotation {
    static let limit = 5

    /// The ones to delete, newest-first ordering imposed here rather than assumed.
    static func expired(_ backups: [LabBackup], limit: Int = BackupRotation.limit) -> [LabBackup] {
        let ordered = backups.sorted { $0.created > $1.created }
        guard ordered.count > limit else { return [] }
        return Array(ordered.dropFirst(limit))
    }

    /// `SheepRadius-backup-2026-09-18-2104.sheeplab` — to the minute, because two backups in
    /// one day is the normal case and the day stamp alone would collide.
    static func filename(on date: Date = Date()) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let parts = calendar.dateComponents([.hour, .minute, .second], from: date)
        return String(format: "SheepRadius-backup-%@-%02d%02d%02d.sheeplab",
                      LabManifest.dayStamp(date), parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0)
    }

    /// Why a backup was taken, for the Restore list and the log.
    enum Reason: String, Sendable {
        case manual, beforeImport, beforeRebuild, beforeBackendSwitch

        var text: String {
            switch self {
            case .manual: "Backup now"
            case .beforeImport: "before importing a lab"
            case .beforeRebuild: "before rebuilding the domain"
            case .beforeBackendSwitch: "before switching the directory backend"
            }
        }
    }
}

// MARK: - Two controllers, one realm

/// Whether somebody else on this network is already answering for this realm.
///
/// The failure this prevents is nasty and silent: a lab moved to a second Mac while the first
/// is still running gives two domain controllers with the **same domain SID** on one LAN. A
/// joined PC picks one by CLDAP, gets a Kerberos ticket from it, and then talks to whichever
/// one DNS happens to answer with next — so a password change lands on one and a login fails
/// against the other, for days, with nothing anywhere saying why.
///
/// The decision is pure and the probing is not: `verdict` takes the addresses a DNS SRV/CLDAP
/// probe produced and this Mac's own address, and says whether to refuse.
nonisolated enum DuplicateDCProbe {
    struct Verdict: Sendable, Equatable {
        var refuse: Bool
        var message: String?
        /// The addresses that answered and are not us.
        var foreign: [String] = []
    }

    /// Loopback and this Mac's own addresses are the DC we are about to start, not a rival.
    static func verdict(answers: [String], ours: [String], realm: String) -> Verdict {
        let mine = Set(ours + ["127.0.0.1", "0.0.0.0", "::1"])
        let foreign = answers
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !mine.contains($0) }
            .reduce(into: [String]()) { out, address in if !out.contains(address) { out.append(address) } }
        guard !foreign.isEmpty else { return Verdict(refuse: false) }
        return Verdict(refuse: true, message: """
        Another domain controller is already answering for \(realm) on this network, at \
        \(foreign.joined(separator: ", ")). Starting this one would put two controllers with the \
        same domain SID on one LAN, and a joined computer would talk to whichever DNS answered \
        first. Stop the controller on the other Mac, then start this one.
        """, foreign: foreign)
    }

    /// `dig +short -t A <host>` output → addresses. `dig` prints one per line, and an SRV
    /// answer's target is a name, not an address, so the caller resolves it first.
    static func addresses(inDigOutput output: String) -> [String] {
        output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { line in
                !line.isEmpty && line.allSatisfy { $0.isNumber || $0 == "." }
                    && line.split(separator: ".").count == 4
            }
    }

    /// The SRV record every Windows client looks up first.
    static func srvName(realm: String) -> String { "_ldap._tcp.dc._msdcs.\(realm)" }

    /// `0 100 389 dc1.lab.sheep.` → `dc1.lab.sheep`
    static func targets(inSRVOutput output: String) -> [String] {
        output.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: " ")
            guard fields.count >= 4 else { return nil }
            var host = String(fields[3])
            if host.hasSuffix(".") { host.removeLast() }
            return host.isEmpty ? nil : host
        }
    }
}
