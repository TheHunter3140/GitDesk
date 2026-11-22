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
    var log: String? = nil
    var created: Date = Date()
    var finished: Date? = nil
}

struct GHRuns: Codable { let workflow_runs: [GHRun] }
struct GHRun: Codable { let id: Int; let status: String; let conclusion: String?; let html_url: String }
struct GHArtifacts: Codable { let artifacts: [GHArtifact] }
struct GHArtifact: Codable { let id: Int; let name: String; let expired: Bool }
struct GHJobs: Codable { let jobs: [GHJob] }
struct GHJob: Codable { let id: Int; let name: String; let conclusion: String?; let steps: [GHStep]? }
struct GHStep: Codable { let name: String; let conclusion: String? }

// MARK: - Réglages

enum BuildSettings {
    static var repoName: String {
        let v = (UserDefaults.standard.string(forKey: "build_repo") ?? "")
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: " ", with: "-")
        return v.isEmpty ? "gitdesk-builds" : v
    }
    static var isPrivate: Bool { UserDefaults.standard.object(forKey: "build_private") as? Bool ?? true }
    static var ntfyOn: Bool { UserDefaults.standard.object(forKey: "build_ntfy") as? Bool ?? true }
    static var topic: String {
        if let t = UserDefaults.standard.string(forKey: "build_topic"), !t.isEmpty { return t }
        let chars = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        let t = "gitdesk-" + String((0..<16).map { _ in chars.randomElement()! })
        UserDefaults.standard.set(t, forKey: "build_topic")
        return t
    }
}

// MARK: - Temps d'exécution en arrière-plan

@MainActor
final class BackgroundGuard {
    private var task: UIBackgroundTaskIdentifier = .invalid
    func begin() {
        task = UIApplication.shared.beginBackgroundTask(withName: "gitdesk-build") { [weak self] in
            self?.end()
        }
    }
    func end() {
        if task != .invalid {
            UIApplication.shared.endBackgroundTask(task)
            task = .invalid
        }
    }
}

// MARK: - Moteur

@MainActor
final class BuildCenter: ObservableObject {
    @Published var jobs: [BuildJob] = []
    private var running: Set<String> = []
    private let store = Paths.documents.appendingPathComponent("Builds", isDirectory: true)
    private var file: URL { store.appendingPathComponent("jobs.json") }

    init() {
        try? FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        load()
    }

    // MARK: Persistance

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

    // MARK: Soumission

