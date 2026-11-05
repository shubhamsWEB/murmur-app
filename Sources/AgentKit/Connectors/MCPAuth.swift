import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Signing in to a connected app the way MCP clients do (the MCP authorization spec, OAuth 2.1), with no key to paste:
///
/// 1. Ask the app's MCP server; it answers 401 and says where its sign-in lives (RFC 9728 protected resource
///    metadata), or Murmur looks in the usual place.
/// 2. Read the sign-in server's metadata (RFC 8414): where to sign in, get tokens, and register.
/// 3. Register Murmur with it, once (dynamic client registration, RFC 7591), with a redirect back to this Mac.
/// 4. Open the sign-in page in the browser, with PKCE. You approve there; the page sends the browser back to Murmur
///    on 127.0.0.1 (`LoopbackRedirect`), with a code that's exchanged for tokens.
/// 5. Tokens are kept in the Keychain and refreshed when they run out.
public enum MCPAuth {
    public struct ServerMetadata: Codable, Sendable, Equatable {
        public var issuer: String?
        public var authorizationEndpoint: String
        public var tokenEndpoint: String
        public var registrationEndpoint: String?
        public var scopes: [String]
        /// The protected resource (the MCP server), sent as `resource` (RFC 8707) when the server says it.
        public var resource: String?
    }

    /// Murmur as registered with one app's sign-in server.
    public struct Client: Codable, Sendable, Equatable {
        public var id: String
        public var secret: String?
        public var redirect: String
        public var server: ServerMetadata
    }

    public struct Tokens: Codable, Sendable, Equatable {
        public var access: String
        public var refresh: String?
        public var expires: Date?

        public var expired: Bool { expires.map { $0 < Date().addingTimeInterval(60) } ?? false }
    }

    public enum Failure: Error, LocalizedError, Equatable {
        case noSignIn(String)
        case cantRegister(String)
        case denied(String)
        case badResponse(String)

        public var errorDescription: String? {
            switch self {
            case .noSignIn(let why): return "This app's server doesn't offer a sign-in Murmur can use (\(why))."
            case .cantRegister(let why): return "The app didn't let Murmur register (\(why))."
            case .denied(let why): return "Sign-in didn't finish (\(why))."
            case .badResponse(let why): return "The app's sign-in answered in a way Murmur can't read (\(why))."
            }
        }
    }

    static var session: URLSession = .shared

    // MARK: Discovery

