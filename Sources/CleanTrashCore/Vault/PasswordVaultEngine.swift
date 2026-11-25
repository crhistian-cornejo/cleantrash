import CryptoKit
import Foundation
import Security

// MARK: - Password Vault Model

public enum PasswordStrength: Int, Sendable, Codable, Equatable, Comparable {
    case weak = 0
    case fair = 1
    case strong = 2

    public static func < (lhs: PasswordStrength, rhs: PasswordStrength) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var label: String {
        switch self {
        case .weak: return "Débil"
        case .fair: return "Media"
        case .strong: return "Fuerte"
        }
    }
}

public struct VaultItem: Identifiable, Sendable, Codable, Equatable {
    public let id: UUID
    public var title: String
    public var url: String
    public var username: String
    public var password: String
    public var notes: String
    public var folder: String
    public var otpAuth: String
    public var source: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        title: String,
        url: String = "",
        username: String = "",
        password: String = "",
        notes: String = "",
        folder: String = "General",
        otpAuth: String = "",
        source: String = "CleanTrash",
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.title = title
        self.url = url
        self.username = username
        self.password = password
        self.notes = notes
        self.folder = folder
        self.otpAuth = otpAuth
        self.source = source
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Canonical normalized host used for grouping, deduplication, and Apple Passwords export.
    public var normalizedDomain: String {
        VaultHygieneAuditor.normalizeDomain(from: url, fallbackTitle: title)
    }

    public var strength: PasswordStrength {
        VaultHygieneAuditor.evaluateStrength(password)
    }
}

public struct VaultAuditReport: Sendable, Equatable {
    public let totalCount: Int
    public let exactDuplicateIDs: Set<UUID>
    public let conflictGroups: [[UUID]]
    public let reusedPasswordIDs: Set<UUID>
    public let weakPasswordIDs: Set<UUID>
    public let score: Int // 0...100

    public init(
        totalCount: Int = 0,
        exactDuplicateIDs: Set<UUID> = [],
        conflictGroups: [[UUID]] = [],
        reusedPasswordIDs: Set<UUID> = [],
        weakPasswordIDs: Set<UUID> = [],
        score: Int = 100
    ) {
        self.totalCount = totalCount
        self.exactDuplicateIDs = exactDuplicateIDs
        self.conflictGroups = conflictGroups
        self.reusedPasswordIDs = reusedPasswordIDs
        self.weakPasswordIDs = weakPasswordIDs
        self.score = score
    }
}

public struct VaultCleanResult: Sendable, Equatable {
    public let items: [VaultItem]
    public let removedDuplicates: Int
    public let recategorizedCount: Int
    public let normalizedTitles: Int
}

// MARK: - NordPass & Apple Passwords RFC-4180 CSV Importer / Exporter