    func submit(_ src: URL, session: Session) throws {
        guard let api = session.api else { throw APIError.message("Connecte-toi à GitHub d'abord.") }
        let id = UUID().uuidString
        let work = store.appendingPathComponent("work", isDirectory: true).appendingPathComponent(id, isDirectory: true)
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

    private func process(id: String, archive: URL, api: GitHubAPI) async {
        running.insert(id)
        let bg = BackgroundGuard()
        bg.begin()
        let work = archive.deletingLastPathComponent()
        defer {
            try? FileManager.default.removeItem(at: work)
        }
        do {
            let login = try await api.me()
            try await checkScopes(api)

            let size = (try? archive.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if size > 50_000_000 { throw APIError.message("Archive trop volumineuse (50 Mo maximum). Retire les dossiers inutiles (node_modules, build, .git…).") }

            let lower = archive.lastPathComponent.lowercased()
            let archiveName: String
            let extract: String
            if lower.hasSuffix(".zip") {
                archiveName = "source.zip"; extract = #"unzip -q "source.zip" -d src"#
            } else if lower.hasSuffix(".tar.gz") || lower.hasSuffix(".tgz") {
                archiveName = "source.tar.gz"; extract = "tar -xzf source.tar.gz -C src"
            } else if lower.hasSuffix(".tar") {
                archiveName = "source.tar"; extract = "tar -xf source.tar -C src"
            } else {
                throw APIError.message("Format non pris en charge : utilise ZIP, TAR ou TAR.GZ.")
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

            let name = jobs.first { $0.id == id }?.name ?? "Projet"
            mutate(id) { $0.kind = plan.kind.rawValue; $0.detail = "Envoi vers GitHub…" }

            let topic: String? = BuildSettings.ntfyOn ? BuildSettings.topic : nil
            let yaml = WorkflowBuilder.make(plan: plan, root: rootPath, extract: extract, title: name, topic: topic)

            let (repo, head) = try await ensureRepo(api, login: login)
            let branch = "build/\(asciiSlug(name))-\(String(id.prefix(6)).lowercased())"
            let commit: String
            do {
                let data = try Data(contentsOf: archive, options: .mappedIfSafe)
                let zipSha = try await api.createBlob(repo, data)
                let ymlSha = try await api.createBlob(repo, Data(yaml.utf8))
                let entries: [[String: String]] = [
                    ["path": archiveName, "mode": "100644", "type": "blob", "sha": zipSha],
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
                $0.owner = repo.owner; $0.repo = repo.name; $0.branch = branch; $0.sha = commit
                $0.state = .queued; $0.detail = "En attente d'un serveur…"
            }
            try? FileManager.default.removeItem(at: work)
            await track(id: id, api: api, repo: repo, sha: commit, started: Date())
        } catch {
            fail(id, error.localizedDescription)
        }
        running.remove(id)
        bg.end()
    }

    // MARK: Reprise (après réouverture de l'app ou tirer pour actualiser)

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
        let name = jobs.first { $0.id == id }?.name ?? "Projet"
        if ok {
            setDetail(id, "Téléchargement du résultat…")
            var dir: String? = nil
            do {
                dir = try await fetchArtifact(id: id, api: api, repo: repo, runId: run.id, name: name)
            } catch {
                mutate(id) { $0.log = "Résultat non téléchargé : \(error.localizedDescription)" }
            }
            let text = dir == nil ? "Terminé" : "Terminé : résultat prêt"
            mutate(id) {
                $0.state = .success
                $0.detail = text
                $0.artifactDir = dir
                $0.finished = Date()
            }
            notify("Compilation réussie", name)
        } else {
            let summary = await failureSummary(api: api, repo: repo, runId: run.id)
            let c = run.conclusion ?? "inconnu"
            let text: String
            if let step = summary.step { text = "Échec à l'étape « \(step) »" } else { text = "Échec (\(c))" }
            let state: BuildState = c == "cancelled" ? .cancelled : .failure
            mutate(id) {
                $0.state = state
                $0.detail = text
                $0.log = summary.log
                $0.finished = Date()
            }
            notify(c == "cancelled" ? "Compilation annulée" : "Compilation échouée", name)
        }
    }

    // MARK: Résultat et journaux

    private func fetchArtifact(id: String, api: GitHubAPI, repo: RepoRef, runId: Int, name: String) async throws -> String? {
        let base = "/repos/\(repo.owner)/\(repo.name)"
        let d = try await api.send("GET", base + "/actions/runs/\(runId)/artifacts")
        let list = try JSONDecoder().decode(GHArtifacts.self, from: d).artifacts.filter { !$0.expired }
        guard let art = list.first, let url = URL(string: "https://api.github.com\(base)/actions/artifacts/\(art.id)/zip") else { return nil }

        var req = URLRequest(url: url)
        req.setValue("Bearer \(api.token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        let (tmp, resp) = try await URLSession.shared.download(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw APIError.message("Téléchargement du résultat refusé.")
        }

        let dir = Paths.downloads
            .appendingPathComponent("Builds", isDirectory: true)
            .appendingPathComponent("\(safeFileName(name))-\(String(id.prefix(6)))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let zip = dir.appendingPathComponent("\(safeFileName(art.name)).zip")
        try? FileManager.default.removeItem(at: zip)
        try FileManager.default.moveItem(at: tmp, to: zip)

        let extracted = await Task.detached { () -> Bool in
            (try? Archive.extract(zip, to: dir)) != nil
        }.value
        if extracted { try? FileManager.default.removeItem(at: zip) }

        let prefix = Paths.documents.path + "/"
        return dir.path.hasPrefix(prefix) ? String(dir.path.dropFirst(prefix.count)) : dir.path
    }

    private func failureSummary(api: GitHubAPI, repo: RepoRef, runId: Int) async -> (step: String?, log: String?) {
        let base = "/repos/\(repo.owner)/\(repo.name)"
        do {
            let d = try await api.send("GET", base + "/actions/runs/\(runId)/jobs")
            let list = try JSONDecoder().decode(GHJobs.self, from: d).jobs
            guard let j = list.first(where: { $0.conclusion == "failure" }) ?? list.first else { return (nil, nil) }
            let step = j.steps?.first(where: { $0.conclusion == "failure" })?.name
            var log: String? = nil
            if let ld = try? await api.send("GET", base + "/actions/jobs/\(j.id)/logs") {
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
        if !j.branch.isEmpty, let api = session.api {
            let r = RepoRef(owner: j.owner, name: j.repo)
            let b = j.branch
            Task { try? await api.deleteBranch(r, name: b) }
        }
        jobs.removeAll { $0.id == id }
        save()
    }
}
