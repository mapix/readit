import Foundation
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif
import CryptoKit
import Network
import Security

/// "Sign in with ChatGPT" — lets eligible ChatGPT Plus / Pro users run Readlet's AI features on their ChatGPT
/// plan instead of an API key (OpenAI's open-source "ChatGPT plan usage" flow).
///
/// Flow (https://developers.openai.com/siwc/token-sharing-open-source):
///  • a stable per-install host id (`urn:uuid:…`) is created once;
///  • OAuth 2.0 + PKCE in the system browser with a loopback callback on 127.0.0.1;
///    first sign-in registers a client via `client_id=dynamic_agent_client`, later ones reuse the issued id;
///  • the ID token is verified against OpenAI's JWKS (RS256, issuer, audience, expiry, nonce);
///  • access tokens (1 h) are refreshed with the rotating refresh token (30 days);
///  • inference goes to `POST https://api.openai.com/v1/responses` with `store: false, stream: true`.
/// Credentials are kept in ~/.config/readlet/chatgpt-auth.json (0600), never in logs.
@MainActor
final class ChatGPTAuth: ObservableObject {
    static let shared = ChatGPTAuth()

    nonisolated static let issuer = "https://auth.openai.com"
    nonisolated static let authorizeURL = "https://auth.openai.com/api/accounts/authorize"
    nonisolated static let tokenURL = "https://auth.openai.com/api/accounts/oauth/token"
    nonisolated static let resource = "https://api.openai.com/v1"
    nonisolated static let scopes = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"
    nonisolated static let usageURL = URL(string: "https://chatgpt.com/settings/usage")!
    nonisolated static let appName = "Readlet"

    struct Credential: Codable, Equatable {
        var email: String?
        var issuer: String
        var subject: String
        var client_id: String
        var ext_agent_host_id: String
        var id_token: String?
        var access_token: String?
        var refresh_token: String?
        var token_type: String?
        var expires_in: Int?
        var scopes: [String]
        var saved_at: Date
        var expiresAt: Date { saved_at.addingTimeInterval(TimeInterval(expires_in ?? 3600)) }
        var sharing: Bool { access_token != nil && scopes.contains("chatgpt.tokens.use.direct") }
    }
    struct Store: Codable { var profiles: [Credential] = []; var active: String? }   // active = client_id
    struct Model: Identifiable, Hashable { var slug: String; var name: String; var id: String { slug } }

    enum Phase: Equatable { case signedOut, signingIn, connected, needsReconnect }
    @Published private(set) var phase: Phase = .signedOut
    @Published private(set) var profile: Credential?
    @Published var models: [Model] = []
    @Published var message = ""

    private var store = Store()
    private var refreshTask: Task<String, Error>?
    private var server: LoopbackServer?

    static var dir: URL {
        ConfigFile.configDir
    }
    static var storeURL: URL { dir.appendingPathComponent("chatgpt-auth.json") }
    static var hostURL: URL { dir.appendingPathComponent("chatgpt-host.json") }

    init() { load() }

    var connected: Bool { phase == .connected && (profile?.sharing ?? false) }
    var accountLabel: String { profile?.email ?? profile?.subject ?? "" }

    // MARK: persistence

    private func load() {
        guard let d = try? Data(contentsOf: ChatGPTAuth.storeURL) else { return }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        guard let s = try? dec.decode(Store.self, from: d) else { return }
        store = s
        profile = s.profiles.first { $0.client_id == s.active }
        if let p = profile { phase = p.refresh_token != nil || p.access_token != nil ? .connected : .needsReconnect }
    }

    private func save() {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let d = try? enc.encode(store) else { return }
        ChatGPTAuth.writeSecret(d, to: ChatGPTAuth.storeURL)
    }