public enum VaultCSVCodec {
    /// Parses NordPass CSV (`name,url,username,password,note,folder,...`) as well as
    /// Apple Passwords / Chrome / 1Password CSV (`Title,URL,Username,Password,Notes,OTPAuth`).
    public static func importCSV(_ rawCSV: String) -> [VaultItem] {
        let rows = parseRFC4180(rawCSV)
        guard let headerRow = rows.first, !headerRow.isEmpty else { return [] }
        let headers = headerRow.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}"))
                .lowercased()
        }

        func idx(_ candidates: [String]) -> Int? {
            for c in candidates {
                if let i = headers.firstIndex(of: c) { return i }
            }
            return nil
        }

        let titleIdx = idx(["name", "title", "service", "website name"])
        let urlIdx = idx(["url", "website", "login_uri", "hostname"])
        let extraUrlIdx = idx(["additional_urls"])
        let userIdx = idx(["username", "login_username", "user", "login"])
        let emailIdx = idx(["email"])
        let passIdx = idx(["password", "login_password", "pass"])
        let noteIdx = idx(["note", "notes", "extra", "comment"])
        let folderIdx = idx(["folder", "grouping", "category", "tags"])
        let sharedFolderIdx = idx(["shared_folder"])
        let otpIdx = idx(["otpauth", "otp", "totp", "login_totp"])
        let typeIdx = idx(["type"])
        let isNordPass = headers.contains("cardholdername") || (headers.contains("name") && headers.contains("note"))

        var items: [VaultItem] = []
        for row in rows.dropFirst() {
            func col(_ index: Int?) -> String {
                guard let i = index, i < row.count else { return "" }
                return row[i].trimmingCharacters(in: .whitespacesAndNewlines)
            }

            let rowType = col(typeIdx).lowercased()
            if rowType == "credit_card" || rowType == "personal_info" { continue }

            let rawTitle = col(titleIdx)
            let rawURL = col(urlIdx)
            let extraURLs = col(extraUrlIdx)
            let rawUser = col(userIdx)
            let username = rawUser.isEmpty ? col(emailIdx) : rawUser
            let password = col(passIdx)
            var notes = col(noteIdx)
            if !extraURLs.isEmpty {
                notes = notes.isEmpty ? "URLs adicionales: \(extraURLs)" : "\(notes)\nURLs adicionales: \(extraURLs)"
            }
            let rawFolder = col(folderIdx).isEmpty ? col(sharedFolderIdx) : col(folderIdx)
            let otp = col(otpIdx)

            // Skip empty or non-password rows
            if password.isEmpty && username.isEmpty && rawURL.isEmpty { continue }

            let cleanURL = VaultHygieneAuditor.normalizeURL(rawURL)
            let title = rawTitle.isEmpty
                ? VaultHygieneAuditor.prettyTitle(fromDomain: VaultHygieneAuditor.normalizeDomain(from: cleanURL, fallbackTitle: username))
                : rawTitle
            let folder = rawFolder.isEmpty
                ? VaultHygieneAuditor.inferFolder(domain: VaultHygieneAuditor.normalizeDomain(from: cleanURL, fallbackTitle: title), title: title)
                : rawFolder

            items.append(VaultItem(
                title: title,
                url: cleanURL,
                username: username,
                password: password,
                notes: notes,
                folder: folder,
                otpAuth: otp,
                source: isNordPass ? "NordPass" : "CSV"
            ))
        }
        return items
    }

    /// Exports to Apple Passwords CSV (`Title,URL,Username,Password,Notes,OTPAuth`) —
    /// ready to import into macOS Passwords → syncs automatically to iPhone via iCloud Keychain!
    public static func exportApplePasswordsCSV(_ items: [VaultItem]) -> String {
        var lines: [String] = ["Title,URL,Username,Password,Notes,OTPAuth"]
        for item in items {
            let fields = [
                item.title,
                item.url,
                item.username,
                item.password,
                item.notes,
                item.otpAuth
            ].map(escapeCSV)
            lines.append(fields.joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func escapeCSV(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") || value.contains("\r") {
            return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        return value
    }

    /// Complete RFC-4180 CSV parser supporting CRLF/LF/CR line endings, quoted fields,
    /// escaped quotes, embedded newlines, and auto-detected `,` / `;` / `\t` delimiters.
    /// Uses `unicodeScalars` (not `Character`) because Swift combines `\r\n` into a single `Character`.
    static func parseRFC4180(_ text: String) -> [[String]] {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        // Detect delimiter from the first line (comma default, semicolon/tab for localized exports)
        let firstLine = normalized.prefix { $0 != "\n" }
        let commaCount = firstLine.filter { $0 == "," }.count
        let semiCount = firstLine.filter { $0 == ";" }.count
        let tabCount = firstLine.filter { $0 == "\t" }.count
        let delimiter: UnicodeScalar
        if semiCount > commaCount && semiCount >= tabCount {
            delimiter = ";"
        } else if tabCount > commaCount && tabCount > semiCount {
            delimiter = "\t"
        } else {
            delimiter = ","
        }

        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        let scalars = Array(normalized.unicodeScalars)
        var i = 0

        while i < scalars.count {
            let sc = scalars[i]
            if inQuotes {
                if sc == "\"" {
                    if i + 1 < scalars.count && scalars[i + 1] == "\"" {
                        field.append("\"")
                        i += 2
                        continue
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.unicodeScalars.append(sc)
                }
            } else {
                if sc == "\"" && field.isEmpty {
                    inQuotes = true
                } else if sc == delimiter {
                    row.append(field)
                    field = ""
                } else if sc == "\n" {
                    row.append(field)
                    field = ""
                    if !row.allSatisfy({ $0.isEmpty }) { rows.append(row) }
                    row = []
                } else {
                    field.unicodeScalars.append(sc)
                }
            }
            i += 1
        }
        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            if !row.allSatisfy({ $0.isEmpty }) { rows.append(row) }
        }
        return rows
    }
}

// MARK: - Hygiene Auditor, Deduplicator, Organizer & Password Generator

public enum VaultHygieneAuditor {
    private static let commonWeak: Set<String> = [
        "123456", "12345678", "123456789", "password", "qwerty", "abc123",
        "111111", "admin", "letmein", "welcome", "iloveyou", "000000"
    ]

    public static func evaluateStrength(_ password: String) -> PasswordStrength {
        let trimmed = password.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .weak }
        if commonWeak.contains(trimmed.lowercased()) || trimmed.count < 8 {
            return .weak
        }
        var classes = 0
        if trimmed.rangeOfCharacter(from: .lowercaseLetters) != nil { classes += 1 }
        if trimmed.rangeOfCharacter(from: .uppercaseLetters) != nil { classes += 1 }
        if trimmed.rangeOfCharacter(from: .decimalDigits) != nil { classes += 1 }
        if trimmed.rangeOfCharacter(from: CharacterSet.alphanumerics.inverted) != nil { classes += 1 }

        if trimmed.count >= 14 && classes >= 3 { return .strong }
        if trimmed.count >= 12 && classes >= 4 { return .strong }
        if trimmed.count >= 10 && classes >= 2 { return .fair }
        return .weak
    }

    public static func audit(_ items: [VaultItem]) -> VaultAuditReport {
        guard !items.isEmpty else { return VaultAuditReport() }

        var exactSeen: [String: UUID] = [:]
        var exactDuplicates = Set<UUID>()
        var accountBuckets: [String: [VaultItem]] = [:]
        var passwordBuckets: [String: [UUID]] = [:]
        var weakIDs = Set<UUID>()

        for item in items {
            let domain = item.normalizedDomain
            let user = item.username.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            let exactKey = "\(domain)|\(user)|\(item.password)"
            if exactSeen[exactKey] != nil {
                exactDuplicates.insert(item.id)
            } else {
                exactSeen[exactKey] = item.id
            }

            if !domain.isEmpty || !user.isEmpty {
                accountBuckets["\(domain)|\(user)", default: []].append(item)
            }
            if !item.password.isEmpty {
                passwordBuckets[item.password, default: []].append(item.id)
            }
            if evaluateStrength(item.password) == .weak {
                weakIDs.insert(item.id)
            }
        }

        var conflicts: [[UUID]] = []
        for (_, group) in accountBuckets where group.count > 1 {
            let uniquePasswords = Set(group.map(\.password))
            if uniquePasswords.count > 1 {
                conflicts.append(group.map(\.id))
            }
        }

        var reusedIDs = Set<UUID>()
        for (_, ids) in passwordBuckets where ids.count > 1 {
            reusedIDs.formUnion(ids)
        }

        let total = max(1, items.count)
        let dupPenalty = Double(exactDuplicates.count) / Double(total) * 28.0
        let weakPenalty = Double(weakIDs.count) / Double(total) * 42.0
        let reusePenalty = Double(reusedIDs.count) / Double(total) * 30.0
        let score = max(0, min(100, Int((100.0 - dupPenalty - weakPenalty - reusePenalty).rounded())))

        return VaultAuditReport(
            totalCount: items.count,
            exactDuplicateIDs: exactDuplicates,
            conflictGroups: conflicts,
            reusedPasswordIDs: reusedIDs,
            weakPasswordIDs: weakIDs,
            score: score
        )
    }

    /// Removes exact duplicates (keeping the entry with richer notes/OTP/newest date),
    /// normalizes URLs & titles, auto-sorts into smart folders, and orders alphabetically.
    public static func cleanAndOrganize(_ items: [VaultItem]) -> VaultCleanResult {
        var bestByExactKey: [String: VaultItem] = [:]
        var removedDuplicates = 0
        var recategorized = 0
        var normalizedTitles = 0

        for raw in items {
            var item = raw
            let cleanURL = normalizeURL(item.url)
            item.url = cleanURL
            let domain = normalizeDomain(from: cleanURL, fallbackTitle: item.title)

            if item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || item.title.hasPrefix("http") {
                let pretty = prettyTitle(fromDomain: domain)
                if pretty != item.title {
                    item.title = pretty
                    normalizedTitles += 1
                }
            }

            if item.folder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || item.folder == "General" || item.folder == "Uncategorized" {
                let inferred = inferFolder(domain: domain, title: item.title)
                if inferred != item.folder {
                    item.folder = inferred
                    recategorized += 1
                }
            }

            let key = "\(domain)|\(item.username.lowercased().trimmingCharacters(in: .whitespacesAndNewlines))|\(item.password)"
            if var existing = bestByExactKey[key] {
                removedDuplicates += 1
                // Merge useful metadata so nothing valuable is lost
                if existing.notes.isEmpty && !item.notes.isEmpty { existing.notes = item.notes }
                if existing.otpAuth.isEmpty && !item.otpAuth.isEmpty { existing.otpAuth = item.otpAuth }
                if existing.url.isEmpty && !item.url.isEmpty { existing.url = item.url }
                bestByExactKey[key] = existing
            } else {
                bestByExactKey[key] = item
            }
        }

        let sorted = bestByExactKey.values.sorted {
            if $0.folder != $1.folder { return $0.folder.localizedCaseInsensitiveCompare($1.folder) == .orderedAscending }
            return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }

        return VaultCleanResult(
            items: sorted,
            removedDuplicates: removedDuplicates,
            recategorizedCount: recategorized,
            normalizedTitles: normalizedTitles
        )
    }

    public static func generateStrongPassword(length: Int = 20) -> String {
        let lower = Array("abcdefghijkmnopqrstuvwxyz")
        let upper = Array("ABCDEFGHJKLMNPQRSTUVWXYZ")
        let digits = Array("23456789")
        let symbols = Array("!@#$%&*-_+=?")
        let all = lower + upper + digits + symbols

        var chars: [Character] = [
            lower.randomElement()!,
            upper.randomElement()!,
            digits.randomElement()!,
            symbols.randomElement()!
        ]
        while chars.count < max(12, length) {
            chars.append(all.randomElement()!)
        }
        chars.shuffle()
        return String(chars)
    }

    public static func normalizeURL(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            return trimmed
        }
        if trimmed.contains(".") && !trimmed.contains(" ") {
            return "https://\(trimmed)"
        }
        return trimmed
    }

    public static func normalizeDomain(from rawURL: String, fallbackTitle: String) -> String {
        let normalized = normalizeURL(rawURL)
        if let host = URL(string: normalized)?.host?.lowercased() {
            return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        }
        return fallbackTitle.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func prettyTitle(fromDomain domain: String) -> String {
        let stem = domain.split(separator: ".").first.map(String.init) ?? domain
        guard !stem.isEmpty else { return "Cuenta" }
        return stem.prefix(1).uppercased() + stem.dropFirst()
    }

    public static func inferFolder(domain: String, title: String) -> String {
        let hay = "\(domain) \(title)".lowercased()
        if ["github", "gitlab", "vercel", "supabase", "cloudflare", "aws", "digitalocean", "linear", "figma", "openai", "anthropic", "claude", "apple.com", "npmjs", "docker", "stripe", "sentry", "railway", "fly.io"].contains(where: { hay.contains($0) }) {
            return "Desarrollo"
        }
        if ["bank", "bcp", "interbank", "bbva", "scotiabank", "paypal", "wise", "binance", "coinbase", "mercadopago", "visa", "mastercard", "revolut", "yape", "plin"].contains(where: { hay.contains($0) }) {
            return "Finanzas"
        }
        if ["google", "gmail", "icloud", "outlook", "slack", "notion", "zoom", "microsoft", "atlassian", "jira", "dropbox"].contains(where: { hay.contains($0) }) {
            return "Trabajo"
        }
        if ["instagram", "facebook", "x.com", "twitter", "tiktok", "linkedin", "discord", "reddit", "whatsapp", "telegram"].contains(where: { hay.contains($0) }) {
            return "Social"
        }
        if ["amazon", "mercadolibre", "aliexpress", "ebay", "shein", "uber", "rappi", "airbnb", "booking"].contains(where: { hay.contains($0) }) {
            return "Compras"
        }
        if ["spotify", "netflix", "disney", "hbo", "max.com", "youtube", "twitch", "steam", "playstation", "xbox", "nintendo"].contains(where: { hay.contains($0) }) {
            return "Entretenimiento"
        }
        return "General"
    }

    /// Context-aware match score (0 = no match, higher = closer match) for browser URL host or active macOS app name.
    public static func matchScore(item: VaultItem, activeHost: String?, activeAppName: String?) -> Int {
        let itemDomain = item.normalizedDomain
        let itemTitle = item.title.lowercased()

        if let host = activeHost?.lowercased(), !host.isEmpty {
            let cleanHost = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
            if itemDomain == cleanHost { return 100 }
            let hostRoot = rootDomain(cleanHost)
            let itemRoot = rootDomain(itemDomain)
            if !hostRoot.isEmpty && hostRoot == itemRoot { return 85 }
            if !itemDomain.isEmpty && (cleanHost.contains(itemDomain) || itemDomain.contains(cleanHost)) { return 70 }
            if !hostRoot.isEmpty && itemTitle.contains(hostRoot.split(separator: ".").first.map(String.init) ?? hostRoot) { return 55 }
        }

        if let app = activeAppName?.lowercased(), app.count >= 3 {
            let cleanApp = app.replacingOccurrences(of: ".app", with: "").trimmingCharacters(in: .whitespaces)
            if itemTitle == cleanApp { return 65 }
            if itemTitle.contains(cleanApp) || itemDomain.contains(cleanApp) { return 45 }
        }
        return 0
    }

    private static func rootDomain(_ host: String) -> String {
        let parts = host.split(separator: ".")
        guard parts.count >= 2 else { return host }
        // Handle country second-level domains like .com.pe, .co.uk
        if parts.count >= 3, parts[parts.count - 1].count == 2, parts[parts.count - 2].count <= 3 {
            return parts.suffix(3).joined(separator: ".")
        }
        return parts.suffix(2).joined(separator: ".")
    }
}

// MARK: - Defense-in-Depth CryptoKit Vault Persistence (CTV2: HKDF-SHA256 + Per-Save Salt + AES-GCM-256 + AAD)

public enum VaultCryptoStore {
    private static let keychainService = "com.cleantrash.mac.vault"
    private static let keychainAccount = "master-key-v1"
    private static let v2Magic = Data("CTV2".utf8)
    private static let backupMagic = Data("CTB1".utf8)
    private static let v2Info = Data("CleanTrashVault-v2-AESGCM256".utf8)

    /// Encrypts `[VaultItem]` with hardened `CTV2` envelope:
    /// `4B Magic ("CTV2") || 32B Random Salt || AES-GCM-256(HKDF-SHA256(masterKey, salt), AAD: Magic || Salt)`.
    public static func encrypt(_ items: [VaultItem], key: SymmetricKey) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let plaintext = try encoder.encode(items)

        let salt = randomBytes(count: 32)
        var header = Data()
        header.append(v2Magic)
        header.append(salt)

        let derived = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: key,
            salt: salt,
            info: v2Info,
            outputByteCount: 32
        )
        let sealed = try AES.GCM.seal(plaintext, using: derived, authenticating: header)
        guard let combined = sealed.combined else {
            throw CocoaError(.coderInvalidValue)
        }

        var envelope = header
        envelope.append(combined)
        return envelope
    }

    /// Decrypts both hardened `CTV2` envelopes (verifying AAD integrity) and legacy `v1` AES-GCM payloads seamlessly.
    public static func decrypt(_ data: Data, key: SymmetricKey) throws -> [VaultItem] {
        let plaintext: Data
        if data.count > 36, data.prefix(4) == v2Magic {
            let header = data.prefix(36)
            let salt = data[4..<36]
            let cipher = data.dropFirst(36)
            let derived = HKDF<SHA256>.deriveKey(
                inputKeyMaterial: key,
                salt: salt,
                info: v2Info,
                outputByteCount: 32
            )
            let box = try AES.GCM.SealedBox(combined: cipher)
            plaintext = try AES.GCM.open(box, using: derived, authenticating: header)
        } else {
            // Legacy v1 compatibility (automatically upgraded to CTV2 on next save)
            let box = try AES.GCM.SealedBox(combined: data)
            plaintext = try AES.GCM.open(box, using: key)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([VaultItem].self, from: plaintext)
    }

    /// Creates a portable passphrase-encrypted backup (`.ctvault`) hardened with 120,000 SHA-256 key-stretching rounds
    /// + HKDF + AES-GCM-256 with authenticated header so stolen files cannot be brute-forced or tampered with.
    public static func encryptBackup(_ items: [VaultItem], passphrase: String) throws -> Data {
        let salt = randomBytes(count: 32)
        var header = Data()
        header.append(backupMagic)
        header.append(salt)

        let key = stretchPassphrase(passphrase, salt: salt, rounds: 120_000)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let plaintext = try encoder.encode(items)
        let sealed = try AES.GCM.seal(plaintext, using: key, authenticating: header)
        guard let combined = sealed.combined else { throw CocoaError(.coderInvalidValue) }

        var out = header
        out.append(combined)
        return out
    }

    public static func decryptBackup(_ data: Data, passphrase: String) throws -> [VaultItem] {
        guard data.count > 36, data.prefix(4) == backupMagic else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let header = data.prefix(36)
        let salt = data[4..<36]
        let cipher = data.dropFirst(36)
        let key = stretchPassphrase(passphrase, salt: salt, rounds: 120_000)
        let box = try AES.GCM.SealedBox(combined: cipher)
        let plaintext = try AES.GCM.open(box, using: key, authenticating: header)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([VaultItem].self, from: plaintext)
    }

    private static func stretchPassphrase(_ passphrase: String, salt: Data, rounds: Int) -> SymmetricKey {
        var digest = Data(SHA256.hash(data: Data(passphrase.utf8) + salt))
        for _ in 0..<rounds {
            var next = Data(capacity: digest.count + salt.count)
            next.append(digest)
            next.append(salt)
            digest = Data(SHA256.hash(data: next))
        }
        return SymmetricKey(data: digest)
    }

    private static func randomBytes(count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes)
    }

    /// Loads or creates the 256-bit AES master key stored securely in macOS Keychain.
    public static func loadOrCreateKeychainKey() -> SymmetricKey {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
           let keyData = result as? Data, keyData.count == 32 {
            return SymmetricKey(data: keyData)
        }

        let fresh = SymmetricKey(size: .bits256)
        let keyData = fresh.withUnsafeBytes { Data($0) }
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecValueData as String: keyData,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        SecItemAdd(add as CFDictionary, nil)
        return fresh
    }

    public static func save(_ items: [VaultItem], to url: URL) throws {
        let key = loadOrCreateKeychainKey()
        let ciphertext = try encrypt(items, key: key)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try ciphertext.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public static func load(from url: URL) throws -> [VaultItem] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let key = loadOrCreateKeychainKey()
        let data = try Data(contentsOf: url)
        let items = try decrypt(data, key: key)
        // Silently migrate legacy v1 files to hardened CTV2 envelope on load
        if data.prefix(4) != v2Magic {
            try? save(items, to: url)
        }
        return items
    }
}
