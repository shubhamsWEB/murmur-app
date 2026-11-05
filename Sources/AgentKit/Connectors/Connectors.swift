import AppKit
import Observation

/// The apps you connected (Linear, Notion, Jira and Confluence, any MCP server by its address): their sign-ins, their
/// tools for commands (`use_app`), and what they teach the living memory.
@MainActor
@Observable
public final class Connectors {
    public static let shared = Connectors()

    public enum Status: Equatable, Sendable {
        case off
        case connecting
        case connected(tools: Int)
        case failed(String)
    }

    public private(set) var custom: [Connector] = []
    public private(set) var status: [String: Status] = [:]
    @ObservationIgnored private var tools: [String: [MCPClient.Tool]] = [:]
    @ObservationIgnored private var clients: [String: MCPClient] = [:]
    nonisolated let vault: ConnectorVault = KeychainVault()

    public var all: [Connector] { Connector.catalog + custom }

    init() {
        custom = (UserDefaults.standard.array(forKey: "connectors.custom") as? [String] ?? []).compactMap(Connector.custom)
        for connector in all {
            status[connector.id] = ConnectorLink.isConnected(connector, vault: vault) ? .connected(tools: 0) : .off
        }
        ConnectorTools.shared.update(self.summary(), names: self.connectedNames())
    }

    /// Loads each connected app's tools (once at launch, and after connecting).
    public func start() {
        Task { for connector in all where ConnectorLink.isConnected(connector, vault: vault) { await load(connector) } }
    }

    // MARK: Connecting

    public func connect(_ connector: Connector) async {
        status[connector.id] = .connecting
        do {
            try await ConnectorLink.connect(connector, vault: vault) { url in
                await MainActor.run { _ = NSWorkspace.shared.open(url) }
            }
            NSApp.activate(ignoringOtherApps: true)   // back from the browser
            clients[connector.id] = nil
            await load(connector)
            await Brain.shared.sync(now: true)
        } catch {
            status[connector.id] = .failed(error.localizedDescription)
        }
    }

    public func disconnect(_ connector: Connector) {
        ConnectorLink.disconnect(connector, vault: vault)
        clients[connector.id] = nil
        tools[connector.id] = nil
        status[connector.id] = .off
        Brain.shared.store.forget(itemPrefix: "app.\(connector.id):")
        ConnectorTools.shared.update(summary(), names: connectedNames())
    }

    /// Adds an app by its MCP server's address, and connects it. Nil when it isn't an address.
    @discardableResult
    public func add(_ address: String) async -> Connector? {
        guard let connector = Connector.custom(address) else { return nil }
        if !custom.contains(where: { $0.id == connector.id }) {
            custom.append(connector)
            UserDefaults.standard.set(custom.map(\.url.absoluteString), forKey: "connectors.custom")
        }
        await connect(connector)
        return connector
    }

    public func remove(_ connector: Connector) {
        disconnect(connector)
        custom.removeAll { $0.id == connector.id }
        status[connector.id] = nil
        UserDefaults.standard.set(custom.map(\.url.absoluteString), forKey: "connectors.custom")
    }

    private func client(_ connector: Connector) -> MCPClient? {
        if let client = clients[connector.id] { return client }
        let client = ConnectorLink.client(connector, vault: vault)
        clients[connector.id] = client
        return client
    }

    private func load(_ connector: Connector) async {
        guard let client = client(connector) else { status[connector.id] = .off; return }
        do {
            let list = try await client.tools()
            tools[connector.id] = list
            status[connector.id] = .connected(tools: list.count)
        } catch MCPClient.Failure.signedOut {
            status[connector.id] = .failed("Signed out. Connect again.")
            clients[connector.id] = nil
        } catch {
            status[connector.id] = .failed(error.localizedDescription)
        }
        ConnectorTools.shared.update(summary(), names: connectedNames())
    }

    // MARK: Commands

    /// What the command model sees about connected apps: each app and its tools, briefly.
    func summary() -> String {
        all.compactMap { connector -> String? in
            guard let list = tools[connector.id], !list.isEmpty else { return nil }
            let names = list.prefix(40).map(\.name).joined(separator: ", ")
            return "\(connector.name) (app: \"\(connector.id)\"): \(names)"
        }.joined(separator: "\n")
    }