    static func writeSecret(_ d: Data, to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? d.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// one stable, opaque id for this installation
    static func hostId() -> String {
        if let d = try? Data(contentsOf: hostURL), let o = try? JSONSerialization.jsonObject(with: d) as? [String: String], let h = o["ext_agent_host_id"] { return h }
        let h = "urn:uuid:" + UUID().uuidString.lowercased()
        if let d = try? JSONSerialization.data(withJSONObject: ["ext_agent_host_id": h]) { writeSecret(d, to: hostURL) }
        return h
    }

    // MARK: sign in

    func signIn(newAccount: Bool = false) {
        guard phase != .signingIn else { return }
        phase = .signingIn; message = L("请在浏览器中登录 ChatGPT 并允许 Readlet 使用你的套餐…")
        Task {
            do {
                try await runSignIn(existing: newAccount ? nil : profile)
                message = connected ? L("已连接") : L("已登录，但没有授权使用 ChatGPT 套餐")
                await refreshModels()
            } catch {
                phase = profile?.access_token != nil ? .connected : (profile == nil ? .signedOut : .needsReconnect)
                message = "❌ " + error.localizedDescription
            }
            server?.stop(); server = nil
        }
    }

    private func runSignIn(existing: Credential?) async throws {
        let host = ChatGPTAuth.hostId()
        let srv = try await LoopbackServer.start(preferredPort: 1455)
        server = srv
        let redirect = "http://127.0.0.1:\(srv.port)/auth/callback"
        let state = ChatGPTAuth.random(32), nonce = ChatGPTAuth.random(32), verifier = ChatGPTAuth.random(48)
        let challenge = ChatGPTAuth.base64url(Data(SHA256.hash(data: Data(verifier.utf8))))
        var q: [(String, String)] = [
            ("client_id", existing?.client_id ?? "dynamic_agent_client"),
            ("ext_agent_host_id", host),
            ("response_type", "code"),
            ("redirect_uri", redirect),
            ("scope", ChatGPTAuth.scopes),
            ("resource", ChatGPTAuth.resource),
            ("state", state),
            ("nonce", nonce),
            ("code_challenge_method", "S256"),
            ("code_challenge", challenge),
        ]
        if let e = existing {
            if let t = e.id_token { q.append(("id_token_hint", t)) }
            if let m = e.email { q.append(("login_hint", m)) }
        } else {
            q.append(("agent_name_hint", ChatGPTAuth.appName))
        }
        var comps = URLComponents(string: ChatGPTAuth.authorizeURL)!
        comps.percentEncodedQueryItems = q.map { URLQueryItem(name: $0.0, value: ChatGPTAuth.formEncode($0.1)) }
        guard let url = comps.url else { throw TranslateError.bad("authorize URL") }
        PlatformBrowser.open(url)

        let cb = try await srv.waitForCallback(timeout: 300)
        guard cb["state"] == state else { throw TranslateError.bad(L("登录回调校验失败（state 不匹配）")) }
        if let err = cb["error"] {
            if err == "access_denied" { throw TranslateError.bad(L("你取消了授权")) }
            throw TranslateError.bad("OAuth: \(err) \(cb["error_description"] ?? "")")
        }
        guard let code = cb["code"] else { throw TranslateError.bad(L("登录回调缺少授权码")) }
        let clientId: String
        if let e = existing {
            if let c = cb["client_id"], c != e.client_id { throw TranslateError.bad(L("返回的 client_id 与已保存的账号不一致")) }
            clientId = e.client_id
        } else {
            guard let c = cb["client_id"], c != "dynamic_agent_client" else { throw TranslateError.bad(L("注册未完成：没有收到 client_id")) }
            clientId = c
        }

        let tok = try await ChatGPTAuth.tokenRequest([
            "grant_type": "authorization_code", "client_id": clientId, "code": code,
            "code_verifier": verifier, "redirect_uri": redirect, "resource": ChatGPTAuth.resource,
        ])
        guard let idToken = tok["id_token"] as? String else { throw TranslateError.bad(L("没有收到 ID token")) }
        let claims = try await JWTVerifier.verify(idToken, audience: clientId, nonce: nonce)
        guard let sub = claims["sub"] as? String else { throw TranslateError.bad("ID token: sub") }
        if let e = existing, e.subject != sub { throw TranslateError.bad(L("登录的账号与当前账号不同，请用「添加账号」")) }
        let cred = Credential(email: claims["email"] as? String, issuer: ChatGPTAuth.issuer, subject: sub, client_id: clientId,
                              ext_agent_host_id: host, id_token: idToken, access_token: tok["access_token"] as? String,
                              refresh_token: tok["refresh_token"] as? String, token_type: tok["token_type"] as? String,
                              expires_in: (tok["expires_in"] as? NSNumber)?.intValue,
                              scopes: ((tok["scope"] as? String) ?? "").split(separator: " ").map(String.init), saved_at: Date())
        put(cred)
    }

    private func put(_ c: Credential) {
        store.profiles.removeAll { $0.client_id == c.client_id }
        store.profiles.append(c)
        store.active = c.client_id
        profile = c
        phase = c.access_token != nil ? .connected : .needsReconnect
        save()
    }

    func select(clientId: String) {
        guard let p = store.profiles.first(where: { $0.client_id == clientId }) else { return }
        store.active = clientId; profile = p
        phase = p.refresh_token != nil ? .connected : .needsReconnect
        save()
        Task { await refreshModels() }
    }
    var savedProfiles: [Credential] { store.profiles }

    // MARK: tokens

    /// a valid access token for the active account (refreshing when it is about to expire)
    func accessToken() async throws -> String {
        guard let p = profile, let at = p.access_token else { throw TranslateError.bad(L("请先在设置中登录 ChatGPT")) }
        guard p.sharing else { throw TranslateError.bad(L("ChatGPT 账号未授权使用套餐额度，请在设置中重新连接")) }
        if p.expiresAt.timeIntervalSinceNow > 120 { return at }
        if let t = refreshTask { return try await t.value }               // serialize: rotating refresh tokens
        let t = Task<String, Error> { @MainActor in
            defer { self.refreshTask = nil }
            return try await self.refresh(p)
        }
        refreshTask = t
        return try await t.value
    }

    private func refresh(_ p: Credential) async throws -> String {
        guard let rt = p.refresh_token else { phase = .needsReconnect; throw TranslateError.bad(L("ChatGPT 登录已过期，请重新连接")) }
        do {
            let tok = try await ChatGPTAuth.tokenRequest([
                "grant_type": "refresh_token", "client_id": p.client_id, "refresh_token": rt, "resource": ChatGPTAuth.resource,
            ])
            var n = p
            n.access_token = tok["access_token"] as? String ?? p.access_token
            n.refresh_token = tok["refresh_token"] as? String ?? p.refresh_token
            n.id_token = tok["id_token"] as? String ?? p.id_token
            n.expires_in = (tok["expires_in"] as? NSNumber)?.intValue ?? 3600
            if let s = tok["scope"] as? String { n.scopes = s.split(separator: " ").map(String.init) }
            n.saved_at = Date()
            put(n)
            guard let at = n.access_token else { throw TranslateError.bad("refresh: no access token") }
            return at
        } catch let e as OAuthError where e.terminal {
            var n = p; n.access_token = nil; n.refresh_token = nil
            put(n); phase = .needsReconnect
            throw TranslateError.bad(L("ChatGPT 登录已失效，请重新连接") + " (\(e.code))")
        }
    }

    func signOut() {
        guard let p = profile else { return }
        Task {
            var confirmed = true
            if let rt = p.refresh_token { confirmed = await ChatGPTAuth.revoke(rt, clientId: p.client_id) }
            var n = p; n.access_token = nil; n.refresh_token = nil; n.id_token = nil
            store.profiles.removeAll { $0.client_id == p.client_id }
            store.profiles.append(n)           // keep the registration (client id ↔ account) for the next sign-in
            store.active = nil
            profile = nil; phase = .signedOut; models = []
            save()
            message = confirmed ? L("已退出登录") : L("已在本机退出；未能确认远程撤销，可在 ChatGPT 设置中断开 Readlet")
        }
    }

    func refreshModels() async {
        guard connected, let t = try? await accessToken(), let u = URL(string: ChatGPTAuth.resource + "/models") else { return }
        var req = URLRequest(url: u, timeoutInterval: 20)
        req.setValue("Bearer " + t, forHTTPHeaderField: "Authorization")
        guard let (d, resp) = try? await URLSession.shared.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200,
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return }
        let arr = (o["models"] as? [[String: Any]]) ?? (o["data"] as? [[String: Any]]) ?? []
        models = arr.filter { ($0["visibility"] as? String ?? "list") == "list" }.compactMap { m in
            guard let slug = (m["slug"] ?? m["id"]) as? String else { return nil }
            return Model(slug: slug, name: m["display_name"] as? String ?? slug)
        }
    }

