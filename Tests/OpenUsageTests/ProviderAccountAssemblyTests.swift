import CommonCrypto
import CryptoKit
import Foundation
import XCTest
@testable import OpenUsage

/// The launch account pass end to end: observer outcomes → account registry records → the per-card
/// identity map consumed by the snapshot cache stamp and the bare-id resolver.
@MainActor
final class ProviderAccountAssemblyTests: XCTestCase {
    private func makeScratchDefaults() -> UserDefaults {
        let suiteName = "OpenUsageTests.ProviderAccountAssembly.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return defaults
    }

    func testResolvedFamiliesFeedIdentityKeysAndTheRegistry() async throws {
        let defaults = makeScratchDefaults()
        let store = ProviderAccountsStore(defaults: defaults)
        let observer = DefaultAccountObserver(
            environment: FakeEnvironment([:]),
            files: FakeFiles([
                // Claude resolved at the default home; Codex has credentials that name no account.
                "/Users/dev/.claude.json": #"{"oauthAccount": {"accountUuid": "ACCT-1", "emailAddress": "dev@example.com"}}"#,
                "/Users/dev/.codex/auth.json": #"{"tokens": {"access_token": "at-1"}}"#,
            ]),
            keychain: FakeKeychain(nil),
            homeDirectory: { URL(fileURLWithPath: "/Users/dev") }
        )

        let assembly = await ProviderAccountAssembly.make(observer: observer, accountsStore: store)

        XCTAssertEqual(assembly.identityKeysByCard, ["claude": "acct-1"])
        // The registry recorded the resolved account under the bare id, holding the default badge.
        let record = try XCTUnwrap(store.defaultBadgeHolder(family: "claude"))
        XCTAssertEqual(record.id, "claude")
        XCTAssertEqual(record.label, "dev@example.com")
        XCTAssertEqual(record.sources.map(\.kind), [.defaultHome])
        // An unresolved family claims no account: no record, no identity key.
        XCTAssertNil(store.defaultBadgeHolder(family: "codex"))
    }

    /// A family whose home facts aren't readable this launch (first Finder/Dock launch racing a
    /// slow shell) is left out of the pass entirely: not observed, not reconciled — while a family
    /// whose home override is already in the process environment still resolves.
    func testFamiliesOutsideThePassAreNeitherObservedNorReconciled() async {
        let defaults = makeScratchDefaults()
        let store = ProviderAccountsStore(defaults: defaults)
        let observer = DefaultAccountObserver(
            environment: FakeEnvironment([:]),
            files: FakeFiles([
                "/Users/dev/.claude.json": #"{"oauthAccount": {"accountUuid": "ACCT-1"}}"#,
                "/Users/dev/.codex/auth.json": #"{"tokens": {"access_token": "at-1", "account_id": "CODEX-1"}}"#,
            ]),
            keychain: FakeKeychain(nil),
            homeDirectory: { URL(fileURLWithPath: "/Users/dev") }
        )

        let assembly = await ProviderAccountAssembly.make(observer: observer, accountsStore: store, families: ["codex"])

        XCTAssertEqual(assembly.identityKeysByCard, ["codex": "codex-1"])
        XCTAssertNil(store.defaultBadgeHolder(family: "claude"), "an out-of-pass family must not be reconciled")
    }

