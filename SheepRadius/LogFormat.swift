import Foundation

// MARK: - Which log the pane is showing

/// The three feeds the Log pane can show. All three exist at all times: whichever backend is
/// selected, the other one's pane says what it is waiting for rather than vanishing — the same
/// rule the sidebar follows for a section whose server is unavailable.
nonisolated enum LogSource: String, Hashable, Sendable, CaseIterable {
    case radius, ldap, adDC

    var title: String {
        switch self {
        case .radius: "RADIUS"
        case .ldap: "LDAP"
        case .adDC: "AD DC"
        }
    }

    /// Which feed the pane opens on before anything has started. RADIUS unless
    /// `-demoLogSource` says otherwise — one more of the `-demo…` hooks that exist so a
    /// screenshot is a command rather than a click, in the same family as `-demoPane`.
    static var opening: LogSource {
        switch CommandLine.value(after: "-demoLogSource")?.lowercased() {
        case "ad", "addc", "ad-dc": .adDC
        case "ldap": .ldap
        default: .radius
        }
    }
}

/// **Which feed the Log pane shows, and who decided.**
///
/// The rule the owner asked for in build 16 (PROJECT-STATUS §14.2): starting a server, or
/// switching the directory backend, points the Log at the thing that just came to life —
/// unless the person has picked a feed by hand, in which case their choice survives *until the
/// mode changes again*. "The mode changed" is the event that forgets a hand pick; a second
/// start of the same mode is not a change and must not steal the pane back.
///
/// Pure and `Equatable` so the whole rule is a unit test rather than a thing to click through.
nonisolated struct LogSourcePolicy: Equatable, Sendable {
    /// What the pane shows.
    private(set) var source: LogSource
    /// The last mode the app switched to on its own. A repeat of it is not a mode change.
    private(set) var mode: LogSource?
    /// The person chose this feed from the picker and has not been overruled by a mode change.
    private(set) var pinned = false

    init(source: LogSource = .radius) { self.source = source }

    /// The person picked a feed from the picker.
    mutating func choose(_ picked: LogSource) {
        source = picked
        pinned = true
    }

    /// A server started, or the directory backend changed. Returns true if the pane moved.
    ///
    /// A pin is cleared here even when the source it pinned is the one we are switching to:
    /// the point of the pin is "do not move while nothing has changed", and something has.
    @discardableResult
    mutating func modeStarted(_ started: LogSource) -> Bool {
        guard started != mode else {
            // The same mode again (Apply restarts radiusd, a health check re-starts the DC).
            // Nothing changed, so a hand-picked feed stays where it is.
            guard !pinned else { return false }
            let moved = source != started
            source = started
            return moved
        }
        mode = started
        pinned = false
        let moved = source != started
        source = started
        return moved
    }
}

// MARK: - Text that came through a terminal

/// Take the terminal out of a line that was read through a pseudo-terminal.
///
/// The domain controller's log is followed through `/usr/bin/script`, because Apple's
/// `container` CLI is a Swift program and Swift's `print` is **block-buffered** when its stdout
/// is a pipe — see `ADController.followLog` for the measurement and why that was the whole of
/// "the AD DC lines don't reach the window". A pty makes it line-buffered and costs three
/// things, all of them here: every line ends `\r\n`, the CLI turns on a cursor hide/show escape
/// it skips for a pipe (`ESC[?25l` / `ESC[?25h`), and `script` itself echoes a `^D^H^H` at the
/// start of the session.
///
/// Anything that is nothing but terminal noise comes back empty, and the caller drops it rather
/// than putting a blank row in the pane.
nonisolated enum TerminalText {
    static func clean(_ line: String) -> String {
        guard line.contains(where: { $0.asciiValue.map { $0 < 0x20 || $0 == 0x7F } ?? false }) else { return line }
        var out = ""
        out.reserveCapacity(line.count)
        var rest = Substring(line)
        while let character = rest.first {
            rest = rest.dropFirst()
            switch character {
            case "\u{1B}":  // ESC — a CSI/OSC/two-character sequence, none of it log content.
                if rest.first == "[" {
                    rest = rest.dropFirst()
                    // CSI: parameter and intermediate bytes, then one final byte 0x40…0x7E.
                    while let next = rest.first, !isCSIFinal(next) { rest = rest.dropFirst() }
                    rest = rest.dropFirst()
                } else if rest.first == "]" {
                    // OSC: up to BEL or ST (ESC \).
                    while let next = rest.first, next != "\u{07}" {
                        rest = rest.dropFirst()
                        if next == "\u{1B}", rest.first == "\\" { rest = rest.dropFirst(); break }
                    }
                    if rest.first == "\u{07}" { rest = rest.dropFirst() }
                } else {
                    rest = rest.dropFirst()
                }
            case "\r", "\u{08}", "\u{04}", "\u{00}", "\u{07}":
                continue
            default:
                out.append(character)
            }
        }
        return out
    }

    private static func isCSIFinal(_ character: Character) -> Bool {
        guard let byte = character.asciiValue else { return false }
        return (0x40...0x7E).contains(byte)
    }
}

