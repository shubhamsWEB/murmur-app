import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import AgentKit

/// Connected apps: signing in the way MCP clients do (no keys), and calling an app's tools.
struct ConnectorPieceTests {
    @Test func sha256MatchesKnownValues() {
        // FIPS 180-2 test vectors, and the PKCE example in RFC 7636 (appendix B).
        #expect(SHA256.hash(Data("abc".utf8)).map { String(format: "%02x", $0) }.joined()
            == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(SHA256.hash(Data()).map { String(format: "%02x", $0) }.joined()
            == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        #expect(SHA256.base64URL(Data("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk".utf8))
            == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        let long = Data(String(repeating: "a", count: 1000).utf8)
        #expect(SHA256.hash(long).map { String(format: "%02x", $0) }.joined()
            == "41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3")
    }

    @Test func readsTheAuthHeaderAndWellKnownPlaces() {
        #expect(MCPAuth.parameter("resource_metadata", in: #"Bearer realm="x", resource_metadata="https://a.b/.well-known/x""#)
            == "https://a.b/.well-known/x")
        #expect(MCPAuth.parameter("error", in: "Bearer error=invalid_token, scope=read") == "invalid_token")
        #expect(MCPAuth.wellKnown("oauth-protected-resource", for: URL(string: "https://mcp.linear.app/mcp")!).map(\.absoluteString)
            == ["https://mcp.linear.app/.well-known/oauth-protected-resource/mcp",
                "https://mcp.linear.app/.well-known/oauth-protected-resource"])
        #expect(MCPAuth.formEncoded(["b": "x y", "a": "1&2"]) == "a=1%262&b=x%20y")
    }

    @Test func readsEventStreams() {
        let stream = "event: message\r\ndata: {\"id\":1}\r\n\r\n: keep-alive\n\ndata: {\"a\":\ndata: 2}\n\n"
        #expect(MCPClient.events(Data(stream.utf8)).map { String(decoding: $0, as: UTF8.self) } == [#"{"id":1}"#, "{\"a\":\n2}"])
    }

    @Test func toolResultsAsText() {
        let result: [String: Any] = ["content": [["type": "text", "text": "Two issues"],
                                                 ["type": "resource", "resource": ["uri": "x", "text": "ENG-1 Fix login"]],
                                                 ["type": "image", "data": "..."]]]
        #expect(MCPClient.text(of: result) == "Two issues\nENG-1 Fix login\n[image]")
    }

    @Test func customAddresses() {
        #expect(Connector.custom("mcp.sentry.dev/mcp")?.url.absoluteString == "https://mcp.sentry.dev/mcp")
        #expect(Connector.custom("mcp.sentry.dev/mcp")?.name == "Sentry")
        #expect(Connector.custom("http://insecure.example.com") == nil)
        #expect(Connector.custom("nonsense") == nil)
    }
}

final class MemoryVault: ConnectorVault, @unchecked Sendable {
    private var values: [String: String] = [:]
    private let lock = NSLock()
    func load(_ account: String) -> String? { lock.lock(); defer { lock.unlock() }; return values[account] }
    func save(_ account: String, _ value: String?) { lock.lock(); values[account] = value; lock.unlock() }
}

/// The whole path against a stand-in server (scripts/mock-mcp.py): set MURMUR_MOCK_MCP to its address to run it.
struct ConnectorFlowTests {
    static let server = ProcessInfo.processInfo.environment["MURMUR_MOCK_MCP"]

    @Test(.enabled(if: server != nil)) func connectsCallsAndStaysSignedIn() async throws {
        let base = Self.server!
        let app = Connector(id: "mock", name: "Mock", url: URL(string: "\(base)/mcp")!, about: "")
        let vault = MemoryVault()
        // "The browser": follows the sign-in page's redirect back to Murmur's loopback address.
        try await ConnectorLink.connect(app, vault: vault, timeout: 20) { url in
            _ = try? await URLSession.shared.data(from: url)
        }
        #expect(ConnectorLink.isConnected(app, vault: vault))
        let client = try #require(ConnectorLink.client(app, vault: vault))
        let tools = try await client.tools()
        #expect(tools.map(\.name) == ["list_my_issues", "create_issue"])
        #expect(tools[0].readOnly && !tools[1].readOnly)
        #expect(tools[1].arguments == "title (string, required)")
        let result = try await client.call("create_issue", arguments: #"{"title": "Fix login"}"#)
        #expect(result.text == #"called create_issue with {"title": "Fix login"}"# && !result.isError)

        // The token runs out: Murmur refreshes it and carries on.
        let before = vault.load(ConnectorLink.tokensAccount("mock"))
        _ = try await URLSession.shared.data(from: URL(string: "\(base)/control/expire")!)
        let again = try await client.call("list_my_issues", arguments: #"{"limit": 2}"#)
        #expect(again.text == #"called list_my_issues with {"limit": 2}"#)
        #expect(vault.load(ConnectorLink.tokensAccount("mock")) != before)

        // Connecting again reuses Murmur's registration.
        let registered = vault.load(ConnectorLink.clientAccount("mock"))
        try await ConnectorLink.connect(app, vault: vault, timeout: 20) { url in _ = try? await URLSession.shared.data(from: url) }
        #expect(vault.load(ConnectorLink.clientAccount("mock")) == registered)

        ConnectorLink.disconnect(app, vault: vault)
        #expect(ConnectorLink.client(app, vault: vault) == nil)
    }
}
