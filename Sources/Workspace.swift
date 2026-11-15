import Foundation
import CryptoKit
import UIKit

struct WSState: Codable {
    var branch: String
    var commitSha: String
    var treeSha: String
    var blobs: [String: String]
    var modes: [String: String]
}

struct Change: Identifiable, Hashable {
    enum Kind: String { case added = "A", modified = "M", deleted = "D" }
    let path: String
    let kind: Kind
    var id: String { path }
}

struct FileNode: Identifiable {
    let id: String
    let name: String
    let children: [FileNode]?
}

struct SearchHit: Identifiable {
    let id = UUID()
    let path: String
    let line: Int
    let text: String
}

struct HashEntry { var mtime: Double; var size: Int; var sha: String }

// MARK: - Accès disque (hors acteur principal)
enum FS {
    static func gitBlobSha(_ data: Data) -> String {
        var h = Insecure.SHA1()
        h.update(data: Data("blob \(data.count)\0".utf8))
        h.update(data: data)
        return h.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func rel(_ root: URL, _ url: URL) -> String {
        let rc = root.standardizedFileURL.pathComponents.count
        return url.standardizedFileURL.pathComponents.dropFirst(rc).joined(separator: "/")
    }

    static func scan(_ root: URL, cache: inout [String: HashEntry]) -> [String: String] {
        var out: [String: String] = [:]
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]
        guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else { return out }
        for case let url as URL in en {
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
            if url.lastPathComponent == ".DS_Store" { continue }
            let p = rel(root, url)
            let mt = v.contentModificationDate?.timeIntervalSince1970 ?? 0
            let sz = v.fileSize ?? 0
            if let c = cache[p], c.mtime == mt, c.size == sz { out[p] = c.sha; continue }
            guard let d = try? Data(contentsOf: url) else { continue }
            let sha = gitBlobSha(d)
            cache[p] = HashEntry(mtime: mt, size: sz, sha: sha)
            out[p] = sha
        }
        return out
    }

    static func nodes(root: URL, dir: URL) -> [FileNode] {
        let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        var out: [FileNode] = []
        for u in items where u.lastPathComponent != ".DS_Store" {
            let isDir = (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            out.append(FileNode(id: rel(root, u), name: u.lastPathComponent, children: isDir ? nodes(root: root, dir: u) : nil))
        }
        return out.sorted { a, b in
            let ka = a.children != nil ? 0 : 1, kb = b.children != nil ? 0 : 1
            if ka != kb { return ka < kb }
            return a.name.lowercased() < b.name.lowercased()
        }
    }

    static func grep(_ root: URL, _ q: String) -> [SearchHit] {
        guard !q.isEmpty, let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) else { return [] }
        var hits: [SearchHit] = []
        for case let url as URL in en {
            guard let v = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), v.isRegularFile == true,
                  (v.fileSize ?? 0) < 1_000_000,
                  let d = try? Data(contentsOf: url), let s = String(data: d, encoding: .utf8) else { continue }
            let path = rel(root, url)
            var n = 0
            for line in s.components(separatedBy: "\n") {
                n += 1
                if line.range(of: q, options: .caseInsensitive) != nil {
                    hits.append(SearchHit(path: path, line: n, text: line.trimmingCharacters(in: .whitespaces)))
                    if hits.count >= 300 { return hits }
                }
            }
        }
        return hits
    }
}

// MARK: - Diff
struct DiffLine: Identifiable {
    enum Kind { case same, add, del, gap }
    let id: Int
    let kind: Kind
    let text: String
}

enum DiffEngine {
    static func make(old: String, new: String, context: Int = 3) -> [DiffLine] {
        let a = old.isEmpty ? [] : old.components(separatedBy: "\n")
        let b = new.isEmpty ? [] : new.components(separatedBy: "\n")
        let d = b.difference(from: a)
        var removed = Set<Int>(), inserted = Set<Int>()
        for c in d {
            switch c {
            case .remove(let o, _, _): removed.insert(o)
            case .insert(let o, _, _): inserted.insert(o)
            }
        }
        var raw: [(DiffLine.Kind, String)] = []
        var i = 0, j = 0
        while i < a.count || j < b.count {
            if i < a.count && removed.contains(i) { raw.append((.del, a[i])); i += 1 }
            else if j < b.count && inserted.contains(j) { raw.append((.add, b[j])); j += 1 }
            else if i < a.count && j < b.count { raw.append((.same, b[j])); i += 1; j += 1 }
            else { break }
        }
        if !raw.contains(where: { $0.0 != .same }) { return [DiffLine(id: 0, kind: .same, text: "Aucune différence")] }
        var keep = [Bool](repeating: false, count: raw.count)
        for (k, r) in raw.enumerated() where r.0 != .same {
            for x in max(0, k - context)...Swift.min(raw.count - 1, k + context) { keep[x] = true }
        }
        var out: [DiffLine] = []
        var skipped = false
        for (k, r) in raw.enumerated() {
            if keep[k] { out.append(DiffLine(id: out.count, kind: r.0, text: r.1)); skipped = false }
            else if !skipped { out.append(DiffLine(id: out.count, kind: .gap, text: "⋯")); skipped = true }
        }
        return out
    }
}

