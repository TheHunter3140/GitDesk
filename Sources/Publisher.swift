import Foundation

/// Publication PUBLIQUE : résultat compilé + code source nettoyé + description, dans un dépôt séparé.
/// Le dépôt privé de compilation n'est pas modifié.
enum Publisher {
    private struct Vis: Decodable { let `private`: Bool }
    private static let anon: [String: String] = ["name": "GitDesk", "email": "gitdesk@users.noreply.github.com"]

    static func repoName(privateName: String) -> String {
        var v = (UserDefaults.standard.string(forKey: "build_public_repo") ?? "")
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: " ", with: "-")
        if v.isEmpty { v = "gitdesk-public" }
        if v.lowercased() == privateName.lowercased() { v += "-public" }
        return v
    }

    static func ensureRepo(_ api: GitHubAPI, login: String, name: String) async throws -> RepoRef {
        let repo = RepoRef(owner: login, name: name)
        do {
            let d = try await api.send("GET", "/repos/\(login)/\(name)")
            if let v = try? JSONDecoder().decode(Vis.self, from: d), v.private {
                throw APIError.message("Le dépôt « \(name) » est privé. Choisis un autre nom pour le dépôt public (Compiler → réglages).")
            }
            return repo
        } catch let e as APIError {
            guard case .http(let code, _) = e, code == 404 else { throw e }
        }
        let body: [String: Any] = ["name": name, "private": false, "auto_init": false,
                                   "description": "Applications compilées et code source publiés avec GitDesk",
                                   "has_issues": false, "has_projects": false, "has_wiki": false]
        _ = try await api.send("POST", "/user/repos", body: body)
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        let readme = "# Publications GitDesk\n\nApplications compilées et leur code source, publiés avec GitDesk. Les clés, jetons et certificats sont retirés avant publication.\n"
        let c: [String: Any] = ["message": "Initialisation", "content": Data(readme.utf8).base64EncodedString(),
                                "author": anon, "committer": anon]
        _ = try await api.send("PUT", "/repos/\(login)/\(name)/contents/README.md", body: c)
        return repo
    }

    static func publish(api: GitHubAPI, login: String, privateName: String, name: String, slug: String, kind: String,
                        id: String, files: [URL], source: URL?, redacted: Int) async throws -> String {
        let repo = try await ensureRepo(api, login: login, name: repoName(privateName: privateName))
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd"
        let day = df.string(from: Date())
        let tag = "\(slug)-\(day)-\(String(id.prefix(4)).lowercased())"

        var lines = ["## \(name)", "", "Compilé avec GitDesk.", "",
                     "- **Type de projet** : \(kind.isEmpty ? "—" : kind)",
                     "- **Date** : \(day)"]
        for f in files {
            lines.append("- **Fichier** : `\(f.lastPathComponent)` (\(FSOps.format(FSOps.fileSize(f))))")
        }
        if source != nil {
            lines.append("- **Code source** : `\(slug)-source.zip`. Clés, jetons, certificats et identifiants ont été retirés avant publication"
                         + (redacted > 0 ? " (\(redacted) élément(s))." : "."))
        }
        let body: [String: Any] = ["tag_name": tag, "name": name, "body": lines.joined(separator: "\n"), "draft": false]
        let d = try await api.send("POST", "/repos/\(repo.owner)/\(repo.name)/releases", body: body)
        let rel = try JSONDecoder().decode(GHReleaseFull.self, from: d)

        var uploads = files.map { ($0, $0.lastPathComponent) }
        if let s = source { uploads.append((s, "\(slug)-source.zip")) }
        for (u, n) in uploads { try await upload(api, repo, rel.id, u, n) }
        return rel.html_url
    }

    private static func upload(_ api: GitHubAPI, _ repo: RepoRef, _ releaseId: Int, _ file: URL, _ name: String) async throws {
        let enc = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? name
        guard let url = URL(string: "https://uploads.github.com/repos/\(repo.owner)/\(repo.name)/releases/\(releaseId)/assets?name=\(enc)") else {
            throw APIError.message("URL d'envoi invalide.")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 3600
        req.setValue("Bearer \(api.token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        var last: Error = APIError.message("Envoi de « \(name) » impossible.")
        for attempt in 0..<2 {
            do {
                let (data, resp) = try await URLSession.shared.upload(for: req, fromFile: file)
                if let h = resp as? HTTPURLResponse, (200..<300).contains(h.statusCode) { return }
                last = APIError.http((resp as? HTTPURLResponse)?.statusCode ?? 0, String(data: data, encoding: .utf8) ?? "")
            } catch { last = error }
            if attempt == 0 { try? await Task.sleep(nanoseconds: 3_000_000_000) }
        }
        throw last
    }
}
