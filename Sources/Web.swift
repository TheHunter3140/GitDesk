import SwiftUI
import WebKit
import SafariServices
import Combine

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

struct SafariView: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController { SFSafariViewController(url: url) }
    func updateUIViewController(_ vc: SFSafariViewController, context: Context) {}
}

enum WebSheet: Identifiable {
    case external(URL), share(URL), library, downloads
    var id: String {
        switch self {
        case .external(let u): return "e" + u.absoluteString
        case .share(let u): return "s" + u.absoluteString
        case .library: return "library"
        case .downloads: return "downloads"
        }
    }
}

struct WebTarget: Identifiable {
    let url: URL?
    var id: String { url?.absoluteString ?? "home" }
}

// MARK: - Modèle du navigateur (WKWebView persistant, cookies conservés, réglages mémorisés)
@MainActor
final class WebModel: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    let webView: WKWebView
    let store = BrowserStore.shared
    @Published var url: URL?
    @Published var title = ""
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var isLoading = false
    @Published var progress = 0.0
    @Published var sheet: WebSheet?
    @Published var toast: String?
    private var obs: [NSKeyValueObservation] = []
    private var cancellables = Set<AnyCancellable>()

    static let hosts = ["github.com", "githubusercontent.com", "githubassets.com", "githubapp.com"]
    static func isGitHub(_ u: URL) -> Bool {
        guard let h = u.host?.lowercased() else { return false }
        return hosts.contains { h == $0 || h.hasSuffix("." + $0) }
    }

    init(start: URL? = nil) {
        let st = BrowserStore.shared
        let first: URL? = start ?? (st.restoreLast ? URL(string: st.lastURL) : nil) ?? URL(string: "https://github.com")
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()
        cfg.allowsInlineMediaPlayback = true
        webView = WKWebView(frame: .zero, configuration: cfg)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsLinkPreview = true
        webView.isFindInteractionEnabled = true
        webView.pageZoom = CGFloat(st.zoom)
        let rc = UIRefreshControl()
        rc.addTarget(self, action: #selector(pulled), for: .valueChanged)
        webView.scrollView.refreshControl = rc
        obs = [
            webView.observe(\.url) { [weak self] _, _ in Task { @MainActor in self?.sync() } },
            webView.observe(\.title) { [weak self] _, _ in Task { @MainActor in self?.sync() } },
            webView.observe(\.canGoBack) { [weak self] _, _ in Task { @MainActor in self?.sync() } },
            webView.observe(\.canGoForward) { [weak self] _, _ in Task { @MainActor in self?.sync() } },
            webView.observe(\.isLoading) { [weak self] _, _ in Task { @MainActor in self?.sync() } },
            webView.observe(\.estimatedProgress) { [weak self] _, _ in Task { @MainActor in self?.sync() } }
        ]
        st.$zoom.sink { [weak self] z in self?.webView.pageZoom = CGFloat(z) }.store(in: &cancellables)
        if let first { webView.load(URLRequest(url: first)) }
    }

    @objc private func pulled() { webView.reload() }

    private func sync() {
        url = webView.url
        title = webView.title ?? ""
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
        isLoading = webView.isLoading
        progress = webView.estimatedProgress
    }

    func showToast(_ s: String) {
        toast = s
        Task { try? await Task.sleep(nanoseconds: 3_500_000_000); if toast == s { toast = nil } }
    }

    // MARK: actions
    func load(_ u: URL) { webView.load(URLRequest(url: u)) }
    func open(_ s: String) { if let u = URL(string: s) { load(u) } }
    func reloadOrStop() { if webView.isLoading { webView.stopLoading() } else { webView.reload() } }
    func find() { webView.findInteraction?.presentFindNavigator(showingReplace: false) }
    func openInSafari() { if let u = webView.url { UIApplication.shared.open(u) } }

    func go(_ input: String) {
        let t = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        let parts = t.split(separator: "/", omittingEmptySubsequences: true)
        if !t.contains(" "), !t.contains("://"), parts.count == 2, !parts[0].contains(".") {
            open("https://github.com/\(t)"); return
        }
        if let u = URL(string: t), let s = u.scheme, s.hasPrefix("http"), u.host != nil { load(u); return }
        if !t.contains(" "), t.contains("."), let u = URL(string: "https://" + t) { load(u); return }
        let q = t.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? t
        open("https://github.com/search?q=\(q)")
    }

    // MARK: navigation
    func webView(_ w: WKWebView, decidePolicyFor action: WKNavigationAction, preferences: WKWebpagePreferences,
                 decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
        guard let url = action.request.url else { decisionHandler(.cancel, preferences); return }
        let scheme = url.scheme?.lowercased() ?? ""
        preferences.preferredContentMode = store.desktop ? .desktop : .mobile
        if scheme == "http" || scheme == "https" {
            let main = action.targetFrame?.isMainFrame ?? true
            if main && store.restrict && !Self.isGitHub(url) {
                sheet = .external(url)
                decisionHandler(.cancel, preferences)
                return
            }
            decisionHandler(.allow, preferences)
            return
        }
        if ["about", "blob", "data", "javascript"].contains(scheme) { decisionHandler(.allow, preferences); return }
        UIApplication.shared.open(url)
        decisionHandler(.cancel, preferences)
    }

    func webView(_ w: WKWebView, decidePolicyFor r: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        let cd = (r.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition")?.lowercased() ?? ""
        decisionHandler(r.canShowMIMEType && !cd.hasPrefix("attachment") ? .allow : .download)
    }

    func webView(_ w: WKWebView, didCommit navigation: WKNavigation!) { w.pageZoom = CGFloat(store.zoom) }
    func webView(_ w: WKWebView, didFinish navigation: WKNavigation!) {
        w.scrollView.refreshControl?.endRefreshing()
        w.pageZoom = CGFloat(store.zoom)
        store.visit(w.url, w.title ?? "")
    }
    func webView(_ w: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { w.scrollView.refreshControl?.endRefreshing() }
    func webView(_ w: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { w.scrollView.refreshControl?.endRefreshing() }

    func webView(_ w: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if action.targetFrame == nil { w.load(action.request) }
        return nil
    }

    // MARK: boîtes JavaScript
    func webView(_ w: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let a = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler() })
        present(a)
    }

    func webView(_ w: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let a = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "Annuler", style: .cancel) { _ in completionHandler(false) })
        a.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(true) })
        present(a)
    }

    private func present(_ vc: UIViewController) {
        guard var top = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first?.rootViewController else { return }
        while let p = top.presentedViewController { top = p }
        top.present(vc, animated: true)
    }

    // MARK: téléchargements -> Documents/Téléchargements (gestionnaire dédié)
    func webView(_ w: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) { download.delegate = self }
    func webView(_ w: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) { download.delegate = self }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let dest = DownloadManager.shared.destination(for: suggestedFilename, download: download, source: response.url)
        showToast("Téléchargement : \(dest.lastPathComponent)")
        completionHandler(dest)
    }

    func downloadDidFinish(_ download: WKDownload) {
        DownloadManager.shared.finished(download)
        showToast("Téléchargement terminé · toucher pour ouvrir")
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        DownloadManager.shared.failed(download)
        showToast("Téléchargement échoué")
    }
}

