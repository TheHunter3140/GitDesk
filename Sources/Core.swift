import Foundation
import Security

enum Paths {
    static var documents: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    static var workspaces: URL { make("Workspaces") }
    static var downloads: URL { make("Téléchargements") }
    private static func make(_ n: String) -> URL {
        let d = documents.appendingPathComponent(n)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
}

enum Keychain {
    static func set(_ value: String, key: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: key]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        if SecItemAdd(add as CFDictionary, nil) != errSecSuccess {
            UserDefaults.standard.set(value, forKey: "kc_" + key) // repli si le Trousseau est refusé (IPA re-signé)
        }
    }
    static func get(_ key: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: key,
                                kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        if SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data {
            return String(data: d, encoding: .utf8)
        }
        return UserDefaults.standard.string(forKey: "kc_" + key)
    }
    static func remove(_ key: String) {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: key] as CFDictionary)
        UserDefaults.standard.removeObject(forKey: "kc_" + key)
    }
}

struct RepoRef: Codable, Hashable, Identifiable {
    var owner: String
    var name: String
    var id: String { "\(owner)/\(name)" }
}

struct GHOwner: Codable, Hashable { let login: String }
struct GHUser: Codable { let login: String }
struct GHSha: Codable { let sha: String }
struct GHPR: Codable { let html_url: String }
struct GHRepoInfo: Codable { let default_branch: String }

struct GHRepo: Codable, Identifiable, Hashable {
    let id: Int
    let name: String
    let full_name: String
    let default_branch: String
    let description: String?
    let owner: GHOwner
    let isPrivate: Bool
    enum CodingKeys: String, CodingKey {
        case id, name, full_name, default_branch, description, owner
        case isPrivate = "private"
    }
}

struct GHBranch: Codable, Identifiable, Hashable {
    let name: String
    var id: String { name }
}

struct GHCommitItem: Codable, Identifiable {
    let sha: String
    let commit: Inner
    var id: String { sha }
    struct Inner: Codable {
        let message: String
        let author: Who
        struct Who: Codable { let name: String; let date: String }
    }
}

struct GHCommitDetail: Codable {
    let sha: String
    let files: [File]?
    struct File: Codable, Identifiable {
        let filename: String
        let status: String
        let patch: String?
        var id: String { filename }
    }
}

struct GHRef: Codable { let object: Obj; struct Obj: Codable { let sha: String } }
struct GHCommitFull: Codable { let sha: String; let tree: GHSha }
struct GHBlob: Codable { let content: String; let encoding: String }
struct GHTree: Codable {
    let sha: String
    let tree: [Entry]
    let truncated: Bool?
    struct Entry: Codable { let path: String; let mode: String; let type: String; let sha: String? }
}

enum APIError: LocalizedError {
    case http(Int, String)
    case message(String)
    var errorDescription: String? {
        switch self {
        case .message(let m): return m
        case .http(let c, let body):
            var msg = body
            if let d = body.data(using: .utf8),
               let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
               let m = j["message"] as? String { msg = m }
            if c == 401 { return "Token refusé (401). \(msg)" }
            if c == 404 { return "GitHub 404 : introuvable ou accès refusé. Vérifie que ton token a la portée « repo » et que tu as les droits d'écriture sur ce dépôt (\(msg))." }
            if c == 403 { return "GitHub 403 : accès refusé ou limite atteinte (\(msg))." }
            if c == 422 && msg.lowercased().contains("fast forward") {
                return "La branche distante a avancé : fais un Pull avant d'envoyer."
            }
            return "GitHub \(c) : \(msg)"
        }
    }
}

extension Array {
    func chunked(_ n: Int) -> [[Element]] {
        stride(from: 0, to: count, by: n).map { Array(self[$0..<Swift.min($0 + n, count)]) }
    }
}

final class GitHubAPI: @unchecked Sendable {
    let token: String
    init(token: String) { self.token = token }

