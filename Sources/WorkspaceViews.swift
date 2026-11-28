import SwiftUI

struct WorkspaceView: View {
    @ObservedObject var ws: Workspace
    @StateObject private var web: WebModel
    @State private var tab = 0

    init(ws: Workspace) {
        _ws = ObservedObject(wrappedValue: ws)
        _web = StateObject(wrappedValue: WebModel(start: URL(string: "https://github.com/\(ws.repo.owner)/\(ws.repo.name)")))
    }

    var body: some View {
        TabView(selection: $tab) {
            FilesTab(ws: ws, onCommit: { tab = 1 }).tabItem { Label("Fichiers", systemImage: "folder") }.tag(0)
            ChangesTab(ws: ws).tabItem { Label("Changements", systemImage: "arrow.up.doc") }.badge(ws.changes.count).tag(1)
            HistoryTab(ws: ws).tabItem { Label("Historique", systemImage: "clock") }.tag(2)
            BranchesTab(ws: ws).tabItem { Label("Branches", systemImage: "arrow.triangle.branch") }.tag(3)
            WebBrowserView(m: web).tabItem { Label("GitHub", systemImage: "globe") }.tag(4)
        }
        .navigationTitle(ws.repo.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 0) {
                    Text(ws.repo.name).font(.headline)
                    Text(ws.state?.branch ?? "").font(.caption).foregroundColor(.secondary)
                }
            }
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                if tab != 4 {
                    Button { Task { await ws.pull() } } label: { Image(systemName: "arrow.down.circle") }
                        .disabled(ws.busy).accessibilityLabel("Pull")
                }
            }
        }
        .overlay(alignment: .bottom) {
            if ws.busy {
                HStack { ProgressView(); Text(ws.progress).font(.footnote) }
                    .padding(10).background(.thinMaterial, in: Capsule()).padding(.bottom, 60)
            }
        }
        .task { await ws.refresh() }
        .alert("Erreur", isPresented: Binding(get: { ws.error != nil }, set: { if !$0 { ws.error = nil } })) {
            Button("OK") {}
        } message: { Text(ws.error ?? "") }
        .alert("Info", isPresented: Binding(get: { ws.info != nil }, set: { if !$0 { ws.info = nil } })) {
            if let sha = ws.state?.commitSha, (ws.info ?? "").hasPrefix("Commit") {
                Button("Voir sur GitHub") {
                    web.open("https://github.com/\(ws.repo.owner)/\(ws.repo.name)/commit/\(sha)")
                    tab = 4
                }
            }
            Button("OK") {}
        } message: { Text(ws.info ?? "") }
    }
}

struct FilesTab: View {
    @ObservedObject var ws: Workspace
    var onCommit: () -> Void

    var body: some View {
        FileBrowserView(dir: ws.root, title: ws.repo.name,
                        onChange: { Task { await ws.refresh() } },
                        ws: ws, gitChanges: ws.changes, embedded: true)
            .safeAreaInset(edge: .bottom) {
                if !ws.changes.isEmpty {
                    Button { onCommit() } label: {
                        Label("\(ws.changes.count) modification(s) · Commit", systemImage: "arrow.up.circle.fill")
                            .padding(.horizontal, 16).padding(.vertical, 10)
                            .background(.thinMaterial, in: Capsule())
                    }
                    .padding(.bottom, 6)
                }
            }
    }
}

struct ChangesTab: View {
    @ObservedObject var ws: Workspace
    @State private var message = ""
    @State private var toDiscard: Change?

    private func color(_ k: Change.Kind) -> Color {
        switch k { case .added: return .green; case .modified: return .orange; case .deleted: return .red }
    }

    var body: some View {
        List {
            Section("Message de commit") {
                TextField("Décris tes changements", text: $message, axis: .vertical).lineLimit(1...5)
                Button {
                    Task { await ws.commitAndPush(message: message); if ws.error == nil { message = "" } }
                } label: { Label("Commit & Push", systemImage: "arrow.up.circle.fill") }
                .disabled(message.trimmingCharacters(in: .whitespaces).isEmpty || ws.changes.isEmpty || ws.busy)
            }
            Section(ws.changes.isEmpty ? "Aucun changement" : "\(ws.changes.count) fichier(s) modifié(s)") {
                ForEach(ws.changes) { c in
                    NavigationLink { DiffView(ws: ws, change: c) } label: {
                        HStack {
                            Text(c.kind.rawValue).font(.system(.body, design: .monospaced)).foregroundColor(color(c.kind))
                            Text(c.path).lineLimit(1).truncationMode(.head)
                        }
                    }
                    .swipeActions { Button("Rétablir", role: .destructive) { toDiscard = c } }
                }
            }
        }
        .refreshable { await ws.refresh() }
        .confirmationDialog("Rétablir ce fichier ?", isPresented: Binding(get: { toDiscard != nil }, set: { if !$0 { toDiscard = nil } }), titleVisibility: .visible) {
            Button("Rétablir (perd tes modifications)", role: .destructive) {
                if let c = toDiscard { Task { await ws.discard(c) } }
                toDiscard = nil
            }
        } message: { Text(toDiscard?.path ?? "") }
    }
}

struct DiffView: View {
    @ObservedObject var ws: Workspace
    let change: Change
    @State private var lines: [DiffLine] = []
    @State private var note: String?