    // MARK: OAuth helpers

    struct OAuthError: LocalizedError {
        var code: String; var detail: String; var status: Int
        var terminal: Bool { ["invalid_grant", "invalid_refresh_token", "token_expired", "refresh_token_expired", "refresh_token_invalidated", "refresh_token_reused", "invalid_client"].contains(code) }
        var errorDescription: String? { "OAuth \(status) \(code) \(detail)" }
    }

    nonisolated static func tokenRequest(_ form: [String: String]) async throws -> [String: Any] {
        guard let u = URL(string: tokenURL) else { throw TranslateError.bad("token URL") }
        var req = URLRequest(url: u, timeoutInterval: 30)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(form.map { "\($0.key)=\(formEncode($0.value))" }.joined(separator: "&").utf8)
        let (d, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let o = (try? JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:]
        guard code == 200 else {
            throw OAuthError(code: o["error"] as? String ?? "http_\(code)", detail: o["error_description"] as? String ?? (o["detail"] as? String ?? ""), status: code)
        }
        return o
    }

    nonisolated static func revoke(_ refreshToken: String, clientId: String) async -> Bool {
        guard let conf = try? await JWTVerifier.configuration(), let s = conf["revocation_endpoint"] as? String, let u = URL(string: s) else { return false }
        var req = URLRequest(url: u, timeoutInterval: 20)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data("token=\(formEncode(refreshToken))&token_type_hint=refresh_token&client_id=\(formEncode(clientId))".utf8)
        for attempt in 0..<3 {
            if let (_, r) = try? await URLSession.shared.data(for: req), let c = (r as? HTTPURLResponse)?.statusCode {
                if c == 200 { return true }
                if c < 500 { return false }
            }
            try? await Task.sleep(nanoseconds: UInt64(700_000_000 * (attempt + 1)))
        }
        return false
    }

    nonisolated static func formEncode(_ s: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }
    nonisolated static func base64url(_ d: Data) -> String {
        d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    nonisolated static func random(_ bytes: Int) -> String {
        var b = [UInt8](repeating: 0, count: bytes)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes, &b)
        return base64url(Data(b))
    }
}

// MARK: - ID token verification (RS256 against OpenAI's JWKS)

enum JWTVerifier {
    static func configuration() async throws -> [String: Any] {
        guard let u = URL(string: ChatGPTAuth.issuer + "/.well-known/openid-configuration") else { throw TranslateError.bad("oidc") }
        let (d, _) = try await URLSession.shared.data(from: u)
        guard let o = try JSONSerialization.jsonObject(with: d) as? [String: Any] else { throw TranslateError.bad("oidc configuration") }
        return o
    }