// MARK: - Passwords a log should not be carrying (build 20, audit N-4)

/// **What the Log and Test panes show, with the credentials taken out.**
///
/// radiusd at `-x` prints the received packet attribute by attribute, cleartext
/// `User-Password` included, and the Log pane is exactly what somebody screenshots into a
/// ticket. This lab's passwords are cleartext by design — that is not the finding. The
/// finding is that a person debugging an authentication has no way to show anyone the trace
/// without also showing them the password.
///
/// It runs at **render** time, over the forty lines a `LazyVStack` actually builds, and the
/// buffer underneath is untouched: the Log pane's **Show passwords** switch re-renders the
/// same ring with nothing lost. That also means it costs nothing per arriving line, which is
/// the rule everything in this pipeline obeys (PROJECT-STATUS §12).
///
/// Nothing here tries to be clever about what a secret looks like. It knows the names the
/// three servers and the four client tools print, and it replaces the value that follows one.
nonisolated enum LogRedaction {
    static let mask = "••••••"

    /// `User-Password = "alice123"` → `User-Password = "••••••"`.
    ///
    /// The RADIUS attributes radiusd echoes, the two `Cleartext-Password` / `NT-Password`
    /// control items `rlm_files` prints back, and the MS-CHAP material that is
    /// password-equivalent even though it is already a hash.
    static let attributes = ["User-Password", "Cleartext-Password", "NT-Password",
                             "LM-Password", "Password-With-Header", "MS-CHAP-Password",
                             "MS-CHAP-Response", "MS-CHAP2-Response", "MS-CHAP-Challenge",
                             "MS-CHAP2-Success", "MS-CHAP-MPPE-Keys", "MS-MPPE-Send-Key",
                             "MS-MPPE-Recv-Key", "CHAP-Password", "Tunnel-Password",
                             "sambaNTPassword", "userPassword", "unicodePwd", "rootpw"]

    /// Configuration and command-line spellings: `password=P"…"` in an eapol_test
    /// configuration, `bindpw …` in an LDAP one, `-w <secret>` on an LDAP tool's argument
    /// list, `--newpassword=…` from samba-tool, `secret = "…"` from clients.conf.
    static let assignments = ["password", "passwd", "bindpw", "secret", "private_key_passwd",
                              "newpassword", "ADMIN_PASSWORD", "TLS_KEY_B64"]

    /// The one shape with no separator at all: `slapd.conf`'s `rootpw {SSHA}…`, where the
    /// value simply follows the keyword.
    static let spaceAssignments = ["rootpw", "rootpw_hash"]

    /// The flags whose **next word** is a credential. Deliberately short: `-s` is a search
    /// scope to `ldapsearch` and a shared secret to `eapol_test`, and redacting `sub` out of
    /// an LDAP trace would take away something a person needs to see.
    static let flags = ["-w", "--newpassword", "--password"]

    /// One line, redacted. `show: true` leaves it exactly as it arrived.
    static func redact(_ line: String, show: Bool = false) -> String {
        guard !show, !line.isEmpty else { return line }
        var out = line
        for name in attributes { out = maskValues(in: out, after: name, separators: [":=", "=", ":"]) }
        for name in assignments { out = maskValues(in: out, after: name, separators: ["=", ":"]) }
        for name in spaceAssignments { out = maskValues(in: out, after: name, separators: [""]) }
        return maskAfterFlag(in: out)
    }

    /// Every `<name> <separator> <value>` on the line, with the value replaced and everything
    /// else — spacing, separator, what follows — left exactly as it was.
    ///
    /// The name has to be a whole word: `Password-With-Header` must not be found inside
    /// another attribute's name, and `secret` must not match `secretary`.
    private static func maskValues(in line: String, after name: String,
                                   separators: [String]) -> String {
        var out = ""
        var rest = Substring(line)
        while let found = rest.range(of: name, options: [.caseInsensitive]) {
            let preceding = rest[..<found.lowerBound].last
            // Whole word, with one allowance: a `-` in front is a **flag** (`--newpassword=`)
            // rather than the tail of a longer name — but only when what is in front of the
            // dash is not itself a word. That is the difference between `--password` and
            // `Cleartext-Password`, and without it the bare `password` rule fired inside the
            // attribute name and masked the `=` of its own `:=`.
            let wholeWord: Bool
            switch preceding {
            case nil: wholeWord = true
            case let character? where character.isLetter || character.isNumber || character == "_":
                wholeWord = false
            case "-":
                let beforeDash = rest[..<rest.index(before: found.lowerBound)].last
                wholeWord = beforeDash.map { !($0.isLetter || $0.isNumber || $0 == "_") } ?? true
            default: wholeWord = true
            }
            var cursor = found.upperBound
            func skipSpaces() {
                while cursor < rest.endIndex, rest[cursor] == " " || rest[cursor] == "\t" {
                    cursor = rest.index(after: cursor)
                }
            }
            skipSpaces()
            let separator = separators.first { rest[cursor...].hasPrefix($0) }
            guard wholeWord, let separator,
                  let afterSeparator = rest.index(cursor, offsetBy: separator.count,
                                                  limitedBy: rest.endIndex) else {
                out += rest[..<found.upperBound]
                rest = rest[found.upperBound...]
                continue
            }
            cursor = afterSeparator
            skipSpaces()
            let valueStart = cursor
            out += rest[..<valueStart]
            out += masked(rest[valueStart...])
            rest = Substring(remainder(after: rest[valueStart...]))
        }
        return out + rest
    }

    /// The masked value, keeping whatever quoting the original had so the line still reads as
    /// the line it was.
    private static func masked(_ text: Substring) -> String {
        if text.hasPrefix("P\"") { return "P\"\(mask)\"" }
        if text.hasPrefix("\"") { return "\"\(mask)\"" }
        if text.hasPrefix("0x") { return "0x\(mask)" }
        return mask
    }

    /// What follows the value. A quoted value ends at its closing quote; an unquoted one ends
    /// at the first comma, space or tab — radiusd prints
    /// `Cleartext-Password := "x", Sheep-OU := "y"`, and only the first half is secret.
    private static func remainder(after text: Substring) -> String {
        if text.hasPrefix("P\"") || text.hasPrefix("\"") {
            var index = text.hasPrefix("P\"") ? text.index(text.startIndex, offsetBy: 2)
                                              : text.index(after: text.startIndex)
            while index < text.endIndex {
                if text[index] == "\\" {
                    index = text.index(index, offsetBy: 2, limitedBy: text.endIndex) ?? text.endIndex
                    continue
                }
                if text[index] == "\"" { return String(text[text.index(after: index)...]) }
                index = text.index(after: index)
            }
            return ""
        }
        guard let end = text.firstIndex(where: { $0 == "," || $0 == " " || $0 == "\t" }) else { return "" }
        return String(text[end...])
    }

    /// `ldapwhoami -x -D cn=admin,… -w admin123` — the word after the flag, and the joined
    /// `-wadmin123` spelling the LDAP tools also accept.
    private static func maskAfterFlag(in line: String) -> String {
        var fields = line.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        var index = 0
        while index < fields.count {
            let field = fields[index]
            if flags.contains(field), index + 1 < fields.count,
               !fields[index + 1].isEmpty, !fields[index + 1].hasPrefix("-"),
               // `-y <file>` and `eapol_test -s @<file>` name a file, not a secret; a file
               // path in a trace is what tells somebody the secret was NOT in argv.
               !fields[index + 1].hasPrefix("@") {
                fields[index + 1] = mask
                index += 2
                continue
            }
            if field.hasPrefix("-w"), field.count > 2, !field.hasPrefix("--") { fields[index] = "-w" + mask }
            index += 1
        }
        return fields.joined(separator: " ")
    }
}