    private func bg(_ k: DiffLine.Kind) -> Color {
        switch k { case .add: return .green.opacity(0.25); case .del: return .red.opacity(0.25); case .gap: return .gray.opacity(0.15); case .same: return .clear }
    }
    private func pre(_ k: DiffLine.Kind) -> String {
        switch k { case .add: return "+ "; case .del: return "- "; default: return "  " }
    }

    var body: some View {
        ScrollView {
            if let n = note { Text(n).foregroundColor(.secondary).padding() }
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(lines) { l in
                    Text(pre(l.kind) + l.text)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 6)
                        .background(bg(l.kind))
                }
            }
        }
        .navigationTitle((change.path as NSString).lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        let newData = try? Data(contentsOf: ws.root.appendingPathComponent(change.path))
        let oldData = try? await ws.baseData(change.path)
        let new = newData.flatMap { String(data: $0, encoding: .utf8) }
        let old = oldData.flatMap { String(data: $0, encoding: .utf8) }
        if (newData != nil && new == nil) || (oldData != nil && old == nil) { note = "Fichier binaire : pas de diff texte."; return }
        lines = DiffEngine.make(old: old ?? "", new: new ?? "")
    }
}

struct HistoryTab: View {
    @ObservedObject var ws: Workspace
    @State private var commits: [GHCommitItem] = []
    @State private var page = 1
    @State private var loading = false

    var body: some View {
        List {
            ForEach(commits) { c in
                NavigationLink { CommitDetailView(ws: ws, sha: c.sha, title: c.commit.message) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(c.commit.message.components(separatedBy: "\n").first ?? "").lineLimit(2)
                        Text("\(c.sha.prefix(7)) · \(c.commit.author.name)").font(.caption).foregroundColor(.secondary)
                    }
                }
                .onAppear { if c.id == commits.last?.id { Task { await load() } } }
            }
            if loading { ProgressView() }
        }
        .task(id: ws.state?.commitSha) { commits = []; page = 1; await load() }
        .refreshable { commits = []; page = 1; await load() }
    }

    private func load() async {
        guard !loading, let b = ws.state?.branch else { return }
        loading = true
        defer { loading = false }
        if let r = try? await ws.api.commits(ws.repo, branch: b, page: page) { commits += r; page += 1 }
    }
}

struct CommitDetailView: View {
    @ObservedObject var ws: Workspace
    let sha: String
    let title: String
    @State private var files: [GHCommitDetail.File] = []

    private func color(_ l: String) -> Color {
        if l.hasPrefix("+") { return .green.opacity(0.25) }
        if l.hasPrefix("-") { return .red.opacity(0.25) }
        if l.hasPrefix("@@") { return .blue.opacity(0.2) }
        return .clear
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                Text(title).font(.headline).padding()
                ForEach(files) { f in
                    Text("\(f.status) · \(f.filename)").font(.system(size: 13, weight: .bold, design: .monospaced)).padding(6)
                    let lines = Array((f.patch ?? "(binaire ou trop volumineux)").components(separatedBy: "\n").prefix(2000).enumerated())
                    ForEach(lines, id: \.offset) { _, l in
                        Text(l).font(.system(size: 12, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 6).background(color(l))
                    }
                }
            }
        }
        .navigationTitle(String(sha.prefix(7)))
        .navigationBarTitleDisplayMode(.inline)
        .task { files = (try? await ws.api.commitDetail(ws.repo, sha: sha).files) ?? [] }
    }
}

struct BranchesTab: View {
    @ObservedObject var ws: Workspace
    @State private var branches: [GHBranch] = []
    @State private var showNew = false
    @State private var name = ""
    @State private var showPR = false
    @State private var prTitle = ""
    @Environment(\.openURL) private var openURL

    var body: some View {
        List {
            Section("Branches") {
                ForEach(branches) { b in
                    Button {
                        Task { await ws.switchBranch(b.name); await load() }
                    } label: {
                        HStack {
                            Text(b.name).foregroundColor(.primary)
                            Spacer()
                            if b.name == ws.state?.branch { Image(systemName: "checkmark") }
                        }
                    }
                    .swipeActions {
                        if b.name != ws.state?.branch {
                            Button("Supprimer", role: .destructive) { Task { await ws.deleteBranch(b.name); await load() } }
                        }
                    }
                }
            }
            Section {
                Button("Nouvelle branche depuis ici") { name = ""; showNew = true }
                Button("Ouvrir une pull request") { prTitle = ""; showPR = true }
            }
        }
        .task { await load() }
        .refreshable { await load() }
        .alert("Nouvelle branche", isPresented: $showNew) {
            TextField("nom-de-branche", text: $name).textInputAutocapitalization(.never).autocorrectionDisabled()
            Button("Créer") { let n = name; Task { await ws.newBranch(n); await load() } }
            Button("Annuler", role: .cancel) {}
        }
        .alert("Pull request", isPresented: $showPR) {
            TextField("Titre", text: $prTitle)
            Button("Créer") {
                let t = prTitle
                Task { if let u = await ws.openPR(title: t), let url = URL(string: u) { openURL(url) } }
            }
            Button("Annuler", role: .cancel) {}
        } message: { Text("De \(ws.state?.branch ?? "") vers la branche par défaut.") }
    }

    private func load() async { branches = (try? await ws.api.branches(ws.repo)) ?? [] }
}