struct WebContainer: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ v: WKWebView, context: Context) {}
}

struct WebBrowserView: View {
    @ObservedObject var m: WebModel
    @ObservedObject private var store = BrowserStore.shared
    @State private var editing = false
    @State private var text = ""
    @FocusState private var focused: Bool

    private var display: String {
        guard let u = m.url else { return "GitHub" }
        return (u.host ?? "") + u.path
    }

    var body: some View {
        VStack(spacing: 0) {
            addressBar
            ZStack(alignment: .top) {
                WebContainer(webView: m.webView)
                if m.isLoading { ProgressView(value: m.progress).progressViewStyle(.linear) }
            }
            bottomBar
        }
        .overlay(alignment: .top) {
            if let t = m.toast {
                Button { m.sheet = .downloads } label: {
                    Label(t, systemImage: "arrow.down.circle.fill").font(.footnote)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(.thinMaterial, in: Capsule())
                }
                .padding(.top, 56)
            }
        }
        .sheet(item: $m.sheet) { s in
            switch s {
            case .external(let u): SafariView(url: u).ignoresSafeArea()
            case .share(let u): ShareSheet(items: [u])
            case .library:
                NavigationStack {
                    BrowserLibraryView { u in m.load(u); m.sheet = nil }
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Fermer") { m.sheet = nil } } }
                }
            case .downloads:
                NavigationStack {
                    DownloadsView()
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Fermer") { m.sheet = nil } } }
                }
            }
        }
        .onChange(of: store.desktop) { _ in m.webView.reload() }
    }

