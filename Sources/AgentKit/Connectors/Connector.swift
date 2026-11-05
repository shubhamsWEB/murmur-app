import Foundation

/// An app Murmur can connect to through its MCP server: you click Connect, sign in on the app's own page, and Murmur
/// can use the app in commands and learn from it for its memory. No keys to paste.
public struct Connector: Sendable, Identifiable, Equatable, Codable {
    public let id: String
    public let name: String
    public let url: URL
    public let about: String
    /// What it gives Murmur's memory: tools to call, newest first. Empty for an app added by its address (its tools
    /// work in commands; the memory doesn't guess what to read).
    public let teaches: [Lesson]
    public let custom: Bool

    public struct Lesson: Sendable, Equatable, Codable {
        public let key: String
        public let title: String
        /// The first of these the app has.
        public let tools: [String]
        /// JSON object, as text.
        public let arguments: String
    }

    public init(id: String, name: String, url: URL, about: String, teaches: [Lesson] = [], custom: Bool = false) {
        self.id = id
        self.name = name
        self.url = url
        self.about = about
        self.teaches = teaches
        self.custom = custom
    }

    /// The apps whose MCP servers let Murmur register itself (dynamic client registration): one click each.
    public static let catalog: [Connector] = [
        Connector(id: "linear", name: "Linear", url: URL(string: "https://mcp.linear.app/mcp")!,
                  about: "Your issues, projects and teams. Ask about them, or create and update issues by voice.",
                  teaches: [
                      Lesson(key: "issues", title: "Your Linear issues", tools: ["list_my_issues", "list_issues"],
                             arguments: #"{"assignee": "me", "limit": 30, "orderBy": "updatedAt"}"#),
                      Lesson(key: "projects", title: "Linear projects", tools: ["list_projects"],
                             arguments: #"{"limit": 20}"#),
                  ]),
        Connector(id: "notion", name: "Notion", url: URL(string: "https://mcp.notion.com/mcp")!,
                  about: "Your pages and databases. Find and read them, or add pages by voice.",
                  teaches: [
                      Lesson(key: "recent", title: "Recent Notion pages", tools: ["notion-search", "search"],
                             arguments: #"{"query": "meeting notes projects plans", "query_type": "internal"}"#),
                  ]),
        Connector(id: "atlassian", name: "Jira and Confluence", url: URL(string: "https://mcp.atlassian.com/v1/mcp")!,
                  about: "Atlassian: your Jira issues and Confluence pages.",
                  teaches: [
                      Lesson(key: "work", title: "Your Jira work", tools: ["search"],
                             arguments: #"{"query": "issues assigned to me"}"#),
                  ]),
    ]

    /// An app added by its MCP server's address.
    public static func custom(_ address: String) -> Connector? {
        var text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.contains("://") { text = "https://" + text }
        guard let url = URL(string: text), url.scheme == "https", let host = url.host, host.contains(".") else { return nil }
        let name = host.split(separator: ".").filter { !["mcp", "www", "api", "com", "app", "io", "dev", "ai"].contains($0) }
            .first.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? host
        return Connector(id: "custom:" + host + url.path, name: name, url: url, about: url.absoluteString, custom: true)
    }
}

/// Where sign-ins are kept: the Keychain in the app, a dictionary in tests.
public protocol ConnectorVault: Sendable {
    func load(_ account: String) -> String?
    func save(_ account: String, _ value: String?)
}

/// Connecting, staying signed in, and signing out.
public enum ConnectorLink {
    static func clientAccount(_ id: String) -> String { "mcp.client.\(id)" }
    static func tokensAccount(_ id: String) -> String { "mcp.tokens.\(id)" }

    /// Signs in: registers Murmur with the app when it's new, opens its sign-in page (`open`), and waits for the
    /// browser to come back. Throws what went wrong, in words for the user.
    public static func connect(_ connector: Connector, vault: ConnectorVault, timeout: TimeInterval = 300,
                               open: @Sendable (URL) async -> Void) async throws {
        let server = try await MCPAuth.discover(connector.url)
        var saved = vault.load(clientAccount(connector.id)).flatMap(decode(MCPAuth.Client.self))
        if saved?.server.authorizationEndpoint != server.authorizationEndpoint
            || saved?.server.tokenEndpoint != server.tokenEndpoint { saved = nil }
        // The same port as when Murmur registered (the app knows that address); a new one, and a new registration,
        // when it's taken.
        let port = saved.flatMap { URL(string: $0.redirect)?.port }.map(UInt16.init) ?? 0
        guard let back = LoopbackRedirect(port: port) ?? LoopbackRedirect() else {
            throw MCPAuth.Failure.denied("Murmur couldn't listen for the sign-in on this Mac")
        }
        var client: MCPAuth.Client
        if let saved, saved.redirect == back.redirect {
            client = saved
            client.server = server
        } else {
            client = try await MCPAuth.register(server, redirect: back.redirect)
            vault.save(clientAccount(connector.id), encode(client))
        }
        let attempt = MCPAuth.begin(client)
        // Listening before the page opens: the browser may come back before `open` returns.
        async let returned = back.wait(timeout: timeout)
        await open(attempt.url)
        guard let callback = await returned else {
            throw MCPAuth.Failure.denied("the sign-in page wasn't finished")
        }
        let code = try MCPAuth.code(from: callback, for: attempt)
        let tokens = try await MCPAuth.exchange(code, attempt: attempt, client: client)
        vault.save(tokensAccount(connector.id), encode(tokens))
    }

    public static func isConnected(_ connector: Connector, vault: ConnectorVault) -> Bool {
        vault.load(tokensAccount(connector.id)) != nil
    }

    public static func disconnect(_ connector: Connector, vault: ConnectorVault) {
        vault.save(tokensAccount(connector.id), nil)
    }

    /// A client for a connected app, which refreshes its sign-in when it runs out. Nil when it isn't connected.
    public static func client(_ connector: Connector, vault: ConnectorVault, session: URLSession = .shared) -> MCPClient? {
        guard isConnected(connector, vault: vault) else { return nil }
        let id = connector.id
        return MCPClient(url: connector.url, session: session) { fresh in
            guard var tokens = vault.load(tokensAccount(id)).flatMap(decode(MCPAuth.Tokens.self)) else {
                throw MCPClient.Failure.signedOut
            }
            if fresh || tokens.expired {
                guard let client = vault.load(clientAccount(id)).flatMap(decode(MCPAuth.Client.self)),
                      let renewed = try? await MCPAuth.refresh(tokens, client: client) else {
                    vault.save(tokensAccount(id), nil)
                    throw MCPClient.Failure.signedOut
                }
                tokens = renewed
                vault.save(tokensAccount(id), encode(tokens))
            }
            return tokens.access
        }
    }

    static func encode<T: Encodable>(_ value: T) -> String? {
        (try? JSONEncoder().encode(value)).map { String(decoding: $0, as: UTF8.self) }
    }

    static func decode<T: Decodable>(_ type: T.Type) -> (String) -> T? {
        { try? JSONDecoder().decode(type, from: Data($0.utf8)) }
    }
}
