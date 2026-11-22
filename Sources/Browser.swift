import SwiftUI
import WebKit

// MARK: - Mémoire du navigateur (réglages, favoris, historique)
struct Bookmark: Codable, Identifiable, Hashable {
    var id = UUID()
    var title: String
    var url: String
}

struct HistoryItem: Codable, Identifiable, Hashable {
    var id = UUID()
    var title: String
    var url: String
    var date: Date
}

@MainActor
final class BrowserStore: ObservableObject {
    static let shared = BrowserStore()
    @Published var zoom: Double { didSet { UserDefaults.standard.set(zoom, forKey: "web.zoom") } }
    @Published var desktop: Bool { didSet { UserDefaults.standard.set(desktop, forKey: "web.desktop") } }
    @Published var restrict: Bool { didSet { UserDefaults.standard.set(restrict, forKey: "web.restrict") } }
    @Published var restoreLast: Bool { didSet { UserDefaults.standard.set(restoreLast, forKey: "web.restore") } }
    @Published var lastURL: String { didSet { UserDefaults.standard.set(lastURL, forKey: "web.last") } }
    @Published var bookmarks: [Bookmark] { didSet { BrowserStore.save(bookmarks, "web.bookmarks") } }
    @Published var history: [HistoryItem] { didSet { BrowserStore.save(history, "web.history") } }

    private init() {
        let d = UserDefaults.standard
        zoom = d.object(forKey: "web.zoom") as? Double ?? 0.85
        desktop = d.object(forKey: "web.desktop") as? Bool ?? true
        restrict = d.object(forKey: "web.restrict") as? Bool ?? true
        restoreLast = d.object(forKey: "web.restore") as? Bool ?? true
        lastURL = d.string(forKey: "web.last") ?? ""
        bookmarks = BrowserStore.load("web.bookmarks")
        history = BrowserStore.load("web.history")
    }

    private static func save<T: Encodable>(_ v: [T], _ key: String) {
        if let d = try? JSONEncoder().encode(v) { UserDefaults.standard.set(d, forKey: key) }
    }
    private static func load<T: Decodable>(_ key: String) -> [T] {
        guard let d = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([T].self, from: d)) ?? []
    }

    func visit(_ url: URL?, _ title: String) {
        guard let url, url.scheme?.hasPrefix("http") == true else { return }
        let s = url.absoluteString
        lastURL = s
        if history.first?.url == s { return }
        history.insert(HistoryItem(title: title.isEmpty ? (url.host ?? s) : title, url: s, date: Date()), at: 0)
        if history.count > 300 { history.removeLast(history.count - 300) }
    }

    func isBookmarked(_ u: URL?) -> Bool {
        guard let u else { return false }
        return bookmarks.contains { $0.url == u.absoluteString }
    }

    func toggleBookmark(_ u: URL?, title: String) {
        guard let u else { return }
        if let i = bookmarks.firstIndex(where: { $0.url == u.absoluteString }) { bookmarks.remove(at: i) }
        else { bookmarks.insert(Bookmark(title: title.isEmpty ? (u.host ?? u.absoluteString) : title, url: u.absoluteString), at: 0) }
    }

    func clearHistory() { history = []; lastURL = "" }

    func resetSettings() { zoom = 0.85; desktop = true; restrict = true; restoreLast = true }
}

// MARK: - Gestionnaire de téléchargements
struct DownloadRecord: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var source: String
    var date: Date
    var status: String // running, done, failed
    var size: Int64 = 0
    var url: URL { Paths.downloads.appendingPathComponent(name) }
}

@MainActor
final class DownloadManager: ObservableObject {
    static let shared = DownloadManager()
    @Published var records: [DownloadRecord] = []
    @Published var progress: [UUID: Double] = [:]
    private var active: [ObjectIdentifier: (UUID, WKDownload)] = [:]
    private var observers: [UUID: NSKeyValueObservation] = [:]

    private init() {
        if let d = UserDefaults.standard.data(forKey: "downloads"),
           let r = try? JSONDecoder().decode([DownloadRecord].self, from: d) {
            records = r.map { x in var y = x; if y.status == "running" { y.status = "failed" }; return y }
        }
    }

    private func persist() {
        if let d = try? JSONEncoder().encode(records) { UserDefaults.standard.set(d, forKey: "downloads") }
    }

    private func update(_ id: UUID, _ f: (inout DownloadRecord) -> Void) {
        guard let i = records.firstIndex(where: { $0.id == id }) else { return }
        f(&records[i])
        persist()
    }