// MARK: - Clocks

/// **One clock for every timestamp this app prints.**
///
/// Three servers write three different times into the one Log pane: Samba stamps its lines in
/// UTC (`at [Fri, 18 Sep 2026 09:01:46.486099 UTC]`, and a `[2026/09/18 09:01:46.123456, 3]`
/// header on everything else — the container has no time zone but UTC), radiusd prints this
/// Mac's local time with no zone at all, and slapd prints hex seconds since the epoch. Read
/// down the pane they disagree by seven hours, which is exactly as useful as no timestamp.
///
/// So each one is parsed and re-rendered as **this Mac's local `HH:mm:ss`**, and `Date`s the
/// app holds itself (authentication events, sync lines) go through the same renderer.
///
/// **No `DateFormatter`, anywhere in here.** Two reasons, both on record: on this Mac a
/// formatter that is not pinned to `en_US_POSIX` *and* a Gregorian calendar renders 2026 as
/// 2569 BE and can render Thai digits (the trap `ADUserFacts.readableFileTime` fell into, and
/// the one `Tests/unit.swift` pins with a Thai-locale formatter beside this one); and this code
/// runs over every line of a log stream that can be hundreds of lines per RADIUS request, where
/// building locale machinery per line is not affordable. Integer arithmetic and `Int`'s own
/// `description` — which is ASCII digits whatever the Mac's locale says — do the whole job.
nonisolated enum LogTime {
    /// `HH:mm:ss` for an absolute instant, in `zone` (this Mac's, by default).
    static func clock(_ date: Date, in zone: TimeZone = .current) -> String {
        let shifted = date.timeIntervalSince1970 + Double(zone.secondsFromGMT(for: date))
        return clock(secondsSinceEpoch: shifted.rounded(.down))
    }

    /// The same from an already-shifted count of seconds — the form the line parsers produce.
    static func clock(secondsSinceEpoch seconds: Double) -> String {
        let whole = Int(seconds)
        // Floored modulo: a negative instant (a clock set wrong, a bad parse) must still give
        // a time of day rather than a negative hour.
        let inDay = ((whole % 86_400) + 86_400) % 86_400
        return two(inDay / 3600) + ":" + two((inDay / 60) % 60) + ":" + two(inDay % 60)
    }

    private static func two(_ value: Int) -> String {
        // `Int.description` is ASCII regardless of locale; a formatter here is what prints
        // Thai digits on this Mac.
        value < 10 ? "0\(value)" : "\(value)"
    }

    // MARK: Re-rendering a server's own line

    /// Every timestamp in one raw server line, rewritten as this Mac's local `HH:mm:ss`.
    ///
    /// Lines with no timestamp — most of radiusd's `-x` stream — come back unchanged and cost
    /// one cheap test each. A line can carry two (winbindd prints a Samba header *and* the
    /// audit record's own `at [...]`), so every scanner runs.
    static func localized(_ line: String, in zone: TimeZone = .current) -> String {
        var out = line
        out = localizeSlapdPrefix(out, zone)
        out = localizeRadiusPrefix(out, zone)
        out = localizeSambaHeader(out, zone)
        out = localizeSambaAudit(out, zone)
        return out
    }

    /// slapd `-d 256`: `68cbf5a2.0f3a2c1b 0x16f9b3000 conn=1000 fd=12 ACCEPT from IP=…`
    ///
    /// Eight hex digits of `time_t`, a dot, eight more of a sub-second counter. The seconds are
    /// UTC. Anything that is not exactly that shape at the start of the line is left alone —
    /// `conn=1000` and a hex pointer must not be mistaken for a clock.
    static func localizeSlapdPrefix(_ line: String, _ zone: TimeZone) -> String {
        let scalars = Array(line.utf8)
        guard scalars.count > 17, scalars[8] == UInt8(ascii: ".") else { return line }
        guard let seconds = hex(scalars, 0, 8), hex(scalars, 9, 17) != nil else { return line }
        // 2001-01-01 … 2100-01-01. A plausibility window, because eight hex digits is also
        // what a great many other things look like.
        guard seconds > 978_307_200, seconds < 4_102_444_800 else { return line }
        let instant = Date(timeIntervalSince1970: Double(seconds))
        let stamp = clock(instant, in: zone)
        return stamp + String(line.dropFirst(17))
    }

    private static func hex(_ bytes: [UInt8], _ from: Int, _ to: Int) -> Int? {
        var value = 0
        for index in from..<to {
            let byte = bytes[index]
            let digit: Int
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): digit = Int(byte - UInt8(ascii: "0"))
            case UInt8(ascii: "a")...UInt8(ascii: "f"): digit = Int(byte - UInt8(ascii: "a")) + 10
            case UInt8(ascii: "A")...UInt8(ascii: "F"): digit = Int(byte - UInt8(ascii: "A")) + 10
            default: return nil
            }
            value = value * 16 + digit
        }
        return value
    }

    /// radiusd: `Fri Sep 18 09:01:46 2026 : Auth: (0) Login OK: [alice] …`
    ///
    /// Already this Mac's local time — FreeRADIUS uses `ctime`, no zone printed — so this is a
    /// re-render, not a conversion. The date is dropped: it is today's, in a pane whose whole
    /// content is the last few minutes, and the column has to line up with the other two feeds.
    static func localizeRadiusPrefix(_ line: String, _ zone: TimeZone) -> String {
        // "Fri Sep 18 09:01:46 2026 : " — `%e` pads a single-digit day with a space, so the
        // field count rather than a fixed width is what this leans on.
        let fields = line.split(separator: " ", maxSplits: 6, omittingEmptySubsequences: true)
        guard fields.count >= 6, fields[5] == ":" else { return line }
        guard fields[0].count == 3, weekdays.contains(fields[0].lowercased()) else { return line }
        guard months.contains(fields[1].lowercased()), Int(fields[2]) != nil, Int(fields[4]) != nil else { return line }
        let clockField = fields[3].split(separator: ":")
        guard clockField.count == 3, clockField.allSatisfy({ Int($0) != nil }) else { return line }
        let stamp = two(Int(clockField[0])!) + ":" + two(Int(clockField[1])!) + ":" + two(Int(clockField[2])!)
        return stamp + " :" + String(fields.count > 6 ? " " + fields[6] : "")
    }

    /// Samba's ordinary header: `[2026/09/18 09:01:46.123456,  3] ../../source3/…`
    ///
    /// Not necessarily at column 0 — winbindd prefixes its own lines with `/usr/sbin/winbindd: `
    /// and an anchored match misses every one of them, which is the mistake `ADAuthAudit` has a
    /// fixture for. The container runs with no `TZ`, so Samba's clock there is UTC.
    static func localizeSambaHeader(_ line: String, _ zone: TimeZone) -> String {
        // Every `[…]` on the line is offered to the parser, not just the first: an audit line
        // opens with `Auth: [LDAP,simple bind]` and the header, when there is one, comes later.
        var open = line.firstIndex(of: "[")
        while let start = open {
            guard let close = line[start...].firstIndex(of: "]") else { return line }
            let inside = line[line.index(after: start)..<close]
            // "2026/09/18 09:01:46.123456,  3"
            let halves = inside.split(separator: ",", maxSplits: 1)
            let parts = (halves.first ?? "").split(separator: " ", omittingEmptySubsequences: true)
            if parts.count == 2 {
                let date = parts[0].split(separator: "/")
                let time = parts[1].split(separator: ".").first?.split(separator: ":") ?? []
                if date.count == 3, time.count == 3,
                   let year = Int(date[0]), let month = Int(date[1]), let day = Int(date[2]),
                   let hour = Int(time[0]), let minute = Int(time[1]), let second = Int(time[2]),
                   // The upper bounds matter as much as the lower ones: this is untrusted log
                   // text, and `year * 86_400` or `hour * 3600` on a 10^17 field overflows
                   // Int64 and traps. Every `[…]` on every line reaches here.
                   year > 1970, year < 10_000, month >= 1, month <= 12, day >= 1, day <= 31,
                   hour >= 0, hour < 24, minute >= 0, minute < 60, second >= 0, second < 62 {
                    let utc = Double(ADAuthAudit.daysFromCivil(year: year, month: month, day: day) * 86_400
                                     + hour * 3600 + minute * 60 + second)
                    let stamp = clock(Date(timeIntervalSince1970: utc), in: zone)
                    let rest = halves.dropFirst().first.map { "," + $0 } ?? ""
                    return String(line[line.startIndex..<start]) + "[" + stamp + rest + String(line[close...])
                }
            }
            open = line[line.index(after: start)...].firstIndex(of: "[")
        }
        return line
    }

    /// Samba's audit record: `… at [Fri, 18 Sep 2026 09:01:46.486099 UTC] with [MSCHAPv2] …`
    ///
    /// The one timestamp in the app that was already parsed (`ADAuthAudit.parseTimestamp`, for
    /// Status ▸ Recent authentications) and yet still reached the Log pane as UTC, seven hours
    /// out from the radiusd line for the same login directly above it.
    static func localizeSambaAudit(_ line: String, _ zone: TimeZone) -> String {
        guard let marker = line.range(of: " at ["),
              let close = line[marker.upperBound...].firstIndex(of: "]") else { return line }
        let inside = String(line[marker.upperBound..<close])
        guard let instant = ADAuthAudit.parseTimestamp(inside) else { return line }
        return String(line[line.startIndex..<marker.lowerBound]) + " at ["
            + clock(instant, in: zone) + "]" + String(line[close...].dropFirst())
    }

    private static let weekdays: Set<String> = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]
    private static let months: Set<String> = ["jan", "feb", "mar", "apr", "may", "jun",
                                              "jul", "aug", "sep", "oct", "nov", "dec"]
}