    private func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? s }
    private func p(_ r: RepoRef) -> String { "/repos/\(r.owner)/\(r.name)" }

    func send(_ method: String, _ path: String, body: [String: Any]? = nil, query: [String: String] = [:]) async throws -> Data {
        guard var comps = URLComponents(string: "https://api.github.com" + path) else { throw APIError.message("URL invalide") }
        if !query.isEmpty { comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        guard let url = comps.url else { throw APIError.message("URL invalide") }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        if let body {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw APIError.message("Réponse invalide") }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }

    func get<T: Decodable>(_ path: String, query: [String: String] = [:]) async throws -> T {
        try JSONDecoder().decode(T.self, from: try await send("GET", path, query: query))
    }

    func me() async throws -> String { let u: GHUser = try await get("/user"); return u.login }

    func repos() async throws -> [GHRepo] {
        var all: [GHRepo] = []
        for page in 1...5 {
            let r: [GHRepo] = try await get("/user/repos", query: ["per_page": "100", "page": "\(page)", "sort": "updated"])
            all += r
            if r.count < 100 { break }
        }
        return all
    }

    func branches(_ r: RepoRef) async throws -> [GHBranch] { try await get(p(r) + "/branches", query: ["per_page": "100"]) }
    func defaultBranch(_ r: RepoRef) async throws -> String { let i: GHRepoInfo = try await get(p(r)); return i.default_branch }

    func headSha(_ r: RepoRef, _ branch: String) async throws -> String {
        let ref: GHRef = try await get(p(r) + "/git/ref/heads/" + enc(branch))
        return ref.object.sha
    }
    func commit(_ r: RepoRef, _ sha: String) async throws -> GHCommitFull { try await get(p(r) + "/git/commits/" + sha) }
    func tree(_ r: RepoRef, _ sha: String) async throws -> GHTree { try await get(p(r) + "/git/trees/" + sha, query: ["recursive": "1"]) }

    func blob(_ r: RepoRef, _ sha: String) async throws -> Data {
        let b: GHBlob = try await get(p(r) + "/git/blobs/" + sha)
        guard let d = Data(base64Encoded: b.content, options: .ignoreUnknownCharacters) else { throw APIError.message("Blob illisible") }
        return d
    }

    func createBlob(_ r: RepoRef, _ data: Data) async throws -> String {
        let d = try await send("POST", p(r) + "/git/blobs", body: ["content": data.base64EncodedString(), "encoding": "base64"])
        return try JSONDecoder().decode(GHSha.self, from: d).sha
    }
    func createTree(_ r: RepoRef, base: String, entries: [[String: Any]]) async throws -> String {
        let d = try await send("POST", p(r) + "/git/trees", body: ["base_tree": base, "tree": entries])
        return try JSONDecoder().decode(GHSha.self, from: d).sha
    }
    func createCommit(_ r: RepoRef, message: String, tree: String, parent: String) async throws -> String {
        let d = try await send("POST", p(r) + "/git/commits", body: ["message": message, "tree": tree, "parents": [parent]])
        return try JSONDecoder().decode(GHSha.self, from: d).sha
    }
    func updateRef(_ r: RepoRef, branch: String, sha: String) async throws {
        _ = try await send("PATCH", p(r) + "/git/refs/heads/" + enc(branch), body: ["sha": sha, "force": false])
    }
    func createBranch(_ r: RepoRef, name: String, sha: String) async throws {
        _ = try await send("POST", p(r) + "/git/refs", body: ["ref": "refs/heads/" + name, "sha": sha])
    }
    func deleteBranch(_ r: RepoRef, name: String) async throws {
        _ = try await send("DELETE", p(r) + "/git/refs/heads/" + enc(name))
    }
    func commits(_ r: RepoRef, branch: String, page: Int) async throws -> [GHCommitItem] {
        try await get(p(r) + "/commits", query: ["sha": branch, "per_page": "30", "page": "\(page)"])
    }
    func commitDetail(_ r: RepoRef, sha: String) async throws -> GHCommitDetail { try await get(p(r) + "/commits/" + sha) }
    func createPR(_ r: RepoRef, title: String, head: String, base: String) async throws -> String {
        let d = try await send("POST", p(r) + "/pulls", body: ["title": title, "head": head, "base": base])
        return try JSONDecoder().decode(GHPR.self, from: d).html_url
    }
}