    /// Regression: previously only scanned org UUIDs under `lastKnownAccountUUID`.
    /// A second Desktop account's org UUID (in a sibling directory) was never discovered.
    func testMultipleDesktopAccountsAreEachDiscovered() async throws {
        let defaults = makeScratchDefaults()
        let store = ProviderAccountsStore(defaults: defaults)
        let home = URL(fileURLWithPath: "/Users/dev")

        // The work account is the CLI login (team seat — identity key contains "|").
        let workAccountUUID = "11111111-0000-0000-0000-000000000001"
        let workOrgUUID     = "22222222-0000-0000-0000-000000000002"
        // The personal account lives in Desktop session dirs only.
        let personalAccountUUID = "33333333-0000-0000-0000-000000000003"
        let personalOrgUUID     = "44444444-0000-0000-0000-000000000004"
        let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"  // production client

        let password = "fixture-password"
        let key = try ClaudeDesktopAuthStore.deriveKey(password: password)
        let futureMs = (Date().timeIntervalSince1970 + 3600) * 1000

        // Build a legacy token cache with both orgs so load(organization:) finds each.
        let workKey     = "\(clientID):\(workOrgUUID):https://api.anthropic.com:user:profile user:inference"
        let personalKey = "\(clientID):\(personalOrgUUID):https://api.anthropic.com:user:profile user:inference"
        let v2: [String: Any] = [
            workKey:     ["token": "work-tok",     "expiresAt": futureMs, "subscriptionType": "team"],
            personalKey: ["token": "personal-tok", "expiresAt": futureMs, "subscriptionType": "pro"],
        ]
        let v2Data    = try JSONSerialization.data(withJSONObject: v2)
        let encrypted = try encryptDesktopData(v2Data, key: key)
        let config: [String: Any] = [
            "oauth:tokenCacheV2": encrypted.base64EncodedString(),
            "lastKnownAccountUuid": workAccountUUID,
        ]
        let configJSON = String(decoding: try JSONSerialization.data(withJSONObject: config), as: UTF8.self)

        // Work org cookie (used by loadActiveOrganization to find the active org).
        let cookieHost = ".claude.ai"
        let cookiePlain = Data(SHA256.hash(data: Data(cookieHost.utf8))) + Data(workOrgUUID.utf8)
        let encryptedCookie = try encryptDesktopData(cookiePlain, key: key)

        let supportDir = home.appendingPathComponent("Library/Application Support/Claude")
        let configPath = supportDir.appendingPathComponent("config.json").path
        let cookiesPath = supportDir.appendingPathComponent("Cookies").path
        let files = FakeFiles([configPath: configJSON, cookiesPath: "sqlite-placeholder"])
        let sqlite = FakeClaudeDesktopSQLite(value: "encrypted:\(encryptedCookie.map { String(format: "%02X", $0) }.joined())")
        let keyReader = FakeClaudeDesktopKeyReader(password: password, requiresInteraction: false)
        let desktop = ClaudeDesktopAuthStore(
            files: files, sqlite: sqlite, keyReader: keyReader,
            homeDirectory: { home }, now: Date.init
        )

        let observer = DefaultAccountObserver(
            environment: FakeEnvironment(["CLAUDE_CONFIG_DIR": "/Users/dev/.claude"]),
            files: FakeFiles([
                "/Users/dev/.claude.json": """
                {"oauthAccount": {"accountUuid": "\(workAccountUUID)", "organizationUuid": "\(workOrgUUID)"}}
                """,
            ]),
            keychain: FakeKeychain(nil),
            homeDirectory: { home }
        )

        // Simulate: claude-code-sessions/<accountUUID>/<orgUUID>/
        let sessionDirStr = supportDir.appendingPathComponent("claude-code-sessions").path
        let assembly = await ProviderAccountAssembly.make(
            observer: observer,
            accountsStore: store,
            desktop: desktop,
            listDesktopOrganizationDirectories: { url in
                switch url.path {
                case sessionDirStr:
                    return [workAccountUUID, personalAccountUUID]
                case sessionDirStr + "/" + workAccountUUID:
                    return [workOrgUUID]
                case sessionDirStr + "/" + personalAccountUUID:
                    return [personalOrgUUID]
                default:
                    return []
                }
            }
        )

        // Expect two Claude cards: work (CLI) and personal (Desktop).
        XCTAssertEqual(assembly.claudeCards.count, 2, "both accounts should be discovered")
        let workCard     = try XCTUnwrap(assembly.claudeCards.first { $0.organizationID == workOrgUUID.lowercased() })
        let personalCard = try XCTUnwrap(assembly.claudeCards.first { $0.organizationID == personalOrgUUID.lowercased() })
        XCTAssertFalse(workCard.usesDesktopCredentials, "work card comes from CLI login")
        XCTAssertTrue(personalCard.usesDesktopCredentials, "personal card comes from Desktop session")
        XCTAssert(personalCard.displayName.contains("Personal"), "personal Pro account should be labelled Personal, got: \(personalCard.displayName)")
    }

    // AES-128-CBC with a static IV (mirrors ClaudeDesktopAuthStore.decrypt).
    private func encryptDesktopData(_ plaintext: Data, key: Data) throws -> Data {
        let iv = Data(repeating: 0x20, count: kCCBlockSizeAES128)
        var output = Data(count: plaintext.count + kCCBlockSizeAES128)
        var outputLength = 0
        let capacity = output.count
        let status = output.withUnsafeMutableBytes { ob in
            plaintext.withUnsafeBytes { pb in
                key.withUnsafeBytes { kb in
                    iv.withUnsafeBytes { ib in
                        CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES),
                                CCOptions(kCCOptionPKCS7Padding),
                                kb.baseAddress, key.count, ib.baseAddress,
                                pb.baseAddress, plaintext.count,
                                ob.baseAddress, capacity, &outputLength)
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw ClaudeDesktopCredentialError.decryptionFailed(status) }
        output.count = outputLength
        return Data("v10".utf8) + output
    }

    func testNothingObservedLeavesRegistryAndKeysEmpty() async {
        let defaults = makeScratchDefaults()
        let store = ProviderAccountsStore(defaults: defaults)
        let observer = DefaultAccountObserver(
            environment: FakeEnvironment([:]),
            files: FakeFiles([:]),
            keychain: FakeKeychain(nil),
            homeDirectory: { URL(fileURLWithPath: "/Users/dev") }
        )

        let assembly = await ProviderAccountAssembly.make(observer: observer, accountsStore: store)

        XCTAssertTrue(assembly.identityKeysByCard.isEmpty)
        XCTAssertTrue(store.records.isEmpty)
        XCTAssertNil(defaults.data(forKey: ProviderAccountsStore.storageKey), "no observations, no write")
    }
}