    static func b64urlDecode(_ s: String) -> Data? {
        var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while t.count % 4 != 0 { t += "=" }
        return Data(base64Encoded: t)
    }

    /// decoded claims of a JWT (no verification)
    static func claims(_ jwt: String) -> [String: Any]? {
        let parts = jwt.split(separator: ".")
        guard parts.count == 3, let d = b64urlDecode(String(parts[1])) else { return nil }
        return try? JSONSerialization.jsonObject(with: d) as? [String: Any]
    }

    static func verify(_ jwt: String, audience: String, nonce: String) async throws -> [String: Any] {
        let parts = jwt.split(separator: ".").map(String.init)
        guard parts.count == 3, let hd = b64urlDecode(parts[0]), let header = try? JSONSerialization.jsonObject(with: hd) as? [String: Any],
              let sig = b64urlDecode(parts[2]), let c = claims(jwt) else { throw TranslateError.bad("ID token: malformed") }
        guard header["alg"] as? String == "RS256" else { throw TranslateError.bad("ID token: unexpected alg") }
        let conf = try await configuration()
        guard let ju = (conf["jwks_uri"] as? String).flatMap(URL.init(string:)) else { throw TranslateError.bad("jwks_uri") }
        let (jd, _) = try await URLSession.shared.data(from: ju)
        guard let jwks = try JSONSerialization.jsonObject(with: jd) as? [String: Any], let keys = jwks["keys"] as? [[String: Any]] else { throw TranslateError.bad("jwks") }
        let kid = header["kid"] as? String
        guard let jwk = keys.first(where: { kid == nil || ($0["kid"] as? String) == kid }),
              let n = (jwk["n"] as? String).flatMap(b64urlDecode), let e = (jwk["e"] as? String).flatMap(b64urlDecode),
              let key = rsaPublicKey(modulus: n, exponent: e) else { throw TranslateError.bad("ID token: signing key not found") }
        let signed = Data((parts[0] + "." + parts[1]).utf8)
        var err: Unmanaged<CFError>?
        guard SecKeyVerifySignature(key, .rsaSignatureMessagePKCS1v15SHA256, signed as CFData, sig as CFData, &err) else {
            throw TranslateError.bad("ID token: bad signature")
        }
        // claims
        guard (c["iss"] as? String) == ChatGPTAuth.issuer else { throw TranslateError.bad("ID token: issuer") }
        let aud = (c["aud"] as? String).map { [$0] } ?? (c["aud"] as? [String]) ?? []
        guard aud.contains(audience) else { throw TranslateError.bad("ID token: audience") }
        if let exp = (c["exp"] as? NSNumber)?.doubleValue, Date(timeIntervalSince1970: exp) < Date().addingTimeInterval(-60) { throw TranslateError.bad("ID token: expired") }
        guard (c["nonce"] as? String) == nonce else { throw TranslateError.bad("ID token: nonce") }
        return c
    }

