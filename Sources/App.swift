import SwiftUI

@main
struct GitDeskApp: App {
    @StateObject private var session = Session()
    @StateObject private var clipboard = FileClipboard()
    @StateObject private var builds = BuildCenter()
    @Environment(\.scenePhase) private var phase

    init() { Memory.install() }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(session).environmentObject(clipboard).environmentObject(builds)
                .tint(Theme.accent)
                .onChange(of: phase) { p in if p == .background { Memory.trim() } }
        }
    }
}

@MainActor
final class Session: ObservableObject {
    @Published var token: String?
    @Published var login = ""
    @Published var remoteRepos: [GHRepo] = []
    @Published var local: [RepoRef] = []
    @Published var loading = false
    @Published var error: String?
    private var cache: [String: Workspace] = [:]

    var api: GitHubAPI? { token.map { GitHubAPI(token: $0) } }

    init() {
        token = Keychain.get("github_token")
        reloadLocal()
        if token != nil { Task { await refresh() } }
    }

    func signIn(_ t: String) async {
        let tok = t.trimmingCharacters(in: .whitespacesAndNewlines)
        loading = true
        defer { loading = false }
        do {
            let me = try await GitHubAPI(token: tok).me()
            Keychain.set(tok, key: "github_token")
            token = tok; login = me; error = nil
            await refresh()
        } catch { self.error = error.localizedDescription }
    }

    func signOut() {
        Keychain.remove("github_token")
        token = nil; remoteRepos = []; cache = [:]
    }

    func refresh() async {
        guard let api else { return }
        loading = true
        defer { loading = false }
        do {
            login = try await api.me()
            remoteRepos = try await api.repos()
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    func reloadLocal() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: Paths.workspaces.path)) ?? []
        local = names.compactMap { n -> RepoRef? in
            guard let r = n.range(of: "__") else { return nil }
            return RepoRef(owner: String(n[..<r.lowerBound]), name: String(n[r.upperBound...]))
        }.sorted { $0.id < $1.id }
    }

    func workspace(_ r: RepoRef) -> Workspace? {
        guard let api else { return nil }
        if let w = cache[r.id] { return w }
        let w = Workspace(repo: r, api: api)
        cache[r.id] = w
        return w
    }

    func deleteLocal(_ r: RepoRef) {
        cache[r.id] = nil
        try? FileManager.default.removeItem(at: Workspace.dir(for: r))
        reloadLocal()
    }
}

struct RootView: View {
    @EnvironmentObject var s: Session
    @EnvironmentObject var builds: BuildCenter
    @State private var tab = 0

    var body: some View {
        if s.token == nil {
            LoginView()
        } else {
            TabView(selection: $tab) {
                RepoListView().tabItem { Label("Travail", systemImage: "briefcase.fill") }.tag(0)
                CompilerView().tabItem { Label("Compiler", systemImage: "hammer.fill") }.tag(1)
                SettingsView().tabItem { Label("Paramètres", systemImage: "gearshape.fill") }.tag(2)
            }
            .overlay(alignment: .bottom) {
                if tab != 1 {
                    ActivityBanner { Haptic.tap(); tab = 1 }.padding(.bottom, 58)
                }
            }
            .animation(.easeInOut(duration: 0.25), value: builds.jobs.filter { $0.state.isActive }.count)
            .task { builds.start(session: s) }
        }
    }
}

struct LoginView: View {
    @EnvironmentObject var s: Session
    @State private var tok = ""
    @State private var web: WebTarget?

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("1. Crée ton token"),
                        footer: Text("GitHub n'accepte plus le mot de passe dans les apps : le token le remplace. Connecte-toi à GitHub dans la fenêtre, vérifie que « repo » et « workflow » sont cochés, touche « Generate token », puis copie le texte qui commence par ghp_.")) {
                    Button { web = WebTarget(url: URL(string: "https://github.com/settings/tokens/new?scopes=repo,workflow&description=GitDesk")!) } label: {
                        Label("Ouvrir GitHub et créer un token", systemImage: "globe")
                    }
                }
                Section(header: Text("2. Colle-le ici"), footer: Text("Il est gardé dans le Trousseau de l'iPhone.")) {
                    SecureField("ghp_…", text: $tok)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button { tok = UIPasteboard.general.string ?? "" } label: { Label("Coller depuis le presse-papiers", systemImage: "doc.on.clipboard") }
                    Button { Task { await s.signIn(tok) } } label: {
                        HStack { Text("Se connecter"); if s.loading { Spacer(); ProgressView() } }
                    }
                    .disabled(tok.isEmpty || s.loading)
                }
                if let e = s.error { Section { Text(e).foregroundColor(.red).font(.footnote) } }
            }
            .navigationTitle("GitDesk")
            .gdScreen()
        }
        .fullScreenCover(item: $web) { t in GitHubWebScreen(start: t.url) }
    }
}