// MARK: - Reading a line (build 32)

/// **How a raw server line is drawn in the Log pane** (build 32, owner: "ปรับ Format log ให้อ่าน
/// ง่ายขึ้น"). Pure, so the unit suite pins it. Three jobs:
///
/// * a **clock column** — the server's own stamp when it printed one (slapd, Samba, radiusd
///   outside debug), otherwise the time the app received the line, because radiusd at `-x`
///   prints none and a RADIUS log with no time in it cannot be matched to a device's own log;
/// * the **noise** taken out of the message: slapd's thread pointer after its stamp;
/// * which lines are **authentications**, for the Auth only switch every feed now has.
nonisolated enum LogPresentation {
    /// `(clock, message)`. `clock` is `HH:mm:ss`, or nil when neither the line nor `received`
    /// has one.
    static func split(_ localized: String, received: Date?, in zone: TimeZone = .current) -> (clock: String?, message: String) {
        var clock: String?
        var message = Substring(localized)
        if message.count >= 8, isClock(message.prefix(8)) {
            clock = String(message.prefix(8))
            message = message.dropFirst(8)
            // radiusd outside debug: "HH:mm:ss : Auth: …"
            if message.hasPrefix(" : ") { message = message.dropFirst(3) }
            // slapd: "HH:mm:ss 0x16e9d7000 conn=…" — the thread is not something to read.
            if message.hasPrefix(" 0x") {
                let rest = message.dropFirst(1)
                if let space = rest.firstIndex(of: " ") { message = rest[space...] }
            }
        } else if let received {
            clock = LogTime.clock(received, in: zone)
        }
        return (clock, String(message.drop { $0 == " " }))
    }

    /// Lines that are true and say nothing: radiusd between requests, its BlastRADIUS banner
    /// rules, slapd's connection teardown.
    static func isQuiet(_ text: String) -> Bool {
        quietMarkers.contains { text.contains($0) } || text.hasSuffix(" closed")
    }

    /// Between requests, and radiusd's start-up banner — measured from a real start of 3.2.10.
    /// Faded, never hidden: a start that failed is diagnosed from exactly these lines.
    private static let quietMarkers = [
        "Ready to process requests", "Waking up in ", "Cleaning up request", "!!!!!!!!",
        " UNBIND", "Finished request", "Done request",
        "Copyright (C)", "There is NO warranty", "PARTICULAR PURPOSE", "You may redistribute",
        "GNU General Public License", "see the file named COPYRIGHT", "is developed, maintained",
        "For commercial support", "inkbridgenetworks.com", "Compiling Auth-Type",
        "Using cached TLS configuration", "Found debugger attached",
        "All secret information will be replaced", "suppress_secrets=no",
    ]

    /// The Auth only switch: a line that is a verdict, or an attempt the server refused
    /// without one. The same rules Recent authentications is built from, so the two agree.
    static func isAuthLine(_ text: String, source: LogSource) -> Bool {
        switch source {
        case .radius:
            return text.contains("Login OK") || text.contains("Login incorrect")
                || text.contains("from unknown client ") || text.contains("Dropping packet without response")
        case .ldap:
            return text.contains(" BIND dn=\"") && text.contains(" method=")
                || text.contains(" RESULT tag=97 ")
        case .adDC:
            return ADAuthAudit.isAuthLine(text)
        }
    }

    private static func isClock(_ text: Substring) -> Bool {
        let bytes = Array(text.utf8)
        guard bytes.count == 8, bytes[2] == UInt8(ascii: ":"), bytes[5] == UInt8(ascii: ":") else { return false }
        return [0, 1, 3, 4, 6, 7].allSatisfy { (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[$0]) }
    }
}