    func destination(for suggested: String, download: WKDownload, source: URL?) -> URL {
        var clean = suggested.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        if clean.isEmpty { clean = "telechargement" }
        let dest = FSOps.unique(Paths.downloads.appendingPathComponent(clean))
        let rec = DownloadRecord(name: dest.lastPathComponent, source: source?.absoluteString ?? "", date: Date(), status: "running")
        records.insert(rec, at: 0)
        active[ObjectIdentifier(download)] = (rec.id, download)
        let id = rec.id
        observers[id] = download.progress.observe(\.fractionCompleted) { [weak self] p, _ in
            let f = p.fractionCompleted
            Task { @MainActor in self?.progress[id] = f }
        }
        persist()
        return dest
    }

    func finished(_ d: WKDownload) {
        guard let entry = active.removeValue(forKey: ObjectIdentifier(d)) else { return }
        let id = entry.0
        update(id) { r in r.status = "done"; r.size = FSOps.fileSize(r.url) }
        progress[id] = nil
        observers[id] = nil
    }

    func failed(_ d: WKDownload) {
        guard let entry = active.removeValue(forKey: ObjectIdentifier(d)) else { return }
        let id = entry.0
        update(id) { r in r.status = "failed"; try? FileManager.default.removeItem(at: r.url) }
        progress[id] = nil
        observers[id] = nil
    }

    func cancel(_ id: UUID) {
        if let e = active.values.first(where: { $0.0 == id }) { e.1.cancel { _ in } }
    }

    func remove(_ r: DownloadRecord) {
        try? FileManager.default.removeItem(at: r.url)
        records.removeAll { $0.id == r.id }
        persist()
    }

    func clearAll() {
        for r in records { try? FileManager.default.removeItem(at: r.url) }
        records = []
        persist()
    }
}

struct DownloadsView: View {
    @ObservedObject private var dm = DownloadManager.shared
    @State private var preview: DownloadRecord?
    @State private var share: ShareTarget?
    @State private var message: String?
    @State private var confirmClear = false

    var body: some View {
        List {
            if dm.records.isEmpty { Text("Aucun téléchargement.").foregroundColor(.secondary) }
            ForEach(dm.records) { r in
                HStack(spacing: 12) {
                    Image(systemName: r.status == "failed" ? "exclamationmark.circle.fill" : "arrow.down.circle.fill")
                        .foregroundColor(r.status == "failed" ? .red : .green).font(.title3)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(r.name).lineLimit(1)
                        if r.status == "running" {
                            ProgressView(value: dm.progress[r.id] ?? 0)
                        } else {
                            Text(r.status == "done" ? FSOps.format(r.size) : "Échec ou annulé").font(.caption).foregroundColor(.secondary)
                        }
                    }
                    Spacer()
                    if r.status == "running" {
                        Button { dm.cancel(r.id) } label: { Image(systemName: "xmark.circle") }.buttonStyle(.borderless)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { if r.status == "done" { preview = r } }
                .contextMenu {
                    if r.status == "done" {
                        Button { share = ShareTarget(urls: [r.url]) } label: { Label("Partager / Enregistrer", systemImage: "square.and.arrow.up") }
                        if Archive.isArchive(r.url) { Button { extract(r) } label: { Label("Extraire", systemImage: "archivebox") } }
                    }
                    Button(role: .destructive) { dm.remove(r) } label: { Label("Supprimer", systemImage: "trash") }
                }
                .swipeActions { Button("Supprimer", role: .destructive) { dm.remove(r) } }
            }
            if !dm.records.isEmpty {
                Section(footer: Text("Les fichiers sont dans Documents/Téléchargements, visibles aussi dans l'app Fichiers.")) {
                    Button("Tout effacer", role: .destructive) { confirmClear = true }
                }
            }
        }
        .navigationTitle("Téléchargements")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $preview) { r in
            NavigationStack {
                FileOpenView(url: r.url)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Fermer") { preview = nil } } }
            }
        }
        .sheet(item: $share) { ShareSheet(items: $0.urls) }
        .confirmationDialog("Supprimer tous les téléchargements ?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Tout effacer", role: .destructive) { dm.clearAll() }
        }
        .alert("Info", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK") {}
        } message: { Text(message ?? "") }
    }

    private func extract(_ r: DownloadRecord) {
        let dest = FSOps.unique(Paths.downloads.appendingPathComponent(Archive.baseName(r.url)))
        let src = r.url
        Task {
            let res = await Task.detached { () -> Result<Int, Error> in Result { try Archive.extract(src, to: dest) } }.value
            switch res {
            case .success(let n): message = "\(n) fichier(s) extraits dans « \(dest.lastPathComponent) » (Documents/Téléchargements)."
            case .failure(let e): message = e.localizedDescription
            }
        }
    }
}

// MARK: - Favoris et historique
struct BrowserLibraryView: View {
    var onOpen: (URL) -> Void
    @ObservedObject private var store = BrowserStore.shared
    @State private var tab = 0