// MARK: - Espace de travail (un dépôt cloné)
@MainActor
final class Workspace: ObservableObject {
    let repo: RepoRef
    let api: GitHubAPI
    @Published var state: WSState?
    @Published var changes: [Change] = []
    @Published var nodes: [FileNode] = []
    @Published var busy = false
    @Published var progress = ""
    @Published var error: String?
    @Published var info: String?
    private var baseCache: [String: Data] = [:]
    private var hashCache: [String: HashEntry] = [:]

    static func dir(for r: RepoRef) -> URL { Paths.workspaces.appendingPathComponent("\(r.owner)__\(r.name)") }
    var base: URL { Workspace.dir(for: repo) }
    var root: URL { base.appendingPathComponent("tree") }
    var stateURL: URL { base.appendingPathComponent("state.json") }

    init(repo: RepoRef, api: GitHubAPI) {
        self.repo = repo
        self.api = api
        if let d = try? Data(contentsOf: Workspace.dir(for: repo).appendingPathComponent("state.json")) {
            state = try? JSONDecoder().decode(WSState.self, from: d)
        }
    }

    private func save() {
        guard let s = state, let d = try? JSONEncoder().encode(s) else { return }
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try? d.write(to: stateURL)
    }

    private func fetchFiles(_ items: [(String, String)]) async throws {
        var done = 0
        for chunk in items.chunked(8) {
            try await withThrowingTaskGroup(of: Void.self) { g in
                for (path, sha) in chunk {
                    g.addTask { [api, repo, root] in
                        let data = try await api.blob(repo, sha)
                        let url = root.appendingPathComponent(path)
                        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try data.write(to: url)
                    }
                }
                for try await _ in g {}
            }
            done += chunk.count
            progress = "Téléchargement \(done)/\(items.count)"
        }
    }

    private func localHashes() async -> [String: String] {
        let root = self.root
        let c0 = hashCache
        let res = await Task.detached { () -> ([String: String], [String: HashEntry]) in
            var c = c0
            let m = FS.scan(root, cache: &c)
            return (m, c)
        }.value
        hashCache = res.1
        return res.0
    }

    func refresh() async {
        guard let st = state else { return }
        let local = await localHashes()
        var ch: [Change] = []
        for (p, sha) in local {
            if let b = st.blobs[p] { if b != sha { ch.append(Change(path: p, kind: .modified)) } }
            else { ch.append(Change(path: p, kind: .added)) }
        }
        for p in st.blobs.keys where local[p] == nil { ch.append(Change(path: p, kind: .deleted)) }
        changes = ch.sorted { $0.path < $1.path }
        let root = self.root
        nodes = await Task.detached { FS.nodes(root: root, dir: root) }.value
    }

    func clone(branch: String) async throws {
        busy = true
        defer { busy = false; progress = "" }
        try? FileManager.default.removeItem(at: base)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        progress = "Lecture de la branche…"
        let head = try await api.headSha(repo, branch)
        let commit = try await api.commit(repo, head)
        let tree = try await api.tree(repo, commit.tree.sha)
        if tree.truncated == true { throw APIError.message("Dépôt trop volumineux pour l'API (arbre tronqué).") }
        var blobs: [String: String] = [:], modes: [String: String] = [:]
        for e in tree.tree where e.type == "blob" { if let s = e.sha { blobs[e.path] = s; modes[e.path] = e.mode } }
        try await fetchFiles(blobs.map { ($0.key, $0.value) })
        state = WSState(branch: branch, commitSha: head, treeSha: commit.tree.sha, blobs: blobs, modes: modes)
        save()
        await refresh()
    }

    func pull() async { await sync(branch: state?.branch ?? "") }

    func sync(branch: String, switching: Bool = false) async {
        guard var st = state else { return }
        busy = true
        defer { busy = false; progress = "" }
        do {
            progress = "Lecture du distant…"
            let head = try await api.headSha(repo, branch)
            if head == st.commitSha && !switching { info = "Déjà à jour."; return }
            let commit = try await api.commit(repo, head)
            let tree = try await api.tree(repo, commit.tree.sha)
            if tree.truncated == true { throw APIError.message("Dépôt trop volumineux pour l'API (arbre tronqué).") }
            var rb: [String: String] = [:], rm: [String: String] = [:]
            for e in tree.tree where e.type == "blob" { if let s = e.sha { rb[e.path] = s; rm[e.path] = e.mode } }
            let local = await localHashes()
            var fetch: [(String, String)] = []
            var conflicts = 0
            for (p, s) in rb where st.blobs[p] != s {
                let l = local[p]
                if l == s { continue }
                if l == st.blobs[p] { fetch.append((p, s)) }
                else { fetch.append((p + ".REMOTE", s)); conflicts += 1 }
            }
            for (p, b) in st.blobs where rb[p] == nil {
                let l = local[p]
                if l == b { try? FileManager.default.removeItem(at: root.appendingPathComponent(p)) }
                else if l != nil { conflicts += 1 }
            }
            try await fetchFiles(fetch)
            st.branch = branch; st.commitSha = head; st.treeSha = commit.tree.sha; st.blobs = rb; st.modes = rm
            state = st; save(); baseCache = [:]
            info = conflicts > 0
                ? "Mis à jour avec \(conflicts) conflit(s) : les versions distantes sont à côté des tiennes, en .REMOTE."
                : "Mis à jour (\(fetch.count) fichier(s))."
        } catch { self.error = error.localizedDescription }
        await refresh()
    }

