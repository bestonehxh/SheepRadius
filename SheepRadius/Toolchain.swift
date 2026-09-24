import Foundation

/// One installable thing on the Environment pane. A start that fails because one of these is
/// missing opens that pane with the item highlighted, rather than leaving the person to find
/// the install button three panes away.
nonisolated enum EnvironmentItem: String, Sendable, CaseIterable {
    case radius, ldap, container, adImage

    /// The sentence at the top of the Environment pane when a start was sent here.
    var reason: String {
        switch self {
        case .radius: "RADIUS cannot start: FreeRADIUS is not in this build."
        case .ldap: "OpenLDAP cannot start: slapd is not in this build."
        case .container: "Samba AD cannot start: Apple's container tool is not installed."
        case .adImage: "Samba AD cannot start: the domain-controller image is not built yet."
        }
    }
}

/// Locates the external binaries the app drives.
///
/// FreeRADIUS and OpenLDAP are both looked for **inside the app bundle first** (the
/// "Bundle servers" build phase copies them out of Homebrew and rewrites their install
/// names), then in Homebrew — so a release build runs on a Mac with no Homebrew at all,
/// while a plain `xcodebuild` without that phase still works on this one.
///
/// Nothing falls back to a macOS-supplied copy: not `/usr/libexec/slapd` (OpenLDAP 2.4.28
/// from 2011), not `/usr/bin/ldapsearch`, not `/usr/bin/openssl` (LibreSSL). Everything the
/// app drives is one known version, bundled, so every Mac behaves identically.
nonisolated struct Toolchain: Equatable, Sendable {
    enum RadiusSource: String, Sendable {
        case bundled, homebrew
        var label: String {
            switch self {
            case .bundled: "bundled in the app"
            case .homebrew: "Homebrew"
            }
        }
    }

    var radiusSource: RadiusSource?
    var radiusd: String?
    var radclient: String?
    var radeapclient: String?
    /// `libdir` for the generated radiusd.conf — where the rlm_*.dylib modules are dlopen'd from.
    var radiusLibDir: String?
    /// `-D`: the dictionary directory. The stock binaries have an absolute Cellar path compiled
    /// in as the default, so this must always be passed explicitly.
    var dictionaryDir: String?
    /// `prefix` in the generated radiusd.conf. Only `${prefix}`-references need it to resolve.
    var radiusPrefix: String?

    /// Where slapd came from. macOS's own `/usr/libexec/slapd` is **not** consulted at all:
    /// it is OpenLDAP 2.4.28 from 2011, and the app now carries 2.7.1 of its own.
    enum LDAPSource: String, Sendable {
        case bundled, homebrew
        var label: String {
            switch self {
            case .bundled: "bundled in the app"
            case .homebrew: "Homebrew openldap"
            }
        }
    }

    var ldapSource: LDAPSource?
    var slapd: String?
    var schemaDir: String?
    var opensslSource: RadiusSource?
    var openssl: String?
    /// `OPENSSL_CONF` and `OPENSSL_MODULES` for every child that links libcrypto — see
    /// `childEnvironment`.
    var opensslConf: String?
    var opensslModulesDir: String?
    /// The 2.7.1 client tools. macOS's own /usr/bin/ldapsearch is deliberately NOT a
    /// fallback — the whole LDAP toolset comes from one OpenLDAP.
    var ldapsearch: String?
    var ldapwhoami: String?
    /// The write half, bundled in build 16 for `OpenLDAPDirectory`: the directory is edited
    /// **online** against the running slapd instead of being wiped and re-seeded. `ldapmodrdn`
    /// is what moves a user between OUs and `ldappasswd` what sets `{SSHA}` without this app
    /// hashing anything itself.
    var ldapadd: String?
    var ldapmodify: String?
    var ldapdelete: String?
    var ldapmodrdn: String?
    var ldappasswd: String?

    /// Whether this build can edit an OpenLDAP directory online. False on a build whose
    /// "Bundle servers" phase predates build 16 — the panes then say so rather than failing
    /// at the first edit.
    var ldapWriteReady: Bool {
        ldapadd != nil && ldapmodify != nil && ldapdelete != nil
            && ldapmodrdn != nil && ldappasswd != nil
    }
    /// Present only so the Status pane can offer to run `brew install <formula>`.
    var brew: String?
    /// Apple's `container` CLI, for AD Domain mode. Unlike FreeRADIUS and OpenLDAP this one
    /// is **not** bundled and cannot be: it is a VM runtime with a launchd agent and a Linux
    /// kernel of its own. AD mode is therefore the one feature with a real prerequisite, and
    /// the Directory pane says so rather than failing at start.
    var containerTool: String?
    /// The supplicant simulator that makes PEAP / TTLS / EAP-TLS testable, from
    /// wpa_supplicant. **Bundled or nothing**: there is no Homebrew formula for it, so unlike
    /// every other tool here it has no second source to fall back to. It is built once by
    /// `Tools/build-eapol-test.sh` into `Vendor/eapol_test` and copied in by "Bundle
    /// servers"; when it is absent the Test pane hides the tunnelled methods and says why
    /// (`eapolTestHint`) rather than offering something that cannot run.
    var eapolTest: String?

    /// Why the tunnelled EAP methods are unavailable, or nil when they are available.
    var eapolTestHint: String? {
        eapolTest == nil
            ? "PEAP and TTLS need eapol_test, which is built from the wpa_supplicant source by "
              + "Tools/build-eapol-test.sh and copied into the app by the \"Bundle servers\" "
              + "build phase. This build does not contain it."
            : nil
    }
    var eapReady: Bool { eapolTest != nil }

    /// **Why a server switch did nothing** (build 25, QA M-8).
    ///
    /// `startRadiusLocked` and `startLDAPLocked` used to fold "the binary is missing" into
    /// their first `guard` and `return`, so ⌘R, Start all and both sidebar switches were
    /// silent no-ops on a build whose "Bundle servers" phase had not run — the switch flicked
    /// back and nothing was said anywhere. The message names the phase, because that is where
    /// the fault is: running the app needs no Homebrew, *building* it does.
    static func missingServerMessage(server: String, binary: String) -> String {
        "\(server) was not started because `\(binary)` is not in this build. It is copied into "
            + "SheepRadius.app by the \"Bundle servers\" build phase, which needs Homebrew's "
            + "freeradius-server, openldap and openssl@3 at build time."
    }

    /// Seeding the directory. `slapadd` is only ever a symlink back to slapd with argv[0]
    /// dispatch, so the app calls the tool mode directly — one code path for all three
    /// builds, and nothing to bundle but the single binary. (Verified on 2.4.28 and 2.7.1.)
    var slapaddArguments: [String] { ["-T", "add"] }

    var radiusReady: Bool { radiusd != nil && openssl != nil }
    var opensslReady: Bool { openssl != nil }
    var ldapReady: Bool { slapd != nil && schemaDir != nil }
    /// True when Homebrew is there to install the missing formulae with.
    var canInstall: Bool { brew != nil }
    /// The Homebrew formulae that are missing, in the order the Status card offers them.
    var missingFormulae: [String] {
        (radiusd == nil ? ["freeradius-server"] : []) + (slapd == nil ? ["openldap"] : [])
    }

    /// **What the Environment pane should open onto at launch**, or nil when nothing the lab
    /// is set to use is missing. RADIUS and OpenLDAP always count; `container` and the DC image
    /// only when the lab's directory is Samba AD — someone who never uses AD mode is not sent
    /// to install Apple's container runtime every time they open the app.
    func launchBlocker(backend: DirectoryBackend, imageBuilt: Bool) -> EnvironmentItem? {
        if !radiusReady { return .radius }
        if !ldapReady { return .ldap }
        guard backend == .activeDirectory else { return nil }
        if containerTool == nil { return .container }
        if !imageBuilt { return .adImage }
        return nil
    }

    static let containerPaths = ["/opt/homebrew/bin/container", "/usr/local/bin/container"]
    static let brewPaths = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
    static let brewPrefixes = ["/opt/homebrew", "/usr/local"]

    static func detect() -> Toolchain {
        let fm = FileManager.default
        func firstExecutable(_ paths: [String]) -> String? { paths.first { fm.isExecutableFile(atPath: $0) } }

        var t = Toolchain()
        // Dev hooks: pretend a server is absent so the "Missing components" card is reachable
        // without uninstalling anything.
        if CommandLine.value(after: "-demoNoRadius") != "1", !t.adoptRadius(bundled: fm) {
            t.adoptRadius(homebrew: fm)
        }
        if CommandLine.value(after: "-demoNoLDAP") != "1", !t.adoptLDAP(bundled: fm) {
            t.adoptLDAP(homebrew: fm)
        }
        if !t.adoptOpenSSL(bundled: fm) { t.adoptOpenSSL(homebrew: fm) }
        // Bundled only, and deliberately not paired with a Homebrew fallback: no such
        // formula exists, so a missing one means this .app was built without Vendor/.
        if CommandLine.value(after: "-demoNoEAPOL") != "1" {
            t.eapolTest = t.optional(Self.bundledRoot.appendingPathComponent("Helpers/eapol_test").path, fm)
        }
        t.brew = firstExecutable(brewPaths)
        if CommandLine.value(after: "-demoNoContainer") != "1" {
            t.containerTool = firstExecutable(containerPaths)
        }
        return t
    }

    // MARK: OpenSSL location

    @discardableResult
    private mutating func adoptOpenSSL(bundled fm: FileManager) -> Bool {
        let root = Self.bundledRoot
        let openssl = root.appendingPathComponent("Helpers/openssl").path
        let conf = root.appendingPathComponent("Resources/openssl/openssl.cnf").path
        guard fm.isExecutableFile(atPath: openssl), fm.fileExists(atPath: conf) else { return false }
        opensslSource = .bundled
        self.openssl = openssl
        opensslConf = conf
        // radiusd loads the legacy provider itself (MS-CHAP needs MD4/DES); this is where
        // it has to find legacy.dylib once the compiled-in Cellar path is gone.
        opensslModulesDir = root.appendingPathComponent("Frameworks/ossl-modules", isDirectory: true).path
        return true
    }

    @discardableResult
    private mutating func adoptOpenSSL(homebrew fm: FileManager) -> Bool {
        guard let prefix = Self.brewPrefixes.first(where: { fm.isExecutableFile(atPath: $0 + "/opt/openssl@3/bin/openssl") })
        else { return false }
        opensslSource = .homebrew
        openssl = prefix + "/opt/openssl@3/bin/openssl"
        // Leave OPENSSL_CONF/OPENSSL_MODULES unset so this Homebrew OpenSSL uses its own
        // compiled-in defaults, which on this Mac are correct.
        return true
    }

    /// The environment every child that links libcrypto is launched with.
    ///
    /// `OPENSSL_CONF` pins the configuration (the bundled OpenSSL has
    /// `OPENSSLDIR=/opt/homebrew/etc/openssl@3` compiled in — absent on a Mac without
    /// Homebrew, and the user's own file on a Mac with it), and `OPENSSL_MODULES` points at
    /// the bundled provider directory. Anything the user set for these, or a `DYLD_*`
    /// override, is dropped rather than inherited: they would quietly change which crypto
    /// the servers run.
    var childEnvironment: [String: String] {
        // The OpenLDAP tools have /opt/homebrew/etc/openldap/ldap.conf compiled in as their
        // default. LDAPNOINIT makes libldap ignore every config file and LDAP* variable, so
        // the app's explicit -H / -b / -D are the only inputs — the same reasoning as
        // OPENSSL_CONF, and it removes the last path that differs between the two Macs.
        var out = ["LDAPNOINIT": "1"]
        if let opensslConf { out["OPENSSL_CONF"] = opensslConf }
        if let opensslModulesDir { out["OPENSSL_MODULES"] = opensslModulesDir }
        return out
    }

    /// Variables never inherited from the app's own environment: each of them could quietly
    /// redirect which crypto, which dylibs or which directory a child ends up using.
    static let scrubbedVariables = ["OPENSSL_CONF", "OPENSSL_MODULES", "OPENSSL_ENGINES",
                                    "LDAPCONF", "LDAPRC", "LDAPNOINIT",
                                    "DYLD_LIBRARY_PATH", "DYLD_FRAMEWORK_PATH", "DYLD_INSERT_LIBRARIES"]

    // MARK: OpenLDAP location

    @discardableResult
    private mutating func adoptLDAP(bundled fm: FileManager) -> Bool {
        let root = Self.bundledRoot
        let slapd = root.appendingPathComponent("Helpers/slapd").path
        let schema = root.appendingPathComponent("Resources/openldap/schema", isDirectory: true)
        guard fm.isExecutableFile(atPath: slapd),
              fm.fileExists(atPath: schema.appendingPathComponent("core.schema").path) else { return false }
        ldapSource = .bundled
        self.slapd = slapd
        schemaDir = schema.path
        ldapsearch = optional(root.appendingPathComponent("Helpers/ldapsearch").path, fm)
        ldapwhoami = optional(root.appendingPathComponent("Helpers/ldapwhoami").path, fm)
        ldapadd = optional(root.appendingPathComponent("Helpers/ldapadd").path, fm)
        ldapmodify = optional(root.appendingPathComponent("Helpers/ldapmodify").path, fm)
        ldapdelete = optional(root.appendingPathComponent("Helpers/ldapdelete").path, fm)
        ldapmodrdn = optional(root.appendingPathComponent("Helpers/ldapmodrdn").path, fm)
        ldappasswd = optional(root.appendingPathComponent("Helpers/ldappasswd").path, fm)
        return true
    }

    @discardableResult
    private mutating func adoptLDAP(homebrew fm: FileManager) -> Bool {
        for prefix in Self.brewPrefixes {
            let slapd = prefix + "/opt/openldap/libexec/slapd"
            let schema = prefix + "/etc/openldap/schema"
            guard fm.isExecutableFile(atPath: slapd),
                  fm.fileExists(atPath: schema + "/core.schema") else { continue }
            ldapSource = .homebrew
            self.slapd = slapd
            schemaDir = schema
            ldapsearch = optional(prefix + "/opt/openldap/bin/ldapsearch", fm)
            ldapwhoami = optional(prefix + "/opt/openldap/bin/ldapwhoami", fm)
            ldapadd = optional(prefix + "/opt/openldap/bin/ldapadd", fm)
            ldapmodify = optional(prefix + "/opt/openldap/bin/ldapmodify", fm)
            ldapdelete = optional(prefix + "/opt/openldap/bin/ldapdelete", fm)
            ldapmodrdn = optional(prefix + "/opt/openldap/bin/ldapmodrdn", fm)
            ldappasswd = optional(prefix + "/opt/openldap/bin/ldappasswd", fm)
            return true
        }
        return false
    }

    // MARK: FreeRADIUS location

    /// The bundle's `Contents`: Helpers/ (executables), Frameworks/ (dylibs),
    /// Resources/freeradius (dictionaries) and Resources/openldap/schema.
    static var bundledRoot: URL { Bundle.main.bundleURL.appendingPathComponent("Contents", isDirectory: true) }

    @discardableResult
    private mutating func adoptRadius(bundled fm: FileManager) -> Bool {
        let root = Self.bundledRoot
        let helpers = root.appendingPathComponent("Helpers", isDirectory: true)
        let frameworks = root.appendingPathComponent("Frameworks", isDirectory: true)
        let dictionaries = root.appendingPathComponent("Resources/freeradius", isDirectory: true)
        let radiusd = helpers.appendingPathComponent("radiusd").path
        guard fm.isExecutableFile(atPath: radiusd),
              fm.fileExists(atPath: frameworks.appendingPathComponent("rlm_eap.dylib").path),
              fm.fileExists(atPath: dictionaries.appendingPathComponent("dictionary").path) else { return false }
        radiusSource = .bundled
        self.radiusd = radiusd
        radclient = helpers.appendingPathComponent("radclient").path
        radeapclient = optional(helpers.appendingPathComponent("radeapclient").path, fm)
        radiusLibDir = frameworks.path
        dictionaryDir = dictionaries.path
        radiusPrefix = root.path
        return true
    }

    @discardableResult
    private mutating func adoptRadius(homebrew fm: FileManager) -> Bool {
        let prefixes = Self.brewPrefixes.map { $0 + "/opt/freeradius-server" }
        guard let prefix = prefixes.first(where: { fm.isExecutableFile(atPath: $0 + "/bin/radiusd") }) else { return false }
        radiusSource = .homebrew
        radiusd = prefix + "/bin/radiusd"
        radclient = optional(prefix + "/bin/radclient", fm)
        radeapclient = optional(prefix + "/bin/radeapclient", fm)
        radiusLibDir = prefix + "/lib"
        dictionaryDir = prefix + "/share/freeradius"
        radiusPrefix = prefix
        return true
    }

    private func optional(_ path: String, _ fm: FileManager) -> String? {
        fm.isExecutableFile(atPath: path) ? path : nil
    }
}

