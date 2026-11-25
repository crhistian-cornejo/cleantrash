import CleanTrashCore
import CryptoKit
import Foundation
import Testing

@Suite("Password Vault & NordPass Migration")
struct VaultEngineTests {
    @Test("NordPass CSV parser handles quotes, multiline notes, and folder inference")
    func nordPassCSVImport() {
        let csv = """
        name,url,username,password,note,cardholdername,cardnumber,cvc,expirydate,zipcode,folder
        GitHub,github.com,dev@example.com,Str0ng!Pass#2026,"Line 1
        Line 2, with comma",,,,,,
        "My Bank",https://www.bcp.com.pe,user123,123456,"PIN note",,,,,,
        ,https://vercel.com,team@example.com,AnotherStrong!99,,,,,,,
        """

        let items = VaultCSVCodec.importCSV(csv)
        #expect(items.count == 3)
        #expect(items[0].title == "GitHub")
        #expect(items[0].url == "https://github.com")
        #expect(items[0].folder == "Desarrollo")
        #expect(items[0].notes.contains("Line 2, with comma"))
        #expect(items[1].folder == "Finanzas")
        #expect(items[1].strength == .weak)
        #expect(items[2].title == "Vercel")
        #expect(items[2].folder == "Desarrollo")
    }

    @Test("Hygiene auditor detects duplicates, reused, and weak passwords and cleans them")
    func auditAndClean() {
        let items = [
            VaultItem(title: "GitHub", url: "https://github.com", username: "a@b.com", password: "Weak1", folder: "General"),
            VaultItem(title: "GitHub copy", url: "github.com", username: "a@b.com", password: "Weak1", notes: "SSH backup", folder: "General"),
            VaultItem(title: "Stripe", url: "https://stripe.com", username: "a@b.com", password: "Weak1", folder: "General"),
            VaultItem(title: "Apple", url: "https://apple.com", username: "a@b.com", password: VaultHygieneAuditor.generateStrongPassword(length: 20), folder: "General")
        ]

        let report = VaultHygieneAuditor.audit(items)
        #expect(report.exactDuplicateIDs.count == 1)
        #expect(report.weakPasswordIDs.count == 3)
        #expect(report.reusedPasswordIDs.count == 3)

        let cleaned = VaultHygieneAuditor.cleanAndOrganize(items)
        #expect(cleaned.removedDuplicates == 1)
        #expect(cleaned.items.count == 3)
        // Notes from the removed duplicate were merged onto the surviving entry
        let gh = cleaned.items.first { $0.normalizedDomain == "github.com" }
        #expect(gh?.notes == "SSH backup")
        #expect(gh?.folder == "Desarrollo")
    }

    @Test("Apple Passwords CSV export round-trips cleanly")
    func appleExportRoundTrip() {
        let original = [
            VaultItem(title: "Linear", url: "https://linear.app", username: "me@co.dev", password: "A1!b2@C3#d4$E5%", notes: "Team workspace", folder: "Desarrollo", otpAuth: "otpauth://totp/Linear")
        ]
        let csv = VaultCSVCodec.exportApplePasswordsCSV(original)
        #expect(csv.hasPrefix("Title,URL,Username,Password,Notes,OTPAuth\n"))
        let reimported = VaultCSVCodec.importCSV(csv)
        #expect(reimported.count == 1)
        #expect(reimported[0].title == "Linear")
        #expect(reimported[0].password == "A1!b2@C3#d4$E5%")
        #expect(reimported[0].otpAuth == "otpauth://totp/Linear")
    }

    @Test("NordPass 24-column CRLF CSV export parses cleanly without Swift grapheme-cluster loss")
    func nordPassCRLFImport() {
        let crlfCSV = "name,url,additional_urls,username,password,note,cardholdername,cardnumber,cvc,pin,expirydate,zipcode,folder,shared_folder,full_name,phone_number,email,address1,address2,city,country,state,type,custom_fields\r\n"
            + "GitHub,https://github.com,,dev@example.com,Str0ng!Pass#2026,,,,,,,,Desarrollo,,,,,,,,,,password,\r\n"
            + "Visa,,,,,,John,4111,123,0000,12/28,,,,,,,,,,,,credit_card,\r\n"
            + "Stripe,stripe.com,dashboard.stripe.com,billing@co.dev,An0ther!Pass99,,,,,,,,Work,,,,,,,,,,password,\r\n"

        let items = VaultCSVCodec.importCSV(crlfCSV)
        #expect(items.count == 2)
        #expect(items[0].title == "GitHub")
        #expect(items[0].folder == "Desarrollo")
        #expect(items[1].title == "Stripe")
        #expect(items[1].notes.contains("dashboard.stripe.com"))
    }

    @Test("CryptoKit AES-GCM 256-bit encrypt and decrypt preserves vault entries")
    func cryptoRoundTrip() throws {
        let key = SymmetricKey(size: .bits256)
        let fixedDate = Date(timeIntervalSince1970: 1_764_000_000)
        let original = [
            VaultItem(
                title: "Cloudflare",
                url: "https://dash.cloudflare.com",
                username: "ops@acme.io",
                password: "SuperSecret!2026#99",
                folder: "Desarrollo",
                createdAt: fixedDate,
                updatedAt: fixedDate
            )
        ]
        let encrypted = try VaultCryptoStore.encrypt(original, key: key)
        #expect(encrypted.prefix(4) == Data("CTV2".utf8))
        #expect(encrypted != Data(original[0].password.utf8))
        let decrypted = try VaultCryptoStore.decrypt(encrypted, key: key)
        #expect(decrypted == original)

        // Tampering with even 1 byte of the authenticated salt/header must fail AAD verification
        var tampered = encrypted
        tampered[10] ^= 0xFF
        #expect(throws: (any Error).self) {
            _ = try VaultCryptoStore.decrypt(tampered, key: key)
        }
    }

    @Test("Passphrase encrypted backup (CTB1) protects against wrong passphrase and context matching ranks exact sites")
    func backupAndBrowserMatch() throws {
        let fixedDate = Date(timeIntervalSince1970: 1_764_000_000)
        let items = [
            VaultItem(title: "GitHub", url: "https://github.com", username: "dev@co.io", password: "Strong!Password99", folder: "Desarrollo", createdAt: fixedDate, updatedAt: fixedDate),
            VaultItem(title: "Uber", url: "https://auth.uber.com", username: "me@co.io", password: "Strong!Password88", folder: "Compras", createdAt: fixedDate, updatedAt: fixedDate)
        ]

        let backup = try VaultCryptoStore.encryptBackup(items, passphrase: "mi-frase-maestra-segura")
        #expect(backup.prefix(4) == Data("CTB1".utf8))
        let restored = try VaultCryptoStore.decryptBackup(backup, passphrase: "mi-frase-maestra-segura")
        #expect(restored == items)
        #expect(throws: (any Error).self) {
            _ = try VaultCryptoStore.decryptBackup(backup, passphrase: "frase-incorrecta")
        }

        // Context matching for active Chrome/Safari URL
        #expect(VaultHygieneAuditor.matchScore(item: items[0], activeHost: "github.com", activeAppName: "Google Chrome") == 100)
        #expect(VaultHygieneAuditor.matchScore(item: items[1], activeHost: "m.uber.com", activeAppName: "Safari") >= 85)
        #expect(VaultHygieneAuditor.matchScore(item: items[0], activeHost: "uber.com", activeAppName: "Safari") == 0)
    }
}