    /// Where an MCP server's sign-in lives.
    public static func discover(_ server: URL) async throws -> ServerMetadata {
        var resource: [String: Any]?
        // The server says it in its 401: WWW-Authenticate: Bearer resource_metadata="…".
        var probe = URLRequest(url: server)
        probe.httpMethod = "POST"
        probe.setValue("application/json", forHTTPHeaderField: "Content-Type")
        probe.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        probe.httpBody = Data(#"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"Murmur","version":"1"}}}"#.utf8)
        probe.timeoutInterval = 15
        if let (_, response) = try? await session.data(for: probe), let http = response as? HTTPURLResponse,
           let header = http.value(forHTTPHeaderField: "WWW-Authenticate"),
           let link = parameter("resource_metadata", in: header), let url = URL(string: link) {
            resource = try? await json(url)
        }
        // Else the well-known places: with the server's path, then at the root.
        if resource == nil {
            for url in wellKnown("oauth-protected-resource", for: server) {
                if let found = try? await json(url) { resource = found; break }
            }
        }
        // The sign-in server: the one the resource names, or (older servers) the MCP server's own origin.
        let authServer = (resource?["authorization_servers"] as? [String])?.first.flatMap(URL.init(string:))
            ?? origin(of: server)
        var metadata: [String: Any]?
        for url in wellKnown("oauth-authorization-server", for: authServer) + wellKnown("openid-configuration", for: authServer) {
            if let found = try? await json(url), found["authorization_endpoint"] != nil { metadata = found; break }
        }
        guard let metadata, let authorize = metadata["authorization_endpoint"] as? String,
              let token = metadata["token_endpoint"] as? String else {
            throw Failure.noSignIn("no OAuth metadata at \(authServer.host ?? authServer.absoluteString)")
        }
        let scopes = (resource?["scopes_supported"] as? [String]) ?? []
        return ServerMetadata(issuer: metadata["issuer"] as? String, authorizationEndpoint: authorize, tokenEndpoint: token,
                              registrationEndpoint: metadata["registration_endpoint"] as? String, scopes: scopes,
                              resource: resource?["resource"] as? String)
    }

    /// RFC 8414 / RFC 9728 places: `/.well-known/<name><path>` first, then `/.well-known/<name>`.
    static func wellKnown(_ name: String, for url: URL) -> [URL] {
        let base = origin(of: url)
        let path = url.path == "/" ? "" : url.path
        var urls: [URL] = []
        if !path.isEmpty, let withPath = URL(string: "/.well-known/\(name)\(path)", relativeTo: base) { urls.append(withPath.absoluteURL) }
        if let root = URL(string: "/.well-known/\(name)", relativeTo: base) { urls.append(root.absoluteURL) }
        return urls
    }

    static func origin(of url: URL) -> URL {
        var parts = URLComponents()
        parts.scheme = url.scheme
        parts.host = url.host
        parts.port = url.port
        return parts.url ?? url
    }

    /// A parameter of an HTTP auth header: `resource_metadata="https://…"`.
    static func parameter(_ name: String, in header: String) -> String? {
        guard let range = header.range(of: "\(name)=") else { return nil }
        var rest = header[range.upperBound...]
        if rest.first == "\"" {
            rest = rest.dropFirst()
            return rest.firstIndex(of: "\"").map { String(rest[..<$0]) }
        }
        return String(rest.prefix { $0 != "," && $0 != " " })
    }

    // MARK: Registering

    /// Registers Murmur with the sign-in server (once per app), for the redirect back to this Mac.
    public static func register(_ server: ServerMetadata, redirect: String) async throws -> Client {
        guard let endpoint = server.registrationEndpoint.flatMap(URL.init(string:)) else {
            throw Failure.cantRegister("it doesn't support automatic registration")
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        var body: [String: Any] = [
            "client_name": "Murmur", "client_uri": "https://usemurmur.live", "redirect_uris": [redirect],
            "grant_types": ["authorization_code", "refresh_token"], "response_types": ["code"],
            "token_endpoint_auth_method": "none", "application_type": "native",
        ]
        if !server.scopes.isEmpty { body["scope"] = server.scopes.joined(separator: " ") }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status), let reply = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = reply["client_id"] as? String else {
            throw Failure.cantRegister("HTTP \(status): \(String(decoding: data.prefix(200), as: UTF8.self))")
        }
        return Client(id: id, secret: reply["client_secret"] as? String, redirect: redirect, server: server)
    }

    // MARK: Signing in

    public struct Attempt: Sendable {
        public let url: URL
        public let verifier: String
        public let state: String
    }

    /// The sign-in page to open, with PKCE.
    public static func begin(_ client: Client) -> Attempt {
        let verifier = randomString(64)
        let state = randomString(24)
        var parts = URLComponents(string: client.server.authorizationEndpoint)!
        var query = parts.queryItems ?? []
        query += [
            URLQueryItem(name: "response_type", value: "code"), URLQueryItem(name: "client_id", value: client.id),
            URLQueryItem(name: "redirect_uri", value: client.redirect), URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: SHA256.base64URL(Data(verifier.utf8))),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        if !client.server.scopes.isEmpty { query.append(URLQueryItem(name: "scope", value: client.server.scopes.joined(separator: " "))) }
        if let resource = client.server.resource { query.append(URLQueryItem(name: "resource", value: resource)) }
        parts.queryItems = query
        return Attempt(url: parts.url!, verifier: verifier, state: state)
    }

    /// What the browser came back with: the code, once its state matches.
    public static func code(from callback: URL, for attempt: Attempt) throws -> String {
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        if let error = value("error") { throw Failure.denied(value("error_description") ?? error) }
        guard value("state") == attempt.state else { throw Failure.denied("the reply wasn't for this sign-in") }
        guard let code = value("code"), !code.isEmpty else { throw Failure.denied("no code came back") }
        return code
    }

    public static func exchange(_ code: String, attempt: Attempt, client: Client) async throws -> Tokens {
        var form = ["grant_type": "authorization_code", "code": code, "redirect_uri": client.redirect,
                    "client_id": client.id, "code_verifier": attempt.verifier]
        if let resource = client.server.resource { form["resource"] = resource }
        return try await token(form, client: client, previous: nil)
    }

    public static func refresh(_ tokens: Tokens, client: Client) async throws -> Tokens {
        guard let refresh = tokens.refresh else { throw Failure.denied("signed out: no way to stay signed in") }
        var form = ["grant_type": "refresh_token", "refresh_token": refresh, "client_id": client.id]
        if let resource = client.server.resource { form["resource"] = resource }
        return try await token(form, client: client, previous: tokens)
    }

    private static func token(_ form: [String: String], client: Client, previous: Tokens?) async throws -> Tokens {
        var form = form
        if let secret = client.secret { form["client_secret"] = secret }
        var request = URLRequest(url: URL(string: client.server.tokenEndpoint)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Data(formEncoded(form).utf8)
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard let reply = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.badResponse("HTTP \(status)")
        }
        guard (200..<300).contains(status), let access = reply["access_token"] as? String else {
            throw Failure.denied(reply["error_description"] as? String ?? reply["error"] as? String ?? "HTTP \(status)")
        }
        let lifetime = (reply["expires_in"] as? NSNumber)?.doubleValue
        return Tokens(access: access, refresh: reply["refresh_token"] as? String ?? previous?.refresh,
                      expires: lifetime.map { Date().addingTimeInterval($0) })
    }

    // MARK: Helpers

    static func formEncoded(_ form: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return form.sorted { $0.key < $1.key }.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
        }.joined(separator: "&")
    }