    /// PKCS#1 RSAPublicKey DER from modulus / exponent → SecKey
    static func rsaPublicKey(modulus: Data, exponent: Data) -> SecKey? {
        func len(_ n: Int) -> Data {
            if n < 0x80 { return Data([UInt8(n)]) }
            var b: [UInt8] = []; var v = n
            while v > 0 { b.insert(UInt8(v & 0xFF), at: 0); v >>= 8 }
            return Data([0x80 | UInt8(b.count)] + b)
        }
        func integer(_ d: Data) -> Data {
            var x = [UInt8](d)
            while x.count > 1 && x[0] == 0 { x.removeFirst() }
            if let f = x.first, f & 0x80 != 0 { x.insert(0, at: 0) }
            return Data([0x02]) + len(x.count) + Data(x)
        }
        let body = integer(modulus) + integer(exponent)
        let der = Data([0x30]) + len(body.count) + body
        let attrs: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
                                    kSecAttrKeySizeInBits as String: modulus.count * 8]
        return SecKeyCreateWithData(der as CFData, attrs as CFDictionary, nil)
    }
}

// MARK: - loopback OAuth callback server (127.0.0.1)

final class LoopbackServer: @unchecked Sendable {
    private let listener: NWListener
    private let q = DispatchQueue(label: "readit.oauth-callback")
    var port: UInt16 = 0
    var started = false
    private var waiter: CheckedContinuation<[String: String], Error>?
    private var result: [String: String]?

    private init(_ l: NWListener) { listener = l }

    static func start(preferredPort: UInt16) async throws -> LoopbackServer {
        do { return try await open(port: preferredPort) } catch { return try await open(port: 0) }
    }

    private static func open(port: UInt16) async throws -> LoopbackServer {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port) ?? .any)
        params.allowLocalEndpointReuse = false
        let l = try NWListener(using: params)
        let s = LoopbackServer(l)
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            l.stateUpdateHandler = { st in
                // runs on s.q
                switch st {
                case .ready:
                    if !s.started { s.started = true; s.port = l.port?.rawValue ?? port; c.resume() }
                case .failed(let e), .waiting(let e):
                    if !s.started { s.started = true; l.cancel(); c.resume(throwing: e) }
                case .cancelled:
                    if !s.started { s.started = true; c.resume(throwing: TranslateError.bad("listener cancelled")) }
                default: break
                }
            }
            l.newConnectionHandler = { conn in s.handle(conn) }
            l.start(queue: s.q)
        }
        return s
    }

    func waitForCallback(timeout: TimeInterval) async throws -> [String: String] {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<[String: String], Error>) in
            q.async {
                if let r = self.result { c.resume(returning: r); return }
                self.waiter = c
                self.q.asyncAfter(deadline: .now() + timeout) {
                    if let w = self.waiter { self.waiter = nil; w.resume(throwing: TranslateError.bad(L("登录超时，请重试"))) }
                }
            }
        }
    }

    func stop() { listener.cancel() }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: q)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 32_768) { data, _, _, _ in
            let req = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let line = req.split(separator: "\r\n").first.map(String.init) ?? ""
            let target = line.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            let comps = URLComponents(string: "http://127.0.0.1" + target)
            let isCallback = comps?.path == "/auth/callback"
            let html = isCallback
                ? "<html><head><meta charset='utf-8'><title>Readlet</title></head><body style='font:16px -apple-system;text-align:center;padding-top:80px'><h2>✓ Readlet</h2><p>可以回到 Readlet 了。You can return to Readlet now.</p></body></html>"
                : "not found"
            let head = "HTTP/1.1 \(isCallback ? "200 OK" : "404 Not Found")\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(Data(html.utf8).count)\r\nConnection: close\r\n\r\n"
            conn.send(content: Data((head + html).utf8), completion: .contentProcessed { _ in conn.cancel() })
            guard isCallback else { return }
            var r: [String: String] = [:]
            for item in comps?.queryItems ?? [] { r[item.name] = item.value ?? "" }
            if let w = self.waiter { self.waiter = nil; w.resume(returning: r) } else { self.result = r }
        }
    }
}
