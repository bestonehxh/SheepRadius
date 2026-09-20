import Combine
import Foundation

/// Where a lab goes when it has to be somewhere else.
///
/// **Export / Import and Backup / Restore are the same machinery**, which is the only reason
/// this is one file and not two. A backup is an export into
/// `~/Library/Application Support/SheepRadius/backups/`; a restore is an import from one. The
/// difference a person sees is which panel opens; the difference in here is a directory and a
/// filename.
///
/// What goes in the file: `lab.json`, `raddb/`, `certs/`, `ldap/`, and in AD mode the container
/// **image** (`container image save`, ~99 MB) and the **state volume** as a tar produced by a
/// one-shot container that mounts it. The volume is the domain: its SID, its computer accounts
/// and its passwords. Re-provisioning a domain on the second Mac would give a new SID and every
/// joined machine would have to rejoin — which is exactly what this exists to avoid.
///
/// **The DC is stopped first.** Tarring a live Samba's `sam.ldb` is tarring a database
/// mid-write; the app stops it, exports, and starts it again.
extension AppModel {

    // MARK: Paths

    /// `<lab>/backups/` — which for a normal install *is*
    /// `~/Library/Application Support/SheepRadius/backups/`, and for a `-labDir` instance is
    /// inside that throwaway lab.
    ///
    /// It has to follow `env.base` rather than being pinned to the real Application Support
    /// path: pinned, every test instance and every dev run wrote into the owner's real backup
    /// folder and counted his files as its own — which is exactly what made the live suite's
    /// "takes a backup of what was here first" check meaningless.
    ///
    /// Inside the lab is safe because a restore replaces only `lab.json`, `raddb/`, `certs/`
    /// and `ldap/`; `backups/` is not one of them, so a restore can never eat the backups it
    /// is restoring from.
    var backupsDirectory: URL {
        env.base.appendingPathComponent("backups", isDirectory: true)
    }

    /// Where an **import** unpacks to, and stays until the Import button is pressed — so a
    /// 99 MB image is unpacked once for the sheet rather than again for the button.
    private var importStaging: URL {
        env.base.appendingPathComponent("transfer-in", isDirectory: true)
    }

    /// Where an **export** collects, and which it deletes when it is done.
    ///
    /// A separate directory from `importStaging`, and not a nicety: importing takes an
    /// automatic backup of this Mac first, and a backup is an export — sharing one staging
    /// directory would have that backup delete the unpacked archive it is about to install.
    private var exportStaging: URL {
        env.base.appendingPathComponent("transfer-out", isDirectory: true)
    }

    // MARK: Export

