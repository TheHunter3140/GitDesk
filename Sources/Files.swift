import SwiftUI
import QuickLook

struct FileItem: Identifiable, Hashable {
    let url: URL
    let isDir: Bool
    let size: Int64
    let date: Date
    var id: URL { url }
    var name: String { url.lastPathComponent }
}

struct ShareTarget: Identifiable {
    let id = UUID()
    let urls: [URL]
}

enum FSOps {
    static let fm = FileManager.default
    enum Policy { case replace, keepBoth, skip }

    static func list(_ dir: URL) -> [FileItem] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        let urls = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys)) ?? []
        var items: [FileItem] = []
        for u in urls where u.lastPathComponent != ".DS_Store" {
            let v = try? u.resourceValues(forKeys: Set(keys))
            items.append(FileItem(url: u, isDir: v?.isDirectory ?? false, size: Int64(v?.fileSize ?? 0), date: v?.contentModificationDate ?? .distantPast))
        }
        return items.sorted { a, b in
            if a.isDir != b.isDir { return a.isDir }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    static func fileSize(_ u: URL) -> Int64 {
        let attrs = try? fm.attributesOfItem(atPath: u.path)
        return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
    }

    static func size(of url: URL) -> Int64 {
        var total: Int64 = 0
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        if let en = fm.enumerator(at: url, includingPropertiesForKeys: keys) {
            for case let u as URL in en {
                if let v = try? u.resourceValues(forKeys: Set(keys)), v.isRegularFile == true { total += Int64(v.fileSize ?? 0) }
            }
        }
        return total
    }

    static func format(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }

    static func unique(_ u: URL) -> URL {
        if !fm.fileExists(atPath: u.path) { return u }
        let base = u.deletingPathExtension().lastPathComponent
        let ext = u.pathExtension
        let dir = u.deletingLastPathComponent()
        var i = 2
        while true {
            let name = ext.isEmpty ? "\(base) \(i)" : "\(base) \(i).\(ext)"
            let c = dir.appendingPathComponent(name)
            if !fm.fileExists(atPath: c.path) { return c }
            i += 1
        }
    }

    static func conflicts(_ sources: [URL], into dir: URL) -> Int {
        sources.filter { s in
            let dst = dir.appendingPathComponent(s.lastPathComponent)
            return fm.fileExists(atPath: dst.path) && s.standardizedFileURL != dst.standardizedFileURL
        }.count
    }

    static func place(_ sources: [URL], move: Bool, into dir: URL, policy: Policy) throws -> Int {
        var n = 0
        for s in sources {
            let src = s.standardizedFileURL
            var dst = dir.appendingPathComponent(s.lastPathComponent)
            if src == dst.standardizedFileURL {
                if move { continue }
                dst = unique(dst)
            } else if fm.fileExists(atPath: dst.path) {
                switch policy {
                case .skip: continue
                case .keepBoth: dst = unique(dst)
                case .replace: try fm.removeItem(at: dst)
                }
            }
            if dst.standardizedFileURL.path.hasPrefix(src.path + "/") { continue } // pas de dossier dans lui-même
            if move { try fm.moveItem(at: s, to: dst) } else { try fm.copyItem(at: s, to: dst) }
            n += 1
        }
        return n
    }
}

@MainActor
final class FileClipboard: ObservableObject {
    @Published var items: [URL] = []
    @Published var cut = false
}

private func fileIcon(_ name: String) -> String {
    switch (name as NSString).pathExtension.lowercased() {
    case "zip", "tar", "gz", "tgz": return "archivebox.fill"
    case "png", "jpg", "jpeg", "gif", "heic", "svg", "webp": return "photo.fill"
    case "pdf": return "doc.richtext.fill"
    case "swift", "py", "js", "ts", "json", "yml", "yaml", "sh", "html", "css", "md", "txt": return "doc.text.fill"
    default: return "doc.fill"
    }
}

struct FileBrowserView: View {
    let dir: URL
    var title: String? = nil
    var onChange: () -> Void = {}