nonisolated enum Shell {
    struct Result: Sendable {
        let status: Int32
        let output: String
        var ok: Bool { status == 0 }
    }

    /// The app's own environment minus anything that could redirect which crypto or which
    /// dylibs a child loads, plus whatever the caller pins. Used for every child process.
    static func childEnvironment(adding extra: [String: String]?) -> [String: String] {
        var out = ProcessInfo.processInfo.environment
        for key in Toolchain.scrubbedVariables { out.removeValue(forKey: key) }
        for (key, value) in extra ?? [:] { out[key] = value }
        return out
    }

    /// Runs a command whose **stdout is binary and large** straight into a file.
    ///
    /// `run` merges stdout and stderr into a `String`, which is right for a tool that prints
    /// sentences and destroys a tar stream. Exporting the domain's state volume is a one-shot
    /// container writing `tar -cf -`, so it needs a file descriptor, not a `String`. stderr is
    /// still captured, because when the tar fails that is the only thing that will say why.
    static func run(_ executable: String, _ arguments: [String], stdoutTo file: URL,
                    stdinFrom input: URL? = nil, environment: [String: String]? = nil) async -> Result {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                guard FileManager.default.createFile(atPath: file.path, contents: nil) ,
                      let out = try? FileHandle(forWritingTo: file) else {
                    cont.resume(returning: Result(status: -1, output: "could not write \(file.path)"))
                    return
                }
                defer { try? out.close() }
                let p = Process()
                p.executableURL = URL(fileURLWithPath: executable)
                p.arguments = arguments
                p.environment = Shell.childEnvironment(adding: environment)
                p.standardOutput = out
                let errors = Pipe()
                p.standardError = errors
                if let input, let handle = try? FileHandle(forReadingFrom: input) {
                    p.standardInput = handle
                } else {
                    p.standardInput = FileHandle.nullDevice
                }
                do { try p.run() } catch {
                    cont.resume(returning: Result(status: -1, output: error.localizedDescription))
                    return
                }
                let data = errors.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                cont.resume(returning: Result(status: p.terminationStatus,
                                              output: String(decoding: data, as: UTF8.self)))
            }
        }
    }

    /// Runs a short-lived command off the main thread; stdout and stderr are merged.
    ///
    /// `input` is written to the child's stdin and the pipe closed — that is how radclient
    /// takes its attribute list, which is why the app no longer needs Homebrew's `radtest`
    /// shell script (it has the Cellar prefix hard-coded and cannot be relocated).
    static func run(_ executable: String, _ arguments: [String], cwd: String? = nil,
                    input: String? = nil, environment: [String: String]? = nil) async -> Result {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: executable)
                p.arguments = arguments
                if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
                p.environment = Shell.childEnvironment(adding: environment)
                let pipe = Pipe()
                p.standardOutput = pipe
                p.standardError = pipe
                let stdin = input.map { _ in Pipe() }
                p.standardInput = stdin ?? FileHandle.nullDevice
                do { try p.run() } catch {
                    cont.resume(returning: Result(status: -1, output: error.localizedDescription))
                    return
                }
                if let stdin, let input {
                    try? stdin.fileHandleForWriting.write(contentsOf: Data(input.utf8))
                    try? stdin.fileHandleForWriting.close()
                }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                cont.resume(returning: Result(status: p.terminationStatus, output: String(decoding: data, as: UTF8.self)))
            }
        }
    }
}


