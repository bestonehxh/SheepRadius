import Foundation

/// Reading this user's own CLI, `radctl`, into the rule list.
///
/// `/opt/homebrew/bin/radctl` keeps VLAN policy in two files and regenerates
/// `raddb/policy.d/vlan_map` from them (`vlan_regen`):
///
/// ```
/// vlan-map.csv     <Called-Station-Id>,<vlan>     one per line; a key ending in ":" is a prefix
/// vlan-rules.tsv   name  attr1 op1 val1  attr2 op2 val2  vlan     tab separated, ops eq/ne/…
/// ```
///
/// **The order inverts.** `vlan_regen` emits the maps first, then the advanced rules, each as a
/// plain `if (…) { update reply { Tunnel-Private-Group-Id := … } }` with nothing stopping the
/// walk — so when two of them match, the **last** one wins. This pane is first-match-wins, so
/// the same file produces the same replies only if the whole sequence is turned around:
/// advanced rules reversed, then maps reversed. That is what `RadctlImport.rules` returns, and
/// the confirm sheet says so in those words.
///
/// The imported rules go in at the **top** of the list, above the group rules: in radctl their
/// `:=` overwrote whatever the `users` file had supplied, and above a stopping group rule is
/// the only place in a first-match-wins list where that still holds.
nonisolated enum RadctlImport {
    /// Where radctl keeps them. Both are read-only to this app, and it never writes there.
    static let defaultDirectory = "/opt/homebrew/etc/raddb"
    static let mapFileName = "vlan-map.csv"
    static let rulesFileName = "vlan-rules.tsv"

    /// One line of one of the files, already turned into a rule — plus where it came from, so
    /// the confirm sheet can show the source line next to what it becomes.
    nonisolated struct Item: Sendable, Identifiable {
        var id = UUID()
        /// `vlan-map.csv:3` — the file and line a person can go and look at.
        var origin: String
        /// The raw line, for the sheet.
        var source: String
        var rule: PolicyRule
    }

    nonisolated struct Result: Sendable {
        /// In the order they will be inserted: already reversed.
        var items: [Item] = []
        /// Lines that could not be read, with the reason. Never silently dropped.
        var problems: [String] = []
        /// Files that were not there at all.
        var missing: [String] = []

        var isEmpty: Bool { items.isEmpty }
    }

    /// radctl's own operator spellings, normalised the way its `op_normalize` does.
    static func normalizeOperator(_ raw: String) -> String? {
        switch raw.lowercased() {
        case "eq", "equals", "equal": "eq"
        case "ne", "not-equals", "notequals": "ne"
        case "contains", "contain": "contains"
        case "begins", "begins-with", "beginwith", "startswith", "starts-with": "begins"
        case "ends", "ends-with", "endwith", "endswith": "ends"
        case "regex", "matches": "regex"
        default: nil
        }
    }

    /// Everything both files say, in the order it has to be inserted.
    static func read(directory: String, using fm: FileManager = .default) -> Result {
        var result = Result()
        let mapPath = (directory as NSString).appendingPathComponent(mapFileName)
        let rulesPath = (directory as NSString).appendingPathComponent(rulesFileName)

        let mapText = fm.fileExists(atPath: mapPath) ? (try? String(contentsOfFile: mapPath, encoding: .utf8)) : nil
        let rulesText = fm.fileExists(atPath: rulesPath) ? (try? String(contentsOfFile: rulesPath, encoding: .utf8)) : nil
        if mapText == nil { result.missing.append(mapPath) }
        if rulesText == nil { result.missing.append(rulesPath) }

        let maps = parseMap(mapText ?? "", into: &result.problems)
        let advanced = parseRules(rulesText ?? "", into: &result.problems)
        // Reversed, and the advanced rules first: see the note at the top.
        result.items = advanced.reversed() + maps.reversed()
        return result
    }

    // MARK: vlan-map.csv

    static func parseMap(_ text: String, into problems: inout [String]) -> [Item] {
        var out: [Item] = []
        for (number, raw) in lines(of: text) {
            let parts = raw.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
            let where_ = "\(mapFileName):\(number)"
            guard parts.count == 2 else {
                problems.append("\(where_): \"\(raw)\" is not <Called-Station-Id>,<vlan>.")
                continue
            }
            // radctl trims trailing whitespace from the key and strips it all from the VLAN.
            let key = String(parts[0]).replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
            let vlan = parts[1].filter { !$0.isWhitespace }
            guard !key.isEmpty else {
                problems.append("\(where_): no Called-Station-Id.")
                continue
            }
            guard let number = Int(vlan), (1...4094).contains(number) else {
                problems.append("\(where_): \"\(vlan)\" is not a VLAN between 1 and 4094.")
                continue
            }
            // A key ending in ":" is every SSID in that AP group — radctl writes it as
            // `=~ /^<key>/` and this app calls that "begins with".
            let kind: ConditionKind = key.hasSuffix(":") ? .calledStationBeginsWith : .calledStationIs
            out.append(Item(origin: where_, source: raw,
                            rule: PolicyRule(conditions: [RuleCondition(kind: kind, value: key)],
                                             stopAfterMatch: true, vlan: String(number))))
        }
        return out
    }

    // MARK: vlan-rules.tsv

    static func parseRules(_ text: String, into problems: inout [String]) -> [Item] {
        var out: [Item] = []
        for (number, raw) in lines(of: text) {
            let f = raw.components(separatedBy: "\t")
            let where_ = "\(rulesFileName):\(number)"
            guard f.count >= 8 else {
                problems.append("\(where_): expected 8 tab-separated fields, found \(f.count).")
                continue
            }
            let name = f[0].trimmingCharacters(in: .whitespaces)
            guard let first = condition(attribute: f[1], op: f[2], value: f[3], at: where_, into: &problems) else {
                continue
            }
            var conditions = [first]
            let secondAttribute = f[4].trimmingCharacters(in: .whitespaces)
            if !secondAttribute.isEmpty, secondAttribute != "-" {
                guard let second = condition(attribute: f[4], op: f[5], value: f[6], at: where_,
                                             into: &problems) else { continue }
                conditions.append(second)
            }
            let vlan = f[7].filter { !$0.isWhitespace }
            guard let value = Int(vlan), (1...4094).contains(value) else {
                problems.append("\(where_): \"\(vlan)\" is not a VLAN between 1 and 4094.")
                continue
            }
            out.append(Item(origin: where_, source: raw,
                            rule: PolicyRule(name: name, match: .all, conditions: conditions,
                                             stopAfterMatch: true, vlan: String(value))))
        }
        return out
    }

    /// One radctl (attribute, operator, value) triple as a condition.
    ///
    /// The pairs this app has a plain-words condition for become that condition, so the rule is
    /// editable afterwards. Everything else becomes a **raw** condition holding exactly the
    /// unlang `condition_expr` would have written, existence guard and all — nothing is dropped
    /// and nothing is approximated, at the price of the preview saying "only radiusd can decide
    /// this one".
    static func condition(attribute rawAttribute: String, op rawOperator: String, value rawValue: String,
                          at origin: String, into problems: inout [String]) -> RuleCondition? {
        let attribute = rawAttribute.trimmingCharacters(in: .whitespaces)
        let value = rawValue
        guard !attribute.isEmpty else {
            problems.append("\(origin): no attribute name.")
            return nil
        }
        guard attribute.range(of: "^[A-Za-z][A-Za-z0-9-]*$", options: .regularExpression) != nil else {
            problems.append("\(origin): \"\(attribute)\" is not an attribute name.")
            return nil
        }
        guard let op = normalizeOperator(rawOperator.trimmingCharacters(in: .whitespaces)) else {
            problems.append("\(origin): \"\(rawOperator)\" is not one of eq ne contains begins ends regex.")
            return nil
        }
        guard !value.isEmpty else {
            problems.append("\(origin): no value.")
            return nil
        }

        switch (attribute, op) {
        case ("Called-Station-Id", "eq"): return RuleCondition(kind: .calledStationIs, value: value)
        case ("Called-Station-Id", "begins"): return RuleCondition(kind: .calledStationBeginsWith, value: value)
        case ("User-Name", "eq"): return RuleCondition(kind: .usernameIs, value: value)
        case ("User-Name", "ends"): return RuleCondition(kind: .usernameEndsWith, value: value)
        case ("User-Name", "regex"): return RuleCondition(kind: .usernameMatches, value: value)
        case ("NAS-Identifier", "eq"): return RuleCondition(kind: .nasIdentifierIs, value: value)
        case ("NAS-Identifier", "regex"): return RuleCondition(kind: .nasIdentifierMatches, value: value)
        case ("NAS-IP-Address", "eq") where Validation.isValidAddress(value):
            return RuleCondition(kind: .nasIPInCIDR, value: value)
        case ("NAS-Port-Type", "eq") where RulePortType(rawValue: value) != nil:
            return RuleCondition(kind: .portType, value: value)
        case ("Calling-Station-Id", "eq") where RuleUnlang.macDigits(value) != nil:
            return RuleCondition(kind: .callingMACIs, value: value)
        case ("Calling-Station-Id", "regex"): return RuleCondition(kind: .callingMACMatches, value: value)
        default:
            return RuleCondition(kind: .raw, value: unlang(attribute: attribute, op: op, value: value))
        }
    }

    /// radctl's `condition_expr`, with the `&Attr &&` existence guard its `if` line carries —
    /// the same guard `RuleUnlang.guarded` writes, and for the same measured reason.
    static func unlang(attribute: String, op: String, value: String) -> String {
        let test: String
        switch op {
        case "eq": test = "&\(attribute) == \"\(RuleUnlang.quoted(value))\""
        case "ne": test = "&\(attribute) != \"\(RuleUnlang.quoted(value))\""
        case "contains": test = "&\(attribute) =~ /\(RuleUnlang.regexLiteral(value))/"
        case "begins": test = "&\(attribute) =~ /^\(RuleUnlang.regexLiteral(value))/"
        case "ends": test = "&\(attribute) =~ /\(RuleUnlang.regexLiteral(value))$/"
        default: test = "&\(attribute) =~ /\(RuleUnlang.regexBody(value))/"
        }
        return "&\(attribute) && \(test)"
    }

    // MARK: Helpers

    /// Numbered, with blank lines and `#` comments skipped — exactly what radctl's `case` does.
    private static func lines(of text: String) -> [(number: Int, text: String)] {
        text.split(separator: "\n", omittingEmptySubsequences: false).enumerated().compactMap { index, raw in
            let line = String(raw).trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
            return (index + 1, line)
        }
    }
}