    @EnvironmentObject var clip: FileClipboard
    @State private var items: [FileItem] = []
    @State private var selection = Set<URL>()
    @State private var editMode: EditMode = .inactive
    @State private var importMode: ImportMode = .files
    @State private var showImporter = false
    @State private var showNewFolder = false
    @State private var showNewFile = false
    @State private var newName = ""
    @State private var renaming: FileItem?
    @State private var renameText = ""
    @State private var pending: PendingOp?
    @State private var toDelete: [URL]?
    @State private var busy: String?
    @State private var message: String?
    @State private var share: ShareTarget?

    enum ImportMode { case files, folder, archive }
    struct PendingOp { var sources: [URL]; var move: Bool; var conflicts: Int; var scoped: Bool }

    var body: some View {
        listView
            .fileImporter(isPresented: $showImporter,
                          allowedContentTypes: importMode == .folder ? [.folder] : [.item],
                          allowsMultipleSelection: importMode != .folder) { handleImport($0) }
            .alert("Nouveau dossier", isPresented: $showNewFolder) {
                TextField("Nom", text: $newName)
                Button("Créer") { create(folder: true) }
                Button("Annuler", role: .cancel) {}
            }
            .alert("Nouveau fichier", isPresented: $showNewFile) {
                TextField("nom.txt", text: $newName).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Créer") { create(folder: false) }
                Button("Annuler", role: .cancel) {}
            }
            .alert("Renommer", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Nom", text: $renameText).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("OK") { rename() }
                Button("Annuler", role: .cancel) { renaming = nil }
            }
            .alert("Info", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("OK") {}
            } message: { Text(message ?? "") }
            .confirmationDialog("Éléments déjà existants",
                                isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
                                titleVisibility: .visible, presenting: pending) { p in
                Button("Remplacer", role: .destructive) { run(p, .replace) }
                Button("Garder les deux") { run(p, .keepBoth) }
                Button("Ignorer les doublons") { run(p, .skip) }
            } message: { p in Text("\(p.conflicts) élément(s) portent déjà ce nom dans ce dossier.") }
            .confirmationDialog("Supprimer ?",
                                isPresented: Binding(get: { toDelete != nil }, set: { if !$0 { toDelete = nil } }),
                                titleVisibility: .visible, presenting: toDelete) { urls in
                Button("Supprimer \(urls.count) élément(s)", role: .destructive) { delete(urls) }
            }
            .sheet(item: $share) { ShareSheet(items: $0.urls) }
            .onAppear { load() }
    }

