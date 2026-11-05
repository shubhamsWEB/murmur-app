"""A stand-in MCP server with OAuth 2.1 (RFC 9728 + 8414 + 7591 + PKCE), for Murmur's connector tests."""
import base64, hashlib, json, sys, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs, urlencode

PORT = int(sys.argv[1])
BASE = f"http://127.0.0.1:{PORT}"
state = {"clients": {}, "codes": {}, "valid": set(), "refresh": {}, "n": 0, "expire_next": False, "sessions": set()}
lock = threading.Lock()


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def send(self, code, body=None, headers=None, ctype="application/json"):
        data = b"" if body is None else (body if isinstance(body, bytes) else json.dumps(body).encode())
        self.send_response(code)
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        if body is not None:
            self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def body(self):
        n = int(self.headers.get("Content-Length", 0))
        return self.rfile.read(n)

    def do_GET(self):
        u = urlparse(self.path)
        if u.path == "/.well-known/oauth-protected-resource/mcp":
            return self.send(200, {"resource": f"{BASE}/mcp", "authorization_servers": [BASE], "scopes_supported": ["read", "write"]})
        if u.path == "/.well-known/oauth-authorization-server":
            return self.send(200, {"issuer": BASE, "authorization_endpoint": f"{BASE}/authorize", "token_endpoint": f"{BASE}/token",
                                   "registration_endpoint": f"{BASE}/register", "code_challenge_methods_supported": ["S256"]})
        if u.path == "/authorize":
            q = {k: v[0] for k, v in parse_qs(u.query).items()}
            c = state["clients"].get(q.get("client_id"))
            if not c or q.get("redirect_uri") not in c["redirect_uris"] or q.get("code_challenge_method") != "S256" \
                    or q.get("resource") != f"{BASE}/mcp" or q.get("scope") != "read write":
                return self.send(400, {"error": "invalid_request"})
            with lock:
                state["n"] += 1
                code = f"code{state['n']}"
                state["codes"][code] = (q["client_id"], q["code_challenge"], q["redirect_uri"])
            return self.send(302, None, {"Location": q["redirect_uri"] + "?" + urlencode({"code": code, "state": q["state"]})})
        if u.path == "/control/expire":
            state["expire_next"] = True
            return self.send(200, {})
        self.send(404, {})

    def do_POST(self):
        u = urlparse(self.path)
        raw = self.body()
        if u.path == "/register":
            req = json.loads(raw)
            with lock:
                state["n"] += 1
                cid = f"client{state['n']}"
                state["clients"][cid] = req
            return self.send(201, {"client_id": cid, **req})
        if u.path == "/token":
            f = {k: v[0] for k, v in parse_qs(raw.decode()).items()}
            if f.get("grant_type") == "authorization_code":
                entry = state["codes"].pop(f.get("code"), None)
                if not entry:
                    return self.send(400, {"error": "invalid_grant"})
                cid, challenge, redirect = entry
                verifier = f.get("code_verifier", "")
                computed = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).decode().rstrip("=")
                if computed != challenge or f.get("client_id") != cid or f.get("redirect_uri") != redirect:
                    return self.send(400, {"error": "invalid_grant", "error_description": "PKCE or client mismatch"})
            elif f.get("grant_type") == "refresh_token":
                if f.get("refresh_token") not in state["refresh"]:
                    return self.send(400, {"error": "invalid_grant"})
            else:
                return self.send(400, {"error": "unsupported_grant_type"})
            with lock:
                state["n"] += 1
                tok, ref = f"tok{state['n']}", f"ref{state['n']}"
                state["valid"].add(tok)
                state["refresh"][ref] = tok
            return self.send(200, {"access_token": tok, "token_type": "Bearer", "expires_in": 3600, "refresh_token": ref})
        if u.path == "/mcp":
            auth = self.headers.get("Authorization", "")
            tok = auth[7:] if auth.startswith("Bearer ") else None
            if tok not in state["valid"] or state["expire_next"]:
                if tok in state["valid"]:
                    state["valid"].discard(tok)
                    state["expire_next"] = False
                return self.send(401, {"error": "unauthorized"},
                                 {"WWW-Authenticate": f'Bearer resource_metadata="{BASE}/.well-known/oauth-protected-resource/mcp"'})
            msg = json.loads(raw)
            method = msg.get("method")
            if "id" not in msg:
                return self.send(202)
            if method == "initialize":
                with lock:
                    state["n"] += 1
                    sid = f"s{state['n']}"
                    state["sessions"].add(sid)
                return self.send(200, {"jsonrpc": "2.0", "id": msg["id"], "result": {"protocolVersion": "2025-06-18",
                                       "capabilities": {"tools": {}}, "serverInfo": {"name": "mock", "version": "1"}}},
                                 {"Mcp-Session-Id": sid})
            if self.headers.get("Mcp-Session-Id") not in state["sessions"]:
                return self.send(400, {"jsonrpc": "2.0", "id": msg["id"], "error": {"code": -32000, "message": "no session"}})
            if method == "tools/list":
                tools = [{"name": "list_my_issues", "description": "Issues assigned to you",
                          "inputSchema": {"type": "object", "properties": {"limit": {"type": "number", "description": "how many"}}},
                          "annotations": {"readOnlyHint": True}},
                         {"name": "create_issue", "description": "Create an issue",
                          "inputSchema": {"type": "object", "properties": {"title": {"type": "string"}}, "required": ["title"]}}]
                reply = json.dumps({"jsonrpc": "2.0", "id": msg["id"], "result": {"tools": tools}})
                sse = f"event: message\ndata: {reply}\n\n".encode()
                return self.send(200, sse, ctype="text/event-stream")
            if method == "tools/call":
                p = msg["params"]
                text = f"called {p['name']} with {json.dumps(p.get('arguments', {}), sort_keys=True)}"
                return self.send(200, {"jsonrpc": "2.0", "id": msg["id"], "result": {"content": [{"type": "text", "text": text}]}})
            return self.send(200, {"jsonrpc": "2.0", "id": msg["id"], "error": {"code": -32601, "message": "unknown"}})
        self.send(404, {})


ThreadingHTTPServer(("127.0.0.1", PORT), H).serve_forever()