// MARK: - What an install is doing (build 33)

/// **One shape for every long-running install on the Environment pane** (owner: "ในส่วนที่ต้อง
/// Install ก็ใส่ไปให้หมด จะได้รู้ status"): what it is doing in words, a fraction when there is
/// something to count, and whether it has ended. `ImageBuildProgress`, `BrewInstallProgress` and
/// the image export/import all end up here, so the card draws them the same way.
nonisolated struct TaskProgress: Equatable, Sendable {
    enum State: Sendable { case running, done, failed }
    var title: String
    /// nil = nothing countable yet: an indeterminate bar, never a 0 % that looks stuck.
    var fraction: Double?
    var detail: String?
    var state: State = .running

    var percent: Int? { fraction.map { Int(($0 * 100).rounded(.down)) } }
}

/// `brew install <formulae>`, read line by line. Homebrew 7 through a pipe prints no download
/// bar, but it does name every formula it is about to pour, so the count of poured formulae
/// against the plan is an honest percentage:
///
///     ==> Fetching downloads for: container
///     ==> Installing dependencies for wget: libidn2, libpsl and openssl@4
///     ==> Pouring libidn2--2.3.8.arm64_tahoe.bottle.tar.gz
///     🍺  /opt/homebrew/Cellar/container/1.4.1: 29 files, 429.8MB
nonisolated struct BrewInstallProgress: Equatable, Sendable {
    private(set) var total: Int
    private(set) var poured = 0
    private var phase = "Asking Homebrew what to install"
    private var finished: TaskProgress.State = .running

    init(formulae: [String]) { total = max(formulae.count, 1) }

    mutating func ingest(_ raw: String) {
        let line = TerminalText.clean(raw)
        if let r = line.range(of: "Installing dependencies for ") {
            let rest = line[r.upperBound...]
            if let colon = rest.firstIndex(of: ":") {
                total += Self.names(in: String(rest[rest.index(after: colon)...])).count
            }
        }
        if let r = line.range(of: "Fetching downloads for: ") {
            total = max(total, Self.names(in: String(line[r.upperBound...])).count)
        }
        if line.contains("==> Fetching") || line.contains("==> Downloading") || line.contains("✔︎ Bottle") {
            phase = "Downloading from Homebrew"
        }
        if line.contains("==> Pouring ") {
            poured += 1
            phase = "Installing " + (line.components(separatedBy: "==> Pouring ").last?
                .components(separatedBy: "--").first ?? "")
        }
        if line.contains("==> Caveats") || line.contains("==> Running `brew cleanup") { phase = "Tidying up" }
    }

    mutating func finish(success: Bool) { finished = success ? .done : .failed }

    var display: TaskProgress {
        switch finished {
        case .done: TaskProgress(title: "Installed", fraction: 1, state: .done)
        case .failed: TaskProgress(title: "Homebrew stopped with an error — the output is below", fraction: nil, state: .failed)
        case .running:
            TaskProgress(title: phase,
                         fraction: poured == 0 ? nil : min(0.05 + 0.9 * Double(poured) / Double(total), 0.99),
                         detail: total > 1 ? "\(min(poured, total)) of \(total) packages" : nil)
        }
    }

    /// "libidn2, libpsl and openssl@4" → three names.
    static func names(in list: String) -> [String] {
        list.replacingOccurrences(of: " and ", with: ", ")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}