    private var listView: some View {
        List(items, selection: $selection) { it in
            row(it)
                .contextMenu { menu(for: [it]) }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) { toDelete = [it.url] } label: { Label("Supprimer", systemImage: "trash") }
                }
                .swipeActions(edge: .leading) {
                    Button { clip.items = [it.url]; clip.cut = false } label: { Label("Copier", systemImage: "doc.on.doc") }.tint(.blue)
                }
        }
        .listStyle(.plain)
        .overlay { if items.isEmpty { Text("Dossier vide").foregroundColor(.secondary) } }
        .overlay {
            if let b = busy {
                HStack { ProgressView(); Text(b) }
                    .padding().background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
        .navigationTitle(title ?? dir.lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .environment(\.editMode, $editMode)
        .onChange(of: editMode) { m in if !m.isEditing { selection = [] } }
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                EditButton()
                Menu {
                    Button { newName = ""; showNewFolder = true } label: { Label("Nouveau dossier", systemImage: "folder.badge.plus") }
                    Button { newName = ""; showNewFile = true } label: { Label("Nouveau fichier", systemImage: "doc.badge.plus") }
                    Divider()
                    Button { importMode = .files; showImporter = true } label: { Label("Importer des fichiers", systemImage: "square.and.arrow.down") }
                    Button { importMode = .folder; showImporter = true } label: { Label("Importer un dossier", systemImage: "folder") }
                    Button { importMode = .archive; showImporter = true } label: { Label("Importer et extraire une archive", systemImage: "archivebox") }
                    if !clip.items.isEmpty {
                        Divider()
                        Button { paste() } label: { Label("Coller (\(clip.items.count))", systemImage: "doc.on.clipboard") }
                    }
                } label: { Image(systemName: "plus.circle") }
            }
        }
        .safeAreaInset(edge: .bottom) { actionBar }
    }

    @ViewBuilder private func row(_ it: FileItem) -> some View {
        if it.isDir {
            NavigationLink { FileBrowserView(dir: it.url, onChange: onChange) } label: { label(it) }
        } else {
            NavigationLink { FileOpenView(url: it.url, onChange: onChange) } label: { label(it) }
        }
    }

    private func label(_ it: FileItem) -> some View {
        HStack(spacing: 12) {
            Image(systemName: it.isDir ? "folder.fill" : fileIcon(it.name))
                .foregroundColor(it.isDir ? .blue : .secondary).frame(width: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(it.name).lineLimit(1)
                Text(it.isDir ? "Dossier" : FSOps.format(it.size)).font(.caption).foregroundColor(.secondary)
            }
        }
    }

    @ViewBuilder private func menu(for its: [FileItem]) -> some View {
        Button { clip.items = its.map(\.url); clip.cut = false } label: { Label("Copier", systemImage: "doc.on.doc") }
        Button { clip.items = its.map(\.url); clip.cut = true } label: { Label("Couper", systemImage: "scissors") }
        if its.count == 1, let it = its.first {
            Button { duplicate(it) } label: { Label("Dupliquer", systemImage: "plus.square.on.square") }
            Button { renaming = it; renameText = it.name } label: { Label("Renommer", systemImage: "pencil") }
            if !it.isDir && Archive.isArchive(it.url) {
                Button { extract(it) } label: { Label("Extraire ici", systemImage: "archivebox") }
            }
        }
        Button { share = ShareTarget(urls: its.map(\.url)) } label: { Label("Partager", systemImage: "square.and.arrow.up") }
        Button(role: .destructive) { toDelete = its.map(\.url) } label: { Label("Supprimer", systemImage: "trash") }
    }

    @ViewBuilder private var actionBar: some View {
        if editMode.isEditing && !selection.isEmpty {
            let sel = items.filter { selection.contains($0.url) }
            HStack(spacing: 28) {
                barButton("Copier", "doc.on.doc") { clip.items = sel.map(\.url); clip.cut = false; editMode = .inactive }
                barButton("Couper", "scissors") { clip.items = sel.map(\.url); clip.cut = true; editMode = .inactive }
                barButton("Partager", "square.and.arrow.up") { share = ShareTarget(urls: sel.map(\.url)) }
                barButton("Supprimer", "trash") { toDelete = sel.map(\.url) }
            }
            .padding(.vertical, 8).frame(maxWidth: .infinity).background(.bar)
        } else if !clip.items.isEmpty {
            HStack {
                Button { paste() } label: {
                    Label("\(clip.cut ? "Déplacer" : "Coller") \(clip.items.count) élément(s)", systemImage: "doc.on.clipboard")
                }
                .buttonStyle(.borderedProminent)
                Button("Vider") { clip.items = [] }
            }
            .padding(8).frame(maxWidth: .infinity).background(.bar)
        }
    }

    private func barButton(_ t: String, _ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) { Image(systemName: icon).font(.title3); Text(t).font(.caption2) }
        }
    }

    // MARK: actions
    private func load() { items = FSOps.list(dir) }

    private func create(folder: Bool) {
        let n = newName.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        let url = dir.appendingPathComponent(n)
        do {
            if folder { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
            else {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                if !FileManager.default.fileExists(atPath: url.path) { try Data().write(to: url) }
            }
        } catch { message = error.localizedDescription }
        load(); onChange()
    }

    private func rename() {
        guard let it = renaming else { return }
        let n = renameText.trimmingCharacters(in: .whitespaces)
        renaming = nil
        guard !n.isEmpty, n != it.name else { return }
        do { try FileManager.default.moveItem(at: it.url, to: it.url.deletingLastPathComponent().appendingPathComponent(n)) }
        catch { message = error.localizedDescription }
        load(); onChange()
    }

    private func duplicate(_ it: FileItem) {
        do { try FileManager.default.copyItem(at: it.url, to: FSOps.unique(it.url)) } catch { message = error.localizedDescription }
        load(); onChange()
    }

    private func delete(_ urls: [URL]) {
        for u in urls { try? FileManager.default.removeItem(at: u) }
        selection = []; toDelete = nil
        load(); onChange()
    }

    private func paste() {
        let src = clip.items.filter { FileManager.default.fileExists(atPath: $0.path) }
        startPlace(src, move: clip.cut, scoped: false)
    }

    private func startPlace(_ src: [URL], move: Bool, scoped: Bool) {
        let c = FSOps.conflicts(src, into: dir)
        let op = PendingOp(sources: src, move: move, conflicts: c, scoped: scoped)
        if c > 0 { pending = op } else { run(op, .keepBoth) }
    }

    private func run(_ op: PendingOp, _ policy: FSOps.Policy) {
        pending = nil
        let d = dir
        busy = op.move ? "Déplacement…" : "Copie…"
        Task {
            let result = await Task.detached { () -> Result<Int, Error> in
                Result { try FSOps.place(op.sources, move: op.move, into: d, policy: policy) }
            }.value
            if op.scoped { op.sources.forEach { $0.stopAccessingSecurityScopedResource() } }
            busy = nil
            switch result {
            case .success(let n):
                message = "\(n) élément(s) \(op.move ? "déplacé(s)" : "copié(s)")."
                if op.move { clip.items = []; clip.cut = false }
            case .failure(let e): message = e.localizedDescription
            }
            load(); onChange()
        }
    }

    private func handleImport(_ res: Result<[URL], Error>) {
        switch res {
        case .failure(let e): message = e.localizedDescription
        case .success(let urls):
            let scoped = urls.filter { $0.startAccessingSecurityScopedResource() }
            if importMode == .archive {
                busy = "Extraction…"
                let d = dir
                Task {
                    var total = 0
                    var err: String?
                    for u in urls {
                        let r = await Task.detached { () -> Result<Int, Error> in
                            Result { try Archive.extract(u, to: FSOps.unique(d.appendingPathComponent(Archive.baseName(u)))) }
                        }.value
                        switch r {
                        case .success(let n): total += n
                        case .failure(let e): err = e.localizedDescription
                        }
                    }
                    scoped.forEach { $0.stopAccessingSecurityScopedResource() }
                    busy = nil
                    message = err ?? "\(total) fichier(s) extraits."
                    load(); onChange()
                }
            } else {
                startPlace(urls, move: false, scoped: true)
            }
        }
    }

    private func extract(_ it: FileItem) {
        busy = "Extraction…"
        let d = dir
        Task {
            let r = await Task.detached { () -> Result<Int, Error> in
                Result { try Archive.extract(it.url, to: FSOps.unique(d.appendingPathComponent(Archive.baseName(it.url)))) }
            }.value
            busy = nil
            switch r {
            case .success(let n): message = "\(n) fichier(s) extraits dans « \(Archive.baseName(it.url)) »."
            case .failure(let e): message = e.localizedDescription
            }
            load(); onChange()
        }
    }
}

