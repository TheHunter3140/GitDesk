import SwiftUI
import QuickLook
import UniformTypeIdentifiers
import ImageIO
import Combine

// MARK: - Modèles

struct FileItem: Identifiable, Hashable {
    let url: URL
    let isDir: Bool
    let size: Int64
    let date: Date
    var childCount: Int = 0
    var id: URL { url }
    var name: String { url.lastPathComponent }
    var ext: String { url.pathExtension.lowercased() }
    var isHidden: Bool { name.hasPrefix(".") }
}

struct ShareTarget: Identifiable {
    let id = UUID()
    let urls: [URL]
}

/// Type privé utilisé pour le glisser-déposer interne (déplacement entre dossiers).
fileprivate let gdDragType = UTType(exportedAs: "com.local.gitdesk.dragitem", conformingTo: .data)

// MARK: - Opérations disque

enum FSOps {
    static let fm = FileManager.default
    enum Policy { case replace, keepBoth, skip }

    /// Liste TOUT le contenu (fichiers cachés compris) : le filtrage se fait dans l'interface.
    static func list(_ dir: URL) -> [FileItem] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        let urls = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys, options: [])) ?? []
        return urls.map { u in
            let v = try? u.resourceValues(forKeys: Set(keys))
            let isDir = v?.isDirectory ?? false
            var count = 0
            if isDir {
                count = ((try? fm.contentsOfDirectory(atPath: u.path)) ?? []).filter { !$0.hasPrefix(".") }.count
            }
            return FileItem(url: u, isDir: isDir, size: Int64(v?.fileSize ?? 0),
                            date: v?.contentModificationDate ?? .distantPast, childCount: count)
        }
    }

    static func searchNames(in dir: URL, query: String, hidden: Bool, limit: Int = 300) -> [FileItem] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        let opts: FileManager.DirectoryEnumerationOptions = hidden ? [] : [.skipsHiddenFiles]
        guard let en = fm.enumerator(at: dir, includingPropertiesForKeys: keys, options: opts) else { return [] }
        var out: [FileItem] = []
        for case let u as URL in en {
            if u.lastPathComponent.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) == nil { continue }
            let v = try? u.resourceValues(forKeys: Set(keys))
            out.append(FileItem(url: u, isDir: v?.isDirectory ?? false, size: Int64(v?.fileSize ?? 0),
                                date: v?.contentModificationDate ?? .distantPast))
            if out.count >= limit { break }
        }
        return out
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

    static func stats(_ url: URL) -> (size: Int64, files: Int, folders: Int) {
        var size: Int64 = 0
        var files = 0
        var folders = 0
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey]
        if let en = fm.enumerator(at: url, includingPropertiesForKeys: keys) {
            for case let u as URL in en {
                let v = try? u.resourceValues(forKeys: Set(keys))
                if v?.isDirectory == true { folders += 1 } else { files += 1; size += Int64(v?.fileSize ?? 0) }
            }
        }
        return (size, files, folders)
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

// MARK: - Corbeille

enum Trash {
    struct Entry: Codable, Identifiable, Hashable {
        var id: String
        var name: String
        var original: String
        var date: Date
        var isDir: Bool
    }

    static var dir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GitDeskTrash", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private static var indexURL: URL { dir.appendingPathComponent("index.json") }

    static func entries() -> [Entry] {
        guard let d = try? Data(contentsOf: indexURL),
              let e = try? JSONDecoder().decode([Entry].self, from: d) else { return [] }
        return e.sorted { $0.date > $1.date }
    }

    private static func save(_ e: [Entry]) {
        if let d = try? JSONEncoder().encode(e) { try? d.write(to: indexURL, options: .atomic) }
    }

    static func add(_ urls: [URL]) throws -> Int {
        let fm = FileManager.default
        var all = entries()
        defer { save(all) }
        var n = 0
        for u in urls {
            let id = UUID().uuidString
            let slot = dir.appendingPathComponent(id, isDirectory: true)
            try fm.createDirectory(at: slot, withIntermediateDirectories: true)
            var isDir: ObjCBool = false
            fm.fileExists(atPath: u.path, isDirectory: &isDir)
            do {
                try fm.moveItem(at: u, to: slot.appendingPathComponent(u.lastPathComponent))
            } catch {
                try? fm.removeItem(at: slot)
                throw error
            }
            all.append(Entry(id: id, name: u.lastPathComponent, original: u.path, date: Date(), isDir: isDir.boolValue))
            n += 1
        }
        return n
    }

    /// Le chemin du conteneur change à chaque réinstallation : on le recalcule depuis « Documents ».
    static func resolve(_ original: String) -> URL {
        if let r = original.range(of: "/Documents/") {
            return Paths.documents.appendingPathComponent(String(original[r.upperBound...]))
        }
        return Paths.documents.appendingPathComponent("Restaurés").appendingPathComponent((original as NSString).lastPathComponent)
    }

    static func display(_ original: String) -> String {
        if let r = original.range(of: "/Documents/") { return String(original[r.upperBound...]) }
        return original
    }

    @discardableResult
    static func restore(_ e: Entry) throws -> URL {
        let fm = FileManager.default
        let slot = dir.appendingPathComponent(e.id, isDirectory: true)
        var dst = resolve(e.original)
        try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
        dst = FSOps.unique(dst)
        try fm.moveItem(at: slot.appendingPathComponent(e.name), to: dst)
        try? fm.removeItem(at: slot)
        save(entries().filter { $0.id != e.id })
        return dst
    }

    static func purge(_ e: Entry) {
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(e.id, isDirectory: true))
        save(entries().filter { $0.id != e.id })
    }

    static func empty() {
        for e in entries() { try? FileManager.default.removeItem(at: dir.appendingPathComponent(e.id, isDirectory: true)) }
        save([])
    }
}

@MainActor
final class FileClipboard: ObservableObject {
    @Published var items: [URL] = []
    @Published var cut = false
}

// MARK: - Icônes et miniatures