    static func randomString(_ length: Int) -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        var generator = SystemRandomNumberGenerator()
        return String((0..<length).map { _ in alphabet[Int(generator.next() % UInt64(alphabet.count))] })
    }

    private static func json(_ url: URL) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.badResponse(url.absoluteString)
        }
        return object
    }
}

/// SHA-256, for PKCE's code challenge (Foundation has no hash of its own on every platform Murmur builds on).
enum SHA256 {
    private static let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5, 0xd807aa98,
        0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786,
        0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da, 0x983e5152, 0xa831c66d, 0xb00327c8,
        0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
        0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819,
        0xd6990624, 0xf40e3585, 0x106aa070, 0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a,
        0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7,
        0xc67178f2,
    ]

    static func hash(_ data: Data) -> [UInt8] {
        var h: [UInt32] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
        var message = [UInt8](data)
        let bits = UInt64(message.count) * 8
        message.append(0x80)
        while message.count % 64 != 56 { message.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) { message.append(UInt8((bits >> UInt64(shift)) & 0xff)) }
        func rotate(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }
        var w = [UInt32](repeating: 0, count: 64)
        for chunk in stride(from: 0, to: message.count, by: 64) {
            for i in 0..<16 {
                let j = chunk + i * 4
                w[i] = UInt32(message[j]) << 24 | UInt32(message[j + 1]) << 16 | UInt32(message[j + 2]) << 8 | UInt32(message[j + 3])
            }
            for i in 16..<64 {
                let s0 = rotate(w[i - 15], 7) ^ rotate(w[i - 15], 18) ^ (w[i - 15] >> 3)
                let s1 = rotate(w[i - 2], 17) ^ rotate(w[i - 2], 19) ^ (w[i - 2] >> 10)
                w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
            }
            var (a, b, c, d, e, f, g, hh) = (h[0], h[1], h[2], h[3], h[4], h[5], h[6], h[7])
            for i in 0..<64 {
                let s1 = rotate(e, 6) ^ rotate(e, 11) ^ rotate(e, 25)
                let choice = (e & f) ^ (~e & g)
                let t1 = hh &+ s1 &+ choice &+ k[i] &+ w[i]
                let s0 = rotate(a, 2) ^ rotate(a, 13) ^ rotate(a, 22)
                let majority = (a & b) ^ (a & c) ^ (b & c)
                let t2 = s0 &+ majority
                (hh, g, f, e, d, c, b, a) = (g, f, e, d &+ t1, c, b, a, t1 &+ t2)
            }
            for (i, value) in [a, b, c, d, e, f, g, hh].enumerated() { h[i] = h[i] &+ value }
        }
        return h.flatMap { value in [24, 16, 8, 0].map { UInt8((value >> UInt32($0)) & 0xff) } }
    }

    static func base64URL(_ data: Data) -> String {
        Data(hash(data)).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