struct FileOpenView: View {
    let url: URL
    var onChange: () -> Void = {}
    @AppStorage("fontSize") private var fontSize = 14.0
    @State private var text = ""
    @State private var saved = ""
    @State private var mode = 0 // 0 chargement, 1 texte, 2 aperçu

    var body: some View {
        Group {
            if mode == 1 { CodeTextView(text: $text, ext: url.pathExtension.lowercased(), fontSize: CGFloat(fontSize)) }
            else if mode == 2 { QuickLookView(url: url).ignoresSafeArea() }
            else { ProgressView() }
        }
        .navigationTitle(url.lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if mode == 1 { Button("Enregistrer") { save() }.disabled(text == saved) }
            }
        }
        .task { await load() }
        .onDisappear { save() }
    }

    private func load() async {
        let u = url
        let r = await Task.detached { () -> String? in
            guard let d = try? Data(contentsOf: u), d.count < 1_500_000 else { return nil }
            return String(data: d, encoding: .utf8)
        }.value
        if let s = r { text = s; saved = s; mode = 1 } else { mode = 2 }
    }

    private func save() {
        guard mode == 1, text != saved else { return }
        try? text.write(to: url, atomically: true, encoding: .utf8)
        saved = text
        onChange()
    }
}

struct QuickLookView: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> QLPreviewController {
        let c = QLPreviewController()
        c.dataSource = context.coordinator
        return c
    }
    func updateUIViewController(_ c: QLPreviewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(url) }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(_ u: URL) { url = u }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { url as NSURL }
    }
}