    /// Write the whole lab to `url`. Returns nil on success, or the sentence that went wrong.
    ///
    /// Everything that was running is stopped and started again around it — the DC because its
    /// database must be at rest, slapd because the `ldif` backend writes files this is about
    /// to copy.
    /// - Parameter restartAfterwards: false when the caller is about to stop everything anyway
    ///   — the automatic backup an import takes. Restarting the servers there and stopping them
    ///   again a moment later is not merely wasted time: the restart is `await`ed nowhere, so it
    ///   would land *after* the import had stopped them and leave a slapd running over a lab
    ///   folder that was being replaced underneath it.
    func exportLab(to url: URL, restartAfterwards: Bool = true) async -> String? {
        let fm = FileManager.default
        let radiusWasRunning = radius.isRunning
        let ldapWasRunning = ldap.isRunning
        let adWasRunning = ad.isRunning

        transferStatus = "Stopping the servers…"
        await stopAll()

        /// Every exit from here goes through this, so a failure leaves the lab as it found it.
        func finish(_ problem: String?) async -> String? {
            if restartAfterwards {
                if adWasRunning || ldapWasRunning { await startDirectory() }
                // `.lab` (build 25, QA M-29): a restore puts back exactly what was running.
                if radiusWasRunning { await startRadiusForLab() }
            }
            transferStatus = nil
            return problem
        }

        let staging = exportStaging
        try? fm.removeItem(at: staging)
        do {
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        } catch {
            return await finish("Could not make a staging folder in the lab: \(error.localizedDescription)")
        }
        defer { try? fm.removeItem(at: staging) }

        transferStatus = "Collecting the lab…"
        try? env.saveDocument(doc)
        var sizes: [String: Int] = [:]
        if fm.fileExists(atPath: env.documentURL.path) {
            try? fm.copyItem(at: env.documentURL, to: staging.appendingPathComponent(LabArchiveEntry.document))
            sizes[LabArchiveEntry.document] = Self.bytes(at: staging.appendingPathComponent(LabArchiveEntry.document))
        }
        for name in LabArchiveEntry.directories {
            let source = env.base.appendingPathComponent(name, isDirectory: true)
            guard fm.fileExists(atPath: source.path) else { continue }
            let target = staging.appendingPathComponent(name, isDirectory: true)
            do { try fm.copyItem(at: source, to: target) } catch {
                return await finish("Could not copy \(name): \(error.localizedDescription)")
            }
            sizes[name] = Self.bytes(at: target)
        }

        var manifest = LabManifest(labID: doc.labID, created: Date(),
                                   appVersion: Self.buildVersion,
                                   realm: doc.settings.directoryBackend == .activeDirectory
                                   ? doc.settings.ad.realm : doc.settings.ldapSuffix,
                                   backend: doc.settings.directoryBackend,
                                   userCount: directory.users.count,
                                   groupCount: directory.groups.count,
                                   joinedComputers: ad.computers.map(\.name))
        // With the directory stopped, a snapshot is not available any more — fall back to the
        // last one rather than reporting zero, which would make the sheet say the lab is empty.
        if manifest.userCount == 0 { manifest.userCount = doc.users.count }
        if manifest.groupCount == 0 { manifest.groupCount = doc.groups.count }

        if doc.settings.directoryBackend == .activeDirectory {
            if let problem = await exportDomain(into: staging, manifest: &manifest, sizes: &sizes) {
                return await finish(problem)
            }
        }

        manifest.sizes = sizes
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(manifest).write(to: staging.appendingPathComponent(LabArchiveEntry.manifest))
        } catch {
            return await finish("Could not write the manifest: \(error.localizedDescription)")
        }

