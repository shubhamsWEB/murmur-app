import Foundation

/// What may go to Claude or OpenAI when the user reads with them, decided on this Mac before anything is sent:
///
/// - Some work never goes at all, and is read by the model on this Mac instead: banking, payments, investing, tax,
///   government IDs, health, insurance, passwords and account recovery, by the site, the app, the window's title, or
///   an ID number in the text (Aadhaar, PAN, SSN, IBAN, passport).
/// - What does go is scrubbed first, beyond the secrets taken out of everything (`BrainModel.redact`): email addresses,
///   phone numbers, long account-like numbers, booking references, and what an address's query carries.
public enum CloudPrivacy {
    /// Sites whose pages are about money, health, identity or access: never sent.
    static let sensitiveSites = [
        // Banks and payments
        "hdfcbank", "icicibank", "onlinesbi", "sbi.co.in", "axisbank", "kotak", "yesbank", "idfcfirstbank", "indusind",
        "pnbindia", "bankofbaroda", "canarabank", "unionbankofindia", "federalbank", "aubank", "rblbank", "netbanking",
        "paypal.com", "wise.com", "revolut", "paytm", "phonepe", "pay.google", "razorpay.com/dashboard", "dashboard.stripe",
        "chase.com", "bankofamerica", "wellsfargo", "citi.com", "hsbc", "barclays", "americanexpress", "amex",
        "creditkarma", "cred.club", "cibil",
        // Investing and crypto
        "zerodha", "kite.", "groww", "upstox", "angelone", "icicidirect", "hdfcsec", "smallcase", "coin.zerodha",
        "camsonline", "kfintech", "nsdl", "cdslindia", "robinhood", "fidelity", "vanguard", "schwab", "coinbase",
        "binance", "wazirx", "coindcx", "kraken",
        // Tax, government and identity
        "incometax.gov", "gst.gov", "uidai", "myaadhaar", "digilocker", "passportindia", "epfindia", "unifiedportal",
        "irs.gov", "ssa.gov", "gov.uk/government", "parivahan", "nsdl.co.in", "tin-nsdl", "eportal.incometax",
        // Health and insurance
        "practo", "apollo247", "1mg.com", "pharmeasy", "netmeds", "mfine", "healthifyme", "mychart", "patient",
        "labcorp", "questdiagnostics", "thyrocare", "lalpathlabs", "metropolisindia", "policybazaar", "starhealth",
        "hdfcergo", "icicilombard", "acko", "digit insurance", "nivabupa", "careinsurance",
        // Passwords and accounts
        "accounts.google.com", "myaccount.google", "appleid.apple", "account.microsoft", "login.", "signin.", "auth.",
        "1password", "bitwarden", "lastpass", "dashlane",
    ]

    /// Apps whose windows are never sent.
    static let sensitiveApps: Set<String> = ["Health", "Keychain Access", "Passwords", "1Password", "Bitwarden", "Wallet",
                                             "Banking", "Stocks", "Zerodha Kite", "Groww", "Authenticator", "Authy"]

    /// Words in a window's title that say it's about money, health, identity or access.
    static let sensitiveTitles = [
        "net banking", "netbanking", "internet banking", "bank statement", "account statement", "credit card statement",
        "payslip", "pay slip", "salary slip", "form 16", "form-16", "income tax", "tax return", "itr-", " itr ", "26as",
        "aadhaar", "aadhar", "pan card", "passport", "driving licence", "driver's license", "voter id", "social security",
        "medical report", "lab report", "test report", "prescription", "diagnosis", "discharge summary", "health record",
        "insurance policy", "claim status", "password reset", "reset your password", "forgot password", "recovery code",
        "two-factor", "2fa", "verification code", "one-time password", "security code", "demat", "portfolio", "holdings",
        "mutual fund", "loan account", "emi schedule", "credit score", "cibil",
    ]

    /// ID numbers that mean a window holds someone's identity or accounts.
    static let identityPatterns: [NSRegularExpression] = [
        #"\b\d{4}[ -]\d{4}[ -]\d{4}\b"#,                     // Aadhaar
        #"\b[A-Z]{5}\d{4}[A-Z]\b"#,                          // PAN
        #"\b\d{3}-\d{2}-\d{4}\b"#,                           // SSN
        #"\b[A-Z]{2}\d{2}[A-Z0-9]{11,30}\b"#,                // IBAN
        #"(?i)\b(?:ifsc|swift|routing)\b[^\n]{0,20}\b[A-Z0-9]{8,11}\b"#,   // a bank's code beside an account
        #"(?i)\b(?:a/?c|account)\s*(?:no\.?|number|#)\s*[:\-]?\s*[X*\d]{6,}"#,
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    /// Why a window must not be sent, or nil when it may be.
    public static func sensitive(_ window: Journal.Snapshot) -> String? {
        let place = ((window.url ?? "") + " " + window.domain).lowercased()
        if let site = sensitiveSites.first(where: { !place.trimmingCharacters(in: .whitespaces).isEmpty && place.contains($0) }) {
            return "a sensitive site (\(site))"
        }
        if sensitiveApps.contains(window.app) { return "a sensitive app (\(window.app))" }
        let title = " " + window.title.lowercased() + " "
        if let word = sensitiveTitles.first(where: title.contains) { return "about \(word.trimmingCharacters(in: .whitespaces))" }
        let text = window.title + "\n" + window.text
        for pattern in identityPatterns where pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil {
            return "an ID or account number"
        }
        return nil
    }

    /// Why an episode stays on this Mac (the first window that must), or nil when it may be sent.
    public static func sensitive(_ windows: [Journal.Snapshot]) -> String? {
        windows.lazy.compactMap(sensitive).first
    }

    static let scrubbing: [(NSRegularExpression, String)] = [
        (#"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#, "[email]"),
        // Phone and account numbers: ten digits or more (a date or a time has fewer).
        (#"(?<![\w.\:/-])(?:\+\d{1,3}[ -]?)?(?:\d[ -]?){9,15}\d(?![\w\:/-]|\.\d)"#, "[number]"),
        (#"(?i)\b(pnr|booking ref(?:erence)?|booking id|confirmation (?:no\.?|number|code)|reference)\b([\s\:#|-]{0,5})[A-Z0-9]{5,10}\b"#, "$1$2[reference]"),
        (#"(https?://[^\s?#]+)\?[^\s]*"#, "$1"),
    ].compactMap { pattern, template in (try? NSRegularExpression(pattern: pattern)).map { ($0, template) } }

    /// The text as it may leave the Mac: secrets, email addresses, phone and account numbers, booking references and
    /// addresses' queries taken out.
    public static func scrub(_ text: String) -> String {
        var result = BrainModel.redact(text)
        for (pattern, template) in scrubbing {
            result = pattern.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: template)
        }
        return result
    }
}