    func commitAndPush(message: String) async {
        guard var st = state, !changes.isEmpty else { return }
        busy = true
        defer { busy = false; progress = "" }
        do {
            var entries: [[String: Any]] = []
            var newBlobs: [String: String] = [:]
            var i = 0
            for c in changes {
                i += 1; progress = "Envoi \(i)/\(changes.count)"
                let mode = st.modes[c.path] ?? "100644"
                if c.kind == .deleted {
                    entries.append(["path": c.path, "mode": mode, "type": "blob", "sha": NSNull()])
                } else {
                    let data = try Data(contentsOf: root.appendingPathComponent(c.path))
                    let sha = try await api.createBlob(repo, data)
                    newBlobs[c.path] = sha
                    entries.append(["path": c.path, "mode": mode, "type": "blob", "sha": sha])
                }
            }
            progress = "Création du commit…"
            let tree = try await api.createTree(repo, base: st.treeSha, entries: entries)
            let commit = try await api.createCommit(repo, message: message, tree: tree, parent: st.commitSha)
            try await api.updateRef(repo, branch: st.branch, sha: commit)
            for c in changes {
                if c.kind == .deleted { st.blobs[c.path] = nil; st.modes[c.path] = nil }
                else { st.blobs[c.path] = newBlobs[c.path]; st.modes[c.path] = st.modes[c.path] ?? "100644" }
            }
            st.commitSha = commit; st.treeSha = tree
            state = st; save()
            info = "Commit \(commit.prefix(7)) envoyé sur \(st.branch)."
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } catch {
            self.error = error.localizedDescription
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
        await refresh()
    }

    func baseData(_ path: String) async throws -> Data? {
        guard let sha = state?.blobs[path] else { return nil }
        if let d = baseCache[sha] { return d }
        let d = try await api.blob(repo, sha)
        baseCache[sha] = d
        return d
    }

    func discard(_ c: Change) async {
        do {
            let url = root.appendingPathComponent(c.path)
            if c.kind == .added { try FileManager.default.removeItem(at: url) }
            else if let d = try await baseData(c.path) {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try d.write(to: url)
            }
        } catch { self.error = error.localizedDescription }
        await refresh()
    }

    func newBranch(_ name: String) async {
        guard let st = state else { return }
        do {
            try await api.createBranch(repo, name: name, sha: st.commitSha)
            state?.branch = name; save()
            info = "Branche \(name) créée et active."
        } catch { self.error = error.localizedDescription }
    }

    func switchBranch(_ name: String) async {
        guard name != state?.branch else { return }
        if !changes.isEmpty { error = "Commit ou annule tes changements avant de changer de branche."; return }
        await sync(branch: name, switching: true)
    }

    func deleteBranch(_ name: String) async {
        do { try await api.deleteBranch(repo, name: name) } catch { self.error = error.localizedDescription }
    }

    func openPR(title: String) async -> String? {
        guard let st = state else { return nil }
        do {
            let b = try await api.defaultBranch(repo)
            return try await api.createPR(repo, title: title, head: st.branch, base: b)
        } catch { self.error = error.localizedDescription; return nil }
    }

    func create(_ rel: String, folder: Bool) async {
        let url = root.appendingPathComponent(rel)
        do {
            if folder { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
            else {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                if !FileManager.default.fileExists(atPath: url.path) { try Data().write(to: url) }
            }
        } catch { self.error = error.localizedDescription }
        await refresh()
    }

    func rename(_ from: String, to: String) async {
        let dst = root.appendingPathComponent(to)
        do {
            try FileManager.default.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: root.appendingPathComponent(from), to: dst)
        } catch { self.error = error.localizedDescription }
        await refresh()
    }

    func delete(_ path: String) async {
        do { try FileManager.default.removeItem(at: root.appendingPathComponent(path)) } catch { self.error = error.localizedDescription }
        await refresh()
    }

    func search(_ q: String) async -> [SearchHit] {
        let root = self.root
        return await Task.detached { FS.grep(root, q) }.value
    }
}
