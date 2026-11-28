import SwiftUI
import UIKit
import UserNotifications

// MARK: - Modèles

enum BuildState: String, Codable {
    case preparing, queued, running, success, failure, cancelled, error

    var isActive: Bool { self == .preparing || self == .queued || self == .running }

    var label: String {
        switch self {
        case .preparing: return "Préparation"
        case .queued: return "En attente"
        case .running: return "En cours"
        case .success: return "Réussi"
        case .failure: return "Échec"
        case .cancelled: return "Annulé"
        case .error: return "Erreur"
        }
    }
}

struct BuildJob: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var kind: String = ""
    var state: BuildState = .preparing
    var detail: String = ""
    var owner: String = ""
    var repo: String = ""
    var branch: String = ""
    var sha: String = ""
    var runId: Int? = nil
    var runURL: String? = nil
    var artifactDir: String? = nil   // relatif à Documents
    var log: String? = nil           // résumé du build (Markdown)
    var created: Date = Date()
    var finished: Date? = nil
    var slug: String? = nil
    var releaseURL: String? = nil
    var sourceReleaseId: Int? = nil
    var publicURL: String? = nil     // publication publique (release)
    var pubSource: String? = nil     // code nettoyé en attente de publication (relatif à Documents)
    var redacted: Int? = nil         // éléments sensibles retirés du code publié
}

struct InboxItem: Identifiable, Equatable {
    var id: String            // chemin complet
    var name: String
    var isFolder: Bool
    var supported: Bool
    var ready: Bool
}

struct GHRuns: Codable { let workflow_runs: [GHRun] }
struct GHRun: Codable { let id: Int; let status: String; let conclusion: String?; let html_url: String }
struct GHArtifacts: Codable { let artifacts: [GHArtifact] }
struct GHArtifact: Codable { let id: Int; let name: String; let expired: Bool }
struct GHJobs: Codable { let jobs: [GHJob] }
struct GHJob: Codable { let id: Int; let name: String; let conclusion: String?; let steps: [GHStep]? }
struct GHStep: Codable { let name: String; let conclusion: String? }
struct GHIdOnly: Codable { let id: Int }
struct GHReleaseFull: Codable { let id: Int; let html_url: String; let assets: [GHAssetFull] }
struct GHAssetFull: Codable { let id: Int; let name: String; let size: Int }

// MARK: - Réglages

enum BuildSettings {
    static var repoName: String {
        let v = (UserDefaults.standard.string(forKey: "build_repo") ?? "")
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: " ", with: "-")
        return v.isEmpty ? "gitdesk-builds" : v
    }
    static var isPrivate: Bool { UserDefaults.standard.object(forKey: "build_private") as? Bool ?? true }
    static var publish: Bool { UserDefaults.standard.object(forKey: "build_publish") as? Bool ?? true }
    static var clean: Bool { UserDefaults.standard.object(forKey: "build_clean") as? Bool ?? true }
    static var ntfyOn: Bool { UserDefaults.standard.object(forKey: "build_ntfy") as? Bool ?? true }
    static var auto: Bool { UserDefaults.standard.object(forKey: "build_auto") as? Bool ?? true }
    static var topic: String {
        if let t = UserDefaults.standard.string(forKey: "build_topic"), !t.isEmpty { return t }
        let chars = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        let t = "gitdesk-" + String((0..<16).map { _ in chars.randomElement()! })
        UserDefaults.standard.set(t, forKey: "build_topic")
        return t
    }
}

// MARK: - Dossiers

enum BuildPaths {
    private static func make(_ u: URL) -> URL {
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    /// Dossier visible dans Fichiers : on y dépose archives et dossiers à compiler.
    static var root: URL { make(Paths.documents.appendingPathComponent("Builds", isDirectory: true)) }
    static var state: URL { make(root.appendingPathComponent(".gitdesk", isDirectory: true)) }
    static var work: URL { make(state.appendingPathComponent("work", isDirectory: true)) }
    static var done: URL { make(root.appendingPathComponent("Traitées", isDirectory: true)) }
    static var results: URL { make(root.appendingPathComponent("Résultats", isDirectory: true)) }
    /// Code nettoyé en attente de publication publique.
    static var pub: URL { make(state.appendingPathComponent("pub", isDirectory: true)) }

    static func relative(_ url: URL) -> String {
        let prefix = Paths.documents.path + "/"
        return url.path.hasPrefix(prefix) ? String(url.path.dropFirst(prefix.count)) : url.path
    }
}

enum Inbox {
    static let reserved: Set<String> = ["Traitées", "Résultats"]