private func fileStyle(_ it: FileItem) -> (String, Color) {
    if it.isDir { return ("folder.fill", .blue) }
    switch it.ext {
    case "zip", "tar", "gz", "tgz", "7z", "rar": return ("archivebox.fill", .brown)
    case "ipa", "apk", "deb": return ("shippingbox.fill", .indigo)
    case "png", "jpg", "jpeg", "gif", "heic", "svg", "webp", "bmp", "tiff": return ("photo.fill", .pink)
    case "pdf": return ("doc.richtext.fill", .red)
    case "swift": return ("swift", .orange)
    case "py", "js", "ts", "sh", "html", "css", "c", "h", "cpp", "m", "java", "kt", "rb", "go", "rs":
        return ("chevron.left.forwardslash.chevron.right", .teal)
    case "json", "yml", "yaml", "toml", "plist", "xml", "xcconfig": return ("gearshape.fill", .gray)
    case "md", "txt", "rtf", "log": return ("doc.text.fill", .secondary)
    case "mp4", "mov", "m4v": return ("film.fill", .purple)
    case "mp3", "m4a", "wav", "aac": return ("music.note", .purple)
    case "gguf": return ("cpu.fill", .mint)
    default: return ("doc.fill", .secondary)
    }
}

enum Thumbs {
    static let cache = NSCache<NSString, UIImage>()
    static let imageExts: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "webp", "bmp", "tiff"]

    static func image(_ url: URL, side: CGFloat, stamp: Date) async -> UIImage? {
        let key = "\(url.path)|\(stamp.timeIntervalSince1970)|\(Int(side))" as NSString
        if let c = cache.object(forKey: key) { return c }
        let img = await Task.detached(priority: .utility) { () -> UIImage? in
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: Int(side * 2)
            ]
            guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
            return UIImage(cgImage: cg)
        }.value
        if let img { cache.setObject(img, forKey: key, cost: Int(img.size.width * img.size.height * img.scale * img.scale * 4)) }
        return img
    }
}

private struct ItemIcon: View {
    let item: FileItem
    let side: CGFloat
    @State private var thumb: UIImage?

    var body: some View {
        let st = fileStyle(item)
        ZStack {
            if let t = thumb {
                Image(uiImage: t).resizable().scaledToFill()
                    .frame(width: side, height: side)
                    .clipShape(RoundedRectangle(cornerRadius: side * 0.16, style: .continuous))
            } else {
                Image(systemName: st.0).font(.system(size: side * 0.6)).foregroundColor(st.1)
            }
        }
        .frame(width: side, height: side)
        .task(id: item.url) {
            guard !item.isDir, Thumbs.imageExts.contains(item.ext), item.size < 30_000_000 else { thumb = nil; return }
            thumb = await Thumbs.image(item.url, side: side, stamp: item.date)
        }
    }
}

private struct OptionalTitle: ViewModifier {
    let title: String?
    func body(content: Content) -> some View {
        if let t = title {
            content.navigationTitle(t).navigationBarTitleDisplayMode(.inline)
        } else {
            content
        }
    }
}

// MARK: - Explorateur

struct FileBrowserView: View {
    let dir: URL
    var title: String? = nil
    var onChange: () -> Void = {}
    /// Dépôt GitDesk : ouvre l'éditeur du dépôt et colore les fichiers modifiés.
    var ws: Workspace? = nil
    var gitChanges: [Change] = []
    /// Dans un onglet : pas de titre ni de bouton retour système.
    var embedded = false

    init(dir: URL, title: String? = nil, onChange: @escaping () -> Void = {},
         ws: Workspace? = nil, gitChanges: [Change] = [], embedded: Bool = false) {
        self.dir = dir
        self.title = title
        self.onChange = onChange
        self.ws = ws
        self.gitChanges = gitChanges
        self.embedded = embedded
        _current = State(initialValue: dir)
    }

    @EnvironmentObject var clip: FileClipboard
    @Environment(\.scenePhase) private var scenePhase

    @AppStorage("fm.showHidden") private var showHidden = false
    @AppStorage("fm.grid") private var grid = false
    @AppStorage("fm.sort") private var sortKey = "name"
    @AppStorage("fm.asc") private var ascending = true
    @AppStorage("fm.foldersFirst") private var foldersFirst = true

    @State private var current: URL
    @State private var items: [FileItem] = []
    @State private var shown: [FileItem] = []
    @State private var sig = ""
    @State private var selecting = false
    @State private var selection = Set<URL>()
    @State private var filter = ""
    @State private var nameHits: [FileItem] = []
    @State private var contentHits: [SearchHit] = []
    @State private var contentSearched = false

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
    @State private var opened: URL?
    @State private var preview: URL?
    @State private var info: FileItem?
    @State private var picker: PickerRequest?
    @State private var showTrash = false
    @State private var dropTarget: URL?
    @State private var bgTarget = false

    private let ticker = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

    enum ImportMode { case files, folder, archive }
    struct PendingOp { var sources: [URL]; var move: Bool; var conflicts: Int; var scoped: Bool; var target: URL }
    struct PickerRequest: Identifiable {
        enum Mode { case move, copy, extract }
        let id = UUID()
        let urls: [URL]
        let mode: Mode
    }
    private struct Crumb: Identifiable { let url: URL; let name: String; var id: URL { url } }
    private struct GitInfo { var files: [String: Change.Kind] = [:]; var dirs: Set<String> = [] }

    private var dropTypes: [UTType] { [gdDragType, .item] }
    private var viewKey: String { "\(showHidden)|\(sortKey)|\(ascending)|\(foldersFirst)" }

    // MARK: corps

