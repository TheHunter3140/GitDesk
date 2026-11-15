import SwiftUI
import WebKit
import SafariServices

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
    case external(URL), share(URL)
    var id: String {
        switch self {
        case .external(let u): return "e" + u.absoluteString
        case .share(let u): return "s" + u.absoluteString
        }
    }
}

struct WebTarget: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

// MARK: - Modèle du navigateur (WKWebView persistant, cookies conservés)
@MainActor
final class WebModel: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    let webView: WKWebView
    @Published var url: URL?
    @Published var title = ""
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var isLoading = false
    @Published var progress = 0.0
    @Published var desktop = false
    @Published var restrict = true
    @Published var sheet: WebSheet?
    private var zoom: CGFloat = 1
    private var obs: [NSKeyValueObservation] = []
    private var downloadDest: URL?

    static let hosts = ["github.com", "githubusercontent.com", "githubassets.com", "githubapp.com"]
    static func isGitHub(_ u: URL) -> Bool {
        guard let h = u.host?.lowercased() else { return false }
        return hosts.contains { h == $0 || h.hasSuffix("." + $0) }
    }

    init(start: URL? = URL(string: "https://github.com")) {
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
        if let start { webView.load(URLRequest(url: start)) }
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

    // MARK: actions
    func load(_ u: URL) { webView.load(URLRequest(url: u)) }
    func open(_ s: String) { if let u = URL(string: s) { load(u) } }
    func reloadOrStop() { if webView.isLoading { webView.stopLoading() } else { webView.reload() } }
    func find() { webView.findInteraction?.presentFindNavigator(showingReplace: false) }
    func openInSafari() { if let u = webView.url { UIApplication.shared.open(u) } }
    func zoomIn() { zoom = min(3, zoom + 0.1); webView.pageZoom = zoom }
    func zoomOut() { zoom = max(0.5, zoom - 0.1); webView.pageZoom = zoom }

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
        preferences.preferredContentMode = desktop ? .desktop : .mobile
        if scheme == "http" || scheme == "https" {
            let main = action.targetFrame?.isMainFrame ?? true
            if main && restrict && !Self.isGitHub(url) {
                sheet = .external(url)   // hors GitHub : ouvert dans une fenêtre Safari séparée
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

    func webView(_ w: WKWebView, didFinish navigation: WKNavigation!) { w.scrollView.refreshControl?.endRefreshing() }
    func webView(_ w: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { w.scrollView.refreshControl?.endRefreshing() }
    func webView(_ w: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { w.scrollView.refreshControl?.endRefreshing() }

    // target=_blank : on reste dans la même vue
    func webView(_ w: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if action.targetFrame == nil { w.load(action.request) }
        return nil
    }

    // MARK: boîtes de dialogue JavaScript (confirm() de GitHub, etc.)
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

    // MARK: téléchargements (ZIP, release assets…) -> feuille de partage / Enregistrer dans Fichiers
    func webView(_ w: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) { download.delegate = self }
    func webView(_ w: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) { download.delegate = self }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(suggestedFilename)
        downloadDest = dest
        completionHandler(dest)
    }

    func downloadDidFinish(_ download: WKDownload) {
        if let d = downloadDest { sheet = .share(d) }
    }
}

struct WebContainer: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ v: WKWebView, context: Context) {}
}

struct WebBrowserView: View {
    @ObservedObject var m: WebModel
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
        .sheet(item: $m.sheet) { s in
            switch s {
            case .external(let u): SafariView(url: u).ignoresSafeArea()
            case .share(let u): ShareSheet(items: [u])
            }
        }
        .onChange(of: m.desktop) { _ in m.webView.reload() }
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
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
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
                Button { m.openInSafari() } label: { Label("Ouvrir dans Safari", systemImage: "safari") }
                Button { m.find() } label: { Label("Rechercher dans la page", systemImage: "text.magnifyingglass") }
                Button { UIPasteboard.general.string = m.url?.absoluteString } label: { Label("Copier le lien", systemImage: "link") }
                Toggle("Version ordinateur", isOn: $m.desktop)
                Toggle("Limiter à GitHub", isOn: $m.restrict)
                Button { m.zoomIn() } label: { Label("Agrandir la page", systemImage: "plus.magnifyingglass") }
                Button { m.zoomOut() } label: { Label("Réduire la page", systemImage: "minus.magnifyingglass") }
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
    let start: URL
    @Environment(\.dismiss) private var dismiss
    @StateObject private var m: WebModel

    init(start: URL = URL(string: "https://github.com")!) {
        self.start = start
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