    private var addressBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: editing ? "magnifyingglass" : (m.url?.scheme == "https" ? "lock.fill" : "globe"))
                    .font(.caption).foregroundColor(.secondary)
                if editing {
                    TextField("owner/repo, URL ou recherche", text: $text)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.webSearch)
                        .submitLabel(.go)
                        .focused($focused)
                        .onSubmit { m.go(text); editing = false }
                        .onAppear { focused = true }
                } else {
                    Text(display).lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture { text = m.url?.absoluteString ?? ""; editing = true }
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            if editing { Button("Annuler") { editing = false; focused = false } }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
    }

    private var bottomBar: some View {
        HStack {
            Button { m.webView.goBack() } label: { Image(systemName: "chevron.left") }
                .disabled(!m.canGoBack).accessibilityLabel("Page précédente")
            Spacer()
            Button { m.webView.goForward() } label: { Image(systemName: "chevron.right") }
                .disabled(!m.canGoForward).accessibilityLabel("Page suivante")
            Spacer()
            Button { if let u = m.url { m.sheet = .share(u) } } label: { Image(systemName: "square.and.arrow.up") }
                .disabled(m.url == nil).accessibilityLabel("Partager")
            Spacer()
            Button { m.reloadOrStop() } label: { Image(systemName: m.isLoading ? "xmark" : "arrow.clockwise") }
                .accessibilityLabel(m.isLoading ? "Arrêter" : "Recharger")
            Spacer()
            Menu {
                Button { store.toggleBookmark(m.url, title: m.title) } label: {
                    Label(store.isBookmarked(m.url) ? "Retirer des favoris" : "Ajouter aux favoris",
                          systemImage: store.isBookmarked(m.url) ? "star.slash" : "star")
                }
                Button { m.sheet = .library } label: { Label("Favoris et historique", systemImage: "book") }
                Button { m.sheet = .downloads } label: { Label("Téléchargements", systemImage: "arrow.down.circle") }
                Divider()
                Button { m.openInSafari() } label: { Label("Ouvrir dans Safari", systemImage: "safari") }
                Button { m.find() } label: { Label("Rechercher dans la page", systemImage: "text.magnifyingglass") }
                Button { UIPasteboard.general.string = m.url?.absoluteString } label: { Label("Copier le lien", systemImage: "link") }
                Divider()
                Toggle("Version ordinateur", isOn: $store.desktop)
                Toggle("Limiter à GitHub", isOn: $store.restrict)
                Button { store.zoom = min(1.5, ((store.zoom + 0.05) * 100).rounded() / 100) } label: { Label("Texte plus grand (\(Int((store.zoom * 100).rounded())) %)", systemImage: "textformat.size.larger") }
                Button { store.zoom = max(0.5, ((store.zoom - 0.05) * 100).rounded() / 100) } label: { Label("Texte plus petit", systemImage: "textformat.size.smaller") }
                Divider()
                Button { m.open("https://github.com") } label: { Label("Accueil GitHub", systemImage: "house") }
                Button { m.open("https://github.com/notifications") } label: { Label("Notifications", systemImage: "bell") }
                Button { m.open("https://github.com/pulls") } label: { Label("Pull requests", systemImage: "arrow.triangle.pull") }
                Button { m.open("https://github.com/issues") } label: { Label("Issues", systemImage: "circle.dotted") }
            } label: { Image(systemName: "ellipsis.circle") }
        }
        .font(.title3)
        .padding(.horizontal, 22).padding(.vertical, 10)
        .background(.bar)
    }
}

struct GitHubWebScreen: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var m: WebModel

    init(start: URL? = nil) {
        _m = StateObject(wrappedValue: WebModel(start: start))
    }

    var body: some View {
        NavigationStack {
            WebBrowserView(m: m)
                .navigationTitle(m.title.isEmpty ? "GitHub" : m.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Fermer") { dismiss() } } }
        }
    }
}