        transferStatus = "Writing \(url.lastPathComponent)…"
        try? fm.removeItem(at: url)
        // `ditto -c -k` rather than `zip`: it is in every macOS, it preserves the tree, and it
        // is the same tool the family's other apps use for an archive a person will double-click.
        let zipped = await Shell.run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", staging.path, url.path],
                                     environment: [:])
        guard zipped.ok else { return await finish("Could not write the file: \(zipped.output)") }
        // `ditto` writes at the process umask — 0644 — and this file holds the lab CA's private
        // key, every user's cleartext password, every NAS shared secret and, in AD mode, the
        // whole of `sam.ldb`. The user picks the destination in a save panel, so it usually
        // lands in Downloads or on the Desktop, where other accounts on this Mac can read it.
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        lastExport = LabBackup(url: url, created: manifest.created, bytes: Self.bytes(at: url))
        return await finish(nil)
    }

    /// The two halves a domain needs: the image it runs and the volume it lives in.
    private func exportDomain(into staging: URL, manifest: inout LabManifest,
                              sizes: inout [String: Int]) async -> String? {
        guard let tool = tools.containerTool else {
            return "Apple's `container` tool is not installed, so the domain cannot be exported."
        }
        // Stopping the domain controller a moment ago may have taken the shared container
        // system down with it — see `ADController.ensureSystemRunning`. Everything below talks
        // to it.
        transferStatus = "Starting the container system…"
        guard await ad.ensureSystemRunning() else {
            return "The container system would not start, so the domain cannot be exported."
        }
        await ad.refreshPrerequisites()
        guard let image = ad.imageReference else {
            return "No domain-controller image is installed here, so there is nothing to export."
        }
        manifest.imageReference = image
        manifest.volumeName = ad.volumeName

        transferStatus = "Saving the domain-controller image (about 99 MB)…"
        let imageTar = staging.appendingPathComponent(LabArchiveEntry.image)
        let saved = await Shell.run(tool, ADImage.saveArguments(reference: image, to: imageTar.path),
                                    environment: [:])
        guard saved.ok else { return "container image save failed: \(saved.output.prefix(300))" }
        sizes[LabArchiveEntry.image] = Self.bytes(at: imageTar)
        // **The digest of the thing that will be executed** (build 20, audit N-1). The image
        // in this archive is loaded and then run with `--cap-add CAP_SYS_ADMIN` and thirteen
        // published ports on whichever Mac imports it; recording its SHA-256 here is what lets
        // that Mac refuse anything that is not byte-for-byte the file this export wrote.
        guard let imageDigest = LabDigest.sha256(ofFileAt: imageTar) else {
            return "The domain-controller image could not be read back to be checksummed."
        }
        manifest.digests[LabArchiveEntry.image] = imageDigest

        transferStatus = "Saving the domain's state volume…"
        let volumeTar = staging.appendingPathComponent(LabArchiveEntry.volume)
        // A one-shot container whose only job is to hand back the volume's contents. `tar`
        // writes to **stdout**, which goes straight into the file — `Shell.run`'s String
        // result would destroy it, which is what `stdoutTo:` exists for.
        let dumped = await Shell.run(tool, ADImage.volumeDumpArguments(volume: ad.volumeName, image: image),
                                     stdoutTo: volumeTar, environment: [:])
        guard dumped.ok, Self.bytes(at: volumeTar) > 0 else {
            return "Could not read the state volume \(ad.volumeName): \(dumped.output.prefix(300))"
        }
        sizes[LabArchiveEntry.volume] = Self.bytes(at: volumeTar)
        guard let volumeDigest = LabDigest.sha256(ofFileAt: volumeTar) else {
            return "The state volume could not be read back to be checksummed."
        }
        manifest.digests[LabArchiveEntry.volume] = volumeDigest
        return nil
    }

    // MARK: Preview

    /// Unpack far enough to read the manifest, and say what importing would mean here.
    ///
    /// The staging directory is **kept** — `importLab` uses it, so the 99 MB image is unpacked
    /// once rather than once for the sheet and again for the button.
    func previewLab(at url: URL) async -> LabImportPreview? {
        let fm = FileManager.default
        let staging = importStaging
        try? fm.removeItem(at: staging)
        transferStatus = "Opening \(url.lastPathComponent)…"
        defer { transferStatus = nil }

        // **Look inside before unpacking** (build 20, audit N-3). `ditto -x -k` trusts the
        // archive completely: an absolute path, a `..` and a symlink are all written as the
        // file asks, and nothing enforces the sizes the manifest itself declares. `zipinfo`
        // answers all four questions without writing a byte.
        let listing = await Shell.run("/usr/bin/zipinfo", [url.path], environment: [:])
        guard listing.ok else {
            report("That file could not be opened as a lab archive.", detail: listing.output)
            return nil
        }
        let entries = ZipListing.parse(listing.output)
        if let problem = ZipListing.problem(entries: entries, declaredBytes: nil) {
            report(problem, detail: listing.output)
            return nil
        }

        // The manifest, read out of the archive rather than out of the disk: the sizes and the
        // digests it declares are the rules the rest of this function applies, so they have to
        // be known before anything is written.
        // `stdoutTo:` rather than the String overload: that one merges stderr into the result,
        // and one `unzip` warning in front of the JSON would make a good manifest unreadable.
        let probe = env.base.appendingPathComponent("transfer-manifest.json")
        try? fm.removeItem(at: probe)
        defer { try? fm.removeItem(at: probe) }
        let read = await Shell.run("/usr/bin/unzip", ["-p", url.path, LabArchiveEntry.manifest],
                                   stdoutTo: probe, environment: [:])
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard read.ok, let data = try? Data(contentsOf: probe),
              let manifest = try? decoder.decode(LabManifest.self, from: data) else {
            report("The manifest in that file could not be read.")
            return nil
        }
        // Every string that becomes a `container` argument or a file name, against a strict
        // charset, **before anything is executed** (audit N-2).
        if let problem = LabManifestCheck.problem(with: manifest) {
            report(problem, detail: "The archive is left alone; nothing was unpacked.")
            return nil
        }
        if let problem = ZipListing.problem(entries: entries, declaredBytes: manifest.totalBytes) {
            report(problem, detail: listing.output)
            return nil
        }
        // An archive carrying an image but no digest for it cannot be verified at all, and an
        // unverifiable image is the whole of N-1. Refused here rather than at the button, so
        // the sheet never offers an import that cannot go through.
        let carriesImage = entries.contains { $0.name == LabArchiveEntry.image }
        if carriesImage, manifest.digests[LabArchiveEntry.image] == nil {
            report("""
            That archive carries a domain-controller image but records no SHA-256 for it, so \
            what would be run here cannot be checked. Export it again from a build 20 or later.
            """)
            return nil
        }

        let unpacked = await Shell.run("/usr/bin/ditto", ["-x", "-k", url.path, staging.path],
                                       environment: [:])
        guard unpacked.ok else {
            report("That file could not be opened as a lab archive.", detail: unpacked.output)
            return nil
        }
        let volumes = await existingVolumeNames()
        let labHasContent = (try? fm.contentsOfDirectory(atPath: env.raddb.path))?.isEmpty == false
        return LabImportPreview.make(manifest: manifest, localLabID: doc.labID,
                                     existingVolumes: volumes, labFolderHasContent: labHasContent)
    }

    private func existingVolumeNames() async -> [String] {
        guard let tool = tools.containerTool else { return [] }
        let listing = await Shell.run(tool, ["volume", "list"], environment: [:])
        return listing.output.split(separator: "\n").dropFirst().compactMap {
            $0.split(separator: " ").first.map(String.init)
        }
    }

    // MARK: Import

    /// Put the unpacked archive in place. `volumeName` overrides the one in the manifest — the
    /// `ad` suite imports under a new name so the real volume is never in the way.
    func importLab(_ preview: LabImportPreview, volumeName: String? = nil) async -> String? {
        let fm = FileManager.default
        let staging = importStaging
        guard fm.fileExists(atPath: staging.appendingPathComponent(LabArchiveEntry.manifest).path) else {
            return "The archive is no longer unpacked — choose the file again."
        }
        transferDetail = nil
        defer { transferStatus = nil }

        // **A backup of what is here, before any of it is replaced.** Not optional and not a
        // checkbox: an import is the one operation in this app that overwrites a working lab.
        transferStatus = "Backing up this Mac's lab first…"
        _ = await backupNow(.beforeImport)

        transferStatus = "Stopping the servers…"
        await stopAll()

        transferStatus = "Restoring the files…"
        try? fm.removeItem(at: env.documentURL)
        let document = staging.appendingPathComponent(LabArchiveEntry.document)
        if fm.fileExists(atPath: document.path) {
            try? fm.copyItem(at: document, to: env.documentURL)
        }
        for name in LabArchiveEntry.directories {
            let source = staging.appendingPathComponent(name, isDirectory: true)
            guard fm.fileExists(atPath: source.path) else { continue }
            let target = env.base.appendingPathComponent(name, isDirectory: true)
            try? fm.removeItem(at: target)
            do { try fm.copyItem(at: source, to: target) } catch {
                return "Could not restore \(name): \(error.localizedDescription)"
            }
        }

        if preview.manifest.backend == .activeDirectory {
            if let problem = await importDomain(from: staging, manifest: preview.manifest,
                                                volumeName: volumeName ?? preview.manifest.volumeName) {
                return problem
            }
        }

        transferStatus = "Reading the lab…"
        try? fm.removeItem(at: staging)
        adoptRestoredDocument()
        // The address on this Mac is not the address it came from, and every device in the lab
        // is pointed at the old one by hand. The Status pane's card is the only thing that will
        // say so, so it is raised deliberately rather than waiting for the network to change.
        noteLabMoved(from: preview.manifest.realm)
        await refreshDirectory()
        return nil
    }

    private func importDomain(from staging: URL, manifest: LabManifest, volumeName: String) async -> String? {
        guard let tool = tools.containerTool else {
            return "Apple's `container` tool is not installed on this host. Install it from the card in Directory ▸ Server, then import again."
        }
        transferStatus = "Starting the container system…"
        guard await ad.ensureSystemRunning() else {
            return "The container system would not start, so the domain cannot be imported."
        }
        let imageTar = staging.appendingPathComponent(LabArchiveEntry.image)
        if FileManager.default.fileExists(atPath: imageTar.path) {
            // **Nothing is loaded until the bytes are the bytes the manifest names** (build 20,
            // audit N-1). What comes out of this tar is run with `--cap-add CAP_SYS_ADMIN` and
            // thirteen published host ports, so an image that does not match — or a manifest
            // that never said what it should be — is refused rather than run.
            transferStatus = "Checking the domain-controller image…"
            if let bad = Self.digestCheck(manifest: manifest, entry: LabArchiveEntry.image,
                                          file: imageTar, what: "domain-controller image") {
                transferDetail = bad.detail
                return bad.message
            }
            transferStatus = "Loading the domain-controller image…"
            let loaded = await Shell.run(tool, ADImage.loadArguments(from: imageTar.path), environment: [:])
            guard loaded.ok else { return "container image load failed: \(loaded.output.prefix(300))" }
        }
        let volumeTar = staging.appendingPathComponent(LabArchiveEntry.volume)
        guard FileManager.default.fileExists(atPath: volumeTar.path) else {
            return "The archive has no state volume, so the domain cannot be restored from it."
        }
        // The volume is the domain itself — its SID, its computer accounts and every password
        // in it. It is not executed the way the image is, but it is what the DC then serves.
        if let bad = Self.digestCheck(manifest: manifest, entry: LabArchiveEntry.volume,
                                      file: volumeTar, what: "state volume") {
            transferDetail = bad.detail
            return bad.message
        }
        if let name = volumeName.isEmpty ? nil : LabManifestCheck.problem(withVolumeName: volumeName) {
            return name
        }
        transferStatus = "Creating the state volume \(volumeName)…"
        // Already-exists is not a failure here: the preview refused a volume that has content,
        // and an empty one left by a previous attempt is exactly what we want to fill.
        _ = await Shell.run(tool, ["volume", "create", "-s", ADImage.volumeSize, volumeName], environment: [:])
        transferStatus = "Restoring the domain…"
        let restored = await Shell.run(
            tool, ADImage.volumeRestoreArguments(volume: volumeName,
                                                 image: manifest.imageReference.isEmpty
                                                 ? (ad.imageReference ?? ADImage.reference)
                                                 : manifest.imageReference),
            stdoutTo: staging.appendingPathComponent("restore.log"), stdinFrom: volumeTar, environment: [:])
        guard restored.ok else { return "Restoring the state volume failed: \(restored.output.prefix(300))" }
        return nil
    }

    // MARK: Backup / Restore

    /// Take a backup now. Returns nil on success, or what went wrong.
    @discardableResult
    func backupNow(_ reason: BackupRotation.Reason) async -> String? {
        let fm = FileManager.default
        try? fm.createDirectory(at: backupsDirectory, withIntermediateDirectories: true)
        let url = backupsDirectory.appendingPathComponent(BackupRotation.filename())
        // An automatic backup is taken immediately before something that stops the servers
        // anyway; only "Backup now" puts them back.
        if let problem = await exportLab(to: url, restartAfterwards: reason == .manual) {
            return problem
        }
        radius.note("—— backup \(reason.text): \(url.lastPathComponent)")
        pruneBackups()
        return nil
    }

    /// Newest first, which is the order the Restore list shows and the order the rotation uses.
    func listBackups() -> [LabBackup] {
        let fm = FileManager.default
        let found = (try? fm.contentsOfDirectory(at: backupsDirectory,
                                                 includingPropertiesForKeys: [.contentModificationDateKey],
                                                 options: [.skipsHiddenFiles])) ?? []
        return found.filter { $0.pathExtension == "sheeplab" }.map { url in
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            return LabBackup(url: url, created: values?.contentModificationDate ?? Date(),
                             bytes: Self.bytes(at: url))
        }
        .sorted { $0.created > $1.created }
    }

    private func pruneBackups() {
        for stale in BackupRotation.expired(listBackups()) {
            try? FileManager.default.removeItem(at: stale.url)
        }
    }

    // MARK: Starting safely

    /// Is another controller already answering for this realm on the LAN?
    ///
    /// Asked **before** the DC starts, not after: two controllers with the same domain SID on
    /// one network is a fault that is invisible from either of them.
    func duplicateDomainVerdict() async -> DuplicateDCProbe.Verdict {
        let realm = doc.settings.ad.realm
        guard !realm.isEmpty else { return .init(refuse: false) }
        let ours = LocalNetwork.allIPv4().map(\.ip)
        let srv = await Shell.run("/usr/bin/dig",
                                  ["+short", "+time=2", "+tries=1", "-t", "SRV",
                                   DuplicateDCProbe.srvName(realm: realm)], environment: [:])
        var answers: [String] = []
        for host in DuplicateDCProbe.targets(inSRVOutput: srv.output) {
            let a = await Shell.run("/usr/bin/dig", ["+short", "+time=2", "+tries=1", host],
                                    environment: [:])
            answers += DuplicateDCProbe.addresses(inDigOutput: a.output)
        }
        // A CLDAP netlogon ping to each answer, so a stale DNS record with nothing behind it
        // does not stop a start that would have been fine.
        let query = CLDAP.netlogonQuery(realm: realm)
        let alive = answers.filter { NetProbe.exchange($0, 389, payload: query, timeout: 2) != nil }
        return DuplicateDCProbe.verdict(answers: alive, ours: ours, realm: realm)
    }

    // MARK: Internals

    /// Load the restored `lab.json` into the model, keeping the id that came with it.
    private func adoptRestoredDocument() {
        let loaded = env.loadDocument()
        doc = loaded
        adoptRestoredApplied(loaded)
    }

    static var buildVersion: String {
        (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "?"
    }

    /// Why this component of an archive must not be used, or nil (build 20, audit N-1).
    ///
    /// A missing digest is a refusal, not a pass: "the manifest did not say" is exactly the
    /// state every pre-build-20 archive is in, and treating it as permission would leave the
    /// finding open for anyone who kept an old file.
    nonisolated static func digestCheck(manifest: LabManifest, entry: String, file: URL,
                                        what: String) -> (message: String, detail: String)? {
        guard let expected = manifest.digests[entry] else {
            return ("That archive records no SHA-256 for its \(what), so it is refused.",
                    "Nothing in the manifest describes \(entry), so what would run here cannot be "
                    + "checked against anything. Export the lab again from build 20 or later.")
        }
        guard LabDigest.isWellFormed(expected) else {
            return ("The SHA-256 that archive records for its \(what) is not a SHA-256.",
                    "manifest digests[\(entry)] = \(expected)")
        }
        guard let actual = LabDigest.sha256(ofFileAt: file) else {
            return ("The \(what) in that archive could not be read.", file.path)
        }
        guard LabDigest.matches(actual, expected) else {
            return ("The \(what) in that archive is not the one its manifest describes, so it is not loaded.",
                    "expected  \(expected)\nactual    \(actual)\n\n"
                    + "The file has been changed or damaged since it was exported. The image an "
                    + "import loads is run with elevated capabilities and thirteen published host "
                    + "ports, so it is refused rather than run.")
        }
        return nil
    }

    /// Bytes on disk for a file or a whole directory.
    static func bytes(at url: URL) -> Int {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }
        if !isDirectory.boolValue {
            return ((try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? 0
        }
        var total = 0
        let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey],
                                       options: [.skipsHiddenFiles])
        while let next = enumerator?.nextObject() as? URL {
            total += ((try? next.resourceValues(forKeys: [.fileSizeKey]))?.fileSize) ?? 0
        }
        return total
    }
}