    var body: some View {
        List {
            Picker("", selection: $tab) {
                Text("Favoris").tag(0)
                Text("Historique").tag(1)
            }
            .pickerStyle(.segmented)
            .listRowBackground(Color.clear)
            if tab == 0 {
                if store.bookmarks.isEmpty { Text("Aucun favori. Utilise le menu ⋯ du navigateur.").foregroundColor(.secondary) }
                ForEach(store.bookmarks) { b in item(b.title, b.url) }
                    .onDelete { store.bookmarks.remove(atOffsets: $0) }
            } else {
                if store.history.isEmpty { Text("Historique vide.").foregroundColor(.secondary) }
                ForEach(store.history) { h in item(h.title, h.url) }
                    .onDelete { store.history.remove(atOffsets: $0) }
            }
        }
        .navigationTitle("Favoris et historique")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if tab == 1 && !store.history.isEmpty { Button("Effacer", role: .destructive) { store.clearHistory() } }
            }
        }
    }

    private func item(_ title: String, _ url: String) -> some View {
        Button { if let u = URL(string: url) { onOpen(u) } } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundColor(.primary).lineLimit(1)
                Text(url).font(.caption).foregroundColor(.secondary).lineLimit(1)
            }
        }
    }
}

// MARK: - Cache et confidentialité
struct CacheManagerView: View {
    @ObservedObject private var store = BrowserStore.shared
    @ObservedObject private var dm = DownloadManager.shared
    @State private var cacheSize = "…"
    @State private var docsSize = "…"
    @State private var dlSize = "…"
    @State private var action: CleanAction?
    @State private var done: String?

    enum CleanAction: String, Identifiable {
        case cache, sites, history, downloads, clean, all
        var id: String { rawValue }
        var title: String {
            switch self {
            case .cache: return "Vider le cache ?"
            case .sites: return "Effacer cookies et données de sites ?"
            case .history: return "Effacer l'historique ?"
            case .downloads: return "Supprimer tous les téléchargements ?"
            case .clean: return "Nettoyer le navigateur ?"
            case .all: return "Tout vider ?"
            }
        }
        var detail: String {
            switch self {
            case .cache: return "Images et fichiers temporaires des pages. Tu restes connecté."
            case .sites: return "Tu seras déconnecté de GitHub dans le navigateur."
            case .history: return "Supprime la liste des pages visitées."
            case .downloads: return "Supprime les fichiers du dossier Téléchargements."
            case .clean: return "Cache + historique + fichiers temporaires. Connexion et favoris conservés."
            case .all: return "Cache, cookies, connexions, historique, favoris et réglages du navigateur. Tes dépôts et fichiers ne sont pas touchés."
            }
        }
    }

    static let cacheTypes: Set<String> = [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache,
                                          WKWebsiteDataTypeOfflineWebApplicationCache, WKWebsiteDataTypeFetchCache]
    static let siteTypes: Set<String> = [WKWebsiteDataTypeCookies, WKWebsiteDataTypeLocalStorage, WKWebsiteDataTypeSessionStorage,
                                         WKWebsiteDataTypeIndexedDBDatabases, WKWebsiteDataTypeWebSQLDatabases]

    var body: some View {
        List {
            Section("Stockage") {
                LabeledContent("Cache du navigateur", value: cacheSize)
                LabeledContent("Téléchargements", value: dlSize)
                LabeledContent("Fichiers de l'app", value: docsSize)
            }
            Section("Navigateur") {
                button("Vider le cache", "internaldrive", .blue, .cache)
                button("Cookies et données de sites", "person.crop.circle.badge.xmark", .orange, .sites)
                button("Effacer l'historique", "clock.arrow.circlepath", .purple, .history)
                button("Nettoyer le navigateur", "sparkles", .teal, .clean)
            }
            Section("Fichiers") {
                button("Supprimer les téléchargements", "trash", .red, .downloads)
            }
            Section(footer: Text("Les dépôts clonés et les fichiers importés ne sont jamais supprimés par ces actions.")) {
                button("Tout vider", "flame.fill", .red, .all)
            }
        }
        .navigationTitle("Cache et confidentialité")
        .navigationBarTitleDisplayMode(.inline)
        .task { await sizes() }
        .confirmationDialog(action?.title ?? "", isPresented: Binding(get: { action != nil }, set: { if !$0 { action = nil } }),
                            titleVisibility: .visible, presenting: action) { a in
            Button("Confirmer", role: .destructive) { Task { await run(a) } }
        } message: { a in Text(a.detail) }
        .alert("Terminé", isPresented: Binding(get: { done != nil }, set: { if !$0 { done = nil } })) {
            Button("OK") {}
        } message: { Text(done ?? "") }
    }

    private func button(_ t: String, _ symbol: String, _ c: Color, _ a: CleanAction) -> some View {
        Button { action = a } label: {
            Label { Text(t).foregroundColor(.primary) } icon: { IconTile(symbol: symbol, color: c) }
        }
    }