    static func supported(_ name: String, folder: Bool) -> Bool {
        if folder { return true }
        let l = name.lowercased()
        return l.hasSuffix(".zip") || l.hasSuffix(".tar") || l.hasSuffix(".tar.gz") || l.hasSuffix(".tgz")
    }

    /// Empreinte (taille, nombre, date) et date de dernière modification, pour savoir si la copie est terminée.
    static func fingerprint(_ url: URL, folder: Bool) -> (String, Date) {
        let fm = FileManager.default
        func attrs(_ u: URL) -> (Int, Date) {
            let a = try? fm.attributesOfItem(atPath: u.path)
            return ((a?[.size] as? NSNumber)?.intValue ?? 0, (a?[.modificationDate] as? Date) ?? Date.distantPast)
        }
        if !folder {
            let (s, d) = attrs(url)
            return ("\(s)-\(Int(d.timeIntervalSince1970))", d)
        }
        var total = 0
        var count = 0
        var newest = Date.distantPast
        if let en = fm.enumerator(atPath: url.path) {
            for case let rel as String in en {
                count += 1
                if count > 50_000 { break }
                let (s, d) = attrs(url.appendingPathComponent(rel))
                total += s
                if d > newest { newest = d }
            }
        }
        return ("\(total)-\(count)-\(Int(newest.timeIntervalSince1970))", newest)
    }
}

// MARK: - Téléchargements authentifiés (sans propager le jeton vers un autre hôte)

final class RedirectGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        var r = request
        if request.url?.host != task.originalRequest?.url?.host {
            r.setValue(nil, forHTTPHeaderField: "Authorization")
        }
        completionHandler(r)
    }
}

// MARK: - Temps d'exécution en arrière-plan

@MainActor
final class BackgroundGuard {
    private var task: UIBackgroundTaskIdentifier = .invalid
    private let key = UUID().uuidString
    func begin() {
        task = UIApplication.shared.beginBackgroundTask(withName: "gitdesk-build") { [weak self] in
            self?.endTask()
        }
        // Écran allumé + maintien en arrière-plan tant que la tâche dure.
        ActivityKeeper.shared.hold(key)
    }
    private func endTask() {
        if task != .invalid {
            UIApplication.shared.endBackgroundTask(task)
            task = .invalid
        }
    }
    func end() {
        endTask()
        ActivityKeeper.shared.release(key)
    }
}

// MARK: - Moteur

@MainActor
final class BuildCenter: ObservableObject {
    @Published var jobs: [BuildJob] = []
    @Published var inbox: [InboxItem] = []
    @Published var notice: String?

    private var running: Set<String> = []
    private var inFlight: Set<String> = []
    private var ignored: Set<String> = []
    private var seen: [String: (fp: String, stable: Int)] = [:]
    private var started = false
    private var scanning = false
    private weak var session: Session?

    private var file: URL { BuildPaths.state.appendingPathComponent("jobs.json") }

    init() {
        _ = BuildPaths.done
        _ = BuildPaths.results
        migrateOldState()
        load()
    }

    // MARK: Persistance

    private func migrateOldState() {
        let fm = FileManager.default
        let old = BuildPaths.root.appendingPathComponent("jobs.json")
        if fm.fileExists(atPath: old.path), !fm.fileExists(atPath: file.path) {
            try? fm.moveItem(at: old, to: file)
        }
        try? fm.removeItem(at: BuildPaths.root.appendingPathComponent("work"))
    }

    private func load() {
        guard let d = try? Data(contentsOf: file),
              var list = try? JSONDecoder().decode([BuildJob].self, from: d) else { return }
        for i in list.indices where list[i].state == .preparing {
            list[i].state = .error
            list[i].detail = "Interrompu : l'app a été fermée pendant la préparation."
            list[i].finished = Date()
        }
        jobs = list
    }

    private func save() {
        if let d = try? JSONEncoder().encode(jobs) { try? d.write(to: file, options: .atomic) }
    }