// MARK: - The live suite's hook

extension AppModel {
    /// `-transferProbe <path>` — export when that file does not exist yet, import it when it
    /// does, and print one `[lab] …` line per step.
    ///
    /// One hook for both halves, because the halves are only meaningful together: the check
    /// that matters is that a lab exported from one directory and imported into another
    /// **answers the same questions afterwards**, and the shell can only ask those of a
    /// running server. So the probe leaves the app up when it is done and the suite drives
    /// radclient and ldapsearch at it.
    ///
    /// `-transferVolume <name>` imports the domain's state under a different volume name,
    /// which is what lets `./Tests/run.sh ad` bring a lab onto a Mac that already has one
    /// without going anywhere near the real `sheepad-state`.
    func runTransferProbe(_ path: String) async {
        setvbuf(stdout, nil, _IONBF, 0)
        func say(_ text: String) { print("[lab] \(text)") }
        let url = URL(fileURLWithPath: path)

        if FileManager.default.fileExists(atPath: path) {
            guard let preview = await previewLab(at: url) else {
                say("preview failed")
                say("done")
                return
            }
            say("preview-realm \(preview.manifest.realm)")
            say("preview-backend \(preview.manifest.backend == .activeDirectory ? "ad" : "openldap")")
            say("preview-users \(preview.manifest.userCount)")
            say("preview-groups \(preview.manifest.groupCount)")
            say("preview-bytes \(preview.manifest.totalBytes)")
            switch preview.clash {
            case .none: say("preview-clash none")
            case .sameLab: say("preview-clash same-lab")
            case .volumeInUse(let name): say("preview-clash volume-in-use \(name)")
            }
            say("preview-can-import \(preview.canImport ? "yes" : "no")")
            let volume = CommandLine.value(after: "-transferVolume")
            if let volume { say("import-volume \(volume)") }
            let problem = await importLab(preview, volumeName: volume)
            say("import \(problem.map { "FAILED " + $0.replacingOccurrences(of: "\n", with: " · ") } ?? "ok")")
            guard problem == nil else { say("done"); return }
            say("import-lab-id \(doc.labID.uuidString)")
            say("import-backups \(listBackups().count)")
            await startAll()
            await refreshDirectory()
            say("after-import radius=\(radius.isRunning ? "yes" : "no") ldap=\(ldap.isRunning ? "yes" : "no") ad=\(ad.isRunning ? "yes" : "no")")
            say("after-import users=\(directory.users.count) groups=\(directory.groups.count) ous=\(directory.ous.count)")
            say("after-import names=\(directory.users.map(\.username).sorted().joined(separator: ","))")
            // The card a person needs after a move, because no device knows the lab changed Mac.
            say("after-import address-card \(addressChange != nil ? "shown" : "MISSING")")
            say("done")
            return
        }

        await startAll()
        await refreshDirectory()
        say("before-export lab-id \(doc.labID.uuidString)")
        say("before-export users=\(directory.users.count) groups=\(directory.groups.count) ous=\(directory.ous.count)")
        say("before-export names=\(directory.users.map(\.username).sorted().joined(separator: ","))")
        let problem = await exportLab(to: url)
        say("export \(problem.map { "FAILED " + $0.replacingOccurrences(of: "\n", with: " · ") } ?? "ok")")
        if problem == nil {
            say("export-bytes \(Self.bytes(at: url))")
            say("export-running-again radius=\(radius.isRunning ? "yes" : "no") ldap=\(ldap.isRunning ? "yes" : "no") ad=\(ad.isRunning ? "yes" : "no")")
        }
        say("done")
    }
}