    private var base: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            footer
        }
        .modifier(OptionalTitle(title: embedded ? nil : (canGoUp ? current.lastPathComponent : (title ?? dir.lastPathComponent))))
        .navigationBarBackButtonHidden(!embedded && canGoUp)
        .searchable(text: $filter, prompt: ws == nil ? "Rechercher par nom" : "Nom de fichier ou code")
        .onSubmit(of: .search) { runContentSearch() }
        .safeAreaInset(edge: .bottom, spacing: 0) { actionBar }
        .simultaneousGesture(edgeSwipe)
        .navigationDestination(isPresented: Binding(get: { opened != nil }, set: { if !$0 { opened = nil } })) {
            if let u = opened { destination(u) }
        }
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: importMode == .folder ? [.folder] : [.item],
                      allowsMultipleSelection: importMode != .folder) { handleImport($0) }
        .task(id: filter) { await runNameSearch() }
        .onAppear { load() }
        .onReceive(ticker) { _ in
            if scenePhase == .active, busy == nil, signature() != sig { load() }
        }
        .onChange(of: scenePhase) { p in if p == .active { load() } }
        .onChange(of: viewKey) { _ in refilter() }
        .onChange(of: busy) { b in
            if b != nil { ActivityKeeper.shared.hold("files") } else { ActivityKeeper.shared.release("files") }
        }
    }

    var body: some View {
        base
            .alert("Nouveau dossier", isPresented: $showNewFolder) {
                TextField("Nom", text: $newName).textInputAutocapitalization(.never).autocorrectionDisabled()
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
                Button("Mettre \(urls.count) élément(s) à la corbeille", role: .destructive) { delete(urls, permanent: false) }
                Button("Supprimer définitivement", role: .destructive) { delete(urls, permanent: true) }
            } message: { urls in Text(urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) éléments") }
            .sheet(item: $share) { ShareSheet(items: $0.urls) }
            .sheet(item: $info) { FileInfoView(item: $0) }
            .sheet(isPresented: $showTrash) { TrashView(onChange: { load(); onChange() }) }
            .sheet(item: $picker) { req in
                FolderPicker(root: dir, start: current,
                             exclude: req.mode == .extract ? [] : req.urls,
                             rootName: title ?? dir.lastPathComponent,
                             confirm: req.mode == .move ? "Déplacer ici" : (req.mode == .copy ? "Copier ici" : "Extraire ici"),
                             onPick: { picked(req, $0) })
            }
            .quickLookPreview($preview)
    }

    // MARK: en-tête

    private var header: some View {
        VStack(spacing: 6) {
            breadcrumb
            toolbarRow
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private var crumbs: [Crumb] {
        var out = [Crumb(url: dir, name: title ?? dir.lastPathComponent)]
        let rc = dir.standardizedFileURL.pathComponents.count
        let comps = current.standardizedFileURL.pathComponents
        var u = dir
        if comps.count > rc {
            for c in comps[rc...] {
                u = u.appendingPathComponent(c)
                out.append(Crumb(url: u, name: c))
            }
        }
        return out
    }

    private var breadcrumb: some View {
        let list = crumbs
        return ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(Array(list.enumerated()), id: \.element.id) { i, c in
                        if i > 0 { Image(systemName: "chevron.right").font(.caption2).foregroundColor(.secondary) }
                        Button { go(c.url) } label: {
                            Text(c.name)
                                .font(.subheadline.weight(i == list.count - 1 ? .semibold : .regular))
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(dropTarget == c.url ? Color.accentColor.opacity(0.3) : Color.clear, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .onDrop(of: dropTypes, isTargeted: targetBinding(c.url)) { handleDrop($0, into: c.url) }
                        .id(c.url)
                    }
                }
            }
            .onChange(of: current) { u in withAnimation { proxy.scrollTo(u, anchor: .trailing) } }
        }
    }

    @ViewBuilder private var toolbarRow: some View {
        if selecting {
            HStack(spacing: 14) {
                Button(selection.count == shown.count && !shown.isEmpty ? "Aucun" : "Tout") {
                    if selection.count == shown.count { selection = [] } else { selection = Set(shown.map(\.url)) }
                }
                Text(selection.isEmpty ? "Sélection" : "\(selection.count) sélectionné(s)")
                    .font(.subheadline).foregroundColor(.secondary)
                Spacer()
                Button("Terminé") { endSelect() }.fontWeight(.semibold)
            }
        } else {
            HStack(spacing: 18) {
                if canGoUp {
                    Button { goUp() } label: { Image(systemName: "chevron.left.circle") }
                        .accessibilityLabel("Dossier parent")
                }
                Spacer()
                Button { selecting = true } label: { Image(systemName: "checkmark.circle") }
                    .accessibilityLabel("Sélectionner")
                Button { showHidden.toggle() } label: { Image(systemName: showHidden ? "eye" : "eye.slash") }
                    .accessibilityLabel(showHidden ? "Masquer les fichiers cachés" : "Afficher les fichiers cachés")
                plusMenu
                viewMenu
            }
            .font(.title3)
        }
    }

    private var plusMenu: some View {
        Menu {
            Button { newName = ""; showNewFolder = true } label: { Label("Nouveau dossier", systemImage: "folder.badge.plus") }
            Button { newName = ""; showNewFile = true } label: { Label("Nouveau fichier", systemImage: "doc.badge.plus") }
            Divider()
            Button { importMode = .files; showImporter = true } label: { Label("Importer des fichiers", systemImage: "square.and.arrow.down") }
            Button { importMode = .folder; showImporter = true } label: { Label("Importer un dossier", systemImage: "folder") }
            Button { importMode = .archive; showImporter = true } label: { Label("Importer et extraire une archive", systemImage: "archivebox") }
            if !clip.items.isEmpty {
                Divider()
                Button { paste(into: current) } label: { Label("Coller (\(clip.items.count))", systemImage: "doc.on.clipboard") }
            }
        } label: { Image(systemName: "plus.circle") }
    }

    private var viewMenu: some View {
        Menu {
            Picker("Affichage", selection: $grid) {
                Label("Liste", systemImage: "list.bullet").tag(false)
                Label("Grille", systemImage: "square.grid.2x2").tag(true)
            }
            Picker("Trier par", selection: $sortKey) {
                Text("Nom").tag("name")
                Text("Date").tag("date")
                Text("Taille").tag("size")
                Text("Type").tag("type")
            }
            Toggle("Ordre croissant", isOn: $ascending)
            Toggle("Dossiers en premier", isOn: $foldersFirst)
            Toggle("Fichiers cachés", isOn: $showHidden)
            Divider()
            Button { load(); onChange() } label: { Label("Actualiser", systemImage: "arrow.clockwise") }
            Button { showTrash = true } label: { Label("Corbeille (\(Trash.entries().count))", systemImage: "trash") }
        } label: { Image(systemName: "ellipsis.circle") }
    }

    private var footer: some View {
        let hidden = items.filter(\.isHidden).count
        return HStack {
            Text("\(shown.count) élément(s)" + (hidden > 0 && !showHidden ? " · \(hidden) caché(s)" : ""))
                .font(.caption2).foregroundColor(.secondary)
            Spacer()
            if hidden > 0 && !showHidden {
                Button("Afficher les cachés") { showHidden = true }.font(.caption2)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 4)
        .background(.bar)
    }

    // MARK: contenu

    @ViewBuilder private var content: some View {
        Group {
            if !filter.trimmingCharacters(in: .whitespaces).isEmpty { searchView }
            else if grid { gridView }
            else { listView }
        }
        .onDrop(of: dropTypes, isTargeted: $bgTarget) { handleDrop($0, into: current) }
        .overlay {
            if bgTarget {
                RoundedRectangle(cornerRadius: 10).stroke(Color.accentColor, lineWidth: 2).padding(2).allowsHitTesting(false)
            }
        }
        .overlay {
            if let b = busy {
                HStack { ProgressView(); Text(b) }
                    .padding().background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
    }

    private var listView: some View {
        let git = makeGit()
        return List {
            ForEach(shown) { it in
                interactive(it, listRow(it, git))
                    .listRowBackground(dropTarget == it.url ? Color.accentColor.opacity(0.18) : Color.clear)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) { toDelete = [it.url] } label: { Label("Supprimer", systemImage: "trash") }
                        Button { renaming = it; renameText = it.name } label: { Label("Renommer", systemImage: "pencil") }.tint(.orange)
                    }
                    .swipeActions(edge: .leading) {
                        Button { clip.items = [it.url]; clip.cut = false } label: { Label("Copier", systemImage: "doc.on.doc") }.tint(.blue)
                        Button { clip.items = [it.url]; clip.cut = true } label: { Label("Couper", systemImage: "scissors") }.tint(.indigo)
                    }
            }
        }
        .listStyle(.plain)
        .refreshable { load(); onChange() }
        .overlay { emptyOverlay }
    }

    private var gridView: some View {
        let git = makeGit()
        return ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 8)], spacing: 12) {
                ForEach(shown) { it in
                    interactive(it, gridCell(it, git))
                }
            }
            .padding(12)
        }
        .refreshable { load(); onChange() }
        .overlay { emptyOverlay }
    }

    @ViewBuilder private var emptyOverlay: some View {
        if shown.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "folder").font(.largeTitle).foregroundColor(.secondary)
                Text(items.isEmpty ? "Dossier vide" : "Il n'y a que des fichiers cachés ici").foregroundColor(.secondary)
                if !items.isEmpty && !showHidden {
                    Button("Afficher les fichiers cachés") { showHidden = true }
                }
            }
        }
    }

    private var searchView: some View {
        List {
            Section("Dans « \(current.lastPathComponent) » et ses sous-dossiers") {
                if nameHits.isEmpty { Text("Aucun nom ne correspond.").foregroundColor(.secondary) }
                ForEach(nameHits) { it in
                    Button { openHit(it) } label: {
                        HStack(spacing: 12) {
                            ItemIcon(item: it, side: 30)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(it.name).lineLimit(1)
                                Text(FS.rel(current, it.url.deletingLastPathComponent()).isEmpty ? "Ce dossier" : FS.rel(current, it.url.deletingLastPathComponent()))
                                    .font(.caption).foregroundColor(.secondary).lineLimit(1).truncationMode(.head)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            if let w = ws {
                Section("Dans le code") {
                    if !contentSearched {
                        Text("Touche « Rechercher » au clavier pour chercher dans le texte de tous les fichiers.").foregroundColor(.secondary)
                    } else if contentHits.isEmpty {
                        Text("Aucun résultat.").foregroundColor(.secondary)
                    }
                    ForEach(contentHits) { h in
                        Button { opened = w.root.appendingPathComponent(h.path) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(h.text).font(.system(size: 13, design: .monospaced)).lineLimit(2)
                                Text("\(h.path):\(h.line)").font(.caption).foregroundColor(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .listStyle(.plain)
    }

    // MARK: lignes et cellules

    private func gitKind(_ it: FileItem, _ g: GitInfo) -> Change.Kind? {
        guard let w = ws, !it.isDir else { return nil }
        return g.files[FS.rel(w.root, it.url)]
    }

    private func gitDirty(_ it: FileItem, _ g: GitInfo) -> Bool {
        guard let w = ws, it.isDir else { return false }
        return g.dirs.contains(FS.rel(w.root, it.url))
    }

    private func kindColor(_ k: Change.Kind) -> Color {
        switch k { case .added: return .green; case .modified: return .orange; case .deleted: return .red }
    }

    private func subtitle(_ it: FileItem) -> String {
        let d = it.date.formatted(date: .abbreviated, time: .shortened)
        if it.isDir { return "\(it.childCount) élément(s) · \(d)" }
        return "\(FSOps.format(it.size)) · \(d)"
    }

    private func listRow(_ it: FileItem, _ g: GitInfo) -> some View {
        let kind = gitKind(it, g)
        let isSel = selection.contains(it.url)
        return Button { tap(it) } label: {
            HStack(spacing: 12) {
                if selecting {
                    Image(systemName: isSel ? "checkmark.circle.fill" : "circle")
                        .foregroundColor(isSel ? .accentColor : .secondary)
                }
                ItemIcon(item: it, side: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text(it.name).lineLimit(1)
                        .foregroundColor(kind.map(kindColor) ?? .primary)
                    Text(subtitle(it)).font(.caption).foregroundColor(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                if let k = kind {
                    Text(k.rawValue).font(.system(.caption, design: .monospaced).weight(.bold))
                        .foregroundColor(kindColor(k))
                } else if gitDirty(it, g) {
                    Circle().fill(Color.orange).frame(width: 8, height: 8)
                }
                if it.isDir && !selecting { Image(systemName: "chevron.right").font(.caption).foregroundColor(.secondary.opacity(0.6)) }
            }
            .opacity(it.isHidden || (clip.cut && clip.items.contains(it.url)) ? 0.55 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func gridCell(_ it: FileItem, _ g: GitInfo) -> some View {
        let kind = gitKind(it, g)
        let isSel = selection.contains(it.url)
        return Button { tap(it) } label: {
            VStack(spacing: 4) {
                ZStack(alignment: .topTrailing) {
                    ItemIcon(item: it, side: 62)
                    if selecting {
                        Image(systemName: isSel ? "checkmark.circle.fill" : "circle")
                            .foregroundColor(isSel ? .accentColor : .secondary)
                            .background(Circle().fill(Color(.systemBackground)))
                    } else if let k = kind {
                        Text(k.rawValue).font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundColor(.white).padding(3).background(kindColor(k), in: Circle())
                    } else if gitDirty(it, g) {
                        Circle().fill(Color.orange).frame(width: 9, height: 9)
                    }
                }
                Text(it.name).font(.caption).lineLimit(2).multilineTextAlignment(.center)
                    .foregroundColor(kind.map(kindColor) ?? .primary)
            }
            .frame(maxWidth: .infinity)
            .padding(6)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(dropTarget == it.url ? Color.accentColor.opacity(0.2) : (isSel ? Color.accentColor.opacity(0.12) : Color.clear))
            )
            .opacity(it.isHidden || (clip.cut && clip.items.contains(it.url)) ? 0.55 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Menu contextuel, glisser et déposer communs à la liste et à la grille.
    private func interactive<V: View>(_ it: FileItem, _ v: V) -> some View {
        v
            .contextMenu { menu(for: selecting && selection.contains(it.url) ? items.filter { selection.contains($0.url) } : [it]) }
            .onDrag { dragProvider(it) }
            .onDrop(of: it.isDir ? dropTypes : [], isTargeted: targetBinding(it.url)) { handleDrop($0, into: it.url) }
    }

    @ViewBuilder private func menu(for its: [FileItem]) -> some View {
        let urls = its.map(\.url)
        if its.count == 1, let it = its.first {
            if it.isDir {
                Button { go(it.url) } label: { Label("Ouvrir", systemImage: "folder") }
            } else {
                Button { open(it) } label: { Label("Ouvrir", systemImage: "doc.text") }
                Button { preview = it.url } label: { Label("Aperçu rapide", systemImage: "eye") }
            }
            Divider()
        }
        Button { clip.items = urls; clip.cut = false } label: { Label("Copier", systemImage: "doc.on.doc") }
        Button { clip.items = urls; clip.cut = true } label: { Label("Couper", systemImage: "scissors") }
        if its.count == 1, let it = its.first, it.isDir, !clip.items.isEmpty {
            Button { paste(into: it.url) } label: { Label("Coller dans « \(it.name) »", systemImage: "doc.on.clipboard") }
        }
        Button { picker = PickerRequest(urls: urls, mode: .move) } label: { Label("Déplacer vers…", systemImage: "folder.badge.gearshape") }
        Button { picker = PickerRequest(urls: urls, mode: .copy) } label: { Label("Copier vers…", systemImage: "doc.on.doc.fill") }
        if its.count == 1, let it = its.first {
            Button { duplicate(it) } label: { Label("Dupliquer", systemImage: "plus.square.on.square") }
            Button { renaming = it; renameText = it.name } label: { Label("Renommer", systemImage: "pencil") }
        }
        Button { compress(urls) } label: { Label("Compresser en ZIP", systemImage: "archivebox") }
        if its.count == 1, let it = its.first, !it.isDir, Archive.isArchive(it.url) {
            Button { extract(it.url, to: current) } label: { Label("Extraire ici", systemImage: "arrow.down.doc") }
            Button { picker = PickerRequest(urls: [it.url], mode: .extract) } label: { Label("Extraire vers…", systemImage: "arrow.down.doc.fill") }
        }
        Divider()
        if its.count == 1, let it = its.first {
            Button { info = it } label: { Label("Informations", systemImage: "info.circle") }
            Button { UIPasteboard.general.string = it.url.path } label: { Label("Copier le chemin", systemImage: "link") }
        }
        Button { share = ShareTarget(urls: urls) } label: { Label("Partager", systemImage: "square.and.arrow.up") }
        Divider()
        Button(role: .destructive) { toDelete = urls } label: { Label("Supprimer", systemImage: "trash") }
    }

    // MARK: barre d'actions

    @ViewBuilder private var actionBar: some View {
        if selecting {
            let sel = items.filter { selection.contains($0.url) }
            HStack(spacing: 0) {
                barButton("Copier", "doc.on.doc") { clip.items = sel.map(\.url); clip.cut = false; endSelect() }
                barButton("Couper", "scissors") { clip.items = sel.map(\.url); clip.cut = true; endSelect() }
                barButton("Déplacer", "folder.badge.gearshape") { picker = PickerRequest(urls: sel.map(\.url), mode: .move) }
                barButton("Partager", "square.and.arrow.up") { share = ShareTarget(urls: sel.map(\.url)) }
                barButton("Supprimer", "trash") { toDelete = sel.map(\.url) }
                Menu { menu(for: sel) } label: {
                    VStack(spacing: 2) { Image(systemName: "ellipsis.circle").font(.title3); Text("Plus").font(.caption2) }
                        .frame(maxWidth: .infinity)
                }
            }
            .disabled(sel.isEmpty)
            .padding(.vertical, 6)
            .background(.bar)
        } else if !clip.items.isEmpty {
            HStack {
                Button { paste(into: current) } label: {
                    Label("\(clip.cut ? "Déplacer" : "Coller") \(clip.items.count) élément(s) ici", systemImage: "doc.on.clipboard")
                }
                .buttonStyle(.borderedProminent)
                Button("Vider") { clip.items = []; clip.cut = false }
            }
            .padding(8).frame(maxWidth: .infinity).background(.bar)
        }
    }

    private func barButton(_ t: String, _ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) { Image(systemName: icon).font(.title3); Text(t).font(.caption2) }
                .frame(maxWidth: .infinity)
        }
    }

    // MARK: navigation

    private var canGoUp: Bool {
        current.standardizedFileURL.pathComponents.count > dir.standardizedFileURL.pathComponents.count
    }

    private var edgeSwipe: some Gesture {
        DragGesture(minimumDistance: 25).onEnded { v in
            if canGoUp && v.startLocation.x < 40 && v.translation.width > 80 && abs(v.translation.height) < 70 { goUp() }
        }
    }

    private func goUp() {
        guard canGoUp else { return }
        go(current.deletingLastPathComponent())
    }

    private func go(_ u: URL) {
        withAnimation(.easeInOut(duration: 0.18)) { current = u }
        selection = []
        filter = ""
        load()
    }

    private func open(_ it: FileItem) {
        if it.isDir { go(it.url) } else { opened = it.url }
    }

    private func openHit(_ it: FileItem) {
        if it.isDir { go(it.url) } else {
            go(it.url.deletingLastPathComponent())
            opened = it.url
        }
    }

    private func tap(_ it: FileItem) {
        if selecting {
            if selection.contains(it.url) { selection.remove(it.url) } else { selection.insert(it.url) }
        } else {
            open(it)
        }
    }

    private func endSelect() { selecting = false; selection = [] }

    @ViewBuilder private func destination(_ u: URL) -> some View {
        if let w = ws { EditorView(ws: w, path: FS.rel(w.root, u)) }
        else { FileOpenView(url: u, onChange: onChange) }
    }

    // MARK: chargement, tri, recherche

    private func load() {
        items = FSOps.list(current)
        sig = signature()
        refilter()
    }

    private func signature() -> String {
        let a = try? FSOps.fm.attributesOfItem(atPath: current.path)
        let d = (a?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let n = (try? FSOps.fm.contentsOfDirectory(atPath: current.path).count) ?? 0
        return "\(d)-\(n)"
    }

    private func refilter() {
        var a = items
        if !showHidden { a = a.filter { !$0.isHidden } }
        let key = sortKey
        let asc = ascending
        let first = foldersFirst
        func cmp(_ x: FileItem, _ y: FileItem) -> Int {
            switch key {
            case "date": return x.date < y.date ? -1 : (x.date > y.date ? 1 : 0)
            case "size": return x.size < y.size ? -1 : (x.size > y.size ? 1 : 0)
            case "type":
                if x.ext != y.ext { return x.ext < y.ext ? -1 : 1 }
            default: break
            }
            switch x.name.localizedCaseInsensitiveCompare(y.name) {
            case .orderedAscending: return -1
            case .orderedDescending: return 1
            case .orderedSame: return 0
            }
        }
        a.sort { x, y in
            if first && x.isDir != y.isDir { return x.isDir }
            let c = cmp(x, y)
            if c == 0 { return false }
            return asc ? c < 0 : c > 0
        }
        shown = a
        selection = selection.filter { s in a.contains { $0.url == s } }
    }

    private func runNameSearch() async {
        let q = filter.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { nameHits = []; contentHits = []; contentSearched = false; return }
        do { try await Task.sleep(nanoseconds: 300_000_000) } catch { return }
        let d = current
        let hidden = showHidden
        let r = await Task.detached { FSOps.searchNames(in: d, query: q, hidden: hidden) }.value
        if q == filter.trimmingCharacters(in: .whitespaces) { nameHits = r }
        contentSearched = false
    }

    private func runContentSearch() {
        guard let w = ws else { return }
        let q = filter.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        Task {
            contentHits = await w.search(q)
            contentSearched = true
        }
    }

    private func makeGit() -> GitInfo {
        var g = GitInfo()
        guard ws != nil else { return g }
        for c in gitChanges {
            g.files[c.path] = c.kind
            var comps = c.path.split(separator: "/").map(String.init)
            if comps.isEmpty { continue }
            comps.removeLast()
            var acc = ""
            for p in comps {
                acc = acc.isEmpty ? p : acc + "/" + p
                g.dirs.insert(acc)
            }
        }
        return g
    }

    // MARK: glisser-déposer

    private func targetBinding(_ u: URL) -> Binding<Bool> {
        Binding(get: { dropTarget == u }, set: { on in
            if on { dropTarget = u } else if dropTarget == u { dropTarget = nil }
        })
    }

    private func dragProvider(_ it: FileItem) -> NSItemProvider {
        let urls = (selecting && selection.contains(it.url)) ? items.filter { selection.contains($0.url) }.map(\.url) : [it.url]
        let p: NSItemProvider
        if it.isDir {
            p = NSItemProvider()
            let u = it.url
            p.registerFileRepresentation(forTypeIdentifier: UTType.folder.identifier, fileOptions: [.openInPlace], visibility: .all) { done in
                done(u, true, nil)
                return nil
            }
        } else {
            p = NSItemProvider(contentsOf: it.url) ?? NSItemProvider()
        }
        p.suggestedName = it.name
        let paths = urls.map(\.path)
        p.registerDataRepresentation(forTypeIdentifier: gdDragType.identifier, visibility: .ownProcess) { done in
            done(try? JSONEncoder().encode(paths), nil)
            return nil
        }
        return p
    }

    private func handleDrop(_ providers: [NSItemProvider], into target: URL) -> Bool {
        let own = providers.filter { $0.hasItemConformingToTypeIdentifier(gdDragType.identifier) }
        if !own.isEmpty {
            for p in own {
                p.loadDataRepresentation(forTypeIdentifier: gdDragType.identifier) { data, _ in
                    guard let data = data, let paths = try? JSONDecoder().decode([String].self, from: data) else { return }
                    let urls = paths.map { URL(fileURLWithPath: $0) }
                    DispatchQueue.main.async { startPlace(urls, move: true, scoped: false, into: target) }
                }
            }
            return true
        }
        var handled = false
        for p in providers where p.hasItemConformingToTypeIdentifier(UTType.item.identifier) {
            handled = true
            let tid = p.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: .item) == true }) ?? UTType.item.identifier
            p.loadFileRepresentation(forTypeIdentifier: tid) { url, _ in
                guard let url = url else { return }
                let fm = FileManager.default
                let tmpDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
                try? fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
                let dest = tmpDir.appendingPathComponent(url.lastPathComponent)
                do { try fm.copyItem(at: url, to: dest) } catch { return }
                DispatchQueue.main.async { startPlace([dest], move: true, scoped: false, into: target) }
            }
        }
        return handled
    }

    // MARK: actions

    private func validName(_ raw: String) -> String? {
        let n = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if n.isEmpty || n == "." || n == ".." { return nil }
        if n.contains("/") {
            message = "Un nom ne peut pas contenir « / ». Pour ranger dans un dossier, utilise « Déplacer vers… » ou glisse-dépose."
            return nil
        }
        return n
    }

    private func create(folder: Bool) {
        guard let n = validName(newName) else { return }
        let url = current.appendingPathComponent(n)
        if FSOps.fm.fileExists(atPath: url.path) { message = "« \(n) » existe déjà ici."; return }
        do {
            if folder { try FSOps.fm.createDirectory(at: url, withIntermediateDirectories: false) }
            else { try Data().write(to: url) }
        } catch { message = error.localizedDescription }
        load(); onChange()
    }

    private func rename() {
        guard let it = renaming else { return }
        renaming = nil
        guard let n = validName(renameText), n != it.name else { return }
        let dst = it.url.deletingLastPathComponent().appendingPathComponent(n)
        if FSOps.fm.fileExists(atPath: dst.path) { message = "« \(n) » existe déjà ici."; return }
        do { try FSOps.fm.moveItem(at: it.url, to: dst) } catch { message = error.localizedDescription }
        load(); onChange()
    }

    private func duplicate(_ it: FileItem) {
        do { try FSOps.fm.copyItem(at: it.url, to: FSOps.unique(it.url)) } catch { message = error.localizedDescription }
        load(); onChange()
    }

    private func delete(_ urls: [URL], permanent: Bool) {
        toDelete = nil
        var err: String?
        if permanent {
            for u in urls {
                do { try FSOps.fm.removeItem(at: u) } catch { err = error.localizedDescription }
            }
        } else {
            do { _ = try Trash.add(urls) } catch { err = error.localizedDescription }
        }
        endSelect()
        if let e = err { message = e }
        load(); onChange()
    }

    private func paste(into target: URL) {
        let src = clip.items.filter { FSOps.fm.fileExists(atPath: $0.path) }
        guard !src.isEmpty else { clip.items = []; return }
        startPlace(src, move: clip.cut, scoped: false, into: target)
    }

    private func picked(_ req: PickerRequest, _ dest: URL) {
        switch req.mode {
        case .move: startPlace(req.urls, move: true, scoped: false, into: dest)
        case .copy: startPlace(req.urls, move: false, scoped: false, into: dest)
        case .extract: if let u = req.urls.first { extract(u, to: dest) }
        }
        endSelect()
    }

    private func startPlace(_ src: [URL], move: Bool, scoped: Bool, into target: URL) {
        let c = FSOps.conflicts(src, into: target)
        let op = PendingOp(sources: src, move: move, conflicts: c, scoped: scoped, target: target)
        if c > 0 { pending = op } else { run(op, .keepBoth) }
    }

    private func run(_ op: PendingOp, _ policy: FSOps.Policy) {
        pending = nil
        let d = op.target
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
                let d = current
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
                startPlace(urls, move: false, scoped: true, into: current)
            }
        }
    }

    private func extract(_ url: URL, to base: URL) {
        busy = "Extraction…"
        Task {
            let r = await Task.detached { () -> Result<Int, Error> in
                Result { try Archive.extract(url, to: FSOps.unique(base.appendingPathComponent(Archive.baseName(url)))) }
            }.value
            busy = nil
            switch r {
            case .success(let n): message = "\(n) fichier(s) extraits dans « \(Archive.baseName(url)) »."
            case .failure(let e): message = e.localizedDescription
            }
            load(); onChange()
        }
    }

    private func compress(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        busy = "Compression…"
        let d = current
        Task {
            let r = await Task.detached { () -> Result<URL, Error> in
                Result {
                    let fm = FileManager.default
                    let name = urls.count == 1 ? urls[0].deletingPathExtension().lastPathComponent : "Archive"
                    let dest = FSOps.unique(d.appendingPathComponent(name + ".zip"))
                    let single = urls.count == 1 && ((try? urls[0].resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false)
                    if single {
                        try ZipWriter.zip(directory: urls[0], to: dest)
                    } else {
                        let tmp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
                        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
                        defer { try? fm.removeItem(at: tmp) }
                        for u in urls { try fm.copyItem(at: u, to: tmp.appendingPathComponent(u.lastPathComponent)) }
                        try ZipWriter.zip(directory: tmp, to: dest)
                    }
                    return dest
                }
            }.value
            busy = nil
            switch r {
            case .success(let u): message = "Archive créée : « \(u.lastPathComponent) »."
            case .failure(let e): message = e.localizedDescription
            }
            endSelect()
            load(); onChange()
        }
    }
}

// MARK: - Sélecteur de dossier

struct FolderPicker: View {
    let root: URL
    let start: URL
    var exclude: [URL] = []
    var rootName: String = "Racine"
    var confirm: String = "Choisir ici"
    let onPick: (URL) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var cur: URL
    @State private var folders: [URL] = []
    @State private var showNew = false
    @State private var newName = ""
    @State private var error: String?

    init(root: URL, start: URL, exclude: [URL] = [], rootName: String = "Racine",
         confirm: String = "Choisir ici", onPick: @escaping (URL) -> Void) {
        self.root = root
        self.start = start
        self.exclude = exclude
        self.rootName = rootName
        self.confirm = confirm
        self.onPick = onPick
        _cur = State(initialValue: start)
    }

    private var atRoot: Bool {
        cur.standardizedFileURL.pathComponents.count <= root.standardizedFileURL.pathComponents.count
    }

    var body: some View {
        NavigationStack {
            List {
                if !atRoot {
                    Button { cur = cur.deletingLastPathComponent() } label: {
                        Label("Dossier parent", systemImage: "arrow.turn.up.left")
                    }
                }
                ForEach(folders, id: \.self) { f in
                    Button { cur = f } label: {
                        HStack {
                            Label(f.lastPathComponent, systemImage: "folder.fill")
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption).foregroundColor(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
                if folders.isEmpty { Text("Aucun sous-dossier.").foregroundColor(.secondary) }
            }
            .listStyle(.plain)
            .navigationTitle(atRoot ? rootName : cur.lastPathComponent)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annuler") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button { newName = ""; showNew = true } label: { Image(systemName: "folder.badge.plus") }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button { onPick(cur); dismiss() } label: {
                    Text("\(confirm) · \(atRoot ? rootName : cur.lastPathComponent)").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .padding(10).background(.bar)
            }
            .alert("Nouveau dossier", isPresented: $showNew) {
                TextField("Nom", text: $newName).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Créer") { createFolder() }
                Button("Annuler", role: .cancel) {}
            }
            .alert("Info", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK") {}
            } message: { Text(error ?? "") }
            .onAppear { reload() }
            .onChange(of: cur) { _ in reload() }
        }
    }

    private func reload() {
        let all = FSOps.list(cur).filter { $0.isDir && !$0.isHidden }
        let ex = exclude.map { $0.standardizedFileURL }
        folders = all.map(\.url)
            .filter { !ex.contains($0.standardizedFileURL) }
            .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
    }

    private func createFolder() {
        let n = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, !n.contains("/") else { error = "Nom invalide (« / » interdit)."; return }
        do { try FSOps.fm.createDirectory(at: cur.appendingPathComponent(n), withIntermediateDirectories: false) }
        catch { self.error = error.localizedDescription }
        reload()
    }
}

// MARK: - Informations

struct FileInfoView: View {
    let item: FileItem
    @Environment(\.dismiss) private var dismiss
    @State private var stats: (size: Int64, files: Int, folders: Int)?
    @State private var created: Date?
    @State private var modified: Date?
    @State private var perms = ""

    private var kindText: String {
        if item.isDir { return "Dossier" }
        return UTType(filenameExtension: item.ext)?.localizedDescription ?? (item.ext.isEmpty ? "Fichier" : "Fichier .\(item.ext)")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 14) {
                        ItemIcon(item: item, side: 48)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name).font(.headline)
                            Text(kindText).font(.subheadline).foregroundColor(.secondary)
                        }
                    }
                }
                Section("Détails") {
                    if item.isDir {
                        if let s = stats {
                            row("Taille", FSOps.format(s.size))
                            row("Contenu", "\(s.files) fichier(s), \(s.folders) dossier(s)")
                        } else {
                            HStack { Text("Taille"); Spacer(); ProgressView() }
                        }
                    } else {
                        row("Taille", "\(FSOps.format(item.size)) (\(item.size) octets)")
                    }
                    if let c = created { row("Création", c.formatted(date: .abbreviated, time: .shortened)) }
                    if let m = modified { row("Modification", m.formatted(date: .abbreviated, time: .shortened)) }
                    if !perms.isEmpty { row("Permissions", perms) }
                    row("Caché", item.isHidden ? "Oui (nom commençant par « . »)" : "Non")
                }
                Section("Emplacement") {
                    Text(Trash.display(item.url.path)).font(.system(size: 13, design: .monospaced)).textSelection(.enabled)
                    Button { UIPasteboard.general.string = item.url.path } label: { Label("Copier le chemin", systemImage: "link") }
                }
            }
            .navigationTitle("Informations")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("OK") { dismiss() } } }
            .task { await load() }
        }
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top) {
            Text(k)
            Spacer()
            Text(v).foregroundColor(.secondary).multilineTextAlignment(.trailing)
        }
    }

    private func load() async {
        let a = try? FSOps.fm.attributesOfItem(atPath: item.url.path)
        created = a?[.creationDate] as? Date
        modified = a?[.modificationDate] as? Date
        if let p = (a?[.posixPermissions] as? NSNumber)?.intValue { perms = String(p, radix: 8) }
        if item.isDir {
            let u = item.url
            stats = await Task.detached { FSOps.stats(u) }.value
        }
    }
}

// MARK: - Corbeille

struct TrashView: View {
    var onChange: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [Trash.Entry] = []
    @State private var message: String?
    @State private var confirmEmpty = false

    var body: some View {
        NavigationStack {
            List {
                if entries.isEmpty { Text("La corbeille est vide.").foregroundColor(.secondary) }
                ForEach(entries) { e in
                    HStack(spacing: 12) {
                        Image(systemName: e.isDir ? "folder.fill" : "doc.fill")
                            .foregroundColor(e.isDir ? .blue : .secondary).frame(width: 26)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(e.name).lineLimit(1)
                            Text(Trash.display(e.original)).font(.caption).foregroundColor(.secondary)
                                .lineLimit(1).truncationMode(.head)
                            Text(e.date.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundColor(.secondary)
                        }
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) { purge(e) } label: { Label("Supprimer", systemImage: "trash") }
                    }
                    .swipeActions(edge: .leading) {
                        Button { restore(e) } label: { Label("Restaurer", systemImage: "arrow.uturn.backward") }.tint(.green)
                    }
                    .contextMenu {
                        Button { restore(e) } label: { Label("Restaurer", systemImage: "arrow.uturn.backward") }
                        Button(role: .destructive) { purge(e) } label: { Label("Supprimer définitivement", systemImage: "trash") }
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle("Corbeille")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Fermer") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button("Vider") { confirmEmpty = true }.disabled(entries.isEmpty)
                }
            }
            .confirmationDialog("Vider la corbeille ?", isPresented: $confirmEmpty, titleVisibility: .visible) {
                Button("Vider définitivement", role: .destructive) { Trash.empty(); reload() }
            } message: { Text("Cette action est irréversible.") }
            .alert("Info", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("OK") {}
            } message: { Text(message ?? "") }
            .onAppear { reload() }
        }
    }

    private func reload() { entries = Trash.entries(); onChange() }

    private func restore(_ e: Trash.Entry) {
        do {
            let u = try Trash.restore(e)
            message = "Restauré dans « \(Trash.display(u.path)) »."
        } catch { message = error.localizedDescription }
        reload()
    }

    private func purge(_ e: Trash.Entry) { Trash.purge(e); reload() }
}

// MARK: - Ouverture d'un fichier (hors dépôt)

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