    private func clearTemp() {
        URLCache.shared.removeAllCachedResponses()
        let tmp = FileManager.default.temporaryDirectory
        for u in (try? FileManager.default.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil)) ?? [] {
            try? FileManager.default.removeItem(at: u)
        }
    }

    private func run(_ a: CleanAction) async {
        let ds = WKWebsiteDataStore.default()
        switch a {
        case .cache: await ds.removeData(ofTypes: Self.cacheTypes, modifiedSince: .distantPast); clearTemp()
        case .sites: await ds.removeData(ofTypes: Self.siteTypes, modifiedSince: .distantPast)
        case .history: store.clearHistory()
        case .downloads: dm.clearAll()
        case .clean:
            await ds.removeData(ofTypes: Self.cacheTypes, modifiedSince: .distantPast)
            store.clearHistory(); clearTemp()
        case .all:
            await ds.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
            store.clearHistory(); store.bookmarks = []; store.resetSettings(); clearTemp()
        }
        await sizes()
        done = "Opération effectuée."
    }

    private func sizes() async {
        let lib = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        let dl = Paths.downloads
        let docs = Paths.documents
        let r = await Task.detached { () -> (Int64, Int64, Int64) in
            (FSOps.size(of: lib.appendingPathComponent("Caches")) + FSOps.size(of: lib.appendingPathComponent("WebKit")),
             FSOps.size(of: dl), FSOps.size(of: docs))
        }.value
        cacheSize = FSOps.format(r.0); dlSize = FSOps.format(r.1); docsSize = FSOps.format(r.2)
    }
}

// MARK: - Paramètres
struct IconTile: View {
    let symbol: String
    let color: Color
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 15, weight: .semibold)).foregroundColor(.white)
            .frame(width: 29, height: 29)
            .background(color, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

func tileLabel(_ title: String, _ symbol: String, _ color: Color) -> some View {
    Label { Text(title).foregroundColor(.primary) } icon: { IconTile(symbol: symbol, color: color) }
}

struct SettingsView: View {
    @EnvironmentObject var s: Session
    @ObservedObject private var store = BrowserStore.shared
    @AppStorage("fontSize") private var fontSize = 14.0
    @State private var web: WebTarget?
    @State private var confirmOut = false

    var body: some View {
        NavigationStack {
            List {
                Section("Compte GitHub") {
                    tileLabel(s.login.isEmpty ? "Connecté" : s.login, "person.fill", .gray)
                    Button("Se déconnecter", role: .destructive) { confirmOut = true }
                }
                Section(header: Text("Navigateur"), footer: Text("Taille du texte des pages : 50 % à 150 %. Tes réglages, favoris, historique et connexion sont mémorisés.")) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack { Text("Taille du texte"); Spacer(); Text("\(Int((store.zoom * 100).rounded())) %").foregroundColor(.secondary) }
                        Slider(value: $store.zoom, in: 0.5...1.5, step: 0.05)
                    }
                    Toggle("Version ordinateur", isOn: $store.desktop)
                    Toggle("Limiter à GitHub", isOn: $store.restrict)
                    Toggle("Rouvrir la dernière page", isOn: $store.restoreLast)
                    Button { web = WebTarget(url: nil) } label: { tileLabel("Ouvrir le navigateur", "safari.fill", .blue) }
                    NavigationLink { BrowserLibraryView { u in web = WebTarget(url: u) } } label: { tileLabel("Favoris et historique", "star.fill", .yellow) }
                    NavigationLink { DownloadsView() } label: { tileLabel("Téléchargements", "arrow.down.circle.fill", .green) }
                    NavigationLink { CacheManagerView() } label: { tileLabel("Cache et confidentialité", "hand.raised.fill", .indigo) }
                }
                Section("Éditeur") {
                    Stepper("Taille du code : \(Int(fontSize)) pt", value: $fontSize, in: 9...28)
                }
                Section(header: Text("Fichiers"), footer: Text("Tout est aussi visible dans l'app Fichiers : Sur mon iPhone → GitDesk.")) {
                    NavigationLink { FileBrowserView(dir: Paths.documents, title: "Fichiers") } label: { tileLabel("Explorateur de fichiers", "folder.fill", .orange) }
                }
                Section("À propos") {
                    LabeledContent("Version", value: "1.4.0")
                }
            }
            .navigationTitle("Paramètres")
        }
        .fullScreenCover(item: $web) { t in GitHubWebScreen(start: t.url) }
        .confirmationDialog("Se déconnecter de GitHub ?", isPresented: $confirmOut, titleVisibility: .visible) {
            Button("Se déconnecter", role: .destructive) { s.signOut() }
        }
    }
}