    func connectedNames() -> [String] {
        all.filter { tools[$0.id]?.isEmpty == false }.flatMap { [$0.name.lowercased(), $0.id] }
    }

    /// The tools of the apps a command names, with their arguments, for the model to pick from.
    public func describe(_ app: String) -> String {
        guard let connector = find(app), let list = tools[connector.id] else {
            return "No connected app called \"\(app)\". Connected: \(all.filter { tools[$0.id] != nil }.map(\.name).joined(separator: ", "))."
        }
        return list.map { "- \($0.name): \($0.description.prefix(160)) [\($0.arguments)]" }.joined(separator: "\n")
    }

    func find(_ app: String) -> Connector? {
        let key = app.lowercased().trimmingCharacters(in: .whitespaces)
        return all.first { $0.id == key || $0.name.lowercased() == key || $0.name.lowercased().contains(key)
            || (key == "jira" || key == "confluence") && $0.id == "atlassian" }
    }

    /// Whether a tool only reads (the app says so, or its name does): those run without asking.
    func readsOnly(_ app: String, _ name: String) -> Bool {
        guard let connector = find(app), let tool = tools[connector.id]?.first(where: { $0.name == name }) else { return false }
        if tool.readOnly { return true }
        let lower = name.lowercased()
        return ["get", "list", "search", "fetch", "find", "read", "query", "view", "lookup"].contains {
            lower.hasPrefix($0) || lower.contains("_\($0)") || lower.contains("-\($0)")
        }
    }

    /// Calls a connected app's tool for a command.
    public func call(app: String, tool name: String, arguments: String) async -> String {
        guard let connector = find(app) else { return describe(app) }
        guard let client = client(connector) else { return "\(connector.name) isn't connected. Connect it on Murmur's Memory page." }
        if tools[connector.id]?.contains(where: { $0.name == name }) == false {
            return "\(connector.name) has no tool \"\(name)\". Its tools:\n\(describe(connector.id))"
        }
        do {
            let result = try await client.call(name, arguments: arguments.isEmpty ? "{}" : arguments)
            return (result.isError ? "\(connector.name) said it couldn't: " : "") + String(result.text.prefix(12000))
        } catch {
            if case MCPClient.Failure.signedOut = error { status[connector.id] = .failed("Signed out. Connect again.") }
            return "\(connector.name): \(error.localizedDescription)"
        }
    }

    // MARK: Memory

    /// What the connected apps say now, for the living memory: each lesson's text, keyed so only changes are read.
    func lessons() async -> [(connector: Connector, lesson: Connector.Lesson, text: String)] {
        var found: [(connector: Connector, lesson: Connector.Lesson, text: String)] = []
        for connector in all where !connector.teaches.isEmpty {
            guard let client = client(connector), let list = tools[connector.id] else { continue }
            for lesson in connector.teaches {
                guard let tool = lesson.tools.first(where: { name in list.contains { $0.name == name } }),
                      let result = try? await client.call(tool, arguments: lesson.arguments), !result.isError,
                      result.text.count > 40 else { continue }
                found.append((connector, lesson, result.text))
            }
        }
        return found
    }
}

/// What `use_app` tells the command model about connected apps (read off the main thread when tools are built).
public final class ConnectorTools: @unchecked Sendable {
    public static let shared = ConnectorTools()
    private let lock = NSLock()
    private var text = ""
    private var apps: [String] = []

    public var summary: String { lock.lock(); defer { lock.unlock() }; return text }
    /// Connected apps' names, lowercased ("linear", "jira and confluence", "atlassian").
    public var names: [String] { lock.lock(); defer { lock.unlock() }; return apps }
    func update(_ value: String, names: [String]) { lock.lock(); text = value; apps = names; lock.unlock() }
}

/// Sign-ins in the login Keychain, on this Mac only.
struct KeychainVault: ConnectorVault {
    func load(_ account: String) -> String? { Keychain.get(account) }
    func save(_ account: String, _ value: String?) { Keychain.set(account, value ?? "") }
}