struct RepoListView: View {
    @EnvironmentObject var s: Session
    @State private var q = ""
    @State private var cloning: GHRepo?
    @State private var path: [RepoRef] = []
    @State private var web: WebTarget?

    private var filtered: [GHRepo] {
        q.isEmpty ? s.remoteRepos : s.remoteRepos.filter { $0.full_name.localizedCaseInsensitiveContains(q) }
    }
    private func gh(_ p: String) -> WebTarget { WebTarget(url: URL(string: "https://github.com" + p)) }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section("Outils") {
                    Button { web = WebTarget(url: nil) } label: { tileLabel("Navigateur GitHub", "safari.fill", .blue) }
                    NavigationLink { DownloadsView() } label: { tileLabel("Téléchargements", "arrow.down.circle.fill", .green) }
                    NavigationLink { FileBrowserView(dir: Paths.documents, title: "Fichiers") } label: { tileLabel("Fichiers et archives", "folder.fill", .orange) }
                }
                if !s.local.isEmpty {
                    Section("Sur l'appareil") {
                        ForEach(s.local) { r in
                            NavigationLink(value: r) { Label(r.id, systemImage: "folder") }
                        }
                        .onDelete { idx in
                            let items = idx.map { s.local[$0] }
                            items.forEach { s.deleteLocal($0) }
                        }
                    }
                }
                Section("GitHub") {
                    if s.loading && s.remoteRepos.isEmpty { ProgressView() }
                    ForEach(filtered) { r in
                        let ref = RepoRef(owner: r.owner.login, name: r.name)
                        Button {
                            if s.local.contains(ref) { path.append(ref) } else { cloning = r }
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Label(r.full_name, systemImage: r.isPrivate ? "lock" : "book.closed").foregroundColor(.primary)
                                    Spacer()
                                    if s.local.contains(ref) { Image(systemName: "checkmark.circle.fill").foregroundColor(.green) }
                                }
                                if let d = r.description { Text(d).font(.caption).foregroundColor(.secondary).lineLimit(2) }
                            }
                        }
                        .contextMenu {
                            Button { cloning = r } label: { Label("Cloner / recloner", systemImage: "arrow.down.circle") }
                            Button { web = gh("/" + r.full_name) } label: { Label("Ouvrir sur GitHub", systemImage: "globe") }
                        }
                    }
                }
                if let e = s.error { Text(e).foregroundColor(.red).font(.footnote) }
            }
            .fullScreenCover(item: $web) { t in GitHubWebScreen(start: t.url) }
            .navigationDestination(for: RepoRef.self) { r in
                if let w = s.workspace(r) { WorkspaceView(ws: w) }
            }
            .searchable(text: $q, prompt: "Filtrer les dépôts")
            .refreshable { await s.refresh() }
            .navigationTitle("Travail")
            .gdScreen()
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Text("Connecté : \(s.login)")
                        Button { web = gh("/notifications") } label: { Label("Notifications", systemImage: "bell") }
                        Button { web = gh("/pulls") } label: { Label("Pull requests", systemImage: "arrow.triangle.pull") }
                        Button { web = gh("/issues") } label: { Label("Issues", systemImage: "circle.dotted") }
                        Button { web = gh("/new") } label: { Label("Nouveau dépôt", systemImage: "plus.square") }
                    } label: { Image(systemName: "person.circle") }
                }
            }
        }
        .sheet(item: $cloning) { r in
            CloneSheet(repo: r) { ref in path.append(ref) }
        }
    }
}

struct CloneSheet: View {
    let repo: GHRepo
    var done: (RepoRef) -> Void
    @EnvironmentObject var s: Session
    @Environment(\.dismiss) private var dismiss
    @State private var branches: [GHBranch] = []
    @State private var branch = ""
    @State private var busy = false
    @State private var err: String?

    private var ref: RepoRef { RepoRef(owner: repo.owner.login, name: repo.name) }

    var body: some View {
        NavigationStack {
            Form {
                Picker("Branche", selection: $branch) {
                    ForEach(branches) { Text($0.name).tag($0.name) }
                }
                if s.local.contains(ref) {
                    Text("Ce dépôt existe déjà sur l'appareil : le cloner le remplace.").font(.footnote).foregroundColor(.orange)
                }
                if busy { ProgressView() }
                if let e = err { Text(e).foregroundColor(.red).font(.footnote) }
                Button("Cloner") { Task { await go() } }.disabled(busy || branch.isEmpty)
            }
            .navigationTitle(repo.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Fermer") { dismiss() } } }
            .task {
                branch = repo.default_branch
                if let api = s.api { branches = (try? await api.branches(ref)) ?? [] }
            }
        }
    }

    private func go() async {
        guard let ws = s.workspace(ref) else { return }
        busy = true
        defer { busy = false }
        do {
            try await ws.clone(branch: branch)
            s.reloadLocal()
            dismiss()
            done(ref)
        } catch { err = error.localizedDescription }
    }
}