    private func mutate(_ id: String, _ f: (inout BuildJob) -> Void) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        f(&jobs[i])
        save()
    }

    private func setDetail(_ id: String, _ text: String) { mutate(id) { $0.detail = text } }

    private func fail(_ id: String, _ message: String, final: Bool = true) {
        let name = jobs.first { $0.id == id }?.name ?? "Projet"
        mutate(id) {
            $0.state = .error
            $0.detail = message
            if final { $0.finished = Date() }
        }
        notify("Compilation interrompue", "\(name) : \(message)")
    }

    // MARK: Notifications locales

    private func notify(_ title: String, _ body: String) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }

    // MARK: Surveillance du dossier Builds

    func start(session: Session) {
        self.session = session
        guard !started else { return }
        started = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        Task {
            while true {
                await self.scanInbox()
                try? await Task.sleep(nanoseconds: 2_500_000_000)
            }
        }
    }

    private func inboxDirs() -> [URL] {
        var dirs: [URL] = [BuildPaths.root]
        let docs = Paths.documents
        let names = (try? FileManager.default.contentsOfDirectory(atPath: docs.path)) ?? []
        for n in names where ["build", "builds"].contains(n.lowercased()) {
            let u = docs.appendingPathComponent(n, isDirectory: true)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir), isDir.boolValue,
               u.standardizedFileURL.path != BuildPaths.root.standardizedFileURL.path {
                dirs.append(u)
            }
        }
        return dirs
    }

    func scanInbox() async {
        guard !scanning, let session, session.api != nil else { return }
        scanning = true
        defer { scanning = false }

        let fm = FileManager.default
        var found: [(url: URL, isFolder: Bool)] = []
        for dir in inboxDirs() {
            let names = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
            for n in names where !n.hasPrefix(".") && !Inbox.reserved.contains(n) && n != "jobs.json" {
                let u = dir.appendingPathComponent(n)
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: u.path, isDirectory: &isDir) else { continue }
                found.append((u, isDir.boolValue))
            }
        }

        var items: [InboxItem] = []
        var alive: Set<String> = []
        for f in found {
            let path = f.url.path
            if inFlight.contains(path) || ignored.contains(path) { continue }
            alive.insert(path)
            let url = f.url
            let folder = f.isFolder
            let fpr = await Task.detached { Inbox.fingerprint(url, folder: folder) }.value
            var stable = 0
            if let p = seen[path], p.fp == fpr.0 { stable = p.stable + 1 }
            seen[path] = (fpr.0, stable)
            let age = Date().timeIntervalSince(fpr.1)
            items.append(InboxItem(id: path, name: f.url.lastPathComponent, isFolder: f.isFolder,
                                   supported: Inbox.supported(f.url.lastPathComponent, folder: f.isFolder),
                                   ready: stable >= 1 && age > 2))
        }
        seen = seen.filter { alive.contains($0.key) }

        if BuildSettings.auto {
            for it in items where it.ready && it.supported {
                await consume(it, session: session)
            }
            items = items.filter { !($0.ready && $0.supported) }
        }
        if items != inbox { inbox = items }
    }

    func compileNow(_ item: InboxItem, session: Session) {
        Task { await self.consume(item, session: session) }
    }

    private func consume(_ item: InboxItem, session: Session) async {
        guard !inFlight.contains(item.id) else { return }
        inFlight.insert(item.id)
        defer { inFlight.remove(item.id) }
        await submitInbox(URL(fileURLWithPath: item.id), isFolder: item.isFolder, session: session)
        inbox.removeAll { $0.id == item.id }
    }

    private func submitInbox(_ url: URL, isFolder: Bool, session: Session) async {
        guard let api = session.api else { return }
        let fm = FileManager.default
        let id = UUID().uuidString
        let name = isFolder ? url.lastPathComponent : Archive.baseName(url)
        jobs.insert(BuildJob(id: id, name: name, detail: "Préparation…"), at: 0)
        save()

        do {
            let work = BuildPaths.work.appendingPathComponent(id, isDirectory: true)
            try fm.createDirectory(at: work, withIntermediateDirectories: true)

            // L'original est rangé dans « Traitées » pour ne pas être détecté une seconde fois.
            var dest = BuildPaths.done.appendingPathComponent(url.lastPathComponent)
            if fm.fileExists(atPath: dest.path) {
                let stamp = Int(Date().timeIntervalSince1970)
                let ext = url.pathExtension
                let base = url.deletingPathExtension().lastPathComponent
                dest = BuildPaths.done.appendingPathComponent(ext.isEmpty || isFolder ? "\(url.lastPathComponent)-\(stamp)" : "\(base)-\(stamp).\(ext)")
            }
            do { try fm.moveItem(at: url, to: dest) } catch {
                dest = url
                ignored.insert(url.path)
            }

            let archive: URL
            if isFolder {
                setDetail(id, "Compression du dossier…")
                let zipURL = work.appendingPathComponent("\(safeFileName(name)).zip")
                let source = dest
                _ = try await Task.detached(priority: .userInitiated) { () throws -> Int in
                    try ZipWriter.zip(directory: source, to: zipURL)
                }.value
                archive = zipURL
            } else {
                archive = work.appendingPathComponent(url.lastPathComponent)
                try fm.copyItem(at: dest, to: archive)
            }
            Task { await self.process(id: id, archive: archive, api: api) }
        } catch {
            fail(id, error.localizedDescription)
        }
    }

    // MARK: Soumission depuis le sélecteur de fichiers

    func submit(_ src: URL, session: Session) throws {
        guard let api = session.api else { throw APIError.message("Connecte-toi à GitHub d'abord.") }
        let id = UUID().uuidString
        let work = BuildPaths.work.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

        let scoped = src.startAccessingSecurityScopedResource()
        defer { if scoped { src.stopAccessingSecurityScopedResource() } }
        let dest = work.appendingPathComponent(src.lastPathComponent)
        try FileManager.default.copyItem(at: src, to: dest)

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        jobs.insert(BuildJob(id: id, name: Archive.baseName(src), detail: "Préparation…"), at: 0)
        save()
        Task { await self.process(id: id, archive: dest, api: api) }
    }

    // MARK: GitHub : vérifications et dépôt

    private func checkScopes(_ api: GitHubAPI) async throws {
        guard let url = URL(string: "https://api.github.com/user") else { return }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(api.token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (_, resp) = try await URLSession.shared.data(for: req)
        guard let h = resp as? HTTPURLResponse, let scopes = h.value(forHTTPHeaderField: "X-OAuth-Scopes"), !scopes.isEmpty else { return }
        let list = scopes.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        if !list.contains("workflow") {
            throw APIError.message("Ton token GitHub n'a pas la portée « workflow ». Crée un token avec les portées « repo » et « workflow », puis reconnecte-toi (Paramètres).")
        }
    }

    private func ensureRepo(_ api: GitHubAPI, login: String) async throws -> (repo: RepoRef, head: String) {
        let repo = RepoRef(owner: login, name: BuildSettings.repoName)
        var created = false
        do {
            _ = try await api.defaultBranch(repo)
        } catch let e as APIError {
            guard case .http(let code, _) = e, code == 404 else { throw e }
            let body: [String: Any] = ["name": repo.name, "private": BuildSettings.isPrivate,
                                       "auto_init": true, "description": "Compilations GitDesk"]
            _ = try await api.send("POST", "/user/repos", body: body)
            created = true
        }
        if created { try? await Task.sleep(nanoseconds: 2_000_000_000) }
        var head = ""
        for attempt in 0..<6 {
            do {
                let branch = try await api.defaultBranch(repo)
                head = try await api.headSha(repo, branch)
                break
            } catch {
                if attempt == 5 { throw error }
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
        return (repo, head)
    }

    /// Envoie l'archive comme fichier d'une release brouillon (jusqu'à 2 Go, sans passer par la mémoire).
    private func uploadSource(id: String, api: GitHubAPI, repo: RepoRef, archive: URL, assetName: String) async throws -> (releaseId: Int, assetId: Int) {
        let tag = "src-\(String(id.prefix(8)).lowercased())"
        let body: [String: Any] = ["tag_name": tag, "name": "Source temporaire GitDesk", "draft": true,
                                   "body": "Supprimée automatiquement après la compilation."]
        let d = try await api.send("POST", "/repos/\(repo.owner)/\(repo.name)/releases", body: body)
        let rel = try JSONDecoder().decode(GHIdOnly.self, from: d)
        mutate(id) { $0.sourceReleaseId = rel.id }

        guard let url = URL(string: "https://uploads.github.com/repos/\(repo.owner)/\(repo.name)/releases/\(rel.id)/assets?name=\(assetName)") else {
            throw APIError.message("URL d'envoi invalide.")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 3600
        req.setValue("Bearer \(api.token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")

        var lastError: Error = APIError.message("Envoi de l'archive impossible.")
        for attempt in 0..<2 {
            do {
                let (data, resp) = try await URLSession.shared.upload(for: req, fromFile: archive)
                if let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                    let a = try JSONDecoder().decode(GHIdOnly.self, from: data)
                    return (rel.id, a.id)
                }
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                lastError = APIError.http(code, String(data: data, encoding: .utf8) ?? "")
            } catch {
                lastError = error
            }
            if attempt == 0 { try? await Task.sleep(nanoseconds: 3_000_000_000) }
        }
        throw lastError
    }

    private func cleanupSource(id: String, api: GitHubAPI) {
        guard let j = jobs.first(where: { $0.id == id }), let rid = j.sourceReleaseId, !j.owner.isEmpty else { return }
        mutate(id) { $0.sourceReleaseId = nil }
        let path = "/repos/\(j.owner)/\(j.repo)/releases/\(rid)"
        Task { _ = try? await api.send("DELETE", path) }
    }

    // MARK: Traitement d'une archive

    private func process(id: String, archive: URL, api: GitHubAPI) async {
        running.insert(id)
        let bg = BackgroundGuard()
        bg.begin()
        let work = archive.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: work) }
        do {
            let login = try await api.me()
            try await checkScopes(api)

            let size = (try? archive.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if size > 1_900_000_000 { throw APIError.message("Archive trop volumineuse (2 Go maximum pour GitHub).") }

            let lower = archive.lastPathComponent.lowercased()
            let assetName: String
            let extract: String
            if lower.hasSuffix(".zip") {
                assetName = "source.zip"; extract = "unzip -q source-archive -d src"
            } else if lower.hasSuffix(".tar.gz") || lower.hasSuffix(".tgz") {
                assetName = "source.tar.gz"; extract = "tar -xf source-archive -C src"
            } else if lower.hasSuffix(".tar") {
                assetName = "source.tar"; extract = "tar -xf source-archive -C src"
            } else {
                throw APIError.message("Format non pris en charge : utilise un dossier, ZIP, TAR ou TAR.GZ.")
            }

            setDetail(id, "Analyse du projet…")
            let ex = work.appendingPathComponent("src", isDirectory: true)
            let result = try await Task.detached(priority: .userInitiated) { () throws -> (BuildPlan, String) in
                _ = try Archive.extract(archive, to: ex)
                let f = Detector.flatten(ex)
                let root = (["src"] + f.rel).joined(separator: "/")
                return (try Detector.plan(root: f.url, rootPath: root), root)
            }.value
            let plan = result.0
            let rootPath = result.1

            if BuildSettings.clean {
                setDetail(id, "Préparation de la version publique…")
                let tokenCopy = api.token
                let pubZip = BuildPaths.pub.appendingPathComponent("\(id)-source.zip")
                let rep = await Task.detached(priority: .userInitiated) { () -> SourceSanitizer.Report? in
                    let r = SourceSanitizer.clean(ex, token: tokenCopy)
                    do { _ = try ZipWriter.zip(directory: ex, to: pubZip); return r } catch { return nil }
                }.value
                if let rep = rep {
                    mutate(id) { $0.pubSource = BuildPaths.relative(pubZip); $0.redacted = rep.total }
                }
            }

            let name = jobs.first { $0.id == id }?.name ?? "Projet"
            let slug = asciiSlug(name)
            mutate(id) { $0.kind = plan.kind.rawValue; $0.slug = slug }

            let (repo, head) = try await ensureRepo(api, login: login)
            mutate(id) { $0.owner = repo.owner; $0.repo = repo.name }

            let mb = max(1, size / 1_000_000)
            setDetail(id, "Envoi de l'archive (\(mb) Mo)… garde l'app ouverte")
            let up = try await uploadSource(id: id, api: api, repo: repo, archive: archive, assetName: assetName)

            setDetail(id, "Création du workflow…")
            let topic: String? = BuildSettings.ntfyOn ? BuildSettings.topic : nil
            let yaml = WorkflowBuilder.make(plan: plan, p: WorkflowBuilder.Params(
                name: name, slug: slug, kind: plan.kind.rawValue, root: rootPath, extract: extract,
                topic: topic, assetId: up.assetId, releaseId: up.releaseId))

            let branch = "build/\(slug)-\(String(id.prefix(6)).lowercased())"
            let commit: String
            do {
                let ymlSha = try await api.createBlob(repo, Data(yaml.utf8))
                let entries: [[String: String]] = [
                    ["path": ".github/workflows/gitdesk-build.yml", "mode": "100644", "type": "blob", "sha": ymlSha]
                ]
                let body: [String: Any] = ["tree": entries]
                let td = try await api.send("POST", "/repos/\(repo.owner)/\(repo.name)/git/trees", body: body)
                let tree = try JSONDecoder().decode(GHSha.self, from: td).sha
                commit = try await api.createCommit(repo, message: "Build \(name)", tree: tree, parent: head)
                try await api.createBranch(repo, name: branch, sha: commit)
            } catch let e as APIError {
                throw APIError.message(e.localizedDescription + " Vérifie que ton token a les portées « repo » et « workflow ».")
            }

            mutate(id) {
                $0.branch = branch; $0.sha = commit
                $0.state = .queued; $0.detail = "En attente d'un serveur…"
            }
            try? FileManager.default.removeItem(at: work)
            await track(id: id, api: api, repo: repo, sha: commit, started: Date())
        } catch {
            cleanupSource(id: id, api: api)
            fail(id, error.localizedDescription)
        }
        running.remove(id)
        bg.end()
    }

    // MARK: Reprise (réouverture de l'app ou tirer pour actualiser)

    func resumePending(session: Session) {
        guard let api = session.api else { return }
        for j in jobs where !j.sha.isEmpty && j.finished == nil && !running.contains(j.id)
            && (j.state == .queued || j.state == .running || j.state == .error) {
            running.insert(j.id)
            let id = j.id
            let repo = RepoRef(owner: j.owner, name: j.repo)
            let sha = j.sha
            let started = j.created
            mutate(id) { $0.state = .queued; $0.detail = "Reprise du suivi…" }
            Task {
                let bg = BackgroundGuard()
                bg.begin()
                await self.track(id: id, api: api, repo: repo, sha: sha, started: started)
                self.running.remove(id)
                bg.end()
            }
        }
    }

    // MARK: Suivi du workflow

    private func track(id: String, api: GitHubAPI, repo: RepoRef, sha: String, started: Date) async {
        let base = "/repos/\(repo.owner)/\(repo.name)"
        var failures = 0
        while true {
            if Task.isCancelled { return }
            do {
                let d = try await api.send("GET", base + "/actions/runs", query: ["head_sha": sha, "per_page": "10"])
                let runs = try JSONDecoder().decode(GHRuns.self, from: d).workflow_runs
                failures = 0
                if runs.isEmpty {
                    if Date().timeIntervalSince(started) > 240 {
                        cleanupSource(id: id, api: api)
                        fail(id, "Aucun workflow n'a démarré. Vérifie que les Actions sont activées sur le dépôt de compilation.")
                        return
                    }
                } else {
                    let run = runs[0]
                    mutate(id) { $0.runId = run.id; $0.runURL = run.html_url }
                    if run.status == "completed" {
                        await finish(id: id, api: api, repo: repo, run: run)
                        return
                    }
                    let st: BuildState = run.status == "in_progress" ? .running : .queued
                    let text = st == .running ? "Compilation en cours…" : "En attente d'un serveur…"
                    mutate(id) { $0.state = st; $0.detail = text }
                }
            } catch {
                failures += 1
                if failures >= 8 {
                    fail(id, "Suivi interrompu : \(error.localizedDescription). Tire la liste vers le bas pour reprendre.", final: false)
                    return
                }
            }
            let waited = Date().timeIntervalSince(started)
            let seconds: UInt64 = waited < 300 ? 10 : 20
            try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
        }
    }

    private func finish(id: String, api: GitHubAPI, repo: RepoRef, run: GHRun) async {
        let ok = run.conclusion == "success"
        let job = jobs.first { $0.id == id }
        let name = job?.name ?? "Projet"
        let slug = job?.slug ?? asciiSlug(name)
        cleanupSource(id: id, api: api)

        if ok {
            setDetail(id, "Récupération du résultat…")
            var dir: String? = nil
            var summary: String? = nil
            var relURL: String? = nil
            do {
                let r = try await fetchReleaseResult(api: api, repo: repo, slug: slug, name: name, id: id, success: true)
                dir = r.dir; summary = r.summary; relURL = r.url
            } catch {
                // Repli : artefact du workflow
                do {
                    dir = try await fetchArtifact(id: id, api: api, repo: repo, runId: run.id, name: name)
                } catch {
                    summary = "Résultat non récupéré : \(error.localizedDescription)"
                }
            }
            let text = dir == nil ? "Terminé" : "Terminé : résultat prêt"
            mutate(id) {
                $0.state = .success
                $0.detail = text
                $0.artifactDir = dir
                $0.log = summary
                $0.releaseURL = relURL
                $0.finished = Date()
            }
            await publishIfNeeded(id: id, api: api)
            notify("Compilation réussie", name)
        } else {
            var summary: String? = nil
            var relURL: String? = nil
            if let r = try? await fetchReleaseResult(api: api, repo: repo, slug: slug, name: name, id: id, success: false) {
                summary = r.summary
                relURL = r.url
            }
            let fs = await failureSummary(api: api, repo: repo, runId: run.id)
            if summary == nil { summary = fs.log }
            let c = run.conclusion ?? "inconnu"
            let text: String
            if let step = fs.step { text = "Échec à l'étape « \(step) »" } else { text = "Échec (\(c))" }
            let state: BuildState = c == "cancelled" ? .cancelled : .failure
            mutate(id) {
                $0.state = state
                $0.detail = text
                $0.log = summary
                $0.releaseURL = relURL
                $0.finished = Date()
            }
            notify(c == "cancelled" ? "Compilation annulée" : "Compilation échouée", name)
        }
    }

    // MARK: Résultat : release « <slug>-latest »

    private func authorizedData(api: GitHubAPI, url: URL, accept: String) async throws -> Data {
        var req = URLRequest(url: url)
        req.setValue("Bearer \(api.token)", forHTTPHeaderField: "Authorization")
        req.setValue(accept, forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        let (data, resp) = try await URLSession.shared.data(for: req, delegate: RedirectGuard())
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw APIError.message("Téléchargement refusé.")
        }
        return data
    }

    private func downloadAsset(api: GitHubAPI, repo: RepoRef, assetId: Int) async throws -> URL {
        guard let url = URL(string: "https://api.github.com/repos/\(repo.owner)/\(repo.name)/releases/assets/\(assetId)") else {
            throw APIError.message("URL invalide.")
        }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(api.token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        let (tmp, resp) = try await URLSession.shared.download(for: req, delegate: RedirectGuard())
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw APIError.message("Téléchargement du fichier refusé.")
        }
        return tmp
    }

    private func fetchReleaseResult(api: GitHubAPI, repo: RepoRef, slug: String, name: String, id: String,
                                    success: Bool) async throws -> (dir: String?, summary: String?, url: String) {
        let tag = success ? "\(slug)-latest" : "\(slug)-latest-echec"
        let d = try await api.send("GET", "/repos/\(repo.owner)/\(repo.name)/releases/tags/\(tag)")
        let rel = try JSONDecoder().decode(GHReleaseFull.self, from: d)

        var summary: String? = nil
        if let a = rel.assets.first(where: { $0.name == "build-summary.md" }) {
            let tmp = try await downloadAsset(api: api, repo: repo, assetId: a.id)
            summary = try? String(contentsOf: tmp, encoding: .utf8)
            try? FileManager.default.removeItem(at: tmp)
        }

        var dirRel: String? = nil
        if success {
            let files = rel.assets.filter { $0.name != "build-summary.md" && !$0.name.hasSuffix(".txt.gz") }
            if !files.isEmpty {
                let dir = BuildPaths.results.appendingPathComponent("\(safeFileName(name))-\(String(id.prefix(6)))", isDirectory: true)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                for a in files {
                    let tmp = try await downloadAsset(api: api, repo: repo, assetId: a.id)
                    let dest = dir.appendingPathComponent(safeFileName(a.name))
                    try? FileManager.default.removeItem(at: dest)
                    try FileManager.default.moveItem(at: tmp, to: dest)
                    if a.name == "build-output.zip" {
                        let ok = await Task.detached { () -> Bool in
                            (try? Archive.extract(dest, to: dir)) != nil
                        }.value
                        if ok { try? FileManager.default.removeItem(at: dest) }
                    }
                }
                dirRel = BuildPaths.relative(dir)
            }
        }
        return (dirRel, summary, rel.html_url)
    }

    // MARK: Repli : artefact du workflow

    private func fetchArtifact(id: String, api: GitHubAPI, repo: RepoRef, runId: Int, name: String) async throws -> String? {
        let base = "/repos/\(repo.owner)/\(repo.name)"
        let d = try await api.send("GET", base + "/actions/runs/\(runId)/artifacts")
        let list = try JSONDecoder().decode(GHArtifacts.self, from: d).artifacts.filter { !$0.expired }
        guard let art = list.first, let url = URL(string: "https://api.github.com\(base)/actions/artifacts/\(art.id)/zip") else { return nil }

        var req = URLRequest(url: url)
        req.setValue("Bearer \(api.token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        let (tmp, resp) = try await URLSession.shared.download(for: req, delegate: RedirectGuard())
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw APIError.message("Téléchargement du résultat refusé.")
        }

        let dir = BuildPaths.results.appendingPathComponent("\(safeFileName(name))-\(String(id.prefix(6)))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let zip = dir.appendingPathComponent("\(safeFileName(art.name)).zip")
        try? FileManager.default.removeItem(at: zip)
        try FileManager.default.moveItem(at: tmp, to: zip)

        let extracted = await Task.detached { () -> Bool in
            (try? Archive.extract(zip, to: dir)) != nil
        }.value
        if extracted { try? FileManager.default.removeItem(at: zip) }
        return BuildPaths.relative(dir)
    }

    private func failureSummary(api: GitHubAPI, repo: RepoRef, runId: Int) async -> (step: String?, log: String?) {
        let base = "/repos/\(repo.owner)/\(repo.name)"
        do {
            let d = try await api.send("GET", base + "/actions/runs/\(runId)/jobs")
            let list = try JSONDecoder().decode(GHJobs.self, from: d).jobs
            guard let j = list.first(where: { $0.conclusion == "failure" }) ?? list.first else { return (nil, nil) }
            let step = j.steps?.first(where: { $0.conclusion == "failure" })?.name
            var log: String? = nil
            if let url = URL(string: "https://api.github.com\(base)/actions/jobs/\(j.id)/logs"),
               let ld = try? await authorizedData(api: api, url: url, accept: "application/vnd.github+json") {
                let text = String(decoding: ld, as: UTF8.self)
                let lines = text.split(separator: "\n", omittingEmptySubsequences: true).suffix(60).map { l -> String in
                    String(l).replacingOccurrences(of: #"^\d{4}-\d{2}-\d{2}T[\d:.]+Z "#, with: "", options: .regularExpression)
                }
                log = String(lines.joined(separator: "\n").suffix(5000))
            }
            return (step, log)
        } catch {
            return (nil, nil)
        }
    }

    // MARK: Publication publique

    func publishNow(_ id: String, session: Session) {
        guard let api = session.api else { return }
        Task {
            let bg = BackgroundGuard()
            bg.begin()
            await publishIfNeeded(id: id, api: api, force: true)
            bg.end()
        }
    }

    private func publishIfNeeded(id: String, api: GitHubAPI, force: Bool = false) async {
        guard force || BuildSettings.publish, let j = jobs.first(where: { $0.id == id }), j.state == .success else { return }
        if j.publicURL != nil && !force { return }
        let prev = j.detail
        setDetail(id, "Publication publique…")
        let fm = FileManager.default
        var files: [URL] = []
        var tempZip: URL? = nil
        if let rel = j.artifactDir {
            let dir = Paths.documents.appendingPathComponent(rel)
            let all = ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
                .filter { !$0.lastPathComponent.hasPrefix(".") && !$0.lastPathComponent.contains("-source.") && $0.lastPathComponent != "build-summary.md" }
            let simple = all.count <= 10 && all.allSatisfy { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true }
            if simple {
                files = all
            } else if !all.isEmpty {
                let z = fm.temporaryDirectory.appendingPathComponent("\(asciiSlug(j.name))-resultat-\(String(id.prefix(4))).zip")
                let ok = await Task.detached { () -> Bool in (try? ZipWriter.zip(directory: dir, to: z)) != nil }.value
                if ok { files = [z]; tempZip = z }
            }
        }
        var source: URL? = nil
        if let p = j.pubSource {
            let u = Paths.documents.appendingPathComponent(p)
            if fm.fileExists(atPath: u.path) { source = u }
        }
        var login = j.owner
        if login.isEmpty { login = (try? await api.me()) ?? "" }
        do {
            let url = try await Publisher.publish(api: api, login: login, privateName: j.repo, name: j.name,
                                                  slug: j.slug ?? asciiSlug(j.name), kind: j.kind, id: id,
                                                  files: files, source: source, redacted: j.redacted ?? 0)
            mutate(id) { $0.publicURL = url; $0.detail = prev }
            if let src = source {
                try? fm.removeItem(at: src)
                mutate(id) { $0.pubSource = nil }
            }
        } catch {
            let msg = error.localizedDescription
            mutate(id) { $0.detail = prev; $0.log = ($0.log ?? "") + "\nPublication publique : " + msg }
            notify("Publication impossible", "\(j.name) : \(msg)")
        }
        if let z = tempZip { try? fm.removeItem(at: z) }
    }

    // MARK: Actions

    func cancel(_ job: BuildJob, session: Session) {
        guard let api = session.api, let runId = job.runId, !job.owner.isEmpty else { return }
        let path = "/repos/\(job.owner)/\(job.repo)/actions/runs/\(runId)/cancel"
        Task { _ = try? await api.send("POST", path) }
    }

    func delete(_ id: String, session: Session) {
        guard let j = jobs.first(where: { $0.id == id }) else { return }
        if let d = j.artifactDir {
            try? FileManager.default.removeItem(at: Paths.documents.appendingPathComponent(d))
        }
        if let p = j.pubSource { try? FileManager.default.removeItem(at: Paths.documents.appendingPathComponent(p)) }
        if !j.branch.isEmpty, let api = session.api {
            let r = RepoRef(owner: j.owner, name: j.repo)
            let b = j.branch
            Task { try? await api.deleteBranch(r, name: b) }
        }
        jobs.removeAll { $0.id == id }
        save()
    }
}
